-- ============================================================================
-- ELI M. NAILS · I62 · Cimientos de Elima Belleza
--
-- FASE 1
--   · Perfil público del salón: rubro, bio, foto de portada, slug y publicado.
--   · Reseñas por salón/turno.
--
-- FASE 5
--   · Ledger de Elima Points: billeteras + movimientos.
--   · saldo_actual NO es editable: se recalcula desde movimientos_puntos.
--
-- DECISIONES DE ESTA ITERACIÓN
--   · Una billetera por cliente (Elima Points global). `salon_id` guarda el
--     salón de origen; los movimientos pueden referenciar turnos de cualquier
--     salón. OJO: hoy `clientes` es por salón, así que para que una misma
--     persona acumule entre salones hay que unificar identidad por WhatsApp
--     en una fase posterior.
--   · `publicado` solo lo puede cambiar un SuperAdmin (o el SQL editor).
--     La dueña edita el perfil, pero no se auto-publica.
--   · No se crea marketplace, portal ni UI de puntos en esta iteración.
--   · No se crean RPC de acreditación/canje todavía: eso va en la fase de
--     identidad global y reglas de negocio.
--
-- REQUISITOS: i50, i51, i54, i55, i56 aplicados.
-- IDEMPOTENTE: se puede correr varias veces.
-- ============================================================================


-- ============================================================================
-- 1 · PERFIL PÚBLICO EN `salones`
-- ============================================================================

alter table public.salones
    add column if not exists rubro            text,
    add column if not exists bio              text,
    add column if not exists foto_portada_url text,
    add column if not exists slug             text,
    add column if not exists publicado        boolean not null default false;

-- Rubros fijos de la primera versión.
alter table public.salones drop constraint if exists salones_rubro_check;
alter table public.salones add constraint salones_rubro_check
    check (
        rubro is null
        or rubro in ('nails', 'peluqueria', 'maquillaje', 'barberia')
    );

-- Bio corta del perfil público (independiente de `descripcion`, que sigue
-- siendo la frase de la tarjeta de WhatsApp).
alter table public.salones drop constraint if exists salones_bio_check;
alter table public.salones add constraint salones_bio_check
    check (
        bio is null
        or char_length(btrim(bio)) between 1 and 500
    );

-- Solo URLs http(s). Evita javascript:, data: y basura similar.
alter table public.salones drop constraint if exists salones_foto_portada_url_check;
alter table public.salones add constraint salones_foto_portada_url_check
    check (
        foto_portada_url is null
        or (
            char_length(btrim(foto_portada_url)) between 8 and 500
            and btrim(foto_portada_url) ~* '^https?://'
        )
    );

-- Slug URL-safe: minúsculas, números y guiones simples.
alter table public.salones drop constraint if exists salones_slug_check;
alter table public.salones add constraint salones_slug_check
    check (
        slug is null
        or (
            char_length(slug) between 3 and 60
            and slug ~ '^[a-z0-9]+(-[a-z0-9]+)*$'
        )
    );

create unique index if not exists un_salones_slug
    on public.salones (slug)
    where slug is not null;

create index if not exists salones_publicado_rubro_idx
    on public.salones (publicado, rubro)
    where publicado;

comment on column public.salones.rubro is
    'Rubro fijo del marketplace: nails | peluqueria | maquillaje | barberia';
comment on column public.salones.bio is
    'Bio pública del salón para Elima Belleza (máx. 500 caracteres)';
comment on column public.salones.foto_portada_url is
    'URL https de la foto de portada del perfil público';
comment on column public.salones.slug is
    'Identificador URL-safe del perfil público; único cuando no es null';
comment on column public.salones.publicado is
    'Aprobado por SuperAdmin para aparecer en el marketplace';


-- ============================================================================
-- 2 · NORMALIZACIÓN DEL PERFIL PÚBLICO
--
-- Deja prolijos los datos aunque lleguen desde el SQL editor o una RPC:
--   + Rubro en minúsculas.
--   + Bio y portada sin espacios sobrantes.
--   + Slug: minúsculas, sin acentos, espacios -> guiones, máximo 60.
-- ============================================================================

create or replace function public.normalizar_perfil_publico()
returns trigger
language plpgsql
as $$
begin
    new.rubro := nullif(lower(btrim(coalesce(new.rubro, ''))), '');
    new.bio := nullif(btrim(coalesce(new.bio, '')), '');
    new.foto_portada_url := nullif(btrim(coalesce(new.foto_portada_url, '')), '');

    new.slug := nullif(lower(btrim(coalesce(new.slug, ''))), '');
    if new.slug is not null then
        new.slug := translate(
            new.slug,
            'áàäâãéèëêíìïîóòöôõúùüûñç',
            'aaaaaeeeeiiiiooooouuuunc'
        );
        new.slug := regexp_replace(new.slug, '[^a-z0-9]+', '-', 'g');
        new.slug := btrim(new.slug, '-');
        new.slug := regexp_replace(new.slug, '-{2,}', '-', 'g');
        new.slug := btrim(left(new.slug, 60), '-');
        if new.slug = '' then
            new.slug := null;
        end if;
    end if;

    return new;
end $$;

drop trigger if exists trg_normalizar_perfil_publico on public.salones;
create trigger trg_normalizar_perfil_publico
before insert or update of rubro, bio, foto_portada_url, slug
on public.salones
for each row execute function public.normalizar_perfil_publico();

-- Continuidad: si el salón ya tenía una frase corta, la usamos como bio
-- inicial. Solo corre una vez (bio null).
update public.salones
   set bio = descripcion
 where bio is null
   and descripcion is not null
   and btrim(descripcion) <> '';


-- ============================================================================
-- 3 · SOLO EL SUPERADMIN PUEDE PUBLICAR UN SALÓN
--
-- Sin esto, la dueña podría hacer un UPDATE directo a salones.publicado y
-- saltarse la aprobación. El resto del perfil sí lo puede editar ella.
-- ============================================================================

create or replace function public.proteger_publicado_salon()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if new.publicado is distinct from old.publicado
       and not (auth.uid() is null or public.es_super_admin()) then
        raise exception 'solo_admin_publica';
    end if;
    return new;
end $$;

drop trigger if exists trg_proteger_publicado on public.salones;
create trigger trg_proteger_publicado
before update of publicado on public.salones
for each row execute function public.proteger_publicado_salon();


-- ============================================================================
-- 4 · RESEÑAS
--
-- Una reseña pertenece a un salón y, cuando se puede, a un cliente/turno.
-- El insert queda cerrado: se hará por RPC en la fase de portal público.
-- ============================================================================

create table if not exists public.resenas (
    id          uuid primary key default gen_random_uuid(),
    salon_id    uuid not null references public.salones(id) on delete cascade,
    cliente_id  bigint references public.clientes(id) on delete set null,
    turno_id    bigint references public.turnos(id) on delete set null,
    estrellas   smallint not null check (estrellas between 1 and 5),
    comentario  text,
    creado_en   timestamptz not null default now(),
    constraint resenas_comentario_check check (
        comentario is null
        or char_length(btrim(comentario)) between 1 and 1000
    )
);

create unique index if not exists un_resena_por_turno
    on public.resenas (turno_id)
    where turno_id is not null;

create index if not exists resenas_salon_idx
    on public.resenas (salon_id, creado_en desc);

comment on table public.resenas is
    'Reseñas de clientas por salón; una por turno como máximo';

-- Devuelve si el salón está aprobado para el marketplace. SECURITY DEFINER
-- para que la policy pública de resenas no choque con la RLS de salones.
create or replace function public.salon_es_publico(p_salon uuid)
returns boolean
language sql
stable
security definer
set search_path = public
as $$
    select exists (
        select 1
          from public.salones s
         where s.id = p_salon
           and s.publicado
    );
$$;

grant execute on function public.salon_es_publico(uuid) to anon, authenticated;

alter table public.resenas enable row level security;

drop policy if exists resenas_miembros on public.resenas;
create policy resenas_miembros on public.resenas
    for select to authenticated
    using (public.es_miembro(salon_id));

drop policy if exists resenas_publicas on public.resenas;
create policy resenas_publicas on public.resenas
    for select to anon, authenticated
    using (public.salon_es_publico(salon_id));

revoke all on public.resenas from anon, authenticated;
grant select on public.resenas to anon, authenticated;


-- ============================================================================
-- 5 · LEDGER DE ELIMA POINTS
--
-- El ledger es la fuente de verdad. `saldo_actual` es una caché recalculada
-- por trigger; no se puede editar a mano.
-- ============================================================================

create table if not exists public.billeteras_puntos (
    id           uuid primary key default gen_random_uuid(),
    cliente_id   bigint not null references public.clientes(id) on delete cascade,
    salon_id     uuid not null references public.salones(id) on delete cascade,
    saldo_actual numeric(12,2) not null default 0,
    creado_en    timestamptz not null default now(),
    constraint billeteras_puntos_saldo_check check (saldo_actual >= 0),
    constraint billeteras_puntos_cliente_unico unique (cliente_id)
);

create index if not exists billeteras_puntos_salon_idx
    on public.billeteras_puntos (salon_id);

create table if not exists public.movimientos_puntos (
    id           uuid primary key default gen_random_uuid(),
    billetera_id uuid not null references public.billeteras_puntos(id) on delete cascade,
    tipo         text not null,
    monto        numeric(12,2) not null,
    motivo       text,
    turno_id     bigint references public.turnos(id) on delete set null,
    creado_en    timestamptz not null default now(),
    constraint movimientos_puntos_tipo_check check (
        tipo in ('ganado', 'canjeado', 'ajuste', 'reverso')
    ),
    constraint movimientos_puntos_monto_check check (
        (tipo = 'ganado' and monto > 0)
        or (tipo = 'canjeado' and monto < 0)
        or (tipo in ('ajuste', 'reverso') and monto <> 0)
    ),
    constraint movimientos_puntos_motivo_check check (
        motivo is null
        or char_length(btrim(motivo)) <= 200
    )
);

create unique index if not exists un_movimiento_ganado_por_turno
    on public.movimientos_puntos (turno_id)
    where tipo = 'ganado' and turno_id is not null;

create index if not exists movimientos_puntos_billetera_idx
    on public.movimientos_puntos (billetera_id, creado_en desc);

comment on table public.billeteras_puntos is
    'Elima Points: una billetera por cliente; salon_id = salón de origen';
comment on table public.movimientos_puntos is
    'Ledger de Elima Points: positivo gana, negativo canjea';


-- Recalcula la caché desde el ledger. Se usa un flag de sesión para que el
-- trigger de protección sepa que el cambio viene de acá.
create or replace function public.recalcular_saldo_puntos(p_billetera_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
    if p_billetera_id is null then
        return;
    end if;

    perform set_config('eli.puntos_recalc', '1', true);

    update public.billeteras_puntos b
       set saldo_actual = coalesce((
           select sum(m.monto)
             from public.movimientos_puntos m
            where m.billetera_id = p_billetera_id
       ), 0)
     where b.id = p_billetera_id;

    perform set_config('eli.puntos_recalc', '0', true);
end $$;

revoke all on function public.recalcular_saldo_puntos(uuid) from public;


create or replace function public.proteger_saldo_puntos()
returns trigger
language plpgsql
as $$
begin
    if new.saldo_actual is distinct from old.saldo_actual
       and coalesce(current_setting('eli.puntos_recalc', true), '') <> '1' then
        raise exception 'saldo_puntos_no_editable';
    end if;
    return new;
end $$;

drop trigger if exists trg_proteger_saldo_puntos on public.billeteras_puntos;
create trigger trg_proteger_saldo_puntos
before update on public.billeteras_puntos
for each row execute function public.proteger_saldo_puntos();


create or replace function public.trg_recalcular_saldo_puntos()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
    if tg_op = 'UPDATE' and new.billetera_id is distinct from old.billetera_id then
        perform public.recalcular_saldo_puntos(old.billetera_id);
        perform public.recalcular_saldo_puntos(new.billetera_id);
    elsif tg_op = 'DELETE' then
        perform public.recalcular_saldo_puntos(old.billetera_id);
    else
        perform public.recalcular_saldo_puntos(new.billetera_id);
    end if;
    return null;
end $$;

drop trigger if exists trg_recalcular_saldo_puntos on public.movimientos_puntos;
create trigger trg_recalcular_saldo_puntos
after insert or update or delete on public.movimientos_puntos
for each row execute function public.trg_recalcular_saldo_puntos();


alter table public.billeteras_puntos enable row level security;
alter table public.movimientos_puntos enable row level security;

drop policy if exists billeteras_puntos_lectura on public.billeteras_puntos;
create policy billeteras_puntos_lectura on public.billeteras_puntos
    for select to authenticated
    using (public.es_miembro(salon_id));

drop policy if exists movimientos_puntos_lectura on public.movimientos_puntos;
create policy movimientos_puntos_lectura on public.movimientos_puntos
    for select to authenticated
    using (
        exists (
            select 1
              from public.billeteras_puntos b
             where b.id = billetera_id
               and public.es_miembro(b.salon_id)
        )
    );

-- Lectura para miembros del salón; escritura solo por service_role o por una
-- RPC futura. Así nadie puede tocar saldo_actual ni inventar movimientos.
revoke all on public.billeteras_puntos from anon, authenticated;
revoke all on public.movimientos_puntos from anon, authenticated;
grant select on public.billeteras_puntos to authenticated;
grant select on public.movimientos_puntos to authenticated;


-- ============================================================================
-- 6 · RECARGA DE CACHÉ DE POSTGREST
-- ============================================================================

notify pgrst, 'reload schema';


-- ============================================================================
-- VERIFICACIÓN (después de correr)
-- ============================================================================
--
-- 1) Columnas nuevas de salones:
-- select column_name, data_type, is_nullable, column_default
--   from information_schema.columns
--  where table_schema = 'public' and table_name = 'salones'
--    and column_name in ('rubro','bio','foto_portada_url','slug','publicado');
--
-- 2) Tablas nuevas:
-- select table_name
--   from information_schema.tables
--  where table_schema = 'public'
--    and table_name in ('resenas','billeteras_puntos','movimientos_puntos');
--
-- 3) Triggers:
-- select tgname, tgrelid::regclass
--   from pg_trigger
--  where tgname in (
--      'trg_normalizar_perfil_publico',
--      'trg_proteger_publicado',
--      'trg_proteger_saldo_puntos',
--      'trg_recalcular_saldo_puntos'
--  );
--
-- 4) El saldo calculado coincide con el ledger:
-- select b.id, b.saldo_actual, coalesce(sum(m.monto), 0) as saldo_ledger
--   from public.billeteras_puntos b
--   left join public.movimientos_puntos m on m.billetera_id = b.id
--  group by b.id, b.saldo_actual
-- having b.saldo_actual <> coalesce(sum(m.monto), 0);
--   → no debe devolver filas.
--
-- 5) El saldo no se puede editar a mano:
-- update public.billeteras_puntos set saldo_actual = 999 where id = '...';
--   → debe fallar con: saldo_puntos_no_editable
--
-- 6) La dueña no puede auto-publicarse:
-- update public.salones set publicado = true where id = '...';
--   → con sesión de dueña debe fallar con: solo_admin_publica
-- ============================================================================
