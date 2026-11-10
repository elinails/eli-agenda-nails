-- ============================================================================
-- ELI M. NAILS · I66 · God Mode V3 (Fase 1): inteligencia, soporte y control
--
-- Contenido:
--   1) tickets ........... CRM de soporte (tabla + RPCs de admin)
--   2) admin_metricas_saas churn del mes, LTV, health score y adopción
--   3) app_flags + cache  "Limpiar caché global" (modelo pull con epoch)
--
-- Seguridad:
--   · tickets y app_flags: RLS activo y SIN políticas → nadie lee ni escribe
--     directo; todo pasa por RPCs security definer que validan es_super_admin().
--   · La única función pública es cache_epoch_actual(): devuelve un entero
--     sin datos sensibles, para que cualquier cliente detecte la purga.
--   · No se toca ninguna tabla existente ni admin_metricas().
--
-- Idempotente: se puede correr varias veces.
-- ============================================================================


-- ============================================================================
-- 1 · TICKETS DE SOPORTE
-- ============================================================================

create table if not exists public.tickets (
    id             bigint generated always as identity primary key,
    salon_id       uuid references public.salones(id) on delete set null,
    asunto         text not null,
    mensaje        text,
    estado         text not null default 'abierto',
    prioridad      text not null default 'media',
    creado_por     uuid default auth.uid(),
    creado_en      timestamptz not null default now(),
    actualizado_en timestamptz not null default now()
);

alter table public.tickets
    drop constraint if exists tickets_asunto_check;
alter table public.tickets
    add constraint tickets_asunto_check
    check (char_length(btrim(asunto)) between 3 and 120);

alter table public.tickets
    drop constraint if exists tickets_mensaje_check;
alter table public.tickets
    add constraint tickets_mensaje_check
    check (mensaje is null or char_length(mensaje) <= 2000);

alter table public.tickets
    drop constraint if exists tickets_estado_check;
alter table public.tickets
    add constraint tickets_estado_check
    check (estado in ('abierto', 'en_proceso', 'cerrado'));

alter table public.tickets
    drop constraint if exists tickets_prioridad_check;
alter table public.tickets
    add constraint tickets_prioridad_check
    check (prioridad in ('baja', 'media', 'alta'));

create index if not exists tickets_estado_idx
    on public.tickets (estado, creado_en desc);

create index if not exists tickets_salon_idx
    on public.tickets (salon_id, creado_en desc);

-- Sin políticas: el acceso es exclusivamente por las RPCs de abajo.
alter table public.tickets enable row level security;


-- Lista de tickets (con nombre del salón y email de quien lo creó).
create or replace function public.admin_tickets(p_estado text default null)
returns table (
    id              bigint,
    salon_id        uuid,
    salon_nombre    text,
    asunto          text,
    mensaje         text,
    estado          text,
    prioridad       text,
    creado_por      uuid,
    creado_por_email text,
    creado_en       timestamptz,
    actualizado_en  timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    return query
        select t.id, t.salon_id, s.nombre, t.asunto, t.mensaje, t.estado, t.prioridad,
               t.creado_por,
               (select u.email::text from auth.users u where u.id = t.creado_por),
               t.creado_en, t.actualizado_en
          from public.tickets t
          left join public.salones s on s.id = t.salon_id
         where p_estado is null or t.estado = p_estado
         order by
           case t.prioridad when 'alta' then 0 when 'media' then 1 else 2 end,
           t.creado_en desc;
end $$;

grant execute on function public.admin_tickets(text) to authenticated;


-- Contador para el badge del sidebar.
create or replace function public.admin_tickets_abiertos()
returns bigint
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    return (select count(*) from public.tickets where estado = 'abierto');
end $$;

grant execute on function public.admin_tickets_abiertos() to authenticated;


create or replace function public.admin_ticket_crear(
    p_asunto    text,
    p_mensaje   text default null,
    p_salon     uuid default null,
    p_prioridad text default 'media'
)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id       bigint;
    v_asunto   text := btrim(coalesce(p_asunto, ''));
    v_mensaje  text := nullif(btrim(coalesce(p_mensaje, '')), '');
    v_prior    text := lower(btrim(coalesce(p_prioridad, 'media')));
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    if char_length(v_asunto) < 3 then raise exception 'asunto_corto'; end if;
    if v_prior not in ('baja', 'media', 'alta') then v_prior := 'media'; end if;
    if p_salon is not null and not exists (select 1 from public.salones s where s.id = p_salon) then
        raise exception 'salon_no_existe';
    end if;

    insert into public.tickets (salon_id, asunto, mensaje, prioridad, estado, creado_por)
    values (p_salon, left(v_asunto, 120), v_mensaje, v_prior, 'abierto', auth.uid())
    returning id into v_id;

    return v_id;
end $$;

grant execute on function public.admin_ticket_crear(text, text, uuid, text) to authenticated;


create or replace function public.admin_ticket_estado(p_id bigint, p_estado text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    v_estado text := lower(btrim(coalesce(p_estado, '')));
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    if v_estado not in ('abierto', 'en_proceso', 'cerrado') then raise exception 'estado_invalido'; end if;
    update public.tickets
       set estado = v_estado, actualizado_en = now()
     where id = p_id;
    if not found then raise exception 'no_existe'; end if;
end $$;

grant execute on function public.admin_ticket_estado(bigint, text) to authenticated;


create or replace function public.admin_ticket_borrar(p_id bigint)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    delete from public.tickets where id = p_id;
end $$;

grant execute on function public.admin_ticket_borrar(bigint) to authenticated;


-- Auditoría: auditar_cambio_admin() ya registra cualquier tabla con un else
-- genérico, así que el trigger deja historial de los cambios de tickets.
drop trigger if exists trg_auditar_tickets on public.tickets;
create trigger trg_auditar_tickets
after insert or update or delete on public.tickets
for each row execute function public.auditar_cambio_admin();


-- ============================================================================
-- 2 · MÉTRICAS SaaS (churn del mes, LTV, health score, adopción)
--
-- Fórmulas:
--   churn_mes = cancelados del mes / (activos al inicio del mes + cancelados) × 100
--   arpu      = MRR de planes pagos / salones pagos activos
--   ltv       = arpu × vida media (1 / churn mensual), acotada a 12–36 meses
--   health    = 🔴 pago sin turnos en 15 días · 🟡 sin turnos 8–15 · 🟢 activo
-- ============================================================================

create or replace function public.admin_metricas_saas()
returns table (
    churn_mes        numeric,
    arpu             numeric,
    ltv              numeric,
    salones_total    bigint,
    salones_pagos    bigint,
    cancelados_mes   bigint,
    health_rojo      bigint,
    health_amarillo  bigint,
    health_verde     bigint,
    en_riesgo        jsonb,
    adopcion         jsonb
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_total       bigint := 0;
    v_pagos       bigint := 0;
    v_mrr         numeric := 0;
    v_cancel_mes  bigint := 0;
    v_activos_ini bigint := 0;
    v_churn       numeric := 0;
    v_arpu        numeric := 0;
    v_ltv         numeric := 0;
    v_rojo        bigint := 0;
    v_amarillo    bigint := 0;
    v_verde       bigint := 0;
    v_riesgo      jsonb := '[]'::jsonb;
    v_adopcion    jsonb := '{}'::jsonb;
    v_puntos      bigint := null;
    v_inicio_mes  timestamptz := date_trunc('month', now());
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;

    select count(*) into v_total from public.salones;

    -- Salones que pagan (plan distinto de gratis y activos).
    select count(*) into v_pagos
      from public.salones s
     where s.activo and s.estado_suscripcion = 'active' and s.plan_id <> 'gratis';

    select coalesce(sum(p.precio), 0) into v_mrr
      from public.salones s
      join public.planes p on p.id = s.plan_id
     where s.activo and s.estado_suscripcion = 'active' and s.plan_id <> 'gratis';

    -- Cancelados este mes.
    select count(*) into v_cancel_mes
      from public.salones s
     where s.estado_suscripcion = 'cancelada'
       and coalesce(s.cancelada_en, s.creado_en) >= v_inicio_mes;

    -- Base para el churn: existían al empezar el mes y no estaban cancelados.
    select count(*) into v_activos_ini
      from public.salones s
     where s.creado_en < v_inicio_mes
       and not (s.estado_suscripcion = 'cancelada'
                and coalesce(s.cancelada_en, s.creado_en) < v_inicio_mes);

    v_arpu := case when v_pagos > 0 then round(v_mrr / v_pagos, 2) else 0 end;

    v_churn := case
        when (v_activos_ini + v_cancel_mes) > 0
            then round(100.0 * v_cancel_mes / (v_activos_ini + v_cancel_mes), 2)
        else 0
    end;

    v_ltv := case
        when v_arpu = 0 then 0
        when v_churn = 0 then round(v_arpu * 36, 2)          -- sin churn: techo de 36 meses
        else round(v_arpu * least(36, greatest(12, 100.0 / v_churn)), 2)
    end;

    -- Health score por salón (solo salones activos).
    with ultimo as (
        select s.id, s.nombre, s.plan_id, s.estado_suscripcion,
               (select max(t.appointment_date) from public.turnos t where t.salon_id = s.id) as ultimo_turno
          from public.salones s
         where s.activo
    ), clasificado as (
        select u.*,
               case
                 when u.estado_suscripcion = 'active' and u.plan_id <> 'gratis'
                      and (u.ultimo_turno is null or u.ultimo_turno < current_date - 15) then 'rojo'
                 when u.ultimo_turno is null or u.ultimo_turno < current_date - 8 then 'amarillo'
                 else 'verde'
               end as salud
          from ultimo u
    )
    select
        coalesce(count(*) filter (where salud = 'rojo'), 0),
        coalesce(count(*) filter (where salud = 'amarillo'), 0),
        coalesce(count(*) filter (where salud = 'verde'), 0)
      into v_rojo, v_amarillo, v_verde
      from clasificado;

    -- Top 5 en riesgo, para la tarjeta de Inicio.
    with ultimo as (
        select s.id, s.nombre, s.plan_id, s.estado_suscripcion,
               (select max(t.appointment_date) from public.turnos t where t.salon_id = s.id) as ultimo_turno
          from public.salones s
         where s.activo
    )
    select coalesce(jsonb_agg(fila), '[]'::jsonb) into v_riesgo
      from (
        select jsonb_build_object(
                   'id', u.id,
                   'nombre', u.nombre,
                   'plan', u.plan_id,
                   'ultimo_turno', u.ultimo_turno,
                   'dias_sin_turnos',
                       case when u.ultimo_turno is null then null
                            else (current_date - u.ultimo_turno) end
               ) as fila
          from ultimo u
         where u.estado_suscripcion = 'active'
           and u.plan_id <> 'gratis'
           and (u.ultimo_turno is null or u.ultimo_turno < current_date - 15)
         order by u.ultimo_turno asc nulls first
         limit 5
      ) x;

    -- Adopción de funciones (% sobre salones activos).
    v_adopcion := jsonb_build_object(
        'agenda',      (select count(distinct t.salon_id) from public.turnos t),
        'finanzas',    (select count(distinct g.salon_id) from public.gastos g),
        'resenas',     (select count(distinct r.salon_id) from public.resenas r),
        'marketplace', (select count(*) from public.salones s where s.activo and s.publicado is true),
        'perfil',      (select count(*) from public.salones s
                         where s.activo and (s.foto_portada_url is not null or s.slug is not null)),
        'equipo',      (select count(*) from (
                            select m.salon_id from public.miembros_salon m
                             where coalesce(m.activo, true)
                             group by m.salon_id having count(*) > 1
                        ) e)
    );

    -- Puntos: la tabla puede no estar aplicada todavía (I66 en curso).
    if to_regclass('public.puntos') is not null then
        begin
            execute 'select count(distinct salon_id) from public.puntos' into v_puntos;
        exception when others then
            v_puntos := null;
        end;
    end if;
    v_adopcion := v_adopcion || jsonb_build_object('puntos', v_puntos);

    v_adopcion := v_adopcion || jsonb_build_object(
        'total_salones', v_total,
        'activos', (select count(*) from public.salones s where s.activo)
    );

    return query select v_churn, v_arpu, v_ltv, v_total, v_pagos, v_cancel_mes,
                        v_rojo, v_amarillo, v_verde, v_riesgo, v_adopcion;
end $$;

grant execute on function public.admin_metricas_saas() to authenticated;


-- ============================================================================
-- 3 · CACHÉ GLOBAL (modelo pull con epoch)
--
-- Una página no puede hablarle a los Service Workers de otros dispositivos.
-- Entonces: el admin sube el epoch y cada cliente, al abrir la app o volver a
-- la pestaña, compara y purga sus cachés + actualiza el SW.
-- ============================================================================

create table if not exists public.app_flags (
    clave          text primary key,
    valor          text not null,
    actualizado_en timestamptz not null default now()
);

alter table public.app_flags enable row level security;   -- sin políticas

insert into public.app_flags (clave, valor)
values ('cache_epoch', '1')
on conflict (clave) do nothing;


create or replace function public.cache_epoch_actual()
returns integer
language sql
stable
security definer
set search_path = public
as $$
    select coalesce(
        (select nullif(regexp_replace(f.valor, '[^0-9]', '', 'g'), '')::integer
           from public.app_flags f where f.clave = 'cache_epoch'),
        1
    );
$$;

-- Público a propósito: es un número, no un dato de negocio.
grant execute on function public.cache_epoch_actual() to anon, authenticated;


create or replace function public.admin_cache_purgar()
returns integer
language plpgsql
security definer
set search_path = public
as $$
declare
    v_epoch integer;
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;

    update public.app_flags
       set valor = ((coalesce(nullif(regexp_replace(valor, '[^0-9]', '', 'g'), '')::integer, 1)) + 1)::text,
           actualizado_en = now()
     where clave = 'cache_epoch'
    returning nullif(regexp_replace(valor, '[^0-9]', '', 'g'), '')::integer into v_epoch;

    if v_epoch is null then
        insert into public.app_flags (clave, valor, actualizado_en)
        values ('cache_epoch', '2', now())
        on conflict (clave) do update set valor = '2', actualizado_en = now()
        returning 2 into v_epoch;
    end if;

    return v_epoch;
end $$;

grant execute on function public.admin_cache_purgar() to authenticated;


notify pgrst, 'reload schema';


-- ============================================================================
-- VERIFICACIÓN (correr a mano después de aplicar)
-- ============================================================================
-- 1) tablas y RLS
--    select relname, relrowsecurity from pg_class
--     where relname in ('tickets','app_flags');
--
-- 2) sin políticas (debe devolver 0 filas)
--    select tablename, policyname from pg_policies
--     where tablename in ('tickets','app_flags');
--
-- 3) funciones y permisos
--    select p.proname,
--           has_function_privilege('authenticated', p.oid, 'execute') as auth_ok,
--           has_function_privilege('anon', p.oid, 'execute') as anon_ok
--      from pg_proc p join pg_namespace n on n.oid = p.pronamespace
--     where n.nspname = 'public'
--       and p.proname in ('admin_tickets','admin_tickets_abiertos','admin_ticket_crear',
--                         'admin_ticket_estado','admin_ticket_borrar','admin_metricas_saas',
--                         'cache_epoch_actual','admin_cache_purgar')
--     order by p.proname;
--    Esperado: solo cache_epoch_actual con anon_ok = true.
--
-- 4) métricas (como super admin)
--    select * from public.admin_metricas_saas();
--
-- 5) epoch y purga
--    select public.cache_epoch_actual();
--    select public.admin_cache_purgar();   -- sube 1
--    select public.cache_epoch_actual();
