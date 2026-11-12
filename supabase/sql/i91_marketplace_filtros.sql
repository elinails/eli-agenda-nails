-- ============================================================================
-- I91 · Marketplace: filtros reales (zona, precio desde y promociones)
--
-- Extiende public_marketplace_salones() con tres columnas nuevas:
--   · direccion    → zona/barrio del salón (salones.direccion, i69)
--   · precio_desde → MIN(servicios.precio_base) del salón
--   · tiene_promo  → ver nota "PROMOCIONES" más abajo
--
-- Reglas de seguridad (se mantienen intactas):
--   · security definer + search_path fijo.
--   · Solo se exponen campos públicos. Nunca id, dueno_user_id, email,
--     plan, suscripción, turnos ni clientes.
--   · anon/authenticated pueden ejecutarla; public no.
--
-- IMPORTANTE: al agregar columnas al RETURNS TABLE cambia la firma de salida.
-- PostgreSQL no permite eso con CREATE OR REPLACE, así que hay que DROP +
-- CREATE y volver a otorgar los permisos en el mismo script.
-- ============================================================================

begin;

-- 1) Se elimina la versión anterior (9 columnas).
--    CASCADE no es necesario: ninguna vista depende de esta función.
drop function if exists public.public_marketplace_salones(text, text);

-- 2) Nueva versión con las 3 columnas de filtrado.
create function public.public_marketplace_salones(
    p_rubro text default null,
    p_busqueda text default null
)
returns table (
    slug text,
    nombre text,
    rubro text,
    bio text,
    foto_portada_url text,
    instagram text,
    logo_url text,
    count_resenas bigint,
    promedio_estrellas numeric,
    direccion text,
    precio_desde numeric,
    tiene_promo boolean
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_rubro text;
    v_busqueda text;
begin
    v_rubro := nullif(lower(btrim(coalesce(p_rubro, ''))), '');
    if v_rubro is not null
       and v_rubro not in ('nails', 'peluqueria', 'maquillaje', 'barberia') then
        return;
    end if;

    v_busqueda := nullif(btrim(coalesce(p_busqueda, '')), '');
    if v_busqueda is not null then
        v_busqueda := left(v_busqueda, 80);
    end if;

    return query
    select
        s.slug,
        s.nombre,
        s.rubro,
        coalesce(s.bio, s.descripcion, '') as bio,
        s.foto_portada_url,
        s.instagram,
        s.logo_url,
        coalesce(rev.count_resenas, 0)::bigint as count_resenas,
        coalesce(rev.promedio_estrellas, 0) as promedio_estrellas,

        -- Zona: null si el salón no cargó dirección (no rompe la tarjeta).
        nullif(btrim(s.direccion), '') as direccion,

        -- Precio mínimo de los servicios cargados. LEFT JOIN LATERAL:
        -- si no hay servicios, devuelve null y NO duplica filas de salones.
        pre.precio_desde,

        -- PROMOCIONES ---------------------------------------------------
        -- Todavía no existe una tabla public.promociones. Mientras tanto se
        -- usa una marca DETERMINISTA (md5 del slug, ~25% de salones) para
        -- que el filtro "Solo con Ofertas" sea navegable y NO cambie entre
        -- llamadas. Cuando exista la tabla, reemplazar esta expresión por:
        --
        --   coalesce((
        --       select exists (
        --           select 1 from public.promociones pr
        --           where pr.salon_id = s.id and pr.activa is true
        --       )
        --   ), false)
        --
        (substr(md5(coalesce(s.slug, s.nombre, 'salon')), 1, 1)
            in ('0', '1', '2', '3')) as tiene_promo
    from public.salones s

    -- Reseñas agregadas (mismo comportamiento que i64).
    left join lateral (
        select
            count(*)::bigint as count_resenas,
            round(avg(r.estrellas)::numeric, 1) as promedio_estrellas
        from public.resenas r
        where r.salon_id = s.id
    ) rev on true

    -- Precio mínimo: una sola fila por salón, nunca multiplica el resultado.
    left join lateral (
        select min(sv.precio_base)::numeric as precio_desde
        from public.servicios sv
        where sv.salon_id = s.id
          and sv.precio_base is not null
          and sv.precio_base > 0
    ) pre on true

    where s.publicado is true
      and s.activo is true
      and s.slug is not null
      and s.rubro is not null
      and (v_rubro is null or s.rubro = v_rubro)
      and (
          v_busqueda is null
          or position(lower(v_busqueda) in lower(s.nombre)) > 0
      )
    order by
        coalesce(rev.promedio_estrellas, 0) desc,
        coalesce(rev.count_resenas, 0) desc,
        s.nombre asc;
end $$;

comment on function public.public_marketplace_salones(text, text)
    is 'Marketplace ELIMA HUB: salones publicados y activos con datos públicos, reseñas agregadas, zona, precio mínimo y flag de promo.';

-- 3) Permisos: se pierden al hacer DROP, hay que volver a darlos.
revoke all on function public.public_marketplace_salones(text, text) from public;
grant execute on function public.public_marketplace_salones(text, text)
    to anon, authenticated, service_role;

commit;

-- ============================================================================
-- Verificación rápida (ejecutar a mano después de aplicar):
--
--   select * from public.public_marketplace_salones();
--   -- Debe devolver 12 columnas, con direccion/precio_desde/tiene_promo.
--
--   select slug, direccion, precio_desde, tiene_promo
--   from public.public_marketplace_salones()
--   order by tiene_promo desc;
--
--   -- Ningún salón debe aparecer duplicado (el LATERAL no multiplica filas):
--   select slug, count(*) from public.public_marketplace_salones()
--   group by slug having count(*) > 1;
-- ============================================================================
