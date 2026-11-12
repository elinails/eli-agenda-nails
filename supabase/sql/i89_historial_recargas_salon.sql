-- ============================================================================
-- ELIMA HUB · I89 · HISTORIAL DE RECARGAS DEL SALÓN
--
-- La dueña necesita saber qué pasó con cada transferencia que notificó:
-- si está pendiente, si se aprobó o si se rechazó (y por qué).
--
-- Sólo LECTURA. Devuelve únicamente las recargas DEL salón pedido y valida
-- que el usuario pertenezca a ese salón (o sea SuperAdmin en modo soporte).
--
-- IDEMPOTENTE: create or replace, se puede correr varias veces.
-- REQUISITOS: i87_recargas_puntos.sql (recargas_puntos) e i48 (es_super_admin).
-- ============================================================================


-- ============================================================================
-- 0 · PRE-CHECK
-- ============================================================================

do $$
begin
    if to_regclass('public.recargas_puntos') is null then
        raise exception 'Falta i87_recargas_puntos.sql (no existe recargas_puntos)';
    end if;
end $$;


-- ============================================================================
-- 1 · RPC: obtener_mis_recargas(p_salon_id uuid)
-- ============================================================================
-- Devuelve el historial completo (pendientes, aprobadas y rechazadas) del
-- salón, la más reciente primero. Tope de 50 filas: alcanza para el uso real
-- y evita respuestas gigantes. Si p_salon_id viene null se deduce de la
-- membresía activa del usuario.
--
-- Códigos de error: sin_sesion, sin_salon, sin_permisos.

create or replace function public.obtener_mis_recargas(p_salon_id uuid)
returns table (
    id                  uuid,
    fecha               timestamptz,
    monto_ars           numeric,
    puntos_equivalentes numeric,
    estado              text,
    motivo_rechazo      text
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_user  uuid := auth.uid();
    v_salon uuid := p_salon_id;
begin
    if v_user is null then
        raise exception 'sin_sesion';
    end if;

    if v_salon is null then
        select m.salon_id into v_salon
        from public.miembros_salon m
        where m.user_id = v_user and coalesce(m.activo, true)
        order by m.creado_en
        limit 1;
    end if;

    if v_salon is null then
        raise exception 'sin_salon';
    end if;

    -- Validación de pertenencia: miembro activo del salón o SuperAdmin.
    if not public.es_super_admin() then
        if not exists (
            select 1
            from public.miembros_salon m
            where m.salon_id = v_salon
              and m.user_id = v_user
              and coalesce(m.activo, true)
        ) then
            raise exception 'sin_permisos';
        end if;
    end if;

    return query
    select
        r.id,
        r.creado_en                              as fecha,
        r.monto_ars,
        r.puntos_equivalentes,
        r.estado,
        coalesce(r.motivo_rechazo, '')           as motivo_rechazo
    from public.recargas_puntos r
    where r.salon_id = v_salon
    order by r.creado_en desc
    limit 50;
end $$;

comment on function public.obtener_mis_recargas(uuid)
    is 'Historial de recargas del salón (más reciente primero). Valida que el usuario pertenezca al salón.';

grant execute on function public.obtener_mis_recargas(uuid) to authenticated;


-- ============================================================================
-- 2 · Recargar el cache de esquema de PostgREST
-- ============================================================================

notify pgrst, 'reload schema';


-- ============================================================================
-- VERIFICACIÓN (opcional)
-- ============================================================================
-- -- desde la app (con sesión del salón) debe devolver sus recargas:
-- select * from public.obtener_mis_recargas('<salon-id>'::uuid);
--
-- -- control rápido de que no se filtre entre salones: con la sesión del
-- -- salón A, pedir el salon-id de B debe fallar con 'sin_permisos'.
--
-- select r.creado_en, s.nombre, r.monto_ars, r.puntos_equivalentes,
--        r.estado, r.motivo_rechazo
--   from public.recargas_puntos r
--   join public.salones s on s.id = r.salon_id
--  order by r.creado_en desc
--  limit 50;
