-- ============================================================================
-- ELIMA HUB · I95 · PERFIL COMPLETO OBLIGATORIO PARA PUBLICAR (backend)
--
-- Hasta ahora la validación vivía sólo en el navegador: cualquiera podía
-- publicar un salón incompleto llamando la API directo, y eso genera tarjetas
-- rotas en el Marketplace.
--
-- Este trigger valida EN LA BASE que, al quedar publicado, el salón tenga
-- nombre, rubro, bio, slug, direccion, foto_portada_url y logo_url.
--
-- REGLAS (para no romper salones existentes):
--   · publicado = false            -> nunca frena (borrador).
--   · INSERT con publicado = true  -> valida.
--   · UPDATE false -> true         -> valida (es el momento de publicar).
--   · UPDATE con perfil editado    -> valida.
--   · Otros UPDATE sobre un salón  -> NO valida (así un salón viejo publicado
--     ya publicado pero incompleto     e incompleto puede seguir cambiando
--                                      plan, activo, etc. sin trabas).
--
-- IDEMPOTENTE: create or replace + drop trigger if exists.
-- REQUISITOS: i54 (logo), i62 (rubro, bio, slug, publicado), i69 (direccion).
-- ============================================================================


-- ============================================================================
-- 0 · PRE-CHECK de columnas (falla claro si falta alguna migración)
-- ============================================================================

do $$
declare
    v_falta text;
begin
    if to_regclass('public.salones') is null then
        raise exception 'Falta el esquema base (no existe public.salones)';
    end if;

    select string_agg(c, ', ' order by c)
      into v_falta
      from unnest(array[
            'publicado', 'nombre', 'rubro', 'bio', 'slug',
            'direccion', 'foto_portada_url', 'logo_url'
           ]) as c
     where not exists (
            select 1
              from information_schema.columns
             where table_schema = 'public'
               and table_name = 'salones'
               and column_name = c
           );

    if v_falta is not null then
        raise exception 'Faltan columnas en public.salones: %. Aplicá i54, i62 e i69 antes de i95.', v_falta;
    end if;
end $$;


-- ============================================================================
-- 1 · FUNCIÓN DE TRIGGER
-- ============================================================================
-- El mensaje de la excepción es EXACTAMENTE el acordado; los campos que
-- faltan viajan en DETAIL para no romper el contrato con el frontend.

create or replace function public.salones_validar_perfil_publicado()
returns trigger
language plpgsql
set search_path = public
as $$
declare
    v_faltantes text[] := '{}';
    v_revisar   boolean := false;
begin
    -- Borrador: nunca se frena.
    if coalesce(new.publicado, false) is not true then
        return new;
    end if;

    if tg_op = 'INSERT' then
        v_revisar := true;
    else
        -- Se está publicando ahora.
        if coalesce(old.publicado, false) is not true then
            v_revisar := true;
        -- O se está editando el perfil de un salón que ya estaba publicado.
        elsif new.nombre           is distinct from old.nombre
           or new.rubro            is distinct from old.rubro
           or new.bio              is distinct from old.bio
           or new.slug             is distinct from old.slug
           or new.direccion        is distinct from old.direccion
           or new.foto_portada_url is distinct from old.foto_portada_url
           or new.logo_url         is distinct from old.logo_url then
            v_revisar := true;
        end if;
    end if;

    -- Cambios que no tocan el perfil (plan, activo, etc.): se dejan pasar.
    if not v_revisar then
        return new;
    end if;

    if nullif(btrim(coalesce(new.nombre, '')), '') is null then
        v_faltantes := array_append(v_faltantes, 'nombre');
    end if;
    if nullif(btrim(coalesce(new.rubro, '')), '') is null then
        v_faltantes := array_append(v_faltantes, 'rubro');
    end if;
    if nullif(btrim(coalesce(new.bio, '')), '') is null then
        v_faltantes := array_append(v_faltantes, 'bio');
    end if;
    if nullif(btrim(coalesce(new.slug, '')), '') is null then
        v_faltantes := array_append(v_faltantes, 'slug');
    end if;
    if nullif(btrim(coalesce(new.direccion, '')), '') is null then
        v_faltantes := array_append(v_faltantes, 'direccion');
    end if;
    if nullif(btrim(coalesce(new.foto_portada_url, '')), '') is null then
        v_faltantes := array_append(v_faltantes, 'foto_portada_url');
    end if;
    if nullif(btrim(coalesce(new.logo_url, '')), '') is null then
        v_faltantes := array_append(v_faltantes, 'logo_url');
    end if;

    if array_length(v_faltantes, 1) is not null then
        raise exception 'perfil_incompleto: Faltan datos obligatorios para publicar'
            using errcode = 'check_violation',
                  detail  = 'Salón ' ||
                            coalesce(
                                nullif(btrim(coalesce(new.nombre, '')), ''),
                                nullif(btrim(coalesce(new.slug, '')), ''),
                                new.id::text
                            ) ||
                            ' — campos faltantes: ' || array_to_string(v_faltantes, ', '),
                  hint    = 'Completá todos los datos en Ajustes → Mi Salón antes de publicar.';
    end if;

    return new;
end $$;

comment on function public.salones_validar_perfil_publicado()
    is 'Bloquea publicar un salón si falta algún dato obligatorio del perfil (I95).';


-- ============================================================================
-- 2 · TRIGGER
-- ============================================================================

drop trigger if exists trg_salones_perfil_publicado on public.salones;

create trigger trg_salones_perfil_publicado
    before insert or update on public.salones
    for each row
    execute function public.salones_validar_perfil_publicado();


-- ============================================================================
-- 3 · Recargar el cache de esquema de PostgREST
-- ============================================================================

notify pgrst, 'reload schema';


-- ============================================================================
-- VERIFICACIÓN
-- ============================================================================
-- -- 1) el trigger quedó instalado:
-- select tgname, tgenabled
--   from pg_trigger
--  where tgrelid = 'public.salones'::regclass
--    and tgname = 'trg_salones_perfil_publicado';
--
-- -- 2) salones YA publicados a los que les falta algo (no se tocan: sólo se
-- --    listan para que los completes antes de que editen el perfil):
-- select s.id, s.nombre,
--        concat_ws(', ',
--            case when nullif(btrim(coalesce(s.nombre,'')),'') is null then 'nombre' end,
--            case when nullif(btrim(coalesce(s.rubro,'')),'') is null then 'rubro' end,
--            case when nullif(btrim(coalesce(s.bio,'')),'') is null then 'bio' end,
--            case when nullif(btrim(coalesce(s.slug,'')),'') is null then 'slug' end,
--            case when nullif(btrim(coalesce(s.direccion,'')),'') is null then 'direccion' end,
--            case when nullif(btrim(coalesce(s.foto_portada_url,'')),'') is null then 'foto_portada_url' end,
--            case when nullif(btrim(coalesce(s.logo_url,'')),'') is null then 'logo_url' end
--        ) as faltantes
--   from public.salones s
--  where s.publicado = true
--  order by s.nombre;
--
-- -- 3) salones PENDIENTES a los que les falta algo: el panel NO va a poder
-- --    aprobarlos hasta que la dueña complete el perfil.
-- select s.id, s.nombre
--   from public.salones s
--  where s.publicado is not true
--    and (
--          nullif(btrim(coalesce(s.nombre,'')),'') is null
--       or nullif(btrim(coalesce(s.rubro,'')),'') is null
--       or nullif(btrim(coalesce(s.bio,'')),'') is null
--       or nullif(btrim(coalesce(s.slug,'')),'') is null
--       or nullif(btrim(coalesce(s.direccion,'')),'') is null
--       or nullif(btrim(coalesce(s.foto_portada_url,'')),'') is null
--       or nullif(btrim(coalesce(s.logo_url,'')),'') is null
--    )
--  order by s.nombre;
--
-- -- 4) prueba del trigger (debe fallar con perfil_incompleto):
-- --    (usá un salón de prueba, NO uno real)
-- -- update public.salones set publicado = true, direccion = null where id = '<salon-id>';
