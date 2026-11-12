-- ============================================================================
-- ELIMA HUB · I98 · CAMBIAR ROL OWNER/STAFF (SOLO SUPERADMIN)
--
-- Objetivo:
--   Permitir al SuperAdmin cambiar el rol de una membresía de un salón entre
--   'owner' y 'staff' desde el panel de Usuarios, sin tocar el mail ni el
--   user_id y sin pasar por el límite de plan.
--
-- Seguridad:
--   · admin_cambiar_rol() valida public.es_super_admin().
--   · security definer + set search_path: la escritura no depende de RLS.
--   · El trigger validar_plan_miembro() exime al SuperAdmin, así que el
--     cambio de rol no se bloquea por cupo del plan.
--   · Se registra la acción en auditoria_admin.
--
-- Requisitos: i48 (es_super_admin), i51 (auditoria_admin), i56 (trigger de
-- plan). Idempotente.
-- ============================================================================

-- ============================================================================
-- 1 · admin_todos_usuarios(): agregar el id de la membresía (m.id)
-- ============================================================================
-- El frontend necesita p_miembro_id para admin_cambiar_rol(). La función
-- devolvía solo el id de auth.users. Cambia la firma de retorno, así que hay
-- que recrearla (drop + create); no tiene dependencias de base.
drop function if exists public.admin_todos_usuarios();

create function public.admin_todos_usuarios()
returns table (
    id uuid, email text, creado_en timestamptz, ultimo_acceso timestamptz,
    salon_id uuid, salon_nombre text, rol text, activo boolean,
    miembro_id uuid
)
language plpgsql
security definer
set search_path = public, auth
as $$
begin
    if not public.es_super_admin() then
        raise exception 'sin_permisos' using errcode = '42501';
    end if;

    return query
        select u.id,
               u.email::text,
               u.created_at,
               u.last_sign_in_at,
               m.salon_id,
               s.nombre,
               m.rol,
               coalesce(m.activo, true),
               m.id
          from auth.users u
          left join public.miembros_salon m on m.user_id = u.id
          left join public.salones s on s.id = m.salon_id
         order by u.created_at desc;
end $$;

revoke all on function public.admin_todos_usuarios() from public;
grant execute on function public.admin_todos_usuarios() to authenticated;

-- ============================================================================
-- 2 · admin_cambiar_rol(): owner <-> staff, solo SuperAdmin
-- ============================================================================
create or replace function public.admin_cambiar_rol(
    p_miembro_id uuid,
    p_nuevo_rol text
)
returns table (
    id uuid,
    user_id uuid,
    salon_id uuid,
    rol text
)
language plpgsql
security definer
set search_path = public, auth
as $$
declare
    v_rol      text := lower(btrim(coalesce(p_nuevo_rol, '')));
    v_anterior public.miembros_salon%rowtype;
begin
    -- 1) Solo SuperAdmin
    if not public.es_super_admin() then
        raise exception 'sin_permisos' using errcode = '42501';
    end if;

    -- 2) Validar rol
    if v_rol not in ('owner', 'staff') then
        raise exception 'rol_invalido' using errcode = '22023';
    end if;

    -- 3) Buscar la membresía (id de miembros_salon, NO el user_id)
    select *
      into v_anterior
      from public.miembros_salon m
     where m.id = p_miembro_id;

    if not found then
        raise exception 'miembro_no_existe' using errcode = 'P0002';
    end if;

    -- No-op: mismo rol
    if v_anterior.rol = v_rol then
        return query
            select v_anterior.id, v_anterior.user_id, v_anterior.salon_id, v_anterior.rol;
        return;
    end if;

    -- 4) Actualizar SOLO el rol
    update public.miembros_salon m
       set rol = v_rol
     where m.id = p_miembro_id;

    -- 5) Auditoría
    insert into public.auditoria_admin (
        admin_id, salon_id, accion, detalle, origen
    ) values (
        auth.uid(),
        v_anterior.salon_id,
        'cambiar_rol',
        jsonb_build_object(
            'miembro_id', p_miembro_id,
            'user_id', v_anterior.user_id,
            'rol_anterior', v_anterior.rol,
            'rol_nuevo', v_rol
        ),
        'admin_usuarios'
    );

    return query
        select p_miembro_id, v_anterior.user_id, v_anterior.salon_id, v_rol;
end $$;

revoke all on function public.admin_cambiar_rol(uuid, text) from public;
grant execute on function public.admin_cambiar_rol(uuid, text) to authenticated;

-- ============================================================================
-- 3 · VERIFICACIÓN RÁPIDA
-- ============================================================================
-- select public.es_super_admin();
-- select * from public.admin_todos_usuarios() limit 5;  -- debe traer miembro_id
-- select * from public.admin_cambiar_rol(
--     (select id from public.miembros_salon where email = 'owner@qa-test.com' limit 1),
--     'owner'
-- );
