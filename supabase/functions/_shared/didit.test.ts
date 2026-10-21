// node --experimental-strip-types --test supabase/functions/_shared/didit.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  canonicalJson,
  handleStart,
  handleSync,
  handleWebhook,
  hmacHex,
  LIVE_ENABLED,
  setRetryDelayForTests,
  reduceDecision,
  verifyDiditSignature,
  type Env,
} from './didit.ts';

setRetryDelayForTests(0);
const secret = 'secreto-de-prueba-solo-para-tests';
const base: Env = {
  SUPABASE_URL: 'https://x.supabase.co',
  SUPABASE_SERVICE_ROLE_KEY: 'srv',
  SUPABASE_ANON_KEY: 'anon',
  DIDIT_API_KEY: 'didit-key',
  DIDIT_WORKFLOW_ID: '1b2c3d4e-0000-4000-8000-00000000abcd',
  DIDIT_WEBHOOK_SECRET: secret,
};

/** Simula Supabase y Didit; guarda cada llamada. */
function fakeFetch(rpcs: Record<string, unknown>, opts: { user?: string | null; didit?: number } = {}) {
  const calls: { url: string; method: string; body: string; headers: Record<string, string> }[] = [];
  const fn = async (url: string, init?: RequestInit) => {
    calls.push({
      url,
      method: init?.method ?? 'GET',
      body: String(init?.body ?? ''),
      headers: Object.fromEntries(new Headers(init?.headers).entries()),
    });
    if (url.endsWith('/auth/v1/user')) {
      return opts.user === null ? new Response('{}', { status: 401 }) : new Response(JSON.stringify({ id: opts.user ?? 'pro-1' }));
    }
    const rpc = url.match(/\/rpc\/(\w+)$/)?.[1];
    if (rpc) return new Response(JSON.stringify(rpcs[rpc] ?? null), { status: 200 });
    if (url.endsWith('/v3/session/')) {
      return new Response(JSON.stringify({ session_id: 'ses-1', verification_url: 'https://verify.didit.me/s/abc' }), {
        status: opts.didit ?? 201,
      });
    }
    if (url.includes('/decision/')) {
      return new Response(JSON.stringify({ status: 'Approved', face_matches: [{ score: 91 }] }));
    }
    return new Response('{}', { status: 200 });
  };
  return { fn, calls };
}

const start = () =>
  new Request('https://x.supabase.co/functions/v1/identity-check', {
    method: 'POST',
    headers: { Authorization: 'Bearer user-jwt' },
  });

const decision = {
  status: 'Approved',
  id_verifications: [
    {
      status: 'Approved',
      document_type: 'Identity Card',
      first_name: 'Marta',
      last_name: 'Quispe',
      date_of_birth: '1990-01-01',
      document_number: '1234567',
      warnings: [{ risk: 'DOCUMENT_NEAR_EXPIRY', short_description: 'x' }],
    },
  ],
  liveness_checks: [{ status: 'Approved', score: 95.4, warnings: [] }],
  face_matches: [{ status: 'Approved', score: 96.1, warnings: ['LOW_FACE_MATCH_SIMILARITY'] }],
};

async function webhook(payload: Record<string, unknown>, opts: { ts?: number; badSig?: boolean; v1?: boolean } = {}) {
  const body = JSON.stringify(payload);
  const ts = String(opts.ts ?? Math.floor(Date.now() / 1000));
  const headers: Record<string, string> = { 'X-Timestamp': ts, 'Content-Type': 'application/json' };
  if (opts.v1) headers['X-Signature'] = await hmacHex(secret, body);
  else headers['X-Signature-V2'] = opts.badSig ? 'ab'.repeat(32) : await hmacHex(secret, canonicalJson(payload));
  return new Request('https://x.supabase.co/functions/v1/didit-webhook', { method: 'POST', body, headers });
}

const event = (extra: Record<string, unknown> = {}) => ({
  event_id: 'ev-1',
  webhook_type: 'status.updated',
  environment: 'sandbox',
  session_id: 'ses-1',
  status: 'Approved',
  decision,
  ...extra,
});

test('firma: claves ordenadas, compacta y sin escapar acentos', async () => {
  assert.equal(canonicalJson({ b: 1, a: { d: 'ñ', c: [2, { z: 1, y: 2 }] } }), '{"a":{"c":[2,{"y":2,"z":1}],"d":"ñ"},"b":1}');
  const body = '{"b":1,"a":2}';
  const now = 1_800_000_000;
  const ok = new Headers({ 'x-timestamp': String(now), 'x-signature-v2': await hmacHex(secret, '{"a":2,"b":1}') });
  assert.equal(await verifyDiditSignature(secret, ok, body, now), true);
  assert.equal(await verifyDiditSignature(secret, ok, body, now + 301), false, 'más de 5 minutos: se rechaza');
  assert.equal(await verifyDiditSignature('otra', ok, body, now), false);
});

test('del resultado solo quedan estado, puntajes y códigos (nada personal)', () => {
  const r = reduceDecision(decision);
  assert.deepEqual(r, {
    warnings: ['DOCUMENT_NEAR_EXPIRY', 'LOW_FACE_MATCH_SIMILARITY'],
    document_type: 'Identity Card',
    id_document_status: 'Approved',
    liveness_score: 95.4,
    face_match_score: 96.1,
  });
  assert.doesNotMatch(JSON.stringify(r), /Marta|Quispe|1990|1234567/);
});

test('pedir la verificación: sin sesión iniciada, no', async () => {
  const { fn, calls } = fakeFetch({}, { user: null });
  const r = await handleStart(start(), base, fn);
  assert.equal(r.status, 401);
  assert.equal(calls.some((c) => c.url.includes('didit')), false);
});

test('pedir la verificación: sandbox por defecto, solo el id interno va a Didit', async () => {
  const { fn, calls } = fakeFetch({ hmy_identity_begin: { allowed: true, resume: false, id: 9 } });
  const r = await handleStart(start(), base, fn);
  assert.equal(r.status, 200);
  assert.deepEqual(r.body, { verification_url: 'https://verify.didit.me/s/abc', sandbox: true });
  const begin = calls.find((c) => c.url.endsWith('/rpc/hmy_identity_begin'))!;
  assert.deepEqual(JSON.parse(begin.body), { p_user: 'pro-1', p_sandbox: true });
  const create = calls.find((c) => c.url.endsWith('/v3/session/'))!;
  assert.equal(create.headers['x-api-key'], 'didit-key');
  assert.deepEqual(JSON.parse(create.body), { workflow_id: '1b2c3d4e-0000-4000-8000-00000000abcd', vendor_data: 'pro-1' });
  assert.ok(calls.some((c) => c.url.endsWith('/rpc/hmy_identity_session') && c.body.includes('ses-1')));
});

test('pedir la verificación: si la base frena el gasto, no se llama a Didit', async () => {
  const { fn, calls } = fakeFetch({ hmy_identity_begin: { allowed: false, reason: 'sandbox_limit' } });
  const r = await handleStart(start(), base, fn);
  assert.equal(r.status, 503);
  assert.deepEqual(r.body, { error: 'HMY_IDENTITY_PAUSED' });
  assert.equal(calls.some((c) => c.url.includes('didit.me')), false);
});

test('modo real cerrado: DIDIT_SANDBOX=false no llama a Didit ni a la base', async () => {
  assert.equal(LIVE_ENABLED, false, 'el modo real solo se abre con un PR aprobado por el dueño');
  const live = { ...base, DIDIT_SANDBOX: 'false' };
  const { fn, calls } = fakeFetch({ hmy_identity_begin: { allowed: true, resume: false, id: 9 }, hmy_identity_pending: [] });
  assert.deepEqual((await handleStart(start(), live, fn)).body, { error: 'HMY_IDENTITY_LIVE_LOCKED' });
  assert.deepEqual((await handleWebhook(await webhook(event()), live, fn)).body, { error: 'HMY_IDENTITY_LIVE_LOCKED' });
  const sync = new Request('https://x/sync', { method: 'POST', headers: { Authorization: 'Bearer srv' } });
  assert.deepEqual((await handleSync(sync, live, fn)).body, { error: 'HMY_IDENTITY_LIVE_LOCKED' });
  assert.equal(calls.some((c) => c.url.includes('didit.me') || c.url.includes('/rpc/')), false);
});

test('solo se habla con Didit (verification.didit.me) y con la propia base', async () => {
  const { fn, calls } = fakeFetch({ hmy_identity_begin: { allowed: true, resume: false, id: 9 }, hmy_identity_decision: { updated: true } });
  await handleStart(start(), base, fn);
  await handleWebhook(await webhook(event()), base, fn);
  for (const c of calls) {
    assert.match(c.url, /^https:\/\/(verification\.didit\.me|x\.supabase\.co)\//, c.url);
  }
});

test('pedir la verificación: una sesión abierta se retoma sin crear otra', async () => {
  const { fn, calls } = fakeFetch({
    hmy_identity_begin: { allowed: true, resume: true, id: 9, verification_url: 'https://verify.didit.me/s/old' },
  });
  const r = await handleStart(start(), base, fn);
  assert.equal((r.body as { verification_url: string }).verification_url, 'https://verify.didit.me/s/old');
  assert.equal(calls.some((c) => c.url.endsWith('/v3/session/')), false);
});

test('pedir la verificación: sin claves de Didit, error claro y queda registrado', async () => {
  const { fn, calls } = fakeFetch({ hmy_identity_begin: { allowed: true, resume: false, id: 9 } });
  const r = await handleStart(start(), { ...base, DIDIT_API_KEY: undefined }, fn);
  assert.deepEqual(r.body, { error: 'HMY_IDENTITY_OFF' });
  assert.ok(calls.some((c) => c.url.endsWith('/rpc/hmy_identity_failed')));
});

test('pedir la verificación: un id de flujo que no es UUID no llega a Didit', async () => {
  const { fn, calls } = fakeFetch({ hmy_identity_begin: { allowed: true, resume: false, id: 9 } });
  const r = await handleStart(start(), { ...base, DIDIT_WORKFLOW_ID: 'Free KYC' }, fn);
  assert.deepEqual(r.body, { error: 'HMY_IDENTITY_BAD_WORKFLOW_ID' });
  assert.equal(calls.some((c) => c.url.includes('didit.me')), false);
  assert.ok(calls.some((c) => c.url.endsWith('/rpc/hmy_identity_failed')));
});

test('pedir la verificación: si Didit falla, no se simula éxito', async () => {
  const { fn, calls } = fakeFetch({ hmy_identity_begin: { allowed: true, resume: false, id: 9 } }, { didit: 500 });
  const r = await handleStart(start(), base, fn);
  assert.equal(r.status, 502);
  assert.deepEqual(r.body, { error: 'HMY_IDENTITY_SEND_FAILED', didit_status: 500 });
  assert.ok(calls.some((c) => c.url.endsWith('/rpc/hmy_identity_failed')));
});

test('aviso de Didit: sin firma válida, se rechaza', async () => {
  const { fn, calls } = fakeFetch({});
  const r = await handleWebhook(await webhook(event(), { badSig: true }), base, fn);
  assert.equal(r.status, 401);
  assert.equal(calls.length, 0);
  const old = await handleWebhook(await webhook(event(), { ts: Math.floor(Date.now() / 1000) - 600 }), base, fn);
  assert.equal(old.status, 401);
});

test('aviso de Didit: un aviso firmado pero viejo no entra aunque cambien X-Timestamp', async () => {
  const { fn, calls } = fakeFetch({ hmy_identity_decision: { updated: true } });
  const now = Math.floor(Date.now() / 1000);
  const old = await handleWebhook(await webhook(event({ timestamp: now - 3600 })), base, fn);
  assert.equal(old.status, 401);
  assert.equal(calls.length, 0);
  const fresh = await handleWebhook(await webhook(event({ timestamp: now - 10 })), base, fn);
  assert.equal(fresh.status, 200);
});

test('aviso de Didit: una firma falsa no pasa aunque traiga las dos cabeceras', async () => {
  const { fn, calls } = fakeFetch({});
  const body = JSON.stringify(event());
  const req = new Request('https://x.supabase.co/functions/v1/didit-webhook', {
    method: 'POST',
    body,
    headers: {
      'X-Timestamp': String(Math.floor(Date.now() / 1000)),
      'X-Signature-V2': await hmacHex('otro-secreto', canonicalJson(JSON.parse(body))),
      'X-Signature': await hmacHex('otro-secreto', body),
    },
  });
  assert.equal((await handleWebhook(req, base, fn)).status, 401);
  assert.equal(calls.length, 0);
});

test('aviso de Didit: si llega antes de que la sesión esté guardada, espera y reintenta', async () => {
  let n = 0;
  const { fn, calls } = fakeFetch({});
  const wrapped = async (url: string, init?: RequestInit) => {
    if (url.endsWith('/rpc/hmy_identity_decision')) {
      calls.push({ url, method: 'POST', body: String(init?.body ?? ''), headers: {} });
      n++;
      return new Response(JSON.stringify(n < 3 ? { updated: false, reason: 'unknown_session' } : { updated: true }));
    }
    return fn(url, init);
  };
  const r = await handleWebhook(await webhook(event({ status: 'Not Started', decision: null })), base, wrapped);
  assert.equal(r.status, 200);
  assert.equal(n, 3);
  const never = async (url: string, init?: RequestInit) =>
    url.endsWith('/rpc/hmy_identity_decision')
      ? new Response(JSON.stringify({ updated: false, reason: 'unknown_session' }))
      : fn(url, init);
  assert.equal((await handleWebhook(await webhook(event({ event_id: 'ev-2' })), base, never)).status, 500, 'Didit reintenta');
});

test('aviso de Didit: guarda lo mínimo y borra la sesión en Didit', async () => {
  const { fn, calls } = fakeFetch({ hmy_identity_decision: { updated: true } });
  const r = await handleWebhook(await webhook(event()), base, fn);
  assert.equal(r.status, 200);
  const saved = JSON.parse(calls.find((c) => c.url.endsWith('/rpc/hmy_identity_decision'))!.body);
  assert.equal(saved.p_session_id, 'ses-1');
  assert.equal(saved.p_status, 'Approved');
  assert.equal(saved.p_sandbox, true);
  assert.equal(saved.p_event_id, 'ev-1');
  assert.doesNotMatch(JSON.stringify(saved), /Marta|1990|1234567/);
  const del = calls.find((c) => c.method === 'DELETE')!;
  assert.equal(del.url, 'https://verification.didit.me/v3/session/ses-1/delete/');
  assert.ok(calls.some((c) => c.url.endsWith('/rpc/hmy_identity_deleted')));
});

test('aviso de Didit: también acepta la firma sobre el cuerpo tal cual', async () => {
  const { fn } = fakeFetch({ hmy_identity_decision: { updated: true } });
  assert.equal((await handleWebhook(await webhook(event({ status: 'In Progress', decision: null }), { v1: true }), base, fn)).status, 200);
});

test('aviso de Didit: un aviso real no entra en el sandbox (y al revés)', async () => {
  const { fn, calls } = fakeFetch({});
  const r = await handleWebhook(await webhook(event({ environment: 'live' })), base, fn);
  assert.equal(r.status, 400);
  assert.equal(calls.length, 0);
});

test('aviso de Didit: sin decisión final, no se borra nada', async () => {
  const { fn, calls } = fakeFetch({ hmy_identity_decision: { updated: true } });
  await handleWebhook(await webhook(event({ status: 'In Review' })), base, fn);
  assert.equal(calls.some((c) => c.method === 'DELETE'), false);
});

test('aviso de Didit: si la base falla, responde 500 para que Didit reintente', async () => {
  const { calls } = fakeFetch({});
  const failing = async (url: string, init?: RequestInit) => {
    calls.push({ url, method: init?.method ?? 'GET', body: '', headers: {} });
    return new Response('boom', { status: 500 });
  };
  const r = await handleWebhook(await webhook(event()), base, failing);
  assert.equal(r.status, 500);
});

test('revisión periódica: solo con la clave del servidor; consulta y borra', async () => {
  const { fn, calls } = fakeFetch({
    hmy_identity_pending: [
      { session_id: 'ses-a', sandbox: true, status: 'in_progress' },
      { session_id: 'ses-b', sandbox: true, status: 'declined' },
      { session_id: 'ses-c', sandbox: false, status: 'in_progress' },
    ],
    hmy_identity_decision: { updated: true },
  });
  const denied = await handleSync(new Request('https://x/sync', { method: 'POST', headers: { Authorization: 'Bearer x' } }), base, fn);
  assert.equal(denied.status, 401);
  const r = await handleSync(new Request('https://x/sync', { method: 'POST', headers: { Authorization: 'Bearer srv' } }), base, fn);
  assert.deepEqual(r.body, { checked: 2 });
  assert.ok(calls.some((c) => c.url.endsWith('/v3/session/ses-a/decision/')));
  assert.ok(calls.some((c) => c.method === 'DELETE' && c.url.includes('ses-b')));
  assert.equal(calls.some((c) => c.url.includes('ses-c')), false, 'una sesión real no se toca con claves del sandbox');
});
