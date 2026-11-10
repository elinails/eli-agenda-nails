-- ============================================================================
-- ELI M. NAILS · I73 · FIX DE SEGURIDAD, CONTABILIDAD Y ZONA HORARIA
--
-- 1) public.revertir_puntos_turno():
--      + guard de autorización (miembro / superadmin / service_role / postgres)
--      + ACL cerrada a anon
-- 2) public.recalcular_saldo_puntos():
--      + revoke de anon y authenticated (queda solo service_role; el trigger
--        interno sigue funcionando porque es SECURITY DEFINER)
-- 3) public.canjear_puntos_turno():
--      + deja de SUMAR descuento_puntos: lo deja EXACTO (v_puntos)
--      + contrato: price ya es el neto; descuento_puntos es el usado;
--        price + descuento_puntos = precio original (base del tope 30%)
-- 4) public.solicitud_aprobar():
--      + vencimiento con fecha/hora de America/Argentina/Buenos_Aires,
--        no con current_date/localtime (UTC)
--
-- No cambia datos. Idempotente. No toca index.html: la precarga del frontend
-- (price neto + descuento usado) es correcta para calcular el tope.
--
-- REQUISITOS: I71 aplicado (idealmente i71_seguridad_final.sql).
-- USO:
--   supabase db query --linked -f supabase/sql/i73_fix_puntos.sql
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 0 · PRE-CHECK
-- ----------------------------------------------------------------------------

do $i73_pre$
begin
    if to_regprocedure('public.revertir_puntos_turno(bigint)') is null
       or to_regprocedure('public.recalcular_saldo_puntos(uuid)') is null
       or to_regprocedure('public.canjear_puntos_turno(bigint, numeric, uuid)') is null
       or to_regprocedure('public.solicitud_aprobar(bigint)') is null then
        raise exception 'I73: faltan funciones de I68/I69. Aplicar i71_seguridad_final.sql primero.';
    end if;
end
$i73_pre$;


-- ----------------------------------------------------------------------------
-- 1 · REVERTIR PUNTOS · guard de autorización
-- ----------------------------------------------------------------------------

create or replace function public.revertir_puntos_turno(p_turno_id bigint)
returns boolean
language plpgsql
security definer
set search_path = public
as $i73_revertir$
declare
    v_turno   public.turnos%rowtype;
    v_ganado  public.movimientos_puntos%rowtype;
    v_reverso public.movimientos_puntos%rowtype;
begin
    select * into v_turno
      from public.turnos t
     where t.id = p_turno_id;

    if not found then
        return false;
    end if;

    -- I73 · GUARD: nadie de otro salón puede revertir puntos ajenos.
    if not (
           public.es_miembro(v_turno.salon_id)
        or public.es_super_admin()
        or coalesce(auth.jwt() ->> 'role', '') = 'service_role'
        or session_user in ('postgres', 'supabase_admin')
    ) then
        raise exception 'sin_permisos';
    end if;

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
end
$i73_revertir$;

comment on function public.revertir_puntos_turno(bigint) is
    'Revierte los puntos de un turno deshecho. I73: exige membresía, superadmin o service_role.';

revoke all on function public.revertir_puntos_turno(bigint) from public, anon;
grant execute on function public.revertir_puntos_turno(bigint) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 2 · RECALCULAR SALDO · solo uso interno/service_role
-- ----------------------------------------------------------------------------

revoke all on function public.recalcular_saldo_puntos(uuid) from public, anon, authenticated;
grant execute on function public.recalcular_saldo_puntos(uuid) to service_role;

comment on function public.recalcular_saldo_puntos(uuid) is
    'Recalcula la caché saldo_actual desde el ledger. I73: solo service_role; lo llama el trigger SECURITY DEFINER.';


-- ----------------------------------------------------------------------------
-- 3 · CANJEAR PUNTOS · dejar de sumar el descuento dos veces
-- ----------------------------------------------------------------------------

create or replace function public.canjear_puntos_turno(
    p_turno_id bigint,
    p_puntos   numeric,
    p_salon_id uuid
)
returns table (ok boolean, puntos numeric, motivo text)
language plpgsql
security definer
set search_path = public
as $i73_canjear$
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

    -- I73 · CONTRATO: price ya es el neto y descuento_puntos ya viene
    -- precargado por index.html. La base del tope es el precio original.
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

    -- I73 · FIX: dejar el valor EXACTO, no sumarlo dos veces.
    update public.turnos t
       set descuento_puntos = v_puntos
     where t.id = p_turno_id;

    return query select true, v_puntos, 'canjeado'::text;
end
$i73_canjear$;

comment on function public.canjear_puntos_turno(bigint, numeric, uuid) is
    'Canje con tope del 30%. I73: descuento_puntos queda exacto (price neto + descuento = precio original).';

revoke all on function public.canjear_puntos_turno(bigint, numeric, uuid) from public, anon;
grant execute on function public.canjear_puntos_turno(bigint, numeric, uuid) to authenticated, service_role;


-- ----------------------------------------------------------------------------
-- 4 · APROBAR SOLICITUD · vencimiento en hora de Buenos Aires
-- ----------------------------------------------------------------------------

create or replace function public.solicitud_aprobar(p_id bigint)
returns bigint
language plpgsql
security definer
set search_path = public
as $i73_aprobar$
declare
    s         record;
    v_cliente bigint;
    v_turno   bigint;
    v_staff   uuid;
    v_hoy     date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
    v_ahora   time := (now() at time zone 'America/Argentina/Buenos_Aires')::time;
begin
    select * into s
      from public.solicitudes_reserva
     where id = p_id
     for update;

    if not found then
        raise exception 'solicitud_no_existe';
    end if;
    if not public.es_miembro(s.salon_id) then
        raise exception 'sin_permisos';
    end if;
    if s.estado <> 'pendiente' then
        raise exception 'solicitud_no_pendiente';
    end if;

    -- I73 · FIX: comparar contra fecha/hora de Buenos Aires, no UTC.
    if s.fecha < v_hoy
       or (s.fecha = v_hoy and s.hora < v_ahora) then
        raise exception 'solicitud_vencida';
    end if;

    if exists (
        select 1
          from public.turnos t
         where t.salon_id = s.salon_id
           and t.appointment_date = s.fecha
           and t.appointment_time = s.hora
           and t.status not in ('cancelled', 'cancelado')
    ) then
        raise exception 'horario_ocupado';
    end if;

    -- CRM: buscar por teléfono normalizado dentro del salón.
    select c.id into v_cliente
      from public.clientes c
     where c.salon_id = s.salon_id
       and regexp_replace(coalesce(c.telefono, ''), '\D', '', 'g') = s.cliente_telefono
     limit 1;

    v_staff := case
        when public.es_owner(s.salon_id) then null
        else auth.uid()
    end;

    if v_cliente is null then
        insert into public.clientes (salon_id, user_id, nombre, telefono, staff_user_id)
        values (s.salon_id, auth.uid(), s.cliente_nombre, s.cliente_telefono, v_staff)
        returning id into v_cliente;
    end if;

    insert into public.turnos
        (salon_id, user_id, cliente_id, servicio_id, client_name, service_type,
         appointment_date, appointment_time, price, notes, status, staff_user_id)
    values
        (s.salon_id, auth.uid(), v_cliente, s.servicio_id, s.cliente_nombre,
         coalesce(s.servicio_nombre, ''), s.fecha, s.hora,
         coalesce(s.servicio_precio, 0),
         'Solicitud online · ' || s.cliente_telefono, 'confirmed', v_staff)
    returning id into v_turno;

    update public.solicitudes_reserva
       set estado = 'aprobada',
           turno_id = v_turno,
           actualizado_en = now()
     where id = p_id;

    return v_turno;
end
$i73_aprobar$;

comment on function public.solicitud_aprobar(bigint) is
    'Aprueba una solicitud y crea el turno. I73: vencimiento calculado en America/Argentina/Buenos_Aires.';

revoke all on function public.solicitud_aprobar(bigint) from public, anon;
grant execute on function public.solicitud_aprobar(bigint) to authenticated, service_role;

notify pgrst, 'reload schema';

commit;
