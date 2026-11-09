-- ============================================================
-- ELI M. NAILS · I48 · Ajuste para la base VIVA
--
-- La base tiene el esquema de columnas (salones.plan_id,
-- anuncios_globales, auditoria_admin) pero faltaban las políticas
-- RLS y la RPC de auditoría que usa el panel.
--
-- Este archivo es idempotente: se puede correr las veces que haga falta.
-- NO crea tablas nuevas ni borra datos.
-- ============================================================

-- 1) Helper de permisos -----------------------------------------
create or replace function public.es_super_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1 from public.super_admins sa where sa.user_id = auth.uid()
    );
$$;

grant execute on function public.es_super_admin() to authenticated;

-- 2) SALONES: lectura y edición para SuperAdmins -----------------
alter table public.salones enable row level security;

drop policy if exists superadmin_salones_select on public.salones;
create policy superadmin_salones_select on public.salones
    for select to authenticated
    using (public.es_super_admin());

drop policy if exists superadmin_salones_update on public.salones;
create policy superadmin_salones_update on public.salones
    for update to authenticated
    using (public.es_super_admin())
    with check (public.es_super_admin());

grant select, update on public.salones to authenticated;

-- 3) ANUNCIOS GLOBALES ------------------------------------------
alter table public.anuncios_globales enable row level security;

-- Lectura pública (login incluido): solo anuncios vigentes.
drop policy if exists anuncios_publicos_lectura on public.anuncios_globales;
create policy anuncios_publicos_lectura on public.anuncios_globales
    for select to anon, authenticated
    using (activo and (expira_en is null or expira_en > now()));

-- El panel necesita ver también los inactivos/vencidos.
drop policy if exists superadmin_anuncios_select on public.anuncios_globales;
create policy superadmin_anuncios_select on public.anuncios_globales
    for select to authenticated
    using (public.es_super_admin());

drop policy if exists superadmin_anuncios_insert on public.anuncios_globales;
create policy superadmin_anuncios_insert on public.anuncios_globales
    for insert to authenticated
    with check (public.es_super_admin());

drop policy if exists superadmin_anuncios_update on public.anuncios_globales;
create policy superadmin_anuncios_update on public.anuncios_globales
    for update to authenticated
    using (public.es_super_admin())
    with check (public.es_super_admin());

grant select, insert, update on public.anuncios_globales to anon, authenticated;

-- 4) AUDITORÍA: lectura solo para SuperAdmins -------------------
alter table public.auditoria_admin enable row level security;

drop policy if exists superadmin_auditoria_select on public.auditoria_admin;
create policy superadmin_auditoria_select on public.auditoria_admin
    for select to authenticated
    using (public.es_super_admin());

grant select on public.auditoria_admin to authenticated;

-- 5) RPC de auditoría con nombres -------------------------------
create or replace function public.admin_auditoria(
    p_limite integer default 100,
    p_offset integer default 0
)
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
    if not public.es_super_admin() then
        raise exception 'sin_permisos';
    end if;

    return query
        select a.id,
               a.creado_en,
               a.admin_id,
               u.email,
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
$$;

grant execute on function public.admin_auditoria(integer, integer) to authenticated;

-- 6) Refrescar el schema cache de PostgREST ---------------------
notify pgrst, 'reload schema';
