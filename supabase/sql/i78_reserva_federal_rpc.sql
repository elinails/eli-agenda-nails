-- ============================================================================
-- ELI M. NAILS · I78 · RESERVA FEDERAL
-- RPCs de solo SuperAdmin para auditar y ajustar Elima Points.
-- No crea tablas, no modifica RLS, no toca turnos ni salones.
-- ============================================================================

-- ============================================================================
-- 1 · RESUMEN GLOBAL
-- ============================================================================

create or replace function public.admin_resumen_puntos()
returns table (
    saldo_total          numeric,
    billeteras_total     bigint,
    billeteras_con_saldo bigint,
    clientas_con_saldo   bigint,
    puntos_ganados_30d   numeric,
    puntos_canjeados_30d numeric,
    ajustes_netos_30d    numeric,
    movimientos_30d      bigint
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
        coalesce((
            select sum(b.saldo_actual)
              from public.billeteras_puntos b
        ), 0)::numeric,

        (select count(*) from public.billeteras_puntos),

        (select count(*)
           from public.billeteras_puntos b
          where b.saldo_actual > 0),

        (select count(distinct b.cliente_id)
           from public.billeteras_puntos b
          where b.saldo_actual > 0),

        coalesce((
            select sum(m.monto)
              from public.movimientos_puntos m
             where m.tipo = 'ganado'
               and m.creado_en >= now() - interval '30 days'
        ), 0)::numeric,

        coalesce((
            select abs(sum(m.monto))
              from public.movimientos_puntos m
             where m.tipo = 'canjeado'
               and m.creado_en >= now() - interval '30 days'
        ), 0)::numeric,

        coalesce((
            select sum(m.monto)
              from public.movimientos_puntos m
             where m.tipo = 'ajuste'
               and m.creado_en >= now() - interval '30 days'
        ), 0)::numeric,

        (select count(*)
           from public.movimientos_puntos m
          where m.creado_en >= now() - interval '30 days');
end $$;

revoke all on function public.admin_resumen_puntos() from public;
grant execute on function public.admin_resumen_puntos() to authenticated;


-- ============================================================================
-- 2 · LISTADO DE BILLETERAS
-- ============================================================================

create or replace function public.admin_listar_wallets(
    p_busqueda       text default null,
    p_salon_id       uuid default null,
    p_solo_con_saldo boolean default false,
    p_limite         integer default 25,
    p_offset         integer default 0
)
returns table (
    billetera_id     uuid,
    cliente_id       bigint,
    cliente_nombre   text,
    cliente_email    text,
    cliente_telefono text,
    salon_id         uuid,
    salon_nombre     text,
    saldo_actual     numeric,
    movimientos      bigint,
    ultimo_movimiento timestamptz,
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
        b.id,
        c.id,
        c.nombre,
        c.email,
        c.telefono,
        s.id,
        s.nombre,
        b.saldo_actual,
        (select count(*)
           from public.movimientos_puntos m
          where m.billetera_id = b.id),
        (select max(m.creado_en)
           from public.movimientos_puntos m
          where m.billetera_id = b.id),
        count(*) over ()
      from public.billeteras_puntos b
      join public.clientes c on c.id = b.cliente_id
      join public.salones s   on s.id = b.salon_id
     where (p_salon_id is null or b.salon_id = p_salon_id)
       and (not coalesce(p_solo_con_saldo, false) or b.saldo_actual > 0)
       and (
            v_busqueda is null
            or c.nombre ilike '%' || v_busqueda || '%'
            or coalesce(c.email, '') ilike '%' || v_busqueda || '%'
            or coalesce(c.telefono, '') ilike '%' || v_busqueda || '%'
            or s.nombre ilike '%' || v_busqueda || '%'
       )
     order by b.saldo_actual desc, c.nombre asc
     limit greatest(1, least(coalesce(p_limite, 25), 100))
    offset greatest(0, coalesce(p_offset, 0));
end $$;

revoke all on function public.admin_listar_wallets(text, uuid, boolean, integer, integer) from public;
grant execute on function public.admin_listar_wallets(text, uuid, boolean, integer, integer) to authenticated;


-- ============================================================================
-- 3 · MOVIMIENTOS DE UNA BILLETERA
-- ============================================================================

create or replace function public.admin_movimientos_wallet(
    p_billetera_id uuid,
    p_limite       integer default 50,
    p_offset       integer default 0
)
returns table (
    id             uuid,
    creado_en      timestamptz,
    tipo           text,
    monto          numeric,
    motivo         text,
    turno_id       bigint,
    salon_nombre   text,
    cliente_nombre text
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
    select m.id,
           m.creado_en,
           m.tipo,
           m.monto,
           m.motivo,
           m.turno_id,
           s.nombre,
           c.nombre
      from public.movimientos_puntos m
      join public.billeteras_puntos b on b.id = m.billetera_id
      join public.clientes c on c.id = b.cliente_id
      join public.salones s on s.id = b.salon_id
     where m.billetera_id = p_billetera_id
     order by m.creado_en desc
     limit greatest(1, least(coalesce(p_limite, 50), 200))
    offset greatest(0, coalesce(p_offset, 0));
end $$;

revoke all on function public.admin_movimientos_wallet(uuid, integer, integer) from public;
grant execute on function public.admin_movimientos_wallet(uuid, integer, integer) to authenticated;


-- ============================================================================
-- 4 · AJUSTE MANUAL
--
-- No edita saldo_actual: inserta un movimiento tipo 'ajuste' y el trigger
-- recalcula la caché. Si la billetera no existe, la crea.
-- ============================================================================

create or replace function public.admin_ajustar_puntos_cliente(
    p_cliente_id bigint,
    p_salon_id   uuid,
    p_monto      numeric,
    p_motivo     text
)
returns table (
    billetera_id  uuid,
    saldo_nuevo   numeric,
    movimiento_id uuid
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_monto      numeric := round(coalesce(p_monto, 0)::numeric, 2);
    v_motivo     text := nullif(btrim(coalesce(p_motivo, '')), '');
    v_billetera  uuid;
    v_saldo      numeric;
    v_movimiento uuid;
begin
    if not public.es_super_admin() then
        raise exception 'sin_permisos';
    end if;

    if p_cliente_id is null or p_salon_id is null then
        raise exception 'datos_invalidos';
    end if;
    if v_monto = 0 then
        raise exception 'monto_invalido';
    end if;
    if abs(v_monto) > 1000000 then
        raise exception 'monto_fuera_de_rango';
    end if;
    if v_motivo is null or char_length(v_motivo) < 3 or char_length(v_motivo) > 180 then
        raise exception 'motivo_invalido';
    end if;

    if not exists (
        select 1 from public.clientes c
         where c.id = p_cliente_id and c.salon_id = p_salon_id
    ) then
        raise exception 'cliente_no_pertenece_al_salon';
    end if;

    select b.id into v_billetera
      from public.billeteras_puntos b
     where b.cliente_id = p_cliente_id
       and b.salon_id = p_salon_id
     for update;

    if v_billetera is null then
        insert into public.billeteras_puntos (cliente_id, salon_id, saldo_actual)
        values (p_cliente_id, p_salon_id, 0)
        on conflict (cliente_id, salon_id) do nothing
        returning id into v_billetera;

        if v_billetera is null then
            select b.id into v_billetera
              from public.billeteras_puntos b
             where b.cliente_id = p_cliente_id
               and b.salon_id = p_salon_id
             for update;
        end if;
    end if;

    if v_billetera is null then
        raise exception 'billetera_no_disponible';
    end if;

    select b.saldo_actual into v_saldo
      from public.billeteras_puntos b
     where b.id = v_billetera
     for update;

    if coalesce(v_saldo, 0) + v_monto < 0 then
        raise exception 'saldo_insuficiente';
    end if;

    insert into public.movimientos_puntos (billetera_id, tipo, monto, motivo)
    values (v_billetera, 'ajuste', v_monto, 'Ajuste SuperAdmin: ' || v_motivo)
    returning id into v_movimiento;

    perform public.recalcular_saldo_puntos(v_billetera);

    select b.saldo_actual into v_saldo
      from public.billeteras_puntos b
     where b.id = v_billetera;

    return query select v_billetera, v_saldo, v_movimiento;
end $$;

revoke all on function public.admin_ajustar_puntos_cliente(bigint, uuid, numeric, text) from public;
grant execute on function public.admin_ajustar_puntos_cliente(bigint, uuid, numeric, text) to authenticated;


notify pgrst, 'reload schema';