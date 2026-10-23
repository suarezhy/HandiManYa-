// node --experimental-strip-types --test supabase/functions/send-push/send-push.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { classify, fcmMessage, handlePush, signedJwt, type Env } from './push.ts';

// Clave RSA creada solo para estas pruebas; no es de ningún proyecto.
const pair = (await crypto.subtle.generateKey(
  { name: 'RSASSA-PKCS1-v1_5', modulusLength: 2048, publicExponent: new Uint8Array([1, 0, 1]), hash: 'SHA-256' },
  true,
  ['sign', 'verify'],
)) as CryptoKeyPair;
const pkcs8 = new Uint8Array(await crypto.subtle.exportKey('pkcs8', pair.privateKey));
const pem = `-----BEGIN PRIVATE KEY-----\n${btoa(String.fromCharCode(...pkcs8))}\n-----END PRIVATE KEY-----\n`;
const sa = { project_id: 'hmy-prueba', client_email: 'push@hmy-prueba.iam.gserviceaccount.com', private_key: pem };

const base: Env = {
  PUSH_WEBHOOK_SECRET: 'secreto-de-prueba',
  FCM_SERVICE_ACCOUNT: JSON.stringify(sa),
  SUPABASE_URL: 'https://x.supabase.co',
  SUPABASE_SERVICE_ROLE_KEY: 'k',
};

const request = (secret = 'secreto-de-prueba') =>
  new Request('https://x.supabase.co/functions/v1/send-push', {
    method: 'POST',
    body: '{"type":"INSERT"}',
    headers: { 'x-hmy-push-secret': secret },
  });

const item = (id: number, token = `tok-${id}`) => ({
  id,
  token,
  platform: 'android',
  title: 'Nuevo mensaje',
  body: 'Ábrelo para leerlo.',
  data: { kind: 'message', notification_id: String(id) },
});

/** Simula Google, Firebase y la base; guarda cada llamada. */
function fakeFetch(queue: unknown[][], fcm: (token: string) => Response = () => new Response('{}')) {
  const calls: { url: string; body: string }[] = [];
  const fn = async (url: string, init?: RequestInit) => {
    const body = String(init?.body ?? '');
    calls.push({ url, body });
    if (url === 'https://oauth2.googleapis.com/token') return new Response(JSON.stringify({ access_token: 'ya29.prueba' }));
    if (url.endsWith('/rpc/hmy_push_claim')) return new Response(JSON.stringify(queue.shift() ?? []));
    if (url.endsWith('/rpc/hmy_push_report')) return new Response(null, { status: 204 });
    if (url.startsWith('https://fcm.googleapis.com/')) return fcm(JSON.parse(body).message.token);
    return new Response('no esperado', { status: 500 });
  };
  return { fn, calls };
}

const reports = (calls: { url: string; body: string }[]) =>
  calls.filter((c) => c.url.endsWith('/rpc/hmy_push_report')).flatMap((c) => JSON.parse(c.body).p_results);

test('rechaza llamadas sin el secreto del webhook', async () => {
  const { fn, calls } = fakeFetch([[item(1)]]);
  const r = await handlePush(request('otro'), base, fn);
  assert.equal(r.status, 401);
  assert.equal(calls.length, 0);
});

test('sin secreto configurado no hace nada', async () => {
  const { fn, calls } = fakeFetch([[item(1)]]);
  const r = await handlePush(request(), { ...base, PUSH_WEBHOOK_SECRET: undefined }, fn);
  assert.equal(r.body.error, 'HMY_PUSH_NOT_CONFIGURED');
  assert.equal(calls.length, 0);
});

test('sin Firebase configurado no reclama nada: la cola queda pendiente', async () => {
  const { fn, calls } = fakeFetch([[item(1)]]);
  const r = await handlePush(request(), { ...base, FCM_SERVICE_ACCOUNT: undefined }, fn);
  assert.equal(r.status, 503);
  assert.equal(r.body.error, 'HMY_PUSH_OFF');
  assert.equal(calls.length, 0);
});

test('si Google no da el token de acceso, no reclama nada', async () => {
  const calls: string[] = [];
  const fn = async (url: string) => {
    calls.push(url);
    return new Response('{}', { status: 400 });
  };
  const r = await handlePush(request(), base, fn);
  assert.equal(r.body.error, 'HMY_PUSH_AUTH_FAILED');
  assert.ok(!calls.some((u) => u.includes('hmy_push_claim')));
});

test('manda cada aviso a FCM v1 y anota el resultado', async () => {
  const { fn, calls } = fakeFetch([[item(1), item(2)]]);
  const r = await handlePush(request(), base, fn);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { sent: 2, failed: 0 });
  const sends = calls.filter((c) => c.url === 'https://fcm.googleapis.com/v1/projects/hmy-prueba/messages:send');
  assert.equal(sends.length, 2);
  assert.deepEqual(
    reports(calls).map((x: { id: number; ok: boolean }) => [x.id, x.ok]),
    [
      [1, true],
      [2, true],
    ],
  );
});

test('el token de acceso es un JWT RS256 válido de la cuenta de servicio', async () => {
  const jwt = await signedJwt(sa, 1_800_000_000);
  const [h, c, s] = jwt.split('.');
  const dec = (x: string) => Uint8Array.from(atob(x.replace(/-/g, '+').replace(/_/g, '/')), (ch) => ch.charCodeAt(0));
  const claims = JSON.parse(new TextDecoder().decode(dec(c)));
  assert.equal(claims.iss, sa.client_email);
  assert.equal(claims.scope, 'https://www.googleapis.com/auth/firebase.messaging');
  assert.equal(claims.exp - claims.iat, 3600);
  const ok = await crypto.subtle.verify('RSASSA-PKCS1-v1_5', pair.publicKey, dec(s), new TextEncoder().encode(`${h}.${c}`));
  assert.equal(ok, true);
});

test('token no registrado: falla y apaga el teléfono; error temporal: reintenta', async () => {
  const { fn, calls } = fakeFetch([[item(1, 'viejo'), item(2, 'ocupado'), item(3, 'bien')]], (token) => {
    if (token === 'viejo')
      return new Response(
        JSON.stringify({ error: { status: 'NOT_FOUND', details: [{ errorCode: 'UNREGISTERED' }] } }),
        { status: 404 },
      );
    if (token === 'ocupado') return new Response(JSON.stringify({ error: { status: 'UNAVAILABLE' } }), { status: 503 });
    return new Response('{}');
  });
  const r = await handlePush(request(), base, fn);
  assert.deepEqual(r.body, { sent: 1, failed: 2 });
  const byId = Object.fromEntries(reports(calls).map((x: { id: number }) => [x.id, x]));
  assert.equal(byId[1].unregistered, true);
  assert.equal(byId[2].retry, true);
  assert.equal(byId[2].unregistered, undefined);
  assert.equal(byId[3].ok, true);
});

test('un error del mensaje no apaga el teléfono ni se reintenta', async () => {
  const r = await classify(
    9,
    new Response(JSON.stringify({ error: { status: 'INVALID_ARGUMENT' } }), { status: 400 }),
  );
  assert.equal(r.ok, false);
  assert.equal(r.unregistered, undefined);
  assert.equal(r.retry, false);
});

test('vacía la cola en tandas hasta que no queda nada', async () => {
  const full = Array.from({ length: 100 }, (_, i) => item(i + 1));
  const { fn, calls } = fakeFetch([full, [item(101)]]);
  const r = await handlePush(request(), base, fn);
  assert.deepEqual(r.body, { sent: 101, failed: 0 });
  assert.equal(calls.filter((c) => c.url.endsWith('/rpc/hmy_push_claim')).length, 2);
});

test('el mensaje lleva título, texto fijo, datos y sonido; el enlace web solo si se configuró', () => {
  const m = fcmMessage(item(1) as never).message as Record<string, any>;
  assert.equal(m.notification.title, 'Nuevo mensaje');
  assert.equal(m.notification.body, 'Ábrelo para leerlo.');
  assert.equal(m.data.kind, 'message');
  assert.equal(m.android.priority, 'high');
  assert.equal(m.webpush, undefined);
  const w = fcmMessage(item(1) as never, 'https://ejemplo.bo/app/').message as Record<string, any>;
  assert.equal(w.webpush.fcm_options.link, 'https://ejemplo.bo/app/');
});
