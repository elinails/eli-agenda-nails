-- ============================================================================
-- ELI M. NAILS · I82 · CANJEAR PUNTOS DESDE EL PORTAL DEL CLIENTE
--
-- RPC segura para que el cliente pueda canjear sus Elima Points en turnos
-- futuros desde el portal. Valida estrictamente:
--   1) El turno está en el salón del cliente
--   2) El turno pertenece al cliente autenticado (clienta_id o email)
--   3) El saldo disponible es suficiente
--   4) El canje no supera el tope del 30% del precio
--
-- REQUISITOS: i68_canje_points.sql aplicado
-- IDEMPOTENTE: se puede correr varias veces
-- ============================================================================

-- 1 · RPC para consultar saldo disponible del cliente en un salón
--    (sin parametros: usa auth.uid() o email de la session)
create or replace function public.cliente_saldo_puntos_turno(
    p_turno_id bigint
)
returns table (
    saldo_disponible numeric,
    tope_maximo       numeric,
    precio_original   numeric,
    salon_id          uuid,
    salon_nombre      text,
    turno_estado      text
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_turno      public.turnos%rowtype;
    v_cliente_id bigint;
    v_billetera  uuid;
    v_saldo      numeric;
    v_base       numeric;
    v_tope       numeric;
begin
    -- Buscar el turno
    select * into v_turno from public.turnos t where t.id = p_turno_id;
    if not found then
        return;
    end if;

    -- Verificar que el turno pertenece al cliente autenticado
    -- (buscamos en turnos.user_id, turnos.cliente_id o clientes vinculados)
    select c.id into v_cliente_id
      from public.clientes c
      where c.salon_id = v_turno.salon_id
        and c.auth_user_id = auth.uid()
      limit 1;

    if v_cliente_id is null then
        -- También buscar por email vinculado
        select c.id into v_cliente_id
          from public.clientes c
          join auth.users u on u.id = auth.uid()
         where c.salon_id = v_turno.salon_id
           and lower(c.email) = lower(u.email)
          limit 1;
    end if;

    if v_cliente_id is null then
        return;  -- El turno no pertenece al cliente
    end if;

    -- Verificar que el turno no está cerrado
    if lower(coalesce(v_turno.status, '')) = any (array['completed', 'realizado', 'cancelled', 'cancelado']) then
        return;
    end if;

    -- Buscar billetera del cliente en este salón
    select b.id into v_billetera
      from public.billeteras_puntos b
     where b.cliente_id = v_cliente_id
       and b.salon_id = v_turno.salon_id;

    if v_billetera is null then
        return;
    end if;

    -- Calcular saldo y tope
    select b.saldo_actual into v_saldo
      from public.billeteras_puntos b
     where b.id = v_billetera;

    v_base := coalesce(v_turno.price, 0);
    v_tope := floor(v_base * 0.30);

    return query select 
        coalesce(v_saldo, 0),
        v_tope,
        v_base,
        v_turno.salon_id,
        s.nombre,
        v_turno.status
    from public.salones s
    where s.id = v_turno.salon_id;
end;
$$;

revoke all on function public.cliente_saldo_puntos_turno(bigint) from public, anon;
grant execute on function public.cliente_saldo_puntos_turno(bigint) to authenticated;


-- 2 · RPC para canjear puntos desde el portal del cliente
create or replace function public.cliente_canjear_puntos(
    p_turno_id bigint,
    p_puntos   numeric
)
returns table (
    ok       boolean,
    puntos   numeric,
    saldo    numeric,
    tope     numeric,
    motivo   text
)
language plpgsql
security definer
set search_path = public
as $$
declare
    c_tope constant numeric := 0.30;
    
    v_turno      public.turnos%rowtype;
    v_cliente_id bigint;
    v_billetera  uuid;
    v_saldo      numeric;
    v_base       numeric;
    v_tope_calc  numeric;
    v_ya         numeric;
begin
    -- Validar cantidad
    p_puntos := floor(coalesce(p_puntos, 0));
    if p_puntos <= 0 then
        return query select false, 0, 0, 0, 'puntos_invalidos'::text;
    end if;

    -- Buscar el turno
    select * into v_turno from public.turnos t where t.id = p_turno_id;
    if not found then
        return query select false, 0, 0, 0, 'turno_no_existe'::text;
    end if;

    -- Verificar propiedad del turno: el cliente autenticado
    select c.id into v_cliente_id
      from public.clientes c
      where c.salon_id = v_turno.salon_id
        and c.auth_user_id = auth.uid()
      limit 1;

    if v_cliente_id is null then
        -- También buscar por email vinculado
        select c.id into v_cliente_id
          from public.clientes c
          join auth.users u on u.id = auth.uid()
         where c.salon_id = v_turno.salon_id
           and lower(c.email) = lower(u.email)
          limit 1;
    end if;

    if v_cliente_id is null then
        return query select false, 0, 0, 0, 'turno_no_pertenece_cliente'::text;
    end if;

    -- Verificar que el turno no está cerrado
    if lower(coalesce(v_turno.status, '')) = any (array['completed', 'realizado', 'cancelled', 'cancelado']) then
        return query select false, 0, 0, 0, 'turno_cerrado'::text;
    end if;

    -- Buscar billetera del cliente en este salón
    select b.id into v_billetera
      from public.billeteras_puntos b
     where b.cliente_id = v_cliente_id
       and b.salon_id = v_turno.salon_id
      for update;

    if v_billetera is null then
        return query select false, 0, 0, 0, 'sin_billetera'::text;
    end if;

    -- Obtener saldo actual
    select b.saldo_actual into v_saldo
      from public.billeteras_puntos b
     where b.id = v_billetera;

    -- Calcular tope del 30%
    v_base := coalesce(v_turno.price, 0);
    v_tope_calc := floor(v_base * c_tope);

    -- Validar saldo
    if v_saldo < p_puntos then
        return query select false, 0, v_saldo, v_tope_calc, 'saldo_insuficiente'::text;
    end if;

    -- Validar tope máximo
    if p_puntos > v_tope_calc then
        return query select false, v_tope_calc, v_saldo, v_tope_calc, 'supera_tope'::text;
    end if;

    -- Verificar que no se canjearon ya puntos en este turno
    select coalesce(sum(abs(m.monto)), 0) into v_ya
      from public.movimientos_puntos m
     where m.turno_id = p_turno_id
       and m.tipo = 'canjeado';

    if v_ya > 0 then
        return query select false, v_ya, v_saldo, v_tope_calc, 'ya_canjeado'::text;
    end if;

    -- Ejecutar el canje
    insert into public.movimientos_puntos (billetera_id, tipo, monto, motivo, turno_id)
    values (v_billetera, 'canjeado', -p_puntos,
            'Canje en turno #' || p_turno_id || ' (portal cliente)', p_turno_id);

    -- Actualizar descuento en el turno (sin cambiar el precio a cobrar)
    update public.turnos t
       set descuento_puntos = t.descuento_puntos + p_puntos
     where t.id = p_turno_id;

    -- Recalcular saldo
    perform public.recalcular_saldo_puntos(v_billetera);

    return query select true, p_puntos, v_saldo - p_puntos, v_tope_calc, 'canjeado'::text;
end;
$$;

revoke all on function public.cliente_canjear_puntos(bigint, numeric) from public, anon;
grant execute on function public.cliente_canjear_puntos(bigint, numeric) to authenticated;


-- 3 · RPC para listar turnos futuros con opción de canjear
create or replace function public.cliente_turnos_canjeables(
    p_limit integer default 10
)
returns table (
    id            bigint,
    salon_id      uuid,
    salon_nombre  text,
    fecha         date,
    hora          time,
    servicio      text,
    precio        numeric,
    estado        text,
    saldo_puntos  numeric,
    tope_puntos   numeric
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_cliente_ids bigint[];
begin
    -- Obtener IDs de clientes vinculados al usuario
    select array_agg(t.id) into v_cliente_ids
      from public._mis_clientes() as t(id);

    if v_cliente_ids is null then
        return;
    end if;

    return query
    select 
        t.id,
        t.salon_id,
        s.nombre,
        t.appointment_date,
        t.appointment_time,
        t.service_type,
        t.price,
        t.status,
        coalesce(bs.saldo_actual, 0),
        floor(coalesce(t.price, 0) * 0.30)
    from public.turnos t
    join public.salones s on s.id = t.salon_id
    left join public.billeteras_puntos bs on bs.cliente_id = any(v_cliente_ids)
    where t.cliente_id = any(v_cliente_ids)
      and t.appointment_date >= current_date
      and t.status not in ('realizado', 'completed', 'cancelled', 'cancelado')
    order by t.appointment_date, t.appointment_time
    limit greatest(1, least(p_limit, 50));
end;
$$;

revoke all on function public.cliente_turnos_canjeables(integer) from public, anon;
grant execute on function public.cliente_turnos_canjeables(integer) to authenticated;


notify pgrst, 'reload schema';

-- ============================================================================
-- VERIFICACIÓN
-- ============================================================================
--
-- 1) Obtener saldo potencial para un turno:
--    select * from public.cliente_saldo_puntos_turno(TURNO_ID);
--
-- 2) Canjear puntos:
--    select * from public.cliente_canjear_puntos(TURNO_ID, 500);
--
-- 3) Listar turnos canjeables:
--    select * from public.cliente_turnos_canjeables(5);
-- ============================================================================