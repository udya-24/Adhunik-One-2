# Item Master timeout: live diagnosis and permanent read/preview fixes

13-Nov-2026. This task made only narrowly scoped read-only GET requests against the configured Supabase project. No products, import records, stock, authentication sessions or production schema were created/changed. No push or deployment was performed. The starting working tree was clean; historical migrations and the earlier inventory implementation are preserved.

## Root cause and evidence

The error must be separated into **historical failed confirmation** and **a new request failure**.

The configured database contains exactly the two reported sources:

| Batch | Created, IST | State | Evidence |
| --- | --- | --- | --- |
| `089a895e-ded9-49c1-b94e-8955f7edabd5` | 12-Nov, 5:02:22 PM | PREVIEW | 1,994 rows; two saved `IMPORT_ATTEMPT_FAILED` events |
| `962ad08e-49ce-455d-b0c1-762a7278c897` | 12-Nov, 5:53:04 PM | COMMITTED | Result: 1,994 created, zero reused/failed/skipped |

Both saved timeout messages belong to the **older PREVIEW batch**, at **5:03:17 PM** and **5:04:12 PM IST**. Their exact stored message is `canceling statement due to statement timeout`.

The repository's original action at commit `1285a1f`, `commitItemWorkbook` in `app/(erp)/inventory/items/import/actions.ts`, calls **`commit_item_import`** and writes the caught error through **`record_item_import_failure`**. That is the matching historical event producer. The original database confirmation ran full-workbook preview revalidation, six classification resolutions per product, and product/link writes in one transaction. The earlier resumable migration already disables this obsolete entry point and replaces it with bounded transactions.

The later successful job is `5771db8e-3bad-4257-87d4-5348fb40f5b2`: **40 completed chunks**, 39 × 50 rows plus 44 rows, every chunk attempted once, recorded execution times **104.234–300.190 ms**. Completion was recorded at 5:55:51 PM IST. These are observed persisted production chunk timings, not a local benchmark.

The application was displaying the saved failure JSON again in the old preview's audit, without labeling it as a historical event. The old identical PREVIEW also continued to offer validation/confirmation despite a separate fully completed source. That combination made a failed earlier attempt remain actionable and its timeout message appear current. The fix preserves and clearly labels the events, links to the completed source, prevents another confirmation of the fully imported identical workbook, and avoids regenerating it.

**Limits of this diagnosis:** no authenticated browser request was captured. A saved audit event establishes the earlier failure, not that every newly observed error is merely historical. The precise inner PostgreSQL statement cancelled in the original RPC is unavailable without cancellation logs. Every new read/action now emits its own operation name, target, reference, elapsed time and error code, so a genuinely new failure can be distinguished immediately.

## What was checked live

Reads used the existing server credential without printing it. That role bypasses RLS, so the following do not claim browser-role performance:

- Exact recent-batch query: HTTP 200; both expected sources returned; approximately 1.91 s including initial connection.
- Exact committed header query: HTTP 200; 647 ms; 1,994 rows and successful result confirmed. No workbook binary/source rows were selected.
- First audit-page metadata query: HTTP 200; 1.327 s; successful job history present.
- Chunk metadata: HTTP 200; 492 ms; all 40 chunks completed, no saved chunk errors.
- Older preview header: HTTP 200; 498 ms.
- Read-migration `source_row_count`: available, 1,994 for both sources.
- Legacy stock proposals: empty. **The legacy stock-snapshot freshness RPC is therefore not the cause for these batches.** This corrects the earlier unverified hypothesis.
- Opening-stock import jobs: empty. No inventory approval/posting was initiated by these diagnostics.
- Read-only progress RPC with the configured server-role token: rejected by its active-Admin identity check. This is expected; no user identity was impersonated or new login created.

PostgREST EXPLAIN requests returned **406 / PGRST107** because plan responses are disabled. No production setting was changed to enable them. No Vercel login/project link/token, Supabase Management token or direct SQL connection was available, so Vercel runtime logs, Supabase PostgreSQL cancellation logs and live role-specific execution plans could not be obtained. The existing service key is not a Management API token. Local PostgreSQL plans were inspected instead; no live plan/index existence claim is inferred from source migration files.

## Implemented changes

### Completed-source protection

A new active-Admin-only `completed_item_import_source` RPC finds an identical digest/worksheet that is COMMITTED **and has source links for every source row**. Its digest lookup uses a partial index. Partial workbook selections do not suppress remaining rows.

- Re-uploading a fully imported workbook returns the existing source ID before classification validation, staging insertion or audit insertion.
- Opening the older identical PREVIEW shows the completed-import link and disables confirmation without running recovery or loading full preview rows.
- Database checks in `start_item_import_job` and `refresh_item_import` also reject obsolete identical previews. An older client cannot bypass the UI guard.
- A COMMITTED detail page uses its saved result; it no longer aggregates all job rows to rediscover completed progress.
- Existing products, batch states, staging JSON and failed audit events remain unchanged. Nothing is cancelled/deleted to conceal the old failure.

### Pagination and query performance

- Recent import sources: 25 rows per page, stable created-time/UUID ordering, one-row lookahead.
- Item Master preview: **100 saved rows per request** through `item_import_preview_page`, with state/revision checks and a hard 100-row database cap. JSONB array subscripts fetch the requested slice; the RPC never invokes preview generation or classification lookups.
- Initial valid-row selection IDs are returned once as small metadata; client selection persists across page changes. Confirmation submits the complete selected set across all pages, not just visible rows.
- Audit: existing 50-event stable pagination preserved, with explicit projected columns.
- During explicit preview generation only, classification lookups use an invocation-local cache keyed by exact input and applicable parent state/UUID. Exact-match preference, inactive/ambiguous states, subgroup parents and generated location codes retain their original behavior. The cache is not persisted across validations, so later master changes remain visible.
- Expression indexes match normalized item-code and category/type/unit/location lookup predicates. The normalized-code index also serves recovery and opening-stock item matching. Existing subcategory/classification/read indexes remain in place.

In the 2,000-row local repeated-master test, classification resolution dropped from **12,000 calls to 29**, with exact preview equality against the original implementation. Local EXPLAIN verified the normalized-code index for point lookup. This does not claim a particular live query plan.

### Operation-specific errors

`runImportQuery` wraps recent sources, batch header, audit, source reuse, saved preview, recovery, progress and all import mutations. A failure names the exact operation and table/RPC, shows the PostgreSQL/API code and a random reference matching structured server logs. Schema mismatch, lock contention, timeout and transport failure are distinguished. Logs contain no credentials, workbook rows, response bodies or backend SQL details. New failures remain visible; they are not replaced with a generic migration instruction.

Historical failure events remain visible with their original message/timestamp under **“Historical failed attempt — saved audit event, not a new request.”** Existing no-automatic-retry and per-chunk atomicity behavior is preserved, including separate interrupted-request reconciliation and lost-success protection.

### Separate inventory import

The existing **Stock Register → Import Opening Stock from Excel** feature remains available and is linked from the Item Master import page. It reuses committed source rows, validates Item Code/Unit/Location, provides editable usable/rejected proposals, and requires a separate active-Admin approval before posting. The previously confirmed accounting rule remains: Opening qty is usable; rejected quantity is additional non-saleable stock, with its own balance and immutable ledger movement. Item Master import still never posts inventory.

The new combined database test applies the latest migration and confirms that preview and even approval setup leave balances/ledger untouched, then explicitly posts one selected usable/rejected row, retries the request without duplication, and checks unchanged Item Master records.

## Exact files changed in this task

- `app/(erp)/inventory/items/import/page.tsx`: recent-source pagination, operation-specific read error, inventory-import link.
- `app/(erp)/inventory/items/import/[id]/page.tsx`: completed-source recognition, saved completed result, bounded preview RPC, historical audit labels and visible query errors.
- `app/(erp)/inventory/items/import/actions.ts`: named diagnostics, no automatic staging retries, saved-preview page action, original interruption codes retained.
- `app/(erp)/inventory/items/import/forms.tsx`: paginated preview with cross-page selection retention.
- `lib/inventory/import/diagnostics.ts`: safe structured operation diagnostics and audit labels.
- `lib/inventory/import/types.ts`: preview-page contract.
- `lib/database.types.ts`: new read RPC contracts.
- `supabase/migrations/202611130003_item_import_preview_and_recovery.sql`: new read RPCs, digest guards, preview cache and matching indexes.
- `tests/item-import-diagnostics.test.mjs`: timeout/transport/schema labeling, safe logs and historical labels.
- `tests/item-import-preview-database.mjs`: migration preservation, preview/cache/paging, partial/full source reuse, duplicate guards, separate stock approval, RLS and EXPLAIN checks.
- `docs/sql/committed-import-timeout-diagnostics.sql`: read-only failure/chunk/plan diagnostics.
- This report and the README report link.

## Migration instructions

Required new migration: **`202611130003_item_import_preview_and_recovery.sql`**. Prerequisites are the repository's prior item/import/inventory migrations, including `202611130001` and `202611130002`. Do not rerun historical migrations that are already applied. The live count column confirms the read migration is present, but does not certify every prerequisite's migration history.

Apply first to a disposable local Supabase database:

```sh
psql "$LOCAL_DATABASE_URL" -v ON_ERROR_STOP=1 \
  -f supabase/migrations/202611130003_item_import_preview_and_recovery.sql
```

This migration creates indexes/functions only; it does not backfill, delete, reimport or post business records, and does not increase a timeout. Normal index creation takes DDL locks; schedule any separately authorized production migration appropriately. Use the updated application together with the new RPCs. No remote migration or deployment was performed here.

Use `docs/sql/committed-import-timeout-diagnostics.sql` for read-only operator verification. After an authorized release, open the COMMITTED batch directly, then the older PREVIEW; the latter should link to the completed source. Re-upload the original file only in a test instance to check reuse. Verify cross-page selection and separate stock approval with test users. Do not confirm the old production preview or post production stock to test the fix.

## Verification

- **136 automated tests passed**, including three new diagnostic/error-history tests.
- **11 new database checks passed** against all incremental import migrations, including 2,000-row pagination, exact cached-preview equality, 29-versus-12,000 lookup instrumentation, partially completed source handling, unchanged products/history, completed-source reuse, obsolete-preview denial, separate approved usable/rejected posting with retry idempotency, Admin/anonymous denial and expression-index EXPLAIN.
- **9 rejected opening-stock database checks passed**, including 2,000 rows and exact separate rejected totals, rollback/resumption and inventory duplicate protection.
- **12 resumable Item Master database checks passed**.
- **TypeScript passed**; lint completed with zero errors and the pre-existing unused `pageH` warning in `lib/hr/documents.ts`.
- **Production webpack build passed**, including TypeScript and generation of 66 static pages. It ran locally outside the sandbox because the sandbox cannot reliably capture Next.js detached TypeScript subprocess output; no deployment occurred.
- `git diff --check` passed. No historical migration or unrelated Purchase/Dispatch/Finance service was changed.

Automated database tests use disposable local PGlite PostgreSQL and synthetic fixtures; live diagnostics are read-only. The separate inventory test explicitly checks no quantity changes before posting. Authenticated browser acceptance, native multi-connection cancellation tests for this new migration, and live cancellation-log capture remain unavailable as described above.

Reproduce locally with Node 22.16+ and the repository's optional PGlite runtime:

```sh
npx tsc --noEmit --incremental false
npm run lint
node --experimental-strip-types --experimental-test-isolation=none --test tests/*.test.mjs
node tests/item-import-preview-database.mjs
node tests/rejected-opening-stock-database.mjs
node tests/item-import-resumable-database.mjs
npm run build -- --webpack
```

