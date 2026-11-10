-- ============================================================================
-- ELI M. NAILS · I69 · Perfil público y solicitud de reserva
--
-- Contenido:
--   1) salones.direccion (perfil público)
--   2) planes.caracteristicas (gate reservas_link) — idempotente
--   3) solicitudes_reserva + RLS (miembros leen; insert solo por RPC)
--   4) public_salon_detalle(p_slug)          — anon, solo datos públicos
--   5) public_crear_solicitud(...)           — anon, valida + anti-spam 3/día
--   6) solicitud_aprobar(p_id)               — miembro: cliente + turno confirmed
--   7) solicitud_rechazar(p_id, p_motivo)    — miembro
--
-- Idempotente. No toca datos privados ni tablas existentes más allá de
-- agregar la columna pública `direccion`.
-- ============================================================================


-- ============================================================================
-- 1 · DIRECCIÓN PÚBLICA
-- ============================================================================

alter table public.salones add column if not exists direccion text;

alter table public.salones drop constraint if exists salones_direccion_check;
alter table public.salones add constraint salones_direccion_check
    check (direccion is null or char_length(btrim(direccion)) between 1 and 200);

comment on column public.salones.direccion is
    'Dirección pública que se muestra en el perfil del marketplace (opcional).';


-- ============================================================================
-- 2 · GATE DE PLAN (reservas_link)
-- ============================================================================

alter table public.planes add column if not exists caracteristicas jsonb not null default '{}'::jsonb;

update public.planes
   set caracteristicas = coalesce(caracteristicas, '{}'::jsonb) || jsonb_build_object(
        'sin_publicidad', false, 'reservas_link', false,
        'automatizaciones', false, 'reportes_avanzados', false)
 where id = 'gratis';

update public.planes
   set caracteristicas = coalesce(caracteristicas, '{}'::jsonb) || jsonb_build_object(
        'sin_publicidad', true, 'reservas_link', true,
        'automatizaciones', true, 'reportes_avanzados', true)
 where id = 'pro';

update public.planes
   set caracteristicas = coalesce(caracteristicas, '{}'::jsonb) || jsonb_build_object(
        'sin_publicidad', true, 'reservas_link', true,
        'automatizaciones', true, 'reportes_avanzados', true)
 where id = 'premium';


-- ============================================================================
-- 3 · TABLA DE SOLICITUDES
-- ============================================================================

create table if not exists public.solicitudes_reserva (
    id                bigint generated always as identity primary key,
    salon_id          uuid not null references public.salones(id) on delete cascade,
    cliente_nombre    text not null,
    cliente_telefono  text not null,
    fecha             date not null,
    hora              time without time zone not null,
    servicio_id       bigint references public.servicios(id) on delete set null,
    servicio_nombre   text,
    servicio_precio   integer,
    servicio_duracion integer,
    estado            text not null default 'pendiente',
    notas             text,
    turno_id          bigint references public.turnos(id) on delete set null,
    creado_en         timestamptz not null default now(),
    actualizado_en    timestamptz not null default now()
);

alter table public.solicitudes_reserva drop constraint if exists solicitudes_estado_check;
alter table public.solicitudes_reserva add constraint solicitudes_estado_check
    check (estado in ('pendiente', 'aprobada', 'rechazada'));

alter table public.solicitudes_reserva drop constraint if exists solicitudes_nombre_check;
alter table public.solicitudes_reserva add constraint solicitudes_nombre_check
    check (char_length(btrim(cliente_nombre)) between 2 and 80);

alter table public.solicitudes_reserva drop constraint if exists solicitudes_telefono_check;
alter table public.solicitudes_reserva add constraint solicitudes_telefono_check
    check (char_length(regexp_replace(cliente_telefono, '\D', '', 'g')) between 6 and 20);

alter table public.solicitudes_reserva drop constraint if exists solicitudes_notas_check;
alter table public.solicitudes_reserva add constraint solicitudes_notas_check
    check (notas is null or char_length(notas) <= 500);

create index if not exists solicitudes_salon_estado_idx
    on public.solicitudes_reserva (salon_id, estado, creado_en desc);

create index if not exists solicitudes_telefono_dia_idx
    on public.solicitudes_reserva (cliente_telefono, salon_id, creado_en desc);

-- RLS: los miembros leen; update/delete directo solo dueña. El insert entra SOLO por la RPC definer.
alter table public.solicitudes_reserva enable row level security;

drop policy if exists solicitudes_owner_lectura on public.solicitudes_reserva;
create policy solicitudes_owner_lectura on public.solicitudes_reserva
for select to authenticated
using (public.es_miembro(salon_id));

drop policy if exists solicitudes_owner_edicion on public.solicitudes_reserva;
create policy solicitudes_owner_edicion on public.solicitudes_reserva
for update to authenticated
using (public.es_owner(salon_id))
with check (public.es_owner(salon_id));

drop policy if exists solicitudes_owner_baja on public.solicitudes_reserva;
create policy solicitudes_owner_baja on public.solicitudes_reserva
for delete to authenticated
using (public.es_owner(salon_id));


-- ============================================================================
-- 4 · DETALLE PÚBLICO (anon)
-- ============================================================================

drop function if exists public.public_salon_detalle(text);

create or replace function public.public_salon_detalle(p_slug text)
returns jsonb
language sql
stable
security definer
set search_path = public
as $$
    select jsonb_build_object(
        'id',             s.id,
        'salon_id',       s.id,
        'slug',           s.slug,
        'nombre',         s.nombre,
        'rubro',          s.rubro,
        'bio',            coalesce(s.bio, s.descripcion, ''),
        'logo_url',       s.logo_url,
        'foto_portada_url', s.foto_portada_url,
        'instagram',      s.instagram,
        'direccion',      s.direccion,
        'reservas_habilitadas', coalesce((pl.caracteristicas ->> 'reservas_link')::boolean, false),
        'servicios', coalesce((
            select jsonb_agg(jsonb_build_object(
                       'id', v.id,
                       'nombre', v.nombre,
                       'precio', v.precio_base,
                       'duracion', v.duracion_minutos
                   ) order by v.nombre)
              from public.servicios v
             where v.salon_id = s.id
        ), '[]'::jsonb)
    )
    from public.salones s
    left join public.planes pl on pl.id = s.plan_id
    where s.slug = lower(btrim(coalesce(p_slug, '')))
      and s.publicado is true
      and s.activo is true
    limit 1;
$$;

comment on function public.public_salon_detalle(text) is
    'Perfil público del salón: solo datos públicos + servicios. Nunca email, dueño, plan ni facturación.';

revoke all on function public.public_salon_detalle(text) from public;
grant execute on function public.public_salon_detalle(text) to anon, authenticated;


-- ============================================================================
-- 5 · CREAR SOLICITUD (anon, gate Pro + anti-spam 3/día)
-- ============================================================================

drop function if exists public.public_crear_solicitud(uuid, text, text, date, time, bigint);

create or replace function public.public_crear_solicitud(
    p_salon_id          uuid,
    p_cliente_nombre    text,
    p_cliente_telefono  text,
    p_fecha             date,
    p_hora              time,
    p_servicio_id       bigint
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    v_nombre   text := btrim(coalesce(p_cliente_nombre, ''));
    v_tel      text := regexp_replace(coalesce(p_cliente_telefono, ''), '\D', '', 'g');
    v_hoy      date := (now() at time zone 'America/Argentina/Buenos_Aires')::date;
    v_habilitado boolean;
    v_servicio record;
    v_cantidad integer;
    v_id       bigint;
begin
    if v_nombre = '' or char_length(v_nombre) > 80 then
        raise exception 'nombre_invalido';
    end if;
    if char_length(v_tel) < 6 or char_length(v_tel) > 20 then
        raise exception 'telefono_invalido';
    end if;
    if p_fecha is null then
        raise exception 'fecha_invalida';
    end if;
    if p_hora is null then
        raise exception 'hora_invalida';
    end if;
    if p_fecha < v_hoy then
        raise exception 'fecha_invalida';
    end if;

    select coalesce((pl.caracteristicas ->> 'reservas_link')::boolean, false)
      into v_habilitado
      from public.salones s
      join public.planes pl on pl.id = s.plan_id
     where s.id = p_salon_id
       and s.publicado is true
       and s.activo is true;

    if not found then
        raise exception 'salon_no_disponible';
    end if;
    if not v_habilitado then
        raise exception 'reservas_no_habilitadas';
    end if;

    select v.id, v.nombre, v.precio_base, v.duracion_minutos
      into v_servicio
      from public.servicios v
     where v.id = p_servicio_id
       and v.salon_id = p_salon_id;

    if not found then
        raise exception 'servicio_invalido';
    end if;

    -- Mismo teléfono + salón + fecha + hora pendiente: no duplicar.
    select count(*)
      into v_cantidad
      from public.solicitudes_reserva sr
     where sr.salon_id = p_salon_id
       and sr.cliente_telefono = v_tel
       and sr.fecha = p_fecha
       and sr.hora = p_hora
       and sr.estado = 'pendiente';

    if v_cantidad > 0 then
        raise exception 'solicitud_duplicada';
    end if;

    -- Anti-spam: 3 solicitudes PENDIENTES por teléfono + salón en 24 h.
    select count(*)
      into v_cantidad
      from public.solicitudes_reserva sr
     where sr.salon_id = p_salon_id
       and sr.cliente_telefono = v_tel
       and sr.estado = 'pendiente'
       and sr.creado_en > now() - interval '24 hours';

    if v_cantidad >= 3 then
        raise exception 'demasiadas_solicitudes';
    end if;

    insert into public.solicitudes_reserva
        (salon_id, cliente_nombre, cliente_telefono, fecha, hora,
         servicio_id, servicio_nombre, servicio_precio, servicio_duracion, estado)
    values
        (p_salon_id, v_nombre, v_tel, p_fecha, p_hora,
         v_servicio.id, v_servicio.nombre, v_servicio.precio_base, v_servicio.duracion_minutos, 'pendiente')
    returning id into v_id;

    return jsonb_build_object('id', v_id, 'estado', 'pendiente');
end $$;

comment on function public.public_crear_solicitud(uuid, text, text, date, time, bigint) is
    'Solicitud de reserva anónima. Valida salón publicado/activo, gate reservas_link y 3/día por teléfono.';

revoke all on function public.public_crear_solicitud(uuid, text, text, date, time, bigint) from public;
grant execute on function public.public_crear_solicitud(uuid, text, text, date, time, bigint) to anon, authenticated;


-- ============================================================================
-- 6 · APROBAR (miembro del salón: dueña o empleada)
-- ============================================================================

drop function if exists public.aprobar_solicitud(uuid);
drop function if exists public.aprobar_solicitud(bigint);
drop function if exists public.solicitud_aprobar(bigint);

create or replace function public.solicitud_aprobar(p_id bigint)
returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare
    s         record;
    v_cliente bigint;
    v_turno   bigint;
    v_staff   uuid;
begin
    select * into s
      from public.solicitudes_reserva
     where id = p_id
     for update;

    if not found then
        raise exception 'solicitud_no_existe';
    end if;
    if not public.es_miembro(s.salon_id) then
        raise exception 'sin_permisos';
    end if;
    if s.estado <> 'pendiente' then
        raise exception 'solicitud_no_pendiente';
    end if;
    if s.fecha < current_date
       or (s.fecha = current_date and s.hora < localtime) then
        raise exception 'solicitud_vencida';
    end if;

    if exists (
        select 1
          from public.turnos t
         where t.salon_id = s.salon_id
           and t.appointment_date = s.fecha
           and t.appointment_time = s.hora
           and t.status not in ('cancelled', 'cancelado')
    ) then
        raise exception 'horario_ocupado';
    end if;

    -- CRM: buscar por teléfono normalizado dentro del salón.
    select c.id into v_cliente
      from public.clientes c
     where c.salon_id = s.salon_id
       and regexp_replace(coalesce(c.telefono, ''), '\D', '', 'g') = s.cliente_telefono
     limit 1;

    v_staff := case
        when public.es_owner(s.salon_id) then null
        else auth.uid()
    end;

    if v_cliente is null then
        insert into public.clientes (salon_id, user_id, nombre, telefono, staff_user_id)
        values (s.salon_id, auth.uid(), s.cliente_nombre, s.cliente_telefono, v_staff)
        returning id into v_cliente;
    end if;

    insert into public.turnos
        (salon_id, user_id, cliente_id, servicio_id, client_name, service_type,
         appointment_date, appointment_time, price, notes, status, staff_user_id)
    values
        (s.salon_id, auth.uid(), v_cliente, s.servicio_id, s.cliente_nombre,
         coalesce(s.servicio_nombre, ''), s.fecha, s.hora,
         coalesce(s.servicio_precio, 0),
         'Solicitud online · ' || s.cliente_telefono, 'confirmed', v_staff)
    returning id into v_turno;

    update public.solicitudes_reserva
       set estado = 'aprobada',
           turno_id = v_turno,
           actualizado_en = now()
     where id = p_id;

    return v_turno;
end $$;

comment on function public.solicitud_aprobar(bigint) is
    'Miembro del salón aprueba: crea/reutiliza cliente por teléfono y crea el turno confirmado, todo transaccional.';

revoke all on function public.solicitud_aprobar(bigint) from public;
grant execute on function public.solicitud_aprobar(bigint) to authenticated;


-- ============================================================================
-- 7 · RECHAZAR (miembro del salón)
-- ============================================================================

drop function if exists public.rechazar_solicitud(uuid, text);
drop function if exists public.rechazar_solicitud(bigint, text);
drop function if exists public.solicitud_rechazar(bigint, text);

create or replace function public.solicitud_rechazar(p_id bigint, p_motivo text default null)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
    s record;
    v_motivo text := nullif(btrim(coalesce(p_motivo, '')), '');
begin
    select * into s
      from public.solicitudes_reserva
     where id = p_id
     for update;

    if not found then
        raise exception 'solicitud_no_existe';
    end if;
    if not public.es_miembro(s.salon_id) then
        raise exception 'sin_permisos';
    end if;
    if s.estado <> 'pendiente' then
        raise exception 'solicitud_no_pendiente';
    end if;

    update public.solicitudes_reserva
       set estado = 'rechazada',
           notas = coalesce(v_motivo, notas),
           actualizado_en = now()
     where id = p_id;
end $$;

comment on function public.solicitud_rechazar(bigint, text) is
    'Miembro del salón rechaza una solicitud pendiente, con motivo opcional.';

revoke all on function public.solicitud_rechazar(bigint, text) from public;
grant execute on function public.solicitud_rechazar(bigint, text) to authenticated;


-- ============================================================================
-- 7b · ALIASES compatibles con la app (aprobar_solicitud / rechazar_solicitud)
-- ============================================================================

create or replace function public.aprobar_solicitud(p_solicitud bigint)
returns bigint
language sql
security definer
set search_path = public
as $$ select public.solicitud_aprobar(p_solicitud); $$;

revoke all on function public.aprobar_solicitud(bigint) from public;
grant execute on function public.aprobar_solicitud(bigint) to authenticated;

create or replace function public.rechazar_solicitud(p_solicitud bigint, p_motivo text default null)
returns void
language sql
security definer
set search_path = public
as $$ select public.solicitud_rechazar(p_solicitud, p_motivo); $$;

revoke all on function public.rechazar_solicitud(bigint, text) from public;
grant execute on function public.rechazar_solicitud(bigint, text) to authenticated;


notify pgrst, 'reload schema';


-- ============================================================================
-- VERIFICACIÓN (correr a mano)
-- ============================================================================
-- 1) detalle público:
--    select public.public_salon_detalle('TU-SLUG');
--
-- 2) gate: un salón gratis no debe poder crear solicitud
--    select public.public_crear_solicitud('UUID-GRATIS', 'Ana', '1122334455',
--           current_date + 1, '15:30', ID-SERVICIO);  -- error reservas_no_habilitadas
--
-- 3) una solicitud válida (3 veces) y la 4ª debe fallar con demasiadas_solicitudes.
--
-- 4) dueña o empleada:
--    select public.solicitud_aprobar(ID-SOLICITUD);
--    select * from public.turnos where id = <turno>;
--    select * from public.clientes where salon_id = '<salon>';
--
-- 5) una empleada puede aprobar; el turno queda asignado a ella.
--
-- 6) RLS: con el token de staff, select * from solicitudes_reserva → filas del salón.
