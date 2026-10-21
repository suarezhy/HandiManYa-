// Revisa los tres números de prueba por rol (cliente, profesional y admin)
// contra el proyecto de DESARROLLO. Solo pide un código: un número de prueba
// de Supabase responde 200 sin llamar a nuestra función de envío; un número
// que no está cargado como de prueba pasa por la función, que no envía nada
// (no hay proveedor pagado) y responde con HMY_OTP_BUDGET o _CHANNEL_OFF.
// Si existe ROLE_TEST_OTP (el código fijo de esos tres números), además entra
// con cada uno y muestra sus roles tal como los ve la propia cuenta. Falla si
// el cliente o el profesional de prueba tienen rol de administrador.
//
// Variables: E2E_URL, E2E_ANON_KEY, EXISTING (números ya registrados, separados
// por comas, sin "+", para no crear cuentas nuevas al revisar) y ROLE_TEST_OTP
// (opcional).
// Uso: node supabase/e2e/phone/role_numbers.mjs
const URL_ = process.env.E2E_URL;
const ANON = process.env.E2E_ANON_KEY;
const OTP = process.env.ROLE_TEST_OTP ?? '';
const existing = new Set((process.env.EXISTING ?? '').split(',').filter(Boolean));
const numbers = [
  ['Cliente', '+59170000001'],
  ['Profesional', '+59170000002'],
  ['Admin', '+59170000003'],
];
let missing = 0;
let wrongRole = 0;
async function rolesAfterSignIn(phone) {
  const v = await fetch(`${URL_}/auth/v1/verify`, {
    method: 'POST',
    headers: { apikey: ANON, 'Content-Type': 'application/json' },
    body: JSON.stringify({ type: 'sms', phone, token: OTP }),
  });
  const session = await v.json().catch(() => ({}));
  if (v.status !== 200 || !session.access_token) return { error: `HTTP ${v.status} ${session.error_code ?? ''}`.trim() };
  const r = await fetch(`${URL_}/rest/v1/user_roles?select=role&user_id=eq.${session.user.id}`, {
    headers: { apikey: ANON, Authorization: `Bearer ${session.access_token}` },
  });
  const rows = await r.json().catch(() => []);
  return { roles: Array.isArray(rows) ? rows.map((x) => x.role).sort() : [] };
}
for (const [role, phone] of numbers) {
  const res = await fetch(`${URL_}/auth/v1/otp`, {
    method: 'POST',
    headers: { apikey: ANON, 'Content-Type': 'application/json' },
    body: JSON.stringify({ phone, create_user: !existing.has(phone.slice(1)) }),
  });
  let body = {};
  try {
    body = await res.json();
  } catch {
    // Sin cuerpo JSON.
  }
  const reason = String(body.msg ?? body.message ?? body.error_code ?? '').match(/HMY_[A-Z_]+|over_sms_send_rate_limit/)?.[0];
  const ok = res.status === 200;
  const tooSoon = res.status === 429;
  if (!ok && !tooSoon) missing++;
  console.log(
    `${role} ${phone.slice(0, 7)}…${phone.slice(-2)}: ` +
      (ok
        ? 'número de prueba configurado (código fijo, sin envío)'
        : tooSoon
          ? 'pedido hace menos de 60 s, vuelve a correr la revisión'
          : `NO es número de prueba en Supabase (HTTP ${res.status} ${reason ?? ''})`),
  );
  if (!ok || !OTP) continue;
  const r = await rolesAfterSignIn(phone);
  if (r.error) {
    missing++;
    console.log(`  entrar con el código: FALLÓ (${r.error})`);
    continue;
  }
  console.log(`  entrar con el código: OK; roles: ${r.roles.join(', ') || 'ninguno'}`);
  if (role !== 'Admin' && r.roles.includes('admin')) wrongRole++;
  if (role === 'Cliente' && r.roles.includes('professional')) wrongRole++;
}
if (!OTP) console.log('Entrar con cada número: NO SE CORRIÓ (falta el secreto ROLE_TEST_OTP).');
if (wrongRole) {
  console.log('::error::El cliente o el profesional de prueba tienen un rol que no les corresponde.');
  process.exit(1);
}
if (missing) {
  console.log(`::error::${missing} número(s) no están cargados como números de prueba en Supabase (Authentication > Sign In / Providers > Phone > Test phone numbers).`);
  process.exit(1);
}
