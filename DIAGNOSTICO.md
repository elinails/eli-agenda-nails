# Diagnóstico técnico — "Eli M. Nails · Agenda de turnos"

**Fecha:** 7 de noviembre de 2026
**Alcance:** `index (1).html` (1.013 líneas, ~47 KB), `style (1).css`, `README (1).md`, `gitattributes (1)`, `agenda eli.zip`
**Método:** lectura completa del código + **ejecución real en Chromium** sobre una copia instrumentada en `%TEMP%` (el proyecto no fue modificado), más verificación aislada en Node.js con `TZ=America/Buenos_Aires`.

---

## 1. Veredicto ejecutivo

**Es un prototipo funcional, no un producto confiable.** Hace lo esencial (crear, listar, editar, borrar turnos, verlos en calendario, exportar a Excel, mandar WhatsApp) y visualmente es prolijo, pero tiene **tres defectos que afectan directamente al negocio**:

1. **Todas las fechas visibles aparecen un día antes** del real (lista, ficha, WhatsApp y Excel). Un turno del martes 10 se le informa a la clienta como *"lunes, 9 de noviembre"*.
2. **Después de las 21:00 (hora argentina) la fecha por defecto del formulario pasa a ser "mañana"**, y el turno se guarda en el día equivocado sin ningún aviso.
3. **El botón de WhatsApp no tiene número de destino** y el link de Instagram del mensaje viaja roto (doble codificación). No se puede enviar directo y el link no abre.

A eso se suman: **no se despliega tal como está** (`index (1).html`), **no tiene respaldo** (si el navegador limpia el almacenamiento se pierde toda la agenda con sus clientas), **no valida superposición de turnos** y **4 scripts de CDN se ejecutan sin integridad ni CSP**.

| Indicador | Estado |
|---|---|
| Funcionalidad núcleo (CRUD) | 🟢 Operativa |
| Exactitud de fechas | 🔴 Roto — todos los días corridos 1 día |
| Envío de WhatsApp | 🔴 Incompleto — sin destinatario, link inválido |
| Persistencia / respaldo | 🟠 Solo local, sin backup ni restauración |
| Seguridad de dependencias | 🟠 CDN sin SRI ni CSP, `xlsx 0.18.5` con CVEs |
| Accesibilidad | 🟠 Sin teclado ni ARIA en modales; contrastes < AA |
| Despliegue | 🔴 Nombres de archivo inválidos para hosting estático |
| Tests / CI / repo | 🔴 Inexistentes |

**Riesgo principal:** el sistema *parece* funcionar. Los errores son silenciosos — un `TypeError` que solo queda en consola, fechas corridas, mensajes que se envían mal — y encima **dos bugs de fecha se cancelan entre sí** (ver hallazgo C2), lo que hace que el problema se descubra recién cuando la clienta llega el día equivocado.

---

## 2. Inventario y arquitectura

### 2.1 Archivos

| Archivo | Tamaño | Rol real |
|---|---|---|
| `index (1).html` | 47.097 B | **Toda la aplicación**: HTML + CSS inline (137 líneas) + JS inline (~580 líneas) |
| `style (1).css` | 388 B | **Código muerto**: no está referenciado por el HTML. Boilerplate de DeepSite |
| `README (1).md` | 211 B | Metadatos de Hugging Face Space (`sdk: static`) con el nombre de **otro** proyecto (`eli-m-nails`) |
| `gitattributes (1)` | 1.519 B | Config de Git LFS para pesos de modelos (`.ckpt`, `.safetensors`…) — irrelevante y mal nombrado (debería ser `.gitattributes`) |
| `agenda eli.zip` | 9.701 B | Copia comprimida de los 4 archivos anteriores; no aporta nada y se sirve públicamente |

### 2.2 Stack

- **UI:** Tailwind CSS vía **Play CDN** (`cdn.tailwindcss.com`, sin versión fijada) + Font Awesome 6.4.0.
- **Calendario:** FullCalendar **5.11.3** (+ locale `es`).
- **Excel:** SheetJS **xlsx 0.18.5**.
- **Persistencia:** **IndexedDB** local, base `eli_nails_appointments`, store `appointments` (autoincrement, índices `date` y `status`).
- **Backend:** ninguno. 100 % cliente; los datos viven en el navegador del dispositivo.

### 2.3 Modelo de datos

```js
{
  id: number,            // autoincrement
  clientName: string,
  serviceType: 'Kapping' | 'Soft gel' | 'Semipermanente',
  date: 'YYYY-MM-DD',    // string, sin zona horaria
  time: 'HH:MM',         // de una lista fija 09:00–19:00
  price: number,         // entero, step=100
  notes: string,
  status: 'pending' | 'confirmed' | 'completed' | 'cancelled',
  timestamp: number      // calculado… y nunca usado
}
```

### 2.4 Flujo

```
IndexedDB ──getAll──> loadAppointments() ──> calendario (FullCalendar)
                    └─> loadAppointmentsList(filtros) ──> tarjetas HTML
Formulario ──> saveAppointment() ──> add/put ──> reload + showView('appointments')
```

Tres vistas conmutadas por `.hidden` (`calendario`, `listado`, `nuevo`), dos modales (`#appointment-modal`, `#confirm-modal`). Todo dentro de un único listener `DOMContentLoaded`.

---

## 3. Hallazgos por severidad

> **Verificado** = reproducido en navegador real o con Node. **Código** = determinado por lectura directa del fuente, sin ambigüedad.

### 🔴 Críticos

#### C1. Todas las fechas mostradas van un día atrás
- **Dónde:** [`index (1).html:964-967`](index%20(1).html#L964-L967) `formatDate()` — usada en [`715`](index%20(1).html#L715), [`847`](index%20(1).html#L847), [`949`](index%20(1).html#L949), [`771`](index%20(1).html#L771)
- **Causa:** `new Date('2026-11-09')` interpreta la cadena *date-only* como **medianoche UTC**. En `America/Buenos_Aires` (UTC−3) cae a las **21:00 del día anterior**; `toLocaleDateString('es-AR')` imprime ese día, con el nombre de día equivocado.
- **Verificado:** guardé un turno el `2026-11-09` (lunes) → lista, modal y mensaje mostraron **"domingo, 8 de noviembre de 2026"**. Node: `new Date('2026-11-07').toLocaleDateString('es-AR', …)` → `"viernes, 6 de noviembre de 2026"`.
- **Impacto:** el mensaje de confirmación que recibe la clienta tiene **el día equivocado**. Lo mismo el Excel (contabilidad) y la ficha. Es el peor defecto porque el error **sale hacia afuera**.
- **Contradicción visible:** el calendario (que usa el string naive) muestra la cita el día 10; el listado la muestra el día 9. La misma cita figura en dos días distintos según la vista.
- **Fix:**
  ```js
  function parseLocalDate(s) {            // 'YYYY-MM-DD' -> Date local
    const [y, m, d] = s.split('-').map(Number);
    return new Date(y, m - 1, d);         // o new Date(`${s}T12:00:00`)
  }
  function formatDate(s) {
    return parseLocalDate(s).toLocaleDateString('es-AR',
      { weekday: 'long', year: 'numeric', month: 'long', day: 'numeric' });
  }
  ```

#### C2. La fecha por defecto salta a "mañana" a partir de las 21:00
- **Dónde:** [`542`](index%20(1).html#L542) (también [`786`](index%20(1).html#L786) y [`1007`](index%20(1).html#L1007))
- **Causa:** `new Date().toISOString().split('T')[0]` devuelve la fecha **en UTC**. Entre las 21:00 y las 23:59 de Argentina, la fecha UTC ya es la del día siguiente.
- **Verificado:** a las **22:40 del 7/11/2026**, "Nuevo Turno" abrió con **`2026-11-08`**. Node: `new Date('2026-11-07T22:40:00-03:00').toISOString().split('T')[0]` → `2026-11-08`.
- **Impacto:** todo turno cargado de noche se guarda un día después del que la profesional cree, en silencio.
- **⚠️ Los dos bugs se enmascaran:** si cargás a las 22:40, el turno se guarda en el 8 (C2) pero el listado lo muestra como el 7 (C1)… **que es el día correcto**. La lista "se ve bien", el calendario muestra otro día y la base guarda un tercero. Esto explica por qué el defecto pasó desapercibido.
- **Fix:** un helper local único, usado también para el nombre del archivo Excel:
  ```js
  const todayISO = () => new Intl.DateTimeFormat('en-CA',
    { timeZone: 'America/Argentina/Buenos_Aires' }).format(new Date());
  ```

#### C3. WhatsApp: sin destinatario y con el link roto
- **Dónde:** [`943-961`](index%20(1).html#L943-L961)
- **A — sin número:** `const phoneNumber = ''` ([`944`](index%20(1).html#L944)) → `https://wa.me/?text=…`. **Verificado:** es exactamente lo que se abre; WhatsApp pide elegir un contacto, no abre el chat de la clienta. El modelo de datos **no tiene campo teléfono**, así que no se arregla sin tocar formulario y base.
- **B — doble codificación:** [`957`](index%20(1).html#L957) hace `${encodeURIComponent('https://www.instagram.com/…')}` **dentro** de un texto que después se codifica entero. **Verificado** en la URL capturada: `Eli%20https%253A%252F%252Fwww.instagram.com…` → el mensaje que recibe la clienta contiene literalmente `https%3A%2F%2F…`, texto no clickeable.
- **C — plantilla fija:** el texto (incluida la regla "sin niños ni acompañantes" y el link de Instagram) está hardcodeado; cambiarlo exige editar código.
- **D — texto contradictorio:** dice *"Te confirmo tu turno"* aunque el estado sea **Cancelado** ([`945-947`](index%20(1).html#L945-L947)).
- **Fix:** agregar `clientPhone` (con selector de país), normalizar a E.164 (`+549…`), armar `https://wa.me/${phone}?text=${encodeURIComponent(msg)}` dejando la URL de Instagram **sin** codificar dentro de `msg`, y condicionar el texto al estado.

### 🟠 Altos

#### A1. Error de arranque: `calendar.render()` sobre `undefined`
- **Dónde:** [`512`](index%20(1).html#L512) llamado desde [`1000`](index%20(1).html#L1000)
- **Causa:** `showView('calendar')` corre **sincrónicamente** al final del `DOMContentLoaded`, pero `calendar` se asigna recién en el `onsuccess` **asíncrono** de IndexedDB.
- **Verificado:** error real en consola: `Uncaught TypeError: Cannot read properties of undefined (reading 'render')`. El `throw` **aborta lo que sigue**: nunca se ejecutan las líneas [`1002-1009`](index%20(1).html#L1002-L1009).
- **Consecuencias verificadas:** el filtro de fecha queda **vacío** (debía arrancar en hoy) y **los `min` de fecha nunca se aplican** (`dateFilterValue: ""`, `dateInputMin: null`, `dateFilterMin: null`).
- **Fix:** `if (calendar) calendar.render();` y ordenar el arranque (abrir base → init → render), moviendo 1002-1009 antes de `showView`.

#### A2. `window.calendar` no es el calendario: es el `<div id="calendar">`
- **Dónde:** [`609`](index%20(1).html#L609) `if (window.calendar) { calendar.removeAllEvents(); … }`
- **Causa:** el fuente **nunca** asigna `window.calendar`. Pero el navegador expone como propiedades de `window` los elementos con `id`, así que la guarda se cumple **por accidente** devolviendo el DIV. Dentro del bloque se usa la variable de closure `calendar` (la instancia real), que sí existe.
- **Verificado:** `window.calendar === document.getElementById('calendar')` → **`true`**; `typeof window.calendar.removeAllEvents` → **`undefined`**.
- **Por qué hoy funciona y por qué es frágil:** funciona solo porque el callback de `getAll()` siempre llega *después* de `initCalendar()`. Si se renombra el `id`, se mueve el contenedor o cambia el orden de inicialización, `calendar.removeAllEvents()` explota sobre `undefined` y **los turnos desaparecen del calendario sin error visible**.
- **Fix:** `window.calendar = calendar;` en `initCalendar()` (o quitar la guarda y usar la variable directa).

#### A3. Modales desalineados (aparecen arriba a la izquierda)
- **Dónde:** [`344`](index%20(1).html#L344) y [`408`](index%20(1).html#L408)
- **Causa:** el contenedor tiene `hidden items-center justify-center`; al mostrar se hace `remove('hidden')` pero **nunca se agrega `flex`**. Sin `display:flex`, `items-center`/`justify-center` no hacen nada.
- **Verificado:** `display: "block"`, caja en `top: 0, left: 16` sobre viewport 1280×800 (captura `modal-desktop.png`).
- **Fix:** `class="… hidden flex items-center justify-center"`, y al panel `max-h-[90vh] overflow-y-auto` (hoy las notas largas se cortan).

#### A4. XSS almacenado en el listado
- **Dónde:** [`702-726`](index%20(1).html#L702-L726) — `appointmentCard.innerHTML = \`… ${appointment.clientName} …\``
- **Causa:** nombre y servicio se interpolan crudos. Un nombre como `<img src=x onerror=alert(1)>` ejecuta JS al abrir "Listado"; un nombre con `<` rompe el layout. El modal sí usa `textContent` ([`845-851`](index%20(1).html#L845-L851)): el escape es inconsistente.
- **Riesgo:** en uso personal es auto-XSS, pero el sitio está pensado para publicarse y cualquier dato importado (Excel, backup) entra a ese `innerHTML`.
- **Fix:** construir con `createElement` + `textContent`, o escapar (`s.replace(/[&<>"']/g, …)`).

#### A5. No hay respaldo ni restauración
- **Dónde:** modelo de persistencia completo ([`436-455`](index%20(1).html#L436-L455)), export en [`759-792`](index%20(1).html#L759-L792)
- **Problema:** IndexedDB es *best effort*: se borra al limpiar datos del navegador, en modo incógnito o al liberar espacio. El único respaldo es un Excel **que no se puede reimportar**; no hay export/import JSON ni copia en la nube.
- **Impacto:** **pérdida total de la agenda** por una acción cotidiana, sin aviso ni recuperación.
- **Fix:** exportar/importar **JSON** completo + botón "Descargar respaldo" y recordatorio periódico.

#### A6. Doble reserva: no hay validación de solapamiento ni duración
- **Dónde:** [`549-597`](index%20(1).html#L549-L597)
- **Problema:** se pueden cargar dos turnos a las 10:00 del mismo día sin aviso; no existe duración ni hora de fin; los horarios son una lista fija de 09:00 a 19:00 **en punto**. Kapping y soft gel duran más de una hora: el solape es inevitable.
- **Impacto:** el propósito de una agenda es justamente evitar el solapamiento. Hoy es un cuaderno, no una agenda.
- **Fix:** leer por índice `date`, comparar rangos antes de `add/put`, rechazar con mensaje; agregar `duration` por servicio y `end` en los eventos.

#### A7. Fallos silenciosos: la app parece funcionar pero no guarda
- **Dónde:** 7 manejadores, todos `console.error` ([`458`](index%20(1).html#L458), [`581`](index%20(1).html#L581), [`594`](index%20(1).html#L594), [`636`](index%20(1).html#L636), [`678`](index%20(1).html#L678), [`790`](index%20(1).html#L790), [`938`](index%20(1).html#L938))
- **Problema:** si IndexedDB está bloqueado, la cuota se llenó o un CDN no cargó, Guardar/Eliminar no hacen nada. Si `open` falla, `db` queda `undefined` y `db.transaction` ([`566`](index%20(1).html#L566), [`601`](index%20(1).html#L601), [`642`](index%20(1).html#L642), [`760`](index%20(1).html#L760), [`928`](index%20(1).html#L928)) lanza `TypeError`. No hay `onblocked`, ni `try/catch`, ni estado de error.
- **Fix:** estado de error visible, deshabilitar acciones hasta abrir la DB, `onblocked`, y aviso al usuario.

#### A8. Cadena de suministro: CDN sin SRI, sin CSP, Tailwind sin pinear
- **Dónde:** [`7-12`](index%20(1).html#L7-L12), [`47`](index%20(1).html#L47), [`1012`](index%20(1).html#L1012)
- **Verificado:** **0** atributos `integrity` en 7 recursos externos (4 scripts + 2 CSS + 1 `@import` de Google Fonts) y **no hay** `<meta http-equiv="Content-Security-Policy">`.
- **Riesgos:** un CDN comprometido ejecuta código con acceso a **toda** la agenda; `cdn.tailwindcss.com` es el compilador JIT de desarrollo, **no está pinneado** (Tailwind lo desaconseja para producción y su versión mayor puede cambiar la API de `tailwind.config`); `xlsx 0.18.5` arrastra **CVE-2023-30533** (prototype pollution) y **CVE-2024-22363** (ReDoS) — acá solo se escribe, no se leen archivos, así que hoy no es explotable, pero es una librería abandonada en npm.
- **Fix:** build de Tailwind, versiones fijas con SRI o self-host, CSP; `xlsx` ≥ 0.20.2 desde `cdn.sheetjs.com` o reemplazar el escritor.

#### A9. El proyecto no despliega como sitio estático
- **Dónde:** nombres de archivo; [`README (1).md:6`](README%20(1).md#L6) declara `sdk: static`
- **Problema:** un hosting estático (incluido HF Spaces) busca `index.html` y `README.md` en la raíz. Con `index (1).html` la app publicada da **404** y los metadatos del Space no se leen. `style (1).css` es huérfano.
- **Fix:** renombrar a `index.html` / `README.md`, borrar `style (1).css` y `agenda eli.zip`, renombrar `.gitattributes`.

### 🟡 Medios

| # | Hallazgo | Línea | Detalle / fix |
|---|---|---|---|
| M1 | La lista ignora los filtros al cambiar de pestaña o tras guardar | [`516`](index%20(1).html#L516), [`641`](index%20(1).html#L641) | `showView('appointments')` llama `loadAppointmentsList()` **sin argumentos**, pero los inputs conservan búsqueda/estado/fecha: la lista aparece completa con filtros aparentemente activos. Fix: helper `currentFilters()` usado en todas las llamadas. |
| M2 | Catálogo y horarios hardcodeados | [`258-264`](index%20(1).html#L258-L264), [`276-290`](index%20(1).html#L276-L290) | 3 servicios y 11 horarios fijos. Agregar un servicio o una franja de 15 min exige editar el HTML. Debería ser configuración (store `settings`). |
| M3 | Precio 0 invisible y sin formato de moneda | [`723`](index%20(1).html#L723), [`849`](index%20(1).html#L849), [`773`](index%20(1).html#L773) | `price \|\| '--'` convierte un 0 legítimo en `--`; se muestra `$5000` en vez de `$5.000`; en Excel va como texto **no sumable**. Fix: `price ?? 0`, `Intl.NumberFormat('es-AR', {style:'currency', currency:'ARS'})`, celda numérica. |
| M4 | `step="100"` y "Modificar" saltea la validación nativa | [`296`](index%20(1).html#L296), [`321`](index%20(1).html#L321), [`897`](index%20(1).html#L897) | El submit rechaza importes no múltiplos de 100 (p. ej. 4.750) con un error nativo que la usuaria no entiende; y como "Modificar" es `type=button`, llama `saveAppointment()` **sin** validación nativa: se pueden grabar precios negativos. Fix: `step="1"`, `min=0`, validar explícitamente en ambos caminos. |
| M5 | La exportación ignora los filtros y no sirve para caja | [`759-786`](index%20(1).html#L759-L786) | Exporta **todo** aunque el listado esté filtrado; la fecha es texto localizado (y con el día −1 de C1); el precio es texto; no hay totales ni ingresos por período. Fix: exportar los filtrados, fecha ISO, precio numérico y hoja resumen. |
| M6 | Índices de IndexedDB creados y nunca usados | [`436-438`](index%20(1).html#L436-L438) | `date` y `status` se indexan, pero todo se resuelve con `getAll()` + filtro en JS. No escala y desperdicia escritura. |
| M7 | Accesibilidad incompleta | general | Filtros sin `<label>`, tabs sin `role=tab`/`aria-selected`, modales sin `role="dialog"`/`aria-modal`/foco atrapado/`Escape`, tarjetas son `div` con `click` (inaccesibles por teclado), botones "×" sin nombre accesible. |
| M8 | El estado en el modal es una barra de ancho completo | [`855`](index%20(1).html#L855) | Se aplica una clase de *badge* a un `<p>` de bloque: ocupa todo el ancho (visible en la captura). Fix: `inline-block` sobre `<span>`. |
| M9 | Eventos sin hora de fin ni franja horaria | [`613-626`](index%20(1).html#L613-L626), [`800-813`](index%20(1).html#L800-L813) | No se pasa `end`; en Semana/Día el turno es un punto sin duración y la grilla muestra 24 h. Falta `slotMinTime`/`slotMaxTime`/`businessHours` (09–20). |
| M10 | Si se arregla A1 se rompe el registro de turnos pasados | [`1008-1009`](index%20(1).html#L1008-L1009) | `min = hoy` impedirá cargar un turno **ya realizado** ayer (justo lo que se hace para registrar la caja) y en el filtro impedirá consultar historia. Fix: `min` **solo** en el alta y con fecha local; **nunca** en el filtro de listado. |
| M11 | Estados sin flujo; el mensaje contradice el estado | [`308-315`](index%20(1).html#L308-L315), [`945-947`](index%20(1).html#L945-L947) | Se puede crear un turno ya "Cancelado/Realizado"; no hay acciones de cancelar/reprogramar; el WhatsApp dice "Te confirmo tu turno" aunque esté cancelado. |
| M12 | El listado abre por lo más viejo | [`667-671`](index%20(1).html#L667-L671) | Orden ascendente puro: primero aparecen los turnos viejos y cancelados. No hay vista "próximos". |
| M13 | La barra de filtros desborda en móvil | [`223`](index%20(1).html#L223) | `flex space-x-2` (select + fecha + exportar) no envuelve; a 320–390 px se sale del contenedor. Fix: `flex-wrap` y apilado. |
| M14 | Contraste insuficiente en los botones de WhatsApp | [`327`](index%20(1).html#L327), [`396`](index%20(1).html#L396) | `text-white` sobre `#25D366` = **1,98:1** (calculado), contra 4,5:1 exigido por WCAG AA. Fix: texto oscuro (`#0B3D1E`) o verde más oscuro. |
| M15 | PII en claro, sin protección | [`436-449`](index%20(1).html#L436-L449), [`786`](index%20(1).html#L786) | Nombres, teléfonos (cuando se agreguen), notas y precios quedan legibles en IndexedDB y en el `.xlsx` de Descargas; sin PIN ni cifrado. En una PC compartida cualquiera ve la agenda. Ley 25.326. |
| M16 | Restos de terceros | [`339`](index%20(1).html#L339), [`1012`](index%20(1).html#L1012), README | El pie dice "Creado con ♥ por @Jacinto.Cards", hay badge fijo de DeepSite con link "Remix" a `Francofsm84/eli-m-nails` y el README describe **otro** Space. Revisar qué corresponde publicar. |
| M17 | Sin repo, tests, lint ni build | — | No hay `.git`, `package.json` ni un solo test. C1 y A1 se detectan con un smoke test de 10 líneas (abrir → guardar → ver el evento). |
| M18 | Datos atados al origen | [`436-438`](index%20(1).html#L436-L438) | La base es por origen: cambiar de dominio, de Space o abrir el archivo local crea una agenda **nueva** y "desaparece" la anterior. Fix: URL estable + backup obligatorio. |

### 🔵 Bajos

| # | Hallazgo | Línea | Detalle |
|---|---|---|---|
| B1 | `timestamp` muerto y mal nombrado | [`558`](index%20(1).html#L558) | Se guarda y nunca se lee; es la fecha del turno, no de creación; se calcula **antes** de validar y puede quedar `NaN`. El orden se recalcula con `new Date()` en cada render. |
| B2 | La animación del modal no existe | [`141-143`](index%20(1).html#L141-L143) vs [`30-37`](index%20(1).html#L30-L37) | `.modal-content` pide `slide-up`, pero Tailwind emite `@keyframes slideUp` (los nombres son sensibles a mayúsculas). Nunca anima. |
| B3 | Doble carga tras guardar | [`575-577`](index%20(1).html#L575-L577), [`630`](index%20(1).html#L630) | El callback de `loadAppointments()` y `showView()` disparan dos `getAll` + dos renders. |
| B4 | `search` asume `clientName` string | [`653`](index%20(1).html#L653) | Un registro viejo o manipulado sin ese campo rompe el render del listado. |
| B5 | Nombre del Excel con fecha UTC | [`786`](index%20(1).html#L786) | Después de las 21:00 se descarga con la fecha de mañana. |
| B6 | Sin `noopener` | [`960`](index%20(1).html#L960), [`1012`](index%20(1).html#L1012) | `window.open(…, '_blank')` y `<a target="_blank">` sin `rel` (los navegadores modernos lo mitigan). |
| B7 | Google Fonts bloqueante | [`47`](index%20(1).html#L47) | `@import` (render-blocking, expone IP/referrer). Fix: `<link rel="preconnect">` + self-host. |
| B8 | Sin favicon, `description` ni Open Graph | [`4-6`](index%20(1).html#L4-L6) | Al compartir el link no hay preview; 404 de favicon en cada carga. |
| B9 | Duplicación de clases de evento | [`624`](index%20(1).html#L624) + [`829`](index%20(1).html#L829) | `fc-event-<status>` se aplica dos veces (por `className` y por `eventClassNames`). |
| B10 | Badge DeepSite tapa contenido en móvil | [`1012`](index%20(1).html#L1012) | `position:fixed; z-index:10`, además es un request externo y branding ajeno. |
| B11 | `alert()` y cero feedback | [`562`](index%20(1).html#L562) | Validación con alert nativo; sin confirmación de guardado (toast). |
| B12 | Sin `prefers-reduced-motion` | [`141-143`](index%20(1).html#L141-L143) | Animaciones fijas para quien pidió reducir movimiento. |

---

## 4. Hipótesis verificadas y descartadas

| Hipótesis | Resultado |
|---|---|
| *"El calendario nunca muestra turnos: `window.calendar` no existe"* | ❌ **FALSA.** Una lectura estática sugiere que el bloque nunca entra; la prueba real lo refuta: tras recargar, el mes mostraba **2 eventos** (`eventsInMonth: 2`). La explicación es A2: `window.calendar` **sí** es *truthy* porque el navegador expone el `<div id="calendar">` en `window`, y dentro del bloque se usa la instancia de closure. Funciona **por accidente**, no por diseño. |
| *"Los turnos se pierden al recargar"* | ❌ Falsa: los 2 turnos persistieron correctamente en IndexedDB. |
| *"El bug de fecha se habría notado"* | ❌ C2 y C1 se cancelan en el listado (ver §3.1) y lo camuflan; el calendario y la base quedan mal igual. |

> Esta es la razón por la que el diagnóstico se hizo **ejecutando la app** y no solo leyendo el código: la conclusión "obvia" era la equivocada.

---

## 5. Pruebas ejecutadas

| # | Prueba | Resultado observado |
|---|---|---|
| 1 | Parseo date-only en `es-AR` (Node, TZ AR) | `2026-11-07` → `"viernes, 6 de noviembre de 2026"` ❌ un día menos |
| 2 | Fecha por defecto del formulario a las 22:40 | Campo `Fecha` = **`2026-11-08`** (mañana) ❌ |
| 3 | Guardar turno `2026-11-10 15:00` | Guarda OK; la lista muestra **`lunes, 9 de noviembre`** ❌ |
| 4 | Misma cita: calendario vs listado | Calendario **10**, listado **9** ❌ se contradicen |
| 5 | Errores de arranque | `Uncaught TypeError: …reading 'render'` ❌ |
| 6 | Estado post-error | `dateFilterValue=""`, `dateInputMin=null`, `dateFilterMin=null` ❌ |
| 7 | `window.calendar` | Es el **DIV** (`isDiv: true`, `removeAllEvents: undefined`) ⚠️ |
| 8 | Eventos en el mes tras recargar | **2 eventos** ✅ (funciona por accidente) |
| 9 | Modal de detalle | `display:block`, caja `top:0/left:16` de 1280×800 ❌ no centrado |
| 10 | URL de WhatsApp | `https://wa.me/?text=…` sin número ❌; Instagram `%253A%252F…` ❌ |
| 11 | Persistencia tras recargar | Turnos intactos ✅ |
| 12 | Locale del calendario | Español correcto (mes, días, botones) ✅ |
| 13 | CRUD completo | Alta/edición/baja operativas; baja con confirmación ✅ |
| 14 | Export Excel | Genera el archivo, fecha UTC en el nombre, todas las filas ⚠️ |

---

## 6. Lo que está bien (no reescribir)

- Paleta y jerarquía visual coherentes; los estados se distinguen por color **y** por texto.
- Separación limpia en tres vistas y un modelo de datos claro.
- FullCalendar bien configurado en lo básico: locale `es`, `buttonText`, `eventTimeFormat` 24 h.
- IndexedDB con `autoIncrement` y `onupgradeneeded` preparado para migraciones (`DB_VERSION`).
- `textContent` en el modal de detalle (la mitad segura del problema de XSS).
- Clases responsive razonables (`grid-cols-1 md:grid-cols-2`, `flex-wrap` en botones).
- Cero dependencias de build: se abre con doble clic.

---

## 7. Plan de corrección priorizado

**Bloque 1 — exactitud (medio día).** Sin esto, la app no debe usarse para confirmar turnos.
1. Helper `todayISO` + `parseLocalDate` y reemplazar las 5 apariciones problemáticas (C1, C2), incluido el nombre del Excel.
2. `window.calendar = calendar` y `if (calendar) calendar.render()` (A1, A2).
3. Agregar `flex` a los dos modales (A3).
4. Verificar 3 casos: turno de hoy, de pasado mañana, y uno cargado a las 23:00.

**Bloque 2 — el mensaje que sale (1 día).**
5. Campo **teléfono** en el modelo + formulario, normalización E.164, `wa.me/<numero>` (C3-A).
6. Sacar el `encodeURIComponent` anidado del link (C3-B); plantilla editable y condicionada al estado (C3-D).
7. Escapar el listado o construir el DOM sin `innerHTML` (A4).

**Bloque 3 — no perder datos (1 día).**
8. Exportar/Importar **JSON** completo + "Descargar respaldo" (A5).
9. Mensaje visible si IndexedDB falla; `onblocked`; deshabilitar acciones hasta abrir la base (A7).

**Bloque 4 — agenda real (3-5 días).**
10. Duración por servicio, `end` en eventos y detección de solapamiento con aviso (A6, M9).
11. Servicios y horarios configurables (M2); `min` de fecha coherente con "cargar turno ya realizado" (M10).
12. Importe con `Intl.NumberFormat` y `step` correcto (M3, M4); export que respete filtros (M5).
13. Filtros persistentes entre vistas (M1) y orden por proximidad (M12).

**Bloque 5 — publicar bien (1 día).**
14. Renombrar a `index.html`; borrar `style (1).css` y `agenda eli.zip`; `.gitattributes`; README real (A9, M16).
15. Fijar dependencias + SRI + CSP, o vendorizar los assets para que funcione **offline** (A8).
16. Accesibilidad de modales, tarjetas y filtros; contrastes AA (M7, M8, M14).

**Bloque 6 — sostenibilidad.**
17. `git init`, `package.json`, linter y 5-6 tests de fechas (la fuente de casi todos los bugs) + smoke test de guardado.
18. Evaluar backend (Supabase/Firebase) si necesita la agenda en **dos dispositivos**: hoy cada navegador tiene su propia agenda, y eso es una limitación estructural, no un bug.

---

## 8. Limitaciones estructurales (decisiones, no bugs)

1. **Una agenda por navegador.** El celular y la computadora no comparten datos. Para un salón que atiende desde el teléfono, suele ser el límite real del producto.
2. **Sin offline.** Paradójicamente los datos son locales, pero la app necesita 7 recursos externos para dibujarse: sin internet no abre.
3. **Privacidad.** Datos personales de clientas sin cifrar en el navegador; sin aviso, consentimiento, política ni borrado por clienta (Ley 25.326).
4. **Sin multi-usuario ni roles.** No hay autenticación: quien tenga el dispositivo tiene la agenda completa.
5. **Escalabilidad.** `getAll()` + filtrado en memoria es correcto hasta unos pocos miles de turnos; después conviene paginar y usar los índices.

---

## 9. Anexo — métricas

| Métrica | Valor |
|---|---|
| Líneas totales | 1.013 |
| JS inline | ~580 líneas en un único `DOMContentLoaded` |
| CSS inline | ~137 líneas + Tailwind runtime |
| Recursos externos | 7 (Tailwind Play CDN, Font Awesome, FullCalendar ×3 contando CSS, SheetJS, Google Fonts) |
| Atributos SRI | 0 |
| Manejadores de error | 7, todos `console.error` |
| Tests | 0 |
| Tamaño del sitio (sin CDN) | ~49 KB |
| Archivos con código muerto | 2 (`style (1).css`, `gitattributes (1)`) + 1 duplicado (`agenda eli.zip`) |
| Hallazgos | **3 críticos · 9 altos · 18 medios · 12 bajos** |
