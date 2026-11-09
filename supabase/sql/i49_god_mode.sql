-- ============================================================
-- ELI M. NAILS · I49 · God Mode V4
-- Planes, usuarios, series, feature flags y dueña en el resumen.
-- Idempotente: se puede correr varias veces.
-- ============================================================

-- 1) PLANES ---------------------------------------------------
create table if not exists public.planes (
    id               text primary key,
    nombre           text not null,
    precio           numeric(10,2) not null default 0,
    limite_empleadas integer,
    descripcion      text,
    activo           boolean not null default true
);

alter table public.planes enable row level security;

drop policy if exists planes_lectura on public.planes;
create policy planes_lectura on public.planes for select to authenticated using (true);

drop policy if exists planes_admin on public.planes;
create policy planes_admin on public.planes for all to authenticated
using (public.es_super_admin())
with check (public.es_super_admin());

insert into public.planes (id, nombre, precio, limite_empleadas, descripcion) values
    ('gratis',  'Gratis',   0,     1,    '1 empleada · agenda y comprobantes'),
    ('pro',     'Pro',      9900,  3,    '3 empleadas · CRM y finanzas'),
    ('premium', 'Premium',  19900, null, 'Empleadas ilimitadas · soporte prioritario')
on conflict (id) do nothing;

-- 2) CONFIGURACIÓN GLOBAL (feature flags) ---------------------
create table if not exists public.configuracion_global (
    clave         text primary key,
    valor_boolean boolean not null default true,
    descripcion   text
);

alter table public.configuracion_global enable row level security;

drop policy if exists config_lectura on public.configuracion_global;
create policy config_lectura on public.configuracion_global
for select to authenticated using (true);

insert into public.configuracion_global (clave, valor_boolean, descripcion) values
    ('registro_abierto',    true, 'Permitir el alta de nuevos salones'),
    ('whatsapp_habilitado', true, 'Habilitar el envío de tarjetas por WhatsApp')
on conflict (clave) do nothing;

create or replace function public.flags_publicos()
returns table (registro_abierto boolean, whatsapp_habilitado boolean)
language sql
stable
security definer
set search_path = public
as $$
    select
        coalesce((select valor_boolean from public.configuracion_global where clave = 'registro_abierto'), true),
        coalesce((select valor_boolean from public.configuracion_global where clave = 'whatsapp_habilitado'), true);
$$;
grant execute on function public.flags_publicos() to anon, authenticated;

create or replace function public.admin_flags()
returns table (clave text, valor_boolean boolean, descripcion text)
language plpgsql security definer set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    return query select c.clave, c.valor_boolean, c.descripcion
                 from public.configuracion_global c order by c.clave;
end $$;
grant execute on function public.admin_flags() to authenticated;

create or replace function public.admin_set_flag(p_clave text, p_valor boolean)
returns void
language plpgsql security definer set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    insert into public.configuracion_global (clave, valor_boolean)
    values (p_clave, p_valor)
    on conflict (clave) do update set valor_boolean = excluded.valor_boolean;
end $$;
grant execute on function public.admin_set_flag(text, boolean) to authenticated;

-- 3) RESUMEN DE SALONES (dueña + último turno) ----------------
drop function if exists public.admin_resumen_salones();

create function public.admin_resumen_salones()
returns table (
    id uuid, nombre text, dueno_email text, miembros bigint,
    turnos bigint, creado_en timestamptz, activo boolean, ultimo_turno date
)
language plpgsql security definer set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    return query
        select s.id, s.nombre,
               (select m.email from public.miembros_salon m
                 where m.salon_id = s.id and m.rol = 'owner'
                 order by m.id limit 1),
               (select count(*) from public.miembros_salon m where m.salon_id = s.id),
               (select count(*) from public.turnos t where t.salon_id = s.id),
               s.creado_en, s.activo,
               (select max(t.appointment_date) from public.turnos t where t.salon_id = s.id)
        from public.salones s
        order by s.nombre;
end $$;
grant execute on function public.admin_resumen_salones() to authenticated;

-- 4) TODOS LOS USUARIOS --------------------------------------
create or replace function public.admin_todos_usuarios()
returns table (
    id uuid, email text, creado_en timestamptz, ultimo_acceso timestamptz,
    salon_id uuid, salon_nombre text, rol text, activo boolean
)
language plpgsql security definer set search_path = public, auth
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    return query
        select u.id, u.email::text, u.created_at, u.last_sign_in_at,
               m.salon_id, s.nombre, m.rol, coalesce(m.activo, true)
        from auth.users u
        left join public.miembros_salon m on m.user_id = u.id
        left join public.salones s on s.id = m.salon_id
        order by u.created_at desc;
end $$;
grant execute on function public.admin_todos_usuarios() to authenticated;

-- 5) SERIES MENSUALES (MRR + salones nuevos) -----------------
create or replace function public.admin_series_mensuales()
returns table (mes date, salones_nuevos bigint, mrr numeric)
language plpgsql security definer set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    return query
        with meses as (
            select (date_trunc('month', now()) - (n || ' months')::interval)::date as mes
            from generate_series(0, 11) n
        )
        select m.mes,
               (select count(*) from public.salones s
                 where date_trunc('month', s.creado_en)::date = m.mes),
               coalesce((select sum(p.precio)
                           from public.salones s
                           join public.planes p on p.id = s.plan_id
                          where date_trunc('month', s.creado_en)::date <= m.mes
                            and s.activo is not false
                            and coalesce(s.estado_suscripcion, 'trial') = 'active'), 0)
        from meses m
        order by m.mes;
end $$;
grant execute on function public.admin_series_mensuales() to authenticated;

-- 6) PLANES · RPCs -------------------------------------------
create or replace function public.admin_planes()
returns table (id text, nombre text, precio numeric, limite_empleadas integer, descripcion text, activo boolean)
language plpgsql security definer set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    return query select p.id, p.nombre, p.precio, p.limite_empleadas, p.descripcion, p.activo
                 from public.planes p order by p.precio;
end $$;
grant execute on function public.admin_planes() to authenticated;

create or replace function public.admin_plan_guardar(
    p_id text, p_nombre text, p_precio numeric, p_limite integer, p_descripcion text, p_activo boolean
)
returns void
language plpgsql security definer set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    if p_id is null or trim(p_id) = '' then raise exception 'id_requerido'; end if;
    insert into public.planes (id, nombre, precio, limite_empleadas, descripcion, activo)
    values (lower(trim(p_id)), trim(p_nombre), coalesce(p_precio, 0), p_limite, p_descripcion, coalesce(p_activo, true))
    on conflict (id) do update
        set nombre = excluded.nombre,
            precio = excluded.precio,
            limite_empleadas = excluded.limite_empleadas,
            descripcion = excluded.descripcion,
            activo = excluded.activo;
end $$;
grant execute on function public.admin_plan_guardar(text, text, numeric, integer, text, boolean) to authenticated;

notify pgrst, 'reload schema';

-- ============================================================
-- 7) LIMPIEZA OPCIONAL · borra todo salvo el principal
--    (descomentar y ejecutar solo si querés limpiar pruebas)
-- ============================================================
-- do $$
-- declare v_principal uuid := '1c13a011-78c4-4009-9e62-7bc22b649cce';
--         r record;
-- begin
--   for r in select id from public.salones where id <> v_principal loop
--     delete from public.pagos_deudas where deuda_id in (select id from public.deudas where salon_id = r.id);
--     delete from public.deudas    where salon_id = r.id;
--     delete from public.gastos    where salon_id = r.id;
--     delete from public.turnos    where salon_id = r.id;
--     delete from public.clientes  where salon_id = r.id;
--     delete from public.servicios where salon_id = r.id;
--     delete from public.miembros_salon where salon_id = r.id;
--     delete from public.salones   where id = r.id;
--   end loop;
-- end $$;
