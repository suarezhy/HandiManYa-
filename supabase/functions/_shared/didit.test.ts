// node --experimental-strip-types --test supabase/functions/_shared/didit.test.ts
import { test } from 'node:test';
import assert from 'node:assert/strict';
import {
  canonicalJson,
  diditLink,
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

const SID = 'aaaa1111-2222-4333-8444-555566667777';
/** Lo que la base responde si la prueba no dice otra cosa. */
const rpcDefaults: Record<string, unknown> = {
  hmy_identity_attach: { saved: true, check: 9, reused: false },
  hmy_identity_session_free: true,
};

/** Simula Supabase y Didit; guarda cada llamada. */
function fakeFetch(
  rpcs: Record<string, unknown>,
  opts: { user?: string | null; didit?: number; diditBody?: string; diditThrows?: boolean } = {},
) {
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
    if (rpc) return new Response(JSON.stringify(rpcs[rpc] ?? rpcDefaults[rpc] ?? null), { status: 200 });
    if (url.endsWith('/v3/session/')) {
      if (opts.diditThrows) throw new TypeError('connect ECONNREFUSED didit-key token=SECRETO');
      // Como responde Didit (docs.didit.me/sessions-api/create-session): 201 y el enlace en "url".
      const body =
        opts.diditBody ??
        JSON.stringify({
          session_id: SID,
          session_kind: 'user',
          session_number: 1024,
          session_token: 'tok12345abcd',
          url: 'https://verify.didit.me/session/tok12345abcd',
          status: 'Not Started',
          workflow_id: '1b2c3d4e-0000-4000-8000-00000000abcd',
          vendor_data: 'pro-1',
        });
      return new Response(body, { status: opts.didit ?? 201 });
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
  assert.deepEqual(r.body, { verification_url: 'https://verify.didit.me/session/tok12345abcd', sandbox: true });
  const begin = calls.find((c) => c.url.endsWith('/rpc/hmy_identity_begin'))!;
  assert.deepEqual(JSON.parse(begin.body), { p_user: 'pro-1', p_sandbox: true });
  const create = calls.find((c) => c.url.endsWith('/v3/session/'))!;
  assert.equal(create.headers['x-api-key'], 'didit-key');
  assert.deepEqual(JSON.parse(create.body), { workflow_id: '1b2c3d4e-0000-4000-8000-00000000abcd', vendor_data: 'pro-1' });
  assert.ok(calls.some((c) => c.url.endsWith('/rpc/hmy_identity_attach') && c.body.includes(SID)));
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

/** Captura console.error mientras corre fn. */
async function captureLogs(fn: () => Promise<unknown>): Promise<string> {
  const lines: string[] = [];
  const original = console.error;
  console.error = (...a: unknown[]) => lines.push(a.map(String).join(' '));
  try {
    await fn();
  } finally {
    console.error = original;
  }
  return lines.join('\n');
}

const begin = { hmy_identity_begin: { allowed: true, resume: false, id: 9 } };
const sensitive = /didit-key|pro-1|tok12345abcd|SECRETO|ECONNREFUSED|Marta|1234567|1b2c3d4e|detail|permission/i;

test('pedir la verificación: 201 de Didit guarda session_id y url de la respuesta', async () => {
  const { fn, calls } = fakeFetch(begin);
  const logs = await captureLogs(() => handleStart(start(), base, fn));
  const saved = JSON.parse(calls.find((c) => c.url.endsWith('/rpc/hmy_identity_attach'))!.body);
  assert.deepEqual(saved, { p_check: 9, p_session_id: SID, p_url: 'https://verify.didit.me/session/tok12345abcd' });
  assert.equal(logs, '', 'si todo sale bien no se registra nada');
});

test('pedir la verificación: sin DIDIT_WORKFLOW_ID (o vacío) no se llama a Didit', async () => {
  for (const wf of [undefined, '', '   ']) {
    const { fn, calls } = fakeFetch(begin);
    const r = await handleStart(start(), { ...base, DIDIT_WORKFLOW_ID: wf }, fn);
    assert.deepEqual(r.body, { error: 'HMY_IDENTITY_OFF' });
    assert.equal(calls.some((c) => c.url.includes('didit.me')), false);
    assert.ok(calls.some((c) => c.url.endsWith('/rpc/hmy_identity_failed')));
  }
});

test('pedir la verificación: el UUID se acepta con espacios alrededor y se envía limpio', async () => {
  const { fn, calls } = fakeFetch(begin);
  const r = await handleStart(start(), { ...base, DIDIT_WORKFLOW_ID: '  1b2c3d4e-0000-4000-8000-00000000abcd\n' }, fn);
  assert.equal(r.status, 200);
  assert.equal(JSON.parse(calls.find((c) => c.url.endsWith('/v3/session/'))!.body).workflow_id, '1b2c3d4e-0000-4000-8000-00000000abcd');
});

for (const [name, opts, reason, status, cleanup] of [
  ['HTTP 400 (flujo inválido)', { didit: 400, diditBody: '{"workflow_id": "Invalid workflow_id."}' }, 'didit_http_error', 400, 'none'],
  ['HTTP 401 (clave)', { didit: 401, diditBody: '{"detail": "Invalid API key didit-key"}' }, 'didit_http_error', 401, 'none'],
  ['HTTP 403 (permiso)', { didit: 403, diditBody: '{"detail": "You do not have permission to perform this action."}' }, 'didit_http_error', 403, 'none'],
  ['HTTP 429 (límite)', { didit: 429, diditBody: '{"detail": "rate limit"}' }, 'didit_http_error', 429, 'none'],
  ['HTTP 500', { didit: 500, diditBody: 'Internal error for pro-1 Marta 1234567' }, 'didit_http_error', 500, 'none'],
  ['red caída', { diditThrows: true }, 'didit_unreachable', 0, 'none'],
  ['201 sin url', { diditBody: '{"session_id":"ses-1","session_token":"tok12345abcd"}' }, 'didit_bad_link', 201, 'kept'],
  ['201 sin session_id', { diditBody: '{"url":"https://verify.didit.me/session/tok12345abcd"}' }, 'didit_missing_fields', 201, 'none'],
  ['201 con url que no es https', { diditBody: '{"session_id":"ses-1","url":"javascript:alert(1)"}' }, 'didit_bad_link', 201, 'kept'],
  ['201 con JSON roto', { diditBody: '{no es json tok12345abcd' }, 'didit_bad_json', 201, 'none'],
] as const) {
  test(`pedir la verificación: ${name} → falla clara, sin simular éxito y sin datos en el registro`, async () => {
    const { fn, calls } = fakeFetch(begin, opts);
    let r: Awaited<ReturnType<typeof handleStart>> | undefined;
    const logs = await captureLogs(async () => {
      r = await handleStart(start(), base, fn);
    });
    assert.equal(r!.status, 502);
    assert.deepEqual(r!.body, { error: 'HMY_IDENTITY_SEND_FAILED', reason, didit_status: status });
    assert.ok(calls.some((c) => c.url.endsWith('/rpc/hmy_identity_failed')));
    assert.equal(calls.some((c) => c.url.endsWith('/rpc/hmy_identity_attach')), false);
    assert.equal(calls.some((c) => c.method === 'DELETE'), false, 'un id que no es UUID nunca se borra');
    assert.equal(logs, `HMY_IDENTITY_SEND_FAILED code=${reason} didit_status=${status} cleanup=${cleanup}`);
    assert.doesNotMatch(logs + JSON.stringify(r!.body), sensitive);
  });
}

test('enlace de Didit: solo https://verify.didit.me (lo que documenta Didit)', () => {
  assert.equal(diditLink('https://verify.didit.me/en/session/Yk7pQ2vN8aBc'), 'https://verify.didit.me/en/session/Yk7pQ2vN8aBc');
  assert.equal(diditLink('https://VERIFY.didit.me/session/abc'), 'https://verify.didit.me/session/abc');
  for (const bad of [
    'http://verify.didit.me/session/abc',
    'https://verify.didit.me.evil.com/session/abc',
    'https://evil.com/verify.didit.me/session/abc',
    'https://verify-didit.me/session/abc',
    'https://didit.me/session/abc',
    'https://verification.didit.me/v3/session/',
    'https://user:pw@verify.didit.me/session/abc',
    'https://verify.didit.me:8443/session/abc',
    'javascript:alert(1)',
    'verify.didit.me/session/abc',
    '',
    42,
    null,
    'https://verify.didit.me/' + 'a'.repeat(3000),
  ]) {
    assert.equal(diditLink(bad), null, String(bad).slice(0, 60));
  }
});

test('pedir la verificación: un enlace de otro dominio no se guarda ni se entrega', async () => {
  const { fn, calls } = fakeFetch(begin, { diditBody: '{"session_id":"ses-1","url":"https://verify.didit.me.evil.com/session/x"}' });
  let r: Awaited<ReturnType<typeof handleStart>> | undefined;
  await captureLogs(async () => {
    r = await handleStart(start(), base, fn);
  });
  assert.deepEqual(r!.body, { error: 'HMY_IDENTITY_SEND_FAILED', reason: 'didit_bad_link', didit_status: 201 });
  assert.equal(calls.some((c) => c.url.endsWith('/rpc/hmy_identity_attach')), false);
});

test('pedir la verificación: url y verification_url se revisan por separado', async () => {
  const cases = [
    ['{"session_id":"ses-1","url":"https://evil.com/x","verification_url":"https://verify.didit.me/session/ok1"}', 'https://verify.didit.me/session/ok1'],
    ['{"session_id":"ses-1","url":12345,"verification_url":"https://verify.didit.me/session/ok2"}', 'https://verify.didit.me/session/ok2'],
    ['{"session_id":"ses-1","url":"https://verify.didit.me/session/ok3","verification_url":"basura"}', 'https://verify.didit.me/session/ok3'],
  ] as const;
  for (const [diditBody, expected] of cases) {
    const { fn, calls } = fakeFetch(begin, { diditBody });
    const r = await handleStart(start(), base, fn);
    assert.equal(r.status, 200, diditBody);
    assert.equal((r.body as { verification_url: string }).verification_url, expected);
    assert.equal(JSON.parse(calls.find((c) => c.url.endsWith('/rpc/hmy_identity_attach'))!.body).p_url, expected);
  }
});

for (const [name, deleteStatus, cleanup] of [
  ['y se borra en Didit', 200, 'deleted'],
  ['y Didit no deja borrarla (permiso)', 403, 'delete_failed'],
] as const) {
  test(`pedir la verificación: Didit creó la sesión pero la base no la guardó ${name}`, async () => {
    const { fn, calls } = fakeFetch(begin);
    const failing = async (url: string, init?: RequestInit) => {
      if (url.endsWith('/rpc/hmy_identity_attach')) {
        calls.push({ url, method: 'POST', body: String(init?.body ?? ''), headers: {} });
        return new Response('boom', { status: 500 });
      }
      if (init?.method === 'DELETE') {
        calls.push({ url, method: 'DELETE', body: '', headers: Object.fromEntries(new Headers(init?.headers).entries()) });
        return new Response('{"detail":"no permission didit-key"}', { status: deleteStatus });
      }
      return fn(url, init);
    };
    let r: Awaited<ReturnType<typeof handleStart>> | undefined;
    const logs = await captureLogs(async () => {
      r = await handleStart(start(), base, failing);
    });
    assert.equal(r!.status, 500);
    assert.deepEqual(r!.body, { error: 'HMY_IDENTITY_UNAVAILABLE' }, 'no se entrega un enlace que la base no guardó');
    const del = calls.find((c) => c.method === 'DELETE')!;
    assert.equal(del.url, `https://verification.didit.me/v3/session/${SID}/delete/`);
    assert.ok(calls.some((c) => c.url.endsWith('/rpc/hmy_identity_failed')), 'el intento queda como fallido');
    assert.equal(logs, `HMY_IDENTITY_UNAVAILABLE code=session_not_saved reason=db_error cleanup=${cleanup}`);
    assert.doesNotMatch(logs + JSON.stringify(r!.body), sensitive);
  });
}

// ---------------------------------------------------------------------------
// Regresión: enlace guardado, sesión sin enlace válido y sesiones reutilizadas
// ---------------------------------------------------------------------------
const ownSession = (extra: Record<string, unknown> = {}) =>
  JSON.stringify({
    session_id: SID,
    session_token: 'tok12345abcd',
    url: 'https://evil.example/session/tok12345abcd',
    status: 'Not Started',
    workflow_id: '1b2c3d4e-0000-4000-8000-00000000abcd',
    vendor_data: 'pro-1',
    ...extra,
  });

/** Responde distinto en cada llamada a una función de la base (la última se repite). */
function sequenced(fn: (url: string, init?: RequestInit) => Promise<Response>, calls: { url: string; method: string; body: string; headers: Record<string, string> }[], name: string, answers: unknown[]) {
  let n = 0;
  return async (url: string, init?: RequestInit) => {
    if (url.endsWith(`/rpc/${name}`)) {
      calls.push({ url, method: 'POST', body: String(init?.body ?? ''), headers: {} });
      const a = answers[Math.min(n++, answers.length - 1)];
      return a instanceof Response ? a : new Response(JSON.stringify(a));
    }
    return fn(url, init);
  };
}

for (const bad of [
  'https://evil.example/session/x',
  'http://verify.didit.me/session/x',
  'https://verify.didit.me.evil.io/session/x',
  'javascript:alert(1)',
  '',
]) {
  test(`retomar: un enlace guardado que no es de Didit nunca se entrega (${bad || 'vacío'})`, async () => {
    const { fn, calls } = fakeFetch({});
    const f = sequenced(fn, calls, 'hmy_identity_begin', [
      { allowed: true, resume: true, id: 4, verification_url: bad },
      { allowed: true, resume: false, id: 9 },
    ]);
    let r: Awaited<ReturnType<typeof handleStart>> | undefined;
    const logs = await captureLogs(async () => {
      r = await handleStart(start(), base, f);
    });
    assert.equal(r!.status, 200);
    assert.deepEqual(r!.body, { verification_url: 'https://verify.didit.me/session/tok12345abcd', sandbox: true });
    assert.equal(JSON.stringify(r!.body).includes(bad || '\u0000'), false);
    assert.deepEqual(JSON.parse(calls.find((c) => c.url.endsWith('/rpc/hmy_identity_forget_link'))!.body), { p_check: 4 });
    assert.equal(calls.filter((c) => c.url.endsWith('/rpc/hmy_identity_begin')).length, 2);
    assert.equal(logs, 'HMY_IDENTITY_BAD_SAVED_LINK');
    assert.doesNotMatch(logs, sensitive);
  });
}

test('retomar: un enlace guardado válido se entrega normalizado, sin llamar a Didit', async () => {
  const { fn, calls } = fakeFetch({
    hmy_identity_begin: { allowed: true, resume: true, id: 4, verification_url: 'https://VERIFY.didit.me/session/abc' },
  });
  const r = await handleStart(start(), base, fn);
  assert.deepEqual(r.body, { verification_url: 'https://verify.didit.me/session/abc', sandbox: true });
  assert.equal(calls.some((c) => c.url.includes('didit.me')), false);
  assert.equal(calls.some((c) => c.url.endsWith('/rpc/hmy_identity_forget_link')), false);
});

test('retomar: si no se puede descartar el enlace malo, error y no se entrega', async () => {
  const { fn, calls } = fakeFetch({ hmy_identity_begin: { allowed: true, resume: true, id: 4, verification_url: 'https://evil.example/x' } });
  const f = sequenced(fn, calls, 'hmy_identity_forget_link', [new Response('boom', { status: 500 })]);
  let r: Awaited<ReturnType<typeof handleStart>> | undefined;
  await captureLogs(async () => {
    r = await handleStart(start(), base, f);
  });
  assert.deepEqual(r!.body, { error: 'HMY_IDENTITY_UNAVAILABLE' });
  assert.equal(calls.some((c) => c.url.includes('didit.me')), false);
});

test('retomar: si la base vuelve a dar un enlace malo, se corta (sin bucle)', async () => {
  const { fn, calls } = fakeFetch({ hmy_identity_begin: { allowed: true, resume: true, id: 4, verification_url: 'https://evil.example/x' } });
  let r: Awaited<ReturnType<typeof handleStart>> | undefined;
  await captureLogs(async () => {
    r = await handleStart(start(), base, fn);
  });
  assert.deepEqual(r!.body, { error: 'HMY_IDENTITY_UNAVAILABLE' });
  assert.equal(calls.filter((c) => c.url.endsWith('/rpc/hmy_identity_begin')).length, 2);
  assert.equal(calls.some((c) => c.url.includes('didit.me')), false);
});

/** Corre handleStart con una base y un Didit dados; devuelve respuesta, llamadas y registro. */
async function runStart(rpcs: Record<string, unknown>, diditBody: string, deleteStatus = 200, failRpc?: string[]) {
  const { fn, calls } = fakeFetch({ ...begin, ...rpcs }, { diditBody });
  const f = async (url: string, init?: RequestInit) => {
    const rpc = url.match(/\/rpc\/(\w+)$/)?.[1];
    if (rpc && failRpc?.includes(rpc)) {
      calls.push({ url, method: 'POST', body: String(init?.body ?? ''), headers: {} });
      return new Response('boom', { status: 500 });
    }
    if (init?.method === 'DELETE') {
      calls.push({ url, method: 'DELETE', body: '', headers: {} });
      return new Response('{}', { status: deleteStatus });
    }
    return fn(url, init);
  };
  let r: Awaited<ReturnType<typeof handleStart>> | undefined;
  const logs = await captureLogs(async () => {
    r = await handleStart(start(), base, f);
  });
  return { r: r!, calls, logs };
}

test('sin enlace válido: la sesión recién creada para este profesional se borra antes de marcar el fallo', async () => {
  const { r, calls, logs } = await runStart({}, ownSession());
  assert.deepEqual(r.body, { error: 'HMY_IDENTITY_SEND_FAILED', reason: 'didit_bad_link', didit_status: 201 });
  const free = calls.findIndex((c) => c.url.endsWith('/rpc/hmy_identity_session_free'));
  const del = calls.findIndex((c) => c.method === 'DELETE');
  const failed = calls.findIndex((c) => c.url.endsWith('/rpc/hmy_identity_failed'));
  assert.deepEqual(JSON.parse(calls[free].body), { p_check: 9, p_session_id: SID });
  assert.equal(calls[del].url, `https://verification.didit.me/v3/session/${SID}/delete/`);
  assert.ok(free < del && del < failed, 'primero se confirma, luego se borra, después se marca el fallo');
  assert.equal(calls.some((c) => c.url.endsWith('/rpc/hmy_identity_attach')), false);
  assert.equal(logs, 'HMY_IDENTITY_SEND_FAILED code=didit_bad_link didit_status=201 cleanup=deleted');
  assert.doesNotMatch(logs, sensitive);
});

test('sin enlace válido: si Didit no deja borrar, se registra y el intento igual queda fallido', async () => {
  const { r, calls, logs } = await runStart({}, ownSession(), 403);
  assert.equal(r.status, 502);
  assert.ok(calls.some((c) => c.url.endsWith('/rpc/hmy_identity_failed')));
  assert.equal(logs, 'HMY_IDENTITY_SEND_FAILED code=didit_bad_link didit_status=201 cleanup=delete_failed');
});

for (const [name, extra, rpcs, failRpc] of [
  ['es de otro profesional', { vendor_data: 'pro-2' }, {}, []],
  ['no dice de quién es', { vendor_data: null }, {}, []],
  ['es de otro flujo', { workflow_id: '9f9f9f9f-0000-4000-8000-000000000000' }, {}, []],
  ['ya estaba en curso (Didit reutilizó una abierta)', { status: 'In Progress' }, {}, []],
  ['ya tenía un estado final', { status: 'Approved' }, {}, []],
  ['el id no es un UUID', { session_id: '../../v3/session/otra' }, {}, []],
  ['otro intento de la base ya la usa', {}, { hmy_identity_session_free: false }, []],
  ['la base no puede confirmar que esté libre', {}, {}, ['hmy_identity_session_free']],
] as const) {
  test(`sin enlace válido: no se borra una sesión que ${name}`, async () => {
    const { r, calls, logs } = await runStart(rpcs, ownSession(extra), 200, [...failRpc]);
    assert.equal(r.status, 502);
    assert.equal(calls.some((c) => c.method === 'DELETE'), false);
    assert.ok(calls.some((c) => c.url.endsWith('/rpc/hmy_identity_failed')));
    assert.equal(logs, 'HMY_IDENTITY_SEND_FAILED code=didit_bad_link didit_status=201 cleanup=kept');
    assert.doesNotMatch(logs, sensitive);
  });
}

const goodOwn = (extra: Record<string, unknown> = {}) => ownSession({ url: 'https://verify.didit.me/session/tok12345abcd', ...extra });

test('sesión reutilizada: Didit devuelve la misma sesión abierta y la base la enlaza al intento que ya la tenía', async () => {
  const { r, calls, logs } = await runStart(
    { hmy_identity_attach: { saved: true, check: 4, reused: true } },
    goodOwn({ status: 'In Progress' }),
  );
  assert.deepEqual(r.body, { verification_url: 'https://verify.didit.me/session/tok12345abcd', sandbox: true });
  assert.equal(calls.some((c) => c.method === 'DELETE'), false);
  assert.equal(calls.some((c) => c.url.endsWith('/rpc/hmy_identity_failed')), false);
  assert.equal(logs, '');
});

test('sesión reutilizada: si la base dice que es de otro profesional, no se entrega ni se borra', async () => {
  const { r, calls, logs } = await runStart(
    { hmy_identity_attach: { saved: false, reason: 'session_conflict' }, hmy_identity_session_free: false },
    goodOwn(),
  );
  assert.deepEqual(r.body, { error: 'HMY_IDENTITY_UNAVAILABLE' });
  assert.equal(calls.some((c) => c.method === 'DELETE'), false);
  assert.ok(calls.some((c) => c.url.endsWith('/rpc/hmy_identity_failed')));
  assert.equal(logs, 'HMY_IDENTITY_UNAVAILABLE code=session_not_saved reason=session_conflict cleanup=kept');
});

test('base caída: si no se puede guardar ni confirmar, la sesión no se borra (Didit la devuelve al reintentar)', async () => {
  const { r, calls, logs } = await runStart({}, goodOwn(), 200, ['hmy_identity_attach', 'hmy_identity_session_free']);
  assert.deepEqual(r.body, { error: 'HMY_IDENTITY_UNAVAILABLE' });
  assert.equal(calls.some((c) => c.method === 'DELETE'), false);
  assert.equal(logs, 'HMY_IDENTITY_UNAVAILABLE code=session_not_saved reason=db_error cleanup=kept');
});

test('base caída: una sesión ya en curso nunca se borra aunque la base no la guarde', async () => {
  const { r, calls } = await runStart({}, goodOwn({ status: 'In Progress' }), 200, ['hmy_identity_attach']);
  assert.equal(r.status, 500);
  assert.equal(calls.some((c) => c.method === 'DELETE'), false);
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
