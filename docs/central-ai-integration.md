# Central OpenAI integration

## Architecture assessment

The repository was clean before implementation. This is Next.js 16.3.2 App Router, TypeScript and Supabase SSR, with a server-only service-role helper already used for administrative work. `lib/security/access.ts`, `erp_permission_sections`, `erp_user_permissions`, `has_erp_permission`, `get_my_erp_permissions` and `is_erp_admin` implement section View/Edit access. Existing access templates and employee onboarding remain intact. Configuration uses module tabs and existing card/field/button styles. Installed Next.js Route Handler and Server Function documentation was read before implementation.

The ERP is **single organization**: profiles/employees have no tenant or branch memberships; `customer_companies` are customers. AI uses a fixed organization UUID, constrained in `ai_settings`, and derives it only from an active ERP profile, role and existing employee-access validation. A browser cannot select an organization. This preserves existing isolation rather than misusing customer records as tenants. Supporting multiple operating companies or branch partitions later requires an explicit membership design across the ERP, not just an AI setting.

Audit tables are domain-specific (`erp_access_audit` accepts only permission-change events; payroll and Item Master activities have domain foreign keys). A separate narrow `ai_audit_events` table is therefore appropriate. No generic audit framework, authentication system or parallel role system was introduced. Environment conventions are `.env.local`, server-only `SUPABASE_SERVICE_ROLE_KEY`, and browser-safe Supabase URL/anon key. OpenAI was not installed before this work.

## Implemented foundation and initial features

- One server-only OpenAI SDK client factory using the Responses API, fixed official endpoint, `store:false`, no automatic SDK retries, bounded request timeout, response-length policy and configurable output limits.
- Typed feature registry and strict Zod schemas. Browser input cannot select arbitrary models, instructions, output limits, company IDs, identities or database tools.
- Administrator-only AI Configuration, manual model identifiers, project-access validation on enabling, immutable pricing versions, task assignments, emergency disable, individual feature switches, model blocklist and user restrictions.
- Actual explicit connection tests, including budget reservation and usage accounting. Tests work while global AI is disabled, require charge confirmation and an Admin, and do not run on page load. Runtime models require a successful test bound to the current key fingerprint. Changing a key requires retesting.
- General assistant: questions, user-text summarization, ERP terminology and structured answers. No automatic ERP table retrieval or write tools.
- Inventory matching: link from Item Master, existing session/RLS search, at most ten minimized candidate records, validated candidate IDs and explanations, optional selection and links to review existing items. Selection never edits inventory. Existing deterministic Item Master/search validation remains authoritative.
- Central PostgreSQL accounting, concurrency and limits; pricing snapshots; explicit unknown usage; reconciliation; request-ID duplicate prevention; denied-request audit records; threshold alerts.
- Usage dashboard with date/user/department/module/feature/model filters, current budget balances, request outcomes, reported tokens, response duration, daily/monthly cost charts, module/employee/model/feature breakdowns and streamed CSV export compatible with Excel. Aggregates are calculated in PostgreSQL over all matching rows; the on-screen request table shows the latest 100. CSV is paginated and protects spreadsheet formula cells.
- Interfaces are loaded dynamically when their pages are opened. Normal ERP workflows do not call OpenAI and do not depend on availability of the AI service.

## Request lifecycle and accounting

`requestAi` is the entry point for all ERP integrations. It verifies the Supabase user and existing permission functions, checks server key configuration and feature input, retrieves only authorized candidates if needed, then invokes the central engine.

`ai_reserve` is a **service-role-only** RPC. The actor argument comes from verified `auth.getUser()`, never the browser. It sets a transaction-local actor for existing authorization functions and locks the organization settings row. In one short transaction it checks enabled status, AI and underlying record permissions, restrictions, tested model/key, pricing, daily/monthly/personal/request budgets, daily request count, duplicate request IDs and concurrency. It records the pending request and reservation together. The transaction closes before any OpenAI network request.

Reservations include a conservative UTF-8 input-byte ceiling, schema/framing allowance and maximum output tokens at the highest applicable input/cache rate. Money uses PostgreSQL `numeric(24,9)` and integer arithmetic in the pure cost helpers; reservations round up to nanodollars. No cache discount is assumed in advance.

`ai_finalize`, also service-role-only, records usage and settles the reservation atomically using the original pricing snapshot. Reported token usage is authoritative. A response that fails schema validation still incurs its reported cost. A definitive HTTP 400/401/403/404/429 rejection releases an otherwise unused reservation. Network errors, timeouts, missing usage and unconfirmed finalization retain the full estimated charge. No invented token counts are written. If reported cost exceeds the reserve, AI is automatically disabled and an audit event is recorded.

Only explicit 429 rejections can retry, up to the configured limit (default zero), within a single timeout. Ambiguous network/5xx/timeouts never retry automatically. Repeating a request ID never replays a provider request; the caller receives a conflict and should review usage.

Abandoned reservations expire after two minutes. The private `ai_reconcile_expired(company_uuid)` RPC changes them to unknown, frees concurrency, and retains their full estimated charge. The service invokes recovery before new reservations in a separate committed transaction. An approved server scheduler can also invoke this RPC; no scheduler is deployed by this change. Known late results can settle an unknown reservation. No administrator UI silently releases unknown charges.

Monthly warning events are deduplicated for each threshold and month on finalization. Threshold history is visible in configuration. Current budget balances include outstanding and unknown reservations even when dashboard date filters differ. Calendar boundaries are Asia/Kolkata. Alerts are internal; no email/Slack notifications are sent.

**ERP budgets are application controls, not a guarantee that the OpenAI Platform invoice cannot exceed an exact amount.** Pricing accuracy, external use of the same project, unconfirmed provider charges and provider billing adjustments remain outside this application's control.

## Permissions

New sections are inserted into the existing permission catalog, with no ordinary-user grants:

| Section | Use |
| --- | --- |
| `configuration.ai_settings` | Configuration and connection tests; active Admin role also required |
| `configuration.ai_usage` | Usage dashboard and CSV export |
| `ai.use` | Baseline permission for AI features |
| `ai.general` | General assistant |
| `ai.inventory` | Inventory matching, also requires `inventory.items` View |
| `ai.purchase`, `ai.sales`, `ai.dispatch`, `ai.finance`, `ai.documents` | Catalog entries reserved for future integrations |

Existing Administrator implicit grants are preserved. An explicit AI user restriction also blocks an Admin's AI requests, but never prevents that Admin from opening configuration and correcting the restriction. Settings, feature and pricing mutations use existing Admin verification. Browser roles cannot write AI settings, pricing, logs, reservations or audits, or call accounting RPCs. Usage reads use RLS and the existing dashboard section permission. No service-role key is returned to clients.

## Local setup

1. Install Node.js 22.16+ (required by the installed OpenAI SDK; tests use native TypeScript stripping) and `npm ci`.
2. Manually create/select your OpenAI Platform project at <https://platform.openai.com/>. Configure API billing and project monitoring/spending notifications. Manually create a restricted project key suitable for the selected models. Key management stays with you.
3. Add `OPENAI_API_KEY` to ignored `.env.local` without a `NEXT_PUBLIC_` prefix. Keep existing Supabase variables. Never paste the value into chat, SQL, screenshots, source code or logs. The server-only Supabase service-role variable is also required for AI accounting.
4. Restart Next.js after environment changes. Without a key, development and mock tests still work; configuration shows “Not configured” and requests return a sanitized configuration error.
5. Review and apply **only to an approved development database** `supabase/migrations/202611130005_central_ai.sql` after existing migrations. This change does not apply it automatically. It is forward-only and leaves historical migrations untouched.
6. Sign in as an existing active ERP Admin and open **Configuration → AI Configuration**. Before migration, the page explains that database setup is unavailable.
7. Keep global AI disabled. Set the default/task model identifiers, reasonable output/timeout/retry/concurrency settings and USD budgets. Defaults intentionally contain no model/pricing and zero budgets; an administrator must approve actual amounts. For INR planning, optionally configure a positive USD/INR rate and its date; no conversion rate is assumed.
8. Add an immutable pricing version for each configured model using current official input/cached-input/output rates, source URL and effective timestamp. A past effective date is permitted; a future date is rejected by the form. Use a new version to correct rates; never overwrite history.
9. After explicit approval, select each assigned task's model in the connection-test selector, check the charge-consent box and click **Test connection**. This creates a real, minimal paid request and consumes the configured budgets. Model availability and actual Responses compatibility are verified through this request. No test is performed automatically by Codex or by rendering the page.
10. Enable the initial features and global AI. Enabling validates project model access and requires successful tests and pricing for all configured, unblocked models. Unsupported/unavailable/untested models cannot initiate normal requests.
11. Assign existing ERP users the appropriate sections via **ERP Access / Permission Management** or existing templates. General use needs `ai.use` and `ai.general`; inventory also needs `ai.inventory` and `inventory.items`. Configuration remains Admin-only.
12. Test `/ai` and the Item Master matching link, then inspect `/configuration/ai/usage`. Do not send unnecessary employee, banking or customer information.

## Checks and verification

```sh
npm run typecheck
npm run lint
npm run test:ai
npm run build
```

`test:ai` runs mocked provider orchestration and a local PGlite PostgreSQL database containing the new migration and the existing identity/permission functions. It never contacts OpenAI or Supabase. Test isolation is disabled so all individual assertions are visible in environments that restrict child-process output.

The tests exercise input/output validation, missing-key error behavior, invalid provider credentials, sanitized errors, prompt boundaries/redaction, read-only candidate restrictions, successful assistant/matching requests, retries/timeouts, accounting failures, permissions/RLS, disabled profiles and employees, budgets, concurrently queued reservations, duplicate IDs, pricing history, expiry, settlement, unknown usage, emergency controls and threshold events. Queued-request tests use a single PGlite connection; a true multi-connection PostgreSQL load test remains a staging validation task.

Implementation verification results are recorded in `docs/central-ai-verification.md`.

## Vercel deployment checklist (no deployment performed)

- Review source changes and the incremental migration. Back up the database according to your normal process.
- Rehearse the migration and permission configuration in development/staging; perform a real multi-connection reservation test on PostgreSQL.
- Confirm the chosen models, official current prices, approved budgets, user restrictions and retention policy.
- Manually set `OPENAI_API_KEY` in the intended Vercel server environment. Confirm existing Supabase URL/anon/service-role values and allowed origins. Do not put secrets in build arguments or public variables.
- Keep global AI disabled and all budgets explicitly approved. Apply the reviewed migration to production **only after separate approval** through your existing workflow. No production SQL was executed here.
- Confirm the hosting plan supports the endpoint's 60-second maximum; provider timeout is capped at 45 seconds. No streaming/background provider work is enabled.
- Obtain approval before pushing, committing or deploying; none is done by this implementation.
- Following approved deployment, verify Admin-only configuration, user permission denials, RLS, disabled feature behavior and no-key status.
- Obtain approval before the first paid connection test, then check its request/usage/reservation records and actual platform usage.
- Enable only approved features and users; verify budgets, alerts, export and emergency disable. Monitor unknown reservations, pricing updates, denied requests and provider limits.
- Configure an approved server reconciliation schedule if recovery must run even when no new AI requests occur. Configure retention/archive operations separately; no destructive cleanup job is included.
- Roll back feature availability with the emergency disable switch. Do not delete accounting history or reverse the forward migration casually.

## Limitations and future work

Binary document extraction, purchase/sales/finance/dispatch-specific AI, retrieval, tools, automatic record writes, persistent conversation history, durable background jobs, notifications, native XLSX export, and multi-company/branch memberships are not implemented. Future feature rows and model assignments remain disabled and are clearly labeled. The current document capability is user-supplied text analysis/summarization; no upload endpoint is exposed.

The assistant has no authority to change stock, prices, POs, payments, vouchers, records or permissions. Future writes must use a separate explicit human-approved ERP workflow. React escapes all answers and explanations; generated HTML/SQL/scripts never execute. Prompt instructions reduce injection risk but are not a standalone security guarantee; authorization, minimized data and absence of tools are the enforced boundaries.

Model availability uses official project metadata on enabling plus an explicit minimal Responses test. A model can lose access later, or reject a structured-output capability; runtime failures remain sanitized and isolated. Models/prices are deliberately not hardcoded. The credential is represented only by a SHA-256 fingerprint for test invalidation; the API key itself is never stored in the database.

Unknown charges may reserve more than the eventual invoice. Do not automatically release them based solely on elapsed time. Late provider evidence or an approved operational reconciliation is necessary. Current automatic recovery runs on the next request; a server scheduler is optional future deployment work. Auth/permission denials are audited when an active organization identity can be established; unauthenticated/malformed HTTP traffic does not fabricate usage rows. Valid rejected requests with an active identity are audited without prompt content.

No live OpenAI call, browser login session, production migration or deployment was used to verify this implementation. Browser-level ERP acceptance testing with actual permissions and an approved live provider test remains required before enabling production AI.

## File manifest

Created:

- `lib/ai/admin.ts`, `client.ts`, `config.ts`, `cost.ts`, `engine.ts`, `errors.ts`, `features.ts`, `inventory.ts`, `models.ts`, `permissions.ts`, `prompts.ts`, `report.ts`, `service.ts`, `types.ts`, `usage.ts`, `validation.ts`
- `app/(erp)/ai/page.tsx`
- `app/(erp)/configuration/ai/page.tsx`, `actions.ts`, `usage/page.tsx`
- `app/api/ai/route.ts`, `usage/export/route.ts`
- `components/ai/assistant.tsx`, `configuration.tsx`, `loaders.tsx`
- `supabase/migrations/202611130005_central_ai.sql`
- `tests/ai.test.mjs`, `tests/ai-database.test.mjs`
- `docs/central-ai-integration.md`, `docs/central-ai-verification.md`

Modified:

- `README.md` — Node runtime requirement and AI setup links
- `.env.example` — empty server-only key variable and manual-management note
- `app/(erp)/inventory/items/page.tsx` — permission-gated matching link
- `lib/database.types.ts` — AI rows and RPC types
- `lib/modules.ts` — AI Assistant navigation
- `lib/security/permissions.ts` — AI catalog/navigation sections
- `package.json`, `package-lock.json` — SDK, Zod, server-only, local PostgreSQL test dependency and check scripts
- `tsconfig.json` — typed source-extension imports for native Node test execution (`noEmit` remains enabled)
