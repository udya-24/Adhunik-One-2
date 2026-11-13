# Central AI verification

## Completed checks

| Check | Result |
| --- | --- |
| AI unit/orchestration tests | 17 passed; provider fully mocked |
| AI PostgreSQL integration tests | 19 passed against local PGlite with the actual migration and existing permission/identity function bodies |
| Combined `npm run test:ai` | 36 passed, zero failures |
| Existing permission + Item Master tests | 10 passed, zero failures |
| `npm run typecheck` | Passed on final source |
| `npm run lint` | Passed: zero errors; one existing unused-variable warning in `lib/hr/documents.ts` |
| `git diff --check` | Passed |

The settings regression was strengthened after the combined run to verify that sparse task overrides and empty override maps are valid, and a conversion rate requires a date. The final unit rerun again passed all 17 tests. No paid API request, Supabase migration, production write, commit, push or deployment was performed.

The database suite covers organization derivation, outsider/inactive-identity denial, ordinary-user opt-in permissions, underlying Item Master permission checks, browser/anonymous grants, private RPC restrictions, all four monetary limits, daily request limits, concurrency, simultaneous queued budget requests, duplicate request IDs, unknown usage, abandoned-reservation expiry, settlement, pricing history/immutability, emergency switches and monthly threshold events. PGlite serializes queued transactions on one connection; true simultaneous multi-connection locking should also be verified in staging.

## Build environment

The workspace initially had only a Windows Node installation that could not execute under this WSL environment. A temporary Linux Node.js 22.16 runtime was used for checks; it is outside the repository. The installed OpenAI SDK requires Node.js 22, and the project now declares Node >=22.16.

The normal Turbopack `npm run build` could not open its CSS worker's local port (`Operation not permitted`). The initial sandboxed webpack attempt could not read its TypeScript subprocess output; a direct diagnostic confirmed `spawnSync ... EPERM`. The webpack build was therefore rerun with the available execution approval. The final `npm run build -- --webpack` completed successfully (exit 0): production compilation, TypeScript, all 72 static pages, optimization and build traces. Default Turbopack remains unverified in this environment because of its worker-port restriction. A pre-existing warning about the parent-directory lockfile was also emitted.

## Operational acceptance still required

- Review/apply the incremental migration through your approved development/staging workflow; no connected database was changed here.
- Verify the UI in an authenticated browser against that database, including user permission assignments and no-key status.
- Add the manually managed server key, configure real current model pricing and approved budgets, then explicitly approve and initiate paid connection tests.
- Test true multi-connection PostgreSQL locking, deployment origins, hosting function limits and the emergency switch in staging.
- Review dependency security findings before production: npm reported 14 dependency-tree vulnerabilities (8 moderate, 4 high, 2 critical). No unrelated dependency upgrades or `npm audit fix --force` were performed.
- Binary document extraction, domain-specific purchase/sales/dispatch/finance features, retrieval/tools, native XLSX export, notifications and multi-company/branch memberships remain future work as detailed in the integration guide.

See [architecture, file manifest, setup and deployment checklist](central-ai-integration.md).
