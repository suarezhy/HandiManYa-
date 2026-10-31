# AI control center: audit of the 26 agents

What each agent in "Centro de Control IA" really does, checked against the code (migrations 0012, 0016, 0017, 0018 and 0036). No agent calls an AI model: the AI budget is 0 and the `ai_model` cost vendor is off. No agent approves professionals, suspends accounts, changes balances or spends money. The rule agents create items in the owner's inbox (`ai_items`), and a person decides.

## Categories and the "Activo" label

The seeded `ai_agents.status` is the agent's **category**:

| status | Category in the app | Meaning |
|---|---|---|
| `rules` | Funcionan con reglas sobre datos reales | SQL rules run on a schedule and with "Revisar ahora" |
| `ai` | Integraciones de IA en funcionamiento | None today |
| `needs_setup` | Esperan configuración | Built, but waiting for an account or the owner's approval |
| `planned` | Planificados o sin construir | Nothing runs |

**"Activo" is never a category.** The app shows "Activo" only when `admin_ai_agents()` reports `execution = 'active'`, which means the agent's latest run in `ai_agent_runs` succeeded within its `max_gap_minutes` (180 minutes for hourly agents, 26 hours for the daily report). Otherwise the card says "Sin ejecución reciente", "Última ejecución falló", "Sin ejecuciones registradas", "No corre: falta configurar" or "No corre: sin construir". The last successful run is read only from `ai_agent_runs`.

Since 0036, every check writes one `ai_agent_runs` row **per agent that actually ran a check**, with a summary ("N regla(s) revisada(s); M aviso(s) nuevo(s)") or, on failure, only the SQL error code. If one agent's rule fails, that agent's run is recorded as failed and the others keep going. `last_run_at` changes only for agents that ran. Before 0036, the hourly monitor set `last_run_at` on 11 agents at once, and the rule agents, the cost monitor and the on-demand daily report left no run row at all.

## Schedules (pg_cron, when the project has it)

| Job | Schedule | Function | Agents that get a run row |
|---|---|---|---|
| `hmy-monitors` | minute 7 of every hour | `run_marketplace_monitors()` | wallet, dispatch, background, quality, fraud, disputes, support, privacy, moderation, ai_auditor, then boss (the whole pass) |
| `hmy-cost-monitors` | minute 12 | `run_cost_monitors()` | finance |
| `hmy-rule-agents` | minute 17 | `run_rule_agents()` | service_safety, punctuality, background, pro_assistant |
| `hmy-daily-report` | minute 2 (only generates at the chosen hour) | `run_daily_report_if_due()` | daily_report |

"Revisar ahora" calls `admin_run_all_checks()` (owner only): rule agents, then costs, then monitors, so the AI auditor runs last and sees failures from the same pass. It is recorded in the audit log as `ai.run_checks`. "Generate now" (`admin_generate_daily_report`) also writes a `daily_report` run row.

## The 26 agents

| # | Agent (key) | Category | Trigger / schedule | Data sources | What it really does | Depends on | What's missing |
|---|---|---|---|---|---|---|---|
| 1 | AI Boss (`boss`) | Rules | Hourly monitors, "Revisar ahora" | `ai_agent_runs`, `ai_items` | Coordinates the hourly pass: one run row for the whole pass, with how many new items and which agents failed. Its last successful run is the "Última revisión completa" on the dashboard. It does not prioritize with AI or decide anything. | pg_cron or "Revisar ahora" | AI summaries and prioritization (needs an AI budget) |
| 2 | Identity (`identity`) | Waiting for setup | When a professional starts verification (no schedule) | `identity_checks`, Didit webhook | Didit ID, liveness and face match, sandbox only (`LIVE_ENABLED = false`). It creates an alert only for non-sandbox declined or in-review results, so today it never does. A person decides. | Didit (sandbox), Edge Functions `identity-check`, `didit-webhook` | Owner approval for live use |
| 3 | Background and documents (`background`) | Rules | Minutes 7 and 17 | `professional_profiles`, `professional_documents` | Applications waiting more than 48 h; approved professionals without an accepted ID (high); documents expired (high) or expiring within 30 days | — | Reading REJAP or police certificates is done by a person |
| 4 | Customer assistant (`customer_assistant`) | Planned | — | — | Nothing runs. Customers pick the category and problem from lists. | — | Free-text understanding needs AI (budget) |
| 5 | Smart dispatch (`dispatch`) | Rules | Minute 7 | `bookings` | ¡Ya! requests not accepted after 15 minutes: a recommendation to widen the search. The database still decides who can accept. | — | — |
| 6 | Pro assistant (`pro_assistant`) | Rules | Minute 17 | `professional_profiles`, `professional_documents` | A draft application with no documents after 2 days: tells the professional once what is missing (in-app notification). | `notify()` | Writing help needs AI |
| 7 | Support (`support`) | Rules | Minute 7 | `support_tickets` | Tickets open more than 24 h without an answer. A person answers. Before 0036 it was shown as "falta configurar" although this rule ran. | — | Automatic answers need AI |
| 8 | Wallet (`wallet`) | Rules | Minute 7 | `wallets`, `wallet_ledger`, `topup_requests` | Balance different from the ledger (critical); top-up pending more than 24 h; the same receipt number on several top-ups (high). It never changes balances or approves top-ups. | — | — |
| 9 | Finance (`finance`) | Rules | Minute 12, and at every metered use | `cost_vendors`, `cost_usage`, `ai_agent_runs` | Free-tier use, projected charges, near-cap and blocked vendors; the cost gate stops unauthorized spending. Commission revenue is in the daily report. | `hmy_cost_gate` | Monthly expenses that aren't metered are not recorded |
| 10 | QA / bug hunter (`qa`) | Planned | — | — | Nothing runs in the app. Tests run in GitHub Actions. | — | Crash reporting (for example Sentry), with approval |
| 11 | Fraud and safety (`fraud`) | Rules | Minute 7 | `user_reports` | Open harassment or fraud reports (high); an account reported by 3+ people in 30 days (high). These are reports, not proven facts; nobody is suspended. | — | Off-app payment detection |
| 12 | Marketing (`marketing`) | Planned | — | — | Nothing runs. | — | AI budget |
| 13 | Recruitment (`recruitment`) | Planned | — | — | Nothing runs. Before 0036 it was shown as working with rules. | — | Targets per city and category |
| 14 | Reviews and quality (`quality`) | Rules | Minute 7 | `reviews` | Two or more 1–2 star reviews in 30 days for the same professional. | — | — |
| 15 | Launch and compliance (`launch`) | Planned | — | — | Nothing runs. Before 0036 it was shown as working with rules. | — | Store accounts (paid, with approval) |
| 16 | Punctuality (`punctuality`) | Rules | Minute 17 | `booking_arrivals`, `bookings` | 3+ arrivals more than 15 minutes late in 30 days (from the arrival code). It only alerts. | Arrival PIN (0014) | Not in the daily report yet |
| 17 | Daily report (`daily_report`) | Rules | Once a day at the chosen hour (6:00 Miami), or "Generate now" | Bookings, wallet, reports, `ai_items`, `ai_agent_runs` | Real-data report with up to 5 fixed-rule priorities. 0036 fixed the security count, which used a non-existent `sos` agent; it now counts `service_safety`. | pg_cron for the automatic run | Expenses, crashes, uptime (listed as "not available") |
| 18 | Professional performance (`performance`) | Planned | — | — | Nothing runs. | — | — |
| 19 | Disputes (`disputes`) | Rules | Minute 7 | `disputes`, `bookings` | Disputes open more than 48 h (high). It doesn't sort evidence or propose solutions. | — | Evidence summaries need AI |
| 20 | Fair pricing (`pricing`) | Planned | — | — | Nothing runs. | — | Enough completed jobs |
| 21 | Moderation (`moderation`) | Rules | Minute 7 | `user_reports` | Content reported as inappropriate; the team decides whether to hide it. | — | Reviewing unreported photos or text needs AI |
| 22 | Privacy (`privacy`) | Rules | Minute 7 | `profiles` | Account deletion requests older than 7 days. | — | Document retention checks |
| 23 | Invoicing (`invoicing`) | Planned | — | — | Nothing runs. | — | Accountant review and invoicing system access |
| 24 | Service safety (`service_safety`) | Rules | Minute 17 | `bookings`, `booking_events`, `booking_arrivals` | "En camino" for more than 3 h without a verified arrival (high); arrivals verified by staff without a code (low). It is not an emergency service. | — | Push notifications |
| 25 | Messaging (`notifications`) | Planned | — | — | Nothing runs as an agent. In-app notifications exist; push, WhatsApp and SMS don't. | — | APNs/push, paid messaging, with approval |
| 26 | AI auditor (`ai_auditor`) | Rules | Minute 7 (last in the pass) | `ai_agent_runs`, `ai_agents`, `app_settings` | Failed runs in the last 24 h from **every** check (monitors, rules, costs, report); rule agents with a schedule that went past `max_gap_minutes` without a successful run ("Un agente dejó de ejecutarse"); AI spending this month above the budget (high). Before 0036 it saw only the hourly monitor's own failures. | The run rows from 0036 | Prompt-injection checks matter only once an agent uses AI |

## Which rules can create a high or critical item

| Severity | Agent | Rule (`dedupe_key` prefix) | Record |
|---|---|---|---|
| critical | wallet | `wallet-mismatch`: balance ≠ ledger | `wallets` |
| high | wallet | `topup-dup`: same receipt on several top-ups | `topup_requests` |
| high | fraud | `report-serious`: open harassment or fraud report | `user_reports` |
| high | fraud | `many-reports`: 3+ reporters in 30 days | `profiles` |
| high | disputes | `dispute-late`: open more than 48 h | `disputes` |
| high | service_safety | `trip-stuck`: "en camino" more than 3 h | `bookings` |
| high | background | `no-ci`: approved without an accepted ID | `professional_profiles` |
| high | background | `doc-expiry:…:expired`: accepted document expired | `professional_documents` |
| high | finance | `cost:<vendor>:blocked` or `:near_cap` (cost monitor); `cost:<vendor>:free_tier_exhausted` or `:monthly_cap` (cost gate) | `cost_vendors` |
| high | identity | `identity:<check>:declined` (live checks only, so not today) | `professional_profiles` |
| high | ai_auditor | `ai-over-budget`: AI spending above the budget | `app_settings` |

The dashboard's "Altas" counter counts high items that are open, waiting for more information or waiting for approval (`admin_ai_overview`). AI recommendations (`source = 'ai'`) can also be high, but no agent creates them today.

### The high alert the owner saw

The dev project can't be queried from this workspace, so the specific alert can't be named here. Its source is now visible in the app:

1. "Estado general" lists every open critical or high alert under "Alertas críticas y altas", with its agent, rule and time.
2. Tapping it opens "Origen del aviso": the agent (number and name), the rule (from the `dedupe_key` prefix, in plain Spanish), whether it's a rule on real data or an AI recommendation, the record it points to (`target_table` and `target_id`), when it was created, the evidence, the decision and the audit history.
3. "Ya lo resolví" and "Descartar" ask for a note (at least 3 characters; the database rejects an empty note with `HMY_NOTE_REQUIRED`). The decision goes through `admin_decide_ai_item` and is written to `admin_audit_log` (`ai_item.completed`, `ai_item.dismiss`, ...), which the detail page shows. Approving an item still executes nothing: no code reads `proposed_action`.

With the dev data, the most likely sources are `no-ci` (professionals approved before the ID requirement in 0032), `topup-dup` (test top-ups reusing a receipt number) or a `cost:` alert. The detail page shows which one it is.

## Database functions added in 0036

- `admin_run_all_checks()`: "Revisar ahora", owner only.
- `admin_ai_agents()`: agents with their latest run, last successful run, 24-hour counts, open items and `execution`, owner only.
- `admin_ai_item_detail(id)`: an item with its source and audit history, owner only.
- `hmy_log_agent_run(...)`, `hmy_agent_run_ok(...)`: internal (revoked from public, anon and authenticated; granted to service_role).
- `run_marketplace_monitors`, `run_rule_agents`, `run_cost_monitors`, `generate_daily_report`, `run_daily_report_if_due`, `admin_generate_daily_report`, `admin_ai_overview`, `admin_decide_ai_item`: replaced from their latest definitions.

Tests: `supabase/tests/99e_truthful_agents_tests.sql` and `test/ai_control_center_test.dart`.
