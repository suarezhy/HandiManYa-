// Prueba del sandbox de Didit contra las funciones desplegadas en el proyecto de
// DESARROLLO. Crea como máximo una sesión de prueba en el sandbox (gratis, sin
// carnet real) y revisa que las puertas estén cerradas para quien no debe.
//
// Variables: E2E_URL, E2E_ANON_KEY, E2E_PASSWORD (cuenta de setup.sql).
// Uso: node --test supabase/e2e/didit/sandbox.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

const URL_ = process.env.E2E_URL;
const ANON = process.env.E2E_ANON_KEY;
const PASSWORD = process.env.E2E_PASSWORD;
const fn = (name) => `${URL_}/functions/v1/${name}`;

let token;
const needsUser = { skip: ANON ? false : 'falta SUPABASE_ANON_KEY' };
let firstUrl;

async function call(name, { auth, body, method = 'POST', headers = {} } = {}) {
  const res = await fetch(fn(name), {
    method,
    headers: { ...(ANON ? { apikey: ANON } : {}), 'Content-Type': 'application/json', ...(auth ? { Authorization: `Bearer ${auth}` } : {}), ...headers },
    ...(body !== undefined ? { body } : {}),
  });
  let json = null;
  try {
    json = await res.json();
  } catch {
    // Sin cuerpo JSON.
  }
  return { status: res.status, json };
}

test('la cuenta de prueba entra con contraseña', needsUser, async () => {
  assert.ok(URL_ && PASSWORD, 'faltan E2E_URL o E2E_PASSWORD');
  const res = await fetch(`${URL_}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { ...(ANON ? { apikey: ANON } : {}), 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: 'didit-pro@test.bo', password: PASSWORD }),
  });
  assert.equal(res.status, 200);
  token = (await res.json()).access_token;
  assert.ok(token);
});

test('identity-check: sin sesión iniciada, no', async () => {
  const r = await call('identity-check');
  assert.equal(r.status, 401);
});

test('identity-check: crea una sesión del sandbox de Didit (gratis)', needsUser, async () => {
  const r = await call('identity-check', { auth: token });
  const hint = {
    HMY_IDENTITY_OFF: 'falta DIDIT_API_KEY o DIDIT_WORKFLOW_ID en los secretos de la función',
    HMY_IDENTITY_SEND_FAILED: 'Didit rechazó crear la sesión: revisa DIDIT_WORKFLOW_ID (de la app sandbox) y el permiso de la clave',
    HMY_IDENTITY_LIVE_LOCKED: 'DIDIT_SANDBOX=false está puesto; quítalo',
  }[r.json?.error];
  assert.equal(r.status, 200, `${JSON.stringify(r.json)} ${hint ?? ''}`);
  assert.equal(r.json.sandbox, true, 'debe ser sandbox');
  const u = new URL(r.json.verification_url);
  assert.equal(u.protocol, 'https:');
  assert.match(u.hostname, /(^|\.)didit\.me$/, 'el enlace debe ser de Didit');
  firstUrl = r.json.verification_url;
});

test('identity-check: pedirla otra vez retoma la misma sesión (no crea otra)', needsUser, async () => {
  const r = await call('identity-check', { auth: token });
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.verification_url, firstUrl);
  assert.equal(r.json.sandbox, true);
});

test('identity-check/sync: solo con la clave del servidor', needsUser, async () => {
  const r = await call('identity-check/sync', { auth: token });
  assert.equal(r.status, 401);
  assert.equal(r.json?.error, 'HMY_FORBIDDEN');
});

test('didit-webhook: sin firma o con firma falsa, se rechaza', async () => {
  const body = JSON.stringify({
    event_id: 'falso', environment: 'sandbox', session_id: 'falsa', status: 'Approved', webhook_type: 'status.updated',
  });
  const none = await call('didit-webhook', { body });
  assert.notEqual(none.json?.error, 'HMY_IDENTITY_OFF', 'falta DIDIT_WEBHOOK_SECRET en los secretos de la función');
  assert.equal(none.status, 401, JSON.stringify(none.json));
  assert.equal(none.json?.error, 'HMY_BAD_SIGNATURE', 'la respuesta debe venir de nuestra función');
  const fake = await call('didit-webhook', {
    body,
    headers: { 'X-Signature-V2': 'ab'.repeat(32), 'X-Timestamp': String(Math.floor(Date.now() / 1000)) },
  });
  assert.equal(fake.status, 401, JSON.stringify(fake.json));
  assert.equal(fake.json?.error, 'HMY_BAD_SIGNATURE');
  const get = await call('didit-webhook', { method: 'GET' });
  assert.equal(get.status, 405);
});
