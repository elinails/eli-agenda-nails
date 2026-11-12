-- ============================================================================
-- ELIMA HUB · I100 · TURNOS LIBERADOS (ofertas de último minuto)
--
-- Objetivo:
--   1) La dueña libera un turno cancelado con un precio de oferta.
--   2) El Marketplace lo muestra destacado para hoy/mañana.
--   3) La clienta lo reserva sin cuenta; se crea una solicitud pendiente
--      dentro del flujo existente de solicitudes_reserva.
--
-- Decisiones de seguridad:
--   · Publicar: sólo owner del salón (auth.uid + es_owner).
--   · Reservar: RPC pública, con bloqueo FOR UPDATE y validación de vigencia.
--   · La tabla no se escribe directamente: todo pasa por RPC security definer.
--   · No se toca el flujo normal de public_crear_solicitud() ni solicitar_aprobar.
--
-- NOTA DE CONTACTO:
--   El marketplace ya pide email para las ofertas (p_cliente_email). Para no
--   romper el flujo existente, solicitudes_reserva.cliente_telefono pasa a ser
--   nullable y se agrega cliente_email. La UI del salón muestra el email para
--   que la reserva no quede sin canal de contacto.
--
-- Idempotente. Ejecutar completo en el SQL Editor de Supabase.
-- ============================================================================

begin;

-- ============================================================================
-- 1 · TABLA DE OFERTAS
-- ============================================================================

create table if not exists public.turnos_liberados (
    id              uuid primary key default gen_random_uuid(),
    salon_id        uuid not null references public.salones(id) on delete cascade,
    turno_id        bigint not null unique references public.turnos(id) on delete cascade,
    servicio_id     bigint not null references public.servicios(id) on delete cascade,
    fecha           date not null,
    hora            time without time zone not null,
    precio_original integer not null,
    precio_oferta   integer not null,
    estado          text not null default 'disponible',
    creado_en       timestamptz not null default now(),
    constraint turnos_liberados_estado_check
        check (estado in ('disponible', 'reservado', 'expirado')),
    constraint turnos_liberados_precio_check
        check (precio_original > 0 and precio_oferta > 0 and precio_oferta < precio_original)
);

create index if not exists turnos_liberados_disponibles_idx
    on public.turnos_liberados (estado, fecha, hora);

create index if not exists turnos_liberados_salon_idx
    on public.turnos_liberados (salon_id, estado, creado_en desc);

alter table public.turnos_liberados enable row level security;

drop policy if exists turnos_liberados_owner_lectura on public.turnos_liberados;
create policy turnos_liberados_owner_lectura on public.turnos_liberados
    for select to authenticated
    using (public.es_owner(salon_id) or public.es_super_admin());

-- Sin policies de INSERT/UPDATE/DELETE: la oferta sólo nace y cambia por RPC.
revoke all on public.turnos_liberados from anon, authenticated;
grant select on public.turnos_liberados to authenticated;
grant all on public.turnos_liberados to service_role;

comment on table public.turnos_liberados is
    'Ofertas de último minuto publicadas por la dueña de un salón (I100).';
comment on column public.turnos_liberados.turno_id is
    'Turno original que se cancela al publicar la oferta. UNIQUE para evitar duplicados.';
comment on column public.turnos_liberados.estado is
    'disponible → visible en Marketplace; reservado → solicitud creada; expirado → fuera de vigencia.';


-- ============================================================================
-- 2 · ADAPTACIÓN COMPATIBLE DE SOLICITUDES
-- ============================================================================
-- El flujo normal sigue exigiendo teléfono desde public_crear_solicitud().
-- Sólo las ofertas pueden crear una solicitud sin teléfono, con email.

alter table public.solicitudes_reserva
    add column if not exists cliente_email text;

alter table public.solicitudes_reserva
    add column if not exists turno_liberado_id uuid;

alter table public.solicitudes_reserva
    drop constraint if exists solicitudes_turno_liberado_fk;

alter table public.solicitudes_reserva
    add constraint solicitudes_turno_liberado_fk
    foreign key (turno_liberado_id) references public.turnos_liberados(id) on delete set null;

alter table public.solicitudes_reserva
    drop constraint if exists solicitudes_email_check;

alter table public.solicitudes_reserva
    add constraint solicitudes_email_check
    check (cliente_email is null or char_length(btrim(cliente_email)) between 5 and 160);

alter table public.solicitudes_reserva
    alter column cliente_telefono drop not null;

alter table public.solicitudes_reserva
    drop constraint if exists solicitudes_telefono_check;

alter table public.solicitudes_reserva
    add constraint solicitudes_telefono_check
    check (
        cliente_telefono is null
        or char_length(regexp_replace(cliente_telefono, '\D', '', 'g')) between 6 and 20
    );

create index if not exists solicitudes_email_idx
    on public.solicitudes_reserva (lower(cliente_email));

create index if not exists solicitudes_turno_liberado_idx
    on public.solicitudes_reserva (turno_liberado_id);

comment on column public.solicitudes_reserva.cliente_email is
    'Email de contacto (obligatorio en reservas de turnos liberados).';
comment on column public.solicitudes_reserva.turno_liberado_id is
    'Oferta de último minuto que originó la solicitud, si aplica.';


-- ============================================================================
-- 3 · PUBLICAR OFERTA (sólo owner)
-- ============================================================================

create or replace function public.publicar_turno_liberado(
    p_turno_id bigint,
    p_precio_oferta integer
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_turno        record;
    v_servicio     record;
    v_hoy          date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
    v_ahora        time := (now() at time zone 'America/Argentina/Buenos_Aires')::time;
    v_id           uuid;
    v_status       text;
begin
    if auth.uid() is null then
        raise exception 'sin_sesion';
    end if;

    select t.id, t.salon_id, t.servicio_id, t.appointment_date,
           t.appointment_time, t.price, lower(coalesce(t.status, '')) as status
      into v_turno
      from public.turnos t
     where t.id = p_turno_id
     for update;

    if not found then
        raise exception 'turno_no_existe';
    end if;

    if not public.es_owner(v_turno.salon_id) then
        raise exception 'sin_permisos';
    end if;

    v_status := coalesce(v_turno.status, '');
    if v_status in ('cancelled', 'cancelado', 'completed', 'realizado') then
        raise exception 'turno_no_liberable';
    end if;

    if v_turno.servicio_id is null then
        raise exception 'servicio_requerido';
    end if;

    select sv.nombre, sv.duracion_minutos
      into v_servicio
      from public.servicios sv
     where sv.id = v_turno.servicio_id
       and sv.salon_id = v_turno.salon_id;

    if not found then
        raise exception 'servicio_invalido';
    end if;

    if v_turno.appointment_date < v_hoy
       or v_turno.appointment_date > (v_hoy + 1) then
        raise exception 'solo_hoy_o_manana';
    end if;

    if v_turno.appointment_date = v_hoy
       and v_turno.appointment_time <= v_ahora then
        raise exception 'turno_vencido';
    end if;

    if coalesce(v_turno.price, 0) <= 0 then
        raise exception 'precio_original_invalido';
    end if;

    if p_precio_oferta is null
       or p_precio_oferta <= 0
       or p_precio_oferta >= v_turno.price then
        raise exception 'precio_oferta_invalido';
    end if;

    if exists (
        select 1
          from public.turnos_liberados tl
         where tl.turno_id = p_turno_id
    ) then
        raise exception 'turno_ya_liberado';
    end if;

    insert into public.turnos_liberados
        (salon_id, turno_id, servicio_id, fecha, hora,
         precio_original, precio_oferta, estado)
    values
        (v_turno.salon_id, p_turno_id, v_turno.servicio_id,
         v_turno.appointment_date, v_turno.appointment_time,
         v_turno.price, p_precio_oferta, 'disponible')
    returning id into v_id;

    update public.turnos
       set status = 'cancelled'
     where id = p_turno_id
       and salon_id = v_turno.salon_id;

    return jsonb_build_object(
        'id', v_id,
        'turno_id', p_turno_id,
        'estado', 'disponible',
        'precio_original', v_turno.price,
        'precio_oferta', p_precio_oferta,
        'descuento_pct', round(
            (1 - (p_precio_oferta::numeric / v_turno.price)) * 100
        )::integer
    );

exception
    when unique_violation then
        raise exception 'turno_ya_liberado';
end $$;

comment on function public.publicar_turno_liberado(bigint, integer) is
    'Owner libera un turno de hoy/mañana con descuento. Crea la oferta y marca el turno original como cancelled, todo transaccional (I100).';

revoke all on function public.publicar_turno_liberado(bigint, integer) from public;
grant execute on function public.publicar_turno_liberado(bigint, integer) to authenticated;


-- ============================================================================
-- 4 · LEER OFERTAS PÚBLICAS (anon)
-- ============================================================================

create or replace function public.obtener_turnos_liberados()
returns table (
    id                   uuid,
    salon_slug           text,
    salon_nombre         text,
    salon_rubro          text,
    salon_bio            text,
    salon_logo_url       text,
    salon_foto_portada_url text,
    salon_instagram      text,
    salon_direccion      text,
    count_resenas        bigint,
    promedio_estrellas   numeric,
    servicio_id          bigint,
    servicio_nombre      text,
    servicio_duracion    integer,
    fecha                date,
    hora                 time without time zone,
    precio_original      integer,
    precio_oferta        integer,
    descuento_pct        integer,
    creado_en            timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
    with reloj as (
        select
            (now() at time zone 'America/Argentina/Buenos_Aires')::date as hoy,
            (now() at time zone 'America/Argentina/Buenos_Aires')::time as ahora
    )
    select
        tl.id,
        s.slug,
        s.nombre,
        s.rubro,
        coalesce(s.bio, s.descripcion, ''),
        s.logo_url,
        s.foto_portada_url,
        s.instagram,
        nullif(btrim(s.direccion), ''),
        coalesce(rev.count_resenas, 0)::bigint,
        coalesce(rev.promedio_estrellas, 0)::numeric,
        tl.servicio_id,
        coalesce(sv.nombre, 'Servicio'),
        sv.duracion_minutos,
        tl.fecha,
        tl.hora,
        tl.precio_original,
        tl.precio_oferta,
        round((1 - (tl.precio_oferta::numeric / tl.precio_original)) * 100)::integer,
        tl.creado_en
      from public.turnos_liberados tl
      join public.salones s
        on s.id = tl.salon_id
      join public.servicios sv
        on sv.id = tl.servicio_id
      cross join reloj r
      left join lateral (
          select
              count(*)::bigint as count_resenas,
              round(avg(re.estrellas)::numeric, 1) as promedio_estrellas
            from public.resenas re
           where re.salon_id = s.id
      ) rev on true
     where tl.estado = 'disponible'
       and s.publicado is true
       and s.activo is true
       and s.slug is not null
       and (
            (tl.fecha = r.hoy and tl.hora > r.ahora)
            or tl.fecha = (r.hoy + 1)
       )
     order by
        case when tl.fecha = r.hoy then 0 else 1 end,
        tl.hora asc,
        tl.creado_en asc
     limit 24;
$$;

comment on function public.obtener_turnos_liberados() is
    'Ofertas disponibles de hoy/mañana con datos públicos del salón y servicio (I100). Segura para anon.';

revoke all on function public.obtener_turnos_liberados() from public;
grant execute on function public.obtener_turnos_liberados() to anon, authenticated;


-- ============================================================================
-- 5 · RESERVAR OFERTA (público, atómico)
-- ============================================================================
-- El email es el contacto de la oferta. El teléfono se agrega como parámetro
-- opcional al final para no perder el WhatsApp cuando el formulario lo tenga:
-- las llamadas con 3 argumentos siguen funcionando.

create or replace function public.reservar_turno_liberado(
    p_turno_liberado_id uuid,
    p_cliente_email text,
    p_cliente_nombre text,
    p_cliente_telefono text default null
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_oferta       public.turnos_liberados%rowtype;
    v_email        text := lower(btrim(coalesce(p_cliente_email, '')));
    v_nombre       text := btrim(coalesce(p_cliente_nombre, ''));
    v_telefono     text := nullif(regexp_replace(coalesce(p_cliente_telefono, ''), '\D', '', 'g'), '');
    v_hoy          date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
    v_ahora        time := (now() at time zone 'America/Argentina/Buenos_Aires')::time;
    v_servicio     record;
    v_solicitud_id bigint;
begin
    if v_nombre = '' or char_length(v_nombre) > 80 then
        raise exception 'nombre_invalido';
    end if;

    if v_email = ''
       or v_email !~* '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]{2,}$' then
        raise exception 'email_invalido';
    end if;

    if v_telefono is not null
       and (char_length(v_telefono) < 6 or char_length(v_telefono) > 20) then
        raise exception 'telefono_invalido';
    end if;

    select *
      into v_oferta
      from public.turnos_liberados
     where id = p_turno_liberado_id
       and estado = 'disponible'
     for update;

    if not found then
        raise exception 'turno_liberado_no_disponible';
    end if;

    if v_oferta.fecha < v_hoy
       or (v_oferta.fecha = v_hoy and v_oferta.hora <= v_ahora) then
        raise exception 'turno_liberado_vencido';
    end if;

    if not exists (
        select 1
          from public.salones s
         where s.id = v_oferta.salon_id
           and s.publicado is true
           and s.activo is true
    ) then
        raise exception 'salon_no_disponible';
    end if;

    select sv.nombre, sv.duracion_minutos
      into v_servicio
      from public.servicios sv
     where sv.id = v_oferta.servicio_id
       and sv.salon_id = v_oferta.salon_id;

    if not found then
        raise exception 'servicio_invalido';
    end if;

    insert into public.solicitudes_reserva
        (salon_id, cliente_nombre, cliente_telefono, cliente_email,
         fecha, hora, servicio_id, servicio_nombre, servicio_precio,
         servicio_duracion, estado, notas, turno_liberado_id)
    values
        (v_oferta.salon_id, v_nombre, v_telefono, v_email,
         v_oferta.fecha, v_oferta.hora, v_oferta.servicio_id, v_servicio.nombre,
         v_oferta.precio_oferta, v_servicio.duracion_minutos, 'pendiente',
         '⚡ Turno liberado · oferta $' || v_oferta.precio_oferta ||
         ' (antes $' || v_oferta.precio_original || ')',
         v_oferta.id)
    returning id into v_solicitud_id;

    update public.turnos_liberados
       set estado = 'reservado'
     where id = v_oferta.id
       and estado = 'disponible';

    if not found then
        raise exception 'turno_liberado_no_disponible';
    end if;

    return jsonb_build_object(
        'solicitud_id', v_solicitud_id,
        'turno_liberado_id', v_oferta.id,
        'estado', 'pendiente',
        'precio_oferta', v_oferta.precio_oferta,
        'fecha', v_oferta.fecha,
        'hora', v_oferta.hora
    );
end $$;

comment on function public.reservar_turno_liberado(uuid, text, text, text) is
    'Reserva atómica de una oferta: bloquea la fila, valida vigencia y crea la solicitud pendiente. Email obligatorio; teléfono opcional (I100).';

revoke all on function public.reservar_turno_liberado(uuid, text, text, text) from public;
grant execute on function public.reservar_turno_liberado(uuid, text, text, text) to anon, authenticated;


-- ============================================================================
-- 6 · RECARGAR SCHEMA CACHE
-- ============================================================================

notify pgrst, 'reload schema';

commit;


-- ============================================================================
-- VERIFICACIÓN MANUAL
-- ============================================================================
-- 1) Tabla y permisos:
--    select * from public.turnos_liberados;
--
-- 2) Publicar (con sesión de la dueña, turno de hoy/mañana con servicio):
--    select public.publicar_turno_liberado(123, 18000);
--
-- 3) Leer como anon:
--    select * from public.obtener_turnos_liberados();
--
-- 4) Reservar como anon (3 argumentos; email obligatorio):
--    select public.reservar_turno_liberado(
--      'UUID-DE-LA-OFERTA', 'clienta@email.com', 'Ana Gómez');
--
-- 5) Doble reserva: la segunda llamada debe fallar con
--    turno_liberado_no_disponible.
--
-- 6) Flujo normal intacto:
--    select public.public_crear_solicitud(
--      'UUID-SALON', 'Ana', '1122334455', current_date + 1, '15:30', 456);
-- ============================================================================
