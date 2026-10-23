// Supabase Edge Function: el profesional pide su verificación de identidad
// (Didit). Devuelve el enlace de Didit. La lógica está en ../_shared/didit.ts.
// Secretos: DIDIT_API_KEY, DIDIT_WORKFLOW_ID, DIDIT_SANDBOX y opcional
// DIDIT_CALLBACK_URL (ver supabase/functions/README.md).
import { handleStart, handleSync } from '../_shared/didit.ts';

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const path = new URL(req.url).pathname;
  const env = Deno.env.toObject();
  const result = path.endsWith('/sync') ? await handleSync(req, env, fetch) : await handleStart(req, env, fetch);
  return new Response(JSON.stringify(result.body), {
    status: result.status,
    headers: { 'Content-Type': 'application/json' },
  });
});
