-- ============================================================================
-- ELIMA HUB · I97 · SEED QA DE PLANES (NO ES UNA MIGRACIÓN)
--
-- Objetivo:
--   Crear 3 cuentas de prueba con sus salones, uno por plan:
--     · owner@qa-test.com          → plan gratis
--     · owner-pro@qa-test.com      → plan pro
--     · owner-premium@qa-test.com  → plan premium
--
--   Los 3 salones quedan con el perfil INCOMPLETO a propósito:
--     nombre y rubro cargados; logo_url, bio, foto_portada_url, slug y
--     dirección en NULL. Así el banner de perfil incompleto debe aparecer
--     en los 3 planes.
--
--   El plan NO exceptúa del perfil completo: la regla es la misma para
--   Gratis, Pro y Premium.
--
-- CREDENCIALES QA (solo prueba):
--   password: QaTest!2026
--
-- SEGURIDAD:
--   · Solo toca emails @qa-test.com y los IDs fijos 97000000-….
--   · No borra ni modifica usuarios/salones reales.
--   · Idempotente: se puede correr varias veces.
--
-- NOTA:
--   En el proyecto alojado, las cuentas QA también pueden crearse con la
--   Admin API (auth.admin.createUser). Este SQL deja el seed reproducible
--   desde el SQL Editor: inserta auth.users + auth.identities + salones +
--   miembros_salon en una sola transacción lógica.
--
-- LIMPIEZA (opcional):
--   Ejecutar el bloque DELETE del inicio sin el resto, o borrar las cuentas
--   desde Authentication → Users (solo las @qa-test.com).
-- ============================================================================

do $$
declare
    v_password text := 'QaTest!2026';
    v record;
begin
    -- ---------------------------------------------------------------------
    -- 0 · Limpieza SOLO de QA (por email y por IDs fijos)
    -- ---------------------------------------------------------------------
    delete from public.miembros_salon
     where salon_id in (
             '97000000-0000-4000-8000-000000000001'::uuid,
             '97000000-0000-4000-8000-000000000002'::uuid,
             '97000000-0000-4000-8000-000000000003'::uuid
           )
        or lower(email) in (
             'owner@qa-test.com',
             'owner-pro@qa-test.com',
             'owner-premium@qa-test.com'
           );

    delete from public.salones
     where id in (
             '97000000-0000-4000-8000-000000000001'::uuid,
             '97000000-0000-4000-8000-000000000002'::uuid,
             '97000000-0000-4000-8000-000000000003'::uuid
           );

    delete from auth.identities
     where user_id in (
             select id from auth.users
              where lower(email) in (
                      'owner@qa-test.com',
                      'owner-pro@qa-test.com',
                      'owner-premium@qa-test.com'
                    )
           );

    delete from auth.users
     where lower(email) in (
             'owner@qa-test.com',
             'owner-pro@qa-test.com',
             'owner-premium@qa-test.com'
           );

    -- ---------------------------------------------------------------------
    -- 1 · Cuentas + salones + membresías
    -- ---------------------------------------------------------------------
    for v in
        select *
          from (values
                ('97100000-0000-4000-8000-000000000001'::uuid,
                 'owner@qa-test.com',
                 'gratis',
                 '97000000-0000-4000-8000-000000000001'::uuid,
                 'QA Salón Gratis'),
                ('97100000-0000-4000-8000-000000000002'::uuid,
                 'owner-pro@qa-test.com',
                 'pro',
                 '97000000-0000-4000-8000-000000000002'::uuid,
                 'QA Salón Pro'),
                ('97100000-0000-4000-8000-000000000003'::uuid,
                 'owner-premium@qa-test.com',
                 'premium',
                 '97000000-0000-4000-8000-000000000003'::uuid,
                 'QA Salón Premium')
               ) as t(uid, email, plan, salon_id, nombre)
    loop
        -- Cuenta de Authentication (email confirmado, password bcrypt)
        insert into auth.users (
            instance_id, id, aud, role, email, encrypted_password,
            email_confirmed_at, recovery_sent_at, last_sign_in_at,
            raw_app_meta_data, raw_user_meta_data,
            created_at, updated_at,
            confirmation_token, email_change, email_change_token_new,
            recovery_token
        ) values (
            '00000000-0000-0000-0000-000000000000'::uuid,
            v.uid,
            'authenticated',
            'authenticated',
            v.email,
            extensions.crypt(v_password, extensions.gen_salt('bf')),
            now(), null, null,
            jsonb_build_object('provider', 'email', 'providers', jsonb_build_array('email')),
            jsonb_build_object('nombre', v.nombre, 'qa', true),
            now(), now(),
            '', '', '', ''
        );

        -- Identidad email para que el login email/password funcione
        insert into auth.identities (
            id, provider_id, user_id, identity_data, provider,
            last_sign_in_at, created_at, updated_at
        ) values (
            gen_random_uuid(),
            v.email,
            v.uid,
            jsonb_build_object(
                'sub', v.uid::text,
                'email', v.email,
                'email_verified', true
            ),
            'email',
            now(), now(), now()
        );

        -- Salón con perfil INCOMPLETO (logo, bio, portada, slug y dirección null)
        insert into public.salones (
            id, nombre, dueno_user_id, activo, plan_id, estado_suscripcion,
            trial_hasta, suscripcion_desde, cancelada_en,
            telefono_contacto, instagram, descripcion,
            rubro, bio, foto_portada_url, slug, publicado, direccion
        ) values (
            v.salon_id,
            v.nombre,
            v.uid,
            true,
            v.plan,
            'active',
            null,
            now(),
            null,
            null, null, null,
            'nails',
            null, null, null,
            false,
            null
        );

        -- Membresía owner (la que lee cargarMembresia)
        insert into public.miembros_salon (
            salon_id, user_id, rol, nombre, email, activo
        ) values (
            v.salon_id,
            v.uid,
            'owner',
            v.nombre,
            v.email,
            true
        );
    end loop;
end $$;

-- ============================================================================
-- Verificación rápida (3 filas, planes gratis/pro/premium, publicado=false)
-- ============================================================================
-- select s.id, s.nombre, s.plan_id, s.estado_suscripcion, s.publicado,
--        s.logo_url, s.bio, s.foto_portada_url, s.slug, s.direccion,
--        m.email as owner
--   from public.salones s
--   join public.miembros_salon m
--     on m.salon_id = s.id and m.rol = 'owner'
--  where s.id in (
--          '97000000-0000-4000-8000-000000000001',
--          '97000000-0000-4000-8000-000000000002',
--          '97000000-0000-4000-8000-000000000003'
--        )
--  order by s.plan_id;
