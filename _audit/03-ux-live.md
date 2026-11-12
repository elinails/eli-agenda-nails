# 03 · Auditoría UX + accesibilidad en vivo — Portal de clientas «MI PERFIL · ELIMA HUB»

| | |
|---|---|
| **URL auditada** | https://eli-agenda-nails.vercel.app/portal.html |
| **Vista autenticada** | `http://127.0.0.1:4310/setup.html` → redirige a `portal.html` (copia **byte-idéntica**, SHA-256 `028D3BF5A249E89E513B1C10CB6CF3BE188AE64C2DF4E5918C74A1ACFA7F0AB1`, sesión QA real, saldo 0 y estados vacíos) |
| **Fecha** | 11 nov 2026 |
| **Viewports** | 1440×900 · 390×844 (device metrics reales, DPR 2) · 360×640 · 320×568 |
| **Artefactos** | Capturas en [`_qa_shots/portal/`](../_qa_shots/portal/) · JSON crudos en `_qa_shots/portal/_tools/scenario{1..6}.json` |
| **Alcance excluido** | No se enviaron OTP, reseñas ni canjes. **No se probó «Cerrar sesión»** (ver §11.3). |

---

## 1. Resumen ejecutivo

El portal **no se puede usar**: en la carga inicial aparecen dos modales superpuestos sobre el login y **ningún gesto los cierra**. El bug tiene una causa de una línea (`.modal-overlay { display: flex }` gana al `display:none` que el navegador aplica a `hidden`), pero sus efectos son sistémicos: tapa el formulario de acceso, se come el foco del teclado, mete dos botones «Cancelar» con el mismo nombre accesible y deja el resto de la pantalla inerte.

Detrás de ese bloqueo hay **cuatro defectos independientes que sobreviven al fix del overlay** y que hoy nadie ve porque la página está tapada:

1. **La reseña no se puede calificar.** El widget de estrellas agrega la clase `.estrellas` pero el CSS pinta `.estrella.seleccionada`: ninguna estrella se marca nunca en dorado. Peor: `mouseleave` borra la selección, el `for` es off-by-one (click en la 3.ª → 4 estrellas) y el valor que se envía a `crear_resena` se lee de clases DOM que el *hover* muta, así que **se puede guardar un puntaje distinto al que la clienta eligió**.
2. **El bloque de canje aparece sin turno** («Canjear Puntos» visible con saldo 0) porque la clase `.hidden` no existe en ningún CSS cargado; el botón, al clickearlo, no hace absolutamente nada.
3. **En pantallas de menos de ~700 px de alto el modal de detalle se recorta arriba y abajo y no se puede scrollear** (360×640: `y=-34`, `bottom=674`; 320×568: 78 % visible). El título y el botón primario quedan inalcanzables.
4. **Contraste insuficiente en todos los CTA primarios**: blanco sobre `#BE9E6F` = **2,53:1** (AA pide 4,5:1).

Ninguna clienta llega hoy a su saldo de puntos. El orden de corrección es: overlay → semántica/foco de diálogo → estrellas → canje → contraste → el resto.

| Severidad | Cantidad | Definición aplicada |
|---|---:|---|
| **Crítico** | 3 | Impide completar la tarea principal; no hay workaround para la clienta |
| **Alto** | 5 | Rompe una función central o excluye a un grupo de usuarias (teclado, lector de pantalla, pantalla chica) |
| **Medio** | 8 | Fricción real, pérdida de confianza o incumplimiento WCAG AA acotado |
| **Bajo** | 6 | Pulido, consistencia y performance |
| **Total** | **22** | |

---

## 2. Verificación de los tres hechos reportados por el Lead

Los tres se confirman, con medición instrumentada (CDP, `getComputedStyle` sobre la página real):

| # | Hecho | Estado | Medición |
|---|---|---|---|
| 1 | Modales visibles al cargar, sobre el login, y no cierran | **Confirmado** | `#modal-resena` y `#modal-turno-detalle`: `hidden="true"` **y** `display: flex`, `position: fixed`, `z-index: 100`. Escape, click en fondo y ambos «Cancelar» dejan `hidden=true` + `display:flex` (sin cambio visual). Captura `live-01-inicial-desktop.png`, `live-27-despues-de-cancelar.png` |
| 2 | Dos botones «Cancelar» con el mismo nombre accesible | **Confirmado** | Nombres accesibles visibles simultáneos: `Cancelar` ×2 (`btn-cancelar-resena`, `btn-cancelar-detalle`) |
| 3 | Etiquetas duplicadas en el detalle | **Confirmado** | Texto renderizado: `Salon Salón · Servicio Servicio · Fecha y hora Fecha Hora · Precio Precio` |

Causa raíz exacta (única regla que matchea `modal-overlay` en `portal.html:216`):

```css
.modal-overlay { position: fixed; inset: 0; background: rgba(59,47,53,.5);
                 display: flex; align-items: center; justify-content: center; z-index: 100; }
```

No existe `.modal-overlay[hidden]`. Sí existen `.vista[hidden]` (`:82`) y `.alerta[hidden]` (`:120`): el patrón se aplicó a dos selectores y se olvidó el tercero. Reglas con `hidden` presentes en el documento: `['.vista[hidden]', '.alerta[hidden]', '.modal-overlay']`.

---

## 3. CRÍTICO

### C-01 · Los modales «Dejá tu reseña» y «Detalles del Turno» tapan el portal al cargar y no se pueden cerrar

**Evidencia**
1. Abrir `portal.html` en frío (1440×900 y 390×844). Sin tocar nada, aparecen dos overlays superpuestos sobre el login.
2. Estructura medida: `hiddenAttr: true`, `display: "flex"`, `visibility: "visible"` en ambos; los dos con `z-index:100`, el de detalle (420×709, `y=96`) cubre por completo al de reseña (420×378, `y=261`) → `detailCoversReview: true`.
3. `Escape` → `[{hidden:true, display:flex}, {hidden:true, display:flex}]` (nada cambia).
4. Click en el fondo (30,700) → idem.
5. Click en `#btn-cancelar-detalle` → idem. Click en `#btn-cancelar-resena` (JS) → idem.
6. Snapshot de accesibilidad antes y después de Escape/Cancelar: **idéntico** (los dos `heading [level=3]` siguen ahí).
7. Cerrando por el camino de producción (`cerrarModalDetalleTurno()`, invocado desde el `abrirModalDetalleTurno()` real con un turno de prueba): lectura inmediata → `display: "flex"` (el `hidden` quedó puesto y el CSS lo ignora, igual que por la UI).
8. Mismo comportamiento con **sesión iniciada** (`mob-390-authed.png`): el panel queda debajo, tapado.

Capturas: `live-01-inicial-desktop.png`, `cli-390-public.png`, `mob-390-public.png`, `mob-390-authed.png`, `live-27-despues-de-cancelar.png`.

**Impacto en la clienta**
Página inutilizable, en desktop y en celular, con y sin sesión. No puede loguearse, no ve su saldo, no puede reservar ni canjear. Los handlers de cierre **sí corren** (setean `hidden=true`): la falla es 100 % de CSS, así que el bug es silencioso en QA manual («toqué Cancelar y no pasó nada») y trivial de arreglar.

**Recomendación**
Fix de sistema (cubre futuros modales):

```css
/* portal.html — después de .modal-overlay */
.modal-overlay[hidden] { display: none; }
/* y, como red de seguridad para todo el documento: */
[hidden] { display: none !important; }
```

Y que el cierre sea explícito y observable (los handlers ya existen, solo hay que llamar al helper de C-02):

```js
function cerrarModal(el) {
  el.hidden = true;
  el.setAttribute('aria-hidden', 'true');
  document.body.style.overflow = '';
  document.querySelector('main').inert = false;
  if (ultimoFoco) { ultimoFoco.focus(); ultimoFoco = null; }
}
// Escape debe cerrar LOS DOS modales, no solo el de detalle
```
**Criterio de aceptación:** con la página recién cargada, `document.querySelectorAll('.modal-overlay:not([hidden])').length === 0` y el orden de tabulación nunca entra en un modal cerrado.

---

### C-02 · Todo el contenido queda detrás del overlay: el puntero no llega y el foco de teclado es invisible

**Evidencia**
1. `elementFromPoint()` en el centro del input de email (487,272 · 466×50) devuelve `div.campo` **dentro del modal**: `blocked: true`. El click físico lo come el overlay.
2. `Tab` ×4 desde la carga: el foco llega a `#email` (paso 4 de la secuencia `marca → Volver a mi Salón → Ver salones → email`), es decir **el campo es enfocable aunque esté tapado**.
3. Escribiendo con teclado real sobre ese foco: `#email.value === "abc@x"` mientras `topElAtInput === "div.campo"` (el campo sigue tapado). **La clienta escribe a ciegas.**
4. El anillo de foco del input existe (`box-shadow: 0 0 0 2.1px rgba(190,158,111,.114)`, borde `#CBB1AF`) pero queda debajo del overlay y de la tarjeta del modal: en `live-26-foco-email-oculto-1440.png` no se percibe.
5. En la vista autenticada, **los 6 primeros stops de Tab caen en elementos tapados** (`visibleAtItsCenter: false` en los 6: `marca`, `Volver a mi Salón`, `Ver salones`, `Copiar mi email`, `Cerrar sesión`, `Copiar email`). `Shift+Tab` desde el `body` entra directo al modal (`Canjear Puntos → Cancelar → input de puntos → Enviar reseña → Cancelar`), también tapado por el otro modal.

Capturas: `live-20-foco-en-email-tras-overlay.png`, `live-21-foco-en-textarea-oculto.png`, `live-26-foco-email-oculto-1440.png`.

**Impacto en la clienta**
Doble exclusión: con mouse no se puede interactuar con nada; con teclado se interactúa **con lo que no se ve** (escribir el email sin ver el cursor ni el texto, tabular a botones invisibles). Para una clienta que usa lector de pantalla, el orden de lectura mezcla login, reseña y detalle sin ninguna señal de qué está activo.

**Recomendación**
Adoptar el patrón de diálogo modal de verdad (C-02 + A-03 juntos):

```html
<div id="modal-turno-detalle" class="modal-overlay" hidden>
  <div class="modal modal-detalle" role="dialog" aria-modal="true"
       aria-labelledby="detalle-titulo" aria-describedby="detalle-desc">
    <h2 id="detalle-titulo">Detalles del turno</h2>
```

```js
function abrirModal(el, disparador) {
  ultimoFoco = disparador || document.activeElement;
  el.hidden = false;
  document.querySelector('main').inert = true;   // fondo fuera del árbol de foco
  document.body.style.overflow = 'hidden';
  (el.querySelector('[data-autofocus]') || el.querySelector('button,input,textarea')).focus();
}
// trampa de foco: Tab/Shift+Tab ciclan dentro de .modal; Escape cierra; click en el overlay cierra.
```
**Criterio de aceptación:** con un modal abierto, `Tab` no sale nunca de `.modal`, `Escape` lo cierra y el foco vuelve al botón que lo abrió.

---

### C-03 · El widget de estrellas no refleja ni registra la calificación (y puede guardar un valor distinto al elegido)

**Evidencia** — el código de `renderizarEstrellas()` (`portal.html:1044-1081`) ejecutado sobre el contenedor real del portal (función extraída **verbatim** y corrida en el DOM de la página; ver §11.2), con mouse real:

| Acción | Resultado medido |
|---|---|
| Estado inicial (5 spans `☆`) | color `rgb(156,139,144)` en las 5, `class="estrella"` |
| Click en la **3.ª** estrella | **4** estrellas con `★` y `class="estrellas"` (off-by-one: `for (j = 0; j <= this.dataset.valor; j++)` con `"3"` → j=0..3) |
| Color de las 4 «seleccionadas» | **`rgb(156,139,144)`** — el mismo gris que las vacías: el CSS pinta `.estrella.seleccionada` y el JS agrega `.estrellas` |
| Mover el mouse **fuera** del bloque | **las 5 vuelven a `☆`**, `count = 0` (`mouseleave` borra la clase de todas y luego pregunta `classList.contains('estrellas')`, ya removida) |
| Click en la 5.ª y después en la 2.ª | quedan **3** marcadas (el `hover` pisó el estado antes del click) |
| `#btn-enviar-resena` (sin turno seleccionado) | `alerta hidden:true` → **no pasa nada** (`if (!turnoSeleccionado) return;`) |
| Teclado | los 5 spans tienen `tabIndex = -1`, sin `role`, sin `aria-label`, contenedor sin `role` → **imposible calificar sin mouse** |

Capturas: `live-22-estrellas-click-3.png` (se ven 4 ★ **grises**), `live-23-estrellas-tras-sacar-mouse.png` (todo borrado), `live-24-estrellas-5-luego-2.png`, `live-25-estrellas-hover-4.png`.

**Corroboración con el camino real del portal** (segunda medición, sin función copiada): usando el `abrirModalResena()` original sobre un turno de prueba (`_audit/harness/portal-debug.html?qa=stars`), con mouse real:

| Acción (handler de producción) | Resultado |
|---|---|
| Click en la **4.ª** estrella | **5** estrellas `★`, las 5 con `class="estrellas"`, las 5 en `rgb(156,139,144)` (`live-30-estrellas-flujo-real-click-4.png`) |
| «Enviar reseña» con 0 marcadas | alerta «Seleccioná al menos una estrella.» (funciona **solo** si hay turno seleccionado) |
| `mouseleave` sobre el bloque | 0 marcadas, todas `☆` |

Los dos caminos coinciden: el bug no es del arnés, es del componente.

**Impacto en la clienta**
La reseña es el corazón del programa de puntos y hoy: (a) no hay feedback visual de lo elegido; (b) cualquier movimiento del mouse hacia «Enviar reseña» borra la selección y el envío responde «Seleccioná al menos una estrella» sin motivo aparente; (c) si logra enviar, `p_estrellas` sale de contar clases DOM mutadas por el hover → **puede guardarse 5 estrellas cuando eligió 3**, y eso es dato de negocio (reputación del salón). Además queda inaccesible por teclado y lector de pantalla (WCAG 4.1.2, 2.1.1).

**Recomendación**
Separar *estado* de *preview*, usar un `radiogroup` de botones y leer el valor del estado, no del DOM:

```css
.estrella { width: 44px; height: 44px; }          /* target real, hoy 23×43 */
.estrella.seleccionada { color: var(--gold-ink); } /* #8C6B3A sobre blanco = 4,8:1 */
```

```js
function renderizarEstrellas(contenedor, valorInicial) {
  contenedor.innerHTML = '';
  contenedor.setAttribute('role', 'radiogroup');
  contenedor.setAttribute('aria-label', 'Calificación de 1 a 5 estrellas');
  var valor = valorInicial || 0;
  function pintar() {
    Array.prototype.forEach.call(contenedor.children, function (b, i) {
      var on = i < valor;
      b.classList.toggle('seleccionada', on);
      b.textContent = on ? '★' : '☆';
      b.setAttribute('aria-checked', String(i + 1 === valor));
    });
    contenedor.dataset.valor = String(valor);
  }
  for (var i = 1; i <= 5; i++) {
    var b = document.createElement('button');
    b.type = 'button';
    b.className = 'estrella';
    b.setAttribute('role', 'radio');
    b.setAttribute('aria-label', i + (i === 1 ? ' estrella' : ' estrellas'));
    b.dataset.valor = i;
    b.addEventListener('click', function () { valor = Number(this.dataset.valor); pintar(); });
    b.addEventListener('mouseenter', function () { this.parentNode.classList.add('preview-' + this.dataset.valor); });
    b.addEventListener('mouseleave', function () { this.parentNode.className = 'estrellas-modal'; });
    contenedor.appendChild(b);
  }
  pintar();
}
// al enviar:  var estrellasSeleccionadas = Number($('estrellas-modal').dataset.valor) || 0;
```
El `mouseenter`/`mouseleave` puede seguir existiendo como *preview* visual, pero **jamás** debe tocar la clase que representa el valor ni el texto que se cuenta al enviar.

---

## 4. ALTO

### A-01 · El bloque de canje y «Canjear Puntos» se muestran sin turno, y el botón no hace nada

**Evidencia**
- `#bloque-canje` tiene `class="hidden"` en el HTML (`:461`) y `#btn-canjear` también (`:474`), pero **no existe ninguna regla `.hidden`** en los CSS cargados (`hasHiddenClassRule: false`; reglas con `hidden`: solo `.vista[hidden]`, `.alerta[hidden]`, `.modal-overlay`). Resultado: `display: flex`, visibles desde el primer render.
- El modal muestra «Saldo disponible: 0 pts», «Usar Elima Points (máx. 30 % del servicio)» y un spinbutton vacío **sin ningún turno**: datos de contexto inexistentes.
- Click en «Canjear Puntos» sin turno → `window.turnoDetalleActual` es `undefined` → `if (!turnoId) return;` → **nada**: sin mensaje, sin estado, sin error (`alerta-canje` sigue `hidden`).
- `#puntos-canjear-input` no tiene nombre accesible: el snapshot devuelve `spinbutton "0"` (el `0` es el valor, no el nombre) porque su `<label>` no tiene `for`.

Capturas: `live-01-inicial-desktop.png`, `mob-390-public.png` (bloque completo con saldo 0).

**Impacto**
Una clienta nueva ve una pantalla que le ofrece «canjear» cuando no tiene turnos, con saldo 0 y sin explicación; si toca, no pasa nada. Es la clase de detalle que hace que la gente cierre la app.

**Recomendación**

```css
.hidden, [hidden] { display: none !important; }
```
```html
<div class="canje-bloque" id="bloque-canje" hidden>
  ...
  <label for="puntos-canjear-input">Usar Elima Points (máx. 30 % del servicio)</label>
  <input id="puntos-canjear-input" aria-describedby="ayuda-canje" ...>
  ...
  <button type="button" id="btn-canjear" class="btn btn-canjear" hidden>Canjear Puntos</button>
</div>
```
Y en JS: `bloqueCanje.hidden = false` **solo** dentro de `abrirModalDetalleTurno`, como ya se hace (el problema es que el HTML de origen ya lo muestra). El botón debe estar `disabled` con motivo visible si no hay turno, nunca `display:flex` sin contexto.

---

### A-02 · El modal de detalle se recorta y no se puede scrollear en pantallas de ≤ ~700 px de alto

**Evidencia** (device metrics reales, `align-items:center` + `overflow: visible`)

| Viewport | Card `y` / alto / `bottom` | Recorte | % visible | «Canjear Puntos» alcanzable |
|---|---|---|---|---|
| 390×844 | 68 / 709 / 776 | no | 100 % | sí |
| **360×640** | **−34** / 709 / **674** | **arriba 34 px y abajo 34 px** | 90 % | **no** |
| **320×568** | **−80** / 729 / **649** | **arriba 80 px y abajo 81 px** | **78 %** | **no** |

`getComputedStyle(overlay).overflowY === "visible"` y `getComputedStyle(card).overflowY === "visible"`: no hay contenedor scrollable. Como el overlay es `position:fixed`, el scroll del `body` no mueve el modal → **la parte recortada es inalcanzable**.

Captura: `mob-360x640-public.png` (se ve el título «Detalles del Turno» cortado a la mitad y el botón dorado cortado por abajo), `mob-320x568-public.png`.

**Impacto**
En un Android de 640 px de alto (muy común) o un iPhone SE, la clienta no puede leer los datos del turno ni tocar «Canjear Puntos». El modal «crece con el contenido» y nada lo contiene.

**Recomendación**

```css
.modal-overlay { padding: 16px; overflow-y: auto; align-items: center; }
.modal, .modal-detalle { max-height: calc(100dvh - 32px); overflow-y: auto; }
@media (max-height: 640px) { .modal-overlay { align-items: flex-start; } }
```
Con eso el modal scrollea por dentro y los botones quedan siempre alcanzables. Verificar también con el teclado abierto en mobile (~300 px de viewport visible).

---

### A-03 · Sin semántica de diálogo, fondo no aislado, dos «Cancelar» iguales y Escape asimétrico

**Evidencia**
- `#modal-resena` y `#modal-turno-detalle`: `role=null`, `aria-modal=null`, `aria-labelledby=null`; el `.modal` interno tampoco tiene `role`.
- El árbol de accesibilidad en la carga expone **login + reseña + detalle en una sola lista plana** (snapshot: `heading level=1 Entrá a tus Elima Points` seguido de `heading level=3 Dejá tu reseña`, `button Cancelar`, `button Enviar reseña`, `heading level=3 Detalles del Turno`, `button Cancelar`, `button Canjear Puntos`). Un lector de pantalla no tiene forma de saber que hay un diálogo modal ni cuál es el activo.
- El único `Escape` implementado (`portal.html:1312-1318`) cierra **solo** el modal de detalle; el de reseña no tiene handler de teclado. Y click en fondo solo cierra si `e.target` es el overlay, que hoy está siempre cubierto por el otro modal.
- Nombres accesibles duplicados: `Cancelar` ×2 visibles a la vez; en la vista autenticada ambos comparten nombre y **el de reseña es inalcanzable con mouse** porque el de detalle lo cubre.

**Impacto**
Para lectores de pantalla (NVDA/VoiceOver) el portal es un muro de texto sin jerarquía de diálogo; para teclado, «Cancelar» es ambiguo y Escape funciona a medias. Incumple WCAG 4.1.2 y 2.1.2 (sin trampa de foco: el foco sí escapa del modal).

**Recomendación** — la de C-02 (role/aria-modal/aria-labelledby + `inert` + trampa de foco) y, además:
- Nombrar los botones por contexto: «Cerrar reseña» y «Cerrar detalle» (o «Cancelar reseña» / «Cancelar»).
- Escape global que cierre **el modal que está arriba** (`document.querySelectorAll('.modal-overlay:not([hidden])')` → último).
- En el HTML, `h3` → `h2` dentro de los modales (ver M-01).

---

### A-04 · Los CTA primarios no pasan AA: blanco sobre `#BE9E6F` = 2,53:1

**Evidencia** — `getComputedStyle` sobre la página real + cálculo WCAG:

| Elemento | Colores | Ratio | AA (4,5:1) |
|---|---|---:|---|
| `.btn` «Enviarme el código» (login) | `#FFFFFF` sobre `#BE9E6F` | **2,53** | ✗ |
| `.btn` «Ingresar» (paso OTP) | idem | **2,53** | ✗ |
| `.btn` «Enviar reseña» | idem | **2,53** | ✗ |
| `#btn-canjear` «Canjear Puntos» | idem | **2,53** | ✗ |

Los cuatro botones primarios del portal fallan por igual (texto 15 px / 600 → umbral 4,5:1). En la captura `mob-390-login-limpio.png` el texto blanco sobre el dorado claro se lee «lavado».

**Impacto**
Baja legibilidad del punto de conversión más importante (pedir el código) y de todas las acciones, para cualquiera con poca visión o en exteriores. Es un incumplimiento WCAG 1.4.3 directo.

**Recomendación** (verificadas, sin salir de la paleta):

```css
/* Opción A — mantener el dorado de marca y pasar el texto a tinta: 5,05:1 */
.btn { background: var(--gold); color: var(--ink); border-color: var(--gold); }
/* Opción B — oscurecer el fondo: #8C6B3A con blanco = 4,91:1 */
.btn--primary-strong { background: var(--gold-ink); border-color: var(--gold-ink); color: #fff; }
```
Recomiendo **A**: conserva el dorado claro actual y el contraste sube a 5,05:1; además el texto en tinta se ve más premium que el blanco lavado.

---

### A-05 · Modal de detalle: etiquetas duplicadas, campos vacíos y `<label>` sin control

**Evidencia**
- Texto renderizado: `Salon Salón Servicio Servicio Fecha y hora Fecha Hora Precio Precio` — cada dato aparece dos veces porque se apilan un `<label>` externo (`Salon`, `Servicio`, `Fecha y hora`, `Precio`) y un `<span class="detalle-label">` interno (`Salón`, `Servicio`, `Fecha`, `Hora`, `Precio`).
- `Salon` sin tilde (el span interno sí dice `Salón`): inconsistencia de microcopy en el mismo bloque.
- Todos los `<label>` del modal tienen `forAttr: null, control: null`: son etiquetas huérfanas (markup inválido, y en lectores de pantalla se leen como texto suelto).
- Sin turno, los `.detalle-valor` están vacíos y las 5 filas quedan como huecos en blanco de ~43 px: el modal se ve roto, no vacío (`mob-390-public.png`).
- El modal de reseña repite el patrón: `<label>Servicio</label>` y `<label>Calificación (1-5 estrellas)</label>` sin control asociado.

**Impacto**
El detalle del turno es donde la clienta confirma salón, servicio, fecha y precio antes de canjear: leer «Salón» dos veces y un hueco vacío en lugar del nombre del salón genera desconfianza justo en el momento del canje. Además el bloque no tiene nombre accesible por campo.

**Recomendación**

```html
<h2 id="detalle-titulo">Detalles del turno</h2>
<dl class="detalle">
  <div class="detalle-item"><dt>Salón</dt><dd id="detalle-salon">—</dd></div>
  <div class="detalle-item"><dt>Servicio</dt><dd id="detalle-servicio">—</dd></div>
  <div class="detalle-item"><dt>Fecha y hora</dt><dd id="detalle-fecha">—</dd></div>
  <div class="detalle-item"><dt>Precio</dt><dd id="detalle-precio">—</dd></div>
</dl>
```
Un solo rótulo por dato, `dl/dt/dd` (semántica de pares), `—` cuando no hay valor y, si el turno no existe, **no abrir el modal**. Si se mantiene el layout actual, al menos borrar los `<label>` externos y corregir «Salon» → «Salón».

---

## 5. MEDIO

### M-01 · Jerarquía de headings: h1→h3 en los modales y panel sin h1
- **Evidencia:** login `h1 "Entrá a tus Elima Points"` → modales `h3` (salta h2). En el panel **no hay ningún h1 visible**: los dos `h1` del documento pertenecen a vistas ocultas; el panel arranca en `h2` (6 × h2: Mis Turnos, «Aún no tenés turnos completados», Turnos Futuros, «No tenés turnos futuros», Movimientos, «Todavía no tenés puntos»).
- **Impacto:** navegación por encabezados (lector de pantalla) sin título de página en el panel; los mensajes de estado vacío compiten al mismo nivel que las secciones reales.
- **Recomendación:** un `h1` por vista (en el panel: `<h1 class="sr-solo">Mi perfil · ELIMA HUB</h1>` o promover «Tus Elima Points»); modales en `h2`; los títulos de estado vacío a `<p class="vacio-titulo">` o `h3`.

### M-02 · Validación del login sin estado accesible ni foco
- **Evidencia:** con email vacío, `abc`, `a@b` el mensaje es correcto («Escribí un email válido.»), el `role="alert"` se anuncia y **no se hace ninguna request** (0 requests a `/auth/v1/otp`, verificado en la traza de red). Pero: `aria-invalid: null`, `aria-describedby: null`, el borde del input **no cambia de color**, y el foco queda donde estaba (en «Enviarme el código», mientras el mensaje aparece arriba).
- **Impacto:** quien usa lector de pantalla escucha el error, pero al volver al campo no hay señal de que ese campo es el que falló; visualmente el formulario «no reacciona».
- **Recomendación:** `aria-describedby="login-alerta"` en el input, setear `aria-invalid="true"/"false"` en JS, `.campo input[aria-invalid="true"]{border-color:var(--danger)}` y `$('email').focus()` al fallar.

### M-03 · «Enviar reseña» sin selección: sin feedback cuando no hay turno
- **Evidencia:** click sobre `#btn-enviar-resena` con `turnoSeleccionado === null` → `alerta-resena` sigue `hidden` y vacía. Con turno (probado con el handler real) sí aparece «Seleccioná al menos una estrella.» (`live-31-resena-sin-seleccion.png`). Es decir: el botón es mudo justo en el estado en que la clienta lo ve al cargar, y explica cuando ya es tarde (después de que C-03 le borró la selección).
- **Impacto:** botón que parece muerto.
- **Recomendación:** validar siempre y mostrar el error aun sin turno (o deshabilitar el botón con `aria-disabled` y texto de ayuda hasta que haya puntaje).

### M-04 · Los textos de ayuda del canje no se actualizan (y al borrar quedan datos viejos)
- **Evidencia (estado real de carga):** con el modal visible, escribir `50` en `#puntos-canjear-input` deja `ayuda-canje = ""` y `saldo-canje = "Saldo disponible: 0 pts"` sin cambios: el listener de `input` se registra **solo** dentro de `abrirModalDetalleTurno()` (`:825`), que nunca corre en la carga.
- **Evidencia (camino real con turno):** abriendo el modal con el handler de producción, el listener se registra **recién después** del `await cliente.rpc('cliente_saldo_puntos_turno')` (`:808`). Un `input` disparado apenas se abre el modal **se pierde** (ayuda sin cambios); disparado después, sí funciona: `Descuento: $1500 · Total a pagar: $8500`.
- **Evidencia (borrado a 0):** escribir `1500` y después `0` deja el texto en **`Descuento: $1500 · Total a pagar: $8500`** — la rama de reset (`:832-836`) depende de `saldoCantidad`, que solo se asigna si la RPC de saldo tuvo éxito, y además escribe en `saldoCanje` cuando quería escribir en `ayudaCanje`. Resultado: descuento fantasma en pantalla.
- **Impacto:** el bloque que más espacio ocupa del modal es el que menos explica; y al corregir la cantidad la clienta ve un total que ya no corresponde.
- **Recomendación:** subscribir el listener al arrancar (no dentro de `abrirModalDetalleTurno`), guardar el estado (`tope`, `precio`, `saldo`) en variables del módulo, recalcular en cada `input` sin depender de la RPC, y resetear al texto base cuando el valor sea 0. `aria-describedby="ayuda-canje"` en el input para que el cambio se anuncie.

### M-05 · El segundo botón «Copiar email» vuelve a decir «Copiar mi email»
- **Evidencia:** estado inicial `Copiar mi email` / `Copiar email`; click en `#copiar-btn-2` → `¡Copiado!` + clase `copiado`; a los 2,2 s → **`Copiar mi email`** (label incorrecto, idéntico al del botón de la tarjeta). Causa: `conectarCopiar()` hardcodea `var original = 'Copiar mi email'` para ambos botones (`:873`).
- **Impacto:** la clienta ve dos botones con el mismo texto y distinta ubicación haciendo lo mismo; parece un error de la app.
- **Recomendación:** `function conectarCopiar(id, etiquetaOriginal)` y llamar `conectarCopiar('copiar-btn','Copiar mi email')` / `conectarCopiar('copiar-btn-2','Copiar email')`. Ideal: un solo botón (el email ya está visible en «Tu cuenta»).

### M-06 · Targets táctiles por debajo del mínimo (WCAG 2.5.8 → 24×24)
| Elemento | Tamaño medido | 24×24 | 44×44 |
|---|---|---|---|
| «Ver salones» (header) | **72×20** | ✗ | ✗ |
| Marca / logo (header) | 149×**34** | ✓ | ✗ |
| «← Volver a mi Salón» | 154×**38** | ✓ | ✗ |
| «Copiar mi email» / «Cerrar sesión» / «Copiar email» | 130×**40** | ✓ | ✗ |
| Estrella del widget | **23**×43 | ✗ | ✗ |

- **Impacto:** el link del header y las estrellas son difíciles de acertar con el pulgar; los 23 px de ancho de las estrellas obligan a puntería fina justo en el gesto más emocional del producto.
- **Recomendación:** `.enlace-suave{display:inline-flex;align-items:center;min-height:44px;padding:0 4px}`, `.boton-mini{min-height:44px}`, `.estrella{width:44px;height:44px;display:grid;place-items:center}`.

### M-07 · Contraste de textos secundarios y anillo de foco
| Token / uso | Fondo real | Ratio | AA | Nota |
|---|---|---:|---|---|
| `.pie` `#9C8B90` 12,5 px | `#FAF6F3` | **3,00** | ✗ | texto normativo del programa de puntos |
| `.marca-sub` `#9C8B90` 9,5 px | `#FAF6F3` / `#F4E7EC` | **3,00** / **2,69** | ✗ | peor caso sobre el degradé |
| `.puntos-etiqueta` `#8C6B3A` 10,5 px | extremo `#F4E7EC` del degradé | **4,09** | ✗ | medido sobre el compuesto del degradé |
| `#panel-alerta` (aviso del panel) `#B4453C` | `danger-soft` sobre **papel** `#F3E4E1` | **4,41** | ✗ (por 0,09) | los avisos dentro de tarjetas blancas sí pasan (4,72) |
| Borde de `.btn-secundario` `#EADFDB` | `#FFFFFF` | **1,31** | ✗ (UI 3:1) | único indicio de forma del botón |
| Anillo de foco de inputs (`gold-soft` 16 %) | `#FAF6F3` | **1,13** | ✗ (UI 3:1) | y el borde al enfocar `#BE9E6F` = **2,35** |

- **Impacto:** los textos chicos son los que explican las reglas del programa («1 Elima Point = $1 · se acreditan al marcar el turno como realizado») y justamente no se leen.
- **Recomendación:** `--ink-faint: #786769` (4,96:1) para texto y dejar `#9C8B90` solo para decoración; etiqueta dorada `#7A5B2E` (5,20:1 sobre el degradé); `--danger: #A63C33` (5,58:1 sobre `#F7EFEC`); foco con `outline: 2px solid var(--ink); outline-offset: 2px` (11,89:1) en lugar del `box-shadow` translúcido.

### M-08 · «Volver a mi Salón» no le habla a una clienta
- **Evidencia:** el link apunta a `index.html`, cuyo `<title>` es **«ELIMA HUB - Agenda de Turnos»** y cuyo `h1` es «Agenda» — es la agenda del salón. El header tiene además «Ver salones» → `marketplace.html`.
- **Impacto:** a la clienta se le ofrece «volver» a un lugar al que nunca entró, y el destino es la herramienta interna del salón. Rompe el modelo mental («Mi perfil / mis puntos») y suma un segundo link de salida en un header de 2 acciones.
- **Recomendación:** reemplazar por «Volver al marketplace» (o quitarlo si «Ver salones» ya cubre la salida) y dejar «Cerrar sesión» como única acción de salida en el panel. Si `index.html` debe quedar accesible, rotularlo «Soy del salón» y no «mi Salón».

---

## 6. BAJO

### B-01 · Header desalineado en 390 px
- **Evidencia:** a 390 px, `.cabecera-fila` mide 71 px con `flex-wrap`; el botón «← Volver a mi Salón» queda en `y=0` (pegado al borde superior, sin padding) y «Ver salones» cae a una segunda fila (`y=50`), debajo de la marca, que se parte en dos líneas («ELIMA / HUB»). Ver `mob-390-login-limpio.png`.
- **Recomendación:** a ≤420 px ocultar el texto de marca (`marca-texto`) o acortar el pill a «← Volver», y `row height` 56 con `align-items:center` para que nada quede a `y=0`.

### B-02 · Tres estados vacíos apilados y saldo con triple etiqueta
- **Evidencia:** página autenticada de **1377 px** de alto en 1440 (1465 px en 390) para mostrar «Mis Turnos» (171), «Turnos Futuros» (217) y «Movimientos» (192) todos vacíos. En la tarjeta: «TUS ELIMA POINTS» + «Tu saldo disponible» + «0» + «Elima Points · 1 punto = $1».
- **Impacto:** sensación de app vacía; tres cajas punteadas iguales seguidas es el patrón visual de «no hay nada acá».
- **Recomendación:** un único estado vacío compuesto («Todavía no tenés puntos. Cuando tu salón marque un turno como realizado vas a ver acá tus puntos y podrás dejar tu reseña»), Turnos Futuros plegado por defecto, y una sola etiqueta para el saldo.

### B-03 · Peso y performance percibida: 7 requests / 150,8 KB, dos dependencias externas bloqueantes
- **Medido:** `portal.html` 13,4 KB comprimidos (56,3 KB decodificados) · `supabase.js` (jsDelivr) **29,6 KB** · Inter woff2 **47,7 KB** · Cormorant woff2 **36,9 KB** · CSS de Google Fonts 1,3 KB · `icon-192.png` **20,3 KB** para un logo de 34 px. FCP **900 ms**, DOMContentLoaded 893 ms, load 1058 ms, TTFB 302 ms.
- **Riesgos:** `supabase-js` se carga **sin `integrity`** y sin fallback; si jsDelivr falla, el portal solo muestra «No se pudo cargar el sistema de acceso» (`iniciar()`, `:886`) y no hay reintento. El CSS de fonts es render-blocking sin `preload` de los woff2.
- **Recomendación:** vendorizar o fijar `integrity` + `crossorigin` y un `onerror` con fallback; `rel=preload` de los dos woff2 (o self-host de un subset); reemplazar `icon-192.png` por un SVG/PNG de 34-68 px para el logo del header.

### B-04 · «¡Copiado!» dura 2,2 s y no se anuncia
- **Evidencia:** el texto del botón cambia a `¡Copiado!` y vuelve a los 2200 ms; no hay `aria-live` ni `role=status`, así que el cambio solo se percibe si el foco sigue en el botón.
- **Recomendación:** `role="status"` en un `span.sr-solo` junto al botón («Email copiado») y 4 s de duración.

### B-05 · Scroll de fondo sin bloquear y `aria-live` ruidoso
- **Evidencia:** con el modal abierto el `body` sigue scrolleando (no hay `overflow:hidden`); `#mis-turnos`, `#turnos-futuros` y `#historial` tienen `aria-live="polite"` y se reconstruyen con `innerHTML/textContent=''` en cada refresh → lectores de pantalla releen listas enteras.
- **Recomendación:** bloquear el scroll del `body` mientras haya modal (`C-02`) y usar `aria-live="polite"` solo en un contenedor de estado («Se actualizaron tus puntos»), no en las listas.

### B-06 · «Cerrar sesión» sin confirmación, junto al saldo
- **Evidencia:** `#salir-btn` es un `.boton-mini` de 118×40 dentro de la tarjeta de puntos, al lado de «Copiar mi email»; no pide confirmación y cierra la sesión al primer toque.
- **Impacto:** toque accidental frecuente en mobile (zona del pulgar, al lado de un botón de uso habitual) y la clienta tiene que pedir un OTP nuevo.
- **Recomendación:** moverlo a un menú/footer de cuenta, o pedir confirmación («¿Cerrar sesión?») y usar `aria-describedby` para el aviso de sesión cerrada.

---

## 7. Responsive

| Chequeo | 390×844 | 360×640 | 320×568 | 1440×900 |
|---|---|---|---|---|
| Overflow horizontal | **no** (`scrollW 390 = clientW 390`, 0 offenders) | no | no | no |
| Modal de detalle completo | sí (709 px) | **no** (−34/+34) | **no** (−80/+81) | sí |
| «Canjear Puntos» alcanzable | sí | **no** | **no** | sí |
| Header sin solapamientos | **no** (pill a `y=0`, 2 filas) | idem | idem | sí |
| Página del panel (alto total) | 1465 px | — | — | 1377 px |

> **Nota de método:** las capturas `cli-390-*.png` se hicieron con `chrome --headless=new --window-size=390,2400`, pero ese flag **no** produjo un layout viewport de 390 px (el contenido se ve cortado a la derecha porque se rasterizó desde un layout más ancho). **No hay overflow horizontal real a 390 px**: lo verifiqué con device metrics (`Emulation.setDeviceMetricsOverride`, `mobile:true`, DPR 2) y con `scrollWidth === clientWidth === 390`. Las capturas válidas para mobile son `mob-390-*`, `mob-360x640-*`, `mob-320x568-*`.

---

## 8. Lo que ya funciona bien (no romper)

- **Copy del flujo OTP**: «Te mandamos un código de 6 a 10 dígitos al email que le diste a tu salón. Sin contraseñas.» + «Revisá spam si no llega» + «Usar otro email» + cuenta regresiva de reenvío. Es claro y en el tono correcto (`mob-390-otp-step2-limpio.png`).
- **El código OTP está bien cableado**: `autocomplete="one-time-code"`, `inputmode="numeric"`, `pattern="[0-9]{6,10}"`, foco automático al campo al pasar de paso, y validación local antes de tocar la red.
- **`signInWithOtp` falla con mensaje accionable** («Demasiados intentos. Esperá un minuto…») y el `role="alert"` de los avisos está bien puesto.
- **Estados vacíos con copy honesto y útil** («pedile a tu salón que cargue tu email en tu ficha»), buen tono y `max-width: 42ch`.
- **Tarjeta de saldo**: número grande en serif, `font-variant-numeric: tabular-nums`, degradé suave; es la pieza más «premium» del portal.
- **Sin overflow horizontal** en ninguno de los 4 viewports y sin errores de consola en la carga.
- **`escapeHTML()`** en el nombre del servicio y `textContent` (no `innerHTML`) en el resto de los datos: la inyección está contenida.
- **Clave de sesión separada** (`eli-portal-auth`) para no cerrar la sesión de la dueña: decisión correcta y bien comentada en el código.

---

## 9. Plan de corrección sugerido

| Orden | Fix | Hallazgos | Esfuerzo |
|---|---|---|---|
| 1 | `[hidden]{display:none!important}` + `.modal-overlay[hidden]` | C-01 | **15 min** |
| 2 | Patrón de diálogo: `role=dialog`, `aria-modal`, `aria-labelledby`, `inert`, trampa de foco, Escape global, scroll lock | C-02, A-03 | 2-3 h |
| 3 | Reescritura del widget de estrellas (estado ≠ preview, `radiogroup`, 44 px, valor desde `dataset`) | C-03 | 1-2 h |
| 4 | Canje oculto sin turno + `label for` + botón deshabilitado con motivo | A-01 | 1 h |
| 5 | Modal con `max-height` y scroll interno | A-02 | 30 min |
| 6 | CTA primario: tinta sobre dorado (5,05:1) | A-04 | 15 min |
| 7 | Limpieza del modal de detalle (un rótulo por dato, `dl`, «Salón», vacíos con `—`) | A-05 | 45 min |
| 8 | Paleta de textos/foco + `--ink-faint` y `--danger` | M-07 | 30 min |
| 9 | H1 del panel, `aria-invalid`/`focus` en el login, `copiar()` con etiqueta, targets 44 px, header mobile | M-01, M-02, M-05, M-06, B-01 | 2 h |
| 10 | Consolidar estados vacíos, `role=status` del copiado, vendorizar supabase, preload de fonts | B-02…B-06, M-08 | 2-3 h |

**Total estimado: ~1,5 días de una persona.** Los tres primeros ítems (≈ medio día) ya devuelven el portal a un estado usable y reseñable.

---

## 10. Cómo se validó el widget de estrellas (transparencia de método)

La cuenta QA no tiene turnos completados, así que el botón «Dejar Reseña» no existe para ella y no era posible abrir el modal de reseña «por la puerta de adelante». Se validó por **dos caminos independientes que coinciden**:

1. **Ejecución del código del portal**: la función `renderizarEstrellas()` copiada **verbatim** de `portal.html:1044-1081`, corrida sobre el `#estrellas-modal` real de la página cargada, con mouse y teclado reales vía CDP (`Input.dispatchMouseEvent` / `dispatchKeyEvent`).
2. **Handler de producción**: `abrirModalResena()` original, invocado desde el arnés del Lead (`_audit/harness/portal-debug.html?qa=stars`, que abre el modal con un turno de prueba `Kapping`), con mouse real sobre las estrellas y lectura de clases, textos y colores computados.

En ambos caminos se ocultó únicamente el overlay de detalle (estilo inline efímero en esa pestaña) para que las estrellas fuesen clicables, porque C-01/C-02 dejan el modal de reseña tapado por el de detalle. Los resultados de la tabla de C-03 son mediciones, no inferencias. La app no se modificó en disco.

Complementariamente se verificó el estado que ve la clienta hoy: en la carga inicial `#estrellas-modal` está **vacío** (`innerHTML: ""`, 0 estrellas), porque `renderizarEstrellas()` solo se llama desde `abrirModalResena()`.

---

## 11. Método, artefactos y limitaciones

### 11.1 Cómo se midió
- **Navegador real**: Chrome 156 headless vía CDP (`Runtime.evaluate`, `getComputedStyle`, `getBoundingClientRect`, `elementFromPoint`, `document.fonts`, `Network.*`), con viewports emulados exactos y eventos de teclado/mouse reales.
- **Capturas**: `Page.captureScreenshot` (mobile DPR 2) y el navegador del harness con `tab_id` explícito para la verificación cruzada (snapshot de accesibilidad antes/después de Escape y Cancelar).
- **Contraste**: cálculo WCAG 2.x sobre los colores computados (`getComputedStyle().color` + fondo efectivo real, descomponiendo `rgba()` sobre el ancestro opaco) y sobre el compuesto del degradé para los tokens que viven sobre `.puntos-card`.
- **Sesión autenticada**: `http://127.0.0.1:4310/setup.html` (harness del Lead), cuya copia de `portal.html` es byte-idéntica al original (SHA-256 verificado). El panel QA muestra saldo 0 y los tres estados vacíos.
- **Sin escrituras**: no se enviaron reseñas ni canjes (los botones no tienen efecto por C-01/A-01/C-03) y no se disparó ningún OTP (verificado: 0 requests a `/auth/v1/otp` durante las pruebas de validación).

### 11.2 Archivos de evidencia
- Capturas: `_qa_shots/portal/` (35 PNG de esta auditoría: los `live-*` son desktop 1440×900, los `mob-*` son device metrics reales a 390/360/320, los `cli-*` son la corrida con `--window-size`).
- Datos crudos: `_qa_shots/portal/_tools/scenario1.json` (carga, foco, contraste, validación) · `scenario2.json` (panel autenticado, canje, copiado, estrellas) · `scenario3.json` (foco, Shift+Tab, estrellas con mouse, labels) · `scenario4.json` (390×844, 360×640, 320×568, overflow) · `scenario5.json` (perf, recorte por altura, paso OTP) · `scenario6.json` (capturas limpias del diseño subyacente) · `scenario7.json` (cross-check con los handlers de producción) · `contrast.json`.
- Scripts de medición: `_qa_shots/portal/_tools/*.js` (herramientas de QA, fuera de la app).

### 11.3 Limitaciones declaradas
1. **«Cerrar sesión» no se ejecutó**: `signOut()` revoca el refresh token de la cuenta QA compartida (el harness la reutiliza), así que probarlo habría roto la sesión para el resto del equipo. Se evaluó por lectura de código (`:1032-1036`: signOut → `volverALogin()` → aviso «Cerraste sesión.» en verde, sin confirmación previa) y B-06 queda como recomendación de diseño, no como defecto verificado en vivo.
2. **No se probó el envío real de una reseña contra un turno verdadero**: el modal se abrió con un turno de prueba del arnés para auditar el widget y el feedback previo, pero la llamada `crear_resena` quedó fuera de alcance y **nunca se disparó con estrellas seleccionadas** (solo el camino de 0 estrellas, que retorna antes de la RPC).
3. **No se probó el canje exitoso** (requiere turno futuro + saldo): el bloque se auditó en su estado real de carga (visible, saldo 0, sin turno).
4. **Lector de pantalla**: no se ejecutó NVDA/VoiceOver; los hallazgos de accesibilidad se basan en el árbol de accesibilidad del navegador, roles/atributos y orden de foco, más el comportamiento esperado de `role=alert`/`aria-live`. Las recomendaciones incluyen el criterio de aceptación para validarlos con un SR real.
5. **Perf**: una sola corrida en red local/headless (FCP 900 ms); sirve como orden de magnitud, no como benchmark.
