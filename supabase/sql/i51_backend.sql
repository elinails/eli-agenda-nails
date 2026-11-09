-- ============================================================================
-- ELI M. NAILS · I51 · Backend del God Mode V5
--
-- 1. salones: estado_suscripcion acepta 'cancelada' + columna cancelada_en
-- 2. admin_metricas()  · MRR, ARR, churn, actividad, trials
-- 3. admin_top_salones() · ranking del mes
-- 4. Auditoría automática de los cambios del SuperAdmin (triggers):
--      salones · planes · configuracion_global · anuncios_globales
-- 5. admin_auditoria(): email del admin con respaldo en super_admins
--
-- Idempotente.
-- ============================================================================


-- ============================================================================
-- 1 · ESTADOS DE SUSCRIPCIÓN
-- ============================================================================

alter table public.salones
    drop constraint if exists salones_estado_check;

alter table public.salones
    add constraint salones_estado_check
    check (estado_suscripcion = any (array['trial', 'active', 'past_due', 'cancelada']));

-- fecha en que se canceló (para churn real de 30 días)
alter table public.salones
    add column if not exists cancelada_en timestamptz;

create index if not exists salones_cancelada_idx
    on public.salones (cancelada_en)
    where cancelada_en is not null;


-- ============================================================================
-- 2 · MÉTRICAS DEL PANEL
-- ============================================================================

create or replace function public.admin_metricas()
returns table (
    mrr               numeric,
    arr               numeric,
    churn_30d         numeric,
    salones_activos_semana bigint,
    usuarios_online   bigint,
    salones_nuevos_mes bigint,
    salones_total     bigint,
    trials_por_vencer bigint,
    cancelados_30d    bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_total integer;
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;

    select count(*) into v_total from public.salones;

    return query
    select
        -- MRR: suma de los planes de los salones activos y al día
        coalesce((
            select sum(p.precio)
              from public.salones s
              join public.planes p on p.id = s.plan_id
             where s.activo and s.estado_suscripcion = 'active'
        ), 0),

        -- ARR = MRR * 12
        coalesce((
            select sum(p.precio) * 12
              from public.salones s
              join public.planes p on p.id = s.plan_id
             where s.activo and s.estado_suscripcion = 'active'
        ), 0),

        -- churn de 30 días: cancelados en el período / salones totales
        round(coalesce((
            100.0 * (select count(*) from public.salones s
                      where s.estado_suscripcion = 'cancelada'
                        and coalesce(s.cancelada_en, s.creado_en) >= now() - interval '30 days')
            / greatest(1, v_total)
        ), 0)::numeric, 2),

        -- salones con al menos un turno en los últimos 7 días
        (select count(distinct t.salon_id)
           from public.turnos t
          where t.appointment_date >= current_date - 7),

        -- "online": activos en los últimos 15 minutos
        (select count(*) from auth.users u
          where u.last_sign_in_at > now() - interval '15 minutes'),

        -- nuevos este mes
        (select count(*) from public.salones s
          where s.creado_en >= date_trunc('month', now())),

        v_total,

        -- trials que vencen en 3 días
        (select count(*) from public.salones s
          where s.estado_suscripcion = 'trial'
            and s.trial_hasta between now() and now() + interval '3 days'),

        -- cancelados en 30 días (para el texto del panel)
        (select count(*) from public.salones s
          where s.estado_suscripcion = 'cancelada'
            and coalesce(s.cancelada_en, s.creado_en) >= now() - interval '30 days');
end $$;
grant execute on function public.admin_metricas() to authenticated;


create or replace function public.admin_top_salones(p_limite integer default 5)
returns table (
    salon_id    uuid,
    nombre      text,
    turnos_mes  bigint,
    mrr         numeric,
    estado      text
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;

    return query
        select s.id,
               s.nombre,
               (select count(*) from public.turnos t
                 where t.salon_id = s.id
                   and t.creado_en >= date_trunc('month', now())),
               coalesce((select p.precio from public.planes p where p.id = s.plan_id), 0),
               s.estado_suscripcion
          from public.salones s
         order by 3 desc, s.nombre asc
         limit greatest(1, least(coalesce(p_limite, 5), 20));
end $$;
grant execute on function public.admin_top_salones(integer) to authenticated;


-- ============================================================================
-- 3 · AUDITORÍA AUTOMÁTICA DE ACCIONES DEL SUPERADMIN
--
-- Se hace con triggers porque el panel actual actualiza las tablas
-- directamente (salones.estado_suscripcion, planes, etc.). Un trigger
-- captura TODOS los caminos, incluidos los que todavía no existen.
-- Solo audita cuando quien cambia es un SuperAdmin.
-- ============================================================================

create or replace function public.auditar_cambio_admin()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_es_admin boolean;
    v_viejo    jsonb := '{}'::jsonb;
    v_nuevo    jsonb := '{}'::jsonb;
    v_salon    uuid;
    v_accion   text;
    v_detalle  jsonb;
    v_headers  jsonb;
begin
    select exists (select 1 from public.super_admins sa where sa.user_id = auth.uid())
      into v_es_admin;

    if not coalesce(v_es_admin, false) then
        return coalesce(NEW, OLD);
    end if;

    -- se leen las filas como jsonb: evita tocar NEW/OLD en operaciones donde no existen
    if TG_OP in ('UPDATE', 'DELETE') then v_viejo := to_jsonb(OLD); end if;
    if TG_OP in ('INSERT', 'UPDATE') then v_nuevo := to_jsonb(NEW); end if;

    if TG_TABLE_NAME = 'salones' then
        v_salon := coalesce((v_nuevo->>'id')::uuid, (v_viejo->>'id')::uuid);
        v_accion := case
            when TG_OP = 'INSERT' then 'salon_alta'
            when (v_nuevo->>'estado_suscripcion') is distinct from (v_viejo->>'estado_suscripcion')
                 and (v_nuevo->>'estado_suscripcion') = 'cancelada' then 'salon_cancelado'
            when (v_nuevo->>'estado_suscripcion') is distinct from (v_viejo->>'estado_suscripcion') then 'plan_estado'
            when (v_nuevo->>'plan_id') is distinct from (v_viejo->>'plan_id') then 'plan_cambio'
            when (v_nuevo->>'activo') is distinct from (v_viejo->>'activo')
                 then case when (v_nuevo->>'activo')::boolean then 'salon_activado' else 'salon_suspendido' end
            else 'salon_editado'
        end;
        v_detalle := jsonb_build_object(
            'salon', coalesce(v_nuevo->>'nombre', v_viejo->>'nombre'),
            'plan_anterior', v_viejo->>'plan_id',
            'plan_nuevo', v_nuevo->>'plan_id',
            'estado_anterior', v_viejo->>'estado_suscripcion',
            'estado_nuevo', v_nuevo->>'estado_suscripcion',
            'activo_anterior', v_viejo->>'activo',
            'activo_nuevo', v_nuevo->>'activo'
        );
    elsif TG_TABLE_NAME = 'planes' then
        v_accion := case when TG_OP = 'INSERT' then 'plan_alta' else 'plan_editado' end;
        v_detalle := jsonb_build_object(
            'plan', coalesce(v_nuevo->>'id', v_viejo->>'id'),
            'nombre', coalesce(v_nuevo->>'nombre', v_viejo->>'nombre'),
            'precio_anterior', v_viejo->>'precio',
            'precio_nuevo', v_nuevo->>'precio',
            'limite_nuevo', v_nuevo->>'limite_empleadas'
        );
    elsif TG_TABLE_NAME = 'configuracion_global' then
        v_accion := 'flag_cambiado';
        v_detalle := jsonb_build_object(
            'clave', coalesce(v_nuevo->>'clave', v_viejo->>'clave'),
            'valor_anterior', v_viejo->>'valor_boolean',
            'valor_nuevo', v_nuevo->>'valor_boolean'
        );
    elsif TG_TABLE_NAME = 'anuncios_globales' then
        v_accion := case
            when TG_OP = 'INSERT' then 'anuncio_publicado'
            when TG_OP = 'DELETE' then 'anuncio_borrado'
            else 'anuncio_editado'
        end;
        v_detalle := jsonb_build_object(
            'mensaje', left(coalesce(v_nuevo->>'mensaje', v_viejo->>'mensaje'), 140),
            'tipo', coalesce(v_nuevo->>'tipo', v_viejo->>'tipo'),
            'activo', v_nuevo->>'activo'
        );
    else
        v_accion := lower(TG_TABLE_NAME) || '_cambio';
        v_detalle := '{}'::jsonb;
    end if;

    begin
        v_headers := nullif(current_setting('request.headers', true), '')::jsonb;
    exception when others then
        v_headers := null;
    end;

    if v_accion in ('salon_editado') then
        return coalesce(NEW, OLD);
    end if;

    insert into public.auditoria_admin (admin_id, salon_id, accion, detalle, ip, user_agent)
    values (
        auth.uid(),
        v_salon,
        v_accion,
        v_detalle,
        v_headers ->> 'x-forwarded-for',
        left(coalesce(v_headers ->> 'user-agent', ''), 300)
    );

    return coalesce(NEW, OLD);
end $$;

drop trigger if exists trg_auditar_salones on public.salones;
create trigger trg_auditar_salones
after insert or update on public.salones
for each row execute function public.auditar_cambio_admin();

drop trigger if exists trg_auditar_planes on public.planes;
create trigger trg_auditar_planes
after insert or update on public.planes
for each row execute function public.auditar_cambio_admin();

drop trigger if exists trg_auditar_flags on public.configuracion_global;
create trigger trg_auditar_flags
after insert or update on public.configuracion_global
for each row execute function public.auditar_cambio_admin();

drop trigger if exists trg_auditar_anuncios on public.anuncios_globales;
create trigger trg_auditar_anuncios
after insert or update or delete on public.anuncios_globales
for each row execute function public.auditar_cambio_admin();


-- ============================================================================
-- 4 · admin_auditoria(): email del admin con respaldo
--
-- NOTA: la versión actual ya resuelve el email con `auth.users`, que es la
-- fuente autoritativa. Se mantiene y se agrega `super_admins` como respaldo
-- por si el usuario fue borrado de Auth.
-- ============================================================================

create or replace function public.admin_auditoria(p_limite integer default 100, p_offset integer default 0)
returns table (
    id uuid,
    creado_en timestamptz,
    admin_id uuid,
    admin_email text,
    salon_id uuid,
    salon_nombre text,
    accion text,
    detalle jsonb
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;

    return query
        select a.id,
               a.creado_en,
               a.admin_id,
               coalesce(u.email::text, sa.email) as admin_email,
               a.salon_id,
               s.nombre as salon_nombre,
               a.accion,
               a.detalle
          from public.auditoria_admin a
          left join auth.users u          on u.id = a.admin_id
          left join public.super_admins sa on sa.user_id = a.admin_id
          left join public.salones s      on s.id = a.salon_id
         order by a.creado_en desc
         limit greatest(1, least(coalesce(p_limite, 100), 500))
        offset greatest(0, coalesce(p_offset, 0));
end $$;
grant execute on function public.admin_auditoria(integer, integer) to authenticated;


notify pgrst, 'reload schema';

-- ============================================================================
-- VERIFICACIÓN
-- ============================================================================
-- select * from public.admin_metricas();
-- select * from public.admin_top_salones(5);
-- select accion, count(*) from public.auditoria_admin group by 1 order by 2 desc;
