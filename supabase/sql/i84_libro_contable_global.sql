-- ============================================================================
-- ELI M. NAILS · I84 · LIBRO CONTABLE GLOBAL
-- Vista inmutable de todas las transacciones de Elima Points
-- Solo accesible por SuperAdmin
-- ============================================================================

-- ============================================================================
-- 1 · LIBRO CONTABLE GLOBAL
-- ============================================================================

create or replace function public.admin_libro_contable_global(
    p_busqueda text default null,
    p_tipo text default null,
    p_salon_id uuid default null,
    p_limite integer default 50,
    p_offset integer default 0
)
returns table (
    fecha            timestamptz,
    cliente_id       bigint,
    cliente_nombre   text,
    cliente_email    text,
    salon_id         uuid,
    salon_nombre     text,
    tipo_movimiento  text,
    monto            numeric,
    motivo           text,
    creado_por       text,
    billetera_id     uuid,
    total_registros  bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_busqueda text := nullif(btrim(coalesce(p_busqueda, '')), '');
    v_tipo     text := nullif(btrim(coalesce(p_tipo, '')), '');
begin
    if not public.es_super_admin() then
        raise exception 'sin_permisos';
    end if;

    return query
    select
        m.creado_en as fecha,
        c.id as cliente_id,
        c.nombre as cliente_nombre,
        c.email as cliente_email,
        s.id as salon_id,
        s.nombre as salon_nombre,
        m.tipo as tipo_movimiento,
        m.monto,
        m.motivo,
        case
            when m.tipo = 'ganado' then 'Turno #' || m.turno_id::text
            when m.tipo = 'canjeado' then 'Canje #' || m.turno_id::text
            when m.tipo = 'ajuste' then split_part(m.motivo, ': ', 2)
            else m.motivo
        end as creado_por,
        m.billetera_id,
        count(*) over () as total_registros
    from public.movimientos_puntos m
    join public.billeteras_puntos b on b.id = m.billetera_id
    join public.clientes c on c.id = b.cliente_id
    join public.salones s on s.id = b.salon_id
    where (
        v_busqueda is null
        or c.nombre ilike '%' || v_busqueda || '%'
        or coalesce(c.email, '') ilike '%' || v_busqueda || '%'
        or s.nombre ilike '%' || v_busqueda || '%'
        or m.motivo ilike '%' || v_busqueda || '%'
    )
    and (v_tipo is null or m.tipo = v_tipo)
    and (p_salon_id is null or s.id = p_salon_id)
    order by m.creado_en desc
    limit greatest(1, least(coalesce(p_limite, 50), 500))
    offset greatest(0, coalesce(p_offset, 0));
end $$;

revoke all on function public.admin_libro_contable_global(text, text, uuid, integer, integer) from public;
grant execute on function public.admin_libro_contable_global(text, text, uuid, integer, integer) to authenticated;


-- ============================================================================
-- 2 · RESUMEN MENSUAL (para el grafico de flujo)
-- ============================================================================

create or replace function public.admin_resumen_mensual_puntos(
    p_salon_id uuid default null,
    p_meses integer default 6
)
returns table (
    mes           text,
    puntos_ganados numeric,
    puntos_canjeados numeric,
    ajustes_nets  numeric,
    saldo_final   numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_start_date date := date_trunc('month', current_date - interval '1 month' * (p_meses - 1));
    v_end_date   date := date_trunc('month', current_date) + interval '1 month' - interval '1 day';
begin
    if not public.es_super_admin() then
        raise exception 'sin_permisos';
    end if;

    return query
    select
        to_char(date_trunc('month', m.creado_en), 'YYYY-MM') as mes,
        sum(case when m.tipo = 'ganado' then m.monto else 0 end)::numeric as puntos_ganados,
        sum(case when m.tipo = 'canjeado' then abs(m.monto) else 0 end)::numeric as puntos_canjeados,
        sum(case when m.tipo = 'ajuste' then m.monto else 0 end)::numeric as ajustes_nets,
        coalesce((
            select sum(b.saldo_actual)
            from public.billeteras_puntos bb
            where (p_salon_id is null or bb.salon_id = p_salon_id)
        ), 0) as saldo_final
    from public.movimientos_puntos m
    join public.billeteras_puntos b on b.id = m.billetera_id
    where m.creado_en >= v_start_date
    and m.creado_en <= v_end_date
    and (p_salon_id is null or b.salon_id = p_salon_id)
    group by date_trunc('month', m.creado_en)
    order by mes;
end $$;

revoke all on function public.admin_resumen_mensual_puntos(uuid, integer) from public;
grant execute on function public.admin_resumen_mensual_puntos(uuid, integer) to authenticated;


notify pgrst, 'reload schema';