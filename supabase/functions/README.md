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

## identity-check y didit-webhook — verificación de identidad (Didit)

Decisión del dueño: **solo el sandbox gratis de Didit** hasta que autorice otra
cosa. Ningún carnet real, nada pagado. La lógica está en `_shared/didit.ts`.

- `identity-check` (con la sesión del profesional): crea o retoma una sesión de
  Didit y devuelve el enlace. Antes pregunta a la base (`hmy_identity_begin`,
  migración 0017): solo con postulación enviada, máximo 3 intentos reales al mes,
  y la compuerta de costos (`hmy_cost_gate`, migración 0016). En sandbox nunca
  se cobra; en real se frena al acabar el plan gratis si no hay autorización.
  - `POST .../identity-check/sync` con la clave del servidor: consulta las sesiones
    sin respuesta y borra en Didit las ya decididas (Didit reintenta los avisos
    solo 2 veces). Se puede programar cada 15 minutos con pg_cron + pg_net.
  - Sesiones repetidas (migración 0019, `hmy_identity_attach`): Didit devuelve la
    misma sesión abierta si se pide otra para el mismo profesional y la misma
    versión del flujo; la base la enlaza al intento que ya la tenía y nunca acepta
    la de otro profesional. Un enlace guardado se revisa otra vez antes de
    entregarlo. Una sesión sin enlace válido o que la base no guardó se borra en
    Didit solo si es claramente la recién creada (UUID, mismo profesional y flujo,
    "Not Started") y ningún otro intento la usa. Borrar necesita el permiso
    `delete:sessions` en la clave de Didit.
  - **Orden al desplegar:** primero la migración 0019, después `identity-check`.
- `didit-webhook` (sin JWT): verifica `X-Signature-V2` (y `X-Timestamp`, 5 min),
  guarda solo estado, puntajes y códigos de aviso (nunca nombre, fecha de
  nacimiento, número de carnet ni imágenes) y, con una decisión final, borra la
  sesión en Didit (así también sale del entrenamiento de sus modelos).
- Un aviso del sandbox nunca puede marcar una verificación real (la base lo
  rechaza), y una verificación del sandbox nunca cuenta para aprobar.
- El resultado de Didit no aprueba a nadie: aprueba una persona del equipo.
- **El modo real está cerrado en el código** (`LIVE_ENABLED = false` en
  `_shared/didit.ts`). Ningún secreto lo abre: con `DIDIT_SANDBOX=false` las
  funciones responden `HMY_IDENTITY_LIVE_LOCKED` sin llamar a Didit. Abrirlo pide
  un PR aprobado por el dueño. Además, la base frena todo uso real no autorizado.

### Activar el sandbox (cuando el dueño lo apruebe)

1. El dueño crea una cuenta en Didit y una aplicación en modo **sandbox**, con un
   flujo (workflow) de carnet + prueba de vida + comparación facial. No hace
   falta tarjeta.
2. Desplegar y probar: subir la rama `supabase/didit-dev` (workflow
   `didit-dev.yml`). Revisa el proyecto, el cierre del modo real y los secretos,
   despliega las dos funciones solo en desarrollo y prueba el sandbox con una
   cuenta temporal. Necesita los secretos de GitHub `SUPABASE_DB_URL` y
   `SUPABASE_ANON_KEY`. Recomendado: **no** dar `SUPABASE_ACCESS_TOKEN` (alcanza
   todos los proyectos de la cuenta, también los de FlutterFlow). Sin él, el
   dueño despliega desde el panel (Edge Functions > Deploy a new function > Via
   Editor) los archivos que arma `supabase/scripts/bundle_didit.sh`, con
   "Verify JWT" apagado solo en `didit-webhook`, y el workflow prueba lo desplegado.
3. Secretos (Dashboard → Edge Functions → Secrets), nunca en el repositorio:
   `DIDIT_API_KEY`, `DIDIT_WORKFLOW_ID`, `DIDIT_WEBHOOK_SECRET`
   (opcional `DIDIT_CALLBACK_URL`).
4. En la consola de Didit, webhook → URL de `didit-webhook`.
5. Probar con los escenarios del sandbox (`sandbox_scenario`, `/simulate/`): aprobado,
   rechazado por documento vencido, revisión manual, abandono. No usar carnets reales.

### Pruebas

`node --experimental-strip-types --test supabase/functions/_shared/didit.test.ts`
(corren también en CI; no llaman a Didit).
