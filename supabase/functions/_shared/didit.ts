// Verificación de identidad con Didit. Lo usan identity-check (la app pide una
// sesión) y didit-webhook (Didit avisa el resultado). Ver supabase/functions/README.md.
//
// Reglas:
// - Solo sandbox: resultados simulados, sin costo. El modo real está cerrado en el
//   código (LIVE_ENABLED); abrirlo pide un cambio revisado y la autorización del
//   dueño. Además, la base (hmy_cost_gate) frena todo uso real que no autorizó.
// - El resultado de Didit es una señal para el equipo: no aprueba a nadie.
// - A la base llegan solo estado, puntajes y códigos de aviso; nunca nombres,
//   fechas de nacimiento, números de documento ni imágenes.
// - Con una decisión final, la sesión se borra en Didit (y con ella la plantilla
//   facial, que así sale también del entrenamiento de sus modelos).
//
// Se prueba con Node (didit.test.ts) y corre en Supabase Edge Functions.

export type Env = Record<string, string | undefined>;
export type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

export interface Result {
  status: number;
  body: Record<string, unknown>;
}

const DIDIT = 'https://verification.didit.me';
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;
// Única dirección del enlace de Didit para el profesional, según
// docs.didit.me/sessions-api/create-session (enlace verify.didit.me/{language}/session/{token}, siempre https).
// No usamos dominio propio (white-label); si algún día se usa, se agrega aquí con revisión.
const LINK_HOST = 'verify.didit.me';

/** Un enlace de Didit válido: https, verify.didit.me, sin usuario, contraseña ni puerto. */
export function diditLink(value: unknown): string | null {
  if (typeof value !== 'string' || value.length > 2048) return null;
  let u: URL;
  try {
    u = new URL(value);
  } catch {
    return null;
  }
  if (u.protocol !== 'https:' || u.hostname !== LINK_HOST || u.username || u.password || u.port) return null;
  return u.href;
}
const enc = new TextEncoder();

const error = (status: number, code: string): Result => ({ status, body: { error: code } });

// ---------------------------------------------------------------------------
// Firma de los avisos de Didit (X-Signature-V2)
// ---------------------------------------------------------------------------
function sortKeysDeep(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(sortKeysDeep);
  if (value !== null && typeof value === 'object') {
    const out: Record<string, unknown> = {};
    for (const k of Object.keys(value as Record<string, unknown>).sort()) {
      out[k] = sortKeysDeep((value as Record<string, unknown>)[k]);
    }
    return out;
  }
  return value;
}

/** JSON con claves ordenadas y sin espacios, como lo firma Didit. */
export function canonicalJson(value: unknown): string {
  return JSON.stringify(sortKeysDeep(value));
}

export async function hmacHex(secret: string, data: string): Promise<string> {
  const key = await crypto.subtle.importKey('raw', enc.encode(secret), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  const sig = new Uint8Array(await crypto.subtle.sign('HMAC', key, enc.encode(data)));
  return Array.from(sig, (b) => b.toString(16).padStart(2, '0')).join('');
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export async function verifyDiditSignature(
  secret: string,
  headers: Headers,
  rawBody: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<boolean> {
  const ts = headers.get('x-timestamp');
  // Más de 5 minutos de diferencia: se descarta (evita reenvíos viejos).
  if (!ts || !/^\d+$/.test(ts) || Math.abs(nowSeconds - Number(ts)) > 300) return false;
  let parsed: unknown;
  try {
    parsed = JSON.parse(rawBody);
  } catch {
    return false;
  }
  const v2 = headers.get('x-signature-v2');
  const raw = headers.get('x-signature');
  const signed =
    (!!v2 && timingSafeEqual(v2.toLowerCase(), await hmacHex(secret, canonicalJson(parsed)))) ||
    (!!raw && timingSafeEqual(raw.toLowerCase(), await hmacHex(secret, rawBody)));
  if (!signed) return false;
  // X-Timestamp no va firmado: quien copie un aviso podría cambiarlo. El
  // "timestamp" del cuerpo sí va firmado, así que también debe ser reciente.
  const bodyTs = (parsed as Record<string, unknown> | null)?.timestamp;
  if (bodyTs !== undefined && bodyTs !== null) {
    const n = Number(bodyTs);
    if (!Number.isFinite(n) || Math.abs(nowSeconds - n) > 300) return false;
  }
  return true;
}

// ---------------------------------------------------------------------------
// Lo único que se guarda del resultado
// ---------------------------------------------------------------------------
interface Decision {
  status?: string;
  id_verifications?: { status?: string; document_type?: string; warnings?: unknown[] }[];
  liveness_checks?: { score?: number; warnings?: unknown[] }[];
  face_matches?: { score?: number; warnings?: unknown[] }[];
}

function warningCodes(list: unknown[] | undefined): string[] {
  return (list ?? [])
    .map((w) => (typeof w === 'string' ? w : ((w as Record<string, unknown>)?.risk ?? (w as Record<string, unknown>)?.code)))
    .filter((w): w is string => typeof w === 'string' && /^[A-Z0-9_]{2,80}$/.test(w));
}

export function reduceDecision(decision: Decision | undefined | null): Record<string, unknown> {
  if (!decision) return {};
  const idv = decision.id_verifications?.[0];
  const live = decision.liveness_checks?.[0];
  const face = decision.face_matches?.[0];
  const out: Record<string, unknown> = {
    warnings: [
      ...warningCodes(idv?.warnings),
      ...warningCodes(live?.warnings),
      ...warningCodes(face?.warnings),
    ],
  };
  if (typeof idv?.document_type === 'string') out.document_type = idv.document_type;
  if (typeof idv?.status === 'string') out.id_document_status = idv.status;
  if (typeof live?.score === 'number') out.liveness_score = live.score;
  if (typeof face?.score === 'number') out.face_match_score = face.score;
  return out;
}

const FINAL = new Set(['Approved', 'Declined', 'Expired', 'Kyc Expired', 'Abandoned']);

// ---------------------------------------------------------------------------
// Llamadas a Supabase y a Didit
// ---------------------------------------------------------------------------
export async function rpc(env: Env, fetchFn: Fetch, fn: string, args: Record<string, unknown>) {
  const url = env.SUPABASE_URL;
  const key = env.SUPABASE_SERVICE_ROLE_KEY;
  if (!url || !key) return { ok: false, data: null };
  try {
    const res = await fetchFn(`${url}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: { apikey: key, Authorization: `Bearer ${key}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(args),
    });
    if (!res.ok) return { ok: false, data: null };
    const text = await res.text();
    return { ok: true, data: text ? JSON.parse(text) : null };
  } catch {
    return { ok: false, data: null };
  }
}

async function currentUser(env: Env, fetchFn: Fetch, authHeader: string | null): Promise<string | null> {
  if (!authHeader?.startsWith('Bearer ') || !env.SUPABASE_URL || !env.SUPABASE_ANON_KEY) return null;
  try {
    const res = await fetchFn(`${env.SUPABASE_URL}/auth/v1/user`, {
      headers: { apikey: env.SUPABASE_ANON_KEY, Authorization: authHeader },
    });
    if (!res.ok) return null;
    const user = (await res.json()) as { id?: string };
    return typeof user.id === 'string' ? user.id : null;
  } catch {
    return null;
  }
}

// El modo real está cerrado: ningún secreto lo abre. Para usar Didit en real hay
// que cambiar esta línea en un PR aprobado por el dueño.
export const LIVE_ENABLED = false;

const isSandbox = (env: Env) => !LIVE_ENABLED || env.DIDIT_SANDBOX !== 'false';
/** Pedir modo real (DIDIT_SANDBOX=false) con el modo real cerrado: no se llama a Didit. */
const liveRequestedButLocked = (env: Env) => !LIVE_ENABLED && env.DIDIT_SANDBOX === 'false';

async function deleteSession(env: Env, fetchFn: Fetch, sessionId: string): Promise<boolean> {
  try {
    const res = await fetchFn(`${DIDIT}/v3/session/${encodeURIComponent(sessionId)}/delete/`, {
      method: 'DELETE',
      headers: { 'x-api-key': env.DIDIT_API_KEY ?? '' },
    });
    // 404: ya no existe en Didit.
    return res.ok || res.status === 404;
  } catch {
    return false;
  }
}

/** Guarda el resultado y, si es final, borra la sesión en Didit. */
/** Espera entre intentos cuando la sesión aún no está guardada (las pruebas la bajan a 0). */
export let retryDelayMs = 1500;
export function setRetryDelayForTests(ms: number) {
  retryDelayMs = ms;
}

async function applyDecision(
  env: Env,
  fetchFn: Fetch,
  sessionId: string,
  status: string,
  decision: Decision | null | undefined,
  eventId: string | null,
  sandbox: boolean,
): Promise<boolean> {
  const args = {
    p_session_id: sessionId,
    p_status: status,
    p_details: reduceDecision(decision),
    p_event_id: eventId,
    p_sandbox: sandbox,
  };
  let saved = await rpc(env, fetchFn, 'hmy_identity_decision', args);
  // Didit avisa "Not Started" apenas crea la sesión, a veces antes de que
  // identity-check alcance a guardarla. Se espera un poco; si sigue sin
  // aparecer, 500 para que Didit reintente.
  for (let i = 0; i < 3 && saved.ok && (saved.data as { reason?: string } | null)?.reason === 'unknown_session'; i++) {
    await new Promise((r) => setTimeout(r, retryDelayMs));
    saved = await rpc(env, fetchFn, 'hmy_identity_decision', args);
  }
  if (!saved.ok || (saved.data as { reason?: string } | null)?.reason === 'unknown_session') return false;
  if (FINAL.has(status) && (await deleteSession(env, fetchFn, sessionId))) {
    await rpc(env, fetchFn, 'hmy_identity_deleted', { p_session_id: sessionId });
  }
  return true;
}

// ---------------------------------------------------------------------------
// identity-check: el profesional pide (o retoma) su verificación
// ---------------------------------------------------------------------------
type Gate = { allowed: boolean; reason?: string; resume?: boolean; id?: number; verification_url?: string };
type DiditSession = {
  session_id?: unknown;
  url?: unknown;
  verification_url?: unknown;
  status?: unknown;
  vendor_data?: unknown;
  workflow_id?: unknown;
};

/**
 * Borra en Didit una sesión que no quedó enlazada, solo si es claramente la que
 * acabamos de crear: id UUID, Didit dice que es de este profesional y de este
 * flujo, todavía "Not Started", y la base confirma que ningún otro intento la
 * usa. Si algo no se puede confirmar, no se borra (Didit la devuelve otra vez
 * al próximo intento del mismo profesional).
 */
async function discardUnlinked(
  env: Env,
  fetchFn: Fetch,
  checkId: number | undefined,
  sessionId: string,
  session: DiditSession,
  user: string,
  workflowId: string,
): Promise<'deleted' | 'kept' | 'delete_failed'> {
  const fresh =
    UUID.test(sessionId) &&
    session.vendor_data === user &&
    typeof session.workflow_id === 'string' &&
    session.workflow_id.toLowerCase() === workflowId.toLowerCase() &&
    session.status === 'Not Started';
  if (!fresh) return 'kept';
  const free = await rpc(env, fetchFn, 'hmy_identity_session_free', { p_check: checkId, p_session_id: sessionId });
  if (!free.ok || free.data !== true) return 'kept';
  return (await deleteSession(env, fetchFn, sessionId)) ? 'deleted' : 'delete_failed';
}

export async function handleStart(req: Request, env: Env, fetchFn: Fetch): Promise<Result> {
  const user = await currentUser(env, fetchFn, req.headers.get('authorization'));
  if (!user) return error(401, 'HMY_AUTH_REQUIRED');
  if (liveRequestedButLocked(env)) return error(503, 'HMY_IDENTITY_LIVE_LOCKED');
  const sandbox = isSandbox(env);
  let g: Gate | null = null;
  // Dos vueltas como máximo: si el enlace guardado no es de Didit, se descarta y se pide uno nuevo.
  for (let round = 0; round < 2; round++) {
    const gate = await rpc(env, fetchFn, 'hmy_identity_begin', { p_user: user, p_sandbox: sandbox });
    if (!gate.ok) return error(500, 'HMY_IDENTITY_UNAVAILABLE');
    g = gate.data as Gate;
    if (!g.allowed) {
      const code = {
        no_application: 'HMY_NO_APPLICATION',
        invalid_status: 'HMY_INVALID_STATUS',
        already_approved: 'HMY_IDENTITY_ALREADY_APPROVED',
        attempt_limit: 'HMY_IDENTITY_ATTEMPT_LIMIT',
      }[g.reason ?? ''];
      // Plan gratis agotado, tope o proveedor apagado: no se cobra, se espera.
      return error(code ? 400 : 503, code ?? 'HMY_IDENTITY_PAUSED');
    }
    if (!g.resume) break;
    // Un enlace guardado se vuelve a revisar antes de entregarlo: nunca sale uno que no sea de Didit.
    const saved = diditLink(g.verification_url);
    if (saved) return { status: 200, body: { verification_url: saved, sandbox } };
    console.error('HMY_IDENTITY_BAD_SAVED_LINK');
    const forgot = await rpc(env, fetchFn, 'hmy_identity_forget_link', { p_check: g.id });
    if (!forgot.ok || round === 1) return error(500, 'HMY_IDENTITY_UNAVAILABLE');
  }
  if (!g) return error(500, 'HMY_IDENTITY_UNAVAILABLE');

  const workflowId = (env.DIDIT_WORKFLOW_ID ?? '').trim();
  if (!env.DIDIT_API_KEY || !workflowId) {
    await rpc(env, fetchFn, 'hmy_identity_failed', { p_check: g.id });
    return error(503, 'HMY_IDENTITY_OFF');
  }
  // El id de un flujo de Didit es un UUID (Console > Workflows). Un nombre o un
  // texto copiado de más se detecta aquí, sin llamar a Didit.
  if (!UUID.test(workflowId)) {
    await rpc(env, fetchFn, 'hmy_identity_failed', { p_check: g.id });
    return error(503, 'HMY_IDENTITY_BAD_WORKFLOW_ID');
  }
  // Didit responde 201 con { session_id, url, session_token, ... }: el enlace es "url".
  // Al registro de la función solo van un código propio y el código HTTP: nunca
  // el cuerpo de Didit, mensajes de error, claves, tokens ni datos de la persona.
  let session: DiditSession = {};
  let diditStatus = 0;
  let failure = '';
  try {
    const res = await fetchFn(`${DIDIT}/v3/session/`, {
      method: 'POST',
      headers: { 'x-api-key': env.DIDIT_API_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        workflow_id: workflowId,
        // Solo el id interno; nunca el nombre ni el carnet.
        vendor_data: user,
        ...(env.DIDIT_CALLBACK_URL ? { callback: env.DIDIT_CALLBACK_URL } : {}),
      }),
    });
    diditStatus = res.status;
    if (!res.ok) {
      failure = 'didit_http_error';
    } else {
      try {
        const body = await res.json();
        if (body && typeof body === 'object') session = body;
      } catch {
        failure = 'didit_bad_json';
      }
    }
  } catch {
    failure = 'didit_unreachable';
  }
  const sessionId = typeof session.session_id === 'string' && session.session_id ? session.session_id : null;
  // Cada campo se revisa por separado: un "url" malo no impide usar un verification_url bueno.
  const link = diditLink(session.url) ?? diditLink(session.verification_url);
  if (!sessionId || !link) {
    if (!failure) failure = sessionId ? 'didit_bad_link' : 'didit_missing_fields';
    // Hay sesión pero no un enlace válido: no sirve, se intenta borrar si es la nuestra.
    const cleanup = sessionId && !link
      ? await discardUnlinked(env, fetchFn, g.id, sessionId, session, user, workflowId)
      : 'none';
    console.error(`HMY_IDENTITY_SEND_FAILED code=${failure} didit_status=${diditStatus} cleanup=${cleanup}`);
    await rpc(env, fetchFn, 'hmy_identity_failed', { p_check: g.id });
    // Solo el código HTTP de Didit, para saber si es la clave (401/403) o el flujo (400/404).
    return { status: 502, body: { error: 'HMY_IDENTITY_SEND_FAILED', reason: failure, didit_status: diditStatus } };
  }
  // Didit devuelve la misma sesión abierta si el profesional ya tenía una (mismo
  // flujo y vendor_data). La base la enlaza al intento que ya la tenía en vez de
  // fallar, y nunca acepta la sesión de otro profesional.
  const saved = await rpc(env, fetchFn, 'hmy_identity_attach', {
    p_check: g.id,
    p_session_id: sessionId,
    p_url: link,
  });
  const attached = saved.data as { saved?: boolean; reason?: string } | null;
  if (!saved.ok || attached?.saved !== true) {
    const reason = saved.ok ? (attached?.reason ?? 'unknown') : 'db_error';
    const cleanup = await discardUnlinked(env, fetchFn, g.id, sessionId, session, user, workflowId);
    await rpc(env, fetchFn, 'hmy_identity_failed', { p_check: g.id });
    console.error(`HMY_IDENTITY_UNAVAILABLE code=session_not_saved reason=${reason} cleanup=${cleanup}`);
    return error(500, 'HMY_IDENTITY_UNAVAILABLE');
  }
  return { status: 200, body: { verification_url: link, sandbox } };
}

// ---------------------------------------------------------------------------
// didit-webhook: Didit avisa un cambio de estado
// ---------------------------------------------------------------------------
export async function handleWebhook(req: Request, env: Env, fetchFn: Fetch): Promise<Result> {
  const secret = env.DIDIT_WEBHOOK_SECRET;
  if (!secret) return error(503, 'HMY_IDENTITY_OFF');
  if (liveRequestedButLocked(env)) return error(503, 'HMY_IDENTITY_LIVE_LOCKED');
  const raw = await req.text();
  if (!(await verifyDiditSignature(secret, req.headers, raw))) return error(401, 'HMY_BAD_SIGNATURE');
  const p = JSON.parse(raw) as {
    event_id?: string;
    webhook_type?: string;
    environment?: string;
    session_id?: string;
    status?: string;
    decision?: Decision;
  };
  if (!p.session_id || !p.status) return { status: 200, body: { ignored: true } };
  // El entorno lo dice Didit, no nosotros: una prueba nunca pasa por real.
  const sandbox = p.environment !== 'live';
  if (sandbox !== isSandbox(env)) return error(400, 'HMY_ENVIRONMENT_MISMATCH');
  const ok = await applyDecision(env, fetchFn, p.session_id, p.status, p.decision, p.event_id ?? null, sandbox);
  // 500: Didit reintenta (solo 2 veces; además está la revisión periódica).
  return ok ? { status: 200, body: {} } : error(500, 'HMY_IDENTITY_UNAVAILABLE');
}

// ---------------------------------------------------------------------------
// Revisión periódica (la llama pg_cron o el equipo con la clave del servidor):
// consulta las sesiones sin respuesta y borra en Didit las ya decididas.
// ---------------------------------------------------------------------------
export async function handleSync(req: Request, env: Env, fetchFn: Fetch): Promise<Result> {
  const key = env.SUPABASE_SERVICE_ROLE_KEY;
  if (!key || !timingSafeEqual(req.headers.get('authorization') ?? '', `Bearer ${key}`)) return error(401, 'HMY_FORBIDDEN');
  if (!env.DIDIT_API_KEY) return error(503, 'HMY_IDENTITY_OFF');
  if (liveRequestedButLocked(env)) return error(503, 'HMY_IDENTITY_LIVE_LOCKED');
  const pending = await rpc(env, fetchFn, 'hmy_identity_pending', { p_limit: 20 });
  if (!pending.ok) return error(500, 'HMY_IDENTITY_UNAVAILABLE');
  let checked = 0;
  for (const s of (pending.data ?? []) as { session_id: string; sandbox: boolean; status: string }[]) {
    if (s.sandbox !== isSandbox(env)) continue;
    if (['approved', 'declined', 'expired', 'abandoned'].includes(s.status)) {
      if (await deleteSession(env, fetchFn, s.session_id)) {
        await rpc(env, fetchFn, 'hmy_identity_deleted', { p_session_id: s.session_id });
      }
      checked++;
      continue;
    }
    try {
      const res = await fetchFn(`${DIDIT}/v3/session/${encodeURIComponent(s.session_id)}/decision/`, {
        headers: { 'x-api-key': env.DIDIT_API_KEY },
      });
      if (!res.ok) continue;
      const d = (await res.json()) as Decision & { status?: string };
      if (d.status) await applyDecision(env, fetchFn, s.session_id, d.status, d, null, s.sandbox);
      checked++;
    } catch {
      // Se intenta en la próxima vuelta.
    }
  }
  return { status: 200, body: { checked } };
}
