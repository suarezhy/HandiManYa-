# HandiMan ¡Ya! — notes for Claude

Flutter (iOS, Android, web) + Supabase app for on-demand home services in Bolivia. The UI is in Spanish. See README.md for the layout and demo mode. Lessons from past mistakes: docs/LESSONS.md (read it before touching an area it mentions).

## Standing rules (from the owner)
- Customer safety comes first. Never weaken professional verification or customer safety to save money. No SOS button that promises an app response; an "Emergencia" link in active requests (public emergency numbers, trip sharing, safety report, clearly not an emergency service) was approved on 2026-10-21.
- Never touch the old FlutterFlow app or its Supabase projects. Only the dev project `yldqopeldibwgbwmdnzy` is ours.
- Work on `feature/base-app` (PR #1). Never merge PR #1, deploy, apply migrations, publish apps, enable paid services, or switch Didit to live without the owner's explicit approval for that step.
- Didit stays sandbox-only: `LIVE_ENABLED = false` in `supabase/functions/_shared/didit.ts`.
- Never ask for, read or store the service_role key, DB password, connection string or a Supabase personal access token. Only the project URL and the publishable (anon) key may be requested. No secrets or personal data in code, logs or docs.
- Keep the launch date out of the repo.
- Report results honestly: a skipped or unexecuted test is never "passed".
- Finish the existing app first. Don't add dependencies or replace working technology without approval.

## Before every push
```
export PATH=/opt/flutter-sdk/flutter/bin:$PATH
flutter analyze && flutter test
node --experimental-strip-types --no-warnings --test supabase/functions/_shared/didit.test.ts
node --experimental-strip-types --no-warnings --test supabase/functions/send-otp/send-otp.test.ts
PGHOST=... PGPORT=... PGUSER=postgres supabase/tests/run_local.sh   # all migrations + SQL tests, local only
```
Edge Function bundles for the dashboard: `supabase/scripts/bundle_didit.sh <dir>` and `bundle_send_otp.sh <dir>`, then always `deno check` the bundle.

## Database
- Migrations are additive and numbered (`supabase/migrations/<timestamp>_<name>.sql`, in order); each one gets a test file in `supabase/tests/` and is listed in `supabase/tests/run_remote.sql`.
- New functions called by the app or Edge Functions go in `supabase/scripts/verify_remote.sql`.
- Permissions live in the database (RLS + security definer functions); the app never decides them. Server-only functions: revoke from public/anon/authenticated, grant to service_role.

## Remote checks (GitHub Actions only; the dev project isn't reachable from the workspace)
Pushing HEAD to these branches runs a workflow against dev, only with the owner's approval:
- `supabase/aplicar-dev` applies migrations;
- `supabase/didit-dev` runs the Didit sandbox tests;
- `supabase/e2e-dev` runs the end-to-end test;
- `supabase/phone-dev` tests phone sign-in with a Supabase test number (no messages sent).
