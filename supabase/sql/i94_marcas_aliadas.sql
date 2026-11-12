-- ============================================================================
-- ELIMA HUB · I94 · MARCAS ALIADAS (publicidad en el Marketplace)
--
-- Marcas de productos de belleza / insumos que le pagan al SuperAdmin por
-- transferencia para aparecer en el Marketplace. El SuperAdmin carga la marca,
-- el producto, el precio, la foto, el WhatsApp de contacto y la fecha de fin
-- de la pauta.
--
-- El Marketplace es PÚBLICO (sin login), así que la lectura va por RPC con
-- security definer y grant a `anon`. La tabla no expone nada directo: RLS
-- activado SIN políticas, todo pasa por las funciones.
--
-- IDEMPOTENTE: create table if not exists / create or replace.
-- REQUISITOS: i48 (es_super_admin).
-- ============================================================================


-- ============================================================================
-- 1 · TABLA: marcas_aliadas
-- ============================================================================

create table if not exists public.marcas_aliadas (
    id                uuid primary key default gen_random_uuid(),
    nombre_marca      text not null,
    nombre_producto   text not null,
    descripcion       text,
    precio_texto      text,
    foto_url          text,
    whatsapp_contacto text not null,
    activo            boolean not null default true,
    fecha_fin         date not null,
    creado_en         timestamptz not null default now()
);

comment on table public.marcas_aliadas
    is 'Publicidad de marcas de productos/insumos en el Marketplace. Pauta paga, cargada por el SuperAdmin.';
comment on column public.marcas_aliadas.precio_texto
    is 'Precio tal cual lo muestra la marca (ej: "$4.500"). Texto libre: no se hacen cuentas con esto.';
comment on column public.marcas_aliadas.whatsapp_contacto
    is 'Sólo dígitos, con código de país y sin 0 ni 15 (ej: 5491155554444). Es el wa.me del botón.';
comment on column public.marcas_aliadas.fecha_fin
    is 'Último día en que la marca se muestra en el Marketplace.';

-- Consulta pública: activo + vigencia.
create index if not exists idx_marcas_aliadas_publicas
    on public.marcas_aliadas (activo, fecha_fin);

-- Listado del panel: orden por vencimiento.
create index if not exists idx_marcas_aliadas_vencimiento
    on public.marcas_aliadas (fecha_fin);


-- ============================================================================
-- 2 · RLS
-- ============================================================================
-- Sin políticas a propósito: nadie lee ni escribe directo la tabla.
-- El Marketplace usa obtener_marcas_aliadas() y el panel las RPC de admin,
-- todas security definer.

alter table public.marcas_aliadas enable row level security;


-- ============================================================================
-- 3 · RPC PÚBLICA: obtener_marcas_aliadas()
-- ============================================================================
-- La llama marketplace.html sin sesión. Filtra activas y vigentes.
-- No expone el estado, ni la fecha de fin, ni datos internos.

create or replace function public.obtener_marcas_aliadas()
returns table (
    id                uuid,
    nombre_marca      text,
    nombre_producto   text,
    descripcion       text,
    precio_texto      text,
    foto_url          text,
    whatsapp_contacto text
)
language sql
stable
security definer
set search_path = public
as $$
    select
        m.id,
        m.nombre_marca,
        m.nombre_producto,
        coalesce(m.descripcion, '')  as descripcion,
        coalesce(m.precio_texto, '') as precio_texto,
        coalesce(m.foto_url, '')     as foto_url,
        m.whatsapp_contacto
    from public.marcas_aliadas m
    where m.activo = true
      and m.fecha_fin >= current_date
    order by m.creado_en desc;
$$;

comment on function public.obtener_marcas_aliadas()
    is 'Marcas aliadas activas y vigentes para el Marketplace público.';

grant execute on function public.obtener_marcas_aliadas() to anon, authenticated;


-- ============================================================================
-- 4 · RPC ADMIN: admin_listar_marcas()
-- ============================================================================

create or replace function public.admin_listar_marcas()
returns table (
    id                uuid,
    nombre_marca      text,
    nombre_producto   text,
    descripcion       text,
    precio_texto      text,
    foto_url          text,
    whatsapp_contacto text,
    activo            boolean,
    fecha_fin         date,
    creado_en         timestamptz,
    vencida           boolean
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
    select
        m.id,
        m.nombre_marca,
        m.nombre_producto,
        coalesce(m.descripcion, '')  as descripcion,
        coalesce(m.precio_texto, '') as precio_texto,
        coalesce(m.foto_url, '')     as foto_url,
        m.whatsapp_contacto,
        m.activo,
        m.fecha_fin,
        m.creado_en,
        (m.fecha_fin < current_date) as vencida
    from public.marcas_aliadas m
    order by m.activo desc, m.fecha_fin asc, m.creado_en desc;
end $$;

comment on function public.admin_listar_marcas()
    is 'Lista todas las marcas aliadas con su estado y vencimiento. Sólo SuperAdmin.';

grant execute on function public.admin_listar_marcas() to authenticated;


-- ============================================================================
-- 5 · RPC ADMIN: admin_guardar_marca()  (crea o actualiza)
-- ============================================================================
-- p_id null  -> inserta una marca nueva
-- p_id uuid  -> actualiza esa marca
--
-- Normaliza el WhatsApp a sólo dígitos (así wa.me funciona siempre) y valida
-- que la foto sea http(s) para no meter cualquier cosa en el <img src>.
--
-- Códigos de error: sin_permisos, nombre_marca_requerido,
--                   nombre_producto_requerido, whatsapp_invalido,
--                   foto_url_invalida, fecha_fin_requerida,
--                   marca_no_encontrada.

create or replace function public.admin_guardar_marca(
    p_id              uuid,
    p_nombre_marca    text,
    p_nombre_producto text,
    p_descripcion     text,
    p_precio_texto    text,
    p_foto_url        text,
    p_whatsapp        text,
    p_fecha_fin       date,
    p_activo          boolean default true
)
returns table (
    id      uuid,
    mensaje text
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_id         uuid := p_id;
    v_marca      text := nullif(btrim(coalesce(p_nombre_marca, '')), '');
    v_producto   text := nullif(btrim(coalesce(p_nombre_producto, '')), '');
    v_desc       text := nullif(btrim(coalesce(p_descripcion, '')), '');
    v_precio     text := nullif(btrim(coalesce(p_precio_texto, '')), '');
    v_foto       text := nullif(btrim(coalesce(p_foto_url, '')), '');
    v_whatsapp   text := regexp_replace(coalesce(p_whatsapp, ''), '\D', '', 'g');
    v_mensaje    text;
begin
    if not public.es_super_admin() then
        raise exception 'sin_permisos';
    end if;

    if v_marca is null then
        raise exception 'nombre_marca_requerido';
    end if;
    if v_producto is null then
        raise exception 'nombre_producto_requerido';
    end if;
    if length(v_whatsapp) < 8 or length(v_whatsapp) > 15 then
        raise exception 'whatsapp_invalido';
    end if;
    if v_foto is not null and v_foto !~* '^https?://' then
        raise exception 'foto_url_invalida';
    end if;
    if p_fecha_fin is null then
        raise exception 'fecha_fin_requerida';
    end if;

    if v_id is null then
        insert into public.marcas_aliadas (
            nombre_marca, nombre_producto, descripcion, precio_texto,
            foto_url, whatsapp_contacto, activo, fecha_fin
        )
        values (
            v_marca, v_producto, v_desc, v_precio,
            v_foto, v_whatsapp, coalesce(p_activo, true), p_fecha_fin
        )
        returning marcas_aliadas.id into v_id;

        v_mensaje := 'Marca creada.';
    else
        update public.marcas_aliadas m
           set nombre_marca      = v_marca,
               nombre_producto   = v_producto,
               descripcion       = v_desc,
               precio_texto      = v_precio,
               foto_url          = v_foto,
               whatsapp_contacto = v_whatsapp,
               activo            = coalesce(p_activo, m.activo),
               fecha_fin         = p_fecha_fin
         where m.id = v_id;

        if not found then
            raise exception 'marca_no_encontrada';
        end if;

        v_mensaje := 'Marca actualizada.';
    end if;

    return query select v_id, v_mensaje;
end $$;

comment on function public.admin_guardar_marca(uuid, text, text, text, text, text, text, date, boolean)
    is 'Crea (p_id null) o actualiza una marca aliada. Normaliza el WhatsApp a dígitos. Sólo SuperAdmin.';

grant execute on function public.admin_guardar_marca(uuid, text, text, text, text, text, text, date, boolean)
    to authenticated;


-- ============================================================================
-- 6 · RPC ADMIN: admin_toggle_marca_aliada()
-- ============================================================================
-- Activar / desactivar rápido desde la tabla, sin abrir el formulario.

create or replace function public.admin_toggle_marca_aliada(
    p_id     uuid,
    p_activo boolean
)
returns table (
    id      uuid,
    activo  boolean,
    mensaje text
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_activo boolean;
begin
    if not public.es_super_admin() then
        raise exception 'sin_permisos';
    end if;

    update public.marcas_aliadas m
       set activo = coalesce(p_activo, not m.activo)
     where m.id = p_id
     returning m.activo into v_activo;

    if not found then
        raise exception 'marca_no_encontrada';
    end if;

    return query
    select p_id, v_activo, case when v_activo then 'Marca activada.' else 'Marca desactivada.' end;
end $$;

comment on function public.admin_toggle_marca_aliada(uuid, boolean)
    is 'Activa o desactiva una marca aliada sin tocar el resto de los datos. Sólo SuperAdmin.';

grant execute on function public.admin_toggle_marca_aliada(uuid, boolean) to authenticated;


-- ============================================================================
-- 7 · Recargar el cache de esquema de PostgREST
-- ============================================================================

notify pgrst, 'reload schema';


-- ============================================================================
-- VERIFICACIÓN (opcional)
-- ============================================================================
-- -- 1) lectura pública (no requiere sesión; desde el SQL Editor no hay anon,
-- --    así que ahí puede devolver 0 filas si la tabla está vacía):
-- select * from public.obtener_marcas_aliadas();
--
-- -- 2) alta de ejemplo (como SuperAdmin, desde la app o con service_role):
-- select * from public.admin_guardar_marca(
--     null, 'Marca Demo', 'Esmalte semipermanente', 'Línea profesional 15 ml',
--     '$4.500', 'https://example.com/foto.jpg', '5491155554444',
--     current_date + 30, true
-- );
--
-- -- 3) listado del panel:
-- select * from public.admin_listar_marcas();
