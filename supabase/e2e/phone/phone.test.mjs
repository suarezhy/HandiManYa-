// Prueba del ingreso por celular contra el proyecto de DESARROLLO, solo con
// números de prueba de Supabase (código fijo, ningún mensaje real). Ningún
// proveedor de WhatsApp o SMS está conectado: un número que no es de prueba
// recibe un error claro y nadie recibe un mensaje.
//
// Variables: E2E_URL, E2E_ANON_KEY, E2E_TEST_PHONE (+5917xxxxxxx), E2E_TEST_OTP.
// Uso: node --test supabase/e2e/phone/phone.test.mjs
import { test } from 'node:test';
import assert from 'node:assert/strict';

const URL_ = process.env.E2E_URL;
const ANON = process.env.E2E_ANON_KEY;
const PHONE = process.env.E2E_TEST_PHONE;
const OTP = process.env.E2E_TEST_OTP;
const ready = URL_ && ANON && /^\+591[67]\d{7}$/.test(PHONE ?? '') && /^\d{6}$/.test(OTP ?? '');

async function auth(path, body, token) {
  const res = await fetch(`${URL_}/auth/v1/${path}`, {
    method: body === undefined ? 'GET' : 'POST',
    headers: { apikey: ANON, 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    ...(body !== undefined ? { body: JSON.stringify(body) } : {}),
  });
  let json = null;
  try {
    json = await res.json();
  } catch {
    // Sin cuerpo JSON.
  }
  return { status: res.status, json };
}
// Solo códigos de error: nunca el número, el código ni un token.
const code = (r) => `HTTP ${r.status} ${r.json?.error_code ?? r.json?.code ?? ''}`.trim();
const wrongOtp = () => (OTP === '000000' ? '111111' : '000000');

let userId;

test('configuración de la prueba', () => {
  assert.ok(ready, 'faltan E2E_URL, E2E_ANON_KEY, E2E_TEST_PHONE (+591 6/7 y 7 dígitos) o E2E_TEST_OTP (6 dígitos)');
});

test('número de prueba: pedir el código funciona sin enviar nada', { skip: !ready }, async () => {
  const r = await auth('otp', { phone: PHONE, create_user: true });
  assert.equal(r.status, 200, `pedir el código: ${code(r)} (Phone activado y número de prueba cargado?)`);
});

test('número de prueba: un código equivocado no entra', { skip: !ready }, async () => {
  const r = await auth('verify', { type: 'sms', phone: PHONE, token: wrongOtp() });
  assert.notEqual(r.status, 200, 'un código equivocado no debe entrar');
  assert.equal(r.json?.access_token, undefined);
});

test('número de prueba: el código correcto crea la cuenta y entra', { skip: !ready }, async () => {
  await auth('otp', { phone: PHONE, create_user: true });
  const r = await auth('verify', { type: 'sms', phone: PHONE, token: OTP });
  assert.equal(r.status, 200, `verificar: ${code(r)}`);
  assert.ok(r.json?.access_token, 'sin sesión');
  const me = await auth('user', undefined, r.json.access_token);
  assert.equal(me.status, 200);
  assert.equal(me.json?.phone, PHONE.slice(1), 'Supabase guarda el número sin "+"');
  userId = me.json.id;
});

test('número de prueba: al volver a entrar es la misma cuenta', { skip: !ready }, async () => {
  assert.ok(userId, 'la prueba anterior no creó la cuenta');
  const sent = await auth('otp', { phone: PHONE, create_user: true });
  assert.equal(sent.status, 200, `pedir el código otra vez: ${code(sent)}`);
  const r = await auth('verify', { type: 'sms', phone: PHONE, token: OTP });
  assert.equal(r.status, 200, `verificar otra vez: ${code(r)}`);
  assert.equal(r.json?.user?.id, userId);
});

test('un número fuera de Bolivia se rechaza (pasa por nuestra función, que no envía nada)', { skip: !ready }, async () => {
  // +1 555 01xx: rango reservado para ficción en Norteamérica, no es de nadie.
  const r = await auth('otp', { phone: '+15555550123', create_user: true });
  assert.notEqual(r.status, 200, 'un número fuera de Bolivia no debe recibir código');
  console.log(`fuera de Bolivia: ${code(r)} ${String(r.json?.msg ?? r.json?.message ?? '').slice(0, 40)}`);
});
