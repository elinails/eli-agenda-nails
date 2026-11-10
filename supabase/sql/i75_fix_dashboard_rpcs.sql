-- Fix para RPCs del Dashboard (Errores 42804 y 42703)
-- Aplicado en la base viva para corregir tipos de datos y columnas inexistentes.

CREATE OR REPLACE FUNCTION public.admin_metricas()
 RETURNS TABLE(mrr numeric, arr numeric, churn_30d numeric, salones_activos_semana bigint, usuarios_online bigint, salones_nuevos_mes bigint, salones_total bigint, trials_por_vencer bigint, cancelados_30d bigint)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare
    v_total bigint;
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;

    select count(*) into v_total from public.salones;

    return query
    select
        coalesce((
            select sum(p.precio)
              from public.salones s
              join public.planes p on p.id = s.plan_id
             where s.activo and s.estado_suscripcion = 'active'
        ), 0),
        coalesce((
            select sum(p.precio) * 12
              from public.salones s
              join public.planes p on p.id = s.plan_id
             where s.activo and s.estado_suscripcion = 'active'
        ), 0),
        round(coalesce((
            100.0 * (select count(*) from public.salones s
                      where s.estado_suscripcion = 'cancelada'
                        and coalesce(s.cancelada_en, s.creado_en) >= now() - interval '30 days')
            / greatest(1, v_total)
        ), 0)::numeric, 2),
        (select count(distinct t.salon_id)
           from public.turnos t
          where t.appointment_date >= current_date - 7),
        (select count(*) from auth.users u
          where u.last_sign_in_at > now() - interval '15 minutes'),
        (select count(*) from public.salones s
          where s.creado_en >= date_trunc('month', now())),
        v_total,
        (select count(*) from public.salones s
          where s.estado_suscripcion = 'trial'
            and s.trial_hasta between now() and now() + interval '3 days'),
        (select count(*) from public.salones s
          where s.estado_suscripcion = 'cancelada'
            and coalesce(s.cancelada_en, s.creado_en) >= now() - interval '30 days');
end $function$;

CREATE OR REPLACE FUNCTION public.admin_top_salones(p_limite integer DEFAULT 5)
 RETURNS TABLE(salon_id uuid, nombre text, turnos_mes bigint, mrr numeric, estado text)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;

    return query
        select s.id,
               s.nombre,
               (select count(*) from public.turnos t
                 where t.salon_id = s.id
                   and t.created_at >= date_trunc('month', now())),
               coalesce((select p.precio from public.planes p where p.id = s.plan_id), 0),
               s.estado_suscripcion
          from public.salones s
         order by 3 desc, s.nombre asc
         limit greatest(1, least(coalesce(p_limite, 5), 20));
end $function$;

CREATE OR REPLACE FUNCTION public.admin_auditoria(p_limite integer DEFAULT 100, p_offset integer DEFAULT 0)
 RETURNS TABLE(id uuid, creado_en timestamp with time zone, admin_id uuid, admin_email text, salon_id uuid, salon_nombre text, accion text, detalle jsonb)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
begin
    if not public.es_super_admin() then
        raise exception 'sin_permisos';
    end if;

    return query
        select a.id,
               a.creado_en,
               a.admin_id,
               u.email::text,
               a.salon_id,
               s.nombre,
               a.accion,
               a.detalle
        from public.auditoria_admin a
        left join auth.users u on u.id = a.admin_id
        left join public.salones s on s.id = a.salon_id
        order by a.creado_en desc
        limit greatest(1, least(coalesce(p_limite, 100), 500))
        offset greatest(0, coalesce(p_offset, 0));
end;
$function$;
