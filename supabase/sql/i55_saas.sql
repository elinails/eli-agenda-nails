-- ============================================================================
-- ELI M. NAILS · I55 · SaaS: vigencia, plan efectivo y vencimientos
--
-- Qué resuelve:
--   La base ya tiene los datos (salones.estado_suscripcion, salones.trial_hasta,
--   salones.plan_id, tabla suscripciones y tabla planes) pero NADIE calculaba
--   el plan que corresponde HOY. Un salón con trial vencido seguía viendo el
--   plan Pro. Esta migración agrega la capa de lectura (plan efectivo) y una
--   RPC explícita para que un admin aplique las degradaciones.
--
-- Qué NO hace (a propósito):
--   · No cobra nada, no habla con MercadoPago.
--   · No modifica datos por sí sola: las funciones de lectura son `stable`.
--     La única escritura ocurre cuando un super admin llama
--     admin_saas_vencimientos(true).
--   · No cambia el CHECK de salones.estado_suscripcion (trial/active/past_due).
--     Un trial vencido queda con estado 'trial' y plan 'gratis': el estado
--     cuenta la historia, el plan efectivo cuenta el presente.
--
-- Reglas de vigencia (documentadas para que no haya sorpresas):
--   1. salón inactivo                        → plan gratis, estado 'suspendido'
--   2. estado 'active' + pago vigente        → plan guardado
--   3. estado 'active'/'past_due' + venció   → gracia de 3 días con el plan
--   4. pasado el margen de gracia            → plan gratis, estado 'vencido'
--   5. estado 'trial' + trial_hasta futuro   → plan guardado, estado 'trial'
--   6. trial vencido                         → plan gratis, estado 'trial_vencido'
--
-- Depende de: public.salones, public.suscripciones (I48), public.planes (I49),
--             public.miembros_salon, public.es_super_admin() (I48).
-- Idempotente: se puede correr varias veces.
-- ============================================================================


-- ============================================================================
-- 1 · ÍNDICES para el proceso diario
-- ============================================================================

create index if not exists salones_vigencia_idx
    on public.salones (estado_suscripcion, trial_hasta);

create index if not exists suscripciones_vence_idx
    on public.suscripciones (vence_en);


-- ============================================================================
-- 1.1 · LIMPIEZA (idempotencia)
--
-- Se borran en orden inverso de dependencia: primero las RPCs públicas y de
-- admin, último el cálculo interno. Si se borrara el interno primero, Postgres
-- rechazaría el DROP por las funciones que lo referencian.
-- ============================================================================

drop function if exists public.admin_saas_por_vencer(integer);
drop function if exists public.admin_saas_vencimientos(boolean);
drop function if exists public.admin_saas_plan(uuid);
drop function if exists public.mi_plan_efectivo();
drop function if exists public._saas_plan_efectivo(uuid);


-- ============================================================================
-- 2 · NORMALIZACIÓN DE NOMBRES DE PLAN
--
-- La tabla suscripciones (I48) usa 'basico' por defecto, mientras que planes
-- (I49) usa 'gratis'. No se reescriben filas: se traduce al leer.
-- ============================================================================

create or replace function public.saas_normalizar_plan(p_plan text)
returns text
language sql
immutable
set search_path = public
as $$
    select case lower(btrim(coalesce(p_plan, '')))
        when 'gratis'  then 'gratis'
        when 'free'    then 'gratis'
        when 'basico'  then 'gratis'
        when 'básico'  then 'gratis'
        when 'pro'     then 'pro'
        when 'premium' then 'premium'
        else 'gratis'
    end;
$$;

revoke all on function public.saas_normalizar_plan(text) from public, anon;


-- ============================================================================
-- 3 · PLAN EFECTIVO (INTERNO)
--
-- Recibe un salón y devuelve el plan que le corresponde ahora.
-- NO se expone: sin grant, nadie puede pedir el plan de un salón ajeno
-- (sería un IDOR trivial). Se usa desde las RPCs de abajo.
-- ============================================================================

create or replace function public._saas_plan_efectivo(p_salon uuid)
returns table (
    salon_id          uuid,
    plan_efectivo     text,
    estado            text,
    motivo            text,
    dias_restantes    integer,
    trial_hasta       timestamptz,
    vence_en          date,
    precio            numeric,
    limite_empleadas  integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    -- Margen de cortesía tras un pago vencido o un trial que expiró.
    c_gracia constant integer := 3;

    v_fila      public.salones%rowtype;
    v_su        public.suscripciones%rowtype;
    v_hay_su    boolean := false;
    v_su_anulada boolean := false;
    v_plan      text := 'gratis';
    v_plan_base text := 'gratis';
    v_estado    text := 'sin_datos';
    v_motivo    text := 'sin_datos';
    v_dias      integer := null;
    v_trial     timestamptz := null;
    v_vence     date := null;
    v_precio    numeric := 0;
    v_limite    integer := null;
begin
    select * into v_fila from public.salones s where s.id = p_salon;
    if not found then
        raise exception 'salon_no_existe';
    end if;

    select * into v_su from public.suscripciones su where su.salon_id = p_salon;
    v_hay_su := found;
    if v_hay_su then
        v_vence := v_su.vence_en;
        -- 'activa' es el único estado que habilita el acceso en esa tabla.
        v_su_anulada := lower(coalesce(v_su.estado, 'activa')) <> 'activa';
    end if;
    v_trial := v_fila.trial_hasta;

    -- ¿De dónde sale el plan guardado?
    -- admin_set_suscripcion() (I48) escribe el plan en la tabla suscripciones,
    -- mientras que el resto de la app lee salones.plan_id. Para que cambiar el
    -- plan en el panel de admin tenga efecto de verdad, manda suscripciones
    -- cuando define un plan real. 'basico' es el default legacy de I48 y no
    -- significa nada: en ese caso se usa salones.plan_id.
    if v_hay_su and lower(btrim(coalesce(v_su.plan, ''))) in ('pro', 'premium', 'gratis', 'free') then
        v_plan_base := public.saas_normalizar_plan(v_su.plan);
    else
        v_plan_base := public.saas_normalizar_plan(v_fila.plan_id);
    end if;

    if coalesce(v_fila.activo, true) = false then
        -- Salón suspendido por el super admin: sin acceso, sin importar el plan.
        v_plan := 'gratis';
        v_estado := 'suspendido';
        v_motivo := 'salon_suspendido';

    elsif v_fila.estado_suscripcion = 'active' then
        if not v_su_anulada and (v_vence is null or v_vence >= current_date) then
            v_plan := v_plan_base;
            v_estado := 'active';
            v_motivo := 'pago_vigente';
            if v_vence is not null then v_dias := v_vence - current_date; end if;
        elsif not v_su_anulada and v_vence is not null and current_date <= v_vence + c_gracia then
            v_plan := v_plan_base;
            v_estado := 'gracia';
            v_motivo := 'pago_vencido_gracia';
            v_dias := (v_vence + c_gracia) - current_date;
        else
            v_plan := 'gratis';
            v_estado := 'vencido';
            v_motivo := 'pago_vencido';
        end if;

    elsif v_fila.estado_suscripcion = 'past_due' then
        if not v_su_anulada and v_vence is not null and current_date <= v_vence + c_gracia then
            v_plan := v_plan_base;
            v_estado := 'gracia';
            v_motivo := 'pago_pendiente';
            v_dias := (v_vence + c_gracia) - current_date;
        else
            v_plan := 'gratis';
            v_estado := 'vencido';
            v_motivo := 'pago_pendiente_vencido';
        end if;

    else
        -- 'trial' (o cualquier valor inesperado: se trata como trial).
        if v_trial is not null and v_trial > now() then
            v_plan := v_plan_base;
            v_estado := 'trial';
            v_motivo := 'trial_vigente';
            v_dias := ceil(extract(epoch from (v_trial - now())) / 86400.0)::integer;
            if v_dias < 0 then v_dias := 0; end if;
        else
            v_plan := 'gratis';
            v_estado := 'trial_vencido';
            v_motivo := 'trial_vencido';
            v_dias := 0;
        end if;
    end if;

    -- Datos comerciales del plan efectivo (precio y tope de empleadas).
    select p.precio, p.limite_empleadas
      into v_precio, v_limite
      from public.planes p
     where p.id = v_plan;

    if not found then
        -- El plan no existe en la tabla planes: se degrada a gratis.
        v_plan := 'gratis';
        select p.precio, p.limite_empleadas
          into v_precio, v_limite
          from public.planes p
         where p.id = 'gratis';
    end if;

    return query
        select p_salon, v_plan, v_estado, v_motivo, v_dias, v_trial, v_vence,
               coalesce(v_precio, 0), v_limite;
end;
$$;

-- Nadie de afuera puede invocarlo: solo las RPCs de abajo (mismo owner).
revoke all on function public._saas_plan_efectivo(uuid) from public, anon, authenticated;


-- ============================================================================
-- 4 · RPC DE LA APP · mi_plan_efectivo()
--
-- Sin parámetros: resuelve el salón del que llama. No hay forma de pedir el
-- plan de otro salón. Si no hay sesión o no hay membresía, devuelve 0 filas.
-- ============================================================================

create or replace function public.mi_plan_efectivo()
returns table (
    salon_id          uuid,
    plan_efectivo     text,
    estado            text,
    motivo            text,
    dias_restantes    integer,
    trial_hasta       timestamptz,
    vence_en          date,
    precio            numeric,
    limite_empleadas  integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_salon uuid;
begin
    if auth.uid() is null then
        return;   -- conjunto vacío: sin sesión no hay plan
    end if;

    -- Misma prioridad que usa la app: owner activa primero, después la más vieja.
    select m.salon_id
      into v_salon
      from public.miembros_salon m
     where m.user_id = auth.uid()
       and coalesce(m.activo, true)
     order by (m.rol = 'owner') desc, m.creado_en asc
     limit 1;

    if v_salon is null then
        return;
    end if;

    return query select * from public._saas_plan_efectivo(v_salon);
end;
$$;

grant execute on function public.mi_plan_efectivo() to authenticated;


-- ============================================================================
-- 5 · RPCS DE ADMIN
-- ============================================================================

create or replace function public.admin_saas_plan(p_salon uuid)
returns table (
    salon_id          uuid,
    plan_efectivo     text,
    estado            text,
    motivo            text,
    dias_restantes    integer,
    trial_hasta       timestamptz,
    vence_en          date,
    precio            numeric,
    limite_empleadas  integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    if not public.es_super_admin() then
        raise exception 'sin_permisos';
    end if;
    return query select * from public._saas_plan_efectivo(p_salon);
end;
$$;

grant execute on function public.admin_saas_plan(uuid) to authenticated;


-- ── Vencimientos: lista (y opcionalmente aplica) las degradaciones ─────────
-- p_aplicar = false → solo informa (dry run, ideal para revisar antes).
-- p_aplicar = true  → baja el plan_id a 'gratis' de los salones vencidos.
-- El trigger trg_auditar_salones (I51) registra el cambio automáticamente.

create or replace function public.admin_saas_vencimientos(p_aplicar boolean default false)
returns table (
    salon_id        uuid,
    nombre          text,
    plan_guardado   text,
    plan_efectivo   text,
    estado          text,
    motivo          text,
    dias_restantes  integer
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_reg   record;
    v_ids   uuid[] := '{}';
begin
    if not public.es_super_admin() then
        raise exception 'sin_permisos';
    end if;

    -- Solo degradaciones: nunca se sube un plan automáticamente.
    for v_reg in
        select s.id, s.nombre, s.plan_id, e.plan_efectivo, e.estado, e.motivo, e.dias_restantes
          from public.salones s
          cross join lateral public._saas_plan_efectivo(s.id) e
         where e.plan_efectivo = 'gratis'
           and s.plan_id <> 'gratis'
         order by s.nombre
    loop
        v_ids := array_append(v_ids, v_reg.id);

        salon_id       := v_reg.id;
        nombre         := v_reg.nombre;
        plan_guardado  := v_reg.plan_id;
        plan_efectivo  := v_reg.plan_efectivo;
        estado         := v_reg.estado;
        motivo         := v_reg.motivo;
        dias_restantes := v_reg.dias_restantes;
        return next;
    end loop;

    if coalesce(p_aplicar, false) and array_length(v_ids, 1) > 0 then
        update public.salones
           set plan_id = 'gratis'
         where id = any(v_ids)
           and plan_id <> 'gratis';
    end if;
end;
$$;

grant execute on function public.admin_saas_vencimientos(boolean) to authenticated;


-- ── Por vencer: quiénes necesitan un recordatorio en los próximos N días ───

create or replace function public.admin_saas_por_vencer(p_dias integer default 7)
returns table (
    salon_id        uuid,
    nombre          text,
    plan_efectivo   text,
    estado          text,
    trial_hasta     timestamptz,
    vence_en        date,
    dias_restantes  integer
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    if not public.es_super_admin() then
        raise exception 'sin_permisos';
    end if;

    return query
        select s.id, s.nombre, e.plan_efectivo, e.estado,
               e.trial_hasta, e.vence_en, e.dias_restantes
          from public.salones s
          cross join lateral public._saas_plan_efectivo(s.id) e
         where e.dias_restantes is not null
           and e.dias_restantes >= 0
           and e.dias_restantes <= greatest(coalesce(p_dias, 7), 0)
         order by e.dias_restantes asc, s.nombre;
end;
$$;

grant execute on function public.admin_saas_por_vencer(integer) to authenticated;


-- ============================================================================
-- 6 · NOTIFICAR A POSTGREST
-- ============================================================================

notify pgrst, 'reload schema';


-- ============================================================================
-- VERIFICACIÓN (correr a mano después de aplicar)
-- ============================================================================
-- 1) Funciones creadas y con los grants correctos:
--    select p.proname, pg_get_userbyid(p.proowner) as owner,
--           has_function_privilege('authenticated', p.oid, 'execute') as auth_ok,
--           has_function_privilege('anon', p.oid, 'execute') as anon_ok
--      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--     where n.nspname = 'public'
--       and p.proname in ('_saas_plan_efectivo','mi_plan_efectivo',
--                         'admin_saas_plan','admin_saas_vencimientos',
--                         'admin_saas_por_vencer','saas_normalizar_plan')
--     order by p.proname;
--    Esperado: _saas_plan_efectivo y saas_normalizar_plan con auth_ok=false.
--
-- 2) Como usuario logueado (no admin): el plan propio
--    select * from public.mi_plan_efectivo();
--
-- 3) Como super admin: qué se degradaría (sin tocar nada)
--    select * from public.admin_saas_vencimientos(false);
--
-- 4) Aplicar de verdad
--    select * from public.admin_saas_vencimientos(true);
--    -- y confirmar la auditoría:
--    select accion, salon_id, detalle, creado_en
--      from public.auditoria_admin order by creado_en desc limit 5;
--
-- 5) Recordatorios
--    select * from public.admin_saas_por_vencer(7);
--
-- 6) Un no-admin NO puede degradar (debe lanzar 'sin_permisos'):
--    select * from public.admin_saas_vencimientos(true);
