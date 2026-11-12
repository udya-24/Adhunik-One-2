# Item Master confirmation timeout — implementation and verification

Date: 12-Nov-2026. This change is local. No configured Supabase database was queried, migrated or retried; no production item/stock records were changed, and nothing was committed, pushed or deployed.

## Diagnosis

The confirmation action made one `commit_item_import` RPC for the entire selected workbook. That database function held a batch-row lock and SHARE ROW EXCLUSIVE locks on six master tables plus Items while it:

1. Rebuilt and compared the entire 1,994-row preview.
2. Revalidated selected source rows.
3. Called six master-creation helpers for every product, even when earlier products had already resolved/created those classifications. On a fresh workbook, these helpers repeated name resolution for almost every product.
4. Inserted each item and source link separately. Normal classification/FK/cost/audit triggers added their required work.

There was no persistent intermediate progress. A statement timeout rolled back that entire RPC, and the application could not distinguish a rolled-back call from an earlier successful call whose response was lost without inspecting saved records.

The repository does not configure a timeout for the import RPC. Its separate go-live reset SQL has timeout settings but is unrelated and was neither run nor changed. Supabase documents role/API statement limits; the actual target project's settings and PostgreSQL cancellation log were not available here. Therefore the exact production instruction at which cancellation occurred remains unverified. The local measurements establish the expensive execution path rather than guessing that locks or validation alone caused the failure.

A disposable PGlite database running the actual Phase 7A/7B schema, original import migration, triggers and workbook measured the original confirmation as follows (identity/storage fixtures are local):

| Original phase | Local elapsed time |
| --- | ---: |
| Lock acquisition | 1 ms |
| Rebuild complete preview | 3,246 ms |
| Selected-row check | 23 ms |
| Repeated classification resolution/creation | 3,947 ms |
| Item/link writes including triggers | 3,283 ms |
| Whole confirmation, including other bookkeeping | 10,564 ms |

A preceding run measured 9,471 ms overall. Classification work and whole-file revalidation were substantial; the selected-row check and lock acquisition were not the primary cost in these uncontended runs. These are local timings, not a claim about the live project's hardware or actual lock waits.

Sources checked: [Supabase timeouts](https://supabase.com/docs/guides/database/postgres/timeouts) and [Supabase retry behavior](https://supabase.com/docs/guides/api/automatic-retries-in-supabase-js). Mutating import RPC calls explicitly disable client retries; uncertain/failed chunks require an explicit user Resume action.

## Implemented fix

New incremental migration: `supabase/migrations/202611120002_resumable_item_master_import.sql`. Historical migrations remain unchanged. No application/database timeout is increased.

The migration adds four private Admin-readable tables with no direct application write grants:

- `item_import_jobs`: one immutable approved selection per source batch, a unique start request key, preview revision, configurable batch size, preflight recovery counts, approver and RUNNING/PAUSED/COMPLETED state.
- `item_import_job_chunks`: stable request keys, PENDING/COMPLETED/FAILED state, attempts, safe last error, row counts, timings and committed created/reused totals.
- `item_import_job_rows`: indexed source rows, approved raw/preview data, pending or committed outcomes, stable item UUIDs and a compact cache of resolved master UUIDs.
- `item_import_job_masters`: reusable name/parent-to-UUID mappings scoped to the job, including whether that job created a master.

The initial maximum/default is 100 products per transaction; users can choose 1–100. Explicit Resume can lower the size. Remaining oversized chunks split into new pending metadata without deleting or reprocessing completed chunks.

Job creation expands the approved preview once and copies only selected valid rows. Each chunk then:

1. Locks the source/job and checks its persistent request key. Completed requests return current progress without performing writes.
2. Uses short NOWAIT table locks. Contention becomes a visible resumable error rather than a long lock wait.
3. Resolves categories first, then distinct category/subcategory pairs and the other four masters. Each distinct mapping is revalidated once per chunk against active state, parent, approved/cached UUID and generated location code. Existing inactive/ambiguous/renamed/reparented conflicts stop that chunk.
4. Resolves row-to-master UUIDs once using keyed cache lookups. Validation, insert and link operations use the compact row cache, avoiding repeated six-way mapping joins.
5. Rechecks existing item codes and supplied fields/COGS in sets. Identical products are reused with all existing fields, timestamps and UUIDs untouched. Conflicts or automatic-code violations stop the chunk. Existing source links are reconciled before insertion.
6. Inserts missing items in one INSERT…SELECT…RETURNING statement and records CREATED/REUSED outcomes from returned UUIDs. Links and progress rows are updated in sets. Existing constraints, RLS checks and audit triggers remain enabled.
7. Commits product/classification/link/progress/audit writes together for that chunk. A caught validation or write failure rolls back all business changes in that chunk and saves its failure state. A real statement cancellation rolls back the whole active RPC; a separate idempotent request records its interrupted status. A lost response after a successful commit cannot turn that committed chunk into a failed chunk.

The old whole-workbook `commit_item_import` entry point is disabled with a refresh/use-resumable message, so an old deployed client cannot silently invoke the expensive path. Apply the new migration and use the updated application together.

## Explicit atomicity change

**Each chunk is atomic. The entire workbook/job is intentionally not atomic.** The original all-or-nothing confirmation is replaced by a durable resumable job. If chunk 2 fails after chunk 1 committed, chunk 1 remains saved; chunk 2 contributes no product/master/link changes. Job progress and audit history report this partial completion.

The source batch remains IMPORTING or PARTIAL until every selected chunk completes. Only then does it become COMMITTED and receive its final summary. Stock proposal creation retains its existing COMMITTED-source requirement. No stock proposal function, posting rule, balance, opening/rejected quantity or ledger mechanism was altered.

## Checking the previous failed attempt

Before retrying, use `docs/sql/item-import-recovery-check.sql` for a read-only inspection of source batch state, commit summaries, committed links and timeout settings. The new import page also performs `item_import_recovery` as the signed-in Admin. Job creation stores this preflight count before any product writes.

For the original migration, a cancelled confirmation RPC is one transaction and rolls back its own business changes. That does **not** establish whether another earlier attempt succeeded. The recovery checks discover existing item-code matches and surviving links; every chunk rechecks them and safely reuses identical products. Conflicting products require administrator review and are never deleted or overwritten.

No live recovery counts are claimed in this report because no production connection was used.

## Interface behavior

The source header retains the workbook's total record count. Job progress shows selected records, newly imported items, already existing products, successfully processed records, pending and failed records, current/total/completed/failed batches and overall percentage. The UI explicitly explains per-batch atomicity.

One sequential request processes each chunk. A failed, uncertain or stalled response stops the runner; it never automatically retries that chunk. Closing the page stops dispatching further requests. On reopening, persisted progress is read and nothing resumes until the Admin selects **Retry / Resume Import**. The button can reduce batch size. Client busy guards/disabled controls prevent accidental double submission; database locks and persistent keys remain the authoritative protection across tabs or users.

Errors expose useful source-row conflicts and safe explanations for timeout, lock contention and changed references. SQL statements, private trigger error text, credentials and backend stack traces are not sent to the import UI. The downloadable report now includes persisted job/chunk outcomes and audit metadata, with paginated reads even when a one-product batch size produces over 1,000 chunks.

A selection is immutable after starting. If source data or an approved identifier genuinely needs a different mapping, correct/review a fresh workbook batch rather than silently altering an approved partially completed job. Previously committed identical item codes will be reused in the new batch.

## Files changed

- New migration `supabase/migrations/202611120002_resumable_item_master_import.sql`.
- `app/(erp)/inventory/items/import/actions.ts`: start, single-chunk processing, interruption recording and explicit resume.
- `app/(erp)/inventory/items/import/forms.tsx`: guarded sequential runner, progress, configurable batch size and Resume UI.
- `app/(erp)/inventory/items/import/[id]/page.tsx`: read-only recovery and durable progress.
- `app/(erp)/inventory/items/import/[id]/report/route.ts`: job/chunk report data.
- `lib/inventory/import/types.ts`, `lib/database.types.ts`: states, progress and RPC contracts.
- New `lib/inventory/import/runner.ts`: sequential orchestration and safe error messages.
- New tests: `tests/helpers/item-import-fixture.mjs`, `tests/item-import-benchmark.mjs`, `tests/item-import-resumable-database.mjs`, `tests/item-import-concurrency-database.mjs`, `tests/item-import-runner.test.mjs`.
- This report, the read-only recovery SQL and README's current operational instructions.

## Validation

- 125 automated tests passed, including runner sequencing, no automatic failure retry, paused/completed jobs, bounded stalled-response handling and sanitized errors.
- 13 resumable PostgreSQL checks passed: 2,000 synthetic products in 20 chunks; full 1,994-row workbook and reimport; all six mappings and 864 parent/group pairs; four-decimal/zero COGS; exact preservation of existing item records; stable request keys; lost success responses; rollback of only the failing chunk; smaller-size resume; source-unit/stock boundaries; RLS and audit/progress counts.
- Five separate native PostgreSQL checks passed using independent connections: simultaneous calls for one chunk, overlapping import jobs, genuine statement-timeout cancellation after an earlier chunk committed, concurrent ordinary table writers, and all 1,994 actual products under an 8-second per-statement test budget.
- Native PostgreSQL 18.6 full workbook: start 154 ms; 20 chunks; maximum chunk 201 ms; mean chunk 155 ms; total chunk execution about 3.10 seconds. PGlite full workbook: start 145 ms; maximum chunk 413 ms; mean chunk 279 ms. Timings vary by hardware/load; no hosted performance guarantee is implied.
- Original import migration regression: 22 checks passed. Finance regression: 16 checks passed.
- TypeScript: `npx tsc --noEmit --incremental false` passed.
- Lint: zero errors and one pre-existing unused-variable warning (`pageH` in `lib/hr/documents.ts`).
- Production build: `npm run build -- --webpack` passed, including the final TypeScript phase. Browser acceptance against a configured local Supabase instance remains a manual step; no authenticated browser session was exercised here.

All databases were disposable and local. Native PostgreSQL binaries were extracted into `/tmp`; a generated database name was used, only that database was removed afterward, the temporary PostgreSQL server was stopped after testing, and application environment credentials were not read. Existing Windows-only build binaries required restoring the lockfile's Linux optional packages locally; application dependency versions were not changed.

## Local verification and release steps

1. Run the read-only recovery SQL against the intended test database and inspect the source batch state before any retry. Confirm the actual target project's migration state and settings; do not rerun migration 001.
2. Apply **only migration 002** after migration 001 to a disposable local Supabase instance. Do not apply either file to production as part of this local verification:

   ```sh
   psql "$LOCAL_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/202611120002_resumable_item_master_import.sql
   ```

3. With Node 22.16+ and repository dependencies installed, run:

   ```sh
   npx tsc --noEmit --incremental false
   npm run lint
   node --experimental-strip-types --experimental-test-isolation=none --test tests/*.test.mjs
   node tests/item-import-database.mjs
   node tests/finance-database.mjs
   node tests/item-import-resumable-database.mjs
   ITEM_IMPORT_WORKBOOK='/mnt/e/Mayank Sir/Apps/Item master v5.xlsx' node --experimental-strip-types tests/item-import-resumable-database.mjs
   npm run build -- --webpack
   ```

   The local database tests reuse the optional cached PGlite runtime under `node_modules/.cache/gp-validation`. The benchmark script reads the original migration and instruments only an in-memory disposable copy; it never edits that historical file.

4. For the native concurrency suite, provide a disposable localhost PostgreSQL server and install the optional test client into the ignored cache:

   ```sh
   npm install --prefix node_modules/.cache/pg-concurrency --no-save pg
   ITEM_IMPORT_LOCAL_POSTGRES='postgresql://test_user@127.0.0.1:55493/postgres' ITEM_IMPORT_WORKBOOK='/mnt/e/Mayank Sir/Apps/Item master v5.xlsx' node --experimental-strip-types tests/item-import-concurrency-database.mjs
   ```

   The script rejects non-local hostnames, creates a uniquely named test database, and removes only that database. Its role fixtures are for a disposable PostgreSQL cluster; do not point it at a shared application cluster.

5. Point local application settings at the test Supabase instance, run `npm run dev`, sign in as an Admin and reopen the existing source batch or upload the workbook. Inspect recovery counts, select rows, keep batch size 100 and acknowledge the new transaction boundary. Watch the counts and batch percentage.
6. Interrupt after a few completed batches, reopen the page, verify that no background retry occurs, choose size 25 and select Resume. Verify completed chunks' attempts and product UUIDs do not change. Try a conflicting existing item and inactive classification; affected chunks must pause without overwriting data.
7. Verify the completed summary and downloaded report, reimport/reuse, nonadmin denial, and unchanged balances/stock ledgers. The separate non-posting stock proposal remains available only after completion.

No migration has been executed against the configured production database. Deployment and a production retry remain manual, separately authorized actions. Existing stock-posting approval requirements remain unchanged.
