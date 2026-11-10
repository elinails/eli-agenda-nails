-- ============================================================================
-- ELI M. NAILS · I79 · Flujo híbrido de publicación de salones
--
-- Mantiene el control manual actual (Flujo A) y prepara infraestructura
-- para auto-publicación futura (Flujo B) cuando se active el flag.
--
-- REQUISITOS: i62_elima_belleza.sql + i64_marketplace.sql aplicados
-- ============================================================================

-- 1 -----------------------------------------------------------------------
-- Tabla de configuración global para control del modo de publicación
-- -----------------------------------------------------------------------
create table if not exists public.configuracion_marketplace (
    clave       text primary key,
    valor       text,
    editable    boolean not null default false,
    creado_en   timestamptz not null default now()
);

-- Flag por defecto en FALSE (modo manual - estado actual)
insert into public.configuracion_marketplace (clave, valor, editable)
values 
    ('auto_publicar_habilitado', 'false', false)
on conflict (clave) do nothing;

comment on table public.configuracion_marketplace is
    'Configuración global del marketplace para controlar flujo de publicación de salones.';
comment on column public.configuracion_marketplace.valor is
    'Valor del setting. Para auto_publicar_habilitado: "true" o "false".';
comment on column public.configuracion_marketplace.editable is
    'Si el valor puede modificarse desde la UI (excluye settings técnicos).';

create unique index if not exists un_config_marketplace_clave
    on public.configuracion_marketplace (clave);

-- 2 -----------------------------------------------------------------------
-- Tabla de control para pasar información entre triggers
-- -----------------------------------------------------------------------
-- Esta tabla temporal permite pasar el origen de la publicación
-- entre los triggers BEFORE y AFTER
create table if not exists public._publicacion_control (
    salon_id    uuid primary key,
    origen      text not null check (origen in ('auto', 'manual')),
    creado_en   timestamptz not null default now()
);

-- Limpiar entradas viejas (más de 1 minuto, por si acaso)
delete from public._publicacion_control
where creado_en < now() - interval '1 minute';

-- 3 -----------------------------------------------------------------------
-- Modificación de la tabla auditoria_admin para registrar origen
-- -----------------------------------------------------------------------
alter table public.auditoria_admin
    add column if not exists origen text default 'manual';

comment on column public.auditoria_admin.origen is
    'Origen de la acción de publicación: "manual" (SuperAdmin) o "auto" (proceso automático).';

-- 4 -----------------------------------------------------------------------
-- Trigger de auto-publicación (BEFORE)
-- Cuando el flag está activo, publica automáticamente salones que cumplen requisitos
-- -----------------------------------------------------------------------
create or replace function public.auto_publicar_salon_si_listo()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_auto_habilitado text;
begin
    -- Leer el flag de configuración
    v_auto_habilitado := (
        select valor from public.configuracion_marketplace
        where clave = 'auto_publicar_habilitado'
    );

    -- Limpiar tabla de control para este salón
    delete from public._publicacion_control where salon_id = new.id;

    -- Sólo actuar si el auto-publicado está HABILITADO y el salón no está publicado
    if v_auto_habilitado = 'true'
       and old.publicado is not true
       and new.rubro is not null
       and new.slug is not null
       and new.activo is true
    then
        -- Registrar origen auto
        insert into public._publicacion_control (salon_id, origen)
        values (new.id, 'auto');

        -- Publicar automáticamente
        new.publicado := true;
    end if;

    return new;
end $$;

drop trigger if exists trg_auto_publicar_salon on public.salones;
create trigger trg_auto_publicar_salon
    before update of publicado, rubro, slug, activo on public.salones
    for each row
    execute function public.auto_publicar_salon_si_listo();

-- 5 -----------------------------------------------------------------------
-- Modificación de proteger_publicado_salon() para permitir auto-publicado
-- -----------------------------------------------------------------------
create or replace function public.proteger_publicado_salon()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_control record;
begin
    if new.publicado is distinct from old.publicado then
        if new.publicado = true then
            -- Verificar si viene del trigger de auto-publicación
            select * into v_control from public._publicacion_control where salon_id = new.id;
            
            if v_control.salon_id is not null then
                -- Auto-publicación: permitido
                return new;
            elsif auth.uid() is not null
                  and auth.uid() not in (select user_id from public.super_admins)
            then
                -- Dueña intentando publicar manualmente - prohibido
                raise exception 'solo_admin_publica';
            end if;
        elsif old.publicado = true then
            -- Despublicación - solo SuperAdmin puede
            if auth.uid() is not null
               and auth.uid() not in (select user_id from public.super_admins)
            then
                raise exception 'solo_admin_publica';
            end if;
        end if;
    end if;

    return new;
end $$;

drop trigger if exists trg_proteger_publicado on public.salones;
create trigger trg_proteger_publicado
    before update of publicado on public.salones
    for each row
    execute function public.proteger_publicado_salon();

-- 6 -----------------------------------------------------------------------
-- Modificación de auditorial_publicacion_salon() para registrar origen
-- (Reemplaza al trigger trg_auditar_publicacion que está en i64_marketplace.sql)
-- -----------------------------------------------------------------------
create or replace function public.auditar_publicacion_salon()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
    v_origen text := 'manual';
    v_control record;
begin
    if new.publicado is distinct from old.publicado then
        -- Verificar si viene del trigger de auto-publicación
        select * into v_control from public._publicacion_control where salon_id = new.id;
        
        if v_control.salon_id is not null then
            v_origen := v_control.origen;
        end if;

        if new.publicado = true or old.publicado = true then
            insert into public.auditoria_admin (admin_id, salon_id, accion, detalle, origen)
            values (
                coalesce(auth.uid(), '00000000-0000-0000-0000-000000000000'::uuid),
                new.id,
                case
                    when new.publicado then 'salon_publicado'
                    else 'salon_despublicado'
                end,
                jsonb_build_object(
                    'publicado_anterior', old.publicado,
                    'publicado_nuevo', new.publicado,
                    'slug', new.slug,
                    'rubro', new.rubro
                ),
                v_origen
            );

            -- Limpiar entrada de control
            delete from public._publicacion_control where salon_id = new.id;
        end if;
    end if;

    return new;
end $$;

drop trigger if exists trg_auditar_publicacion on public.salones;
create trigger trg_auditar_publicacion
    after update of publicado on public.salones
    for each row
    execute function public.auditar_publicacion_salon();

-- 7 -----------------------------------------------------------------------
-- Función auxiliar para verificar si un salón está listo para aprobar
-- -----------------------------------------------------------------------
create or replace function public.salon_listo_para_aprobar(p_salon uuid)
returns table (
    rubro_ok boolean,
    slug_ok boolean,
    bio_ok boolean,
    foto_ok boolean,
    activo_ok boolean,
    plan_ok boolean,
   _completo boolean
)
language sql
security definer
set search_path = public
as $$
    select
        (s.rubro is not null) as rubro_ok,
        (s.slug is not null) as slug_ok,
        (coalesce(s.bio, '') <> '') as bio_ok,
        (s.foto_portada_url is not null) as foto_ok,
        (s.activo is true) as activo_ok,
        exists (
            select 1 from public.suscripciones sn
            where sn.salon_id = s.id
              and sn.estado in ('activo', 'trial')
        ) as plan_ok,
        (s.rubro is not null
         and s.slug is not null
         and s.activo is true) as completo
    from public.salones s
    where s.id = p_salon;
$$;

-- 8 -----------------------------------------------------------------------
-- Notificación de actualización al esquema PostgREST
-- -----------------------------------------------------------------------
notify pgrst, 'reload schema';

-- ============================================================================
-- NOTA DE ORDEN DE TRIGGERS:
-- 1. trg_auto_publicar_salon (BEFORE): Si flag activo, registra origen y pone publicado=true
-- 2. trg_proteger_publicado (BEFORE): Rechaza cambios no autorizados
-- 3. trg_auditar_publicacion (AFTER): Audita el cambio usando tabla _publicacion_control
--
-- LA TABLA _publicacion_control PERMITE PASAR EL ORIGEN ENTRE TRIGGERS
-- ============================================================================