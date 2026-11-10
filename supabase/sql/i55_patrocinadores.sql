-- ============================================================================
-- ELI M. NAILS · I55 · Patrocinadores (modelo Freemium)
--
-- El plan Gratis muestra un patrocinador sutil en el Inicio. El plan Pro lo
-- quita. Esta migración crea SOLO la infraestructura: tabla, permisos y RPCs.
-- No hay cobro ni MercadoPago acá.
--
-- Seguridad:
--   · RLS activo y SIN políticas → nadie lee ni escribe la tabla directo.
--   · Todo pasa por RPCs: las de admin validan es_super_admin().
--   · La RPC pública devuelve solo id, nombre, mensaje, logo_url, url_destino.
--     Nunca creado_en, activo, ni datos de salones.
--
-- Idempotente: se puede correr varias veces.
-- ============================================================================


-- ============================================================================
-- 1 · TABLA
-- ============================================================================

create table if not exists public.patrocinadores (
    id          uuid primary key default gen_random_uuid(),
    nombre      text not null,
    mensaje     text,
    logo_url    text,
    url_destino text,
    activo      boolean not null default true,
    orden       integer not null default 0,
    creado_en   timestamptz not null default now()
);

-- Validaciones: nada de URLs raras ni nombres vacíos.
alter table public.patrocinadores
    drop constraint if exists patrocinadores_nombre_check;
alter table public.patrocinadores
    add constraint patrocinadores_nombre_check
    check (char_length(btrim(nombre)) between 1 and 60);

alter table public.patrocinadores
    drop constraint if exists patrocinadores_mensaje_check;
alter table public.patrocinadores
    add constraint patrocinadores_mensaje_check
    check (mensaje is null or char_length(btrim(mensaje)) <= 90);

-- Solo https:// (evita javascript:, data: y http plano).
alter table public.patrocinadores
    drop constraint if exists patrocinadores_url_check;
alter table public.patrocinadores
    add constraint patrocinadores_url_check
    check (url_destino is null or url_destino ~* '^https://');

alter table public.patrocinadores
    drop constraint if exists patrocinadores_logo_check;
alter table public.patrocinadores
    add constraint patrocinadores_logo_check
    check (logo_url is null or logo_url ~* '^https://');

create index if not exists patrocinadores_activos_idx
    on public.patrocinadores (activo, orden);


-- ============================================================================
-- 2 · RLS SIN POLÍTICAS
--
-- Sin políticas, Postgres niega todo a anon/authenticated. El acceso es
-- exclusivamente por las RPCs security definer de abajo.
-- ============================================================================

alter table public.patrocinadores enable row level security;


-- ============================================================================
-- 3 · KILL SWITCH
--
-- admin_flags() ya lista toda configuracion_global, así que este flag aparece
-- solo en Admin → Ajustes, con su interruptor.
-- ============================================================================

insert into public.configuracion_global (clave, valor_boolean, descripcion)
values ('patrocinios_habilitados', true,
        'Muestra el patrocinador en el Inicio de los salones con plan Gratis')
on conflict (clave) do nothing;


-- ============================================================================
-- 4 · RPC PÚBLICA
--
-- Devuelve UN patrocinador (el de menor orden) o cero filas si:
--   · no hay patrocinadores activos, o
--   · el flag patrocinios_habilitados está en false.
--
-- La app la llama sin sesión de admin: solo desde el Inicio del plan Gratis.
-- ============================================================================

create or replace function public.patrocinador_publico()
returns table (
    id          uuid,
    nombre      text,
    mensaje     text,
    logo_url    text,
    url_destino text
)
language sql
stable
security definer
set search_path = public
as $$
    select p.id, p.nombre, p.mensaje, p.logo_url, p.url_destino
      from public.patrocinadores p
     where p.activo
       and coalesce((select c.valor_boolean
                       from public.configuracion_global c
                      where c.clave = 'patrocinios_habilitados'), true)
     order by p.orden asc, p.creado_en asc
     limit 1;
$$;

grant execute on function public.patrocinador_publico() to anon, authenticated;


-- ============================================================================
-- 5 · RPCS DE ADMIN
-- ============================================================================

create or replace function public.admin_patrocinadores()
returns table (
    id          uuid,
    nombre      text,
    mensaje     text,
    logo_url    text,
    url_destino text,
    activo      boolean,
    orden       integer,
    creado_en   timestamptz
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    return query
        select p.id, p.nombre, p.mensaje, p.logo_url, p.url_destino,
               p.activo, p.orden, p.creado_en
          from public.patrocinadores p
         order by p.activo desc, p.orden asc, p.creado_en desc;
end $$;

grant execute on function public.admin_patrocinadores() to authenticated;


create or replace function public.admin_patrocinador_guardar(
    p_id       uuid,
    p_nombre   text,
    p_mensaje  text,
    p_logo     text,
    p_url      text,
    p_orden    integer,
    p_activo   boolean
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id     uuid;
    v_nombre text := btrim(coalesce(p_nombre, ''));
    v_url    text := nullif(btrim(coalesce(p_url, '')), '');
    v_logo   text := nullif(btrim(coalesce(p_logo, '')), '');
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    if v_nombre = '' then raise exception 'nombre_requerido'; end if;
    if v_url is not null and v_url !~* '^https://' then raise exception 'url_invalida'; end if;
    if v_logo is not null and v_logo !~* '^https://' then raise exception 'logo_invalido'; end if;

    if p_id is null then
        insert into public.patrocinadores (nombre, mensaje, logo_url, url_destino, orden, activo)
        values (
            v_nombre,
            nullif(btrim(coalesce(p_mensaje, '')), ''),
            v_logo,
            v_url,
            coalesce(p_orden, 0),
            coalesce(p_activo, true)
        )
        returning id into v_id;
    else
        update public.patrocinadores
           set nombre      = v_nombre,
               mensaje     = nullif(btrim(coalesce(p_mensaje, '')), ''),
               logo_url    = v_logo,
               url_destino = v_url,
               orden       = coalesce(p_orden, orden),
               activo      = coalesce(p_activo, activo)
         where id = p_id
        returning id into v_id;

        if v_id is null then raise exception 'no_existe'; end if;
    end if;

    return v_id;
end $$;

grant execute on function public.admin_patrocinador_guardar(uuid, text, text, text, text, integer, boolean)
    to authenticated;


create or replace function public.admin_patrocinador_estado(p_id uuid, p_activo boolean)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    update public.patrocinadores set activo = coalesce(p_activo, activo) where id = p_id;
    if not found then raise exception 'no_existe'; end if;
end $$;

grant execute on function public.admin_patrocinador_estado(uuid, boolean) to authenticated;


create or replace function public.admin_patrocinador_borrar(p_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    delete from public.patrocinadores where id = p_id;
end $$;

grant execute on function public.admin_patrocinador_borrar(uuid) to authenticated;


-- ============================================================================
-- 6 · AUDITORÍA
--
-- auditar_cambio_admin() ya tiene un else genérico: registra la acción como
-- 'patrocinadores_cambio'. No hace falta reescribir la función.
-- ============================================================================

drop trigger if exists trg_auditar_patrocinadores on public.patrocinadores;
create trigger trg_auditar_patrocinadores
after insert or update or delete on public.patrocinadores
for each row execute function public.auditar_cambio_admin();


notify pgrst, 'reload schema';

-- ============================================================================
-- VERIFICACIÓN
-- ============================================================================
-- 1) tabla y RLS
-- select relname, relrowsecurity from pg_class where relname = 'patrocinadores';
--
-- 2) sin políticas (debe devolver 0 filas)
-- select policyname from pg_policies where tablename = 'patrocinadores';
--
-- 3) alta de prueba (como super admin, desde el SQL editor auth.uid() es null
--    y es_super_admin() da false: los INSERT directos también están permitidos
--    por el rol de servicio).
-- insert into public.patrocinadores (nombre, mensaje, logo_url, url_destino, orden)
-- values ('Marca Demo', 'Tu aliada en insumos', 'https://ejemplo.com/logo.png',
--         'https://ejemplo.com', 1);
--
-- 4) lectura pública (debe devolver 1 fila si hay activos y el flag está en true)
-- select * from public.patrocinador_publico();
--
-- 5) kill switch
-- update public.configuracion_global set valor_boolean = false
--  where clave = 'patrocinios_habilitados';
-- select * from public.patrocinador_publico();   -- 0 filas

-- ============================================================================
-- 6 · PLANES · B1 (características por plan editables desde el admin)
-- ============================================================================

alter table public.planes
    add column if not exists caracteristicas jsonb not null default '{}'::jsonb;

update public.planes set
    descripcion = '1 persona (la dueña) · agenda y comprobantes',
    caracteristicas = '{"reservas_link": false, "automatizaciones": false, "reportes_avanzados": false, "sin_publicidad": false}'::jsonb
where id = 'gratis';

update public.planes set
    descripcion = 'Hasta 3 personas (dueña + 2) · CRM y finanzas',
    caracteristicas = '{"reservas_link": true, "automatizaciones": true, "reportes_avanzados": true, "sin_publicidad": true}'::jsonb
where id = 'pro';

update public.planes set
    descripcion = 'Personas ilimitadas · soporte prioritario',
    caracteristicas = '{"reservas_link": true, "automatizaciones": true, "reportes_avanzados": true, "sin_publicidad": true}'::jsonb
where id = 'premium';

drop function if exists public.admin_planes();
create function public.admin_planes()
returns table (
    id text, nombre text, precio numeric, limite_empleadas integer,
    descripcion text, activo boolean, caracteristicas jsonb
)
language plpgsql
security definer
set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    return query
        select p.id, p.nombre, p.precio, p.limite_empleadas,
               p.descripcion, p.activo, p.caracteristicas
          from public.planes p
         order by p.precio;
end $$;
grant execute on function public.admin_planes() to authenticated;

create or replace function public.admin_plan_guardar(
    p_id text, p_nombre text, p_precio numeric, p_limite integer,
    p_descripcion text, p_activo boolean, p_caracteristicas jsonb
)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if not public.es_super_admin() then raise exception 'sin_permisos'; end if;
    if p_id is null or trim(p_id) = '' then raise exception 'id_requerido'; end if;
    insert into public.planes (id, nombre, precio, limite_empleadas, descripcion, activo, caracteristicas)
    values (
        lower(trim(p_id)), trim(p_nombre), coalesce(p_precio, 0), p_limite,
        p_descripcion, coalesce(p_activo, true), coalesce(p_caracteristicas, '{}'::jsonb)
    )
    on conflict (id) do update
        set nombre = excluded.nombre,
            precio = excluded.precio,
            limite_empleadas = excluded.limite_empleadas,
            descripcion = excluded.descripcion,
            activo = excluded.activo,
            caracteristicas = excluded.caracteristicas;
end $$;
grant execute on function public.admin_plan_guardar(text, text, numeric, integer, text, boolean, jsonb) to authenticated;

notify pgrst, 'reload schema';
