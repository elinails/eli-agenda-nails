-- ============================================================================
-- ELI M. NAILS · I50 · Blindaje de seguridad SaaS
--
-- Corrige los 3 agujeros encontrados en la auditoría de la base viva:
--   1. gastos: política USING (true) → cualquiera leía/escribía todo
--   2. storage logos: políticas legacy sin chequeo de carpeta
--   3. deudas / pagos_deudas: solo por user_id, no por salón
--
-- Agrega además:
--   4. agregar_miembro_salon() con límite de plan
--   5. trigger de límite de plan (respaldo para cualquier insert)
--   6. admin_alertas() para el panel
--
-- Idempotente: se puede correr varias veces.
-- ============================================================================

-- 0) Copia de seguridad de las políticas actuales ---------------------------
create table if not exists public._backup_politicas_i50 as
select * from pg_policies where schemaname in ('public', 'storage');


-- 1) GASTOS: cerrar el agujero crítico -------------------------------------
drop policy if exists gastos_propios on public.gastos;
drop policy if exists propias_gastos  on public.gastos;

drop policy if exists gastos_salon on public.gastos;
create policy gastos_salon on public.gastos
for all to authenticated
using (public.es_owner(salon_id))
with check (public.es_owner(salon_id));


-- 2) DEUDAS y PAGOS: por salón (solo la dueña) -----------------------------
drop policy if exists propias_deudas       on public.deudas;
drop policy if exists propias_pagos_deudas on public.pagos_deudas;

drop policy if exists deudas_salon on public.deudas;
create policy deudas_salon on public.deudas
for all to authenticated
using (public.es_owner(salon_id))
with check (public.es_owner(salon_id));

drop policy if exists pagos_salon on public.pagos_deudas;
create policy pagos_salon on public.pagos_deudas
for all to authenticated
using (public.es_owner(salon_id))
with check (public.es_owner(salon_id));


-- 3) STORAGE · logos: borrar las políticas legacy sin carpeta --------------
drop policy if exists "Permitir ver logos"        on storage.objects;
drop policy if exists "Permitir subir logos"      on storage.objects;
drop policy if exists "Permitir actualizar logos" on storage.objects;


-- 4) AGREGAR MIEMBRO con validación de plan --------------------------------
create or replace function public.agregar_miembro_salon(p_email text, p_rol text default 'staff')
returns bigint
language plpgsql
security definer
set search_path = public, auth
as $$
declare
    v_salon    uuid;
    v_user     uuid;
    v_email    text;
    v_id       bigint;
    v_plan     text;
    v_limite   integer;
    v_activos  integer;
begin
    if auth.uid() is null then raise exception 'sin_sesion'; end if;

    select m.salon_id into v_salon
      from public.miembros_salon m
     where m.user_id = auth.uid() and m.rol = 'owner' and m.activo
     limit 1;

    if v_salon is null then raise exception 'sin_permisos'; end if;

    v_email := lower(trim(p_email));
    if v_email is null or position('@' in v_email) = 0 then raise exception 'email_invalido'; end if;

    select u.id into v_user from auth.users u where lower(u.email::text) = v_email limit 1;
    if v_user is null then raise exception 'usuario_no_registrado'; end if;

    -- límite de plan (solo cuenta empleadas, la dueña no ocupa cupo)
    select s.plan_id into v_plan from public.salones s where s.id = v_salon;
    select p.limite_empleadas into v_limite
      from public.planes p where p.id = coalesce(v_plan, 'gratis');

    if v_limite is not null then
        select count(*) into v_activos
          from public.miembros_salon m
         where m.salon_id = v_salon and m.rol = 'staff' and m.activo
           and m.user_id <> v_user;

        if v_activos >= v_limite then
            raise exception 'limite_plan:%', v_limite using errcode = 'P0002';
        end if;
    end if;

    insert into public.miembros_salon (salon_id, user_id, email, rol, activo)
    values (v_salon, v_user, v_email, coalesce(nullif(p_rol, ''), 'staff'), true)
    on conflict (salon_id, user_id) do update
        set rol = excluded.rol, activo = true, email = excluded.email
    returning id into v_id;

    return v_id;
end $$;
grant execute on function public.agregar_miembro_salon(text, text) to authenticated;


-- 5) Trigger de respaldo del límite (cubre cualquier otro camino) ----------
create or replace function public.miembros_valida_limite()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_plan    text;
    v_limite  integer;
    v_activos integer;
begin
    if coalesce(NEW.activo, true) is false then return NEW; end if;
    if NEW.rol = 'owner' then return NEW; end if;

    select s.plan_id into v_plan from public.salones s where s.id = NEW.salon_id;
    select p.limite_empleadas into v_limite
      from public.planes p where p.id = coalesce(v_plan, 'gratis');

    if v_limite is null then return NEW; end if;

    select count(*) into v_activos
      from public.miembros_salon m
     where m.salon_id = NEW.salon_id and m.rol = 'staff' and m.activo
       and m.id is distinct from NEW.id;

    if v_activos >= v_limite then
        raise exception 'limite_plan:%', v_limite using errcode = 'P0002';
    end if;
    return NEW;
end $$;

drop trigger if exists trg_miembros_limite on public.miembros_salon;
create trigger trg_miembros_limite
before insert or update of rol, activo on public.miembros_salon
for each row execute function public.miembros_valida_limite();


-- 6) Alertas de seguridad para el panel ------------------------------------
create or replace function public.admin_alertas()
returns table (
    fallidos_1h bigint,
    fallidos_24h bigint,
    ips_sospechosas bigint,
    ultimo_fallo timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    return query
        select
            (select count(*) from public.auditoria_admin a
              where a.accion = 'impersonar_fallido' and a.creado_en > now() - interval '1 hour'),
            (select count(*) from public.auditoria_admin a
              where a.accion = 'impersonar_fallido' and a.creado_en > now() - interval '24 hours'),
            (select count(distinct a.ip) from public.auditoria_admin a
              where a.accion = 'impersonar_fallido' and a.creado_en > now() - interval '24 hours'),
            (select max(a.creado_en) from public.auditoria_admin a
              where a.accion = 'impersonar_fallido');
end $$;
grant execute on function public.admin_alertas() to authenticated;


notify pgrst, 'reload schema';

-- ============================================================================
-- Verificación posterior (debe devolver 0 filas)
-- ============================================================================
-- select * from pg_policies
--  where tablename = 'gastos' and qual = 'true';
