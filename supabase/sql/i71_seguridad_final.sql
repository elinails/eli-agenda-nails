-- ============================================================================
-- ELI M. NAILS · I71 · SEGURIDAD FINAL (VERSIONADO)
--
-- Este archivo versiona en el repo los fixes de I71 que YA están aplicados en
-- la base viva y que hasta ahora solo existían ahí:
--
--   1) Guard de autorización en public.procesar_puntos_turno().
--   2) Gate Pro por PLAN EFECTIVO en public.public_crear_solicitud().
--   3) Gate Pro por PLAN EFECTIVO en public.public_salon_detalle().
--   4) Cierre de RPCs sensibles a anon (procesar/revertir/canjear/lecturas).
--
-- No cambia datos. Es idempotente. Se puede correr varias veces.
--
-- REQUISITOS: I68 (canje) + I69 (solicitudes) aplicados.
-- ORDEN:     I68 → I69 → este archivo → i73_fix_puntos.sql
--
-- USO:
--   supabase db query --linked -f supabase/sql/i71_seguridad_final.sql
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 0 · PRE-CHECK
-- ----------------------------------------------------------------------------

do $i71_pre$
begin
    if to_regprocedure('public._saas_plan_efectivo(uuid)') is null then
        raise exception 'I71: falta public._saas_plan_efectivo(uuid) (aplicar i55_saas.sql)';
    end if;
    if to_regclass('public.solicitudes_reserva') is null then
        raise exception 'I71: falta public.solicitudes_reserva (aplicar i69_solicitudes.sql)';
    end if;
    if to_regclass('public.billeteras_puntos') is null
       or to_regclass('public.movimientos_puntos') is null then
        raise exception 'I71: faltan las tablas de puntos (aplicar i62/i68)';
    end if;
end
$i71_pre$;


-- ----------------------------------------------------------------------------
-- 1 · PROCESAR PUNTOS · guard de autorización (código vivo I71)
-- ----------------------------------------------------------------------------

create or replace function public.procesar_puntos_turno(p_turno_id bigint)
returns table (otorgado boolean, puntos numeric, motivo text)
language plpgsql
security definer
set search_path = public
as $i71_procesar$
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
        return query select false, 0::numeric, 'turno_no_existe'::text; return;
    end if;

    -- I71 · GUARD
    if not (
           public.es_miembro(v_turno.salon_id)
        or public.es_super_admin()
        or coalesce(auth.jwt() ->> 'role', '') = 'service_role'
        or session_user in ('postgres', 'supabase_admin')
    ) then
        raise exception 'sin_permisos';
    end if;

    if lower(coalesce(v_turno.status, '')) <> all (c_tipos_realizado) then
        return query select false, 0::numeric, 'turno_no_realizado'::text; return;
    end if;

    select e.plan_efectivo into v_plan from public._saas_plan_efectivo(v_turno.salon_id) e;
    if coalesce(v_plan, 'gratis') not in ('pro', 'premium') then
        return query select false, 0::numeric, 'plan_no_habilitado'::text; return;
    end if;

    if v_turno.cliente_id is null then
        return query select false, 0::numeric, 'sin_clienta'::text; return;
    end if;

    v_puntos := public.puntos_por_turno(v_turno.price);
    if coalesce(v_puntos, 0) <= 0 then
        return query select false, 0::numeric, 'sin_puntos'::text; return;
    end if;

    select b.id into v_billetera from public.billeteras_puntos b
     where b.cliente_id = v_turno.cliente_id and b.salon_id = v_turno.salon_id limit 1;

    if v_billetera is null then
        insert into public.billeteras_puntos (cliente_id, salon_id, saldo_actual)
        values (v_turno.cliente_id, v_turno.salon_id, 0)
        on conflict (cliente_id, salon_id) do nothing
        returning id into v_billetera;

        if v_billetera is null then
            select b.id into v_billetera from public.billeteras_puntos b
             where b.cliente_id = v_turno.cliente_id and b.salon_id = v_turno.salon_id limit 1;
        end if;
    end if;

    if v_billetera is null then
        return query select false, 0::numeric, 'sin_billetera'::text; return;
    end if;

    select * into v_ganado from public.movimientos_puntos m
     where m.turno_id = p_turno_id and m.tipo = 'ganado' limit 1;

    if found then
        select * into v_reverso from public.movimientos_puntos m
         where m.turno_id = p_turno_id and m.tipo = 'reverso'
           and m.creado_en > v_ganado.creado_en
         order by m.creado_en desc limit 1;

        if not found then
            return query select false, v_ganado.monto, 'ya_otorgado'::text; return;
        end if;

        insert into public.movimientos_puntos (billetera_id, tipo, monto, motivo, turno_id)
        values (v_billetera, 'ajuste', v_ganado.monto,
                'Turno #' || p_turno_id || ' reabierto y vuelto a completar', p_turno_id);

        return query select true, v_ganado.monto, 'restituido'::text; return;
    end if;

    insert into public.movimientos_puntos (billetera_id, tipo, monto, motivo, turno_id)
    values (v_billetera, 'ganado', v_puntos,
            'Turno #' || p_turno_id || ' · ' || coalesce(v_turno.service_type, 'servicio'),
            p_turno_id);

    return query select true, v_puntos, 'otorgado'::text;
end
$i71_procesar$;

comment on function public.procesar_puntos_turno(bigint) is
    'Elima Points: acredita/restituye puntos de un turno realizado. I71: exige membresía, superadmin o service_role.';


-- ----------------------------------------------------------------------------
-- 2 · CREAR SOLICITUD · gate Pro por plan EFECTIVO (código vivo I71)
-- ----------------------------------------------------------------------------

create or replace function public.public_crear_solicitud(
    p_salon_id          uuid,
    p_cliente_nombre    text,
    p_cliente_telefono  text,
    p_fecha             date,
    p_hora              time,
    p_servicio_id       bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $i71_solicitud$
declare
    v_nombre   text := btrim(coalesce(p_cliente_nombre, ''));
    v_tel      text := regexp_replace(coalesce(p_cliente_telefono, ''), '\D', '', 'g');
    v_hoy      date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
    v_habilitado boolean;
    v_servicio record;
    v_cantidad integer;
    v_id       bigint;
begin
    if v_nombre = '' or char_length(v_nombre) > 80 then raise exception 'nombre_invalido'; end if;
    if char_length(v_tel) < 6 or char_length(v_tel) > 20 then raise exception 'telefono_invalido'; end if;
    if p_fecha is null then raise exception 'fecha_invalida'; end if;
    if p_hora  is null then raise exception 'hora_invalida';  end if;
    if p_fecha < v_hoy then raise exception 'fecha_invalida'; end if;

    -- I71 · GATE PRO por plan EFECTIVO: un salón vencido cae a 'gratis'
    --        y deja de recibir reservas aunque plan_id diga 'pro'.
    select coalesce((pl.caracteristicas ->> 'reservas_link')::boolean, false)
      into v_habilitado
      from public.salones s
      join public._saas_plan_efectivo(s.id) e on true
      left join public.planes pl on pl.id = e.plan_efectivo
     where s.id = p_salon_id
       and s.publicado is true
       and s.activo is true;

    if not found then raise exception 'salon_no_disponible'; end if;
    if not v_habilitado then raise exception 'reservas_no_habilitadas'; end if;

    select v.id, v.nombre, v.precio_base, v.duracion_minutos into v_servicio
      from public.servicios v
     where v.id = p_servicio_id and v.salon_id = p_salon_id;
    if not found then raise exception 'servicio_invalido'; end if;

    select count(*) into v_cantidad
      from public.solicitudes_reserva sr
     where sr.salon_id = p_salon_id and sr.cliente_telefono = v_tel
       and sr.fecha = p_fecha and sr.hora = p_hora and sr.estado = 'pendiente';
    if v_cantidad > 0 then raise exception 'solicitud_duplicada'; end if;

    select count(*) into v_cantidad
      from public.solicitudes_reserva sr
     where sr.salon_id = p_salon_id and sr.cliente_telefono = v_tel
       and sr.estado = 'pendiente'
       and sr.creado_en > now() - interval '24 hours';
    if v_cantidad >= 3 then raise exception 'demasiadas_solicitudes'; end if;

    insert into public.solicitudes_reserva
        (salon_id, cliente_nombre, cliente_telefono, fecha, hora,
         servicio_id, servicio_nombre, servicio_precio, servicio_duracion, estado)
    values
        (p_salon_id, v_nombre, v_tel, p_fecha, p_hora,
         v_servicio.id, v_servicio.nombre, v_servicio.precio_base, v_servicio.duracion_minutos, 'pendiente')
    returning id into v_id;

    return jsonb_build_object('id', v_id, 'estado', 'pendiente');
end
$i71_solicitud$;

comment on function public.public_crear_solicitud(uuid, text, text, date, time, bigint) is
    'Solicitud anónima: valida salón publicado/activo y gate reservas_link sobre el plan EFECTIVO.';


-- ----------------------------------------------------------------------------
-- 3 · DETALLE PÚBLICO · gate Pro por plan EFECTIVO (código vivo I71)
-- ----------------------------------------------------------------------------

create or replace function public.public_salon_detalle(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $i71_detalle$
    select jsonb_build_object(
        'id',             s.id,
        'salon_id',       s.id,
        'slug',           s.slug,
        'nombre',         s.nombre,
        'rubro',          s.rubro,
        'bio',            coalesce(s.bio, s.descripcion, ''),
        'logo_url',       s.logo_url,
        'foto_portada_url', s.foto_portada_url,
        'instagram',      s.instagram,
        'direccion',      s.direccion,
        -- I71 · gate sobre el plan EFECTIVO (trial/vencido), no el guardado
        'reservas_habilitadas', coalesce((pl.caracteristicas ->> 'reservas_link')::boolean, false),
        'servicios', coalesce((
            select jsonb_agg(jsonb_build_object(
                       'id', v.id, 'nombre', v.nombre,
                       'precio', v.precio_base, 'duracion', v.duracion_minutos
                   ) order by v.nombre)
              from public.servicios v
             where v.salon_id = s.id
        ), '[]'::jsonb)
    )
    from public.salones s
    join public._saas_plan_efectivo(s.id) e on true
    left join public.planes pl on pl.id = e.plan_efectivo
    where s.slug = lower(btrim(coalesce(p_slug, '')))
      and s.publicado is true
      and s.activo is true
    limit 1;
$i71_detalle$;

comment on function public.public_salon_detalle(text) is
    'Perfil público: solo datos públicos + gate reservas_link sobre el plan EFECTIVO.';


-- ----------------------------------------------------------------------------
-- 4 · ACLs · cerrar RPCs sensibles a anon (las públicas del marketplace siguen)
-- ----------------------------------------------------------------------------

revoke all on function public.procesar_puntos_turno(bigint) from public, anon;
grant execute on function public.procesar_puntos_turno(bigint) to authenticated, service_role;

revoke all on function public.revertir_puntos_turno(bigint) from public, anon;
grant execute on function public.revertir_puntos_turno(bigint) to authenticated, service_role;

revoke all on function public.canjear_puntos_turno(bigint, numeric, uuid) from public, anon;
grant execute on function public.canjear_puntos_turno(bigint, numeric, uuid) to authenticated, service_role;

revoke all on function public.obtener_mis_puntos() from public, anon;
grant execute on function public.obtener_mis_puntos() to authenticated, service_role;

revoke all on function public.saldo_puntos_cliente(bigint) from public, anon;
grant execute on function public.saldo_puntos_cliente(bigint) to authenticated, service_role;

revoke all on function public.vincular_mi_cuenta() from public, anon;
grant execute on function public.vincular_mi_cuenta() to authenticated, service_role;

revoke all on function public.solicitud_aprobar(bigint) from public, anon;
grant execute on function public.solicitud_aprobar(bigint) to authenticated, service_role;

revoke all on function public.solicitud_rechazar(bigint, text) from public, anon;
grant execute on function public.solicitud_rechazar(bigint, text) to authenticated, service_role;

revoke all on function public.aprobar_solicitud(bigint) from public, anon;
grant execute on function public.aprobar_solicitud(bigint) to authenticated, service_role;

revoke all on function public.rechazar_solicitud(bigint, text) from public, anon;
grant execute on function public.rechazar_solicitud(bigint, text) to authenticated, service_role;

-- RPCs públicas: el marketplace necesita anon.
grant execute on function public.public_crear_solicitud(uuid, text, text, date, time, bigint) to anon, authenticated, service_role;
grant execute on function public.public_salon_detalle(text) to anon, authenticated, service_role;
grant execute on function public.public_marketplace_salones(text, text) to anon, authenticated, service_role;

notify pgrst, 'reload schema';

commit;
