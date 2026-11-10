-- ============================================================================
-- ELI M. NAILS · I83 · RESERVA FEDERAL MEJORAS
-- RPC para listar clientes con/ sin billetera y emitir puntos a cualquier clienta.
-- ============================================================================

-- ============================================================================
-- 1 · LISTAR CLIENTES CON O SIN BILLETERA
-- ============================================================================
-- Devuelve TODAS las clientas de un salón, indicando si tienen billetera y su saldo.

create or replace function public.admin_listar_clientes_billeteras(
    p_salon_id       uuid,
    p_busqueda       text default null,
    p_solo_con_saldo boolean default false,
    p_limite         integer default 25,
    p_offset         integer default 0
)
returns table (
    cliente_id       bigint,
    cliente_nombre   text,
    cliente_email    text,
    cliente_telefono text,
    salon_id         uuid,
    salon_nombre     text,
    billetera_id     uuid,
    saldo_actual     numeric,
    tiene_billetera  boolean,
    total_registros  bigint
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_busqueda text := nullif(btrim(coalesce(p_busqueda, '')), '');
begin
    if not public.es_super_admin() then
        raise exception 'sin_permisos';
    end if;

    return query
    select
        c.id as cliente_id,
        c.nombre as cliente_nombre,
        c.email as cliente_email,
        c.telefono as cliente_telefono,
        s.id as salon_id,
        s.nombre as salon_nombre,
        b.id as billetera_id,
        coalesce(b.saldo_actual, 0) as saldo_actual,
        b.id is not null as tiene_billetera,
        count(*) over () as total_registros
    from public.clientes c
    join public.salones s on s.id = p_salon_id
    left join public.billeteras_puntos b on b.cliente_id = c.id and b.salon_id = s.id
    where (
        v_busqueda is null
        or c.nombre ilike '%' || v_busqueda || '%'
        or coalesce(c.email, '') ilike '%' || v_busqueda || '%'
        or coalesce(c.telefono, '') ilike '%' || v_busqueda || '%'
        or s.nombre ilike '%' || v_busqueda || '%'
    )
    and (not p_solo_con_saldo or b.id is not null)
    order by c.nombre asc
    limit greatest(1, least(coalesce(p_limite, 25), 100))
    offset greatest(0, coalesce(p_offset, 0));
end $$;

revoke all on function public.admin_listar_clientes_billeteras(uuid, text, boolean, integer, integer) from public;
grant execute on function public.admin_listar_clientes_billeteras(uuid, text, boolean, integer, integer) to authenticated;


-- ============================================================================
-- 2 · EMITIR PUNTOS A CLIENTE
-- ============================================================================
-- Emite puntos a una clienta. Si no tiene billetera, la crea automáticamente.
-- Solo puede usarse el SuperAdmin.

create or replace function public.admin_emitir_puntos(
    p_cliente_id bigint,
    p_salon_id   uuid,
    p_monto      numeric,
    p_motivo     text
)
returns table (
    billetera_id  uuid,
    saldo_nuevo   numeric,
    movimiento_id uuid,
    cliente_nombre text,
    saldo_anterior numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_monto         numeric := round(coalesce(p_monto, 0)::numeric, 2);
    v_motivo        text := nullif(btrim(coalesce(p_motivo, '')), '');
    v_billetera     uuid;
    v_saldo         numeric;
    v_saldo_anterior numeric;
    v_movimiento    uuid;
    v_cliente_nombre text;
begin
    -- Verificar permisos de SuperAdmin
    if not public.es_super_admin() then
        raise exception 'sin_permisos';
    end if;

    -- Validaciones
    if p_cliente_id is null or p_salon_id is null then
        raise exception 'datos_invalidos';
    end if;
    if v_monto <= 0 then
        raise exception 'monto_debe_ser_positivo';
    end if;
    if abs(v_monto) > 1000000 then
        raise exception 'monto_fuera_de_rango';
    end if;
    if v_motivo is null or char_length(v_motivo) < 3 or char_length(v_motivo) > 180 then
        raise exception 'motivo_invalido';
    end if;

    -- Verificar que el cliente pertenece al salón
    select c.nombre into v_cliente_nombre
    from public.clientes c
    where c.id = p_cliente_id and c.salon_id = p_salon_id;

    if not found then
        raise exception 'cliente_no_pertenece_al_salon';
    end if;

    -- Obtener o crear billetera
    select b.id, b.saldo_actual into v_billetera, v_saldo_anterior
      from public.billeteras_puntos b
     where b.cliente_id = p_cliente_id and b.salon_id = p_salon_id
     for update;

    if v_billetera is null then
        insert into public.billeteras_puntos (cliente_id, salon_id, saldo_actual)
        values (p_cliente_id, p_salon_id, 0)
        on conflict (cliente_id, salon_id) do nothing
        returning id, saldo_actual into v_billetera, v_saldo_anterior;
    end if;

    -- Registrar el movimiento (tipo 'emitido' para puntos emitidos por SuperAdmin)
    insert into public.movimientos_puntos (billetera_id, tipo, monto, motivo)
    values (v_billetera, 'ajuste', v_monto, 'Emissión SuperAdmin: ' || v_motivo)
    returning id into v_movimiento;

    -- Recalcular saldo
    perform public.recalcular_saldo_puntos(v_billetera);

    -- Obtener nuevo saldo
    select b.saldo_actual into v_saldo
      from public.billeteras_puntos b
     where b.id = v_billetera;

    return query select v_billetera, v_saldo, v_movimiento, v_cliente_nombre, v_saldo_anterior;
end $$;

revoke all on function public.admin_emitir_puntos(bigint, uuid, numeric, text) from public;
grant execute on function public.admin_emitir_puntos(bigint, uuid, numeric, text) to authenticated;


-- ============================================================================
-- 3 · VERIFICAR SI CLIENTE TIENE BILLETERA
-- ============================================================================

create or replace function public.admin_tiene_billetera(
    p_billetera_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
    return exists (
        select 1 from public.billeteras_puntos
        where id = p_billetera_id
    );
end $$;

revoke all on function public.admin_tiene_billetera(uuid) from public;
grant execute on function public.admin_tiene_billetera(uuid) to authenticated;


notify pgrst, 'reload schema';