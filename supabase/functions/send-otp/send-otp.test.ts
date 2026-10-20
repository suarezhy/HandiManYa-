// node --experimental-strip-types --test supabase/functions/send-otp/send-otp.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { handleHook, sign, type Env } from './otp.ts';

const secret = 'v1,whsec_' + btoa('clave-de-prueba-solo-para-tests');
const now = 1_800_000_000;
const base: Env = { SEND_SMS_HOOK_SECRET: secret, SUPABASE_URL: 'https://x.supabase.co', SUPABASE_SERVICE_ROLE_KEY: 'k' };

async function hookRequest(payload: unknown, opts: { ts?: number; badSig?: boolean } = {}) {
  const body = JSON.stringify(payload);
  const ts = String(opts.ts ?? now);
  const sig = opts.badSig ? 'AAAA' : await sign(secret, 'msg_1', ts, body);
  return new Request('https://x.supabase.co/functions/v1/send-otp', {
    method: 'POST',
    body,
    headers: { 'webhook-id': 'msg_1', 'webhook-timestamp': ts, 'webhook-signature': `v1,${sig}` },
  });
}

const payload = { user: { id: 'u1', phone: '59171234567' }, sms: { otp: '482913', phone: '59171234567' } };

/** Simula la base (límites) y los proveedores; guarda cada llamada. */
function fakeFetch(gate: Record<string, unknown>, providerStatus = 200) {
  const calls: { url: string; body: string }[] = [];
  const fn = async (url: string, init?: RequestInit) => {
    calls.push({ url, body: String(init?.body ?? '') });
    if (url.endsWith('/rpc/hmy_otp_gate')) return new Response(JSON.stringify(gate), { status: 200 });
    if (url.endsWith('/rpc/hmy_otp_result')) return new Response('', { status: 204 });
    return new Response('{}', { status: providerStatus });
  };
  return { fn, calls };
}

const allowed = (channel: string) => ({ allowed: true, id: 7, channel, phone: '+59171234567' });

test('rechaza llamadas sin la firma de Supabase', async () => {
  const { fn, calls } = fakeFetch(allowed('sms'));
  const r = await handleHook(await hookRequest(payload, { badSig: true }), base, fn, now);
  assert.equal(r.status, 401);
  assert.equal(calls.length, 0);
});

test('rechaza firmas viejas (más de 5 minutos)', async () => {
  const { fn } = fakeFetch(allowed('sms'));
  const r = await handleHook(await hookRequest(payload, { ts: now - 600 }), base, fn, now);
  assert.equal(r.status, 401);
});

test('sin proveedor configurado no envía nada y lo dice', async () => {
  const { fn, calls } = fakeFetch(allowed('whatsapp'));
  const r = await handleHook(await hookRequest(payload), base, fn, now);
  assert.equal(r.status, 503);
  assert.deepEqual(r.body, { error: { http_code: 503, message: 'HMY_OTP_CHANNEL_OFF:whatsapp' } });
  assert.ok(!calls.some((c) => c.url.includes('facebook') || c.url.includes('twilio')));
  const result = calls.find((c) => c.url.endsWith('/rpc/hmy_otp_result'));
  assert.equal(JSON.parse(result!.body).p_delivered, false);
});

test('respeta los límites de envío', async () => {
  const { fn, calls } = fakeFetch({ allowed: false, reason: 'too_soon', retry_after: 42 });
  const r = await handleHook(await hookRequest(payload), { ...base, TWILIO_ACCOUNT_SID: 'AC1', TWILIO_AUTH_TOKEN: 't', TWILIO_FROM: '+1' }, fn, now);
  assert.equal(r.status, 429);
  assert.equal((r.body.error as { message: string }).message, 'HMY_OTP_TOO_SOON:42');
  assert.ok(!calls.some((c) => c.url.includes('twilio')));
});

test('SMS: manda el código por Twilio al canal elegido', async () => {
  const { fn, calls } = fakeFetch(allowed('sms'));
  const env = { ...base, TWILIO_ACCOUNT_SID: 'AC1', TWILIO_AUTH_TOKEN: 't', TWILIO_FROM: '+15550001111' };
  const r = await handleHook(await hookRequest(payload), env, fn, now);
  assert.equal(r.status, 200);
  const sms = calls.find((c) => c.url.includes('twilio'));
  assert.ok(sms);
  const form = new URLSearchParams(sms.body);
  assert.equal(form.get('To'), '+59171234567');
  assert.match(form.get('Body')!, /482913/);
});

test('WhatsApp: usa la plantilla de autenticación y no cae solo a SMS si falla', async () => {
  const env = {
    ...base,
    WHATSAPP_TOKEN: 'w',
    WHATSAPP_PHONE_NUMBER_ID: '123',
    WHATSAPP_TEMPLATE: 'codigo_handiman',
    TWILIO_ACCOUNT_SID: 'AC1',
    TWILIO_AUTH_TOKEN: 't',
    TWILIO_FROM: '+1',
  };
  const ok = fakeFetch(allowed('whatsapp'));
  assert.equal((await handleHook(await hookRequest(payload), env, ok.fn, now)).status, 200);
  const wa = ok.calls.find((c) => c.url.includes('graph.facebook.com/v21.0/123/messages'));
  assert.equal(JSON.parse(wa!.body).template.components[0].parameters[0].text, '482913');

  const failing = fakeFetch(allowed('whatsapp'), 500);
  const r = await handleHook(await hookRequest(payload), env, failing.fn, now);
  assert.equal(r.status, 503);
  assert.equal((r.body.error as { message: string }).message, 'HMY_OTP_SEND_FAILED:whatsapp');
  assert.ok(!failing.calls.some((c) => c.url.includes('twilio')));
});

test('código mal formado: no se envía', async () => {
  const { fn, calls } = fakeFetch(allowed('sms'));
  const r = await handleHook(await hookRequest({ sms: { otp: '12', phone: '59171234567' } }), base, fn, now);
  assert.equal(r.status, 400);
  assert.equal(calls.length, 0);
});

test('sin autorización de gasto, no envía nada y lo dice', async () => {
  const { fn, calls } = fakeFetch({ allowed: false, reason: 'budget', channel: 'whatsapp', phone: '+59171234567' });
  const r = await handleHook(await hookRequest(payload), base, fn, now);
  assert.equal(r.status, 503);
  assert.match(JSON.stringify(r.body), /HMY_OTP_BUDGET:whatsapp/);
  assert.equal(calls.some((c) => c.url.includes('graph.facebook.com') || c.url.includes('twilio')), false);
});
