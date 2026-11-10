-- ============================================================================
-- ELI M. NAILS · I56 · Límite de personas según el PLAN EFECTIVO
--
-- PROBLEMA
--   validar_plan_miembro() resolvía el cupo con:
--       select s.plan_id from public.salones where s.id = new.salon_id
--   Es decir, el plan GUARDADO. Pero el plan que rige hoy lo calcula
--   _saas_plan_efectivo() (i55_saas.sql), que entiende de trial, gracia y
--   vencimiento, y además prioriza la tabla `suscripciones`.
--
--   Consecuencia real:
--     · Salón en TRIAL PRO con salones.plan_id = 'gratis' (lo normal cuando el
--       plan se carga desde `suscripciones`): la app muestra 3 personas pero
--       la base bloquea la segunda invitación con limite_plan:1.
--     · Salón VENCIDO con salones.plan_id = 'pro': la app ya lo trata como
--       Gratis pero la base le sigue permitiendo 3 personas.
--
-- SOLUCIÓN
--   Reemplazar SOLO la resolución del cupo. El resto de la función queda igual
--   (DELETE con dueña requerida, service role, miembro_inmutable, solo_owner,
--   owner_unico, no degradar a la última dueña, bypass de filas ya activas).
--
--   El límite ahora sale de _saas_plan_efectivo(), que devuelve el
--   limite_empleadas del plan que corresponde HOY (null = sin límite).
--
-- REQUISITO: i55_saas.sql aplicado (crea _saas_plan_efectivo).
-- Idempotente: se puede correr varias veces.
-- ============================================================================


-- ============================================================================
-- 0 · PRE-CHECK
--
-- Si falta i55_saas.sql, esto corta con un mensaje claro en vez de dejar la
-- base a medio migrar.
-- ============================================================================

do $$
begin
    if to_regprocedure('public._saas_plan_efectivo(uuid)') is null then
        raise exception 'Falta i55_saas.sql: no existe public._saas_plan_efectivo(uuid)';
    end if;
end $$;


-- ============================================================================
-- 1 · FUNCIÓN (cuerpo completo, no fragmentos)
-- ============================================================================

create or replace function public.validar_plan_miembro()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_limite  integer;
    v_activos integer;
begin
    -- DELETE: no permitir quedarse sin dueña
    if tg_op = 'DELETE' then
        if auth.uid() is not null
           and not public.es_super_admin()
           and old.rol = 'owner'
           and not exists (
               select 1 from public.miembros_salon m
                where m.salon_id = old.salon_id and m.rol = 'owner'
                  and m.id is distinct from old.id
           ) then
            raise exception 'owner_requerido';
        end if;
        return old;
    end if;

    -- Service role / SQL editor / SuperAdmin: sin restricciones
    if auth.uid() is null or public.es_super_admin() then
        return new;
    end if;

    -- No mover un miembro de salón ni cambiarle el user_id.
    -- (OLD solo se toca dentro de un IF de UPDATE: en INSERT no está asignado.)
    if tg_op = 'UPDATE' then
        if new.salon_id is distinct from old.salon_id
           or new.user_id is distinct from old.user_id then
            raise exception 'miembro_inmutable';
        end if;
    end if;

    -- Solo la dueña del salón invita/edita (defensa en profundidad)
    if not exists (
        select 1 from public.miembros_salon m
         where m.salon_id = new.salon_id and m.user_id = auth.uid()
           and m.rol = 'owner' and m.activo
    ) then
        -- bootstrap: primer owner creado por crear_salon_inicial
        if not (
            tg_op = 'INSERT'
            and not exists (select 1 from public.miembros_salon m where m.salon_id = new.salon_id)
            and new.user_id = auth.uid()
            and new.rol = 'owner'
        ) then
            raise exception 'solo_owner';
        end if;
    end if;

    -- Sin co-dueñas
    if new.rol = 'owner' and exists (
        select 1 from public.miembros_salon m
         where m.salon_id = new.salon_id and m.rol = 'owner'
           and m.id is distinct from new.id
    ) then
        raise exception 'owner_unico';
    end if;

    -- No degradar a la última dueña
    if tg_op = 'UPDATE' then
        if old.rol = 'owner' and new.rol <> 'owner'
           and not exists (
               select 1 from public.miembros_salon m
                where m.salon_id = old.salon_id and m.rol = 'owner'
                  and m.id is distinct from old.id
           ) then
            raise exception 'owner_requerido';
        end if;
    end if;

    if new.activo is false then
        return new;
    end if;

    -- Si la fila ya estaba activa, el cupo no cambia: permitir editar
    -- email/rol sin bloquear a salones en gracia por downgrade.
    if tg_op = 'UPDATE' then
        if old.activo is true then
            return new;
        end if;
    end if;

    -- ── I56 · LÍMITE SEGÚN PLAN EFECTIVO ─────────────────────────────────
    -- Antes: select s.plan_id from salones (plan guardado).
    -- Ahora: _saas_plan_efectivo() resuelve trial / gracia / vencido y
    -- devuelve el limite_empleadas del plan que corresponde hoy.
    -- null = sin límite (Premium).
    select pe.limite_empleadas
      into v_limite
      from public._saas_plan_efectivo(new.salon_id) pe;

    if v_limite is null then
        return new;
    end if;

    select count(*) into v_activos
      from public.miembros_salon m
     where m.salon_id = new.salon_id and m.activo
       and m.id is distinct from new.id;

    if v_activos >= v_limite then
        raise exception 'limite_plan:%', v_limite using errcode = 'P0002';
    end if;

    return new;
end $$;


-- ============================================================================
-- 2 · EL TRIGGER (por si se perdió)
-- ============================================================================

drop trigger if exists trg_validar_plan_miembro on public.miembros_salon;
create trigger trg_validar_plan_miembro
before insert or update or delete on public.miembros_salon
for each row execute function public.validar_plan_miembro();


-- ============================================================================
-- VERIFICACIÓN (después de correr)
-- ============================================================================
-- 1) La función quedó apuntando al plan efectivo:
-- select proname,
--        prosrc like '%_saas_plan_efectivo%' as usa_plan_efectivo,
--        prosrc like '%salones s where s.id = new.salon_id%' as todavia_usa_plan_guardado
--   from pg_proc where proname = 'validar_plan_miembro';
--   → esperado: usa_plan_efectivo = true, todavia_usa_plan_guardado = false
--
-- 2) Plan efectivo de un salón cualquiera:
-- select * from public.admin_saas_plan('PEGA-AQUI-EL-UUID-DEL-SALON');
--
-- 3) Prueba end-to-end (con un salón en trial Pro):
--    a) el plan efectivo debe decir pro / limite 3
--    b) insertar 2 miembros staff: permitido
--    c) el tercero: ERROR 'limite_plan:3'
--
-- 4) Prueba del caso vencido:
--    a) update public.salones set estado_suscripcion = 'past_due',
--          trial_hasta = now() - interval '30 days' where id = '...';
--    b) select * from public.admin_saas_plan('...') → plan_efectivo gratis, limite 1
--    c) invitar a una segunda persona → ERROR 'limite_plan:1'
--    d) IMPORTANTE: los miembros YA activos no se expulsan; solo se bloquean
--       altas nuevas.
