// Supabase Edge Function: Didit avisa el resultado de una verificación.
// Se despliega sin JWT (--no-verify-jwt): la firma X-Signature-V2 lo reemplaza.
// La lógica está en ../_shared/didit.ts. Secretos: DIDIT_WEBHOOK_SECRET, DIDIT_API_KEY y DIDIT_SANDBOX.
import { handleWebhook } from '../_shared/didit.ts';

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const result = await handleWebhook(req, Deno.env.toObject(), fetch);
  return new Response(JSON.stringify(result.body), {
    status: result.status,
    headers: { 'Content-Type': 'application/json' },
  });
});
