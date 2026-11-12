-- ============================================================================
-- ELIMA HUB · I99 · Foto de portada OPCIONAL
--
-- Contexto: la dueña tenía fricción al subir la foto de portada y el trigger
-- de I95 le bloqueaba la publicación si faltaba. Decisión de producto: la
-- portada deja de ser obligatoria. Si no hay foto, el frontend muestra un
-- degradado con el logo (clase .portada-default).
--
-- Campos obligatorios para publicar (después de este script):
--     nombre · rubro · bio · slug · direccion · logo_url
--
-- Ya NO se exige: foto_portada_url
--
-- IDEMPOTENTE: create or replace, se puede correr varias veces.
-- REQUIERE: i95_validacion_perfil_completo.sql (crea el trigger original).
-- ============================================================================

begin;


-- ============================================================================
-- 1 · Función de validación sin la portada
-- ============================================================================

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
        -- I99: foto_portada_url sale de esta lista: cambiarla (o no tenerla)
        -- ya no dispara una revalidación del resto del perfil.
        elsif new.nombre    is distinct from old.nombre
           or new.rubro     is distinct from old.rubro
           or new.bio       is distinct from old.bio
           or new.slug      is distinct from old.slug
           or new.direccion is distinct from old.direccion
           or new.logo_url  is distinct from old.logo_url then
            v_revisar := true;
        end if;
    end if;

    -- Cambios que no tocan el perfil (plan, activo, portada, etc.): pasan.
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
    -- I99: la foto de portada ya NO se valida.
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
    is 'Bloquea publicar un salón si falta algún dato obligatorio del perfil. I99: la foto de portada es opcional.';


-- ============================================================================
-- 2 · Trigger (se recrea por claridad; ya apunta a la función actualizada)
-- ============================================================================

drop trigger if exists trg_salones_perfil_publicado on public.salones;
create trigger trg_salones_perfil_publicado
    before insert or update of publicado, nombre, rubro, bio, slug, direccion, logo_url
    on public.salones
    for each row
    execute function public.salones_validar_perfil_publicado();


commit;

notify pgrst, 'reload schema';


-- ============================================================================
-- VERIFICACIÓN (opcional)
-- ============================================================================
-- -- 1) Un salón publicado sin portada debe poder guardarse:
-- update public.salones
--    set foto_portada_url = null
--  where slug = '<tu-slug>';
--
-- -- 2) Pero publicar sin logo sigue frenando:
-- update public.salones
--    set logo_url = null, publicado = true
--  where slug = '<tu-slug>';
-- -- Esperado: error perfil_incompleto con detail "campos faltantes: logo_url"
--
-- -- 3) Ver el trigger activo:
-- select tgname, pg_get_triggerdef(oid)
--   from pg_trigger
--  where tgrelid = 'public.salones'::regclass
--    and tgname = 'trg_salones_perfil_publicado';
-- ============================================================================
