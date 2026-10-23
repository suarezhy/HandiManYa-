// Lógica del servicio que manda los avisos push por Firebase Cloud Messaging
// (HTTP v1). Android y la web reciben directo de FCM; el iPhone recibe por FCM
// con la clave APNs cargada en Firebase. La base decide qué se manda y con qué
// texto (hmy_push_claim, migración 0045); este servicio solo lo entrega y anota
// el resultado (hmy_push_report). Sin la cuenta de servicio de Firebase no
// reclama nada y responde con un error claro: los avisos quedan en cola y
// nunca se marcan como enviados sin haberlo sido.
//
// Lo llama un webhook de la base (Database → Webhooks, al insertar en
// push_outbox) con el encabezado x-hmy-push-secret. Cada llamada vacía toda la
// cola, así que una llamada perdida se recupera con la siguiente.
//
// Se prueba con Node (send-push.test.ts) y corre en Supabase Edge Functions (index.ts).

export type Env = Record<string, string | undefined>;
export type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

export interface PushResult {
  status: number;
  body: Record<string, unknown>;
}

interface ServiceAccount {
  project_id: string;
  client_email: string;
  private_key: string;
  token_uri?: string;
}

interface Claimed {
  id: number;
  token: string;
  platform: 'android' | 'ios' | 'web';
  title: string;
  body: string;
  data: Record<string, string>;
}

interface Report {
  id: number;
  ok: boolean;
  error?: string;
  retry?: boolean;
  unregistered?: boolean;
}

const enc = new TextEncoder();
const SCOPE = 'https://www.googleapis.com/auth/firebase.messaging';
const DEFAULT_TOKEN_URI = 'https://oauth2.googleapis.com/token';

const fail = (status: number, message: string): PushResult => ({ status, body: { error: message } });

function b64url(bytes: Uint8Array | ArrayBuffer): string {
  let bin = '';
  for (const b of new Uint8Array(bytes)) bin += String.fromCharCode(b);
  return btoa(bin).replace(/\+/g, '-').replace(/\//g, '_').replace(/=+$/, '');
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

export function parseServiceAccount(raw: string | undefined): ServiceAccount | null {
  if (!raw) return null;
  try {
    const sa = JSON.parse(raw);
    if (typeof sa.project_id !== 'string' || typeof sa.client_email !== 'string' || typeof sa.private_key !== 'string') {
      return null;
    }
    return sa;
  } catch {
    return null;
  }
}

/** JWT firmado (RS256) con la clave de la cuenta de servicio, para pedir el token de acceso. */
export async function signedJwt(sa: ServiceAccount, nowSeconds: number): Promise<string> {
  const header = b64url(enc.encode(JSON.stringify({ alg: 'RS256', typ: 'JWT' })));
  const claims = b64url(
    enc.encode(
      JSON.stringify({
        iss: sa.client_email,
        scope: SCOPE,
        aud: sa.token_uri ?? DEFAULT_TOKEN_URI,
        iat: nowSeconds,
        exp: nowSeconds + 3600,
      }),
    ),
  );
  const pem = sa.private_key.replace(/-----[^-]+-----/g, '').replace(/\s+/g, '');
  const der = Uint8Array.from(atob(pem), (c) => c.charCodeAt(0));
  const key = await crypto.subtle.importKey('pkcs8', der, { name: 'RSASSA-PKCS1-v1_5', hash: 'SHA-256' }, false, [
    'sign',
  ]);
  const sig = await crypto.subtle.sign('RSASSA-PKCS1-v1_5', key, enc.encode(`${header}.${claims}`));
  return `${header}.${claims}.${b64url(sig)}`;
}

async function accessToken(sa: ServiceAccount, fetchFn: Fetch, nowSeconds: number): Promise<string | null> {
  try {
    const res = await fetchFn(sa.token_uri ?? DEFAULT_TOKEN_URI, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({
        grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer',
        assertion: await signedJwt(sa, nowSeconds),
      }).toString(),
    });
    if (!res.ok) return null;
    const json = await res.json();
    return typeof json.access_token === 'string' ? json.access_token : null;
  } catch {
    return null;
  }
}

async function rpc(env: Env, fetchFn: Fetch, fn: string, args: Record<string, unknown>) {
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

/** El mensaje de FCM HTTP v1 para un teléfono. */
export function fcmMessage(item: Claimed, webLink?: string): Record<string, unknown> {
  const message: Record<string, unknown> = {
    token: item.token,
    notification: { title: item.title, body: item.body },
    data: item.data,
    android: { priority: 'high', notification: { sound: 'default' } },
    apns: { headers: { 'apns-priority': '10' }, payload: { aps: { sound: 'default' } } },
  };
  if (webLink) message.webpush = { fcm_options: { link: webLink } };
  return { message };
}

/** Qué hacer con la respuesta de FCM: enviado, reintentar o apagar el token. */
export async function classify(id: number, res: Response): Promise<Report> {
  if (res.ok) return { id, ok: true };
  let code = '';
  try {
    const json = await res.json();
    code = json?.error?.details?.find((d: { errorCode?: string }) => d.errorCode)?.errorCode ?? json?.error?.status ?? '';
  } catch {
    // Sin cuerpo legible: se decide por el estado HTTP.
  }
  const error = `${res.status} ${code}`.trim();
  if (code === 'UNREGISTERED' || res.status === 404) return { id, ok: false, error, unregistered: true };
  const retry = res.status === 429 || res.status >= 500 || code === 'UNAVAILABLE' || code === 'INTERNAL';
  return { id, ok: false, error, retry };
}

/** Lo que pasa cuando el webhook de la base avisa que hay avisos en cola. */
export async function handlePush(req: Request, env: Env, fetchFn: Fetch, nowSeconds?: number): Promise<PushResult> {
  const secret = env.PUSH_WEBHOOK_SECRET;
  if (!secret) return fail(500, 'HMY_PUSH_NOT_CONFIGURED');
  const given = req.headers.get('x-hmy-push-secret') ?? '';
  if (!timingSafeEqual(given, secret)) return fail(401, 'HMY_UNAUTHORIZED');

  const sa = parseServiceAccount(env.FCM_SERVICE_ACCOUNT);
  // Sin Firebase configurado no se reclama nada: la cola queda pendiente y veraz.
  if (!sa) return fail(503, 'HMY_PUSH_OFF');
  const now = nowSeconds ?? Math.floor(Date.now() / 1000);
  const token = await accessToken(sa, fetchFn, now);
  if (!token) return fail(502, 'HMY_PUSH_AUTH_FAILED');

  let sent = 0;
  let failed = 0;
  // Hasta 5 tandas de 100 por llamada; lo que quede sale con la próxima llamada.
  for (let round = 0; round < 5; round++) {
    const claimed = await rpc(env, fetchFn, 'hmy_push_claim', { p_limit: 100 });
    if (!claimed.ok) return fail(502, 'HMY_PUSH_DB_FAILED');
    const items = (claimed.data ?? []) as Claimed[];
    if (items.length === 0) break;
    const reports = await Promise.all(
      items.map(async (item) => {
        try {
          const res = await fetchFn(`https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`, {
            method: 'POST',
            headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
            body: JSON.stringify(fcmMessage(item, env.PUSH_WEB_LINK)),
          });
          return await classify(item.id, res);
        } catch {
          return { id: item.id, ok: false, error: 'network', retry: true } as Report;
        }
      }),
    );
    sent += reports.filter((r) => r.ok).length;
    failed += reports.filter((r) => !r.ok).length;
    const reported = await rpc(env, fetchFn, 'hmy_push_report', { p_results: reports });
    if (!reported.ok) return fail(502, 'HMY_PUSH_DB_FAILED');
    if (items.length < 100) break;
  }
  return { status: 200, body: { sent, failed } };
}
