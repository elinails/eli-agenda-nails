-- ============================================================================
-- ELIMA HUB · I88 · LISTADO DE RECARGAS PENDIENTES PARA EL PANEL
--
-- El SuperAdmin necesita ver las transferencias que notifican los salones
-- antes de aprobarlas o rechazarlas desde admin.html.
--
-- Sólo LECTURA: no cambia estados ni saldos. Las acciones siguen siendo
-- aprobar_recarga_puntos() y rechazar_recarga_puntos() (i87).
--
-- IDEMPOTENTE: create or replace, se puede correr varias veces.
-- REQUISITOS: i85 (billeteras), i87 (recargas_puntos) e i48 (es_super_admin).
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
-- 1 · RPC: admin_listar_recargas_pendientes()
-- ============================================================================
-- Devuelve las recargas en estado 'pendiente', la más vieja primero (la que
-- lleva más tiempo esperando). El email es el del miembro activo del salón,
-- priorizando al owner; si no hay ninguno, queda vacío.
--
-- Códigos de error: sin_permisos.

create or replace function public.admin_listar_recargas_pendientes()
returns table (
    id                  uuid,
    salon_id            uuid,
    salon_nombre        text,
    email               text,
    monto_ars           numeric,
    puntos_equivalentes numeric,
    comprobante         text,
    creado_en           timestamptz
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
        r.id,
        r.salon_id,
        coalesce(nullif(btrim(s.nombre), ''), 'Salón sin nombre') as salon_nombre,
        coalesce(miembro.email, '')                              as email,
        r.monto_ars,
        r.puntos_equivalentes,
        coalesce(r.comprobante, '')                              as comprobante,
        r.creado_en
    from public.recargas_puntos r
    join public.salones s
      on s.id = r.salon_id
    left join lateral (
        select mm.email
        from public.miembros_salon mm
        where mm.salon_id = r.salon_id
          and coalesce(mm.activo, true)
        order by (mm.rol = 'owner') desc, mm.creado_en
        limit 1
    ) miembro on true
    where r.estado = 'pendiente'
    order by r.creado_en asc;
end $$;

comment on function public.admin_listar_recargas_pendientes()
    is 'Lista las recargas de puntos pendientes de aprobación. Sólo SuperAdmin.';

grant execute on function public.admin_listar_recargas_pendientes() to authenticated;


-- ============================================================================
-- 2 · Recargar el cache de esquema de PostgREST
-- ============================================================================

notify pgrst, 'reload schema';


-- ============================================================================
-- VERIFICACIÓN (opcional)
-- ============================================================================
-- -- como SuperAdmin, debe listar las pendientes (o 0 filas):
-- select * from public.admin_listar_recargas_pendientes();
--
-- -- para ver el histórico completo (aprobadas y rechazadas incluidas):
-- select r.creado_en, s.nombre, r.monto_ars, r.puntos_equivalentes,
--        r.estado, r.comprobante, r.resuelto_en, r.resuelto_por, r.motivo_rechazo
--   from public.recargas_puntos r
--   join public.salones s on s.id = r.salon_id
--  order by r.creado_en desc
--  limit 50;
