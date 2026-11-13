# Completed-import reads and separate rejected opening stock

13-Nov-2026. Local implementation only. No configured Supabase database was queried or migrated, no production stock or products were posted, and nothing was committed, pushed or deployed. The starting Git working tree was clean; historical migrations remain unchanged.

## Confirmed accounting and actual workbook

The user confirmed in this session: **“Opening qty is usable; add rejected separately.”** This supersedes the older rejected-exclusion requirement for new stock import jobs. Existing jobs/approvals retain their original policy and do not silently acquire permission to post rejected stock.

Read the original `/mnt/e/Mayank Sir/Apps/Item master v5.xlsx` without changing it. Sheet1 contains 1,994 data rows. Actual headers are `New code`, `Item name`, `Item group`, `Type`, `Family`, `Store`, `Unit`, `Status`, `Opening qty`, `Rejected qty`, `Rate (Rs)`, `Value (Rs)`, `Rejected value (Rs)`, `Uses in 6 months`, `Last used`. Stock uses New code, Item name, Opening qty, Rejected qty, Store and Unit. No column aliases or unit conversions were invented.

There are 1,725 positive usable-opening rows, 55 positive-rejected rows and **45 rejected-only rows**. Consequently a clean eligible database has 1,770 positive rows and 224 zero rows. Units remain separate: PCS, KG, MTR, BUNDLE.

The existing ERP's `on_hand_quantity` already means **usable** on hand; DAMAGE moves quantity out of that balance into damage. Preserve that accounting across Purchase/Dispatch:

- Available = usable on hand − reserved.
- Gross physical stock = usable on hand + rejected + damaged.
- Equivalently, Available = gross physical stock − rejected − damaged − reserved.

Rejected quantities never increase usable on hand, damaged stock, available stock, valuation or costs.

## Timeout investigation and read changes

The completed import detail route previously selected the entire batch, including workbook base64, all source rows and all preview rows. If a legacy stock proposal existed, every visit also called `item_import_stock_review_current`, which rebuilt and compared a complete stock snapshot. The snapshot SQL joined each source link to an expanded workbook JSON array and counted ledger entries for each item/location. Recent batch and batch-audit reads lacked matching ordered indexes.

The new read migration adds recent-batch, completed-source, batch-audit and item/location-ledger indexes. It preserves the existing snapshot's result while materializing the source expansion explicitly once. A generated source-row count lets the page fetch header fields and summary without fetching workbook bytes or source records. Full product preview data is fetched only for PREVIEW batches. Legacy stock proposal/freshness work is opt-in behind “Load legacy stock proposal.” Audit history is paginated in stable 50-event pages; nothing is removed. The main committed source remains accessible if the optional stock freshness RPC fails.

**The exact cancelled production statement is not established.** There was no authenticated live database session or cancellation log. Local 2,000-row snapshot comparisons measured 144–162 ms for the rewritten function and 149–159 ms for the original; they do not demonstrate that this join caused the production timeout. PostgreSQL can optimize the original join. The reliable application improvement is avoiding this complete snapshot and oversized payload on ordinary completed-import page loads, plus providing indexes for selective reads. No timeout limit was raised. The existing bounded/resumable Item Master confirmation remains unchanged, and a COMMITTED import is never retried automatically.

Use `docs/sql/item-import-recovery-check.sql` before considering any Item Master retry. After the read migration, `docs/sql/committed-import-timeout-diagnostics.sql` inspects state, indexes, timeout settings and read plans. Match Supabase/PostgREST cancellation logs to the request/RPC and timestamp before claiming a live root cause. Owner SQL Editor plans do not reproduce authenticated-role RLS or role-specific timeouts.

## Preview and posting

Open **Inventory → Stock Register → Import Opening Stock from Excel** and reuse the already COMMITTED Item Master source. Upload and selected-sheet parsing remain available. Opening-stock upload permits missing Rejected qty / Rejected value columns; the original Item Master parser still requires its original headers. Missing/blank rejected quantities block a row until an administrator explicitly enters a quantity, including an explicit zero.

The editable preview shows selection, item code/name, unit/classification, location, original stock/rejected quantities, editable rejected quantity, existing usable/rejected stock, proposed usable quantity, change, resulting available stock, validation and ledger references. It renders 100 rows per page; controlled edits and selection persist across pages and are submitted together. Saving rebuilds the reviewed revision; unsaved edits disable confirmation. Source rounding to six decimal places is visible, and manually entered excess precision is invalid.

Counts include matched/unmatched items, ready records, invalid/existing/posted/pending records and failed/posted batches. Exact Excel usable/rejected, selected usable/available/rejected and posted usable/rejected totals are grouped by stable unit UUID; unrelated units are never added together. Downloaded reconciliation distinguishes original rejected values, edited selected quantities, actual rejected postings and remaining unposted amounts.

New jobs use `USABLE_PLUS_REJECTED`; existing jobs retain `USABLE_OPENING_EXCLUDE_REJECTED`. For an old unposted job, cancel it and create a fresh preview from the committed source to obtain the new policy. For a partially posted old job, posted rows remain immutable and existing items stay blocked; this change does not backfill rejected quantities onto earlier usable-only postings. Such rows need separate inventory reconciliation and are not silently reposted.

Approval still binds the saved revision, quantity/location/unit/inventory snapshots, date, reason, actor, selection and existing-stock decision. The existing choices are Skip or Review individually: an item with **any** inventory balance or movement history at any location remains unposted in bulk. Ordinary adjustment links support separately reviewed usable-stock reconciliation. No balance is overwritten or inferred as an adjustment.

Usable quantities call the existing `post_inventory_movement('OPENING_STOCK', ...)`. Rejected quantities use an internal service, `post_rejected_opening`, callable only inside the approved chunk flow. It writes a `REJECTED_OPENING` movement to the existing immutable stock ledger with a positive `rejected_delta`, zero usable/reserved/damaged deltas, and updates only the separate rejected balance. Rejected-only rows create that movement without creating a fictitious positive usable opening. Item/unit/location references, source-row ID, import/source batch, actor/date/timestamp and approval snapshots remain available in the row/audit/report.

Both movements, balances, row outcomes and audit entries commit together per chunk. A failure during rejected posting rolls back usable posting from that chunk too. Earlier chunks remain committed. Unique rejected item/location and source-reference indexes, existing usable-opening indexes, persistent chunk request keys, locks and approved-state checks enforce duplicate prevention. Uncertain requests stop the sequential runner; lost-success retries return persisted progress without additional movements. Refresh pending preview and reapprove after failure; explicitly resume an unchanged current approval after an interruption. No automatic inventory posting occurs merely by visiting a page.

Inventory Overview adds **Items with Rejected Stock**, counting active items with positive rejected balances. Stock Register, item stock detail and ledger views show rejected quantities/deltas separately. Item detail now queries only the requested item's stock instead of reading the whole catalogue. Existing usable availability and ordinary Purchase/Dispatch/Finance functions are preserved.

## Incremental migrations and local instructions

New migrations:

1. `supabase/migrations/202611130001_import_read_performance.sql`.
2. `supabase/migrations/202611130002_rejected_opening_stock.sql`.

Prerequisites: the existing item/inventory schema and migrations `202611120001`, `202611120002`, `202611120003`. Inspect migration history first; do not rerun already applied historical migrations or reimport the COMMITTED master. Apply the new pair and updated application together. The new constraints/indexes take normal DDL locks; test on a disposable database first and schedule any eventual approved production migration appropriately.

```sh
psql "$LOCAL_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/202611130001_import_read_performance.sql
psql "$LOCAL_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/202611130002_rejected_opening_stock.sql
```

Migration 001 changes read metadata/indexes/function only. Migration 002 adds zero-default rejected balances/deltas, a checked ledger movement type, rejection idempotency indexes, nullable staged rejection proposals and optional rejected ledger links. It replaces the necessary preview/approval/progress/posting functions incrementally. Ledger immutability, RLS and existing direct-write restrictions remain enabled. The internal rejected service has no authenticated/anonymous execute grant. Locations with rejected stock cannot be deactivated. Existing products, source JSON/binary, audit events, ledger records and approval accounting policies are preserved.

Never roll this back by dropping rejected columns or deleting ledger entries after posting. Review a forward correction if a later change is needed. No production migration or import was executed in this task.

## Testing results

All database tests ran in disposable local PGlite PostgreSQL instances, without application credentials or network access.

- 133 automated tests passed, including a new missing-rejected-column parser test and exact rejected reconciliation test.
- 9 new database checks passed on the final code: migration preservation; legacy exclusion approval; separate/rejected-only postings and reserved availability; repeat-source/existing-stock protection; missing/manual rejected input and precision; atomic rollback between usable/rejected writes and resume; immutable ledger/private service/direct-write denial; legacy/new snapshot equality; 2,000 rows in 20 chunks with 4,000 unique movements and exact totals.
- The original workbook acceptance run passed all 10 checks, including 1,994 rows with one existing-stock item protected at quantity 11. It posted 1,769 rows in 18 chunks, skipped 225 rows, created 55 rejected ledger entries and left damaged balances at zero. Item Master records stayed exactly unchanged. Maximum measured workbook chunk was 417 ms; the separate final 2,000-row run measured 818 ms maximum. These are local fixture measurements, not hosted performance guarantees.
- Protected-workbook posted totals: BUNDLE usable `109.000000`, rejected `9.000000`; KG usable `346453.377000`, rejected `225.125000`; MTR usable `565692.000000`, rejected `0.000000`; PCS usable `3204398.000000`, rejected `242539.000000`.
- Existing opening-stock regression: 17 checks; resumable Item Master: 12; Purchase/Material Receipt: 30; Sales/Dispatch: 12; Finance: 16. These regression scripts use their existing isolated schema fixtures; the new integration suite exercises the new rejected schema and ordinary inventory posting together.
- TypeScript passed. Lint has zero errors and the pre-existing unused `pageH` warning in `lib/hr/documents.ts`.
- Production webpack build passed, including TypeScript and route generation. The sandbox returned empty output from a detached TypeScript subprocess on the first attempt; rerunning the local build outside the sandbox succeeded. Build output also contains the existing parent-lockfile scope warning.

Reproduce with Node 22.16+ and the existing optional PGlite cache:

```sh
npx tsc --noEmit --incremental false
npm run lint
node --experimental-strip-types --experimental-test-isolation=none --test tests/*.test.mjs
node tests/rejected-opening-stock-database.mjs
ITEM_IMPORT_WORKBOOK='/mnt/e/Mayank Sir/Apps/Item master v5.xlsx' node --experimental-strip-types tests/rejected-opening-stock-database.mjs
node tests/opening-stock-database.mjs
node tests/item-import-resumable-database.mjs
node tests/purchase-receipts-database.mjs
node tests/sales-workflow-database.mjs
node tests/finance-database.mjs
npm run build -- --webpack
```

The original workbook is an external read-only test input, not a committed application asset. Native multi-connection/real statement-cancellation tests and authenticated browser acceptance were not rerun for this extension. The checked rollback/resume scenarios include trigger failures and lost-success retries; they do not substitute for a new live hosted timeout trace. Manually verify pagination/edit retention, approval and interrupted/resumed processing against a local Supabase instance before release. Do not post production quantities without separate explicit approval.
