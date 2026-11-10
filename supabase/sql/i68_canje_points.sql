-- ============================================================================
-- ELI M. NAILS · I68 · Canje de Elima Points
--
-- 1) Billeteras POR SALÓN: unique (cliente_id, salon_id) + migración de datos
-- 2) turnos.descuento_puntos
-- 3) saldo_puntos_cliente(p_cliente_id)
-- 4) canjear_puntos_turno(p_turno_id, p_puntos, p_salon_id) con tope del 30%
-- 5) Devolución automática al cancelar
-- 6) procesar_puntos_turno() actualizada a la billetera por salón
--
-- REQUISITOS: i62 (billeteras/movimientos) + i66 (motor de puntos) aplicados.
-- IDEMPOTENTE: se puede correr varias veces.
-- ============================================================================


-- ============================================================================
-- 1 · PRE-CHECK
-- ============================================================================

do $$
begin
    if to_regclass('public.billeteras_puntos') is null
       or to_regclass('public.movimientos_puntos') is null then
        raise exception 'Falta i62_elima_belleza.sql (tablas de puntos)';
    end if;
    if to_regprocedure('public.procesar_puntos_turno(bigint)') is null then
        raise exception 'Falta i66_puntos.sql (motor de puntos)';
    end if;
end $$;


-- ============================================================================
-- 2 · COLUMNA DE DESCUENTO EN EL TURNO
--
-- price sigue siendo LO QUE SE COBRA (las finanzas no cambian).
-- El precio original queda como price + descuento_puntos.
-- ============================================================================

alter table public.turnos
    add column if not exists descuento_puntos numeric(12,2) not null default 0;

alter table public.turnos
    drop constraint if exists turnos_descuento_puntos_check;

alter table public.turnos
    add constraint turnos_descuento_puntos_check
    check (descuento_puntos >= 0);


-- ============================================================================
-- 3 · MIGRACIÓN · billetera global  →  una por salón
--
-- Antes: unique (cliente_id). Ahora: unique (cliente_id, salon_id).
--
-- Cada movimiento se reasigna a la billetera del salón donde se originó:
--   · si tiene turno → salón del turno
--   · si no → el salón que tenía la billetera
-- Después se recalcula el saldo de todas (la caché sale del ledger).
-- ============================================================================

alter table public.billeteras_puntos
    drop constraint if exists billeteras_puntos_cliente_unico;

do $$
declare
    v_hay_duplicadas integer := 0;
begin
    -- 3.1 · ¿hay clientas con movimientos de más de un salón?
    select count(*) into v_hay_duplicadas
      from (
        select b.cliente_id
          from public.movimientos_puntos m
          join public.billeteras_puntos b on b.id = m.billetera_id
          left join public.turnos t on t.id = m.turno_id
         group by b.cliente_id
        having count(distinct coalesce(t.salon_id, b.salon_id)) > 1
      ) x;

    if v_hay_duplicadas > 0 then
        raise notice 'I68 · % clienta(s) con puntos de varios salones: se separan', v_hay_duplicadas;
    end if;

    -- 3.2 · crear las billeteras por salón que falten
    insert into public.billeteras_puntos (cliente_id, salon_id, saldo_actual)
    select distinct b.cliente_id, coalesce(t.salon_id, b.salon_id), 0
      from public.movimientos_puntos m
      join public.billeteras_puntos b on b.id = m.billetera_id
      left join public.turnos t on t.id = m.turno_id
     where coalesce(t.salon_id, b.salon_id) is not null
    on conflict do nothing;

    -- 3.3 · reasignar cada movimiento a su billetera correcta
    create temp table if not exists _i68_mapa (mov_id uuid primary key, bil_id uuid not null);
    truncate _i68_mapa;

    insert into _i68_mapa (mov_id, bil_id)
    select m.id, nb.id
      from public.movimientos_puntos m
      join public.billeteras_puntos b on b.id = m.billetera_id
      left join public.turnos t on t.id = m.turno_id
      join public.billeteras_puntos nb
        on nb.cliente_id = b.cliente_id
       and nb.salon_id = coalesce(t.salon_id, b.salon_id)
     where nb.id <> m.billetera_id;

    update public.movimientos_puntos m
       set billetera_id = m2.bil_id
      from _i68_mapa m2
     where m2.mov_id = m.id;

    -- 3.4 · recalcular saldos desde el ledger
    perform public.recalcular_saldo_puntos(b.id)
       from public.billeteras_puntos b;

    -- 3.5 · borrar billeteras vacías que hayan quedado
    delete from public.billeteras_puntos b
     where not exists (select 1 from public.movimientos_puntos m where m.billetera_id = b.id)
       and b.saldo_actual = 0;

    drop table if exists _i68_mapa;
end $$;

-- La nueva unicidad va DESPUÉS de la migración
alter table public.billeteras_puntos
    drop constraint if exists billeteras_puntos_cliente_salon_unico;

alter table public.billeteras_puntos
    add constraint billeteras_puntos_cliente_salon_unico
    unique (cliente_id, salon_id);


-- ============================================================================
-- 4 · MOTOR DE PUNTOS · ahora busca la billetera POR SALÓN
--
-- Igual que i66, cambiando solo la búsqueda de la billetera: antes era
-- "la de la clienta" (global), ahora "la de la clienta en este salón".
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

    if lower(coalesce(v_turno.status, '')) <> all (c_tipos_realizado) then
        return query select false, 0::numeric, 'turno_no_realizado'::text;
        return;
    end if;

    select e.plan_efectivo into v_plan
      from public._saas_plan_efectivo(v_turno.salon_id) e;

    if coalesce(v_plan, 'gratis') not in ('pro', 'premium') then
        return query select false, 0::numeric, 'plan_no_habilitado'::text;
        return;
    end if;

    if v_turno.cliente_id is null then
        return query select false, 0::numeric, 'sin_clienta'::text;
        return;
    end if;

    v_puntos := public.puntos_por_turno(v_turno.price);
    if coalesce(v_puntos, 0) <= 0 then
        return query select false, 0::numeric, 'sin_puntos'::text;
        return;
    end if;

    -- billetera de la clienta EN ESTE SALÓN
    select b.id into v_billetera
      from public.billeteras_puntos b
     where b.cliente_id = v_turno.cliente_id
       and b.salon_id = v_turno.salon_id
     limit 1;

    if v_billetera is null then
        insert into public.billeteras_puntos (cliente_id, salon_id, saldo_actual)
        values (v_turno.cliente_id, v_turno.salon_id, 0)
        on conflict (cliente_id, salon_id) do nothing
        returning id into v_billetera;

        if v_billetera is null then
            select b.id into v_billetera
              from public.billeteras_puntos b
             where b.cliente_id = v_turno.cliente_id
               and b.salon_id = v_turno.salon_id
             limit 1;
        end if;
    end if;

    if v_billetera is null then
        return query select false, 0::numeric, 'sin_billetera'::text;
        return;
    end if;

    select * into v_ganado
      from public.movimientos_puntos m
     where m.turno_id = p_turno_id and m.tipo = 'ganado'
     limit 1;

    if found then
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

        insert into public.movimientos_puntos (billetera_id, tipo, monto, motivo, turno_id)
        values (v_billetera, 'ajuste', v_ganado.monto,
                'Turno #' || p_turno_id || ' reabierto y vuelto a completar', p_turno_id);

        return query select true, v_ganado.monto, 'restituido'::text;
        return;
    end if;

    insert into public.movimientos_puntos (billetera_id, tipo, monto, motivo, turno_id)
    values (v_billetera, 'ganado', v_puntos,
            'Turno #' || p_turno_id || ' · ' || coalesce(v_turno.service_type, 'servicio'),
            p_turno_id);

    return query select true, v_puntos, 'otorgado'::text;
end $$;

grant execute on function public.procesar_puntos_turno(bigint) to authenticated;


-- ============================================================================
-- 5 · SALDO DE UNA CLIENTA (para la dueña)
--
-- obtener_mis_puntos() devuelve los puntos de QUIEN LLAMA. Para el formulario
-- hace falta el saldo de la clienta seleccionada, y solo del salón propio.
-- ============================================================================

create or replace function public.saldo_puntos_cliente(p_cliente_id bigint)
returns numeric
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_salon uuid;
    v_saldo numeric := 0;
begin
    if auth.uid() is null or p_cliente_id is null then
        return 0;
    end if;

    select c.salon_id into v_salon
      from public.clientes c
     where c.id = p_cliente_id;

    if v_salon is null then
        return 0;
    end if;

    if not (public.es_miembro(v_salon) or public.es_super_admin()) then
        raise exception 'sin_permisos';
    end if;

    select coalesce(b.saldo_actual, 0) into v_saldo
      from public.billeteras_puntos b
     where b.cliente_id = p_cliente_id
       and b.salon_id = v_salon
     limit 1;

    return coalesce(v_saldo, 0);
end $$;

revoke all on function public.saldo_puntos_cliente(bigint) from public, anon;
grant execute on function public.saldo_puntos_cliente(bigint) to authenticated;


-- ============================================================================
-- 6 · CANJE
--
-- Tope: 30% del precio original del turno (price + descuento_puntos).
-- El saldo se bloquea con FOR UPDATE: dos canjes simultáneos no pueden
-- dejar la billetera en negativo.
-- ============================================================================

create or replace function public.canjear_puntos_turno(
    p_turno_id bigint,
    p_puntos   numeric,
    p_salon_id uuid
)
returns table (ok boolean, puntos numeric, motivo text)
language plpgsql
security definer
set search_path = public
as $$
declare
    c_tope      constant numeric := 0.30;
    c_cerrados  constant text[] := array['completed', 'realizado', 'cancelled', 'cancelado'];

    v_turno     public.turnos%rowtype;
    v_puntos    numeric;
    v_billetera uuid;
    v_saldo     numeric;
    v_base      numeric;
    v_tope      numeric;
    v_ya        numeric;
begin
    v_puntos := floor(coalesce(p_puntos, 0));

    if v_puntos <= 0 then
        return query select false, 0::numeric, 'puntos_invalidos'::text;
        return;
    end if;

    select * into v_turno from public.turnos t where t.id = p_turno_id;
    if not found then
        return query select false, 0::numeric, 'turno_no_existe'::text;
        return;
    end if;

    if v_turno.salon_id is distinct from p_salon_id then
        return query select false, 0::numeric, 'turno_de_otro_salon'::text;
        return;
    end if;

    if not (public.es_miembro(p_salon_id) or public.es_super_admin()) then
        raise exception 'sin_permisos';
    end if;

    if v_turno.cliente_id is null then
        return query select false, 0::numeric, 'sin_clienta'::text;
        return;
    end if;

    if lower(coalesce(v_turno.status, '')) = any (c_cerrados) then
        return query select false, 0::numeric, 'turno_cerrado'::text;
        return;
    end if;

    -- billetera de la clienta en este salón, bloqueada
    select b.id into v_billetera
      from public.billeteras_puntos b
     where b.cliente_id = v_turno.cliente_id
       and b.salon_id = p_salon_id
     for update;

    if v_billetera is null then
        return query select false, 0::numeric, 'sin_billetera'::text;
        return;
    end if;

    select b.saldo_actual into v_saldo
      from public.billeteras_puntos b
     where b.id = v_billetera;

    if coalesce(v_saldo, 0) < v_puntos then
        return query select false, 0::numeric, 'saldo_insuficiente'::text;
        return;
    end if;

    v_base := coalesce(v_turno.price, 0) + coalesce(v_turno.descuento_puntos, 0);
    v_tope := floor(v_base * c_tope);

    if v_puntos > v_tope then
        return query select false, v_tope, 'supera_tope'::text;
        return;
    end if;

    select coalesce(sum(abs(m.monto)), 0) into v_ya
      from public.movimientos_puntos m
     where m.turno_id = p_turno_id
       and m.tipo = 'canjeado';

    if v_ya > 0 then
        return query select false, v_ya, 'ya_canjeado'::text;
        return;
    end if;

    insert into public.movimientos_puntos (billetera_id, tipo, monto, motivo, turno_id)
    values (v_billetera, 'canjeado', -v_puntos,
            'Canje en turno #' || p_turno_id, p_turno_id);

    update public.turnos t
       set descuento_puntos = coalesce(t.descuento_puntos, 0) + v_puntos
     where t.id = p_turno_id;

    return query select true, v_puntos, 'canjeado'::text;
end $$;

revoke all on function public.canjear_puntos_turno(bigint, numeric, uuid) from public, anon;
grant execute on function public.canjear_puntos_turno(bigint, numeric, uuid) to authenticated;


-- ============================================================================
-- 7 · DEVOLUCIÓN AUTOMÁTICA AL CANCELAR
--
-- Si el turno tenía puntos canjeados, se devuelven con un 'ajuste' positivo y
-- el turno vuelve a su precio original (ya no está cobrado).
-- ============================================================================

create or replace function public.trg_devolver_puntos_turno()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    c_cancelado constant text[] := array['cancelled', 'cancelado'];
    v_canjeado  numeric := 0;
    v_devuelto  numeric := 0;
    v_falta     numeric := 0;
begin
    if not (lower(coalesce(new.status, '')) = any (c_cancelado)) then
        return null;
    end if;
    if lower(coalesce(old.status, '')) = any (c_cancelado) then
        return null;
    end if;

    select coalesce(sum(abs(m.monto)), 0) into v_canjeado
      from public.movimientos_puntos m
     where m.turno_id = new.id
       and m.tipo = 'canjeado';

    if v_canjeado <= 0 then
        return null;
    end if;

    select coalesce(sum(m.monto), 0) into v_devuelto
      from public.movimientos_puntos m
     where m.turno_id = new.id
       and m.tipo = 'ajuste'
       and m.monto > 0;

    v_falta := v_canjeado - v_devuelto;
    if v_falta <= 0 then
        return null;
    end if;

    insert into public.movimientos_puntos (billetera_id, tipo, monto, motivo, turno_id)
    select b.id, 'ajuste', v_falta,
           'Devolución de puntos · turno #' || new.id, new.id
      from public.billeteras_puntos b
     where b.cliente_id = new.cliente_id
       and b.salon_id = new.salon_id;

    update public.turnos t
       set price = coalesce(t.price, 0) + coalesce(t.descuento_puntos, 0),
           descuento_puntos = 0
     where t.id = new.id;

    return null;
end $$;

drop trigger if exists trg_devolver_puntos_turno on public.turnos;
create trigger trg_devolver_puntos_turno
after update of status on public.turnos
for each row
when (lower(coalesce(old.status, '')) is distinct from lower(coalesce(new.status, '')))
execute function public.trg_devolver_puntos_turno();


-- ============================================================================
-- 8 · LECTURA PARA EL PORTAL · sigue igual, pero ahora suma todas las
-- billeteras de la clienta (una por salón) y muestra el salón de cada una.
-- ============================================================================

notify pgrst, 'reload schema';

-- ============================================================================
-- VERIFICACIÓN
-- ============================================================================
-- 1) ¿quedó la unicidad por salón?
-- select conname, pg_get_constraintdef(oid)
--   from pg_constraint where conrelid = 'public.billeteras_puntos'::regclass;
--
-- 2) ¿se separaron los saldos?
-- select cliente_id, salon_id, saldo_actual from public.billeteras_puntos
--  order by cliente_id, salon_id;
--
-- 3) saldo de una clienta (desde la sesión de la dueña):
-- select public.saldo_puntos_cliente(123);
--
-- 4) canje (turno en borrador del salón propio):
-- select * from public.canjear_puntos_turno(456, 500, 'UUID-DEL-SALON');
--    → ok=true, puntos=500, motivo='canjeado'
--
-- 5) tope del 30%: con un turno de $10.000 el máximo es 3000
-- select * from public.canjear_puntos_turno(456, 3001, 'UUID-DEL-SALON');
--    → ok=false, motivo='supera_tope'
--
-- 6) dispararlo dos veces:
-- select * from public.canjear_puntos_turno(456, 500, 'UUID-DEL-SALON');
--    → ok=false, motivo='ya_canjeado'
--
-- 7) cancelar devuelve los puntos:
-- update public.turnos set status = 'cancelled' where id = 456;
-- select tipo, monto from public.movimientos_puntos where turno_id = 456 order by creado_en;
--    → canjeado -500 · ajuste +500
