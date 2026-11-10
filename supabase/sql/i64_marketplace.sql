-- ============================================================================
-- ELI M. NAILS · I64 · Marketplace público + auditoría de publicación
--
-- 1) public_marketplace_salones(): lectura pública del marketplace.
--    Devuelve SOLO datos públicos y agregados de reseñas.
-- 2) Auditoría de aprobación/despublicación de perfiles.
--
-- REQUISITOS: i62_elima_belleza.sql aplicado
--             (columnas rubro, bio, foto_portada_url, slug, publicado;
--              tabla resenas; trigger trg_proteger_publicado).
--
-- IDEMPOTENTE: se puede correr varias veces.
-- ============================================================================


-- ============================================================================
-- 1 · RPC PÚBLICA DEL MARKETPLACE
--
-- Regla de oro: no devuelve id, dueno_user_id, email de la dueña, plan,
-- suscripción, turnos, clientes ni reseñas individuales. Solo los campos
-- públicos del salón y agregados (cantidad y promedio de estrellas).
-- ============================================================================

create or replace function public.public_marketplace_salones(
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
    promedio_estrellas numeric
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
        coalesce(rev.promedio_estrellas, 0) as promedio_estrellas
    from public.salones s
    left join lateral (
        select
            count(*)::bigint as count_resenas,
            round(avg(r.estrellas)::numeric, 1) as promedio_estrellas
        from public.resenas r
        where r.salon_id = s.id
    ) rev on true
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
    is 'Marketplace Elima Belleza: salones publicados y activos; solo datos públicos y agregados de reseñas.';

revoke all on function public.public_marketplace_salones(text, text) from public;
grant execute on function public.public_marketplace_salones(text, text) to anon, authenticated;


-- ============================================================================
-- 2 · AUDITORÍA DE APROBACIÓN / DESPUBLICACIÓN
--
-- El trigger existente trg_auditar_salones no registra cambios de publicado:
-- los clasifica como "salon_editado" y sale sin insertar. Este trigger
-- específico deja rastro de quién aprobó o despublicó un perfil.
-- ============================================================================

create or replace function public.auditar_publicacion_salon()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.publicado is distinct from old.publicado then
        insert into public.auditoria_admin (admin_id, salon_id, accion, detalle)
        values (
            auth.uid(),
            new.id,
            case
                when new.publicado then 'salon_publicado'
                else 'salon_despublicado'
            end,
            jsonb_build_object(
                'publicado_anterior', old.publicado,
                'publicado_nuevo', new.publicado,
                'slug', new.slug,
                'rubro', new.rubro
            )
        );
    end if;
    return new;
end $$;

drop trigger if exists trg_auditar_publicacion on public.salones;
create trigger trg_auditar_publicacion
after update of publicado on public.salones
for each row execute function public.auditar_publicacion_salon();


-- ============================================================================
-- 3 · RECARGA DE CACHÉ DE POSTGREST
-- ============================================================================

notify pgrst, 'reload schema';


-- ============================================================================
-- VERIFICACIÓN (después de correr)
-- ============================================================================
--
-- 1) La RPC existe y anon puede ejecutarla:
-- select has_function_privilege(
--          'anon',
--          'public.public_marketplace_salones(text,text)',
--          'execute'
--        );
--
-- 2) Sin filtros (solo salones publicados, activos, con slug y rubro):
-- select * from public.public_marketplace_salones();
--
-- 3) Filtros:
-- select * from public.public_marketplace_salones('nails');
-- select * from public.public_marketplace_salones(null, 'eli');
-- select * from public.public_marketplace_salones('rubro_invalido'); -- 0 filas
--
-- 4) La respuesta no debe tener columnas privadas:
-- select * from public.public_marketplace_salones() limit 0;
--    → slug, nombre, rubro, bio, foto_portada_url, instagram, logo_url,
--      count_resenas, promedio_estrellas.
--
-- 5) Trigger de auditoría:
-- select tgname from pg_trigger where tgname = 'trg_auditar_publicacion';
--
-- 6) Prueba de publicación (con un salón de prueba):
-- update public.salones set publicado = true where id = 'PEGA-UUID';
-- select accion, detalle from public.auditoria_admin
--  order by creado_en desc limit 1;
--    → accion = 'salon_publicado' y detalle con publicado_anterior/nuevo.
--
-- 7) La dueña no puede auto-publicarse (debe fallar con solo_admin_publica):
-- update public.salones set publicado = true where id = 'PEGA-UUID';
-- ============================================================================
