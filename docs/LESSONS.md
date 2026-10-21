# Lessons

One line per confirmed mistake: what went wrong, the rule now, and the test that guards it.

- **Read the vendor's API reference before coding an integration.** Didit's create-session reply puts the link in `url`, not `verification_url`, so valid sessions were treated as failures. Test mocks now copy the documented response. Guarded by `didit.test.ts`: "201 de Didit guarda session_id y url".
- **Don't trust a URL from an API or the database just because it's https.** Links are allowed only from `verify.didit.me`, and saved links are re-checked before they're returned. Guarded by `didit.test.ts`: "enlace de Didit" and "retomar".
- **Vendors may return an existing resource instead of creating one.** Didit returns the same open session for the same `vendor_data`, which broke our unique `session_id`. Migration 0019 links it to the attempt that already had it. Guarded by `95_identity_attach_tests.sql`.
- **Never delete a vendor resource you can't prove is yours.** Deletion needs a UUID, the same professional and workflow, "Not Started", and no other attempt using it. Guarded by `didit.test.ts`: "no se borra una sesión que…".
- **Log codes, not contents.** No vendor bodies, exception text, tokens, keys, user ids or document data in function logs. Every failure test asserts this.
- **A webhook header timestamp can be unsigned.** Check the signed body `timestamp` too, so an old signed body can't be replayed with a fresh header. Guarded by `didit.test.ts`: "un aviso firmado pero viejo no entra".
- **Webhooks can arrive before your own write.** Didit's "Not Started" can beat the session save, so retry, then return 500 so Didit retries. Guarded by `didit.test.ts`: "espera y reintenta".
- **A CI run that skips its tests must fail, not pass.** A missing secret is now a hard error in `didit-dev.yml`.
- **Diagnose secrets by name before changing code.** `SUPABASE_ANNON_KEY` (typo) looked like an empty `SUPABASE_ANON_KEY`. Workflows print only whether a secret is set and its length, never the value.
- **CI host checks scan comments too.** A `https://` link in a comment would have failed the "only Didit and the database" check. Write hosts in comments without the scheme.
- **Node's type stripping doesn't type-check.** `send-otp` passed its Node tests but failed `deno check` on a `Uint8Array` type. Bundled Edge Functions now always go through `deno check` before they're handed over for deploy.
- **Check the exact Edge Function name before testing a deploy.** Dev had `identity-check` and `Identity-check`; the new code went to the unused one. A failure reply without `reason`/`didit_status` means the old identity-check answered.
- **Sessions orphaned by old code come back.** Didit reuses an open session for the same `vendor_data`, so its "Not Started" webhook may never arrive again. The first sandbox run after a fix can miss that check; the next run starts clean.
- **Bienvenida: two crops of one photo are still the same picture.** Slides 2 and 4 used the same professional, so on the phone they looked identical. Each slide now has its own photo, and screenshots of all four are checked by eye before an APK. Guarded by `onboarding_layout_test.dart`: "cuatro fotos distintas" (catches repeated files, not repeated photos).
- **CI debug APKs are signed with a new key each run.** Android refuses to install one over another, so the phone can keep the old app. Uninstall before installing a new test APK, and check the build number in Perfil.
