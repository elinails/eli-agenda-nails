// ============================================================================
// ELI M. NAILS · I66 · Edge Function: admin-backup-trigger
//
// Dispara el workflow de backup de GitHub Actions desde el panel de SuperAdmin
// SIN exponer el token en el frontend (el PAT vive en los secrets de Supabase).
//
// Seguridad:
//   1. Exige un JWT válido (Authorization: Bearer …).
//   2. Verifica que el usuario esté en public.super_admins (con service role).
//   3. Solo entonces llama a la API de GitHub con el PAT del entorno.
//   4. CORS restringido a los orígenes del panel y de la app.
//
// Secrets requeridos (supabase secrets set …):
//   GITHUB_BACKUP_TOKEN  PAT con scope "actions:write" sobre el repo
//   GITHUB_REPO          owner/repo, ej: elinails/eli-agenda-nails
//   GITHUB_WORKFLOW      (opcional) nombre del archivo, default: backup.yml
//   GITHUB_REF           (opcional) rama, default: main
//
// Deploy:
//   supabase functions deploy admin-backup-trigger --no-verify-jwt
//   (el JWT se valida acá adentro, no con la verificación por defecto)
// ============================================================================

import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const ORIGENES = [
  "https://elinails.github.io",
  "https://eli-agenda-nails.vercel.app",
  "http://localhost:3000",
  "http://127.0.0.1:5500",
];

function cors(origen: string | null): Record<string, string> {
  const permitido = origen && (ORIGENES.includes(origen) ||
    /^https:\/\/[a-z0-9-]+\.vercel\.app$/i.test(origen) ||
    /^https:\/\/[a-z0-9-]+\.github\.io$/i.test(origen))
    ? origen
    : ORIGENES[0];
  return {
    "Access-Control-Allow-Origin": permitido,
    "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
    "Access-Control-Allow-Methods": "POST, OPTIONS",
    "Vary": "Origin",
  };
}

function json(cuerpo: unknown, estado: number, origen: string | null) {
  return new Response(JSON.stringify(cuerpo), {
    status: estado,
    headers: { "Content-Type": "application/json; charset=utf-8", ...cors(origen) },
  });
}

Deno.serve(async (req: Request) => {
  const origen = req.headers.get("origin");

  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: cors(origen) });
  }
  if (req.method !== "POST") {
    return json({ error: "metodo_no_permitido" }, 405, origen);
  }

  // ── 1. Sesión ─────────────────────────────────────────────────────────
  const autorizacion = req.headers.get("Authorization") || "";
  const jwt = autorizacion.replace(/^Bearer\s+/i, "").trim();
  if (!jwt) {
    return json({ error: "falta_token" }, 401, origen);
  }

  const url = Deno.env.get("SUPABASE_URL");
  const anon = Deno.env.get("SUPABASE_ANON_KEY");
  const service = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY");
  if (!url || !anon || !service) {
    return json({ error: "config_faltante" }, 500, origen);
  }

  const comoUsuario = createClient(url, anon, {
    global: { headers: { Authorization: `Bearer ${jwt}` } },
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: datosUsuario, error: errorUsuario } = await comoUsuario.auth.getUser();
  if (errorUsuario || !datosUsuario?.user) {
    return json({ error: "token_invalido" }, 401, origen);
  }
  const usuarioId = datosUsuario.user.id;

  // ── 2. ¿Es super admin? ───────────────────────────────────────────────
  const admin = createClient(url, service, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  const { data: esAdmin, error: errorAdmin } = await admin
    .from("super_admins")
    .select("user_id")
    .eq("user_id", usuarioId)
    .limit(1);

  if (errorAdmin) {
    console.error("No se pudo verificar super admin:", errorAdmin.message);
    return json({ error: "error_verificacion" }, 500, origen);
  }
  if (!esAdmin || esAdmin.length === 0) {
    return json({ error: "sin_permisos" }, 403, origen);
  }

  // ── 3. GitHub ─────────────────────────────────────────────────────────
  const token = Deno.env.get("GITHUB_BACKUP_TOKEN");
  const repo = Deno.env.get("GITHUB_REPO");
  const workflow = Deno.env.get("GITHUB_WORKFLOW") || "backup.yml";
  const ref = Deno.env.get("GITHUB_REF") || "main";

  if (!token || !repo) {
    return json(
      { error: "github_sin_configurar", detalle: "Faltan GITHUB_BACKUP_TOKEN y/o GITHUB_REPO en los secrets." },
      500,
      origen,
    );
  }
  if (!/^[\w.-]+\/[\w.-]+$/.test(repo)) {
    return json({ error: "github_repo_invalido" }, 500, origen);
  }

  const destino = `https://api.github.com/repos/${repo}/actions/workflows/${encodeURIComponent(workflow)}/dispatches`;

  let respuesta: Response;
  try {
    respuesta = await fetch(destino, {
      method: "POST",
      headers: {
        "Accept": "application/vnd.github+json",
        "Authorization": `Bearer ${token}`,
        "X-GitHub-Api-Version": "2022-11-28",
        "User-Agent": "eli-god-mode",
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ ref }),
    });
  } catch (error) {
    console.error("Error de red con GitHub:", error);
    return json({ error: "github_red" }, 502, origen);
  }

  // GitHub responde 204 sin cuerpo cuando el disparo fue aceptado.
  if (respuesta.status === 204) {
    console.log(`Backup disparado por ${datosUsuario.user.email} (${workflow}@${ref})`);
    return json({
      ok: true,
      workflow,
      ref,
      repo,
      url: `https://github.com/${repo}/actions/workflows/${workflow}`,
    }, 200, origen);
  }

  const texto = await respuesta.text();
  console.error("GitHub respondió", respuesta.status, texto.slice(0, 300));

  const detalle = respuesta.status === 401
    ? "El token de GitHub no es válido o venció."
    : respuesta.status === 403
      ? "El token no tiene permiso actions:write sobre el repo."
      : respuesta.status === 404
        ? "No se encontró el repo o el workflow (revisá GITHUB_REPO y GITHUB_WORKFLOW)."
        : respuesta.status === 422
          ? "GitHub rechazó la referencia (revisá GITHUB_REF, ej: main)."
          : "GitHub devolvió un error inesperado.";

  return json({ error: "github_error", estado: respuesta.status, detalle }, 502, origen);
});
