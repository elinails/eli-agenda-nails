# Auditoría — Portal de clientas «MI PERFIL · ELIMA HUB»

**URL auditada:** https://eli-agenda-nails.vercel.app/portal.html
**Fecha:** 11 de noviembre de 2026 · America/Argentina/Buenos_Aires
**Código:** `portal.html` — 1.356 líneas, 56.318 B, single-file (HTML + CSS + JS inline)
**Commit de referencia:** `c744e96`
**Método:** lectura completa del código + ejecución real en Chromium (1280×800 y 390×844), sesión QA real (`qa.clienta@elimabelleza.test`), llamadas REST al backend Supabase, cálculo de contraste WCAG y pruebas instrumentadas sobre una copia del archivo.
**Alcance:** esta página. El detalle de backend está en [`_audit/02-seguridad-backend.md`](_audit/02-seguridad-backend.md) y el QA de UX en [`_audit/03-ux-live.md`](_audit/03-ux-live.md).

---

## 1. Veredicto ejecutivo

**El portal no se puede usar. Está roto en la primera pantalla, para el 100 % de las visitas, y de una forma que no se puede cerrar.**

Al abrir `portal.html` aparecen **dos modales vacíos superpuestos** —«Dejá tu reseña» y «Detalles del Turno»— que tapan el login. El botón *Cancelar* no hace nada, el clic en el fondo no hace nada y `Escape` no hace nada: el atributo `hidden` no logra ocultarlos porque el CSS de `.modal-overlay` lo pisa. Con mouse o dedo no se puede escribir el email ni ver la página; con teclado se llega a campos que están **detrás del overlay y no se ven** (el foco no tiene indicador).

Debajo de eso hay un segundo problema estructural: **los datos de la clienta no llegan**. Las consultas `turnos_de_cliente` y `crear_resena` vinculan la ficha de la clienta con `clientes.user_id`, que en este esquema es **la cuenta del salón que cargó la ficha**, no la cuenta de la clienta. Resultado: una clienta real inicia sesión y no ve ningún turno (`Mis Turnos` siempre vacío), y la RPC de reseña le responde «No tenés un cliente activo en este salón». La función de reseñas, que es la razón de ser del portal, hoy no puede funcionar para clientas. Al mismo tiempo, esa misma JOIN sin correlación hace que una cuenta de staff vea turnos completados de **otros salones** (verificado en vivo: un staff de «Eli M. Nails» recibió el turno de «La biblia peluquería», duplicado).

Y hay un tercer problema, de seguridad y de integridad del marketplace: en la base viva quedó una versión vieja de `crear_resena` (3 argumentos) que **no está en el repositorio**, conserva permiso de ejecución para `anon` y tiene una validación tautológica. Con la clave pública, **sin iniciar sesión**, se puede insertar una reseña en cualquier turno completado de cualquier salón, atribuida a la clienta real y consumiendo su cupo de reseña. El backend lo verificó en vivo hasta el límite del `INSERT` (transacción read-only): hoy hay un turno completado, así que el vector es explotable ya. El detalle está en el anexo 02.

Y lo que sí funciona a medias —estrellas, canje, fechas— tiene defectos que lo anulan: las estrellas se destildan solas al mover el mouse y cuentan una de más, las fechas de los turnos se muestran **un día antes**, y el canje de puntos depende de un saldo leído antes de que termine de cargar.

| Dimensión | Estado |
|---|---|
| Que la página se pueda abrir y usar | 🔴 Bloqueada por modales en la primera carga |
| Login OTP | 🔴 Inalcanzable; además sin límites ni validación fuerte |
| «Mis Turnos» / reseñas | 🔴 No devuelve nada para clientas reales; reseña sin control de dueño |
| Integridad del sistema de reseñas | 🔴 `anon` puede insertar reseñas en cualquier turno completado (función legacy viva) |
| Aislamiento entre salones | 🔴 `turnos_de_cliente` muestra turnos de otros salones; saldo/canje leen turnos ajenos |
| Canje de puntos | 🟠 Visible desde el login; botón inerte; carrera de saldo; listener duplicado |
| Fechas | 🔴 Turnos y turnos futuros, un día antes |
| Accesibilidad | 🔴 Sin foco visible, sin semántica de diálogo, sin trampa de foco, contraste de CTA 2,53:1 |
| Seguridad de dependencias | 🟠 CDN sin SRI, sin CSP; sesión en `localStorage` |
| Diseño / identidad | 🟢 Sistema visual coherente y apropiado; el problema no es estética, es ejecución |
| Performance | 🟠 150,8 KB en 7 requests, FCP ~900 ms; aceptable, pero dos dependencias externas bloqueantes y sin fallback |

**Riesgo de negocio:** una clienta que abre el portal para ver sus puntos o dejar una reseña se encuentra con una pantalla trabada. Si insiste, no puede hacer nada. El
mensaje que la marca da es «está roto». Es el tipo de defecto que se nota en el primer clic, no en un test de laboratorio. Y en paralelo, el sistema de reseñas que alimenta el marketplace es manipulable por cualquiera con el link, sin cuenta: se pueden fabricar o destruir promedios de salones reales.

---

## 2. Cómo se probó

- **Carga real** de la URL publicada y comparación byte a byte con el código del repo: **idénticos** (SHA-256 `028D3BF5…7F0AB1`). Lo que se describe acá es lo que está online.
- **Sesión real de QA:** login por password con la cuenta de prueba del propio repo, sesión inyectada en una copia local del portal (mismo origen, mismo código) para ver el panel autenticado sin enviar emails.
- **Chromium real** con capturas a 1280×800 y a 390×844. El viewport móvil se emuló con un iframe de ancho exacto (la ventana headless de Chrome en Windows impone un ancho mínimo y recorta la captura; por eso no se usó para medir).
- **Pruebas instrumentadas** en una copia de `portal.html` (sin tocar producción) para disparar clicks y `mouseleave` reales sobre las estrellas y para verificar qué hace *Cancelar* sobre el modal.
- **REST directo a Supabase** con la clave pública y el token de QA para comprobar qué puede ejecutar un usuario autenticado y qué puede ejecutar `anon`.
- **Cálculo de contraste** con la fórmula WCAG 2.1 sobre los colores reales del CSS.

---

## 3. Hallazgos

### 🔴 Críticos

#### C1 · Dos modales taponan el portal en la primera carga y no se pueden cerrar

**Dónde:** `portal.html:216-229` (CSS), `portal.html:400` y `portal.html:424` (HTML), `portal.html:1216-1236`, `portal.html:1313-1318` (JS).
**Causa:** los modales tienen el atributo `hidden`, pero `.modal-overlay { display: flex }` es una regla de autor con `display` explícito y **gana** sobre el `display: none` del estilo del navegador para `[hidden]`. El atributo, entonces, no oculta nada. Al abrir la página se ven los dos, uno encima del otro.
**Agravante:** los tres caminos de cierre escriben `modal.hidden = true`, que ya era `true` desde el HTML. No cambian el CSS, así que no cierran nada. `Escape` ni siquiera entra al `if` porque comprueba `!modal.hidden`, que es `false` desde el arranque.
**Verificado:** captura `_qa_shots/portal/live-01-inicial-desktop.png`; en el DOM, `#modal-resena` y `#modal-turno-detalle` tienen `display: flex` con `hidden=true`; tras hacer clic en *Cancelar* y en el fondo, el `display` sigue siendo `flex` (`displayTrasCerrar: "flex"`).

![Primera carga: el modal «Detalles del Turno» tapa el login y no se puede cerrar](_qa_shots/portal/lead-01-modal-inicial-desktop.png)

**Impacto:** la página es inutilizable. Ni login, ni panel, ni nada. Es el defecto que hay que arreglar antes que cualquier otro.

```css
/* fix mínimo, una línea, al principio del <style> */
[hidden] { display: none !important; }
```

Y después, el cierre real:

```js
function cerrarModalDetalleTurno() {
  modal.hidden = true;                 // ahora sí oculta
  document.getElementById('btn-canjear').hidden = true;
  ultimoFoco?.focus();                 // devolver el foco
}
```

**Nota:** el fix de CSS también resuelve C2 de inmediato.

---

#### C2 · El bloque de canje aparece en el login y el botón «Canjear Puntos» no hace nada

**Dónde:** `portal.html:461` (`class="canje-bloque hidden"`), `portal.html:474` (`class="btn btn-canjear hidden"`), `portal.html:1235`, `portal.html:1241`.
**Causa:** **la clase `.hidden` no existe en esta página**. No se carga Tailwind, y el CSS inline solo define `.vista[hidden]` y `.alerta[hidden]`; nunca `.hidden`. Por eso:
1. `#bloque-canje` se muestra siempre, incluso antes de elegir un turno (se ve «Saldo disponible: 0 pts» en el login).
2. `#btn-canjear` se muestra siempre, con apariencia de botón principal activo.
3. `btnCanjear.hidden = true` tampoco lo oculta, porque `.btn { display: inline-flex }` vuelve a pisar `[hidden]`.
4. Al hacer clic, `turnoDetalleActual` todavía no existe → `if (!turnoId) return;` y **no pasa nada, sin mensaje**. La usuaria cree que el botón está roto (lo está).
**Verificado:** el botón es visible y clickeable en la carga inicial; al pulsarlo no aparece ningún aviso ni cambia la pantalla. En el modal, el campo acepta `100` y el texto de ayuda no se actualiza.
**Fix:** el `[hidden]` global de C1 + `hidden` en el HTML/JS. Y en el handler, cuando no hay turno, mostrar un aviso (`No hay un turno seleccionado`) en vez de retornar en silencio.

---

#### C3 · Las reseñas son imposibles de enviar: las estrellas se destildan y cuentan una de más

**Dónde:** `portal.html:1044-1081` (widget), `portal.html:1179-1181` (conteo).
**Tres defectos encadenados:**
1. **Off-by-one:** `for (var j = 0; j <= this.dataset.valor; j++)` usa `<=`, así que elegir la 3.ª estrella marca **4**. Además `data-valor` es string y la comparación se resuelve por coerción.
2. **Clase equivocada:** el código agrega `'estrellas'` (plural) pero el CSS y el conteo esperan `'seleccionada'`. La regla `.estrella.seleccionada` nunca se usa.
3. **`mouseleave` borra todo:** al salir de la fila, el handler recorre las estrellas, les saca la clase y decide el glifo *después* de sacarla, con lo que todas vuelven a `☆`. En escritorio, mover el mouse hacia «Enviar reseña» dispara ese `mouseleave` y **borra la selección**.

**Verificado (instrumentado):**
- Clic en la 3.ª estrella → `[★,★,★,★,☆]`, `marcadas: 4`.
- `mouseleave` → `[☆,☆,☆,☆,☆]`, `marcadas: 0`.
- Al pulsar «Enviar reseña» → *«Seleccioná al menos una estrella.»*, con `alertaVisible: true`.

**Impacto:** en escritorio es **imposible puntuar**; en móvil se envía una calificación corrida (3 estrellas → 4). Peor: el valor que se manda a `crear_resena` se cuenta leyendo la clase `estrellas` del DOM (`portal.html:1180`), que el `hover` también modifica; si la clienta hace clic y mueve el mouse sin salir de la fila, puede guardarse un puntaje distinto del que eligió. Y como el CSS pinta `.estrella.seleccionada` —clase que el código nunca agrega— **ninguna estrella se ve dorada nunca**. Las estrellas, además, son `<span>` de 23 px de ancho sin rol ni teclado: no se pueden elegir con `Tab` y son difíciles de acertar con el dedo. El aviso de «Seleccioná al menos una estrella» existe, pero aparece **dentro del modal de reseña, que queda detrás del de detalle**, así que la clienta no lo ve.
**Fix:**

```js
var calificacion = 0;
function pintarEstrellas() {
  [...contenedor.children].forEach(function (el, i) {
    var on = i < calificacion;
    el.textContent = on ? '★' : '☆';
    el.classList.toggle('seleccionada', on);
    el.setAttribute('aria-pressed', String(on));
  });
}
```
…con las estrellas como `<button type="button" aria-label="1 estrella">` y sin `mouseleave` que borre el estado; el hover debe previsualizar y al salir **volver al valor elegido**, no a cero.

---

#### C4 · Los turnos se muestran un día antes

**Dónde:** `portal.html:1136` (`cargarTurnos`), `portal.html:716` (`cargarTurnosFuturos`).
**Causa:** `new Date('2026-11-12')` interpreta una fecha *date-only* como **medianoche UTC**. En Argentina (UTC−3) cae el día anterior a las 21:00; `toLocaleDateString('es-AR')` imprime el día equivocado. Es el mismo defecto que ya se había documentado en el diagnóstico anterior y que reaparece acá.
**Verificado (Node, TZ Buenos Aires):** `new Date('2026-11-12').toLocaleDateString('es-AR', …)` → `11 de nov de 2026`; el día real es el **jueves 12**.
**Impacto:** «Mis Turnos» y «Turnos Futuros» muestran el turno el día anterior. Una clienta puede presentarse el día equivocado. El dato en la base está bien: el error es de visualización.
**Fix:**

```js
function fechaLocal(valor) {
  var m = /^(\d{4})-(\d{2})-(\d{2})/.exec(String(valor || ''));
  return m ? new Date(+m[1], +m[2] - 1, +m[3]) : new Date(valor);
}
```
Y para la hora: `String(t.hora || '').slice(0, 5)` (hoy se muestra `15:00:00`).

---

#### C5 · Backend: cualquiera puede publicar reseñas sin iniciar sesión

**Dónde:** base viva, función `public.crear_resena(bigint, integer, text)` — sobrecarga de 3 argumentos **que no existe en el repositorio actual**.
**Causa:** en la base quedó viva una versión vieja que conserva `EXECUTE` para `anon` y cuya comprobación de permisos es tautológica:

```sql
if not (
       public.es_miembro(v_turno.salon_id)
    or (exists (select 1 from public.clientes c
                where c.id = v_turno.cliente_id
                  and c.salon_id = v_turno.salon_id))
) then raise exception 'sin_permisos'; end if;
```

La segunda rama es verdadera para **cualquier** turno cuyo `cliente_id` apunte a una ficha del mismo salón, sin mirar `auth.uid()`. PostgREST resuelve la sobrecarga de 3 argumentos y la ejecuta como `anon`.

**Verificado en vivo (sin escribir):** `POST /rpc/crear_resena` con `p_turno_id:-1` devuelve `400 turno_no_existe` (la función se ejecutó como `anon`); con el turno completado real `111` («La biblia peluquería»), dentro de una transacción read-only, el motor abortó en el `INSERT` (`25006 cannot execute INSERT in a read-only transaction`) y **no** en `sin_permisos`: la autorización pasó. No se insertó ninguna fila.
**Impacto:** con la clave pública que viaja en el sitio, sin cuenta, se puede insertar una reseña de 1 a 5 estrellas en cualquier turno completado, atribuida a la clienta real, quemando el cupo único de reseña y moviendo el promedio público del marketplace. Hoy hay un turno completado, así que es explotable de inmediato. El comentario se guarda sin sanitizar (XSS latente si algún consumidor lo pinta con `innerHTML`).
**Fix inmediato:**

```sql
drop function if exists public.crear_resena(bigint, integer, text);
revoke execute on function public.crear_resena(uuid, bigint, smallint, text) from public, anon;
grant  execute on function public.crear_resena(uuid, bigint, smallint, text) to authenticated, service_role;
```

Y después: auditar/limpiar reseñas inyectadas y cerrar la deriva repo ↔ base (M-3 del anexo). **No** hay fuga de `service_role` en el repo ni en las Edge Functions, y el `search_path` está fijado en todas las `SECURITY DEFINER`.

---

#### C6 · Backend: aislamiento roto entre salones y clientas sin datos

**Dónde:** `supabase/sql/i81_turnos_cliente.sql:38-43`, `supabase/sql/i80_resenas_rpc.sql:154-163`, `supabase/sql/i82_canje_cliente_rpc.sql:48-66,147-177`.
**Tres problemas que comparten la misma causa —identidad de la clienta mal resuelta—:**

1. **`turnos_de_cliente` no correlaciona `turnos` con `clientes`.** Hace `join clientes c on c.user_id = auth.uid()` y nunca conecta `t` con `c`. Verificado en vivo: una cuenta de staff de «Eli M. Nails» recibió el turno completado de **otro salón** («La biblia peluquería»), duplicado ×2. Para una clienta real, en cambio, `clientes.user_id` es la cuenta del salón que cargó la ficha (0/8 fichas tienen `auth_user_id`), así que **no ve ningún turno**.
2. **`crear_resena` (4 argumentos) no valida de quién es el turno.** Comprueba que el turno esté completado y sea del salón, y que quien llama tenga *alguna* ficha en ese salón — pero nunca que el turno sea de esa ficha. Una dueña puede reseñar el turno de cualquier clienta y atribuirlo a la clienta que elija.
3. **`cliente_saldo_puntos_turno` y `cliente_canjear_puntos` validan el salón, no el dueño del turno.** Verificado en vivo: una identidad de clienta leyó precio, tope y estado de un turno de otra clienta, y el canje llegó hasta el `SELECT … FOR UPDATE` de su billetera antes de que la transacción read-only lo frenara. Es abuso de lógica de negocio: permite consumir el único cupo de canje del turno ajeno y bloquear el beneficio de la clienta real.

**Fix (resumen):**

```sql
-- identidad correcta en las tres RPC
where t.cliente_id in (select id from public._mis_clientes())
revoke all on function public.turnos_de_cliente(text) from public, anon;
```

```sql
-- crear_resena: el turno tiene que ser de la clienta que llama
select t.cliente_id into v_cliente_id
  from public.turnos t
 where t.id = p_turno_id
   and t.salon_id = p_salon_id
   and t.cliente_id in (select id from public._mis_clientes());
if v_cliente_id is null then
  raise exception 'El turno no pertenece a tu cuenta';
end if;
```

Para el canje, repetir la misma comprobación de `t.cliente_id` antes de `FOR UPDATE` en `cliente_saldo_puntos_turno` y `cliente_canjear_puntos`.

> El detalle completo, con evidencia de cada prueba, ACL y plan de migración, está en [`_audit/02-seguridad-backend.md`](_audit/02-seguridad-backend.md).

---

### 🟠 Altos

#### A1 · Accesibilidad de diálogos y foco

- Los dos modales son `<div>` sin `role="dialog"`, `aria-modal`, `aria-labelledby` ni nombre accesible (`portal.html:400-421`, `portal.html:424-478`).
- No hay **trampa de foco**: con `Tab` se recorre la página de atrás mientras el modal tapa todo. El foco termina en el email del login, invisible detrás del overlay (verificado con capturas `live-20`, `live-21`, `live-26`). En la vista autenticada, los 6 primeros stops de `Tab` caen en elementos tapados.
- **No hay ningún indicador de foco visible** en enlaces ni botones: el CSS solo define `:focus` para inputs (`portal.html:97`), y ese anillo translúcido mide **1,13:1** sobre el fondo (WCAG pide 3:1). En la captura posterior a `Tab` no se ve ningún anillo.
- La validación del login muestra el mensaje y lo anuncia (`role="alert"`), pero el input no recibe `aria-invalid`/`aria-describedby`, el borde no cambia de color y el foco se queda en el botón (`portal.html:908-911`).
- Al cambiar de vista (login → OTP → panel) no se mueve el foco ni se anuncia el cambio; el foco queda en un botón que acaba de desaparecer. El panel, además, **no tiene ningún `h1` visible**.
- `Escape` solo intenta cerrar el detalle (y no lo logra); el modal de reseña no tiene `Escape`.
- La jerarquía de encabezados salta de `h1` a `h3` en los modales; los estados vacíos usan `h2` dentro de secciones que ya tienen `h2`.

**Fix:** convertir cada modal en `role="dialog" aria-modal="true" aria-labelledby="…"`, atrapar el foco, cerrar con `Escape`, devolver el foco al disparador y agregar `:focus-visible` global. Es un cambio acotado y de alto impacto.

#### A2 · Contraste insuficiente en el botón principal y en textos secundarios

Medido con WCAG 2.1:

| Combinación | Ratio | AA normal (4,5:1) | AA grande (3:1) |
|---|---|---|---|
| Blanco `#FFF` sobre dorado `#BE9E6F` (todos los CTA) | **2,53:1** | ❌ | ❌ |
| `#9C8B90` (ink-faint) sobre papel `#FAF6F3` (footer, subtítulos) | **3,00:1** | ❌ | ❌ |
| `#9C8B90` sobre blanco | 3,23:1 | ❌ | ❌ |
| `#8C6B3A` sobre blush `#F4E7EC` (etiqueta «TUS ELIMA POINTS») | 4,09:1 | ❌ | ✅ |
| `#9C8B90` sobre blush (marca-sub, peor caso del degradé) | 2,69:1 | ❌ | ❌ |
| Borde de foco `#BE9E6F` sobre papel (indicador de foco, WCAG 1.4.11) | 2,35:1 | — | ❌ |
| Anillo de foco `gold-soft` 16 % sobre papel | 1,13:1 | — | ❌ |
| Borde `.btn-secundario` `#EADFDB` sobre blanco | 1,31:1 | — | ❌ |
| `#3B2F35` sobre papel | 11,89:1 | ✅ | ✅ |
| `#776569` sobre papel | 5,08:1 | ✅ | ✅ |

El dorado es un color de marca correcto, pero **no sirve como fondo de texto blanco**. La mejor opción conserva el dorado y pasa el texto a tinta `#3B2F35` (**5,05:1**); la alternativa es oscurecer el fondo a `#8C6B3A` con blanco (**4,91:1**). Con 15 px/600 el CTA no califica como texto grande: necesita 4,5:1. Para el foco, un `outline: 2px solid var(--ink)` da 11,89:1 y no depende de un color translúcido.

#### A3 · El canje de puntos no es confiable

- `cargarTurnosFuturos()` lee el saldo **del texto del DOM** (`portal.html:710`) en vez de un estado. Se llama en paralelo con `cargarPuntos()`, que es quien pinta ese texto; si los turnos llegan antes, el saldo leído es `0` y **no se muestra ningún botón «Canjear»** aunque la clienta tenga puntos.
- `abrirModalDetalleTurno` agrega un listener `input` **cada vez** que se abre el modal (`portal.html:825-838`) y el handler de ese listener usa un `datos` viejo (precio/tope de la apertura anterior). Después de abrir dos turnos, los textos de ayuda compiten.
- El handler hace referencia a una variable inexistente, `saldoCanje` (`portal.html:834`), por lo que al borrar el campo se lanza un `ReferenceError` y el texto de ayuda queda congelado.
- El total se calcula como `precio - puntos` sin tope del 30 % en la UI; el servidor lo rechaza después, pero la pantalla muestra un total inválido.
- **Lo que se envía no es lo que se muestra:** el texto de ayuda recorta a `datos.tope`, pero el handler del botón manda `parseInt(input.value)` crudo (`portal.html:1244`). Si la clienta escribe 5.000 con tope 3.000, la pantalla dice «hasta 3.000» y el servidor responde `supera_tope`.
- El mensaje de éxito se muestra y el modal se cierra a los 1500 ms; si el canje falla, el error del servidor se imprime crudo (`portal.html:1273`, `1300`).

**Fix:** guardar `saldoPuntos` en una variable, esperar `await cargarPuntos()` antes de pintar turnos futuros, enganchar el listener una sola vez, recalcular con `min(puntos, tope, saldo)` y traducir los motivos del servidor (`supera_tope`, `saldo_insuficiente`, `ya_canjeado`) a castellano.

#### A4 · El login OTP no está endurecido

- `signInWithOtp({ email })` sin `shouldCreateUser: false` (`portal.html:919`): cualquier email puede crear una cuenta de auth y disparar un correo. Es superficie de spam y consume la cuota de emails del proyecto.
- El estado `emailOtp` vive solo en memoria (`portal.html:501`): recargar en la pantalla del código devuelve al login sin explicación.
- La validación de email es `email.indexOf('@') < 1 || email.length < 5` (`portal.html:908`), con `novalidate`: acepta `a@@bcd`, `a@b.c` y similares.
- Los errores de Supabase se muestran crudos («No pudimos enviar el código: …»), incluidos mensajes internos de rate limit.
- Sin límite de intentos del lado del cliente para el código (depende de Supabase, pero no se informa).

#### A5 · El modal de detalle se recorta y no se puede scrollear en pantallas bajas

**Dónde:** `portal.html:222-229` (`.modal` sin `max-height`), `portal.html:216-221` (overlay `overflow: visible`).
**Medido** (device metrics reales, DPR 2): en **360×640** la tarjeta mide 709 px, arranca en `y=-34` y termina en 674 → 34 px recortados arriba y abajo, el botón «Canjear Puntos» queda **inalcanzable**. En **320×568** solo se ve el **78 %** (`y=-80`, `bottom=649`). Como el overlay es `position:fixed` y no hay contenedor scrolleable, el scroll del `body` no mueve el modal: lo recortado es inaccesible.
**Impacto:** en un Android de 640 px de alto o un iPhone SE la clienta no puede leer el turno ni canjear.
**Fix:**

```css
.modal-overlay{ padding:16px; overflow-y:auto; }
.modal,.modal-detalle{ max-height:calc(100dvh - 32px); overflow-y:auto; }
@media (max-height:640px){ .modal-overlay{ align-items:flex-start; } }
```

#### A6 · Dependencias y sesión

- `supabase-js@2.45.4` se carga desde jsDelivr **sin `integrity`** (`portal.html:486`) y la página **no tiene CSP**. Si el CDN se compromete, el script tiene acceso a la sesión y a todas las RPC de la clienta. La versión, además, está lejos de la actual (2.119 en `package.json`).
- La sesión se persiste en `localStorage` (clave `eli-portal-auth`): cualquier XSS equivale a robo de sesión. Hoy el render usa `textContent` en casi todo, pero el comentario de reseña va a un backend que lo sirve al marketplace (ver anexo de seguridad).
- Faltan cabeceras: `Content-Security-Policy`, `X-Content-Type-Options`, `Referrer-Policy`, `Permissions-Policy`. `Strict-Transport-Security` sí está.

---

### 🟡 Medios

| # | Hallazgo | Evidencia / fix |
|---|---|---|
| M1 | **Header roto a 390 px:** «ELIMA HUB» se parte en dos líneas y «Ver salones» queda descolgado debajo de la marca, fuera de la columna de acciones. | `portal.html:60-69`; captura `lead-04-panel-390.png`. `.marca-nombre{white-space:nowrap}` + `.cabecera-fila{flex-wrap:wrap}` o menú móvil. |
| M2 | **Etiquetas duplicadas en el modal de detalle:** «Salón / Salón», «Servicio / Servicio», «Fecha / Fecha», «Hora», «Precio». El `<label>` del campo y el `.detalle-label` interno repiten el mismo texto. | `portal.html:427-458`; visible en `lead-01`. Quitar el `<label>` externo o el interno. |
| M3 | **Tres estados vacíos apilados** («Aún no tenés turnos completados», «No tenés turnos futuros», «Todavía no tenés puntos») ocupan la mayor parte del panel y hacen que la página parezca vacía aunque esté todo bien. | Consolidar en un solo bloque de bienvenida + acciones (reservar, ver salones), o mostrar Movimientos recién cuando haya datos. |
| M4 | **Formato de hora y precio:** se muestra `15:00:00` (segundos) y `$10000` sin separador de miles. | `portal.html:1137`, `732`; usar `slice(0,5)` e `Intl.NumberFormat('es-AR')`. |
| M5 | **Errores silenciosos:** si `turnos_de_cliente` falla, el `.catch` está vacío (`portal.html:1166`) y la sección queda en blanco, sin estado de error ni reintento. | Mostrar un aviso con botón «Reintentar». |
| M6 | **«Volver a mi Salón» apunta a `index.html`** (`portal.html:285`), que es la app de la dueña, con otra clave de sesión. Para una clienta es un callejón: la manda a un login que no es el suyo. | Cambiar a «Volver al marketplace» o al perfil público de su salón; si se conserva, renombrar («Ir a la agenda del salón»). |
| M7 | **Sin estados de carga:** el panel se pinta recién cuando termina la RPC; mientras tanto queda la vista de OTP con el botón en «Verificando…». Si falla, se muestra el panel con saldo `0` y un alerta: parece que perdió los puntos. | Skeleton en la tarjeta de saldo y en las listas; no mostrar `0` hasta tener respuesta. |
| M8 | **Targets táctiles chicos:** «Ver salones» mide 72×20 px y el pill «Volver a mi Salón» 154×38 (el mínimo recomendado es 44×44; WCAG 2.5.8 pide 24×24). | `portal.html:69,285`; agrandar a 44 px de alto o agrupar en un menú. |
| M9 | **Microcopia:** «Canjear Puntos» en mayúsculas de título; «desde el app del salón» (¿cuál app?); «Aún no tenés turnos completados» bajo el título «Mis Turnos» (el RPC solo trae completados, pero el título promete todos). | Revisar jerarquía y nombres: «Mis turnos» debería incluir próximos e historial, o llamarse «Turnos para reseñar». |
| M10 | **`<label>` usados como títulos:** en el modal, `<label>Servicio</label>` no está asociado a ningún control (no hay `for` ni input). Un lector de pantalla anuncia labels huérfanos. | Usar `<h4>`/`<dt>` o asociarlos. |
| M11 | **Código muerto / clases inexistentes:** `.estrella.seleccionada` nunca se aplica; `.btn-sm` no existe pero se usa en «Dejar Reseña» (`portal.html:742`, `1154`); `saldo-unidad` tiene una rama para `saldo === 1` que casi nunca se ve. | Limpiar o definir. |
| M12 | **Tipografía:** «MIS PUNTOS» a 9,5 px, etiquetas a 10,5 px con tracking; Inter 700 se usa (etiqueta, montos) pero **no se pidió** en Google Fonts (solo 400/500/600): el navegador sintetiza la negrita. | Subir mínimos a 11-12 px y pedir el 700 real o usar 600. |
| M13 | **`<title>` «MI PERFIL» vs `h1` «Entrá a tus Elima Points»** y el header dice «Mis puntos». Tres nombres para la misma cosa. | Unificar. |
| M14 | **Service worker:** `sw.js` cachea `portal.html` en el shell. No se registra desde el portal, pero sí desde otras páginas: una clienta que lo tenga activo puede quedar con una copia vieja si navega offline. | Revisar estrategia al publicar el fix; subir `CACHE` a v12. |
| M15 | **«Cerrar sesión» sin confirmación y al lado del saldo:** es un botón de 40 px en la zona del pulgar, junto a «Copiar mi email»; un toque accidental obliga a pedir otro OTP. | `portal.html:354`; moverlo a un menú de cuenta o pedir confirmación. |

![A 390 px la marca se parte en dos líneas y «Ver salones» queda fuera de la columna de acciones](_qa_shots/portal/lead-04-panel-390.png)

![Panel con el fix mínimo de CSS: así debería verse la pantalla que hoy queda tapada](_qa_shots/portal/lead-02-panel-preview-1280.png)

---

### 🔵 Bajos

- **`escapeHTML` + `textContent`:** en `abrirModalResena` se escapa el nombre del servicio y después se asigna con `textContent` (`portal.html:1090`), con lo que un `&` se ve como `&amp;`. Elegir una sola capa.
- **Dos `<h1>` en el DOM** (login y OTP), aunque la vista oculta está en `display:none`. No molesta hoy; prolijidad.
- **`aria-live` en listas completas:** cada rerender anuncia toda la lista; para 40 movimientos puede ser verboso. Anunciar solo el cambio.
- **Botón «Copiar email» secundario** vuelve a decir «Copiar mi email» después de copiar (`portal.html:873`), distinto de su label inicial.
- **Sin Open Graph / preview** al compartir el link (tiene `noindex`, correcto).
- **Logo de 34 px** usando `icon-192.png`: se ve borroso en pantallas retina por el escalado del contenedor.
- **`Precio` con `$10000`** y sin decimales; consistente con un peso entero, pero poco legible.
- **`#detalle-salon` etc. usan `display:flex;justify-content:space-between`** dentro de `.campo` que no es flex: el label interno queda a la izquierda y el valor a la derecha, bien; pero el `<label>` externo duplica el texto (M2).

---

## 4. Lo que está bien (no reescribir)

- **Sistema visual coherente y con identidad:** papel cálido `#FAF6F3`, tinta `#3B2F35`, blush y un dorado de marca; nada de gradientes arbitrarios ni glassmorphism. Se siente un portal de belleza, no una plantilla genérica.
- **Tipografía con jerarquía real:** Cormorant Garamond para display (saldo, títulos) + Inter para UI. El saldo grande como punto focal funciona.
- **Ancho de lectura correcto:** columna de 560 px; el portal es una utilidad y no necesita más.
- **Estados diseñados:** los vacíos no son un espacio en blanco, hay mensajes explicativos; los avisos usan `role="alert"`; el botón de reenvío tiene cuenta regresiva y se deshabilita.
- **Construcción defensiva en varias partes:** `textContent` en casi todo el render, `try/catch` en las llamadas, `cargando` como guarda, `noindex` (correcto para datos personales), `autocomplete="one-time-code"`, `maxlength` en email y comentario.
- **Sin build:** se abre con doble clic, cero dependencias de compilación. Para el tamaño del producto es una decisión válida.
- **El modal de reseña y el de detalle ya existen y están estilizados:** el problema es de comportamiento, no de diseño.
- **Backend, lo que sí está bien:** las RLS de `clientes`, `turnos`, `billeteras_puntos` y `movimientos_puntos` bloquean lecturas cruzadas (verificado: `anon` y la cuenta QA no leen filas ajenas); todas las `SECURITY DEFINER` fijan `search_path`; no hay `service_role` filtrada en repo, workflows ni Edge Functions; el tope del 30 % se calcula del lado del servidor y el canje usa `FOR UPDATE` en la billetera.

**Crítica de diseño en una línea:** la dirección visual está bien elegida; lo que falla es la ejecución del estado inicial y la accesibilidad. No hace falta rediseñar: hace falta que la página se comporte como fue diseñada.

**Rúbrica (1-10, criterio de diseño):**

| Dimensión | Nota | Comentario |
|---|---|---|
| Jerarquía | 7 | El saldo es el ancla correcta; los tres vacíos compiten por atención. |
| Composición | 7 | Columna única de 560 px, apropiada para una utilidad; algo monótona. |
| Tipografía | 8 | Serif + sans bien elegidos y bien escalados; tamaños de 9,5 px y negrita sintética restan. |
| Espaciado | 8 | Escala consistente (4/8/12/16/24/32). |
| Alineación | 8 | Alineación limpia dentro de la columna. |
| Consistencia | 7 | Botones y tarjetas coherentes; `.btn-sm` y `.hidden` inexistentes rompen el sistema. |
| Distintividad | 7 | Paleta cálida y editorial, no genérica; el dorado es marca, no capricho. |
| Usabilidad | 1 | Bloqueada en la primera pantalla; acciones que no responden. |
| Responsive | 5 | Sin overflow, pero el header se rompe a 390 px y el modal no scrollea. |
| Motion | 3 | Solo transiciones de hover; no hay sistema de movimiento. |
| Color | 6 | Paleta coherente; contraste de CTA y textos secundarios fuera de norma. |
| Pulido | 3 | Modales vacíos visibles, etiquetas duplicadas, `0` antes de cargar. |

*La nota visual (≈7) y la nota funcional (≈1) no se promedian: un portal que no se puede abrir es un 0 de producto, por más lindo que sea el sistema visual.*

---

## 5. Plan de corrección priorizado

### P0 — hoy (sin esto el portal no se puede publicar)

1. **CSS:** agregar `[hidden] { display: none !important; }`. Esto solo ya desbloquea la página y oculta el canje.
2. **Modales:** `role="dialog"`, `aria-modal`, `aria-labelledby`; `Escape` para los dos; devolver el foco; `max-height:90dvh; overflow:auto`; un solo botón «Cancelar» visible a la vez.
3. **Estrellas:** reescribir el widget con estado `calificacion`, botones accesibles y hover que no borre la selección.
4. **Fechas:** helper `fechaLocal()` y `horaCorta()`; aplicarlo en `cargarTurnos` y `cargarTurnosFuturos`.
5. **Backend (P0):** eliminar la sobrecarga legacy `crear_resena(bigint, integer, text)` y revocar `EXECUTE` de `anon`; corregir `turnos_de_cliente` (identidad y filtro por clienta + revocar de `PUBLIC/anon`); validar dueño del turno en `crear_resena` y en las dos RPC de canje. Detalle y SQL en el anexo 02.
6. **Verificación:** abrir la URL en incógnito, comprobar que se ve el login, que los modales solo aparecen al hacer clic, que `Escape` y Cancelar cierran, y que una clienta con turnos completados los ve y puede reseñar.

### P1 — esta semana

7. Contraste: CTA dorado con texto oscuro o dorado más profundo; subir `ink-faint` a un tono que llegue a 4,5:1 en 12 px.
8. Foco visible global + trampa de foco + anuncio de cambio de vista (`aria-live` en el contenedor de vistas o mover el foco al `h1`).
9. Canje: estado de saldo en variable, `await cargarPuntos()` antes de turnos futuros, listener único, tope y saldo en la UI, motivos traducidos. Quitar `saldoCanje`.
10. Header móvil: `white-space:nowrap` en la marca y reordenar acciones; targets de 44 px.
11. Login: `shouldCreateUser:false`, validación de email con `input.checkValidity()`, errores en castellano, persistir el email del OTP en `sessionStorage`.
12. Errores visibles y reintento en `cargarTurnos`; estados de carga/skeleton.
13. SRI en `supabase-js` (o self-host), CSP mínima, `X-Content-Type-Options`, `Referrer-Policy`.

### P2 — siguiente iteración

14. Consolidar estados vacíos y reordenar el panel (saldo → próximos turnos → historial → reseñas).
15. Unificar nombres (título, h1, header) y microcopia; formato de moneda y hora.
16. Limpiar etiquetas duplicadas y `<label>` huérfanos; revisar jerarquía de encabezados.
17. Pasar de `innerHTML=''` a reemplazo de hijos en las listas (evita parpadeos y facilita `aria-live`).
18. Tests de humo: abrir, login (mock), render de turno con fecha, reseña con 3 estrellas, canje con tope. Hoy no hay ninguno.

---

## 6. Pruebas ejecutadas

| # | Prueba | Resultado |
|---|---|---|
| 1 | Carga publicada vs repo | Idénticos (SHA-256) |
| 2 | Primera carga 1280×800 | Dos modales superpuestos; login inaccesible |
| 3 | Clic en Cancelar del detalle | `display` sigue `flex`; no cierra |
| 4 | Clic en el fondo / `Escape` | No cierra |
| 5 | `hidden` computado en los modales | `display:flex` con `hidden=true` |
| 6 | `hidden` computado en `#bloque-canje` / `#btn-canjear` | `block` / `flex`; visibles |
| 7 | Clic en «Canjear Puntos» sin turno | Sin efecto ni mensaje |
| 8 | Escribir 100 en el input de canje | El texto de ayuda no cambia |
| 9 | Clic en 3.ª estrella | 4 marcadas (`marcadas: 4`) |
| 10 | `mouseleave` después del clic | 0 marcadas; selección borrada |
| 11 | «Enviar reseña» tras clic + salir | «Seleccioná al menos una estrella.» |
| 12 | Fecha `2026-11-12` en `es-AR` | `11 de nov de 2026` (un día antes) |
| 13 | `Tab` desde la carga | Foco sin indicador visible; llega al email tapado por el overlay |
| 14 | Contraste CTA blanco/dorado | 2,53:1 (falla AA) |
| 15 | `anon` → `turnos_de_cliente` | 200 `[]` (ejecutable sin sesión) |
| 16 | `anon` → `obtener_mis_puntos` / `cliente_turnos_canjeables` | 401 (correcto) |
| 17 | `anon` → `crear_resena(bigint,integer,text)` | 400 `turno_no_existe` (la función se ejecuta) |
| 18 | `anon` → `crear_resena` con turno completado real (read-only) | Aborta en el `INSERT`, no en `sin_permisos`: la autorización pasa |
| 19 | Cuenta staff de un salón → `turnos_de_cliente` | Recibe el turno completado de **otro** salón, duplicado ×2 |
| 20 | Identidad de clienta → saldo/canje de turno ajeno | Lee precio/tope y llega al `FOR UPDATE` (read-only) |
| 21 | Panel autenticado con sesión QA | Renderiza saldo 0 y estados vacíos; modales siguen encima |
| 22 | Ancho 390 px | Sin overflow horizontal; header parte la marca y descolga «Ver salones» |

**No probado / límites:** no se enviaron códigos OTP ni reseñas, no se canjeó puntos y no se creó ni modificó ningún dato de producción. El backend se verificó con GET/REST y SQL en transacciones read-only, simulando rol/claims reales cuando fue necesario. No se pudo ver un panel con datos reales porque la cuenta QA no tiene ficha y hoy hay 0/8 fichas con `auth_user_id`; los defectos de puntos se verificaron por SQL y simulación de identidad. La configuración de rate limits de Supabase Auth no es visible desde el repo.

---

## 7. Evidencia

- `_qa_shots/portal/lead-01-modal-inicial-desktop.png` — primera carga, modal tapando el login.
- `_qa_shots/portal/lead-02-panel-preview-1280.png` — panel tal como se vería con el fix de CSS (vista de evaluación).
- `_qa_shots/portal/lead-04-panel-390.png` — header partido y «Ver salones» descolgado.
- `_qa_shots/portal/lead-05-foco.png` — ausencia de indicador de foco.
- `_qa_shots/portal/mob-390-*.png`, `live-*.png` — capturas del QA en vivo (estrellas, foco detrás del overlay, panel limpio).
- `_audit/02-seguridad-backend.md` — RPCs, RLS, grants y pruebas REST.
- `_audit/03-ux-live.md` — recorrido de UX, accesibilidad y responsive.
- `_audit/harness/` — copia local con sesión, `measure.html` (mediciones) y `portal-debug.html` (pruebas de estrellas/canje). No forma parte del sitio: no se publica.

---

## 8. Anexo — métricas

| Métrica | Valor |
|---|---|
| Líneas / peso del HTML | 1.356 líneas · 56.318 B (13,4 KB comprimido) |
| JS inline | ~870 líneas en una IIFE |
| CSS inline | ~256 líneas |
| Recursos externos | Google Fonts CSS (36 `@font-face`, 6 pesos × 6 subsets) + 3-6 woff2 + `supabase-js` 110.797 B (29,6 KB gzip) |
| Peso total medido | **150,8 KB · 7 requests** |
| FCP / load | ~900 ms / ~1.058 ms (TTFB 302 ms) |
| SRI / CSP | 0 / ausente |
| Dependencias de build | ninguna |
| Contraste CTA | 2,53:1 |
| Hallazgos | 6 críticos · 8 altos · 18 medios · 13 bajos (incluye el anexo backend) |

*Auditoría realizada sin modificar el sitio publicado ni los datos de producción.*

> **Sobre el conteo:** el informe consolida la página (frontend + backend). Los anexos usan su propia clasificación —el 02 reporta 1 crítico, 2 altos, 3 medios y 5 bajos; el 03 reporta 3 críticos, 5 altos, 8 medios y 6 bajos— porque agrupan distinto (por ejemplo, el 03 separa «overlay» de «foco detrás del overlay», y acá se consolidan como C1 y A1). No hay hallazgos contradictorios entre los tres documentos.
