-- ============================================================================
-- ELI M. NAILS · I54 · Branding dinámico (Perfil del Salón)
--
-- La tarjeta de WhatsApp tenía los datos de Eli hardcodeados. Para que cada
-- salón tenga su propia identidad hacen falta estos datos:
--
--   nombre      → ya existía (salones.nombre)
--   logo_url    → ya existía (salones.logo_url)
--   telefono_contacto → NUEVA
--   instagram         → NUEVA
--   descripcion       → NUEVA (bio corta opcional para la tarjeta)
--
-- No toca RLS: la política de `salones` ya permite a la dueña del salón
-- hacer UPDATE de su propia fila y a los miembros hacer SELECT.
--
-- Idempotente: se puede correr varias veces.
-- ============================================================================


-- ============================================================================
-- 1 · COLUMNAS DE BRANDING
-- ============================================================================

alter table public.salones
    add column if not exists telefono_contacto text,
    add column if not exists instagram         text,
    add column if not exists descripcion       text;


-- ============================================================================
-- 2 · VALIDACIÓN SUAVE
--
-- Se permiten valores vacíos/null (el salón puede no tener teléfono público).
-- Lo que se evita es guardar basura: espacios, un Instagram con URL completa
-- o un arroba suelto.
-- ============================================================================

alter table public.salones
    drop constraint if exists salones_telefono_check;

alter table public.salones
    add constraint salones_telefono_check
    check (
        telefono_contacto is null
        or length(btrim(telefono_contacto)) between 4 and 32
    );

alter table public.salones
    drop constraint if exists salones_instagram_check;

alter table public.salones
    add constraint salones_instagram_check
    check (
        instagram is null
        or length(btrim(instagram)) between 1 and 60
    );

alter table public.salones
    drop constraint if exists salones_descripcion_check;

alter table public.salones
    add constraint salones_descripcion_check
    check (
        descripcion is null
        or length(btrim(descripcion)) <= 160
    );


-- ============================================================================
-- 3 · NORMALIZAR
--
-- Deja los datos prolijos antes de que los use el canvas:
--   +54 9 11 1234-5678  →  +5491112345678   (solo dígitos y +)
--   @Eli.Nails / https://instagram.com/eli.nails  →  @eli.nails
-- ============================================================================

create or replace function public.normalizar_branding()
returns trigger
language plpgsql
as $$
declare
    v_tel text;
    v_ig  text;
begin
    -- teléfono
    v_tel := nullif(btrim(coalesce(NEW.telefono_contacto, '')), '');
    if v_tel is not null then
        -- se sacan espacios, guiones, paréntesis y puntos
        v_tel := regexp_replace(v_tel, '[^0-9+]', '', 'g');
        -- un solo + y solo al principio
        if v_tel like '+%' then
            v_tel := '+' || regexp_replace(substring(v_tel from 2), '[^0-9]', '', 'g');
        else
            v_tel := regexp_replace(v_tel, '[^0-9]', '', 'g');
        end if;
        NEW.telefono_contacto := nullif(v_tel, '');
    else
        NEW.telefono_contacto := null;
    end if;

    -- instagram
    v_ig := nullif(btrim(coalesce(NEW.instagram, '')), '');
    if v_ig is not null then
        -- si pegaron la URL completa, nos quedamos con el usuario
        v_ig := regexp_replace(v_ig, '^https?://(www\.)?instagram\.com/', '', 'i');
        v_ig := regexp_replace(v_ig, '[?#].*$', '');
        v_ig := btrim(v_ig, '/');
        v_ig := regexp_replace(v_ig, '^@+', '');
        NEW.instagram := nullif(v_ig, '');
    else
        NEW.instagram := null;
    end if;

    -- descripción
    NEW.descripcion := nullif(btrim(coalesce(NEW.descripcion, '')), '');

    return NEW;
end $$;

drop trigger if exists trg_normalizar_branding on public.salones;
create trigger trg_normalizar_branding
before insert or update of telefono_contacto, instagram, descripcion on public.salones
for each row execute function public.normalizar_branding();


-- ============================================================================
-- 4 · NORMALIZAR LO QUE YA EXISTE
-- (por si algún salón ya tenía datos cargados a mano)
-- ============================================================================

update public.salones
   set telefono_contacto = telefono_contacto
 where telefono_contacto is not null;

update public.salones
   set instagram = instagram
 where instagram is not null;


-- ============================================================================
-- 5 · RPC DE LECTURA PÚBLICA DEL BRANDING (opcional)
--
-- La app ya lee `salones` con la política por pertenencia. Esta RPC sirve si
-- en algún momento hace falta mostrar el branding sin sesión (ej. una landing
-- o el link público de reserva). Devuelve SOLO datos de marca, nada sensible.
-- ============================================================================

create or replace function public.salon_branding(p_salon uuid)
returns table (
    nombre            text,
    logo_url          text,
    telefono_contacto text,
    instagram         text,
    descripcion       text
)
language sql
security definer
set search_path = public
as $$
    select s.nombre,
           s.logo_url,
           s.telefono_contacto,
           s.instagram,
           s.descripcion
      from public.salones s
     where s.id = p_salon
       and s.activo;
$$;

grant execute on function public.salon_branding(uuid) to anon, authenticated;


notify pgrst, 'reload schema';

-- ============================================================================
-- VERIFICACIÓN
-- ============================================================================
-- 1) columnas creadas
-- select column_name, data_type
--   from information_schema.columns
--  where table_schema = 'public' and table_name = 'salones'
--    and column_name in ('nombre','logo_url','telefono_contacto','instagram','descripcion');
--
-- 2) normalización funcionando (debe guardarse '+5491112345678' y '@eli.nails')
-- update public.salones
--    set telefono_contacto = '+54 9 11 1234-5678',
--        instagram = 'https://instagram.com/Eli.Nails/'
--  where id = (select id from public.salones limit 1);
--
-- select nombre, telefono_contacto, instagram from public.salones limit 5;
--
-- 3) branding por salón
-- select * from public.salon_branding((select id from public.salones limit 1));
