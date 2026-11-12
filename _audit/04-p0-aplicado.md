# P0 aplicado — Portal ELIMA HUB

**Fecha:** 11 de noviembre de 2026
**Rama:** `main` · **commits:** `7411d0e` (fixes) + `02b604f` (secuenciación)
**URL:** https://eli-agenda-nails.vercel.app/portal.html (deploy verificado)
**Base:** proyecto Supabase `wppleywdprvdlbajeubl` (migración aplicada con `supabase db query --linked`)

## Qué se aplicó

| # | Cambio | Archivo | Verificación |
|---|---|---|---|
| 1 | `[hidden]{display:none!important}` para modales, canje y botones ocultos | `portal.html` | En carga real: `#modal-resena` y `#modal-turno-detalle` → `display:none`, login visible. Captura `_qa_shots/portal/portal-i89-live-fixed.png`. |
| 2 | CTA con tinta oscura y borde `--gold-ink` (contraste 5,05:1) | `portal.html` | `getComputedStyle`: `rgb(59,47,53)` sobre `rgb(190,158,111)`. Antes 2,53:1. |
| 3 | Fechas date-only armadas en hora local; hora a `HH:MM` | `portal.html` | `fechaTurno('2026-11-12')` → `12 de nov de 2026` (antes 11); `horaCorta('15:00:00')` → `15:00`. |
| 4 | Estrellas reescritas: estado `calificacion`, `<button>` accesibles, hover no borra, sin off-by-one | `portal.html` | Clic en 3.ª → 3 marcadas + `aria-pressed`; `mouseleave` → sigue 3; clic en 5.ª → 5; cerrar modal → `display:none`. |
| 5 | Eliminada la sobrecarga legacy `crear_resena(bigint,integer,text)` y `EXECUTE` de `anon`/`PUBLIC` | `supabase/sql/i89_fix_resenas_legacy.sql` | `pg_proc`: solo queda `crear_resena(uuid,bigint,smallint,text)` con ACL `postgres, authenticated, service_role`. `anon` 3-arg → 404; 4-arg → 401. |
| 6 | `crear_resena` (4 args) exige que el turno sea de la clienta (`_mis_clientes()`) | ídem | Llamada autenticada de QA contra turno ajeno → `El turno no existe, no está completado o no pertenece a tu cuenta` (sin escritura). |
| 7 | `turnos_de_cliente` filtra por `_mis_clientes()` (auth_user_id/email), sin JOIN cruzada | ídem | Simulación de la clienta del turno 111 con email vinculado en transacción con `ROLLBACK` → `turnos_visibles=1`, `salones=1`. `anon` → 401. |
| 8 | El portal espera `vincular_mi_cuenta`/saldo antes de pedir turnos | `portal.html` | `cargarPortal()` reemplaza los `setTimeout(...,300)` en `SIGNED_IN` y `getSession`. |

## Nota sobre el paso 3 del pedido

El pedido indicaba `<JOIN con clientes.user_id = auth.uid()>`. En este esquema `clientes.user_id` es **la cuenta del salón que cargó la ficha** (ver `i66_puntos.sql:72-77`), no la clienta. Usar esa columna era justamente el bug auditado: la clienta no veía sus turnos y el staff veía turnos de otros salones. La migración usa `_mis_clientes()`, que resuelve por `clientes.auth_user_id` o por email del JWT, que es la identidad real de la clienta.

## Verificación de producción

- **Deploy:** `portal.html` live contiene `[hidden] { display: none !important; }` y `cargarPortal()` (bytes 57.435; HEAD publicado).
- **UI en vivo:** el login se muestra sin modales; el email es clickeable y editable; «Enviarme el código» con `abc` muestra «Escribí un email válido.» sin request.
- **REST anon:** `crear_resena` 3-arg → `404 PGRST202`; 4-arg → `401`; `turnos_de_cliente` → `401 permission denied`.
- **Datos:** la transacción de prueba que vinculó temporalmente el email del turno 111 terminó en `ROLLBACK`; `clientes.email` volvió a quedar vacío y `resenas` del turno 111 sigue en 0.

## Fuera de alcance (sigue pendiente, no se tocó)

- Lógica de puntos/canje (`cliente_saldo_puntos_turno`, `cliente_canjear_puntos`) y Marketplace, por pedido expreso.
- Semántica completa de diálogo (`role="dialog"`, `aria-modal`, trampa de foco, Escape para ambos modales) y `max-height` del modal — quedan en P1 del informe.
- El botón «Canjear Puntos» ya no aparece en el login, pero el flujo de canje conserva los defectos A3 del informe.
- `index.html` no requirió cambios.

## Rollback

El cambio de base es una migración SQL versionada; para revertir el frontend alcanza con `git revert 02b604f 7411d0e` y push (Vercel redeploya). La función legacy **no** debe restaurarse: era el vector de escritura anónima.
