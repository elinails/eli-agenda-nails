-- ============================================================================
-- ELI M. NAILS · I80 · FASE 1: Sistema de Reseñas (Reviews)
--
-- REQUISITOS: i62_elima_belleza.sql aplicado (tiene turnos, clientes, salones)
--
-- IDIMOTENTE: Se puede correr varias veces sin errores.
-- ============================================================================

-- 1 -----------------------------------------------------------------------
-- Tabla resenas
-- -----------------------------------------------------------------------
create table if not exists public.resenas (
    id          bigint generated always as identity primary key,
    salon_id    uuid not null references public.salones(id) on delete cascade,
    cliente_id  bigint not null references public.clientes(id) on delete cascade,
    turno_id    bigint not null references public.turnos(id) on delete cascade,
    estrellas   smallint not null check (estrellas between 1 and 5),
    comentario  text check (char_length(btrim(comentario)) between 1 and 500),
    creado_en   timestamptz not null default now(),
    constraint un_resena_por_turno unique (turno_id)
);

-- Índices para rendimiento
create index if not exists resenas_salon_idx on public.resenas (salon_id);
create index if not exists resenas_cliente_idx on public.resenas (cliente_id);
create index if not exists resenas_turno_idx on public.resenas (turno_id);

-- Habilitar Row Level Security
alter table public.resenas enable row level security;

-- 2 -----------------------------------------------------------------------
-- POLÍTICAS RLS ( Idempotentes - una política por operación)
-- -----------------------------------------------------------------------

-- 2.1 Público (anon) puede LEER reseñas
drop policy if exists resenas_lectura_publico on public.resenas;
create policy resenas_lectura_publico
    on public.resenas for select to anon using (true);

-- 2.2 Clienta AUTENTICADA puede LEER sus propias reseñas
drop policy if exists resenas_lectura_cliente on public.resenas;
create policy resenas_lectura_cliente
    on public.resenas for select to authenticated using (
        cliente_id in (
            select c.id from public.clientes c 
            where c.user_id = auth.uid()
        )
    );

-- 2.3 Clienta AUTENTICADA puede INSERTAR reseña SOBRE SU TURNO
--    Requisitos:
--    - El turno debe estar "realizado" o "completed"
--    - El turno debe pertenecer al salón especificado
--    - El cliente debe ser dueño de una reserva del turno
--    - El turno aún no tiene reseña
--    - Asigna cliente_id automáticamente
drop policy if exists resenas_insertion_cliente on public.resenas;
create policy resenas_insertion_cliente
    on public.resenas for insert to authenticated with check (
        -- Verificar que el turno existe y está completado
        exists (
            select 1 from public.turnos t
            where t.id = resenas.turno_id
              and t.status in ('realizado', 'completed', 'completado')
        )
        -- Verificar que el turno pertenece al salón especificado
        and exists (
            select 1 from public.turnos t
            where t.id = resenas.turno_id
              and t.salon_id = resenas.salon_id
        )
        -- Verificar que el cliente es dueño de una reserva en ese turno
        and exists (
            select 1 from public.clientes c
            where c.user_id = auth.uid()
              and c.salon_id = resenas.salon_id
              and exists (
                  select 1 from public.turnos t2
                  where t2.id = resenas.turno_id
                    and (t2.user_id = c.user_id or t2.cliente_id = c.id)
              )
        )
        -- Verificar que el turno aún no tiene reseña (unicidad)
        and not exists (
            select 1 from public.resenas r
            where r.turno_id = resenas.turno_id
        )
        -- Asignar cliente_id automáticamente si no se especifica
        and resenas.cliente_id = (
            select c.id from public.clientes c
            where c.user_id = auth.uid()
              and c.salon_id = resenas.salon_id
            limit 1
        )
    );

-- 2.4 Dueño del salón puede LEER reseñas del salón
drop policy if exists resenas_lectura_dueño on public.resenas;
create policy resenas_lectura_dueño
    on public.resenas for select to authenticated using (
        public.es_owner(salon_id)
    );

-- 2.5 Dueño del salón puede EDITAR reseñas del salón
drop policy if exists resenas_edicion_dueño on public.resenas;
create policy resenas_edicion_dueño
    on public.resenas for update to authenticated using (
        public.es_owner(salon_id)
    );

-- 2.6 Dueño del salón puede BORRAR reseñas del salón
drop policy if exists resenas_borrado_dueño on public.resenas;
create policy resenas_borrado_dueño
    on public.resenas for delete to authenticated using (
        public.es_owner(salon_id)
    );

-- 3 -----------------------------------------------------------------------
-- Función RPC para crear reseña (con verificación centralizada)
-- -----------------------------------------------------------------------
create or replace function public.crear_resena(
    p_salon_id uuid,
    p_turno_id bigint,
    p_estrellas smallint,
    p_comentario text
)
returns resenas
language plpgsql
security definer
set search_path = public
as $$
declare
    v_cliente_id bigint;
    v_result resenas%ROWTYPE;
begin
    -- Verificar que el turno existe y está completado
    if not exists (
        select 1 from public.turnos t
        where t.id = p_turno_id
          and t.status in ('realizado', 'completed', 'completado')
          and t.salon_id = p_salon_id
    ) then
        raise exception 'El turno no existe, no está completado o no pertenece al salón';
    end if;

    -- Verificar que el turno aún no tiene reseña
    if exists (
        select 1 from public.resenas r
        where r.turno_id = p_turno_id
    ) then
        raise exception 'Este turno ya tiene una reseña asociada';
    end if;

    -- Obtener el cliente del usuario autenticado
    select c.id into v_cliente_id
    from public.clientes c
    where c.user_id = auth.uid()
      and c.salon_id = p_salon_id
    limit 1;

    if v_cliente_id is null then
        raise exception 'No tienes un cliente activo en este salón';
    end if;

    -- Insertar la reseña
    insert into public.resenas (salon_id, cliente_id, turno_id, estrellas, comentario)
    values (p_salon_id, v_cliente_id, p_turno_id, p_estrellas, p_comentario)
    returning * into v_result;

    return v_result;
end $$;

grant execute on function public.crear_resena(uuid, bigint, smallint, text) to authenticated;

-- 4 -----------------------------------------------------------------------
-- Función auxiliar para verificar si un turno puede ser reseñado
-- -----------------------------------------------------------------------
create or replace function public.turno_puede_resenarse(p_turno_id bigint)
returns table (
    puede boolean,
    salon_id uuid,
    cliente_id bigint,
    estado_turno text
)
language sql
security definer
set search_path = public
as $$
    select
        t.id is not null as puede,
        t.salon_id,
        c.id as cliente_id,
        t.status as estado_turno
    from public.turnos t
    left join public.clientes c on c.user_id = auth.uid() and c.salon_id = t.salon_id
    where t.id = p_turno_id
      and t.status in ('realizado', 'completed', 'completado')
      and not exists (
          select 1 from public.resenas r
          where r.turno_id = t.id
      );
$$;

grant execute on function public.turno_puede_resenarse(bigint) to authenticated;

-- 5 -----------------------------------------------------------------------
-- VISTA para marketplace (promedios de reseñas)
-- -----------------------------------------------------------------------
create or replace view public.salones_con_reseñas as
select
    s.id as salon_id,
    s.nombre,
    s.rubro,
    coalesce(avg(r.estrellas), 0)::numeric(2,1) as promedio_estrellas,
    count(r.id)::bigint as cantidad_reseñas
from public.salones s
left join public.resenas r on r.salon_id = s.id
where s.publicado = true
  and s.activo = true
  and s.rubro is not null
  and s.slug is not null
group by s.id, s.nombre, s.rubro;

-- 6 -----------------------------------------------------------------------
-- Notificación de actualización al esquema PostgREST
-- -----------------------------------------------------------------------
notify pgrst, 'reload schema';

-- ============================================================================
-- VERIFICACIÓN (ejecutar después de aplicar)
-- ============================================================================
-- 1) Ver tabla creada:
--    select * from public.resenas limit 5;
--
-- 2) Ver políticas (consulta corregida):
--    select polname, CASE polcmd WHEN 'r' THEN 'SELECT' WHEN 'w' THEN 'INSERT' 
--           WHEN 'a' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' END as operation
--    from pg_policy where polrelid = 'resenas'::regclass;
--
-- 3) Probar RPC crear_resena:
--    select * from public.crear_resena('SALON_UUID', 12345::bigint, 5, 'Excelente servicio');
--
-- 4) Verificar política insertion_cliente:
--    select polname, CASE polcmd WHEN 'r' THEN 'SELECT' WHEN 'w' THEN 'INSERT' 
--           WHEN 'a' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' END as operation
--    from pg_policy where polrelid = 'resenas'::regclass and polname = 'resenas_insertion_cliente';
--    Resultado esperado: operation = 'INSERT'
--
-- 5) Verificar política edicion_dueño:
--    select polname, CASE polcmd WHEN 'r' THEN 'SELECT' WHEN 'w' THEN 'INSERT' 
--           WHEN 'a' THEN 'UPDATE' WHEN 'd' THEN 'DELETE' END as operation
--    from pg_policy where polrelid = 'resenas'::regclass and polname = 'resenas_edicion_dueño';
--    Resultado esperado: operation = 'UPDATE'
--
-- 6) Ver promedio en marketplace:
--    select * from public.salones_con_reseñas limit 5;
-- ============================================================================