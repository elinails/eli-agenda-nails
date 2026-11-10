-- ============================================================================
-- ELI M. NAILS · I68 · Storage logos (logo + portada)
--
-- Problema: el I50 borró las políticas legacy del bucket `logos` y no creó
-- las nuevas → el upload de la dueña devolvía 403 y quedaba el monograma.
--
-- Solución: bucket público para getPublicUrl + lectura pública y escritura
-- SOLO para la dueña del salón dueño de la carpeta (carpeta = salon_id).
--
-- Idempotente. Aplicar en el SQL Editor o por Management API.
-- ============================================================================

-- 1) Bucket público (para que <img src=getPublicUrl> cargue)
update storage.buckets set public = true where id = 'logos';

-- 2) Quitar legacy (por si el I50 no se aplicó)
drop policy if exists "Permitir ver logos"        on storage.objects;
drop policy if exists "Permitir subir logos"      on storage.objects;
drop policy if exists "Permitir actualizar logos" on storage.objects;

-- 3) Lectura pública del bucket
drop policy if exists "logos_lectura" on storage.objects;
create policy "logos_lectura" on storage.objects
for select to anon, authenticated
using (bucket_id = 'logos');

-- 4) Escritura: solo la dueña del salón de la carpeta
--    (la carpeta se valida como uuid antes del cast, para no romper con
--     rutas viejas del tipo `logo.png` en la raíz)
drop policy if exists "logos_owner_insert" on storage.objects;
create policy "logos_owner_insert" on storage.objects
for insert to authenticated
with check (
  bucket_id = 'logos'
  and public.es_owner(
    case
      when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then ((storage.foldername(name))[1])::uuid
      else null
    end
  )
);

drop policy if exists "logos_owner_update" on storage.objects;
create policy "logos_owner_update" on storage.objects
for update to authenticated
using (
  bucket_id = 'logos'
  and public.es_owner(
    case
      when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then ((storage.foldername(name))[1])::uuid
      else null
    end
  )
)
with check (
  bucket_id = 'logos'
  and public.es_owner(
    case
      when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then ((storage.foldername(name))[1])::uuid
      else null
    end
  )
);

drop policy if exists "logos_owner_delete" on storage.objects;
create policy "logos_owner_delete" on storage.objects
for delete to authenticated
using (
  bucket_id = 'logos'
  and public.es_owner(
    case
      when (storage.foldername(name))[1] ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      then ((storage.foldername(name))[1])::uuid
      else null
    end
  )
);

notify pgrst, 'reload schema';

-- ============================================================================
-- VERIFICACIÓN
-- ============================================================================
-- select policyname, cmd, roles, qual, with_check
--   from pg_policies
--  where schemaname='storage' and tablename='objects'
--    and policyname like 'logos_%';
--
-- select id, name, public from storage.buckets where id='logos';
