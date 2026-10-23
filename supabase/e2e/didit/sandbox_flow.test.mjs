// Segunda parte de la prueba del sandbox de Didit (corre después de
// sandbox.test.mjs, que dejó una sesión creada). Usa el simulador del sandbox de
// Didit (sin carnet, sin costo) para llevar las sesiones a un resultado final y
// revisa que: el aviso firmado de Didit llega y se acepta (secreto correcto), la
// base se actualiza, la sesión se borra en Didit y nadie queda aprobado por Didit.
//
// Variables: E2E_URL, E2E_ANON_KEY, E2E_PASSWORD, DB_URL.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';

const URL_ = process.env.E2E_URL;
const ANON = process.env.E2E_ANON_KEY;
const PASSWORD = process.env.E2E_PASSWORD;
const PRO = 'd1d17000-0000-4000-8000-0000000000b1';
const DIDIT = 'https://verification.didit.me';
const skip = { skip: ANON ? false : 'falta SUPABASE_ANON_KEY' };

const sql = (q) => execFileSync('psql', [process.env.DB_URL, '-X', '-At', '-v', 'ON_ERROR_STOP=1', '-c', q], { encoding: 'utf8' }).trim();
const latest = () => {
  const row = sql(`select session_id, verification_url, status, coalesce(last_event_id, ''), vendor_deleted_at is not null,
                          coalesce(face_match_score::text, ''), coalesce(liveness_score::text, ''), sandbox
                     from public.identity_checks where professional_id = '${PRO}' order by id desc limit 1`);
  const [session, url, status, event, deleted, face, live, sandbox] = row.split('|');
  return { session, url, status, event, deleted: deleted === 't', face, live, sandbox: sandbox === 't' };
};
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
async function waitFor(what, check, seconds) {
  for (let i = 0; i < seconds / 5; i++) {
    const c = latest();
    if (check(c)) return c;
    await sleep(5000);
  }
  const c = latest();
  assert.fail(`${what}: no pasó en ${seconds} s (estado=${c.status}, aviso=${c.event ? 'sí' : 'no'}, borrada=${c.deleted})`);
}

let token;
async function start() {
  const res = await fetch(`${URL_}/functions/v1/identity-check`, {
    method: 'POST',
    headers: { apikey: ANON, Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  });
  return { status: res.status, json: await res.json().catch(() => null) };
}

/** Simulador del sandbox de Didit con el token de la sesión (va en el enlace). */
async function simulate(c, scenario) {
  const sessionToken = new URL(c.url).pathname.split('/').filter(Boolean).pop();
  const res = await fetch(`${DIDIT}/v3/session/${encodeURIComponent(c.session)}/sandbox/simulate/`, {
    method: 'POST',
    headers: { 'Session-Token': sessionToken, 'Content-Type': 'application/json' },
    body: JSON.stringify({ scenario }),
  });
  const text = await res.text();
  assert.ok(res.ok, `el simulador de Didit respondió ${res.status}: ${text.slice(0, 300)}`);
}

test('entra la cuenta de prueba', skip, async () => {
  const res = await fetch(`${URL_}/auth/v1/token?grant_type=password`, {
    method: 'POST',
    headers: { apikey: ANON, 'Content-Type': 'application/json' },
    body: JSON.stringify({ email: 'didit-pro@test.bo', password: PASSWORD }),
  });
  assert.equal(res.status, 200);
  token = (await res.json()).access_token;
});

test('el aviso "Not Started" de Didit llega con firma válida (el secreto del webhook es el correcto)', skip, async () => {
  const c = await waitFor('aviso firmado de Didit', (c) => c.event !== '', 120);
  assert.equal(c.sandbox, true);
});

test('rechazo simulado: la base guarda "declined", los puntajes y borra la sesión en Didit', skip, async () => {
  await simulate(latest(), 'decline_face_match_low_similarity');
  const c = await waitFor('resultado rechazado', (c) => c.status === 'declined', 120);
  console.log(`  rechazado: parecido=${c.face || '-'} prueba de vida=${c.live || '-'}`);
  await waitFor('sesión borrada en Didit (permiso de la clave)', (c) => c.deleted, 60);
});

test('tras un rechazo se puede intentar de nuevo: sesión nueva', skip, async () => {
  const before = latest().session;
  const r = await start();
  assert.equal(r.status, 200, JSON.stringify(r.json));
  assert.equal(r.json.sandbox, true);
  assert.notEqual(latest().session, before);
  await waitFor('aviso firmado de la sesión nueva', (c) => c.event !== '', 120);
});

test('aprobación simulada: la base guarda "approved" y borra la sesión, pero nadie queda aprobado', skip, async () => {
  await simulate(latest(), 'approve');
  await waitFor('resultado aprobado', (c) => c.status === 'approved', 120);
  await waitFor('sesión aprobada borrada en Didit', (c) => c.deleted, 60);
  assert.equal(sql(`select status from public.professional_profiles where user_id = '${PRO}'`), 'draft',
    'el resultado de Didit no aprueba al profesional: aprueba una persona');
  const r = await start();
  assert.equal(r.status, 400);
  assert.equal(r.json?.error, 'HMY_IDENTITY_ALREADY_APPROVED');
});
