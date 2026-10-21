// Revisa los tres números de prueba por rol (cliente, profesional y admin)
// contra el proyecto de DESARROLLO. Solo pide un código: un número de prueba
// de Supabase responde 200 sin llamar a nuestra función de envío; un número
// que no está cargado como de prueba pasa por la función, que no envía nada
// (no hay proveedor pagado) y responde con HMY_OTP_BUDGET o _CHANNEL_OFF.
// No verifica ningún código ni crea sesiones.
//
// Variables: E2E_URL, E2E_ANON_KEY y EXISTING (números ya registrados, separados
// por comas, sin "+", para no crear cuentas nuevas al revisar).
// Uso: node supabase/e2e/phone/role_numbers.mjs
const URL_ = process.env.E2E_URL;
const ANON = process.env.E2E_ANON_KEY;
const existing = new Set((process.env.EXISTING ?? '').split(',').filter(Boolean));
const numbers = [
  ['Cliente', '+59170000001'],
  ['Profesional', '+59170000002'],
  ['Admin', '+59170000003'],
];
let missing = 0;
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
}
if (missing) {
  console.log(`::error::${missing} número(s) no están cargados como números de prueba en Supabase (Authentication > Sign In / Providers > Phone > Test phone numbers).`);
  process.exit(1);
}
