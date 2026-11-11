-- ============================================================================
-- ELIMA HUB · I87 · RECARGAS DE PUNTOS POR TRANSFERENCIA BANCARIA
--
-- Flujo MVP: la dueña transfiere a la cuenta de ELIMA HUB, pega el número de
-- operación en la app y la recarga queda 'pendiente'. Los puntos se acreditan
-- RECIÉN cuando el SuperAdmin aprueba la recarga desde el panel.
--
-- Ratio acordado: 1 ARS = 1 Elima Point.
-- El ratio se calcula al momento de SOLICITAR y se guarda en
-- `puntos_equivalentes`: si mañana cambia, las solicitudes pendientes
-- mantienen lo que se prometió (no se recalculan al aprobar).
--
-- IDEMPOTENTE: se puede correr varias veces. No borra datos.
-- REQUISITOS: i85_economia_b2b.sql (billeteras_salones) e i48 (es_super_admin).
-- ============================================================================


-- ============================================================================
-- 0 · PRE-CHECK
-- ============================================================================

do $$
begin
    if to_regclass('public.billeteras_salones') is null then
        raise exception 'Falta i85_economia_b2b.sql (no existe billeteras_salones)';
    end if;
    if to_regclass('public.salones') is null then
        raise exception 'Falta el esquema base (no existe salones)';
    end if;
end $$;


-- ============================================================================
-- 1 · TABLA: recargas_puntos
-- ============================================================================
-- Una fila por solicitud de recarga. NUNCA se actualiza el saldo desde acá:
-- el saldo vive en billeteras_salones y sólo lo mueve aprobar_recarga_puntos().

create table if not exists public.recargas_puntos (
    id                   uuid primary key default gen_random_uuid(),
    salon_id             uuid not null references public.salones (id) on delete cascade,
    monto_ars            numeric(12, 2) not null,
    puntos_equivalentes  numeric(12, 2) not null,
    metodo_pago          text not null default 'transferencia',
    estado               text not null default 'pendiente',
    comprobante          text,
    creado_en            timestamptz not null default now(),

    -- auditoría de la resolución (la completa el SuperAdmin al aprobar)
    resuelto_en          timestamptz,
    resuelto_por         uuid,
    motivo_rechazo       text,

    constraint recargas_puntos_monto_positivo
        check (monto_ars > 0),
    constraint recargas_puntos_puntos_positivos
        check (puntos_equivalentes > 0),
    constraint recargas_puntos_metodo_valido
        check (metodo_pago in ('transferencia', 'mercadopago')),
    constraint recargas_puntos_estado_valido
        check (estado in ('pendiente', 'aprobado', 'rechazado'))
);

comment on table public.recargas_puntos
    is 'Solicitudes de recarga de Elima Points. Los puntos se acreditan al aprobar.';
comment on column public.recargas_puntos.puntos_equivalentes
    is 'Puntos prometidos al momento de solicitar (1 ARS = 1 punto). No se recalcula al aprobar.';
comment on column public.recargas_puntos.comprobante
    is 'Número de operación / referencia de la transferencia declarada por la dueña.';
comment on column public.recargas_puntos.resuelto_por
    is 'SuperAdmin que aprobó o rechazó la recarga.';

create index if not exists idx_recargas_puntos_salon
    on public.recargas_puntos (salon_id, creado_en desc);

create index if not exists idx_recargas_puntos_estado
    on public.recargas_puntos (estado, creado_en desc);


-- ============================================================================
-- 2 · RLS
-- ============================================================================
-- Lectura: cada salón ve sus propias recargas; el SuperAdmin ve todas.
-- Escritura: NO se permite directo. Sólo por RPC security definer.

alter table public.recargas_puntos enable row level security;

drop policy if exists recargas_puntos_select_propias on public.recargas_puntos;
create policy recargas_puntos_select_propias on public.recargas_puntos
    for select to authenticated
    using (
        exists (
            select 1
            from public.miembros_salon m
            where m.salon_id = recargas_puntos.salon_id
              and m.user_id = auth.uid()
        )
    );

drop policy if exists recargas_puntos_select_superadmin on public.recargas_puntos;
create policy recargas_puntos_select_superadmin on public.recargas_puntos
    for select to authenticated
    using (public.es_super_admin());

grant select on public.recargas_puntos to authenticated;


-- ============================================================================
-- 3 · RPC: solicitar_recarga_transferencia()
-- ============================================================================
-- La llama la dueña desde index.html (Mi Billetera).
-- Valida pertenencia al salón, monto y comprobante, y deja la recarga
-- en 'pendiente'. NO toca el saldo.

create or replace function public.solicitar_recarga_transferencia(
    p_salon_id     uuid,
    p_monto_ars    numeric,
    p_comprobante  text
)
returns table (
    id                uuid,
    estado            text,
    monto_ars         numeric,
    puntos_equivalentes numeric,
    mensaje           text
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_user        uuid := auth.uid();
    v_salon       uuid := p_salon_id;
    v_monto       numeric;
    v_comprobante text;
    v_puntos      numeric;
    v_id          uuid;
    -- Ratio vigente: 1 ARS = 1 Elima Point.
    c_ratio       constant numeric := 1;
    c_monto_max   constant numeric := 2000000;   -- techo anti-error de tipeo
begin
    if v_user is null then
        raise exception 'sin_sesion';
    end if;

    -- Si el cliente no manda el salón, se deduce de la membresía activa.
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

    -- Autorización: miembro del salón o SuperAdmin (soporte).
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

    v_monto := round(coalesce(p_monto_ars, 0)::numeric, 2);
    if v_monto <= 0 then
        raise exception 'monto_invalido';
    end if;
    if v_monto > c_monto_max then
        raise exception 'monto_fuera_de_rango';
    end if;

    v_comprobante := nullif(btrim(coalesce(p_comprobante, '')), '');
    if v_comprobante is null or length(v_comprobante) < 3 then
        raise exception 'comprobante_requerido';
    end if;
    v_comprobante := left(v_comprobante, 120);

    -- Evita notificar dos veces la misma transferencia.
    if exists (
        select 1
        from public.recargas_puntos r
        where r.salon_id = v_salon
          and r.estado = 'pendiente'
          and lower(btrim(r.comprobante)) = lower(v_comprobante)
    ) then
        raise exception 'comprobante_repetido';
    end if;

    v_puntos := round(v_monto * c_ratio, 2);

    insert into public.recargas_puntos (
        salon_id, monto_ars, puntos_equivalentes, metodo_pago, estado, comprobante
    )
    values (
        v_salon, v_monto, v_puntos, 'transferencia', 'pendiente', v_comprobante
    )
    returning recargas_puntos.id into v_id;

    return query
    select
        v_id,
        'pendiente'::text,
        v_monto,
        v_puntos,
        'Recarga solicitada. Tus puntos se acreditarán una vez validado el pago.';
end $$;

comment on function public.solicitar_recarga_transferencia(uuid, numeric, text)
    is 'Crea una recarga en estado pendiente. Los puntos se acreditan al aprobarla. Ratio 1 ARS = 1 punto.';

grant execute on function public.solicitar_recarga_transferencia(uuid, numeric, text)
    to authenticated;


-- ============================================================================
-- 4 · RPC: aprobar_recarga_puntos()
-- ============================================================================
-- Sólo SuperAdmin (o service_role para tareas administrativas).
-- Todo el cuerpo corre en UNA transacción: si falla el update de la
-- billetera, la recarga NO queda aprobada.
--
-- Códigos de error: sin_permisos, recarga_no_encontrada, recarga_no_pendiente,
--                   admin_id_requerido, admin_id_no_coincide.

create or replace function public.aprobar_recarga_puntos(
    p_recarga_id uuid,
    p_admin_id   uuid
)
returns table (
    exito        boolean,
    puntos       numeric,
    saldo_nuevo  numeric,
    mensaje      text
)
language plpgsql
security definer
set search_path = public
as $$
declare
    v_admin       uuid;
    v_salon_id    uuid;
    v_puntos      numeric;
    v_estado      text;
    v_saldo_nuevo numeric;
begin
    if not (public.es_super_admin() or coalesce(auth.role(), '') = 'service_role') then
        raise exception 'sin_permisos';
    end if;

    v_admin := coalesce(auth.uid(), p_admin_id);
    if v_admin is null then
        raise exception 'admin_id_requerido';
    end if;
    -- Si hay sesión y también mandan un id, tienen que ser el mismo:
    -- así no se puede firmar la auditoría con el id de otra persona.
    if auth.uid() is not null and p_admin_id is not null and p_admin_id <> auth.uid() then
        raise exception 'admin_id_no_coincide';
    end if;

    -- Bloqueo de fila: dos aprobaciones simultáneas no pueden sumar doble.
    select r.salon_id, r.puntos_equivalentes, r.estado
      into v_salon_id, v_puntos, v_estado
    from public.recargas_puntos r
    where r.id = p_recarga_id
    for update;

    if not found then
        raise exception 'recarga_no_encontrada';
    end if;
    if v_estado <> 'pendiente' then
        raise exception 'recarga_no_pendiente';
    end if;

    update public.recargas_puntos r
       set estado        = 'aprobado',
           resuelto_en   = now(),
           resuelto_por  = v_admin
     where r.id = p_recarga_id;

    -- Acreditación: crea la billetera si el salón todavía no tenía una.
    insert into public.billeteras_salones (salon_id, saldo_actual)
    values (v_salon_id, v_puntos)
    on conflict (salon_id) do update
        set saldo_actual = billeteras_salones.saldo_actual + excluded.saldo_actual
    returning saldo_actual into v_saldo_nuevo;

    return query
    select
        true,
        v_puntos,
        v_saldo_nuevo,
        'Recarga aprobada: ' || v_puntos::text || ' puntos acreditados.';
end $$;

comment on function public.aprobar_recarga_puntos(uuid, uuid)
    is 'Aprueba una recarga pendiente y suma los puntos a la billetera del salón. Sólo SuperAdmin.';

grant execute on function public.aprobar_recarga_puntos(uuid, uuid) to authenticated;


-- ============================================================================
-- 5 · BASE PARA MERCADOPAGO (NO IMPLEMENTADO AÚN)
-- ============================================================================
-- Cuando se conecte MercadoPago, el flujo cambia sólo en el ORIGEN del pago:
-- la tabla recargas_puntos se reutiliza con metodo_pago = 'mercadopago'.
--
-- 5.1 · Tabla de pagos del proveedor (una fila por preferencia/intención):
--
--   create table if not exists public.pagos_mp (
--       id                  uuid primary key default gen_random_uuid(),
--       recarga_id          uuid not null references public.recargas_puntos (id) on delete cascade,
--       mp_preference_id    text,
--       mp_payment_id       text unique,          -- idempotencia del webhook
--       mp_status           text,                 -- pending | approved | rejected
--       mp_status_detail    text,
--       payload             jsonb,                -- respuesta cruda para auditar
--       creado_en           timestamptz not null default now(),
--       actualizado_en      timestamptz not null default now()
--   );
--   create index on public.pagos_mp (recarga_id);
--   create unique index on public.pagos_mp (mp_payment_id);
--
-- 5.2 · Función que consumiría el webhook (Edge Function `mp-webhook`):
--
--   public.confirmar_pago_mp(p_mp_payment_id text, p_status text, p_payload jsonb)
--     - buscar pagos_mp por mp_payment_id (si ya existe: salir, es un reintento)
--     - si status = 'approved'  -> llamar aprobar_recarga_puntos(recarga_id, null)
--     - si status = 'rejected'  -> estado 'rechazado' + motivo_rechazo
--
-- 5.3 · La RPC de aprobación NO cambia: tanto la transferencia manual como el
--       webhook de MP terminan en aprobar_recarga_puntos(). La diferencia es
--       quién la invoca (SuperAdmin vs service_role).
--
-- 5.4 · Variables de entorno necesarias cuando se active:
--       MP_ACCESS_TOKEN, MP_WEBHOOK_SECRET, MP_NOTIFICATION_URL.


-- ============================================================================
-- 6 · Recargar el cache de esquema de PostgREST
-- ============================================================================

notify pgrst, 'reload schema';


-- ============================================================================
-- VERIFICACIÓN (opcional)
-- ============================================================================
-- select id, salon_id, monto_ars, puntos_equivalentes, estado, comprobante, creado_en
--   from public.recargas_puntos
--  order by creado_en desc
--  limit 20;
--
-- -- como SuperAdmin:
-- select * from public.aprobar_recarga_puntos('<recarga-id>'::uuid, null);
