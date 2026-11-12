-- ============================================================================
-- ELIMA HUB · I93 · NOTIFICACIONES IN-APP
--
-- Bandeja de notificaciones para el salón (dueña/staff) y para el SuperAdmin.
--
--   · salon_id  → notificación dirigida a un salón (la ven sus miembros activos)
--   · admin_id  → notificación dirigida a un admin concreto (auth.uid())
--   · Ambas null → no la ve nadie (se evita por CHECK)
--
-- Las RPC son SECURITY DEFINER y filtran por auth.uid(): el cliente nunca
-- puede pedir notificaciones de otro salón ni de otro admin.
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
    constraint notificaciones_destino_check check (salon_id is not null or admin_id is not null),
    constraint notificaciones_titulo_check  check (char_length(btrim(titulo)) between 1 and 120)
);

comment on table public.notificaciones
    is 'Bandeja in-app: cada fila apunta a un salón o a un admin destinatario.';

create index if not exists notificaciones_salon_idx  on public.notificaciones (salon_id, creado_en desc);
create index if not exists notificaciones_admin_idx  on public.notificaciones (admin_id, creado_en desc);
create index if not exists notificaciones_no_leidas_idx on public.notificaciones (leida) where leida = false;


-- ============================================================================
-- 2 · RLS (defensa en profundidad; las RPC igual filtran)
-- ============================================================================

alter table public.notificaciones enable row level security;

drop policy if exists notificaciones_select on public.notificaciones;
create policy notificaciones_select on public.notificaciones
    for select to authenticated
    using (
        admin_id = auth.uid()
        or (
            salon_id is not null
            and exists (
                select 1 from public.miembros_salon m
                where m.salon_id = notificaciones.salon_id
                  and m.user_id = auth.uid()
                  and coalesce(m.activo, true)
            )
        )
    );

drop policy if exists notificaciones_update on public.notificaciones;
create policy notificaciones_update on public.notificaciones
    for update to authenticated
    using (
        admin_id = auth.uid()
        or (
            salon_id is not null
            and exists (
                select 1 from public.miembros_salon m
                where m.salon_id = notificaciones.salon_id
                  and m.user_id = auth.uid()
                  and coalesce(m.activo, true)
            )
        )
    )
    with check (true);

-- Sin policies de INSERT/DELETE para authenticated: sólo escribe el backend
-- (service_role / SuperAdmin desde una función de servidor).

revoke all on public.notificaciones from anon;
grant select, update on public.notificaciones to authenticated;


-- ============================================================================
-- 3 · RPC · obtener_notificaciones(p_limit int)
-- ============================================================================
-- Devuelve las notificaciones del usuario actual (por salón o por admin),
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
    where n.admin_id = v_user
       or (
            n.salon_id is not null
            and exists (
                select 1
                from public.miembros_salon m
                where m.salon_id = n.salon_id
                  and m.user_id = v_user
                  and coalesce(m.activo, true)
            )
       )
    order by n.creado_en desc
    limit v_limit;
end $$;

comment on function public.obtener_notificaciones(int)
    is 'Notificaciones del usuario actual (su salón o su usuario admin). Más reciente primero, máximo 50.';

revoke all on function public.obtener_notificaciones(int) from public;
grant execute on function public.obtener_notificaciones(int) to authenticated;


-- ============================================================================
-- 4 · RPC · marcar_notificacion_leida(p_id uuid)
-- ============================================================================
-- Devuelve true sólo si la notificación era del usuario y se marcó.

create or replace function public.marcar_notificacion_leida(p_id uuid)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_user uuid := auth.uid();
begin
    if v_user is null then
        raise exception 'sin_sesion';
    end if;

    update public.notificaciones n
       set leida = true
     where n.id = p_id
       and (
            n.admin_id = v_user
            or (
                n.salon_id is not null
                and exists (
                    select 1
                    from public.miembros_salon m
                    where m.salon_id = n.salon_id
                      and m.user_id = v_user
                      and coalesce(m.activo, true)
                )
            )
       );

    return found;
end $$;

comment on function public.marcar_notificacion_leida(uuid)
    is 'Marca como leída una notificación propia. Devuelve false si no existía o no era del usuario.';

revoke all on function public.marcar_notificacion_leida(uuid) from public;
grant execute on function public.marcar_notificacion_leida(uuid) to authenticated;


-- ============================================================================
-- 5 · Recargar cache de PostgREST
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
-- -- Notificación de prueba para un admin:
-- insert into public.notificaciones (admin_id, titulo, mensaje)
-- values (auth.uid(), 'Prueba admin', 'Si ves esto, la campana funciona.');
--
-- -- Como dueña del salón (con sesión):
-- select * from public.obtener_notificaciones(25);
-- select public.marcar_notificacion_leida('<uuid>'::uuid);
-- ============================================================================
