/**
 * ELI M. NAILS · I51 · admin-user
 *
 * Gestión de usuarios desde el God Mode (service_role SOLO aquí, nunca en el frontend).
 *
 * Acciones:
 *   POST { action: "revoke_sessions", user_id }
 *     → invalida todas las sesiones/refresh tokens del usuario.
 *
 * Seguridad (mismas garantías que impersonate):
 *   1) CORS con allowlist de orígenes (nunca "*").
 *   2) JWT del llamador validado con la publishable key.
 *   3) El user_id debe estar en public.super_admins (verificado con service_role).
 *   4) Se exige AAL2 (2FA) cuando el claim `aal` viene presente.
 *   5) Rate limit: N acciones por admin por hora.
 *   6) Todo se audita en public.auditoria_admin (ok y fallido), sin secretos.
 */

import { createClient } from "npm:@supabase/supabase-js@2.45.4";

/* ─────────────────────────── Configuración ───────────────────────────── */

const SUPABASE_URL = (Deno.env.get("SUPABASE_URL") || "").replace(/\\/+$/, "");
const SERVICE_ROLE_KEY = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";

const PUBLISHABLE_KEY =
  Deno.env.get("SUPABASE_PUBLISHABLE_KEY") ||
  Deno.env.get("SUPABASE_ANON_KEY") ||
  "sb_publishable_Y32sTccT1KPn_rKSgCzpOw_1F3RZvK1";

const EXIGIR_2FA = (Deno.env.get("REQUIRE_AAL2") || "true").toLowerCase() !== "false";

const MAX_POR_HORA_RAW = Number(Deno.env.get("ADMIN_USER_MAX_POR_HORA") || "20");
const MAX_POR_HORA = Number.isFinite(MAX_POR_HORA_RAW) && MAX_POR_HORA_RAW > 0
  ? Math.floor(MAX_POR_HORA_RAW)
  : 20;

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
  .map((origen) => origen.trim().replace(/\\/+$/, ""))
  .filter(Boolean);

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/* ──────────────────────────── Utilidades ───────────────────────────── */

function corsHeaders(origen: string | null): Record<string, string> {
  const headers: Record<string, string> = {
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Access-Control-Max-Age": "86400",
    Vary: "Origin",
  };
  if (origen && ORIGENES_PERMITIDOS.includes(origen)) {
    headers["Access-Control-Allow-Origin"] = origen;
  }
  return headers;
}

function responder(cuerpo: unknown, status: number, cors: Record<string, string>): Response {
  return new Response(JSON.stringify(cuerpo), {
    status,
    headers: { ...cors, "Content-Type": "application/json; charset=utf-8", "Cache-Control": "no-store" },
  });
}

// Decodifica un claim del JWT sin validar la firma (ya validamos el token con auth.getUser).
function leerClaim(token: string, claim: string): unknown {
  try {
    const parte = token.split(".")[1];
    if (!parte) return null;
    const json = atob(parte.replace(/-/g, "+").replace(/_/g, "/"));
    const payload = JSON.parse(json);
    return payload ? payload[claim] : null;
  } catch {
    return null;
  }
}

/* ───────────────────────────── Handler ────────────────────────────── */

Deno.serve(async (req: Request) => {
  const origen = req.headers.get("origin");

  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders(origen) });
  }
  if (req.method !== "POST") {
    return responder({ error: "metodo_no_permitido" }, 405, corsHeaders(origen));
  }
  if (origen && !ORIGENES_PERMITIDOS.includes(origen)) {
    return responder({ error: "origen_no_permitido" }, 403, corsHeaders(origen));
  }

  const cors = corsHeaders(origen);

  if (!SUPABASE_URL || !SERVICE_ROLE_KEY) {
    console.error("admin-user · faltan SUPABASE_URL o SUPABASE_SERVICE_ROLE_KEY");
    return responder({ error: "config_faltante" }, 500, cors);
  }

  // 1) Token del SuperAdmin
  const authHeader = req.headers.get("authorization") || "";
  const token = authHeader.toLowerCase().startsWith("bearer ") ? authHeader.slice(7).trim() : "";
  if (!token) return responder({ error: "falta_token" }, 401, cors);

  const supabaseAuth = createClient(SUPABASE_URL, PUBLISHABLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });
  const supabaseAdmin = createClient(SUPABASE_URL, SERVICE_ROLE_KEY, {
    auth: { persistSession: false, autoRefreshToken: false, detectSessionInUrl: false },
  });

  const { data: userData, error: userError } = await supabaseAuth.auth.getUser(token);
  if (userError || !userData?.user) {
    console.warn("admin-user · JWT inválido:", userError?.message);
    return responder({ error: "token_invalido" }, 401, cors);
  }
  const adminUser = userData.user;

  // 2) 2FA
  if (EXIGIR_2FA) {
    const aal = String(leerClaim(token, "aal") || "").toLowerCase();
    if (aal === "aal1") {
      console.warn("admin-user · se requiere AAL2:", adminUser.id);
      return responder({ error: "se_requiere_2fa" }, 403, cors);
    }
  }

  const ip = (req.headers.get("x-forwarded-for") || req.headers.get("cf-connecting-ip") || "")
    .split(",")[0].trim() || null;
  const userAgent = (req.headers.get("user-agent") || "").slice(0, 300);

  const auditar = async (accion: string, detalle: Record<string, unknown>, salonId: string | null) => {
    try {
      const { error } = await supabaseAdmin.from("auditoria_admin").insert({
        admin_id: adminUser.id,
        salon_id: salonId,
        accion,
        detalle,
        ip,
        user_agent: userAgent,
      });
      if (error) console.error("admin-user · auditoría:", error.message);
    } catch (e) {
      console.error("admin-user · auditoría:", e);
    }
  };

  const fallo = async (status: number, error: string, extra: Record<string, unknown> = {}) => {
    await auditar("admin_user_fallido", { error, ...extra }, null);
    return responder({ error, ...extra }, status, cors);
  };

  // 3) Body
  let body: Record<string, unknown> = {};
  try {
    body = await req.json();
  } catch {
    return await fallo(400, "json_invalido");
  }

  const accion = typeof body.action === "string" ? body.action.trim() : "";
  const userId = typeof body.user_id === "string" ? body.user_id.trim() : "";

  if (accion !== "revoke_sessions") return await fallo(400, "accion_desconocida", { accion });
  if (!UUID.test(userId)) return await fallo(400, "user_id_invalido");

  // 4) SuperAdmin
  const { data: esSuper, error: superError } = await supabaseAdmin
    .from("super_admins")
    .select("user_id")
    .eq("user_id", adminUser.id)
    .maybeSingle();

  if (superError) {
    console.error("admin-user · super_admins:", superError.message);
    return responder({ error: "error_interno" }, 500, cors);
  }
  if (!esSuper) {
    console.warn("admin-user · no es superadmin:", adminUser.id);
    return await fallo(403, "no_superadmin");
  }

  // 5) Rate limit por admin
  const desde = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  const { count } = await supabaseAdmin
    .from("auditoria_admin")
    .select("id", { count: "exact", head: true })
    .eq("admin_id", adminUser.id)
    .in("accion", ["logout_forzado", "admin_user_fallido"])
    .gte("creado_en", desde);

  if ((count ?? 0) >= MAX_POR_HORA) {
    return await fallo(429, "demasiadas_acciones", { intentos: count });
  }

  // 6) El objetivo debe existir
  const { data: objetivo, error: objetivoError } = await supabaseAdmin.auth.admin.getUserById(userId);
  if (objetivoError || !objetivo?.user) {
    return await fallo(404, "usuario_no_encontrado");
  }
  if (!objetivo.user.email) {
    return await fallo(409, "usuario_sin_email");
  }

  // 7) No se revocan sesiones de otro SuperAdmin
  const { data: objetivoSuper } = await supabaseAdmin
    .from("super_admins")
    .select("user_id")
    .eq("user_id", userId)
    .maybeSingle();
  if (objetivoSuper) {
    return await fallo(403, "objetivo_superadmin");
  }

  // 8) Revocar sesiones
  //    Endpoint de GoTrue para cerrar todas las sesiones de un usuario.
  //    Si la versión del proyecto no lo soporta, se devuelve el error real.
  let metodo = "gotrue_admin_logout";
  let ok = false;
  let detalleError: string | null = null;

  try {
    const urlRevocar = `${SUPABASE_URL}/auth/v1/admin/users/${encodeURIComponent(userId)}/logout?scope=global`;
    console.log(`Intentando revocar sesiones en: ${urlRevocar}`);
    if (!/^https:\/\/./i.test(urlRevocar)) {
      return await fallo(500, "url_revocar_invalida");
    }
    const respuesta = await fetch(urlRevocar, {
      method: "POST",
      headers: {
        apikey: SERVICE_ROLE_KEY,
        Authorization: `Bearer ${SERVICE_ROLE_KEY}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ scope: "global" }),
    });

    if (respuesta.ok) {
      ok = true;
    } else {
      detalleError = `${respuesta.status} ${(await respuesta.text()).slice(0, 200)}`;
    }
  } catch (e) {
    detalleError = String(e).slice(0, 200);
  }

  if (!ok) {
    // Respaldo: signOut del admin SDK (puede requerir un JWT válido del usuario).
    try {
      const { error } = await supabaseAdmin.auth.admin.signOut(userId, "global");
      if (!error) {
        metodo = "admin_signout";
        ok = true;
      } else if (!detalleError) {
        detalleError = error.message;
      }
    } catch (e) {
      if (!detalleError) detalleError = String(e).slice(0, 200);
    }
  }

  if (!ok) {
    console.error("admin-user · no se pudo revocar:", detalleError);
    return await fallo(502, "revoke_fallido", { detalle: detalleError });
  }

  // 9) Auditoría del éxito (sin tokens)
  await auditar("logout_forzado", {
    objetivo: objetivo.user.email,
    objetivo_id: userId,
    metodo,
  }, null);

  console.log("admin-user · ok", { admin: adminUser.id, objetivo: userId, metodo });

  return responder({ ok: true, metodo, email: objetivo.user.email }, 200, cors);
});
