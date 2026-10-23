# Management roles: Propietario, Gerente de Operaciones, Empleado

Permissions are decided in the database, never by the app. Migrations:
`20261022003500_management_roles.sql` (roles, cases, permission checks) and
`20261022003700_owner_dashboard.sql` (owner metrics). Tests:
`supabase/tests/99d_management_roles_tests.sql`, `99f_owner_dashboard_tests.sql`,
`test/management_panels_test.dart`.

- **Propietario** = an account with the existing `admin` role (`is_admin()`).
  Everything financial stays behind `is_admin()`, unchanged.
- **Gerente** and **Empleado** = a row in `staff_members` (role `manager` or
  `employee`, status `active` / `suspended` / `revoked`), keyed by the
  authenticated user id. Only `owner_grant_staff` and `owner_set_staff_status`
  write it, and both require `is_admin()`. The migrations grant no role to
  any account.
- `hmy_staff_role()` returns `owner`, `manager`, `employee` or null (suspended,
  revoked, or suspended profile = null on the next call). `hmy_can(perm)`
  checks one permission from `hmy_role_permissions(role)`.
- Each panel is its own route tree (`/admin`, `/gerente`, `/empleado`); the
  router sends anyone else back to their own home. That is convenience only:
  every RPC re-checks.

## Permission matrix

| Action | Propietario | Gerente | Empleado |
|---|---|---|---|
| Owner dashboard: revenue, commissions, wallets, top-ups, costs | ✔ | ✘ | ✘ |
| Operations dashboard (counts only, no money) | ✔ | ✔ (team-wide) | ✔ (own cases) |
| See all cases / unassigned / escalated | ✔ | ✔ | ✘ (own only) |
| Assign and reassign cases | ✔ | ✔ | ✘ |
| Reply to support, internal notes | ✔ | ✔ | ✔ (assigned cases) |
| Resolve a case | ✔ | ✔ | Routine support/report only, with a note |
| Escalate | ✔ | ✔ (to owner) | ✔ (to manager) |
| Safety, fraud, dispute cases | ✔ | ✔ | Must escalate |
| Full application review | ✔ | ✔ | Basic profile only |
| Open identity documents | ✔ | ✔ | ✘ |
| Flag missing / questionable documents | ✔ | ✔ | ✔ |
| Accept or reject documents | ✔ | ✔ | ✘ |
| Approve or reject a professional | ✔ | ✔ only with CI accepted and identity check passed when required | ✘ |
| Approve over a declined identity check | ✔ (audited; CI documents must still be accepted) | ✘ (`HMY_IDENTITY_DECLINED`) | ✘ |
| Suspend customers or professionals | ✔ | ✔ (not staff, not owner) | ✘ |
| Resolve disputes (changes commission) | ✔ | ✘ (view and escalate) | ✘ |
| Refunds, wallet adjustments, top-up review | ✔ | ✘ | ✘ |
| Commission rules, platform settings, vendors, AI spending | ✔ | ✘ | ✘ |
| AI Control Center | ✔ | ✘ | ✘ |
| Create staff, change roles, suspend or revoke staff | ✔ | ✘ | ✘ |
| See team workload and response times | ✔ | ✔ | ✘ |
| Read the audit log | ✔ | ✘ | Own activity only |
| Update or delete the audit log | ✘ (append-only for app roles) | ✘ | ✘ |

Every sensitive action writes `admin_audit_log` with the actor and `by_role`.
Suspending or revoking a staff member returns their open cases to the
unassigned queue.

## Known limits

- The audit log is append-only for `anon` and `authenticated`; the database
  owner (used by CI cleanup) can still delete rows.
- Coverage gaps count approved professionals by home municipality only, not
  by service radius.
