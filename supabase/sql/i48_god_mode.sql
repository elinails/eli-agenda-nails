-- ============================================================
-- ELI M. NAILS · I48 · God Mode V3
-- Tablas y RPCs para suscripciones, anuncios y auditoría.
-- Todas las RPCs validan que auth.uid() esté en public.super_admins.
-- ============================================================

-- 1) SUSCRIPCIONES -------------------------------------------
create table if not exists public.suscripciones (
    salon_id       uuid primary key references public.salones(id) on delete cascade,
    plan           text not null default 'basico',
    estado         text not null default 'activa',
    vence_en       date,
    actualizado_en timestamptz not null default now()
);

alter table public.suscripciones enable row level security;

-- 2) ANUNCIOS ------------------------------------------------
create table if not exists public.anuncios (
    id         uuid primary key default gen_random_uuid(),
    mensaje    text not null,
    tipo       text not null default 'info',
    activo     boolean not null default true,
    creado_en  timestamptz not null default now(),
    expira_en  timestamptz
);

alter table public.anuncios enable row level security;

drop policy if exists anuncios_lectura on public.anuncios;
create policy anuncios_lectura on public.anuncios for select to authenticated
using (activo and (expira_en is null or expira_en > now()));

-- 3) AUDITORÍA -----------------------------------------------
create table if not exists public.auditoria_admin (
    id         bigint generated always as identity primary key,
    admin_id   uuid,
    salon_id   uuid,
    accion     text not null,
    detalle    jsonb,
    ip         text,
    user_agent text,
    creado_en  timestamptz not null default now()
);

alter table public.auditoria_admin enable row level security;
-- sin políticas: solo la service_role (Edge Function) escribe y lee.

-- 4) HELPERS -------------------------------------------------
create or replace function public.es_super_admin()
returns boolean
language sql stable security definer set search_path = public
as $$
    select exists (select 1 from public.super_admins sa where sa.user_id = auth.uid());
$$;
grant execute on function public.es_super_admin() to authenticated;

-- 5) SUSCRIPCIONES · RPCs ------------------------------------
create or replace function public.admin_suscripciones()
returns table (
    salon_id uuid, nombre text, dueno_email text,
    plan text, estado text, vence_en date
)
language plpgsql security definer set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    return query
        select s.id, s.nombre,
               (select m.email from public.miembros_salon m
                 where m.salon_id = s.id and m.rol = 'owner' limit 1),
               coalesce(su.plan, 'basico'),
               coalesce(su.estado, 'activa'),
               su.vence_en
        from public.salones s
        left join public.suscripciones su on su.salon_id = s.id
        order by s.nombre;
end $$;
grant execute on function public.admin_suscripciones() to authenticated;

create or replace function public.admin_set_suscripcion(
    p_salon uuid, p_plan text, p_estado text, p_vence date
)
returns void
language plpgsql security definer set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    insert into public.suscripciones (salon_id, plan, estado, vence_en, actualizado_en)
    values (p_salon, p_plan, p_estado, p_vence, now())
    on conflict (salon_id) do update
        set plan = excluded.plan,
            estado = excluded.estado,
            vence_en = excluded.vence_en,
            actualizado_en = now();
end $$;
grant execute on function public.admin_set_suscripcion(uuid, text, text, date) to authenticated;

-- 6) ANUNCIOS · RPCs -----------------------------------------
create or replace function public.admin_anuncios()
returns table (
    id uuid, mensaje text, tipo text, activo boolean,
    creado_en timestamptz, expira_en timestamptz
)
language plpgsql security definer set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    return query
        select a.id, a.mensaje, a.tipo, a.activo, a.creado_en, a.expira_en
        from public.anuncios a
        order by a.creado_en desc;
end $$;
grant execute on function public.admin_anuncios() to authenticated;

create or replace function public.admin_anuncio_crear(
    p_mensaje text, p_tipo text, p_dias integer
)
returns uuid
language plpgsql security definer set search_path = public
as $$
declare v_id uuid;
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    insert into public.anuncios (mensaje, tipo, activo, expira_en)
    values (
        p_mensaje,
        coalesce(nullif(p_tipo, ''), 'info'),
        true,
        case when p_dias is null or p_dias <= 0 then null
             else now() + (p_dias || ' days')::interval end
    )
    returning anuncios.id into v_id;
    return v_id;
end $$;
grant execute on function public.admin_anuncio_crear(text, text, integer) to authenticated;

create or replace function public.admin_anuncio_estado(p_id uuid, p_activo boolean)
returns void
language plpgsql security definer set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    update public.anuncios set activo = p_activo where id = p_id;
end $$;
grant execute on function public.admin_anuncio_estado(uuid, boolean) to authenticated;

create or replace function public.admin_anuncio_borrar(p_id uuid)
returns void
language plpgsql security definer set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    delete from public.anuncios where id = p_id;
end $$;
grant execute on function public.admin_anuncio_borrar(uuid) to authenticated;

notify pgrst, 'reload schema';
