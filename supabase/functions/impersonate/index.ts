/**
 * I48 · God Mode V3 — Impersonación segura de un salón.
 *
 * Qué hace (en este orden):
 *   1) Valida el JWT del que llama usando la PUBLISHABLE key (pública).
 *   2) Con la service_role verifica que su user_id esté en public.super_admins.
 *   3) Resuelve el dueño del salón EN EL SERVIDOR (miembros_salon, rol = owner).
 *   4) Genera el magic link con auth.admin.generateLink y devuelve el action_link.
 *   5) Audita el intento en public.auditoria_admin (ok y fallido), sin guardar tokens.
 *
 * Seguridad:
 *   - La service_role SOLO existe como secret de esta función. Nunca en el frontend.
 *   - No se confía en ningún email/user_id que mande el navegador: se recibe salon_id
 *     y el dueño se resuelve contra la base.
 *   - redirect_to se valida contra una allowlist de orígenes (anti open-redirect).
 *   - El action_link y el token_hash son credenciales: no se loguean ni se guardan.
 *   - Se exige sesión AAL2 (2FA) del SuperAdmin cuando el claim `aal` está presente.
 */

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

/* ─────────────────────────── Configuración ─────────────────────────── */

const SUPABASE_URL = (Deno.env.get("SUPABASE_URL") || "").replace(/\/+$/, "");
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

// La publishable/anon key es PÚBLICA por diseño (ya viaja en admin.html/index.html).
// Supabase la inyecta como SUPABASE_ANON_KEY (o SUPABASE_PUBLISHABLE_KEY en proyectos
// nuevos). El literal queda como último respaldo para no depender del nombre exacto.
const PUBLISHABLE_KEY =
  Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ||
  Deno.env.get("SUPABASE_ANON_KEY") ||
  "sb_publishable_Y32sTccT1KPn_rKSgCzpOw_1F3RZvK1";

const MAX_POR_HORA_RAW = Number(Deno.env.get("IMPERSONATE_MAX_POR_HORA") || "10");
const MAX_POR_HORA = Number.isFinite(MAX_POR_HORA_RAW) && MAX_POR_HORA_RAW > 0
  ? Math.floor(MAX_POR_HORA_RAW)
  : 10;

const EXIGIR_2FA = (Deno.env.get("REQUIRE_AAL2") || "true").toLowerCase() !== "false";

// Si el proyecto usa un dominio propio, sobreescribir con:
//   supabase secrets set ADMIN_ORIGINS="https://midominio.com,https://elinails.github.io"
const ORIGENES_PERMITIDOS = (
  Deno.env.get("ADMIN_ORIGINS") ||
  [
    "https://elinails.github.io",
    "https://eli-agenda-nails.vercel.app",
    "http://localhost:5500",
    "http://127.0.0.1:5500",
    "http://localhost:8080",
    "http://127.0.0.1:8080",
    "http://localhost:3080",
    "http://127.0.0.1:3080",
  ].join(",")
)
  .split(",")
  .map((origen) => origen.trim().replace(/\/+$/, ""))
  .filter(Boolean);

// Fallback opcional si el frontend no manda redirect_to (ej. para probar con curl).
const SITE_URL = (Deno.env.get("SITE_URL") || "").replace(/\/+$/, "");

/* ──────────────────────────── Utilidades ───────────────────────────── */

function corsHeaders(origen: string | null): Record<string, string> {
  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
  // Se devuelve el origen exacto (nunca "*"), y solo si está en la allowlist.
  if (origen && ORIGENES_PERMITIDOS.includes(origen)) {
    headers["Access-Control-Allow-Origin"] = origen;
  }
  return headers;
}

function responder(cuerpo: unknown, status: number, cors: Record<string, string>): Response {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: {
      ...cors,
      "Content-Type": "application/json; charset=utf-8",
      "Cache-Control": "no-store",
    },
  });
}

function leerClaim(jwt: string, nombre: string): unknown {
  try {
    const partes = jwt.split(".");
    if (partes.length < 2) return undefined;
    const base64 = partes[1].replace(/-/g, "+").replace(/_/g, "/");
    const relleno = base64 + "=".repeat((4 - (base64.length % 4)) % 4);
    const payload = JSON.parse(atob(relleno));
    return payload ? payload[nombre] : undefined;
  } catch {
    return undefined;
  }
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/* ────────────────────────────── Handler ────────────────────────────── */

Deno.serve(async (req: Request) => {
  const origen = req.headers.get("origin");

  // 0) CORS preflight
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders(origen) });
  }
  if (req.method !== "POST") {
    return responder({ error: "metodo_no_permitido" }, 405, corsHeaders(origen));
  }
  if (origen && !ORIGENES_PERMITIDOS.includes(origen)) {
    console.warn("impersonate · origen no permitido:", origen);
    return responder({ error: "origen_no_permitido" }, 403, corsHeaders(origen));
  }

  const cors = corsHeaders(origen);

  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    console.error("impersonate · faltan SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY");
    return responder({ error: "config_faltante" }, 500, cors);
  }

  // 1) Token del SuperAdmin
  const authHeader = req.headers.get("authorization") || "";
  const token = authHeader.toLowerCase().startsWith("bearer ")
    ? authHeader.slice(7).trim()
    : "";
  if (!token) return responder({ error: "falta_token" }, 401, cors);

  const supabaseAuth = createClient(SUPABASE_URL, PUBLISHABLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  // 2) Validación del JWT con la publishable key
  const { data: userData, error: userError } = await supabaseAuth.auth.getUser(token);
  if (userError || !userData?.user) {
    console.warn("impersonate · JWT inválido:", userError?.message);
    return responder({ error: "token_invalido" }, 401, cors);
  }
  const adminUser = userData.user;

  // 3) Exigir 2FA cuando el token lo declara explícitamente (aal1 = sin 2FA)
  if (EXIGIR_2FA) {
    const aal = String(leerClaim(token, "aal") || "").toLowerCase();
    if (aal === "aal1") {
      console.warn("impersonate · se requiere AAL2:", adminUser.id);
      return responder({ error: "se_requiere_2fa" }, 403, cors);
    }
  }

  // ── Auditoría (nunca hacer fallar la request por un error de auditoría) ──
  const ip = (
    req.headers.get("x-forwarded-for") ||
    req.headers.get("cf-connecting-ip") ||
    ""
  ).split(",")[0].trim() || null;
  const userAgent = (req.headers.get("user-agent") || "").slice(0, 300);
  let salonId: string | null = null;

  const auditar = async (
    accion: "impersonar" | "impersonar_fallido",
    detalle: Record<string, unknown>,
  ) => {
    try {
      const { error } = await supabaseAdmin.from("auditoria_admin").insert({
        admin_id: adminUser.id,
        salon_id: salonId,
        accion,
        detalle,
        ip,
        user_agent: userAgent,
      });
      if (error) console.error("impersonate · auditoría:", error.message);
    } catch (e) {
      console.error("impersonate · auditoría:", e);
    }
  };

  const fallo = async (
    status: number,
    error: string,
    extra: Record<string, unknown> = {},
  ): Promise<Response> => {
    await auditar("impersonar_fallido", { motivo: error, ...extra });
    return responder({ error }, status, cors);
  };

  // 4) ¿Es SuperAdmin? (service_role, consulta directa)
  const { data: superAdmin, error: superError } = await supabaseAdmin
    .from("super_admins")
    .select("user_id")
    .eq("user_id", adminUser.id)
    .maybeSingle();

  if (superError) {
    console.error("impersonate · super_admins:", superError.message);
    return responder({ error: "error_interno" }, 500, cors);
  }
  if (!superAdmin) {
    console.warn("impersonate · usuario sin permisos:", adminUser.id);
    return await fallo(403, "no_autorizado");
  }

  // 5) Body
  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    return await fallo(400, "json_invalido");
  }

  const salonIdSolicitado = typeof body.salon_id === "string" ? body.salon_id.trim() : "";
  if (!UUID.test(salonIdSolicitado)) {
    return await fallo(400, "salon_id_invalido");
  }

  // 5b) I49 · user_id opcional: impersonar a una empleada puntual
  const userIdSolicitado = typeof body.user_id === "string" ? body.user_id.trim() : "";
  if (userIdSolicitado && !UUID.test(userIdSolicitado)) {
    return await fallo(400, "user_id_invalido");
  }

  // 6) redirect_to: solo http(s) y solo orígenes de la allowlist
  let redirectTo = typeof body.redirect_to === "string" ? body.redirect_to.trim() : "";
  if (!redirectTo) {
    if (!SITE_URL) return await fallo(400, "redirect_to_requerido");
    redirectTo = new URL("index.html?soporte=1", SITE_URL + "/").href;
  }
  let urlRedirect: URL;
  try {
    urlRedirect = new URL(redirectTo);
  } catch {
    return await fallo(400, "redirect_invalido");
  }
  if (urlRedirect.protocol !== "https:" && urlRedirect.protocol !== "http:") {
    return await fallo(400, "redirect_invalido");
  }
  if (!ORIGENES_PERMITIDOS.includes(urlRedirect.origin)) {
    return await fallo(403, "redirect_origen_no_permitido", { origen: urlRedirect.origin });
  }
  redirectTo = urlRedirect.href;

  // 7) El salón tiene que existir
  const { data: salon, error: salonError } = await supabaseAdmin
    .from("salones")
    .select("id, nombre, activo")
    .eq("id", salonIdSolicitado)
    .maybeSingle();

  if (salonError) {
    console.error("impersonate · salones:", salonError.message);
    return responder({ error: "error_interno" }, 500, cors);
  }
  if (!salon) {
    return await fallo(404, "salon_no_encontrado", { salon_id: salonIdSolicitado });
  }
  salonId = salon.id;

  // 8) Rate limit: máximo N intentos por admin en la última hora
  const desde = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  const { count, error: rateError } = await supabaseAdmin
    .from("auditoria_admin")
    .select("id", { count: "exact", head: true })
    .eq("admin_id", adminUser.id)
    .in("accion", ["impersonar", "impersonar_fallido"])
    .gte("creado_en", desde);

  if (rateError) {
    // Fail-open: el rate limit no es la barrera de seguridad principal.
    console.warn("impersonate · rate limit no disponible:", rateError.message);
  } else if ((count ?? 0) >= MAX_POR_HORA) {
    return await fallo(429, "demasiadas_impersonaciones", { intentos: count });
  }

  // 9) Objetivo: el user_id pedido (validado como miembro) o la dueña
  let objetivoId = "";

  if (userIdSolicitado) {
    const { data: miembro, error: miembroError } = await supabaseAdmin
      .from("miembros_salon")
      .select("user_id, activo")
      .eq("salon_id", salon.id)
      .eq("user_id", userIdSolicitado)
      .maybeSingle();

    if (miembroError) {
      console.error("impersonate · miembro:", miembroError.message);
      return responder({ error: "error_interno" }, 500, cors);
    }
    if (!miembro) {
      return await fallo(404, "usuario_no_es_del_salon", { salon: salon.nombre });
    }
    if (miembro.activo === false) {
      return await fallo(409, "usuario_inactivo", { salon: salon.nombre });
    }
    objetivoId = miembro.user_id;
  } else {
    const { data: miembros, error: miembrosError } = await supabaseAdmin
      .from("miembros_salon")
      .select("user_id, activo")
      .eq("salon_id", salon.id)
      .eq("rol", "owner")
      .order("creado_en", { ascending: true })
      .limit(10);

    if (miembrosError) {
      console.error("impersonate · miembros_salon:", miembrosError.message);
      return responder({ error: "error_interno" }, 500, cors);
    }

    const lista = miembros ?? [];
    const dueno = lista.find((m) => m.activo !== false);
    if (!dueno) {
      const hayInactivo = lista.length > 0;
      return await fallo(
        hayInactivo ? 409 : 404,
        hayInactivo ? "dueno_inactivo" : "sin_dueno",
        { salon: salon.nombre },
      );
    }
    objetivoId = dueno.user_id;
  }

  // 10) No se impersona a otro SuperAdmin
  const { data: objetivoSuper } = await supabaseAdmin
    .from("super_admins")
    .select("user_id")
    .eq("user_id", objetivoId)
    .maybeSingle();

  if (objetivoSuper) {
    return await fallo(403, "objetivo_superadmin", { salon: salon.nombre });
  }

  // 11) Email del objetivo (desde Auth, nunca desde el body)
  const { data: objetivoAuth, error: objetivoError } = await supabaseAdmin.auth.admin
    .getUserById(objetivoId);

  if (objetivoError || !objetivoAuth?.user?.email) {
    console.error("impersonate · getUserById:", objetivoError?.message || "sin email");
    return await fallo(409, "objetivo_sin_email", { salon: salon.nombre });
  }
  const emailObjetivo = objetivoAuth.user.email;

  // 12) Magic link
  const { data: linkData, error: linkError } = await supabaseAdmin.auth.admin.generateLink({
    type: "magiclink",
    email: emailObjetivo,
    options: { redirectTo },
  });

  if (linkError) {
    const mensaje = String(linkError.message || "");
    console.error("impersonate · generateLink:", mensaje);
    const esRedirect = /redirect/i.test(mensaje);
    return await fallo(
      esRedirect ? 400 : 502,
      esRedirect ? "redirect_no_permitido_en_auth" : "generate_link_fallido",
      { detalle: mensaje.slice(0, 300), salon: salon.nombre },
    );
  }

  const actionLink = linkData?.properties?.action_link;
  // I51: el token_hash permite canjear el enlace con verifyOtp (sin PKCE).
  const hashedToken = linkData?.properties?.hashed_token;
  if (!actionLink && !hashedToken) {
    console.error("impersonate · generateLink sin action_link ni token_hash");
    return await fallo(502, "link_sin_url", { salon: salon.nombre });
  }

  // 13) Auditoría del éxito (sin el link ni tokens)
  await auditar("impersonar", {
    salon: salon.nombre,
    salon_activo: salon.activo !== false,
    objetivo: emailObjetivo, objetivo_id: objetivoId,
    redirect_to: redirectTo,
    via: hashedToken ? "token_hash" : "action_link",
  });

  console.log("impersonate · ok", { admin: adminUser.id, salon: salon.id });

  return responder(
    {
      ok: true,
      url: actionLink,
      token_hash: hashedToken || null,
      type: "magiclink",
      salon: { id: salon.id, nombre: salon.nombre },
    },
    200,
    cors,
  );
});
