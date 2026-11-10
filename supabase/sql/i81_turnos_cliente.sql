-- ============================================================================
-- ELI M. NAILS · I81 · Turnos de cliente con estado de reseña
--
-- RPC que devuelve los turnos del cliente autenticado y si pueden ser reseñados
-- ============================================================================

create or replace function public.turnos_de_cliente(
    p_estado text default null
)
returns table (
    id              bigint,
    salon_id        uuid,
    fecha           date,
    hora            time,
    servicio_nombre text,
    salon_nombre    text,
    salon_slug      text,
    estado          text,
    ya_resenado     boolean
)
language sql
security definer
set search_path = public
as $$
    select
        t.id,
        s.id as salon_id,
        t.appointment_date as fecha,
        t.appointment_time as hora,
        t.service_type as servicio_nombre,
        s.nombre as salon_nombre,
        s.slug as salon_slug,
        t.status as estado,
        exists (
            select 1 from public.resenas r
            where r.turno_id = t.id
        ) as ya_resenado
    from public.turnos t
    join public.clientes c on c.user_id = auth.uid()
    join public.salones s on s.id = t.salon_id
    where (p_estado is null or t.status = p_estado)
      and t.status in ('realizado', 'completed', 'completado')
    order by t.appointment_date desc, t.appointment_time desc;
$$;

-- Permitir que clientes autenticados ejecuten la RPC
grant execute on function public.turnos_de_cliente(text) to authenticated;

-- Notificación de actualización
notify pgrst, 'reload schema';

-- ============================================================================
-- VERIFICACIÓN:
-- select * from public.turnos_de_cliente();
-- select * from public.turnos_de_cliente('realizado');
-- ============================================================================