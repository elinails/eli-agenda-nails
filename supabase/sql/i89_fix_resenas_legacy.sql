-- ============================================================================
-- ELIMA HUB · I89 · P0 de la auditoría del portal de clientas
--
-- Corrige tres defectos de la capa de datos que consume portal.html:
--
--   1. Elimina la sobrecarga legacy crear_resena(bigint, integer, text) que
--      quedó viva en la base, no está versionada en el repo, conserva EXECUTE
--      para anon y tenía una validación tautológica (cualquiera podía insertar
--      reseñas en turnos completados ajenos). Ver I89 de AUDITORIA_PORTAL.md.
--
--   2. Recrea crear_resena(uuid, bigint, smallint, text) para que además de
--      validar salón y estado, exija que el turno pertenezca a la clienta
--      autenticada (clientes.auth_user_id o email vía _mis_clientes()).
--
--   3. Reescribe turnos_de_cliente(text) para que filtre por la identidad de
--      la clienta (_mis_clientes()) en lugar de unir clientes por user_id
--      (que es la cuenta del salón que cargó la ficha). Así la clienta ve sus
--      turnos y deja de ver los turnos completados de otros salones.
--
-- NO toca la lógica de puntos, canjes, billeteras ni el marketplace.
--
-- Requisitos: I66 (_mis_clientes), I80/I81 aplicados.
-- Idempotente: se puede correr más de una vez.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1 · Eliminar la sobrecarga legacy de 3 argumentos
-- ----------------------------------------------------------------------------
drop function if exists public.crear_resena(bigint, integer, text);
drop function if exists public.crear_resena(bigint, smallint, text);

-- ----------------------------------------------------------------------------
-- 2 · crear_resena (4 argumentos) con control de dueño del turno
-- ----------------------------------------------------------------------------
create or replace function public.crear_resena(
    p_salon_id uuid,
    p_turno_id bigint,
    p_estrellas smallint,
    p_comentario text
)
returns public.resenas
language plpgsql
security definer
set search_path = public
as $$
declare
    v_cliente_id bigint;
    v_result public.resenas%rowtype;
begin
    if p_estrellas is null or p_estrellas < 1 or p_estrellas > 5 then
        raise exception 'La calificación debe estar entre 1 y 5 estrellas';
    end if;

    -- El turno tiene que estar completado, ser del salón indicado y pertenecer
    -- a una ficha de la clienta autenticada (vínculo directo o por email).
    select t.cliente_id
      into v_cliente_id
      from public.turnos t
     where t.id = p_turno_id
       and t.salon_id = p_salon_id
       and t.status in ('realizado', 'completed', 'completado')
       and t.cliente_id in (select mc.id from public._mis_clientes() as mc(id))
     limit 1;

    if v_cliente_id is null then
        raise exception 'El turno no existe, no está completado o no pertenece a tu cuenta';
    end if;

    if exists (
        select 1 from public.resenas r where r.turno_id = p_turno_id
    ) then
        raise exception 'Este turno ya tiene una reseña asociada';
    end if;

    insert into public.resenas (salon_id, cliente_id, turno_id, estrellas, comentario)
    values (
        p_salon_id,
        v_cliente_id,
        p_turno_id,
        p_estrellas,
        nullif(btrim(coalesce(p_comentario, '')), '')
    )
    returning * into v_result;

    return v_result;
end;
$$;

revoke all on function public.crear_resena(uuid, bigint, smallint, text) from public, anon;
grant execute on function public.crear_resena(uuid, bigint, smallint, text)
    to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3 · turnos_de_cliente: identidad de la clienta, sin fuga entre salones
-- ----------------------------------------------------------------------------
create or replace function public.turnos_de_cliente(
    p_estado text default null
)
returns table (
    id              bigint,
    salon_id        uuid,
    fecha           date,
    hora            time,
    servicio_nombre text,
    salon_nombre    text,
    salon_slug      text,
    estado          text,
    ya_resenado     boolean
)
language sql
security definer
set search_path = public
as $$
    select
        t.id,
        s.id as salon_id,
        t.appointment_date as fecha,
        t.appointment_time as hora,
        t.service_type as servicio_nombre,
        s.nombre as salon_nombre,
        s.slug as salon_slug,
        t.status as estado,
        exists (
            select 1 from public.resenas r where r.turno_id = t.id
        ) as ya_resenado
    from public.turnos t
    join public.salones s on s.id = t.salon_id
    where t.cliente_id in (select mc.id from public._mis_clientes() as mc(id))
      and (p_estado is null or t.status = p_estado)
      and t.status in ('realizado', 'completed', 'completado')
    order by t.appointment_date desc, t.appointment_time desc;
$$;

revoke all on function public.turnos_de_cliente(text) from public, anon;
grant execute on function public.turnos_de_cliente(text)
    to authenticated, service_role;

-- Refrescar el schema cache de PostgREST para que la sobrecarga eliminada
-- desaparezca de la API sin esperar al TTL.
notify pgrst, 'reload schema';

commit;
