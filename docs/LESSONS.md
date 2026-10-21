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
