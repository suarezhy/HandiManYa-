# Funciones de Supabase (Edge Functions)

## send-otp — entrega del código de 6 dígitos (WhatsApp o SMS)

Supabase Auth genera, vence y verifica el código. Esta función solo lo entrega,
como "Send SMS hook". **Está apagada**: no se despliega ni se activa sin la
aprobación del dueño, porque cada mensaje lo cobra el proveedor.

Sin credenciales de un proveedor no envía nada y responde con un error claro
(`HMY_OTP_CHANNEL_OFF`); nunca simula un envío. No pasa sola de WhatsApp a SMS:
la app ofrece "Recibirlo por SMS" y la persona elige.

Antes de enviar, pregunta a la base (`hmy_otp_gate`, migración 0013) si se puede:
solo celulares de Bolivia (+591 6/7), 1 por minuto, 5 por hora y 10 por día por
número, 300 por hora en total. Supabase no le dice a la función qué canal
eligió la persona; la app lo guarda antes con `choose_code_channel`.

### Activarla (cuando el dueño lo apruebe)

1. Elegir proveedor(es): WhatsApp Cloud API (Meta) con una plantilla de
   autenticación aprobada, y/o SMS por Twilio. Ver
   `/mnt/project-files/research/phone-otp-providers.md` (precios y requisitos).
2. Desplegar: `supabase functions deploy send-otp --no-verify-jwt --project-ref yldqopeldibwgbwmdnzy`
   (la firma del hook reemplaza al JWT).
3. Secretos de la función (Dashboard → Edge Functions → Secrets), nunca en el repositorio:
   - `SEND_SMS_HOOK_SECRET` (lo genera Supabase al crear el hook, formato `v1,whsec_...`)
   - WhatsApp: `WHATSAPP_TOKEN`, `WHATSAPP_PHONE_NUMBER_ID`, `WHATSAPP_TEMPLATE` (opcional `WHATSAPP_TEMPLATE_LANG`, por defecto `es`)
   - SMS: `TWILIO_ACCOUNT_SID`, `TWILIO_AUTH_TOKEN` y `TWILIO_MESSAGING_SERVICE_SID` o `TWILIO_FROM`
4. Authentication → Sign In / Providers → Phone: activar. Authentication → Hooks →
   Send SMS → HTTPS → URL de la función.
5. Authentication → Rate limits / Phone: código de 6 dígitos, vence en 300 s,
   60 s entre envíos. En Twilio, permitir solo Bolivia (Geo Permissions).

### Pruebas

`node --experimental-strip-types --test supabase/functions/send-otp/send-otp.test.ts`
(corren también en CI; no llaman a ningún proveedor).
