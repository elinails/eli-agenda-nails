-- ============================================================================
-- ELI M. NAILS · I80 · RPC CREAR RESENA
--
-- Permite al dueño del turno (o al cliente asociado) crear una reseña.
-- Valida:
--   1. El turno existe y pertenece al salón del usuario
--   2. El turno está en estado "completed" o "realizado"
--   3. No existe una reseña previa para ese turno
--   4. El usuario es el cliente del turno O el salón dueño/miastre
--
-- No cambia datos. Idempotente. Se ejecuta como SECURITY DEFINER.
-- ============================================================================

create or replace function public.crear_resena(
    p_turno_id bigint,
    p_estrellas int,
    p_comentario text
)
returns uuid
language plpgsql
security definer
set search_path = public
as $i80_crear_resena$
declare
    v_turno   public.turnos%rowtype;
    v_cliente public.clientes%rowtype;
    v_id      uuid;
    c_tipos_realizado constant text[] := array['completed', 'realizado'];
begin
    -- 1. Validar parámetros
    if p_estrellas is null or p_estrellas < 1 or p_estrellas > 5 then
        raise exception 'estrellas_invalidas';
    end if;
    if char_length(btrim(coalesce(p_comentario, ''))) > 1000 then
        raise exception 'comentario_muy_largo';
    end if;
    if p_turno_id is null then
        raise exception 'turno_id_requerido';
    end if;

    -- 2. Obtener el turno
    select t.* into v_turno from public.turnos t where t.id = p_turno_id;
    if not found then
        raise exception 'turno_no_existe';
    end if;

    -- 3. Verificar que el turno está realizado
    if lower(coalesce(v_turno.status, '')) <> all (c_tipos_realizado) then
        raise exception 'turno_no_realizado';
    end if;

    -- 4. Verificar que no existe reseña previa (única por turno)
    if exists (select 1 from public.resenas r where r.turno_id = p_turno_id) then
        raise exception 'ya_existe_resena';
    end if;

    -- 5. Validar permisos: miembro del salón O dueño del cliente
    select * into v_cliente from public.clientes where id = v_turno.cliente_id;
    if not (
           public.es_miembro(v_turno.salon_id)
        or (v_turno.cliente_id is not null and v_cliente.user_id = auth.uid())
    ) then
        raise exception 'sin_permisos';
    end if;

    -- 6. Insertar la reseña
    insert into public.resenas (salon_id, cliente_id, turno_id, estrellas, comentario)
    values (v_turno.salon_id, v_turno.cliente_id, p_turno_id, p_estrellas, btrim(p_comentario))
    returning id into v_id;

    return v_id;
end;
$i80_crear_resena$;

-- Permisos: solo usuarios autenticados (ya sea cliente o dueño del salón)
revoke all on function public.crear_resena(bigint, int, text) from public;
grant execute on function public.crear_resena(bigint, int, text) to authenticated;