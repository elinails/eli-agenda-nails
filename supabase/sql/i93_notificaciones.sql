-- ============================================================================
-- ELIMA HUB · I93 · NOTIFICACIONES IN-APP
--
-- Bandeja de notificaciones para el salón (dueña/staff) y para el SuperAdmin.
--
--   · salon_id → notificación dirigida a un salón (la ven sus miembros activos)
--   · salon_id NULL → notificación del SuperAdmin (la ven los superadmins;
--     si admin_id tiene un uuid, sólo ese admin la ve)
--
-- Las RPC son SECURITY DEFINER y filtran por auth.uid(): el cliente nunca
-- puede pedir notificaciones de otro salón ni de otro admin.
--
-- Generación automática:
--   · Nueva recarga solicitada → avisa al SuperAdmin.
--   · Recarga aprobada/rechazada → avisa al salón.
--
-- IDEMPOTENTE: se puede correr varias veces.
-- ============================================================================

begin;


-- ============================================================================
-- 1 · TABLA
-- ============================================================================

create table if not exists public.notificaciones (
    id         uuid primary key default gen_random_uuid(),
    salon_id   uuid references public.salones(id) on delete cascade,
    admin_id   uuid references auth.users(id) on delete cascade,
    titulo     text not null,
    mensaje    text,
    leida      boolean not null default false,
    creado_en  timestamptz not null default now(),
    constraint notificaciones_titulo_check check (char_length(btrim(titulo)) between 1 and 120)
);

-- Versiones anteriores exigían salon_id o admin_id. El modelo actual permite
-- una notificación de SuperAdmin con ambos NULL (broadcast a los admins).
alter table public.notificaciones drop constraint if exists notificaciones_destino_check;

comment on table public.notificaciones
    is 'Bandeja in-app: salon_id NULL = SuperAdmin; salon_id con valor = ese salón.';
comment on column public.notificaciones.admin_id
    is 'Opcional: si está seteado, la notificación de SuperAdmin es para ese admin.';

create index if not exists notificaciones_salon_idx
    on public.notificaciones (salon_id, creado_en desc);
create index if not exists notificaciones_admin_idx
    on public.notificaciones (admin_id, creado_en desc);
create index if not exists notificaciones_no_leidas_idx
    on public.notificaciones (leida) where leida = false;


-- ============================================================================
-- 2 · RLS
-- ============================================================================
-- El cliente NO lee ni escribe la tabla directo: todo pasa por las RPC
-- security definer. Así no se puede filtrar por otro salón ni tocar mensajes.
-- Los triggers de recargas insertan como owner de la tabla.

alter table public.notificaciones enable row level security;

drop policy if exists notificaciones_select on public.notificaciones;
drop policy if exists notificaciones_update on public.notificaciones;

revoke all on public.notificaciones from anon, authenticated;


-- ============================================================================
-- 3 · RPC · obtener_notificaciones(p_limit int)
-- ============================================================================
-- Devuelve las notificaciones del usuario actual (su salón o su rol admin),
-- la más reciente primero. Tope duro de 50.

create or replace function public.obtener_notificaciones(p_limit int default 25)
returns table (
    id        uuid,
    titulo    text,
    mensaje   text,
    leida     boolean,
    creado_en timestamptz
)
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_user  uuid := auth.uid();
    v_limit int;
begin
    if v_user is null then
        raise exception 'sin_sesion';
    end if;

    v_limit := greatest(1, least(coalesce(p_limit, 25), 50));

    return query
    select
        n.id,
        n.titulo,
        coalesce(n.mensaje, '') as mensaje,
        n.leida,
        n.creado_en
    from public.notificaciones n
    where (
            -- Notificación de un salón: la ven sus miembros activos.
            (
                n.salon_id is not null
                and exists (
                    select 1
                    from public.miembros_salon m
                    where m.salon_id = n.salon_id
                      and m.user_id = v_user
                      and coalesce(m.activo, true)
                )
            )
            -- Notificación de SuperAdmin: salon_id NULL.
            or (
                n.salon_id is null
                and (n.admin_id is null or n.admin_id = v_user)
                and public.es_super_admin()
            )
        )
    order by n.creado_en desc
    limit v_limit;
end $$;

comment on function public.obtener_notificaciones(int)
    is 'Notificaciones del usuario actual (su salón o SuperAdmin). Más reciente primero, máximo 50.';

revoke all on function public.obtener_notificaciones(int) from public;
grant execute on function public.obtener_notificaciones(int) to authenticated;


-- ============================================================================
-- 4 · RPC · marcar_notificacion_leida(p_id uuid)
-- ============================================================================
-- Devuelve true sólo si la notificación era del usuario.

create or replace function public.marcar_notificacion_leida(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_user uuid := auth.uid();
    v_rows int;
begin
    if v_user is null then
        raise exception 'sin_sesion';
    end if;

    update public.notificaciones n
       set leida = true
     where n.id = p_id
       and n.leida = false
       and (
            (
                n.salon_id is not null
                and exists (
                    select 1
                    from public.miembros_salon m
                    where m.salon_id = n.salon_id
                      and m.user_id = v_user
                      and coalesce(m.activo, true)
                )
            )
            or (
                n.salon_id is null
                and (n.admin_id is null or n.admin_id = v_user)
                and public.es_super_admin()
            )
       );

    get diagnostics v_rows = row_count;
    if v_rows > 0 then
        return true;
    end if;

    -- Idempotente: si ya estaba leída y es del usuario, también devolvemos true.
    return exists (
        select 1
        from public.notificaciones n
        where n.id = p_id
          and (
                (
                    n.salon_id is not null
                    and exists (
                        select 1
                        from public.miembros_salon m
                        where m.salon_id = n.salon_id
                          and m.user_id = v_user
                          and coalesce(m.activo, true)
                    )
                )
                or (
                    n.salon_id is null
                    and (n.admin_id is null or n.admin_id = v_user)
                    and public.es_super_admin()
                )
          )
    );
end $$;

comment on function public.marcar_notificacion_leida(uuid)
    is 'Marca como leída una notificación propia. Devuelve false si no existía o no era del usuario.';

revoke all on function public.marcar_notificacion_leida(uuid) from public;
grant execute on function public.marcar_notificacion_leida(uuid) to authenticated;


-- ============================================================================
-- 5 · GENERACIÓN AUTOMÁTICA (recargas)
-- ============================================================================
-- Notificaciones del sistema: no dependen del cliente, así no se pueden
-- falsificar ni duplicar desde la app.

create or replace function public.notificar_recarga_solicitada()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_salon text;
    v_monto text;
    v_msg   text;
begin
    select nombre into v_salon from public.salones where id = new.salon_id;
    v_monto := trim(to_char(coalesce(new.monto_ars, 0), 'FM999999999999D00'));

    v_msg := coalesce(nullif(btrim(v_salon), ''), 'Un salón')
          || ' solicitó recargar $' || v_monto
          || ' (comprobante ' || coalesce(nullif(btrim(new.comprobante), ''), 'sin comprobante') || ').';

    insert into public.notificaciones (salon_id, admin_id, titulo, mensaje)
    values (null, null, 'Nueva solicitud de recarga', left(v_msg, 500));

    return new;
end $$;

create or replace function public.notificar_recarga_resuelta()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_titulo text;
    v_msg    text;
begin
    if new.estado is not distinct from old.estado
       or new.estado not in ('aprobado', 'rechazado') then
        return new;
    end if;

    if new.estado = 'aprobado' then
        v_titulo := 'Recarga aprobada';
        v_msg := 'Se acreditaron '
              || trim(to_char(coalesce(new.puntos_equivalentes, 0), 'FM999999999999D00'))
              || ' puntos en tu billetera.';
    else
        v_titulo := 'Recarga rechazada';
        v_msg := 'Motivo: '
              || coalesce(nullif(btrim(new.motivo_rechazo), ''), 'consultá con soporte')
              || '.';
    end if;

    insert into public.notificaciones (salon_id, admin_id, titulo, mensaje)
    values (new.salon_id, null, v_titulo, left(v_msg, 500));

    return new;
end $$;

drop trigger if exists trg_notificar_recarga_solicitada on public.recargas_puntos;
create trigger trg_notificar_recarga_solicitada
    after insert on public.recargas_puntos
    for each row execute function public.notificar_recarga_solicitada();

drop trigger if exists trg_notificar_recarga_resuelta on public.recargas_puntos;
create trigger trg_notificar_recarga_resuelta
    after update of estado on public.recargas_puntos
    for each row execute function public.notificar_recarga_resuelta();


-- ============================================================================
-- 6 · Recargar cache de PostgREST
-- ============================================================================

notify pgrst, 'reload schema';

commit;


-- ============================================================================
-- VERIFICACIÓN / DATOS DE PRUEBA (opcional, correr a mano)
-- ============================================================================
-- -- Notificación de prueba para un salón concreto:
-- insert into public.notificaciones (salon_id, titulo, mensaje)
-- values (
--     (select id from public.salones where slug = 'eli-m-nails'),
--     'Nuevo turno reservado',
--     'Tenés una reserva nueva para mañana a las 15:00.'
-- );
--
-- -- Notificación de prueba para todos los SuperAdmins:
-- insert into public.notificaciones (salon_id, admin_id, titulo, mensaje)
-- values (null, null, 'Prueba admin', 'Si ves esto, la campana funciona.');
--
-- -- Con sesión de la dueña:
-- select * from public.obtener_notificaciones(25);
-- select public.marcar_notificacion_leida('<uuid>'::uuid);
-- ============================================================================
