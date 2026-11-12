-- ============================================================================
-- ELIMA HUB · I90 · PALETAS PREMIUM POR SALÓN
--
-- Permite que un SuperAdmin otorgue o revoque las 6 paletas Premium a un salón
-- (para pruebas o regalos) y que la app del salón lea solo sus desbloqueadas.
--
-- Seguridad:
--   · salones_paletas queda con RLS y SIN policies directas: nadie la lee ni
--     la escribe desde PostgREST; solo las RPC SECURITY DEFINER.
--   · admin_toggle_paleta / admin_listar_paletas exigen es_super_admin().
--   · obtener_mis_paletas() no recibe parámetros: resuelve el salón de la
--     cuenta autenticada desde miembros_salon, con la misma prioridad que la
--     app (owner activa > staff activa).
--
-- Requisitos: I48 (es_super_admin), I53/I62 (miembros_salon, salones).
-- Idempotente.
-- ============================================================================

begin;

-- ----------------------------------------------------------------------------
-- 1 · Tabla de paletas otorgadas
-- ----------------------------------------------------------------------------
create table if not exists public.salones_paletas (
    salon_id  uuid not null references public.salones(id) on delete cascade,
    paleta_id text not null,
    creado_en timestamptz not null default now(),
    primary key (salon_id, paleta_id),
    constraint salones_paletas_premium_check check (
        paleta_id in ('salvia', 'mauve', 'rose-gold', 'golden-glam', 'nude-gold', 'mono-dark')
    )
);

create index if not exists salones_paletas_salon_idx
    on public.salones_paletas (salon_id);

alter table public.salones_paletas enable row level security;

-- Sin policies: el acceso directo queda cerrado. Las RPC definen el contrato.
revoke all on public.salones_paletas from public, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2 · RPC de SuperAdmin: otorgar / revocar una paleta
-- ----------------------------------------------------------------------------
create or replace function public.admin_toggle_paleta(
    p_salon_id  uuid,
    p_paleta_id text,
    p_otorgar   boolean
)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
declare
    v_paleta text := lower(btrim(coalesce(p_paleta_id, '')));
begin
    -- Guard primero: no filtrar existencia de salones a quien no es admin.
    if not public.es_super_admin() then
        raise exception 'sin_permisos';
    end if;

    if p_salon_id is null or p_otorgar is null then
        raise exception 'parametros_invalidos';
    end if;

    if v_paleta not in ('salvia', 'mauve', 'rose-gold', 'golden-glam', 'nude-gold', 'mono-dark') then
        raise exception 'paleta_invalida';
    end if;

    if not exists (select 1 from public.salones s where s.id = p_salon_id) then
        raise exception 'salon_no_existe';
    end if;

    if p_otorgar then
        insert into public.salones_paletas (salon_id, paleta_id)
        values (p_salon_id, v_paleta)
        on conflict (salon_id, paleta_id) do nothing;
    else
        delete from public.salones_paletas
         where salon_id = p_salon_id and paleta_id = v_paleta;
    end if;

    return true;
end;
$$;

revoke all on function public.admin_toggle_paleta(uuid, text, boolean) from public, anon;
grant execute on function public.admin_toggle_paleta(uuid, text, boolean)
    to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 3 · RPC de SuperAdmin: leer las paletas de un salón para el modal
-- ----------------------------------------------------------------------------
create or replace function public.admin_listar_paletas(p_salon_id uuid)
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
begin
    if not public.es_super_admin() then
        raise exception 'sin_permisos';
    end if;

    if p_salon_id is null then
        raise exception 'parametros_invalidos';
    end if;

    return coalesce(
        (select array_agg(paleta_id order by paleta_id)
           from public.salones_paletas
          where salon_id = p_salon_id),
        '{}'::text[]
    );
end;
$$;

revoke all on function public.admin_listar_paletas(uuid) from public, anon;
grant execute on function public.admin_listar_paletas(uuid)
    to authenticated, service_role;

-- ----------------------------------------------------------------------------
-- 4 · RPC de la app: paletas del salón de la cuenta logueada
-- ----------------------------------------------------------------------------
create or replace function public.obtener_mis_paletas()
returns text[]
language plpgsql
stable
security definer
set search_path = public
as $$
declare
    v_salon uuid;
begin
    if auth.uid() is null then
        return '{}'::text[];
    end if;

    -- Misma elección que cargarMembresia() en index.html:
    -- owner activa manda; si no hay, la primera membresía activa.
    select m.salon_id
      into v_salon
      from public.miembros_salon m
     where m.user_id = auth.uid()
       and m.activo
     order by (m.rol = 'owner') desc, m.creado_en asc
     limit 1;

    if v_salon is null then
        return '{}'::text[];
    end if;

    return coalesce(
        (select array_agg(paleta_id order by paleta_id)
           from public.salones_paletas
          where salon_id = v_salon),
        '{}'::text[]
    );
end;
$$;

revoke all on function public.obtener_mis_paletas() from public, anon;
grant execute on function public.obtener_mis_paletas() to authenticated, service_role;

notify pgrst, 'reload schema';

commit;
