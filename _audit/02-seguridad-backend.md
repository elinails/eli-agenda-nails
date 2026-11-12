# Auditoría de seguridad backend — Supabase del portal de clientas

**Proyecto Supabase:** `wppleywdprvdlbajeubl` (`https://wppleywdprvdlbajeubl.supabase.co`)
**Portal auditado:** `https://eli-agenda-nails.vercel.app/portal.html`
**Fecha:** 2026-11-11 (America/Argentina/Buenos_Aires)
**Auditor:** `backend-security` (teammate del Lead)
**Alcance:** capa backend/Supabase que consume el portal: RPCs `obtener_mis_puntos`, `turnos_de_cliente`, `cliente_turnos_canjeables`, `cliente_saldo_puntos_turno`, `cliente_canjear_puntos`, `crear_resena`, `vincular_mi_cuenta`; tablas `clientes`, `billeteras_puntos`, `movimientos_puntos`, `turnos`, `resenas`, `salones`, `miembros_salon`; ACL/RLS, `SECURITY DEFINER`, `search_path`, auth (`signInWithOtp`/signup/rate limits) y búsqueda de fugas de `service_role`.
**Fuera de alcance:** frontend del portal (auditado por el Lead), Edge Functions como superficie de ataque (solo se revisaron por fugas de claves), resto del marketplace.

> **Convención de evidencia**
> **[VIVO]** = ejecutado contra la API/base vivas (REST o SQL read-only).
> **[VIVO-SIM]** = ejecutado contra la base vivas simulando rol y claims de PostgREST (`set local role authenticated` + `request.jwt.claims`) dentro de `begin read only`.
> **[LECTURA]** = verificado leyendo SQL/código, sin ejecutar el vector.
>
> **No se escribió nada en producción.** Los intentos de INSERT/UPDATE se hicieron dentro de `set default_transaction_read_only = on` y `begin read only`; el motor los abortó con `25006` (read-only). No se crearon reseñas, no se canjearon puntos, no se enviaron OTP y no se modificó ninguna cuenta.

---

## 1. Veredicto ejecutivo

**El backend no está en condiciones de producción.** La base viva tiene una función `SECURITY DEFINER` heredada, `public.crear_resena(bigint, integer, text)` (3 argumentos), que **no existe en el repositorio actual**, conserva `EXECUTE` para el rol `anon` y tiene una comprobación de autorización tautológica. Con solo la `publishable key` (que es pública y viaja en el sitio), un usuario no autenticado puede insertar una reseña en **cualquier turno completado de cualquier salón**, atribuida al cliente real de ese turno. Lo verifiqué en vivo hasta el límite del `INSERT`: en una transacción read-only el motor abortó exactamente en el `INSERT`, lo que demuestra que todas las validaciones previas —incluida la de autorización— pasaron para `anon`. Hoy hay un solo turno completado (id 111, salón «La biblia peluquería»), por lo que el vector es explotable de inmediato contra un negocio real; a escala, permite manipular el promedio de estrellas, difamar, quemar el turno de reseña de la clienta real y alojar HTML arbitrario en la base.

A esto se suman dos problemas de aislamiento entre salones. Primero, `turnos_de_cliente()` une `clientes` sin correlacionar con `turnos`: cualquier cuenta autenticada que tenga una fila en `clientes` creada a su nombre (el caso normal de una dueña/staff al dar de alta clientas) recibe **todos los turnos completados de todos los salones**, duplicados tantas veces como fichas de clienta tenga. Lo reproduje en vivo: una cuenta staff del salón «Eli M. Nails» vio el turno completado del salón «La biblia peluquería» (dos veces, por dos fichas). Segundo, la capa de puntos del portal valida que la clienta pertenezca al salón, pero **no que el turno sea suyo**: verifiqué en vivo que una identidad de clienta del salón leyó precio/tope/estado de un turno de otra clienta y que el canje llegó hasta el `SELECT … FOR UPDATE` de su billetera antes de que la transacción read-only lo frenara. Es un vector de abuso de lógica de negocio (no de robo de puntos): permite leer datos de turnos ajenos, consumir el único cupo de canje de un turno ajeno y bloquear el beneficio de la clienta real.

La causa estructural es el **drift entre el repositorio y la base viva**: la sobrecarga de 3 argumentos de `crear_resena`, la policy `salones_lectura_publica` y varios `GRANT` a `anon` no están versionados; el patrón de `create or replace function` con cambio de firma dejó la función vieja viva; y las migraciones `i80`/`i81` otorgan `EXECUTE` a `authenticated` sin revocar `PUBLIC`/`anon`, confiando en privilegios por defecto de Supabase. Lo que sí está bien resuelto: RLS de `clientes`, `turnos`, `billeteras_puntos` y `movimientos_puntos` (verificado: `anon` y la cuenta QA no leen filas ajenas), `search_path` fijo en **todas** las `SECURITY DEFINER` (0 excepciones), guards de las RPCs `admin_*`, tope del 30 % calculado server-side y `FOR UPDATE` en la billetera. La prioridad es una migración de ACL + `DROP` de la sobrecarga vieja, no un parche de frontend.

---

## 2. Tabla resumen de hallazgos

| ID | Severidad | Hallazgo | Verificación | Evidencia principal |
|---|---|---|---|---|
| **C-1** | **Crítico** | `crear_resena(bigint, integer, text)` legacy, viva y ejecutable por `anon`; autorización tautológica → cualquiera inserta reseñas en cualquier turno completado | **[VIVO]** + **[LECTURA]** | `pg_proc` ACL viva; `pg_get_functiondef`; REST `400 turno_no_existe`; transacción read-only aborta en el `INSERT` |
| **A-1** | **Alto** | `turnos_de_cliente()` filtra turnos completados de **otros salones** (JOIN sin correlación) y los duplica | **[VIVO-SIM]** + **[LECTURA]** | `supabase/sql/i81_turnos_cliente.sql:38-43`; simulación staff: turno 111 de «La biblia peluquería» ×2 |
| **A-2** | **Alto** | `crear_resena` 4-arg permite reseñar **cualquier** turno completado del salón (no solo el propio) y usa `clientes.user_id` (staff) en vez de la identidad de la clienta | **[VIVO]** parcial + **[LECTURA]** | `supabase/sql/i80_resenas_rpc.sql:154-167`; 8/8 `clientes` con `user_id`, 0 con `auth_user_id` |
| **M-1** | **Medio** | `cliente_saldo_puntos_turno` y `cliente_canjear_puntos` validan salón pero **no** dueño del turno | **[VIVO]** (saldo y hasta `FOR UPDATE`) | `supabase/sql/i82_canje_cliente_rpc.sql:48-66,147-177,213-220`; turno 17 ajeno leído con identidad de otra clienta |
| **M-2** | **Medio** | `anon` lee todas las columnas de `salones` publicados: `dueno_user_id`, plan, estado de suscripción, trial, baja | **[VIVO]** | `GET /rest/v1/salones?select=*` → 200 con esos campos |
| **M-3** | **Medio** | Drift de ACL/versionado: decenas de funciones con `EXECUTE` para `anon` por privilegios por defecto; `i80`/`i81` no revocan; sobrecargas huérfanas | **[VIVO]** + **[LECTURA]** | `pg_proc` ACL; `pg_policies`; `i80:173`, `i81:47`, `i82:287-288`; `git show ecb9c4e` |
| **B-1** | **Bajo** | `resenas_lectura_publico` (`anon USING true`) expone reseñas de salones no publicados; `resenas_publicas` ya cubre el caso | **[VIVO]** + **[LECTURA]** | `supabase/sql/i80_resenas_rpc.sql:36-38`; `pg_policies` |
| **B-2** | **Bajo** | `cliente_turnos_canjeables` une billeteras por `cliente_id` sin `salon_id` → filas duplicadas y saldo de otro salón | **[LECTURA]** | `supabase/sql/i82_canje_cliente_rpc.sql:278` |
| **B-3** | **Bajo** | El comentario de reseña se guarda sin sanitizar (HTML crudo). Hoy no se renderiza en marketplace/portal/admin, así que el XSS es latente, no explotable todavía | **[LECTURA]** + **[VIVO]** | `i80:166-167`; `marketplace.html:823-827,975,1416`; pruebas de render |
| **B-4** | **Bajo** | `turno_puede_resenarse` y `admin_tiene_billetera` ejecutables por `anon` (oráculos de estado/existencia) | **[VIVO]** | `POST /rpc/turno_puede_resenarse` 200; ACL viva; función sin guard |
| **B-5** | **Bajo** | Modelo de identidad por email (`_mis_clientes`/`vincular_mi_cuenta`): si se desactiva la confirmación de email o hay un email mal tipeado, otra cuenta puede reclamar puntos/historial | **[VIVO]** (settings) + **[LECTURA]** | `i66:94-136`; `/auth/v1/settings` → `mailer_autoconfirm=false` (mitiga hoy) |

**Conteo:** 1 Crítico · 2 Altos · 3 Medios · 5 Bajos.

---

## 3. Hallazgos detallados

### C-1 — [CRÍTICO] `crear_resena` legacy de 3 argumentos: escritura anónima en el sistema de reseñas

**Estado:** **[VIVO]** + **[LECTURA]** — verificado contra la base y la API vivas, sin llegar a escribir.

#### Evidencia

La base viva tiene **dos** sobrecargas de `crear_resena`:

```text
crear_resena | p_turno_id bigint, p_estrellas integer, p_comentario text
             | secdef=true | config=search_path=public
             | ACL: postgres=X/postgres, anon=X/postgres, authenticated=X/postgres, service_role=X/postgres

crear_resena | p_salon_id uuid, p_turno_id bigint, p_estrellas smallint, p_comentario text
             | secdef=true | config=search_path=public
             | ACL: =X/postgres, postgres=X/postgres, anon=X/postgres, authenticated=X/postgres, service_role=X/postgres
```

La sobrecarga de 3 argumentos **no existe en el repositorio actual**. El repo solo define la de 4 argumentos (`supabase/sql/i80_resenas_rpc.sql:121-171`). El commit `ecb9c4e` introdujo una versión de 3 argumentos con otra comprobación (`git show ecb9c4e:supabase/sql/i80_resenas_rpc.sql:57-64`), pero la definición que está viva no coincide con esa versión: fue editada fuera del versionado. Su cuerpo efectivo (extraído con `pg_get_functiondef`) contiene:

```sql
if not (
       public.es_miembro(v_turno.salon_id)
    or (exists (select 1 from public.clientes c
                where c.id = v_turno.cliente_id
                  and c.salon_id = v_turno.salon_id))
) then
    raise exception 'sin_permisos';
end if;
...
insert into public.resenas (salon_id, cliente_id, turno_id, estrellas, comentario)
values (v_turno.salon_id, v_turno.cliente_id, p_turno_id, p_estrellas, btrim(p_comentario))
returning id;
```

La segunda condición es **verdadera para cualquier turno cuyo `cliente_id` apunte a una ficha del mismo salón** (el caso normal de un turno completado; para el turno 111 se verificó `cliente_ok=1`), porque `v_turno.cliente_id` referencia una fila de `clientes` del mismo salón. No depende de `auth.uid()` ni de quién llama. Para `anon`, `public.es_miembro(...)` es falso, pero la segunda rama da `true`, así que el `raise` no se ejecuta y se llega al `INSERT`. La única excepción es un turno con `cliente_id` nulo o inconsistente; el turno 111, que es el único completado al momento, no lo es.

Prueba de exposición por REST, **sin sesión** y con la `apikey` publishable:

```http
POST /rest/v1/rpc/crear_resena
apikey: sb_publishable_…
Content-Type: application/json

{"p_turno_id":-1,"p_estrellas":1,"p_comentario":"probe"}
```

```http
HTTP/1.1 400
{"code":"P0001","details":null,"hint":null,"message":"turno_no_existe"}
```

Ese `400` demuestra que PostgREST resolvió la sobrecarga de 3 argumentos y ejecutó la función como `anon`; con `p_turno_id = -1` no hay escritura porque falla antes. La prueba de autorización se hizo con un turno real completado (id `111`, `cliente_id=47`, salón `76d27107-…`), también como `anon`, dentro de una transacción read-only:

```sql
set default_transaction_read_only = on;
begin read only;
select set_config('request.jwt.claims','{"role":"anon"}', true);
set local role anon;
select public.crear_resena(111::bigint, 1::integer, 'AUDIT_PROBE_SIN_ESCRITURA');
rollback;
```

```text
ERROR: 25006: cannot execute INSERT in a read-only transaction
CONTEXT: SQL statement "insert into public.resenas (...)"
         PL/pgSQL function crear_resena(bigint,integer,text) line 46 at SQL statement
```

El error se produce **en el INSERT**, no en `sin_permisos`: la comprobación de autorización pasó para `anon`. No se insertó nada porque la transacción era read-only. La misma prueba con una identidad autenticada de **otro salón** (staff de «Eli M. Nails») dio el mismo `25006`, confirmando que tampoco hay control de pertenencia.

#### Escenario de explotación paso a paso

1. El atacante obtiene la `publishable key` del sitio (está embebida en `marketplace.html`/`portal.html`; no es un secreto).
2. Enumera turnos completados. Los `id` son `bigint` secuenciales; además `turno_puede_resenarse(id)` es ejecutable por `anon` y devuelve `puede=true` + `salon_id` + `estado` para turnos completados (ver B-4). Al momento de la auditoría el único completado es `111`, pero a escala se enumeran todos.
3. Para cada turno completado, hace:

   ```bash
   curl -s -X POST 'https://wppleywdprvdlbajeubl.supabase.co/rest/v1/rpc/crear_resena' \
     -H 'apikey: sb_publishable_…' -H 'Content-Type: application/json' \
     -d '{"p_turno_id":111,"p_estrellas":1,"p_comentario":"<contenido difamatorio o HTML>"}'
   ```

4. La fila queda en `public.resenas` con `salon_id` y `cliente_id` del turno real (la reseña parece de la clienta real), `estrellas` 1–5 y el comentario elegido.
5. Como hay un único índice `un_resena_por_turno`, el atacante **quema el cupo**: la clienta real ya no puede reseñar ese turno y la dueña tampoco. Repite en todos los turnos completados de todos los salones.
6. `public_marketplace_salones` calcula `count_resenas` y `promedio_estrellas` desde `resenas`: el promedio público del salón cambia de inmediato.

#### Impacto de negocio

- **Integridad del marketplace:** cualquier persona, sin cuenta, puede fabricar reseñas de 1 o 5 estrellas y manipular el ranking/promedio que ven las clientas.
- **Difamación y extorsión:** reseñas negativas atribuidas a clientas reales, con el agravante de que el `cliente_id` es el verdadero.
- **Denegación de reseñas genuinas:** el cupo único por turno lo consume el atacante.
- **XSS almacenado latente:** el comentario se guarda sin sanitizar; hoy no se renderiza en las páginas públicas (ver B-3), pero cualquier consumidor futuro que lo pinte con `innerHTML` ejecutará el payload en el navegador de las visitantes y del admin.
- **Costo de remediación:** hay que auditar/limpiar reseñas inyectadas y reconstruir promedios; no hay auditoría de inserción de reseñas para distinguir el origen.

#### Fix concreto

1. **Eliminar la sobrecarga vieja** (es la causa raíz del vector):

   ```sql
   drop function if exists public.crear_resena(bigint, integer, text);
   ```

2. **Cerrar la ACL de la sobrecarga válida** (no alcanza con `revoke ... from public`, porque `anon` tiene un grant explícito):

   ```sql
   revoke execute on function public.crear_resena(uuid, bigint, smallint, text)
     from public, anon;
   grant execute on function public.crear_resena(uuid, bigint, smallint, text)
     to authenticated, service_role;
   ```

3. **Reescribir la validación de la 4-arg para que la dueña del turno sea la clienta autenticada**, usando `_mis_clientes()` (que contempla `auth_user_id` o email) y no `clientes.user_id`:

   ```sql
   create or replace function public.crear_resena(
       p_salon_id uuid, p_turno_id bigint,
       p_estrellas smallint, p_comentario text
   ) returns public.resenas
   language plpgsql security definer set search_path = public
   as $$
   declare
       v_cliente_id bigint;
       v_result public.resenas%rowtype;
       v_turno public.turnos%rowtype;
   begin
       if p_estrellas is null or p_estrellas < 1 or p_estrellas > 5 then
           raise exception 'estrellas_invalidas';
       end if;

       select * into v_turno from public.turnos where id = p_turno_id;
       if not found
          or v_turno.salon_id is distinct from p_salon_id
          or lower(coalesce(v_turno.status,'')) not in ('realizado','completed','completado') then
           raise exception 'turno_invalido';
       end if;

       select c.id into v_cliente_id
       from public.clientes c
       where c.salon_id = p_salon_id
         and c.id in (select public._mis_clientes())
         and c.id = v_turno.cliente_id
       limit 1;

       if v_cliente_id is null then
           raise exception 'turno_no_pertenece_cliente';
       end if;

       if exists (select 1 from public.resenas r where r.turno_id = p_turno_id) then
           raise exception 'ya_existe_resena';
       end if;

       insert into public.resenas (salon_id, cliente_id, turno_id, estrellas, comentario)
       values (p_salon_id, v_cliente_id, p_turno_id, p_estrellas, btrim(p_comentario))
       returning * into v_result;

       return v_result;
   end $$;
   ```

   Nota: `c.id = v_turno.cliente_id` es la condición que falta hoy; `c.id in (select public._mis_clientes())` es la identidad correcta de la clienta.

4. **Sanitizar el comentario** (defensa en profundidad; ver B-3):

   ```sql
   alter table public.resenas
     add constraint resenas_comentario_sin_html
     check (comentario is null or comentario !~ '<[^>]*>');
   ```

   Y en el frontend, pintar siempre con `textContent` (nunca `innerHTML`).

5. **Auditoría/limpieza:** `select count(*) from public.resenas;` (al momento: 0 filas), revisar `creado_en` y, si aparece una reseña sin turno/clienta coherente, borrarla. No hay tabla de auditoría de reseñas; conviene agregar un trigger de auditoría o al menos loguear `auth.uid()`.

6. **Proceso:** toda migración que cambie la firma de una función debe hacer `DROP FUNCTION` de la firma anterior. Ver M-3.

---

### A-1 — [ALTO] `turnos_de_cliente()` filtra turnos completados de otros salones

**Estado:** **[VIVO-SIM]** + **[LECTURA]** — reproducido en vivo simulando rol/claims reales en transacción read-only.

#### Evidencia

`supabase/sql/i81_turnos_cliente.sql:38-43`:

```sql
from public.turnos t
join public.clientes c on c.user_id = auth.uid()
join public.salones s on s.id = t.salon_id
where (p_estado is null or t.status = p_estado)
  and t.status in ('realizado', 'completed', 'completado')
```

Falta la correlación `c.id = t.cliente_id` (o `t.cliente_id in (select public._mis_clientes())`). El `join` con `clientes` solo sirve para exigir que el que llama tenga **alguna** ficha de clienta con `user_id = auth.uid()`; no filtra los turnos por esa ficha. El resultado es el producto cartesiano entre las fichas del usuario y **todos** los turnos completados de **todos** los salones, repetido una vez por ficha.

Prueba en vivo (read-only, sin escrituras), con una cuenta staff real del salón `1c13a011-…` («Eli M. Nails»), que tiene 2 fichas de clienta con `user_id` propio:

```sql
begin read only;
select set_config('request.jwt.claims','{"sub":"5a6e…","role":"authenticated"}', true);
set local role authenticated;
select id, salon_id, salon_nombre, salon_slug, servicio_nombre, estado
  from public.turnos_de_cliente();
rollback;
```

```text
id  | salon_id                             | salon_nombre         | salon_slug | servicio_nombre | estado
111 | 76d27107-8ee7-4925-a882-d862bb44821d | La biblia peluquería | elima-hub  | Kapping         | completed
111 | 76d27107-8ee7-4925-a882-d862bb44821d | La biblia peluquería | elima-hub  | Kapping         | completed
```

La cuenta pertenece a «Eli M. Nails» (`1c13a011-…`) y ve el turno completado de «La biblia peluquería» (`76d27107-…`), **dos veces** por sus dos fichas. No es una fuga de datos de la propia clienta: es cross-tenant. `anon` recibe `200 []` porque `auth.uid()` es `NULL` y el `join` no produce filas; el grant a `anon` existe igual (ver M-3), pero no es explotable sin sesión.

#### Escenario de explotación paso a paso

1. La dueña/staff de un salón crea fichas de clientas desde la agenda; el default `clientes.user_id = auth.uid()` hace que esas fichas queden a nombre de la cuenta staff.
2. Esa cuenta (o cualquier cuenta con una ficha así) llama `supabase.rpc('turnos_de_cliente')` desde la consola del navegador, sin necesitar permisos de miembro del otro salón.
3. Recibe `id`, `salon_id`, fecha, hora, `servicio_nombre`, `salon_nombre`, `salon_slug`, `estado` y `ya_resenado` de **todos** los turnos completados de la plataforma, no solo de su salón.
4. Puede automatizarlo y guardar la agenda de la competencia (qué servicios, qué días/horarios, qué volumen), y usar los `id` para otros vectores (por ejemplo C-1 o M-1).
5. La duplicación por ficha puede contaminar la UI del portal (turnos repetidos) si la cuenta además usa el portal como clienta.

#### Impacto de negocio

- **Violación de aislamiento multi-tenant:** datos operativos de un salón (agenda, servicios, estado de reseña) visibles para otro salón.
- **Inteligencia competitiva:** un competidor puede medir la actividad de otro (fechas/horas/servicios completados).
- **Base para otros ataques:** los `id` de turnos ajenos alimentan C-1 (reseñas) y M-1 (canje/consulta de precios).
- **Confusión operativa:** filas duplicadas por cantidad de fichas.

#### Fix concreto

```sql
create or replace function public.turnos_de_cliente(p_estado text default null)
returns table (
    id bigint, salon_id uuid, fecha date, hora time,
    servicio_nombre text, salon_nombre text, salon_slug text,
    estado text, ya_resenado boolean
)
language sql
security definer
set search_path = public
as $$
    select t.id,
           t.salon_id,
           t.appointment_date,
           t.appointment_time,
           t.service_type,
           s.nombre,
           s.slug,
           t.status,
           exists (select 1 from public.resenas r where r.turno_id = t.id)
    from public.turnos t
    join public.salones s on s.id = t.salon_id
    where t.cliente_id in (select public._mis_clientes())
      and (p_estado is null or t.status = p_estado)
      and t.status in ('realizado', 'completed', 'completado')
    order by t.appointment_date desc, t.appointment_time desc;
$$;

revoke all on function public.turnos_de_cliente(text) from public, anon;
grant execute on function public.turnos_de_cliente(text) to authenticated, service_role;
```

`_mis_clientes()` ya devuelve las fichas por `auth_user_id` **o** por email verificado, que es la identidad correcta de la clienta. Con `t.cliente_id in (...)` desaparece el producto cartesiano y el cross-tenant.

**Test de regresión:** login como staff con 2 fichas → `select count(*) from public.turnos_de_cliente()` debe devolver solo turnos de clientas propias (idealmente 0 si esas fichas no tienen turnos), nunca turnos de otro salón.

---

### A-2 — [ALTO] `crear_resena` 4-arg: reseñar cualquier turno del salón y usar la columna de identidad equivocada

**Estado:** **[VIVO]** parcial (anon bloqueado en la 4-arg) + **[LECTURA]** para el abuso autenticado.

#### Evidencia

`supabase/sql/i80_resenas_rpc.sql:154-167`:

```sql
select c.id into v_cliente_id
from public.clientes c
where c.user_id = auth.uid()
  and c.salon_id = p_salon_id
limit 1;

if v_cliente_id is null then
    raise exception 'No tienes un cliente activo en este salón';
end if;

insert into public.resenas (salon_id, cliente_id, turno_id, estrellas, comentario)
values (p_salon_id, v_cliente_id, p_turno_id, p_estrellas, p_comentario)
```

La función valida que el turno exista, esté completado y sea del salón (`i80:136-144`), pero **no valida que el turno pertenezca a esa clienta**. Con que el que llama tenga *una* ficha en el salón, puede reseñar el turno de cualquier otra clienta. Además usa `clientes.user_id`, que según el propio diseño de `i66` es la **staff que cargó a la clienta** (default `auth.uid()` al insertar), no la clienta. La identidad de la clienta vive en `clientes.auth_user_id` (agregada en `i66:80-85`) o en el email.

Un detalle importante: `resenas` solo tiene `SELECT` para `anon`/`authenticated` (verificado en vivo); no hay `INSERT` directo. Como `crear_resena` es `SECURITY DEFINER` y corre como owner, la policy `resenas_insertion_cliente` (`i80:57-95`) **no se evalúa** en este camino: es letra muerta. La única puerta de inserción es el RPC, y por eso el fix tiene que estar en el RPC (y en la ACL), no solo en la policy.

Datos vivos que confirman el modelo:

```text
clientes_total = 8
clientes_con_user_id = 8
clientes_con_auth_user_id = 0
```

Es decir: hoy **ninguna** clienta está vinculada por `auth_user_id`; las 8 fichas tienen `user_id` de staff. La clienta QA (`qa.clienta@…`) no tiene ficha, por eso `obtener_mis_puntos` le devuelve vacío. En la práctica:

- Una **clienta real no puede reseñar** (su `clientes.user_id` es la staff, no ella) → bug funcional del portal.
- Una **dueña/staff** puede reseñar cualquier turno completado de su salón usando la primera ficha que creó, incluso turnos de otras clientas → autopromoción/fraude de reseñas.

Prueba viva de que la 4-arg está expuesta a `anon` pero se frena en la validación de identidad (no escribe):

```http
POST /rest/v1/rpc/crear_resena
{"p_salon_id":"76d27107-…","p_turno_id":111,"p_estrellas":5,"p_comentario":"x"}
→ HTTP 400 {"code":"P0001","message":"No tienes un cliente activo en este salón"}
```

#### Escenario de explotación paso a paso

1. La dueña del salón inicia sesión en la app (cuenta owner) y obtiene su JWT.
2. Enumera los turnos completados de su salón (los ve en su agenda o vía `turnos` con su RLS de miembro).
3. Llama `POST /rest/v1/rpc/crear_resena` con `p_salon_id`, el `p_turno_id` de otra clienta, 5 estrellas y un comentario elogioso; la función toma su primera ficha de `clientes` (creada por ella) y firma la reseña como si fuera esa clienta.
4. Repite en todos los turnos completados; el promedio público de su salón sube.
5. Como el cupo es único por turno, la clienta real ya no puede dejar su reseña.

#### Impacto de negocio

- **Fraude de reputación:** auto-reseñas de 5 estrellas de la propia dueña; supresión de la reseña real.
- **Pérdida de confianza:** el marketplace promete «reseñas reales de clientas» (`marketplace.html:9`), pero la identidad no se verifica.
- **Bloqueo funcional:** las clientas reales no pueden reseñar, lo que reduce el volumen de reseñas genuinas.
- **Combinado con C-1:** el atacante anónimo ya puede hacer lo mismo sin cuenta; A-2 sigue existiendo aunque se elimine la 3-arg.

#### Fix concreto

Mismo reemplazo que C-1, punto 3: usar `_mis_clientes()` y exigir `c.id = v_turno.cliente_id`. Además:

```sql
revoke execute on function public.crear_resena(uuid, bigint, smallint, text)
  from public, anon;
grant execute on function public.crear_resena(uuid, bigint, smallint, text)
  to authenticated, service_role;
```

Y corregir también `turno_puede_resenarse` (`i80:178-204`), que usa el mismo `c.user_id = auth.uid()`:

```sql
create or replace function public.turno_puede_resenarse(p_turno_id bigint)
returns table (puede boolean, salon_id uuid, cliente_id bigint, estado_turno text)
language sql security definer set search_path = public
as $$
    select true, t.salon_id, t.cliente_id, t.status
    from public.turnos t
    where t.id = p_turno_id
      and t.cliente_id in (select public._mis_clientes())
      and lower(t.status) in ('realizado','completed','completado')
      and not exists (select 1 from public.resenas r where r.turno_id = t.id);
$$;

revoke all on function public.turno_puede_resenarse(bigint) from public, anon;
grant execute on function public.turno_puede_resenarse(bigint) to authenticated, service_role;
```

**Test de regresión:** con una clienta real vinculada, `crear_resena` sobre el turno de otra clienta del mismo salón debe fallar con `turno_no_pertenece_cliente`; sobre su propio turno debe insertar una sola vez.

---

### M-1 — [MEDIO] Puntos: se valida el salón, no el dueño del turno

**Estado:** **[VIVO]** — saldo y canje verificados contra la base con identidad real de otra clienta, en read-only.

#### Evidencia

`supabase/sql/i82_canje_cliente_rpc.sql:48-66` (saldo) y `147-165` (canje) resuelven la ficha de la clienta así:

```sql
select c.id into v_cliente_id
from public.clientes c
where c.salon_id = v_turno.salon_id
  and c.auth_user_id = auth.uid()
limit 1;
-- fallback por email…
```

Solo se exige que la clienta exista **en el salón del turno**; nunca se compara `v_turno.cliente_id` con `v_cliente_id`. El canje (`i82:173-220`) bloquea la billetera de la clienta, valida saldo y tope, y luego inserta `-p_puntos` y actualiza `turnos.descuento_puntos`. Nada ata el turno a la clienta que canjea.

Prueba en vivo con una identidad real (usuario cuyo email coincide con la ficha 1 del salón `1c13a011-…`) y un turno de **otra** clienta (turno `17`, `cliente_id=3`):

```sql
begin read only;
select set_config('request.jwt.claims','{"sub":"5a6e…","role":"authenticated"}', true);
set local role authenticated;
select * from public.cliente_saldo_puntos_turno(17::bigint);
rollback;
```

```text
saldo_disponible | tope_maximo | precio_original | salon_id                             | salon_nombre | turno_estado
2.00             | 6600        | 22003           | 1c13a011-78c4-4009-9e62-7bc22b649cce | Eli M. Nails | confirmed
```

La clienta no es dueña del turno 17 y aun así obtiene su precio, tope y estado. El canje también pasó la validación de dueño: en read-only llegó hasta el `SELECT … FOR UPDATE` de la billetera (después de las validaciones de propiedad y estado) y solo lo frenó el modo read-only:

```text
ERROR: 25006: cannot execute SELECT FOR UPDATE in a read-only transaction
CONTEXT: select b.id from public.billeteras_puntos b
         where b.cliente_id = v_cliente_id and b.salon_id = v_turno.salon_id
         for update
         PL/pgSQL function cliente_canjear_puntos(bigint,numeric) line 52
```

Con una billetera con saldo ≥1 y un turno ajeno, el canje habría insertado el movimiento y actualizado `descuento_puntos` del turno ajeno. No se ejecutó la escritura.

#### Escenario de explotación paso a paso

1. La atacante es clienta de un salón (tiene ficha y, tras vincular, billetera con puntos).
2. Obtiene el `id` de un turno futuro de otra clienta del mismo salón (los `id` son secuenciales; además A-1 filtra turnos de otros salones a las cuentas staff, y `cliente_saldo_puntos_turno` confirma la existencia).
3. Consulta `cliente_saldo_puntos_turno(id)` y lee precio/tope/estado del turno ajeno (privacidad).
4. Llama `cliente_canjear_puntos(id, 1)` con sus propios puntos: el turno ajeno recibe un descuento y queda marcado con `descuento_puntos`; el chequeo `ya_canjeado` (global por turno) queda satisfecho, por lo que **la clienta dueña del turno ya no puede canjear** en él.
5. Si dos clientas distintas canjean a la vez sobre el mismo turno, ambas bloquean billeteras distintas y pueden pasar el chequeo `ya_canjeado` antes de que la otra confirme → descuento acumulado por encima del 30 % (condición de carrera; mitigada solo para una misma billetera por el `FOR UPDATE`).

#### Impacto de negocio

- **Privacidad:** precio, tope y estado de turnos de otras clientas.
- **Abuso de lógica de negocio:** consumir el cupo de canje de un turno ajeno (denegación del beneficio de fidelidad) y alterar el `descuento_puntos` sin consentimiento.
- **Inconsistencia financiera:** descuentos inesperados en turnos de terceros; con carrera, superación del tope del 30 %.
- **No es robo de puntos:** la atacante gasta sus propios puntos; el daño es de integridad/disponibilidad, no de saldo ajeno.

#### Fix concreto

En ambas funciones, después de resolver `v_cliente_id` y antes de leer saldo/tope:

```sql
if v_turno.cliente_id is distinct from v_cliente_id then
    -- cliente_saldo_puntos_turno: return; (sin filas)
    return;
end if;

-- cliente_canjear_puntos:
if v_turno.cliente_id is distinct from v_cliente_id then
    return query select false, 0, 0, 0, 'turno_no_pertenece_cliente'::text;
    return;
end if;
```

Además:

```sql
-- 1) Serializar por turno, no solo por billetera
select * into v_turno from public.turnos where id = p_turno_id for update;

-- 2) Impedir doble canje por turno a nivel de dato (no solo por chequeo)
create unique index if not exists un_canje_por_turno
  on public.movimientos_puntos (turno_id)
  where tipo = 'canjeado' and turno_id is not null;
```

Datos vivos: `movimientos_puntos` tiene 3 filas, **0** de tipo `canjeado`, así que el índice único se puede crear sin conflicto.

3) Alinear el tope con el contrato de `i73` (precio neto + descuento ya usado) y dejar el descuento exacto, no acumulativo:

```sql
v_base := coalesce(v_turno.price, 0) + coalesce(v_turno.descuento_puntos, 0);
v_tope := floor(v_base * 0.30);

update public.turnos
   set descuento_puntos = p_puntos
 where id = p_turno_id;
```

**Test de regresión:** clienta A no puede consultar ni canjear en un turno de clienta B del mismo salón; dos canjes concurrentes sobre el mismo turno fallan con `ya_canjeado`/violación de índice único.

---

### M-2 — [MEDIO] `anon` lee plan, suscripción, trial y `dueno_user_id` de todos los salones publicados

**Estado:** **[VIVO]**.

#### Evidencia

Sin sesión, solo con la `apikey` publishable:

```http
GET /rest/v1/salones?select=*&limit=1
```

```json
[{
  "id":"1c13a011-78c4-4009-9e62-7bc22b649cce",
  "nombre":"Eli M. Nails",
  "dueno_user_id":"92886f5a-71d3-47c3-a6cb-f59ea750bedf",
  "plan_id":"pro",
  "estado_suscripcion":"active",
  "trial_hasta":"2027-01-04T04:27:45.439+00:00",
  "suscripcion_desde":"2026-11-10T10:47:08.478+00:00",
  "cancelada_en":null,
  "telefono_contacto":"+5491112345678",
  ...
}]
```

La policy viva `salones_lectura_publica` (`anon, authenticated`, `USING publicado IS TRUE AND activo IS TRUE`) permite leer las filas publicadas, y el `GRANT SELECT` por defecto de Supabase aplica a **todas** las columnas. La policy no está en el repo (drift); el repo solo tiene `salones_miembro` y `salones_edicion` (`supabase/sql/00_baseline.sql:7749-7757`).

#### Escenario de explotación paso a paso

1. Cualquiera con la `publishable key` (pública) consulta `GET /rest/v1/salones?select=*`.
2. Obtiene el UUID de la dueña, el plan (`gratis`/`pro`/`premium`), el estado (`trial`/`active`/`past_due`), fechas de trial/suscripción y baja, y el teléfono de contacto.
3. Filtra por `estado_suscripcion=eq.past_due` o `trial_hasta` próximo para armar campañas de phishing/venta, o usa el UUID de la dueña para correlacionar con otras filtraciones.
4. Usa la lista de salones con plan para inteligencia comercial (a quién atacar, quién está por vencer).

#### Impacto de negocio

- Divulgación de datos comerciales/financieros del salón (plan, estado de cobro, trial) y del identificador de la cuenta de la dueña.
- Phishing/social engineering dirigido a dueñas en `past_due` o con trial por vencer.
- Ventaja competitiva y exposición de la base de clientes B2B.

#### Fix concreto

No revocar todo el `SELECT` de `salones` sin reemplazar el uso: `marketplace.html:1601` depende de `dueno_user_id` para decidir «Mi agenda» vs «Mis Puntos» (y lo hace con la `apikey` anónima, no con el JWT de la usuaria). Plan:

```sql
-- 1) Quitar el SELECT de tabla a anon y otorgar solo columnas públicas
revoke select on public.salones from anon;
grant select (id, nombre, activo, creado_en, logo_url, telefono_contacto,
              instagram, descripcion, rubro, bio, foto_portada_url, slug,
              publicado, direccion)
  on public.salones to anon;
```

2) Para el chequeo de «¿es dueña?», crear una RPC que no exponga columnas sensibles y usarla con el JWT de la sesión:

```sql
create or replace function public.mi_rol_salon()
returns table (salon_id uuid, rol text)
language sql stable security definer set search_path = public
as $$
    select m.salon_id, m.rol
    from public.miembros_salon m
    where m.user_id = auth.uid() and m.activo;
$$;
revoke all on function public.mi_rol_salon() from public, anon;
grant execute on function public.mi_rol_salon() to authenticated;
```

Y en `marketplace.html:1601` reemplazar el `fetch` a `/rest/v1/salones?dueno_user_id=…` por `supabase.rpc('mi_rol_salon')` usando el cliente autenticado (no la `apikey` como Bearer). Si se necesita el perfil público, usar `public_salon_detalle(slug)`.

3) Para `authenticated` no miembro, el mismo problema persiste (puede leer `select=*` de salones publicados). Aplicar el mismo recorte de columnas y exponer los campos sensibles del propio salón vía una RPC `mi_salon_privado()` para la dueña/staff.

---

### M-3 — [MEDIO] Drift de ACL y versionado: funciones vivas que el repo no describe

**Estado:** **[VIVO]** + **[LECTURA]**.

#### Evidencia

- La sobrecarga `crear_resena(bigint, integer, text)` existe **solo** en la base viva (C-1); el repo no la contiene.
- La policy `salones_lectura_publica` existe en la base viva y no en el repo (M-2).
- `turnos_de_cliente` tiene `EXECUTE` para `PUBLIC` (`=X/postgres`) y `anon`; `i81:47` solo hace `grant ... to authenticated`, sin `revoke`. Lo mismo pasa con `turno_puede_resenarse` y la 4-arg de `crear_resena` (`i80:173`). En cambio `i82:287-288` sí hace `revoke all ... from public, anon`, que es el patrón correcto.
- La consulta a `pg_proc` con `EXECUTE` para `anon` devuelve **más de 60 funciones** de `public`, incluyendo `admin_*`, `aprobar_recarga_puntos`, `solicitar_recarga_transferencia`, `agregar_miembro_salon`, `crear_salon_inicial`, `turnos_de_cliente`, `turno_puede_resenarse` y las dos `crear_resena`. La mayoría de las `admin_*` tienen guard interno (`es_super_admin()`) y devuelven error a `anon`; pero el control efectivo es el guard, no la ACL. `admin_tiene_billetera(p_billetera_id uuid)` no tiene guard y es un oráculo de existencia (UUID no adivinable → impacto bajo). Las funciones de trigger (`trg_*`) están expuestas por ACL pero no se pueden invocar directo como trigger.
- La consulta de `SECURITY DEFINER` sin `search_path` devolvió **0 filas**: todas fijan `search_path = public` (o `public, auth` en `agregar_miembro_salon`), lo cual está bien.

Prueba de que el patrón deja funciones nuevas expuestas: `POST /rpc/turnos_de_cliente` como `anon` → `200 []`; `POST /rpc/crear_resena` 3-args → `400 turno_no_existe` (C-1); `POST /rpc/turno_puede_resenarse` → `200`.

#### Escenario de explotación paso a paso

1. Cualquier función `SECURITY DEFINER` nueva que se cree sin `revoke` queda ejecutable por `anon` por los privilegios por defecto de Supabase. Si el desarrollador se olvida del guard interno, es un crítico instantáneo.
2. Al cambiar la firma con `create or replace function`, la firma vieja **no se reemplaza**: queda viva como sobrecarga huérfana. El atacante puede probar nombres de RPC y argumentos (PostgREST responde `404` vs `400`/`200`) y explotar la vieja.
3. El repo y la base divergen: una auditoría basada solo en `supabase/sql/` no ve la función maliciosa/vieja, y un `supabase db reset` desde cero produce un estado distinto al de producción.

#### Impacto de negocio

- Superficie de ataque que crece sin control y sin revisión.
- Regresiones de seguridad invisibles al code review (C-1 es la prueba).
- Imposibilidad de reconstruir producción desde el repo; incidentes imposibles de reproducir.

#### Fix concreto

1. **Migración de ACL con allowlist** (una sola vez, revisada):

   ```sql
   -- Cerrar todo lo no explícitamente público. NO hace falta re-otorgar a
   -- authenticated: sus grants explícitos (p. ej. es_miembro, es_owner,
   -- _mis_clientes, obtener_mis_puntos) sobreviven a este revoke.
   revoke execute on all functions in schema public from public, anon;

   -- Allowlist pública real (marketplace + helpers de policies)
   grant execute on function public.public_crear_solicitud(uuid,text,text,date,time,bigint) to anon;
   grant execute on function public.public_salon_detalle(text) to anon;
   grant execute on function public.public_marketplace_salones(text,text) to anon;
   grant execute on function public.salon_es_publico(uuid) to anon;
   grant execute on function public.salon_branding(uuid) to anon;
   grant execute on function public.flags_publicos() to anon;
   grant execute on function public.patrocinador_publico() to anon;
   grant execute on function public.cache_epoch_actual() to anon;
   ```

   Ojo: `resenas_publicas` usa `salon_es_publico` en la policy; por eso `anon` necesita `EXECUTE` sobre esa función si se mantiene esa policy. Verificar cada policy que llame funciones. Además, toda función que solo tuviera `EXECUTE` por `PUBLIC` y que necesite un rol concreto debe recibir un `GRANT` explícito para ese rol; el repo debe versionar esa allowlist. No usar `grant execute on all functions ... to authenticated`: reabriría funciones internas que `i73` cerró a propósito (por ejemplo `recalcular_saldo_puntos`).

2. **Eliminar sobrecargas huérfanas** (empezando por C-1) y agregar al proceso: toda migración que cambie argumentos debe incluir `drop function if exists <firma vieja>;`.

3. **Chequeo en CI** que falle si una función `SECURITY DEFINER` de `public` tiene `EXECUTE` para `anon` y no está en una allowlist versionada; y que compare `pg_proc`/`pg_policies` de staging contra el repo (`supabase db diff`).

4. Revisar la lista completa de funciones con `anon=X` y confirmar guard/allowlist una por una; `admin_tiene_billetera` debería cerrarse o ir a `service_role`.

---

### B-1 — [BAJO] `resenas_lectura_publico` expone reseñas de salones no publicados

**Estado:** **[VIVO]** + **[LECTURA]**.

`supabase/sql/i80_resenas_rpc.sql:36-38` crea una policy `for select to anon using (true)`. La policy `resenas_publicas` (`i62:235-238`, `salon_es_publico(salon_id)`) ya cubre el caso correcto para `anon` y `authenticated`. La policy `using (true)` permite leer reseñas de salones en borrador/no publicados. Hoy `resenas` tiene 0 filas, así que el impacto es nulo; a futuro filtra existencia/contenido de reseñas de negocios aún no publicados. **Fix:** `drop policy if exists resenas_lectura_publico on public.resenas;` y conservar `resenas_publicas`.

---

### B-2 — [BAJO] `cliente_turnos_canjeables`: join de billetera sin `salon_id`

**Estado:** **[LECTURA]**.

`supabase/sql/i82_canje_cliente_rpc.sql:278`:

```sql
left join public.billeteras_puntos bs on bs.cliente_id = any(v_cliente_ids)
```

Falta `and bs.salon_id = t.salon_id`. Si la clienta tiene billeteras en más de un salón, cada turno se multiplica por cada billetera y muestra el saldo de otro salón junto a un turno que no corresponde. Hoy no hay clientes con más de una billetera (consulta viva: 0), así que es latente. **Fix:**

```sql
left join public.billeteras_puntos bs
  on bs.cliente_id = any(v_cliente_ids)
 and bs.salon_id = t.salon_id
```

**Test:** clienta con 2 billeteras → una sola fila por turno y saldo del salón del turno.

---

### B-3 — [BAJO] Comentario de reseña sin sanitizar: XSS almacenado latente

**Estado:** **[LECTURA]** + **[VIVO]** (render actual).

`i80:166-167` inserta `p_comentario` tal cual; la 3-arg viva solo hace `btrim` y limita longitud. No hay validación de HTML ni escape en el backend. Sin embargo, al revisar los consumidores actuales:

- `marketplace.html:823-827, 975, 1416` solo muestra cantidad/promedio (`textoResenas`), no el comentario.
- `portal.html` solo tiene el formulario; no lista comentarios.
- `admin.html` usa `textContent` en los renders relevados; no se encontró un render de `comentario` con `innerHTML`.

Por eso **hoy no hay XSS almacenado explotable** en lo auditado; el riesgo es latente y se materializa cuando se agregue una lista de reseñas que pinte el comentario con `innerHTML` (o cuando otro consumidor lo haga). El vector de inserción ya existe (C-1/A-2), así que el payload `<img src=x onerror=…>` puede quedar guardado desde ahora. **Fix:** constraint/sanitización server-side (C-1 punto 4) y render con `textContent`/DOMPurify en el frontend; sumar CSP.

---

### B-4 — [BAJO] Oráculos anónimos: `turno_puede_resenarse` y `admin_tiene_billetera`

**Estado:** **[VIVO]**.

- `POST /rest/v1/rpc/turno_puede_resenarse` con `{"p_turno_id":111}` como `anon` devuelve una fila (`puede=true`, `salon_id`, `estado_turno=completed`; `cliente_id` sale `NULL` porque es la ficha del que llama, no la del turno). Permite confirmar turnos completados y su salón sin autenticación. **Fix:** revocar de `public, anon` y limitar a turnos propios (A-2).
- `admin_tiene_billetera(uuid)` es `SECURITY DEFINER` sin guard y con `EXECUTE` para `anon`; devuelve si un UUID de billetera existe. Los UUID no son adivinables, pero es una función administrativa expuesta innecesariamente. **Fix:** `revoke execute ... from public, anon; grant ... to service_role;`.

---

### B-5 — [BAJO] Identidad por email en `_mis_clientes`/`vincular_mi_cuenta`

**Estado:** **[VIVO]** (config de auth) + **[LECTURA]**.

`i66:94-109` resuelve «mis fichas» por `c.auth_user_id = auth.uid()` **o** `lower(c.email) = email del JWT`; `vincular_mi_cuenta` (`i66:115-136`) escribe `auth_user_id` en toda ficha con ese email. La seguridad depende de que el email del JWT esté verificado. Bien: `/auth/v1/settings` devuelve `mailer_autoconfirm=false` (no hay auto-confirmación) y `anonymous_users=false`; el login QA tiene `email_confirmed_at`. Riesgo residual: si se desactiva la confirmación, se habilita OAuth con email no verificado o se carga un email mal tipeado/de otra persona en una ficha, esa cuenta puede reclamar puntos/historial ajenos. Datos vivos: 2 fichas tienen email que coincide con un usuario de auth (una de ellas, una cuenta staff usada como clienta en otro salón), y 0 fichas tienen `auth_user_id`; el flujo por email está activo. **Fix:** en `_mis_clientes`/`vincular_mi_cuenta`, exigir `auth.users.email_confirmed_at is not null` y comparar contra `auth.users.email`, no solo contra el claim; preferir el vínculo explícito (`auth_user_id`) y auditar cada vinculación. No es un hallazgo explotable con la configuración actual.

---

## 4. Controles verificados que sí funcionan (no son hallazgos)

- **Cierre de RPCs sensibles a `anon`:** `obtener_mis_puntos`, `cliente_turnos_canjeables`, `cliente_saldo_puntos_turno`, `cliente_canjear_puntos`, `procesar_puntos_turno`, `revertir_puntos_turno`, `canjear_puntos_turno`, `saldo_puntos_cliente` → `401 / 42501` en vivo. Coincide con `i71:277-310` e `i82:103-104/229-230/287-288`.
- **RLS de tablas sensibles:** como `anon` y como cuenta QA autenticada, `GET /rest/v1/turnos`, `/clientes`, `/billeteras_puntos`, `/movimientos_puntos`, `/resenas` → `200 []`; `GET /salones` solo publicados. `billeteras_puntos`/`movimientos_puntos` no tienen `SELECT` para `anon` (`401`).
- **`search_path`:** 0 funciones `SECURITY DEFINER` de `public` sin `search_path` (consulta a `pg_proc.proconfig`).
- **Guards de funciones admin:** `admin_ajustar_puntos_cliente`, `admin_emitir_puntos`, `admin_set_flag`, `admin_set_salon_activo`, `admin_todos_usuarios`, `admin_kpis_saas`, etc. verifican `super_admins`/`auth.uid()` y devuelven error a `anon`; `admin_kpis_saas` lo hace con `EXISTS (select 1 from public.super_admins …)`.
- **Puntos (lado staff):** `procesar_puntos_turno`/`revertir_puntos_turno` exigen membresía, superadmin o `service_role` (`i71:67-75`, `i73:67-75`); `recalcular_saldo_puntos` quedó solo para `service_role` (`i73:116-117`); el canje staff valida 30 % server-side con `price + descuento_puntos` y `FOR UPDATE` (`i73:181-239`); `puntos <= 0` se rechaza.
- **Canje portal (parcial):** el tope del 30 % y el rechazo de puntos ≤0 son server-side; `FOR UPDATE` en la billetera evita doble gasto de la **misma** billetera; el chequeo `ya_canjeado` evita repetir sobre el mismo turno en el caso secuencial.
- **Auth:** `mailer_autoconfirm=false`, `disable_signup=false`, `anonymous_users=false`, email habilitado, Google habilitado. No se probaron rate limits (no se enviaron OTP ni se hicieron intentos masivos).
- **Secrets:** no se encontraron claves `service_role` ni JWTs hardcodeados en el árbol de trabajo (excluyendo `node_modules`), ni en `.github/workflows/*.yml` (usan `${{ secrets.* }}`), ni en `supabase/functions/*/index.ts` (leen `Deno.env`), ni en `.env`/backups (no hay archivos de ese tipo). `git log -S "eyJhbGciOi"` no devolvió commits. `.gitignore` excluye `supabase/seed/` y `supabase/.temp/`. **Limitación:** no se auditó exhaustivamente todo el historial de git; se buscaron patrones conocidos.
- **Sin SQL injection:** las RPCs revisadas no usan SQL dinámico; los filtros son parámetros (`t.status = p_estado`) y `SECURITY DEFINER` fija `search_path`.

---

## 5. Pruebas ejecutadas y resultado

### 5.1 REST (API viva)

| # | Prueba | Rol | Resultado |
|---|---|---|---|
| 1 | `POST /auth/v1/token?grant_type=password` con cuenta QA | — | `200`; `email_confirmed_at` presente; token válido |
| 2 | `GET /auth/v1/settings` | — | `200`; `mailer_autoconfirm=false`, `disable_signup=false`, `anonymous_users=false`, `email=true`, `google=true` |
| 3 | `POST /rpc/obtener_mis_puntos` | anon | `401 42501 permission denied for function` |
| 4 | `POST /rpc/cliente_turnos_canjeables` | anon | `401 42501` |
| 5 | `POST /rpc/cliente_saldo_puntos_turno(-1)` | anon | `401 42501` |
| 6 | `POST /rpc/cliente_canjear_puntos(-1,1)` | anon | `401 42501` |
| 7 | `POST /rpc/procesar_puntos_turno(-1)` | anon | `401 42501` |
| 8 | `POST /rpc/revertir_puntos_turno(-1)` | anon | `401 42501` |
| 9 | `POST /rpc/canjear_puntos_turno(-1)` | anon | `401 42501` |
| 10 | `POST /rpc/saldo_puntos_cliente(1)` | anon | `401 42501` |
| 11 | `POST /rpc/turnos_de_cliente({})` | anon | `200 []` (grant a `anon`, sin datos por `auth.uid()` nulo) |
| 12 | `POST /rpc/turno_puede_resenarse(-1)` | anon | `200 []` (función expuesta) |
| 13 | `POST /rpc/crear_resena` 4-arg, turno `-1` | anon | `400 P0001 "El turno no existe…"` (expuesta; no escribe) |
| 14 | `POST /rpc/crear_resena` 3-arg, turno `-1` | anon | `400 P0001 "turno_no_existe"` (sobrecarga expuesta; no escribe) |
| 15 | `GET /salones?select=*` | anon | `200` con `dueno_user_id`, `plan_id`, `estado_suscripcion`, `trial_hasta`, `suscripcion_desde`, `cancelada_en` |
| 16 | `GET /turnos`, `/clientes`, `/resenas` | anon | `200 []` (RLS) |
| 17 | `GET /billeteras_puntos`, `/movimientos_puntos` | anon | `401 42501` (sin grant) |
| 18 | `POST /rpc/obtener_mis_puntos` | QA autenticada | `200 {"saldo":0,"clienta":"","movimientos":[]}` (sin ficha de clienta) |
| 19 | `POST /rpc/turnos_de_cliente` | QA autenticada | `200 []` |
| 20 | `POST /rpc/cliente_turnos_canjeables` | QA autenticada | `200 []` |
| 21 | `GET /turnos`, `/clientes`, `/billeteras_puntos`, `/movimientos_puntos`, `/resenas` | QA autenticada | `200 []` (RLS) |
| 22 | `POST /rpc/saldo_puntos_cliente(1)` | QA autenticada | `400 P0001 "sin_permisos"` |
| 23 | `POST /auth/v1/token` con `qa.staff@…` (cuenta QA del seed) | — | `200`; sin membresías ni fichas; RPCs del portal devuelven vacío |

### 5.2 SQL read-only contra la base viva

| # | Prueba | Resultado |
|---|---|---|
| 24 | `pg_proc` ACL/SECURITY DEFINER/`proconfig` de las RPCs del portal | 2 sobrecargas de `crear_resena`; la 3-arg con `anon=X`; `turnos_de_cliente`/`turno_puede_resenarse` con `=X` (PUBLIC); todas con `search_path=public` |
| 25 | `pg_proc` definer sin `search_path` | **0 filas** |
| 26 | `pg_policies` de `resenas` | `resenas_lectura_publico` → `{anon}` `USING true`; `resenas_publicas` → `{anon,authenticated}` `salon_es_publico`; policies de dueño/miembro |
| 27 | `pg_policies` de `turnos`/`clientes` | `turnos_*` y `clientes_salon` por membresía/owner; sin policies para `anon` |
| 28 | Conteos | `turnos=11`, `realizados=1` (id 111), `clientes=8`, `clientes.con_user_id=8`, `clientes.con_auth_user_id=0`, `salones=8`, `resenas=0`, `billeteras=2`, `movimientos=3` |
| 29 | `turnos_de_cliente` como staff real `5a6e…` de «Eli M. Nails» (2 fichas) | 2 filas del turno `111` de «La biblia peluquería» (cross-tenant + duplicación) |
| 30 | `crear_resena(111,1,'…')` como `anon` en read-only | `25006` abortado en el `INSERT` → **la autorización pasó**; no se escribió |
| 31 | `crear_resena(111,1,'…')` como staff de otro salón en read-only | `25006` en el `INSERT` → la autorización también pasa para autenticados |
| 32 | `crear_resena` 4-arg (111) como `anon` en read-only | `P0001 "No tienes un cliente activo en este salón"` (no llega al INSERT) |
| 33 | `turno_puede_resenarse(111)` como `anon` | `puede=true`, `salon_id=76d27107-…`, `estado=completed`, `cliente_id NULL` |
| 34 | `cliente_saldo_puntos_turno(17)` con identidad de la ficha 1 (turno 17 es de la ficha 3) | Devuelve `saldo=2`, `tope=6600`, `precio=22003`, salón `1c13a011-…`, `confirmed` → **dueño ajeno** |
| 35 | `cliente_canjear_puntos(17,1)` con esa identidad, read-only | `25006` en `SELECT … FOR UPDATE` (línea 52) → **pasó la validación de dueño**; no se escribió |
| 36 | `cliente_saldo_puntos_turno(17)` con la QA (sin ficha) | `[]` (control) |
| 37 | `movimientos_puntos` por tipo | 2 `ajuste`, 1 `ganado`, **0 `canjeado`** (el índice único de canje es seguro) |
| 38 | Funciones con `anon=X` | >60 en `public`; la mayoría `admin_*` con guard; `crear_resena` 3-arg sin guard efectivo; `admin_tiene_billetera` sin guard |
| 39 | Búsqueda de `service_role`/JWT hardcodeado | Sin hallazgos en árbol de trabajo, workflows, Edge Functions, `.env`, backups; `git log -S "eyJhbGciOi"` vacío |

---

## 6. Limitaciones, notas de método y limpieza

1. **No se ejecutó ninguna escritura.** El vector de C-1 y M-1 se verificó hasta el límite del `INSERT`/`FOR UPDATE` dentro de `set default_transaction_read_only = on` + `begin read only`; el motor abortó con `25006`. No se crearon reseñas, no se canjearon puntos, no se enviaron OTP y no se modificó ninguna cuenta.
2. **No se usaron credenciales de dueñas/staff reales.** Para reproducir el cross-tenant de A-1 y el dueño ajeno de M-1 se usó una **simulación de rol/claims** en read-only (`set local role authenticated` + `request.jwt.claims`) con UIDs reales obtenidos por SQL. Reproduce el contexto de ejecución de PostgREST, pero no la capa de login/sesión. Las identidades se muestran enmascaradas en este informe.
3. **La cuenta QA no tiene ficha de clienta.** `obtener_mis_puntos`, `turnos_de_cliente` y `cliente_turnos_canjeables` devuelven vacío para ella; los defectos de M-1/A-2 se verificaron con el código vivo y con una identidad real simulada, no con la QA. La QA sirvió para confirmar login, settings de auth y el cierre de RPCs a `anon`.
4. **Rate limits de GoTrue no se probaron** (requeriría intentos masivos/OTP, prohibido por el alcance). Solo se inspeccionó `/auth/v1/settings`.
5. **La base viva se consultó con `supabase db query --linked`** (Management API, rol `postgres`) en modo read-only. Donde hubo drift, el informe se apoya en `pg_proc`/`pg_policies` vivos y lo indica; no se asume que el repo refleje producción.
6. **Búsqueda de secretos:** se cubrió el árbol de trabajo (sin `node_modules`), workflows, Edge Functions, `.env`/backups y búsquedas puntuales en el historial (`git log -S`). No es un escaneo exhaustivo de todo el historial; no se encontró `service_role` hardcodeada.
7. **Artefacto local con token:** `_audit/harness/setup.html:5` contiene un `access_token` de la cuenta QA en texto plano (artefacto **untracked** de la auditoría del Lead). No está en git, pero conviene borrarlo/rotarlo y agregar `_audit/` al `.gitignore` antes de cualquier commit.
8. **Sin evidencia de explotación previa:** `public.resenas` tiene 0 filas al momento de la auditoría. No hay tabla de auditoría de reseñas; se recomienda monitorear inserciones después del fix.
