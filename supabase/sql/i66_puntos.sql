-- ============================================================================
-- ELI M. NAILS · I66 · Motor de Elima Points
--
-- Activa la ganancia de puntos y expone la lectura para el portal de clientas.
-- Reutiliza la infraestructura de I62: billeteras_puntos, movimientos_puntos,
-- recalcular_saldo_puntos() y trg_proteger_saldo_puntos(). NADA de eso se toca.
--
-- DISEÑO
--   · El otorgamiento vive en un TRIGGER: no se puede saltear desde el cliente,
--     funciona venga la escritura de index.html, del admin o del SQL Editor.
--   · procesar_puntos_turno() queda como entrada manual (reprocesar / backfill)
--     y usa exactamente el mismo núcleo, así no hay dos verdades.
--   · "Deshacer" un turno inserta un 'reverso'; volver a completarlo inserta un
--     'ajuste'. El ledger nunca se reescribe y el índice único de 'ganado'
--     nunca se viola.
--
-- REQUISITOS: i62_elima_belleza.sql aplicado.
-- IDEMPOTENTE: se puede correr varias veces.
-- ============================================================================


-- ============================================================================
-- 0 · PRE-CHECK
-- ============================================================================

do $$
begin
    if to_regclass('public.billeteras_puntos') is null
       or to_regclass('public.movimientos_puntos') is null then
        raise exception 'Falta i62_elima_belleza.sql (no existen las tablas de puntos)';
    end if;
    if to_regprocedure('public._saas_plan_efectivo(uuid)') is null then
        raise exception 'Falta i55_saas.sql (no existe _saas_plan_efectivo)';
    end if;
end $$;


-- ============================================================================
-- 1 · REGLA DE NEGOCIO  ⚠️ LOS DOS NÚMEROS QUE PODÉS CAMBIAR
--
--   c_porcentaje  → qué parte del precio se convierte en puntos
--   c_valor_punto → cuántos pesos vale 1 punto (para expresar el saldo)
--
--   puntos = floor(precio * c_porcentaje / c_valor_punto)
--
--   Con los valores de abajo (regla literal de I66):
--       turno de $45.000  →  floor(45000 * 0.10 / 1) = 4500 puntos
--
--   Si preferís un cashback más sostenible, cambiá SOLO estas dos líneas
--   antes de correr el archivo y volvé a ejecutarlo:
--       1%  de cashback  →  c_porcentaje := 0.01   (turno de $45.000 = 450 pts)
--       10% con punto de $10 → c_porcentaje := 0.10, c_valor_punto := 10 (450 pts)
-- ============================================================================

create or replace function public.puntos_por_turno(p_precio numeric)
returns numeric
language sql
immutable
as $$
    select floor(
        greatest(coalesce(p_precio, 0), 0) * 0.10 / 1
    );
$$;

comment on function public.puntos_por_turno(numeric) is
    'Elima Points: 10% del precio del turno, redondeado hacia abajo. Un punto = un peso.';


-- ============================================================================
-- 2 · VÍNCULO CLIENTA ↔ CUENTA
--
-- clientes.user_id es la STAFF que cargó a la clienta (default auth.uid()).
-- Para que el portal sepa de quién es la billetera hace falta una columna
-- propia, opcional, que se completa cuando la clienta entra con su email.
--
-- Mientras no esté vinculada, obtener_mis_puntos() igual la encuentra por
-- email: las dos vías conviven.
-- ============================================================================

alter table public.clientes
    add column if not exists auth_user_id uuid;

create index if not exists clientes_auth_user_idx
    on public.clientes (auth_user_id)
    where auth_user_id is not null;

create index if not exists clientes_email_lower_idx
    on public.clientes (lower(email))
    where email is not null;


-- Devuelve los ids de "mis" fichas de clienta: por vínculo directo o por email.
-- Interna: no se expone a anon.
create or replace function public._mis_clientes()
returns setof bigint
language sql
stable
security definer
set search_path = public
as $$
    with yo as (
        select auth.uid() as uid,
               lower(nullif(auth.jwt() ->> 'email', '')) as email
    )
    select c.id
      from public.clientes c, yo
     where (yo.uid is not null and c.auth_user_id = yo.uid)
        or (yo.email is not null and lower(c.email) = yo.email);
$$;

revoke all on function public._mis_clientes() from public, anon;


-- Vincula mi cuenta a las fichas que tengan mi email (una sola vez).
create or replace function public.vincular_mi_cuenta()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    v_email text := lower(nullif(auth.jwt() ->> 'email', ''));
    v_cantidad integer := 0;
begin
    if auth.uid() is null or v_email is null then
        return 0;
    end if;

    update public.clientes c
       set auth_user_id = auth.uid()
     where lower(c.email) = v_email
       and c.auth_user_id is null;

    get diagnostics v_cantidad = row_count;
    return v_cantidad;
end $$;

grant execute on function public.vincular_mi_cuenta() to authenticated;


-- ============================================================================
-- 3 · NÚCLEO · procesar_puntos_turno(p_turno_id)
--
-- Idempotente. Devuelve (otorgado, puntos, motivo) para que la app pueda
-- explicar qué pasó sin adivinar.
-- ============================================================================

create or replace function public.procesar_puntos_turno(p_turno_id bigint)
returns table (otorgado boolean, puntos numeric, motivo text)
language plpgsql
security definer
set search_path = public
as $$
declare
    c_tipos_realizado constant text[] := array['completed', 'realizado'];

    v_turno     public.turnos%rowtype;
    v_plan      text;
    v_puntos    numeric;
    v_billetera uuid;
    v_ganado    public.movimientos_puntos%rowtype;
    v_reverso   public.movimientos_puntos%rowtype;
begin
    select * into v_turno from public.turnos t where t.id = p_turno_id;
    if not found then
        return query select false, 0::numeric, 'turno_no_existe'::text;
        return;
    end if;

    -- 1 · El turno tiene que estar realizado
    if lower(coalesce(v_turno.status, '')) <> all (c_tipos_realizado) then
        return query select false, 0::numeric, 'turno_no_realizado'::text;
        return;
    end if;

    -- 2 · Solo salones con plan Pro o Premium (plan EFECTIVO, no el guardado)
    select e.plan_efectivo into v_plan
      from public._saas_plan_efectivo(v_turno.salon_id) e;

    if coalesce(v_plan, 'gratis') not in ('pro', 'premium') then
        return query select false, 0::numeric, 'plan_no_habilitado'::text;
        return;
    end if;

    -- 3 · Hace falta saber de quién es el turno
    if v_turno.cliente_id is null then
        return query select false, 0::numeric, 'sin_clienta'::text;
        return;
    end if;

    v_puntos := public.puntos_por_turno(v_turno.price);
    if coalesce(v_puntos, 0) <= 0 then
        return query select false, 0::numeric, 'sin_puntos'::text;
        return;
    end if;

    -- 4 · Billetera de la clienta (una sola por clienta, global)
    select b.id into v_billetera
      from public.billeteras_puntos b
     where b.cliente_id = v_turno.cliente_id
     limit 1;

    if v_billetera is null then
        insert into public.billeteras_puntos (cliente_id, salon_id, saldo_actual)
        values (v_turno.cliente_id, v_turno.salon_id, 0)
        on conflict (cliente_id) do nothing
        returning id into v_billetera;

        if v_billetera is null then
            select b.id into v_billetera
              from public.billeteras_puntos b
             where b.cliente_id = v_turno.cliente_id
             limit 1;
        end if;
    end if;

    if v_billetera is null then
        return query select false, 0::numeric, 'sin_billetera'::text;
        return;
    end if;

    -- 5 · ¿Ya se otorgó? ¿Se revirtió?
    select * into v_ganado
      from public.movimientos_puntos m
     where m.turno_id = p_turno_id and m.tipo = 'ganado'
     limit 1;

    if found then
        -- ¿hay un reverso posterior al ganado? entonces el turno se reabrió
        select * into v_reverso
          from public.movimientos_puntos m
         where m.turno_id = p_turno_id
           and m.tipo = 'reverso'
           and m.creado_en > v_ganado.creado_en
         order by m.creado_en desc
         limit 1;

        if not found then
            return query select false, v_ganado.monto, 'ya_otorgado'::text;
            return;
        end if;

        -- se había revertido: se restituye con un ajuste (auditable)
        insert into public.movimientos_puntos (billetera_id, tipo, monto, motivo, turno_id)
        values (v_billetera, 'ajuste', v_ganado.monto,
                'Turno #' || p_turno_id || ' reabierto y vuelto a completar', p_turno_id);

        return query select true, v_ganado.monto, 'restituido'::text;
        return;
    end if;

    -- 6 · Otorgamiento
    insert into public.movimientos_puntos (billetera_id, tipo, monto, motivo, turno_id)
    values (v_billetera, 'ganado', v_puntos,
            'Turno #' || p_turno_id || ' · ' || coalesce(v_turno.service_type, 'servicio'),
            p_turno_id);

    return query select true, v_puntos, 'otorgado'::text;
end $$;

grant execute on function public.procesar_puntos_turno(bigint) to authenticated;


-- ============================================================================
-- 4 · REVERSO · se llama cuando el turno deja de estar realizado
-- ============================================================================

create or replace function public.revertir_puntos_turno(p_turno_id bigint)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_ganado  public.movimientos_puntos%rowtype;
    v_reverso public.movimientos_puntos%rowtype;
begin
    select * into v_ganado
      from public.movimientos_puntos m
     where m.turno_id = p_turno_id and m.tipo = 'ganado'
     limit 1;

    if not found then
        return false;
    end if;

    select * into v_reverso
      from public.movimientos_puntos m
     where m.turno_id = p_turno_id
       and m.tipo = 'reverso'
       and m.creado_en > v_ganado.creado_en
     limit 1;

    if found then
        return false;   -- ya estaba revertido
    end if;

    insert into public.movimientos_puntos (billetera_id, tipo, monto, motivo, turno_id)
    values (v_ganado.billetera_id, 'reverso', -v_ganado.monto,
            'Turno #' || p_turno_id || ' deshecho', p_turno_id);

    return true;
end $$;

revoke all on function public.revertir_puntos_turno(bigint) from public, anon;
grant execute on function public.revertir_puntos_turno(bigint) to authenticated;


-- ============================================================================
-- 5 · TRIGGER · el que realmente otorga
--
-- AFTER UPDATE OF status: cubre index.html (marcar/deshacer), el admin y el
-- SQL Editor. No hay forma de marcar un turno como realizado y saltearlo.
-- ============================================================================

create or replace function public.trg_puntos_turno()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    c_tipos_realizado constant text[] := array['completed', 'realizado'];
    v_antes  boolean;
    v_ahora  boolean;
begin
    v_antes := lower(coalesce(old.status, '')) = any (c_tipos_realizado);
    v_ahora := lower(coalesce(new.status, '')) = any (c_tipos_realizado);

    if v_ahora and not v_antes then
        -- errores de puntos NUNCA bloquean el cambio de estado del turno
        begin
            perform public.procesar_puntos_turno(new.id);
        exception when others then
            raise warning 'I66 · no se pudieron otorgar puntos al turno %: %', new.id, sqlerrm;
        end;

    elsif v_antes and not v_ahora then
        begin
            perform public.revertir_puntos_turno(new.id);
        exception when others then
            raise warning 'I66 · no se pudieron revertir puntos del turno %: %', new.id, sqlerrm;
        end;
    end if;

    return null;
end $$;

drop trigger if exists trg_puntos_turno on public.turnos;
create trigger trg_puntos_turno
after update of status on public.turnos
for each row
when (old.status is distinct from new.status)
execute function public.trg_puntos_turno();


-- ============================================================================
-- 6 · LECTURA PARA EL PORTAL · obtener_mis_puntos()
--
-- Sin parámetros: la identidad es auth.uid(). security definer porque la RLS
-- de billeteras_puntos exige es_miembro() y una clienta NO es miembro.
--
-- Devuelve SOLO: saldo total, nombre de pila y los últimos movimientos con el
-- nombre del salón. Nada de ids, emails ajenos, precios de turnos ni datos de
-- otros salones.
-- ============================================================================

create or replace function public.obtener_mis_puntos()
returns jsonb
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_ids      bigint[];
    v_saldo    numeric := 0;
    v_nombre   text := '';
    v_movs     jsonb := '[]'::jsonb;
begin
    if auth.uid() is null then
        return jsonb_build_object('saldo', 0, 'clienta', '', 'movimientos', '[]'::jsonb);
    end if;

    select coalesce(array_agg(t.id), '{}'::bigint[]) into v_ids
      from public._mis_clientes() as t(id);

    if array_length(v_ids, 1) is null then
        return jsonb_build_object('saldo', 0, 'clienta', '', 'movimientos', '[]'::jsonb);
    end if;

    select coalesce(sum(b.saldo_actual), 0) into v_saldo
      from public.billeteras_puntos b
     where b.cliente_id = any (v_ids);

    select c.nombre into v_nombre
      from public.clientes c
     where c.id = any (v_ids)
     order by c.id
     limit 1;

    select coalesce(jsonb_agg(fila order by fila ->> 'fecha' desc), '[]'::jsonb)
      into v_movs
      from (
        select jsonb_build_object(
                   'tipo',   m.tipo,
                   'monto',  m.monto,
                   'motivo', coalesce(m.motivo, ''),
                   'salon',  coalesce(s.nombre, ''),
                   'fecha',  m.creado_en
               ) as fila
          from public.movimientos_puntos m
          join public.billeteras_puntos b on b.id = m.billetera_id
          left join public.salones s on s.id = b.salon_id
         where b.cliente_id = any (v_ids)
         order by m.creado_en desc
         limit 40
      ) t;

    return jsonb_build_object(
        'saldo',       v_saldo,
        'clienta',     coalesce(split_part(v_nombre, ' ', 1), ''),
        'movimientos', v_movs
    );
end $$;

revoke all on function public.obtener_mis_puntos() from public, anon;
grant execute on function public.obtener_mis_puntos() to authenticated;


-- ============================================================================
-- 7 · REPARACIÓN OPCIONAL · puntos de turnos ya realizados
--
-- Si ya tenés turnos completados y querés otorgarles los puntos de una vez,
-- corré esto UNA sola vez (es idempotente: no duplica nada).
-- ============================================================================
-- select t.id, (public.procesar_puntos_turno(t.id)).*
--   from public.turnos t
--  where lower(t.status) in ('completed', 'realizado')
--  order by t.id desc
--  limit 200;


notify pgrst, 'reload schema';

-- ============================================================================
-- VERIFICACIÓN
-- ============================================================================
-- 1) objetos creados
-- select proname from pg_proc
--  where proname in ('puntos_por_turno','procesar_puntos_turno',
--                    'revertir_puntos_turno','obtener_mis_puntos','vincular_mi_cuenta');
--
-- 2) el trigger está en su lugar
-- select tgname, tgrelid::regclass from pg_trigger where tgname = 'trg_puntos_turno';
--
-- 3) cuánto daría un turno (antes de tocar nada)
-- select public.puntos_por_turno(45000) as puntos_turno_45k;   -- 4500
--
-- 4) prueba de punta a punta con un turno real (elegí uno de un salón Pro):
-- update public.turnos set status = 'completed' where id = 123;
-- select * from public.movimientos_puntos order by creado_en desc limit 1;
-- select * from public.billeteras_puntos where cliente_id = (select cliente_id from public.turnos where id = 123);
--
-- 5) deshacer revierte:
-- update public.turnos set status = 'pending' where id = 123;
-- select tipo, monto from public.movimientos_puntos where turno_id = 123 order by creado_en;
--    → ganado +4500, reverso -4500
--
-- 6) el portal (con la sesión de la clienta):
-- select public.obtener_mis_puntos();
