# HandiMan ¡Ya!

On-demand services app for Bolivia (Santa Cruz, Cochabamba and La Paz).
Flutter (iOS, Android and web) + Supabase. The app itself is in Spanish.

- **¡Ya!** (the main idea): the customer asks for help now, every verified
  professional nearby who is available gets the offer, and the first one to
  accept takes the job.
- **Programar**: the customer picks a professional and a day and time.
- One account, two doors: "Necesito un servicio" (customer) and
  "Soy profesional" (provider). A professional can switch modes from Perfil.

## Try it without any setup (demo mode)

When the app is built without Supabase keys it runs in **demo mode** with
sample data kept in memory. A dark band at the top says "Modo demostración".

| Who | Email | Password |
| --- | --- | --- |
| Customer | `cliente@demo.bo` | `Demo1234` |
| Professional | `profesional@demo.bo` | `Demo1234` |

Email verification code for new demo accounts: `123456`.

What the demo simulates on its own:
- A ¡Ya! request is accepted by a nearby professional after about 5 seconds,
  who then sends a chat message.
- When the demo professional turns on "Disponible para ¡Ya!", a new offer
  arrives after a few seconds.
- A professional application is approved after about 8 seconds, and wallet
  top-ups are credited after about 6 seconds.

Web demo (updated on every merge to `main`):
https://suarezhy.github.io/HandiManYa-/

## Project layout

```
lib/
  core/        theme (brand colors, sizes), validators, formatters, shared widgets
  data/        models, repository contracts, Supabase backend, demo backend, providers
  features/    one folder per area: auth, home, search, booking, messages, pro_mode, profile…
  router.dart  every screen and the role-based redirects
supabase/
  migrations/  database schema, security rules (RLS) and server functions
  tests/       SQL tests run against a throwaway local PostgreSQL
test/          app tests (validators, the full ¡Ya! flow, every tab at normal and large text)
```

Location: the customer can share their GPS point (after a Spanish explanation
of why). Professionals set a base point and a radius in "Mi zona de trabajo".
Until a professional accepts, they only see a point rounded to about 1 km and
the distance; the exact address and point unlock after acceptance. Up to 5
problem photos per request, visible only to the customer, professionals with a
pending offer, and the assigned professional.

The app never decides permissions. Row level security and server functions in
the database do: who can see an exact address, who can accept an offer, wallet
movements, status changes.

## Checks

```bash
flutter analyze
flutter test
# Database: needs a local PostgreSQL 16, never a Supabase project
PGHOST=... PGPORT=... PGUSER=postgres supabase/tests/run_local.sh
```

GitHub Actions runs all three on every pull request.

## Supabase project: handimanya-flutter-dev

The real backend is a new, separate Supabase project, `handimanya-flutter-dev`
(ref `yldqopeldibwgbwmdnzy`). It has nothing to do with the old FlutterFlow
projects, and the tooling here refuses to connect to them.

`config/supabase-dev.json` holds the project URL and the **publishable** key.
Both are public by design: the database rules (RLS) protect the data. The
`service_role`/secret key and the database password never go in this repo.

```bash
flutter run --dart-define-from-file=config/supabase-dev.json
```

Without that file the app runs in demo mode, as before.

### Loading the database (only with the owner's OK)

The workflow `.github/workflows/supabase-migrations.yml` connects with the
repository secret `SUPABASE_DB_URL` (the "Session pooler" connection string,
which includes the database password). It checks the string points at
`yldqopeldibwgbwmdnzy` and stops for any other project.

- Push the branch `supabase/revisar-dev`: read-only check (lists tables).
- Push the branch `supabase/aplicar-dev`: applies every file in
  `supabase/migrations/` in **one transaction**. On the first error it stops
  and nothing is kept.

After applying:
1. Authentication → Email: turn on "Confirm email" and put `{{ .Token }}` in
   the "Confirm signup" and "Reset password" templates (6-digit codes).
2. Make the first admin: add a row `(user_id, 'admin')` to `user_roles`.
3. Commission rules start empty on purpose. The admin creates them in the panel.

## Still to do

- SMS phone verification needs a paid SMS provider.
- Terms and privacy texts are drafts and need review by a lawyer in Bolivia.
- App Store and Google Play publishing.

Fonts: Nunito, SIL Open Font License (`assets/fonts/OFL.txt`).
