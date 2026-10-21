// Lógica del servicio que manda el código de 6 dígitos por WhatsApp o SMS
// ("Send SMS hook" de Supabase Auth). Supabase genera, vence y verifica el
// código; este servicio solo lo entrega. Sin credenciales de un proveedor
// configuradas, no envía nada y responde con un error claro (nunca simula
// un envío).
//
// Se prueba con Node (send-otp.test.ts) y corre en Supabase Edge Functions (index.ts).

export type Env = Record<string, string | undefined>;
export type Fetch = (url: string, init?: RequestInit) => Promise<Response>;

export interface HookResult {
  status: number;
  body: Record<string, unknown>;
}

const enc = new TextEncoder();

function b64decode(s: string): Uint8Array<ArrayBuffer> {
  const bin = atob(s);
  return Uint8Array.from(bin, (c) => c.charCodeAt(0));
}

function b64encode(bytes: ArrayBuffer): string {
  let bin = '';
  for (const b of new Uint8Array(bytes)) bin += String.fromCharCode(b);
  return btoa(bin);
}

/** Firma "Standard Webhooks" con la que Supabase llama al servicio. */
export async function sign(secret: string, id: string, timestamp: string, body: string): Promise<string> {
  const raw = secret.replace(/^v1,/, '').replace(/^whsec_/, '');
  const key = await crypto.subtle.importKey('raw', b64decode(raw), { name: 'HMAC', hash: 'SHA-256' }, false, ['sign']);
  return b64encode(await crypto.subtle.sign('HMAC', key, enc.encode(`${id}.${timestamp}.${body}`)));
}

export async function verifySignature(
  secret: string,
  headers: Headers,
  body: string,
  nowSeconds = Math.floor(Date.now() / 1000),
): Promise<boolean> {
  const id = headers.get('webhook-id');
  const ts = headers.get('webhook-timestamp');
  const sigs = headers.get('webhook-signature');
  if (!id || !ts || !sigs) return false;
  // Más de 5 minutos de diferencia: se descarta (evita reenvíos viejos).
  if (!/^\d+$/.test(ts) || Math.abs(nowSeconds - Number(ts)) > 300) return false;
  const expected = await sign(secret, id, ts, body);
  return sigs.split(' ').some((s) => {
    const [version, value] = s.split(',');
    return version === 'v1' && value !== undefined && timingSafeEqual(value, expected);
  });
}

function timingSafeEqual(a: string, b: string): boolean {
  if (a.length !== b.length) return false;
  let diff = 0;
  for (let i = 0; i < a.length; i++) diff |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return diff === 0;
}

const error = (status: number, message: string): HookResult => ({
  status,
  body: { error: { http_code: status, message } },
});

/**
 * Estado HTTP con el que responde la función. Supabase Auth solo lee el
 * mensaje de error del cuerpo cuando la respuesta es 200; con 400, 429 o 503
 * muestra un error genérico ("Invalid payload sent to hook") y la app no sabe
 * qué pasó. Por eso los rechazos van con 200 y el código real en
 * error.http_code. Una llamada sin firma válida sigue recibiendo 401.
 */
export const httpStatus = (result: HookResult): number => (result.status === 401 ? 401 : 200);

/** Lo que pasa cuando Supabase pide entregar un código. */
export async function handleHook(req: Request, env: Env, fetchFn: Fetch, nowSeconds?: number): Promise<HookResult> {
  const secret = env.SEND_SMS_HOOK_SECRET;
  if (!secret) return error(500, 'HMY_OTP_NOT_CONFIGURED');
  const body = await req.text();
  if (!(await verifySignature(secret, req.headers, body, nowSeconds))) return error(401, 'HMY_OTP_BAD_SIGNATURE');

  let payload: { user?: { id?: string; phone?: string }; sms?: { otp?: string; phone?: string } };
  try {
    payload = JSON.parse(body);
  } catch {
    return error(400, 'HMY_OTP_BAD_REQUEST');
  }
  const otp = payload.sms?.otp ?? '';
  const phone = payload.sms?.phone || payload.user?.phone || '';
  if (!/^\d{6}$/.test(otp) || !phone) return error(400, 'HMY_OTP_BAD_REQUEST');

  // Límites por número y en total; también decide el canal que eligió la persona.
  const gate = await rpc(env, fetchFn, 'hmy_otp_gate', { p_phone: phone, p_user: payload.user?.id ?? null });
  if (!gate.ok) return error(500, 'HMY_OTP_UNAVAILABLE');
  const g = gate.data as { allowed: boolean; reason?: string; retry_after?: number; id?: number; channel: string; phone: string };
  if (!g.allowed) {
    if (g.reason === 'too_soon') return error(429, `HMY_OTP_TOO_SOON:${g.retry_after ?? 60}`);
    if (g.reason === 'invalid_phone') return error(400, 'HMY_INVALID_PHONE');
    // Sin autorización de gasto (o tope del mes alcanzado): no se envía ni se cobra.
    if (g.reason === 'budget') return error(503, `HMY_OTP_BUDGET:${g.channel === 'sms' ? 'sms' : 'whatsapp'}`);
    return error(429, 'HMY_OTP_LIMIT');
  }

  const channel = g.channel === 'sms' ? 'sms' : 'whatsapp';
  const sent = channel === 'whatsapp' ? await sendWhatsApp(env, fetchFn, g.phone, otp) : await sendSms(env, fetchFn, g.phone, otp);
  if (g.id !== undefined) {
    await rpc(env, fetchFn, 'hmy_otp_result', {
      p_id: g.id,
      p_delivered: sent.ok,
      p_provider: sent.provider,
      p_error: sent.ok ? null : sent.error,
    });
  }
  if (sent.ok) return { status: 200, body: {} };
  // Sin pasar solo al otro canal: la app ofrece "Probar por SMS" o "por WhatsApp".
  return error(503, sent.provider === 'none' ? `HMY_OTP_CHANNEL_OFF:${channel}` : `HMY_OTP_SEND_FAILED:${channel}`);
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

interface Sent {
  ok: boolean;
  provider: string;
  error?: string;
}

/** WhatsApp Cloud API (Meta) con una plantilla de autenticación aprobada. */
async function sendWhatsApp(env: Env, fetchFn: Fetch, phone: string, otp: string): Promise<Sent> {
  const token = env.WHATSAPP_TOKEN;
  const numberId = env.WHATSAPP_PHONE_NUMBER_ID;
  const template = env.WHATSAPP_TEMPLATE;
  if (!token || !numberId || !template) return { ok: false, provider: 'none', error: 'WhatsApp no configurado' };
  try {
    const res = await fetchFn(`https://graph.facebook.com/v21.0/${numberId}/messages`, {
      method: 'POST',
      headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify({
        messaging_product: 'whatsapp',
        to: phone.replace('+', ''),
        type: 'template',
        template: {
          name: template,
          language: { code: env.WHATSAPP_TEMPLATE_LANG ?? 'es' },
          components: [
            { type: 'body', parameters: [{ type: 'text', text: otp }] },
            { type: 'button', sub_type: 'url', index: '0', parameters: [{ type: 'text', text: otp }] },
          ],
        },
      }),
    });
    return res.ok ? { ok: true, provider: 'whatsapp' } : { ok: false, provider: 'whatsapp', error: `HTTP ${res.status}` };
  } catch (e) {
    return { ok: false, provider: 'whatsapp', error: String(e) };
  }
}

/** SMS por Twilio (u otro proveedor que se agregue aquí). */
async function sendSms(env: Env, fetchFn: Fetch, phone: string, otp: string): Promise<Sent> {
  const sid = env.TWILIO_ACCOUNT_SID;
  const auth = env.TWILIO_AUTH_TOKEN;
  const from = env.TWILIO_MESSAGING_SERVICE_SID ?? env.TWILIO_FROM;
  if (!sid || !auth || !from) return { ok: false, provider: 'none', error: 'SMS no configurado' };
  const form = new URLSearchParams({
    To: phone,
    Body: `Tu código de HandiMan ¡Ya! es ${otp}. Vence en 5 minutos. No lo compartas con nadie.`,
  });
  form.set(from.startsWith('MG') ? 'MessagingServiceSid' : 'From', from);
  try {
    const res = await fetchFn(`https://api.twilio.com/2010-04-01/Accounts/${sid}/Messages.json`, {
      method: 'POST',
      headers: { Authorization: `Basic ${btoa(`${sid}:${auth}`)}`, 'Content-Type': 'application/x-www-form-urlencoded' },
      body: form.toString(),
    });
    return res.ok ? { ok: true, provider: 'twilio' } : { ok: false, provider: 'twilio', error: `HTTP ${res.status}` };
  } catch (e) {
    return { ok: false, provider: 'twilio', error: String(e) };
  }
}
