// Supabase Edge Function: manda los avisos push en cola. La lógica está en push.ts.
// La llama un webhook de la base al insertar en push_outbox, con x-hmy-push-secret.
// Secretos: PUSH_WEBHOOK_SECRET, FCM_SERVICE_ACCOUNT y opcional PUSH_WEB_LINK (ver supabase/functions/README.md).
import { handlePush } from './push.ts';

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const result = await handlePush(req, Deno.env.toObject(), fetch);
  return new Response(JSON.stringify(result.body), {
    status: result.status,
    headers: { 'Content-Type': 'application/json' },
  });
});
