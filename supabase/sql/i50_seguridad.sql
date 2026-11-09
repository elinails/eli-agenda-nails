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




-- 7) STORAGE · bucket legacy "tickets" (la app no lo usa) ------------------
drop policy if exists "ver tickets propios"    on storage.objects;
drop policy if exists "subir tickets propios"  on storage.objects;
drop policy if exists "borrar tickets propios" on storage.objects;

-- opcional: borrar el bucket cuando esté vacío
-- delete from storage.buckets b
--  where b.id = 'tickets'
--    and not exists (select 1 from storage.objects o where o.bucket_id = 'tickets');

notify pgrst, 'reload schema';

-- ============================================================================
-- Verificación posterior (debe devolver 0 filas)
-- ============================================================================
-- select * from pg_policies
--  where tablename = 'gastos' and qual = 'true';

-- ============================================================================
-- 8) I50 · CIERRE (este bloque manda sobre las secciones 4 y 5)
--
-- Reglas:
--   · Límite = dueña + staff activos (Gratis 1, Pro 3, Premium sin límite).
--   · Una sola dueña por salón (sin co-dueñas).
--   · Solo la dueña invita/edita miembros.
--   · Nadie salvo SuperAdmin cambia plan/estado/activo de un salón.
--   · Servicios: dueña escribe, staff solo lee.
--   · Registro cerrado bloquea el onboarding.
-- ============================================================================

-- 8.1 Reemplazar el trigger staff-only anterior -----------------------------
drop trigger if exists trg_miembros_limite on public.miembros_salon;
drop function if exists public.miembros_valida_limite();

-- 8.2 Trigger de plan + dueña única + protección de la dueña ---------------
create or replace function public.validar_plan_miembro()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_limite  integer;
    v_activos integer;
    v_plan    text;
begin
    -- DELETE: no permitir quedarse sin dueña
    if tg_op = 'DELETE' then
        if auth.uid() is not null
           and not public.es_super_admin()
           and old.rol = 'owner'
           and not exists (
               select 1 from public.miembros_salon m
                where m.salon_id = old.salon_id and m.rol = 'owner'
                  and m.id is distinct from old.id
           ) then
            raise exception 'owner_requerido';
        end if;
        return old;
    end if;

    -- Service role / SQL editor / SuperAdmin: sin restricciones
    if auth.uid() is null or public.es_super_admin() then
        return new;
    end if;

    -- No mover un miembro de salón ni cambiarle el user_id
    if tg_op = 'UPDATE' and (
        new.salon_id is distinct from old.salon_id
        or new.user_id is distinct from old.user_id
    ) then
        raise exception 'miembro_inmutable';
    end if;

    -- Solo la dueña del salón invita/edita (defensa en profundidad)
    if not exists (
        select 1 from public.miembros_salon m
         where m.salon_id = new.salon_id and m.user_id = auth.uid()
           and m.rol = 'owner' and m.activo
    ) then
        -- bootstrap: primer owner creado por crear_salon_inicial
        if not (
            tg_op = 'INSERT'
            and not exists (select 1 from public.miembros_salon m where m.salon_id = new.salon_id)
            and new.user_id = auth.uid()
            and new.rol = 'owner'
        ) then
            raise exception 'solo_owner';
        end if;
    end if;

    -- Sin co-dueñas
    if new.rol = 'owner' and exists (
        select 1 from public.miembros_salon m
         where m.salon_id = new.salon_id and m.rol = 'owner'
           and m.id is distinct from new.id
    ) then
        raise exception 'owner_unico';
    end if;

    -- No degradar a la última dueña
    if tg_op = 'UPDATE' and old.rol = 'owner' and new.rol <> 'owner'
       and not exists (
           select 1 from public.miembros_salon m
            where m.salon_id = old.salon_id and m.rol = 'owner'
              and m.id is distinct from old.id
       ) then
        raise exception 'owner_requerido';
    end if;

    if new.activo is false then
        return new;
    end if;

    -- Si la fila ya estaba activa, el cupo no cambia: permitir editar
    -- email/rol sin bloquear a salones en gracia por downgrade.
    if tg_op = 'UPDATE' and old.activo is true then
        return new;
    end if;

    -- Límite: dueña + staff activos
    select s.plan_id into v_plan from public.salones s where s.id = new.salon_id;
    select p.limite_empleadas into v_limite
      from public.planes p where p.id = coalesce(v_plan, 'gratis');

    if v_limite is null then
        return new;
    end if;

    select count(*) into v_activos
      from public.miembros_salon m
     where m.salon_id = new.salon_id and m.activo
       and m.id is distinct from new.id;

    if v_activos >= v_limite then
        raise exception 'limite_plan:%', v_limite using errcode = 'P0002';
    end if;

    return new;
end $$;

drop trigger if exists trg_validar_plan_miembro on public.miembros_salon;
create trigger trg_validar_plan_miembro
before insert or update or delete on public.miembros_salon
for each row execute function public.validar_plan_miembro();

-- 8.3 Invitar solo staff, con límite dueña+staff ---------------------------
--     La RPC anterior devolvía bigint y el id real es uuid: se reemplaza.
drop function if exists public.agregar_miembro_salon(text, text);
create function public.agregar_miembro_salon(p_email text, p_rol text default 'staff')
returns uuid
language plpgsql
security definer
set search_path = public, auth
as $$
declare
    v_salon   uuid;
    v_user    uuid;
    v_email   text;
    v_id      uuid;
    v_rol     text;
begin
    if auth.uid() is null then raise exception 'sin_sesion'; end if;

    select m.salon_id into v_salon
      from public.miembros_salon m
     where m.user_id = auth.uid() and m.rol = 'owner' and m.activo
     limit 1;

    if v_salon is null then raise exception 'sin_permisos'; end if;

    v_rol := coalesce(nullif(trim(p_rol), ''), 'staff');
    if v_rol <> 'staff' then raise exception 'owner_unico'; end if;

    v_email := lower(trim(coalesce(p_email, '')));
    if v_email = '' or position('@' in v_email) = 0 then raise exception 'email_invalido'; end if;

    select u.id into v_user from auth.users u where lower(u.email::text) = v_email limit 1;
    if v_user is null then raise exception 'usuario_no_registrado'; end if;
    if v_user = auth.uid() then raise exception 'ya_es_duena'; end if;

    -- El límite (dueña + staff) lo valida el trigger validar_plan_miembro.
    insert into public.miembros_salon (salon_id, user_id, email, rol, activo)
    values (v_salon, v_user, v_email, 'staff', true)
    on conflict (salon_id, user_id) do update
        set email = excluded.email, activo = true
    returning id into v_id;

    return v_id;
end $$;
grant execute on function public.agregar_miembro_salon(text, text) to authenticated;

-- 8.4 Nadie salvo SuperAdmin cambia plan/estado/activo de un salón ---------
create or replace function public.proteger_salones()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if auth.uid() is null or public.es_super_admin() then
        return new;
    end if;
    if new.plan_id is distinct from old.plan_id
       or new.estado_suscripcion is distinct from old.estado_suscripcion
       or new.trial_hasta is distinct from old.trial_hasta
       or new.suscripcion_desde is distinct from old.suscripcion_desde
       or new.activo is distinct from old.activo
       or new.dueno_user_id is distinct from old.dueno_user_id then
        raise exception 'solo_admin';
    end if;
    return new;
end $$;

drop trigger if exists trg_proteger_salones on public.salones;
create trigger trg_proteger_salones
before update on public.salones
for each row execute function public.proteger_salones();

-- 8.5 Servicios: staff solo lectura ---------------------------------------
drop policy if exists servicios_salon on public.servicios;
drop policy if exists servicios_lectura on public.servicios;
drop policy if exists servicios_owner_write on public.servicios;
create policy servicios_lectura on public.servicios
for select to authenticated using (public.es_miembro(salon_id));
create policy servicios_owner_write on public.servicios
for all to authenticated
using (public.es_owner(salon_id))
with check (public.es_owner(salon_id));

-- 8.6 CHECK de rol (idempotente; la base ya lo tiene) ---------------------
do $$
begin
    if not exists (
        select 1 from pg_constraint
         where conname = 'miembros_salon_rol_check'
           and conrelid = 'public.miembros_salon'::regclass
    ) then
        alter table public.miembros_salon
            add constraint miembros_salon_rol_check check (rol in ('owner','staff'));
    end if;
end $$;

-- 8.7 Registro cerrado: bloquear onboarding --------------------------------
create or replace function public.crear_salon_inicial(p_nombre text default 'Mi salón')
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_user  uuid := auth.uid();
    v_salon uuid;
    v_email text;
    v_nombre text;
begin
    if v_user is null then raise exception 'sin_sesion'; end if;

    select m.salon_id into v_salon
      from public.miembros_salon m
     where m.user_id = v_user and m.activo
     order by m.creado_en limit 1;
    if v_salon is not null then return v_salon; end if;

    if exists (select 1 from public.miembros_salon m where m.user_id = v_user) then
        raise exception 'cuenta_desactivada';
    end if;

    if not coalesce((
        select valor_boolean from public.configuracion_global where clave = 'registro_abierto'
    ), true) then
        raise exception 'registro_cerrado';
    end if;

    select email into v_email from auth.users where id = v_user;
    v_nombre := coalesce(nullif(trim(p_nombre), ''), 'Salón de ' || split_part(coalesce(v_email, ''), '@', 1));

    insert into public.salones (nombre, dueno_user_id)
    values (v_nombre, v_user)
    returning id into v_salon;

    insert into public.miembros_salon (salon_id, user_id, rol, email, nombre, activo)
    values (v_salon, v_user, 'owner', v_email, split_part(coalesce(v_email, ''), '@', 1), true);

    insert into public.servicios (salon_id, nombre, precio_base, duracion_minutos)
    values (v_salon, 'Servicio general', 0, 60);

    return v_salon;
end $$;
grant execute on function public.crear_salon_inicial(text) to authenticated;

-- 8.8 Anuncio visible antes del login (anon) ------------------------------
drop policy if exists anuncios_publicos_lectura on public.anuncios_globales;
create policy anuncios_publicos_lectura on public.anuncios_globales
for select to anon, authenticated
using (activo and (expira_en is null or expira_en > now()));

-- 8.9 Dueña única por salón: limpiar duplicados y crear índice -------------
--     Conserva como dueña a la que coincide con salones.dueno_user_id;
--     si ninguna coincide, conserva la más antigua.
with ranked as (
    select m.id,
           row_number() over (
               partition by m.salon_id
               order by (m.user_id = s.dueno_user_id) desc, m.creado_en, m.id
           ) as rn
      from public.miembros_salon m
      join public.salones s on s.id = m.salon_id
     where m.rol = 'owner'
)
update public.miembros_salon m
   set rol = 'staff'
  from ranked r
 where m.id = r.id and r.rn > 1;

create unique index if not exists un_owner_por_salon
    on public.miembros_salon (salon_id) where rol = 'owner';

-- 8.10 Deduplicación de alertas (GitHub Action) ---------------------------
create table if not exists public.seguridad_alertas (
    clave      text primary key,
    creado_en  timestamptz not null default now()
);
alter table public.seguridad_alertas enable row level security;
revoke all on public.seguridad_alertas from anon, authenticated;

-- 8.11 La tabla de backup de políticas no debe ser legible ----------------
alter table public._backup_politicas_i50 enable row level security;
revoke all on public._backup_politicas_i50 from anon, authenticated;

notify pgrst, 'reload schema';

-- ============================================================================
-- Verificación posterior (manual)
-- ============================================================================
-- select salon_id, count(*) from public.miembros_salon where rol='owner' group by salon_id having count(*)>1;
-- select * from public.planes order by precio;
-- select tgname from pg_trigger where tgname in ('trg_validar_plan_miembro','trg_proteger_salones');
-- select * from pg_policies where tablename in ('servicios','salones','miembros_salon');
