// Supabase Edge Function: "Send SMS hook" de Supabase Auth. La lógica está en otp.ts.
// Se configura en Authentication → Hooks → Send SMS (HTTPS) apuntando a esta función.
// Secretos: SEND_SMS_HOOK_SECRET y los del proveedor (ver supabase/functions/README.md).
import { handleHook } from './otp.ts';

Deno.serve(async (req) => {
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405 });
  const result = await handleHook(req, Deno.env.toObject(), fetch);
  return new Response(JSON.stringify(result.body), {
    status: result.status,
    headers: { 'Content-Type': 'application/json' },
  });
});
