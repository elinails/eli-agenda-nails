-- ============================================================================
-- ELIMA HUB · I96 · BLINDAJE DE BASE DE DATOS (auditoría de seguridad)
--
-- Hallazgos de la auditoría sobre las migraciones del repo:
--
--   [CRÍTICO] billeteras_salones: tenía policy pero RLS DESHABILITADO, así que
--             la policy no regía. Con los grants por defecto de Supabase,
--             cualquier cliente (incluso anon) podía leer y MODIFICAR el saldo
--             de cualquier salón con un PATCH directo a PostgREST.
--   [CRÍTICO] compras_hub / catalogo_hub: sin RLS -> lectura y escritura libre.
--   [ALTO]    configuracion_marketplace: sin RLS -> cualquiera podía activar
--             'auto_publicar_habilitado' y saltarse la aprobación manual.
--   [ALTO]    _publicacion_control: sin RLS -> se podía inyectar el "origen"
--             que usan los triggers del flujo de publicación.
--   [ALTO]    comprar_producto_hub usaba auth.uid() como si fuera salon_id
--             (en multi-tenant el salón sale de miembros_salon). Resultado:
--             lectura de una billetera inexistente y "saldo insuficiente"
--             siempre; y si se arreglaba el saldo, escribía un salon_id
--             incorrecto. Además no bloqueaba la fila: dos compras
--             simultáneas podían dejar el saldo negativo.
--   [MEDIO]   Varias RPC sensibles no revocaban EXECUTE de PUBLIC/anon.
--
-- IDEMPOTENTE: create or replace, drop policy/trigger if exists, revokes
-- repetibles. No borra datos ni agrega funcionalidades.
-- ============================================================================


-- ============================================================================
-- 0 · PRE-CHECK: las tablas que este archivo endurece tienen que existir
-- ============================================================================

do $$
declare
    v_faltan text;
begin
    select string_agg(t, ', ' order by t)
      into v_faltan
      from unnest(array[
            'salones', 'miembros_salon',
            'billeteras_salones', 'catalogo_hub', 'compras_hub',
            'configuracion_marketplace', '_publicacion_control'
           ]) as t
     where to_regclass('public.' || t) is null;

    if v_faltan is not null then
        raise exception 'I96 necesita estas tablas y no existen: %. Aplicá i62/i79/i85 antes.', v_faltan;
    end if;
end $$;


-- ============================================================================
-- 1 · BILLETERAS: RLS real + lectura sólo para miembros + sin escritura directa
-- ============================================================================

alter table public.billeteras_salones enable row level security;

-- La policy vieja se llamaba igual pero no regía (RLS estaba apagado).
drop policy if exists "Los salones solo ven su propia billetera" on public.billeteras_salones;
drop policy if exists billeteras_salones_select on public.billeteras_salones;

create policy billeteras_salones_select on public.billeteras_salones
    for select to authenticated
    using (public.es_miembro(salon_id) or public.es_super_admin());

-- Sin policies de INSERT/UPDATE/DELETE: el saldo sólo se mueve por RPC
-- security definer (comprar_producto_hub, aprobar_recarga_puntos, etc).
revoke insert, update, delete on public.billeteras_salones from anon, authenticated;
grant select on public.billeteras_salones to authenticated;


-- ============================================================================
-- 2 · CATÁLOGO: RLS + lectura pública de activos + escritura sólo SuperAdmin
-- ============================================================================

alter table public.catalogo_hub enable row level security;

drop policy if exists "Catálogo visible para todos" on public.catalogo_hub;
drop policy if exists catalogo_hub_lectura on public.catalogo_hub;
drop policy if exists catalogo_hub_admin on public.catalogo_hub;

create policy catalogo_hub_lectura on public.catalogo_hub
    for select to anon, authenticated
    using (activo = true);

create policy catalogo_hub_admin on public.catalogo_hub
    for all to authenticated
    using (public.es_super_admin())
    with check (public.es_super_admin());

revoke insert, update, delete on public.catalogo_hub from anon;


-- ============================================================================
-- 3 · COMPRAS: RLS + lectura sólo de los miembros del salón
-- ============================================================================
-- La policy vieja comparaba salon_id con auth.uid() (ids de distinto tipo):
-- nunca coincidía, así que en la práctica bloqueaba todo. Se reemplaza por
-- la pertenencia real.

alter table public.compras_hub enable row level security;

drop policy if exists "Los salones solo ven sus propias compras" on public.compras_hub;
drop policy if exists compras_hub_select on public.compras_hub;

create policy compras_hub_select on public.compras_hub
    for select to authenticated
    using (public.es_miembro(salon_id) or public.es_super_admin());

-- Las compras las inserta sólo la RPC security definer.
revoke insert, update, delete on public.compras_hub from anon, authenticated;


-- ============================================================================
-- 4 · CONFIGURACIÓN DEL MARKETPLACE: nadie la edita salvo el SuperAdmin
-- ============================================================================

alter table public.configuracion_marketplace enable row level security;

drop policy if exists config_marketplace_lectura on public.configuracion_marketplace;
drop policy if exists config_marketplace_admin on public.configuracion_marketplace;

create policy config_marketplace_lectura on public.configuracion_marketplace
    for select to authenticated
    using (true);

create policy config_marketplace_admin on public.configuracion_marketplace
    for all to authenticated
    using (public.es_super_admin())
    with check (public.es_super_admin());

revoke insert, update, delete on public.configuracion_marketplace from anon;


-- ============================================================================
-- 5 · TABLA INTERNA DE TRIGGERS: cerrada por completo
-- ============================================================================

alter table public._publicacion_control enable row level security;
revoke all on public._publicacion_control from anon, authenticated;


-- ============================================================================
-- 6 · BILLETERA NUNCA NEGATIVA (blindaje a nivel de fila)
-- ============================================================================
-- Aunque una función se equivoque (o alguien logre llamar algo que descuente),
-- la base rechaza dejar el saldo por debajo de cero.

create or replace function public.billeteras_salones_no_negativas()
returns trigger
language plpgsql
set search_path = public
as $$
begin
    if coalesce(new.saldo_actual, 0) < 0 then
        raise exception 'saldo_negativo: la billetera no puede quedar con saldo negativo'
            using errcode = 'check_violation',
                  detail  = 'salon_id ' || coalesce(new.salon_id::text, '?') ||
                            ' intento quedar en ' || new.saldo_actual || ' puntos.';
    end if;
    return new;
end $$;

comment on function public.billeteras_salones_no_negativas()
    is 'Impide que el saldo de una billetera quede negativo (I96).';

drop trigger if exists trg_billeteras_no_negativas on public.billeteras_salones;

create trigger trg_billeteras_no_negativas
    before insert or update on public.billeteras_salones
    for each row
    execute function public.billeteras_salones_no_negativas();


-- ============================================================================
-- 7 · COMPRAR PRODUCTO: salón real + bloqueo de fila (evita doble gasto)
-- ============================================================================
-- Misma firma y mismas columnas de salida que antes, para no tocar el frontend.

create or replace function public.comprar_producto_hub(p_producto_id bigint)
returns table (
    exito          boolean,
    producto_nombre text,
    precio_puntos  numeric,
    saldo_anterior numeric,
    saldo_nuevo    numeric,
    mensaje        text
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_producto public.catalogo_hub%rowtype;
    v_salon_id uuid;
    v_saldo    numeric;
    v_costo    numeric;
begin
    if auth.uid() is null then
        return query select false, null::text, 0::numeric, 0::numeric, 0::numeric,
            'sin_sesion:no hay sesión activa';
    end if;

    -- El salón NO es el user id: sale de la membresía activa (owner primero).
    select m.salon_id into v_salon_id
      from public.miembros_salon m
     where m.user_id = auth.uid()
       and coalesce(m.activo, true)
     order by (m.rol = 'owner') desc, m.creado_en
     limit 1;

    if v_salon_id is null then
        return query select false, null::text, 0::numeric, 0::numeric, 0::numeric,
            'sin_salon:tu usuario no pertenece a ningún salón';
    end if;

    select * into v_producto
      from public.catalogo_hub
     where id = p_producto_id and activo = true;

    if not found then
        return query select false, null::text, 0::numeric, 0::numeric, 0::numeric,
            'producto_no_encontrado_o_inactivo:el producto no existe o no está disponible';
    end if;

    v_costo := greatest(coalesce(v_producto.precio_puntos, 0), 0);

    -- Crear la billetera si el salón todavía no tenía, y bloquear la fila:
    -- dos compras simultáneas no pueden leer el mismo saldo.
    insert into public.billeteras_salones (salon_id, saldo_actual)
    values (v_salon_id, 0)
    on conflict (salon_id) do nothing;

    select b.saldo_actual into v_saldo
      from public.billeteras_salones b
     where b.salon_id = v_salon_id
     for update;

    v_saldo := coalesce(v_saldo, 0);

    if v_saldo < v_costo then
        return query select false, v_producto.nombre, v_costo, v_saldo, v_saldo,
            'saldo_insuficiente:tenés ' || v_saldo || ' pts y el producto cuesta ' || v_costo || ' pts';
    end if;

    update public.billeteras_salones b
       set saldo_actual = b.saldo_actual - v_costo,
           creado_en    = now()
     where b.salon_id = v_salon_id;

    insert into public.compras_hub (salon_id, producto_id, monto_puntos)
    values (v_salon_id, p_producto_id, v_costo);

    return query select true, v_producto.nombre, v_costo, v_saldo, v_saldo - v_costo,
        'Compra exitosa: ' || v_producto.nombre || ' (' || v_costo ||
        ' pts descontados). Saldo restante: ' || (v_saldo - v_costo) || ' pts';
end $$;

comment on function public.comprar_producto_hub(bigint)
    is 'Compra en Tienda HUB: resuelve el salón por membresía, bloquea la billetera y descuenta puntos sin permitir saldo negativo (I96).';

revoke execute on function public.comprar_producto_hub(bigint) from anon, public;
grant execute on function public.comprar_producto_hub(bigint) to authenticated, service_role;


-- ============================================================================
-- 8 · RPC SENSIBLES: sin EXECUTE para anon / PUBLIC
-- ============================================================================
-- PostgreSQL concede EXECUTE a PUBLIC por defecto en cada función nueva.
-- Para las funciones de negocio y de admin se revoca ese permiso implícito
-- y se vuelve a otorgar a authenticated (las de admin validan adentro con
-- es_super_admin()). Las funciones públicas del Marketplace NO se tocan.

do $$
declare
    r record;
begin
    for r in
        select p.oid::regprocedure::text as firma, p.proname
          from pg_proc p
          join pg_namespace n on n.oid = p.pronamespace
         where n.nspname = 'public'
           and p.prokind = 'f'
           and p.proname ~ '^(admin_|aprobar_|rechazar_|solicitar_|comprar_|emitir_|canjear_|cliente_|obtener_mis_|obtener_notificaciones|marcar_|ajustar_|vincular_|agregar_|crear_salon|saldo_puntos|turnos_de_cliente|crear_resena|recalcular_|revertir_)'
    loop
        execute format('revoke execute on function %s from anon, public', r.firma);
        execute format('grant execute on function %s to authenticated, service_role', r.firma);
    end loop;
end $$;


-- ============================================================================
-- 9 · Recargar el cache de esquema de PostgREST
-- ============================================================================

notify pgrst, 'reload schema';


-- ============================================================================
-- VERIFICACIÓN
-- ============================================================================
-- -- 1) ¿Quedó alguna tabla de public sin RLS? (debe devolver 0 filas)
-- select c.relname
--   from pg_class c
--   join pg_namespace n on n.oid = c.relnamespace
--  where n.nspname = 'public'
--    and c.relkind = 'r'
--    and not c.relrowsecurity
--  order by c.relname;
--
-- -- 2) Policies permisivas que quedan (revisar una por una):
-- select schemaname, tablename, policyname, roles, cmd, qual
--   from pg_policies
--  where schemaname = 'public'
--    and qual = 'true'
--  order by tablename;
--
-- -- 3) RPC sensibles ejecutables por anon (debe devolver 0 filas):
-- select p.proname, p.proacl
--   from pg_proc p
--   join pg_namespace n on n.oid = p.pronamespace
--  where n.nspname = 'public'
--    and p.prokind = 'f'
--    and has_function_privilege('anon', p.oid, 'execute')
--    and p.proname !~ '^(cache_epoch_actual|flags_publicos|patrocinador_publico|obtener_marcas_aliadas|public_marketplace_salones|public_salon_detalle|public_crear_solicitud|salon_branding|salon_es_publico)$'
--  order by p.proname;
--
-- -- 4) trigger de saldo negativo instalado:
-- select tgname from pg_trigger
--  where tgrelid = 'public.billeteras_salones'::regclass
--    and tgname = 'trg_billeteras_no_negativas';
--
-- -- 5) saldos negativos que ya existieran (para corregir a mano):
-- select salon_id, saldo_actual
--   from public.billeteras_salones
--  where saldo_actual < 0;
