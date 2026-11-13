# Bulk Opening Stock from Excel — implementation report

Historical report. The 13-Nov-2026 confirmation supersedes rejected-stock exclusion for new jobs: usable opening plus separate rejected stock. See [the current report](opening-rejected-stock-update.md).

Date: 12-Nov-2026. Implemented locally. No production migrations, stock postings, imports, commits, pushes or deployments were performed.

## Confirmed accounting rule and workbook

The user explicitly confirmed: **Opening qty is usable stock; leave Rejected qty unposted for separate review.** This supersedes the earlier unresolved opening-quantity question. Rejected-stock accounting remains unapproved; this feature never posts it.

Source: `/mnt/e/Mayank Sir/Apps/Item master v5.xlsx`, SHA-256 `1702c9562fcd612abc9b5c31d60a8d671db7a1a23aab9bf3e2889f1925d6b24c`.

The actual workbook has one worksheet, **Sheet1**, and 1,994 data rows. The headers used are:

| Workbook header | Opening stock handling |
| --- | --- |
| New code | Match existing Item Master with trim/case normalization |
| Item name | Display source/current names; warn on differences without changing the item |
| Opening qty | Usable opening quantity; editable before approval |
| Unit | Validate against the existing item's stable unit; never infer conversions |
| Store | Resolve an existing Stock Location, or require an explicit location override |
| Status | Display source stock classification and current item classification; never change activity/history |
| Rejected qty | Retain in source/report only; never post or subtract it |
| Rate (Rs), Value (Rs), Rejected value (Rs) | Traceability only; no costs, values or fiscal documents are imported |

There are 1,725 positive Opening qty rows and 269 zero rows. Fifty-five rows have nonzero Rejected qty. Units are PCS, KG, MTR and BUNDLE; locations are Store A1, Store A2 and Store B. The worksheet selector is explicit even for a one-sheet workbook. Item Master upload retains its existing single-sheet default; stock upload supports choosing a sheet deliberately.

## Implemented workflow

Open **Inventory → Stock Register → Import Opening Stock from Excel**.

An Admin can either upload the original workbook and select its worksheet, or reuse a completed Item Master source already stored by the Excel integration. No item, classification or location is created by this feature. Existing import lineage supplies stable unit/location UUIDs when reusing the original Item Master source, preserving renames. A fresh upload uses exact/unambiguous normalized existing Unit/Store matches.

Preview displays item code/name, unit, source/current classification, mapped location, original Opening/Rejected quantities, current ERP on-hand, proposed opening quantity, proposed change, resulting quantity, validation and ledger references. It flags missing/inactive items, unresolved/inactive locations, unit mismatches, invalid/negative/out-of-range quantities, duplicate selections and existing inventory/history.

Quantities, location overrides and selection can be edited. **Save edits and rebuild preview** persists a new reviewed revision. Confirmation is disabled while the displayed edits are unsaved. Duplicate source codes require explicit selection of at most one row. Zero quantities create no ledger entry. The existing schema has no per-UOM decimal-place setting; the importer preserves the ledger's supported `numeric(24,6)` precision for matching units rather than inventing integer-only PCS rules. Source floating-point residue is visibly rounded to six decimals; manual edits with greater precision require correction.

Approval requires the current revision, selected valid positive rows, an explicit effective date, reason, existing-stock policy, batch size (1–100) and acknowledgement. It binds the selected rows, quantities, item/unit/location snapshots and inventory state to an immutable per-chunk approval record. No stock changes occur during upload, worksheet inspection, preview, editing or approval setup alone; the approved runner then dispatches posting requests.

### Existing-stock policy

The default is **Skip existing stock/history**. Bulk opening is conservatively prohibited if the item has **any balance row or movement history at any location**, even if its current on-hand is zero, its original opening was already posted, or the workbook maps a different location. Those rows remain unselected and unposted here.

The second policy is **Review individually**: existing rows still remain unposted in bulk, with links to the existing authorized Adjustment In/Out workflows. No adjustment direction, replacement balance or adjustment quantity is inferred from the workbook. Administrators may perform a separately reviewed ordinary adjustment, then refresh the pending import preview.

A repeated workbook with no remaining eligible positive rows reports existing/zero rows and cannot post another opening. It can be cancelled to close its draft history. Matching by another upload ID, filename or changed quantity cannot circumvent existing inventory/history checks.

### Posting and atomicity

Each approved batch contains at most 100 products. **A batch is atomic; the entire workbook is not atomic.** If a later batch fails, earlier posted batches remain saved. A failed batch rolls back all its balance, ledger, row-result and posting-audit changes.

Posting calls the existing `post_inventory_movement('OPENING_STOCK', ...)` function. It does not write balances directly, overwrite balances, create purchase orders, material receipts or supplier invoices, or alter existing Item Master/COGS data. The existing immutable ledger and quantity constraints remain enabled.

The import batch ID is stored as the ledger reference number. Each source-row UUID is its reference ID under `OPENING_STOCK_EXCEL`; item/location UUIDs and posting user/timestamps are retained. A new database unique index on this source reference works alongside the existing one-opening-per-item/location index. Persistent chunk request keys, job locks, terminal posted states and transactional source links prevent duplicate posting after retries or lost responses.

### Freshness, interruption and resumption

Approval snapshots include item/unit/location identifiers and versions, all balances for the item, existing opening/history counts, source/mapping data, quantities, effective date and approval actor. Posting rechecks these under short NOWAIT locks compatible with the existing ordinary posting functions' DML protocol. Locks also protect the absence of a balance and stock at other locations. Concurrent manual stock, receipt, dispatch or transfer writes cannot slip between the freshness check and posting.

A changed balance, unit, item, location or ledger history pauses the affected batch. Even a movement that returns a balance to the same number invalidates the old preview. Refreshing pending preview supersedes old unposted chunk approvals and requires fresh administrator approval. Earlier posted rows and their approvals/ledger links cannot be edited or reprocessed. Prior failed/superseded chunk approval data remains available in the report.

Closing a page stops dispatching further requests; it does not undo a committed batch. Reopen and explicitly select **Resume approved batches** when the job still has a current RUNNING approval. A failed/timed-out/stale job requires **Refresh pending preview**, review/edit/save as needed, and new confirmation. A smaller batch size can be selected for the new pending approval. Uncertain or failed requests are never automatically retried. Cancelling remaining work preserves existing posted ledger entries and does not reverse them.

## Database and security

New incremental migration: `supabase/migrations/202611120003_bulk_opening_stock_import.sql`. Historical migrations 001/002 and all older migrations are untouched.

It adds:

- `item_import_batches.purpose`: existing sources default to ITEM_MASTER; new stock uploads use OPENING_STOCK. Product-import screens exclude stock-only uploads.
- `opening_stock_imports`: separate stock review/approval lifecycle and source reference.
- `opening_stock_import_rows`: raw source rows, editable proposal, validated snapshots, selected state and immutable posted transaction references.
- `opening_stock_posting_chunks`: stable request keys, approval generations with complete reviewed row snapshots, pending/posted/failed/superseded status, attempts and safe errors.
- A unique ledger source-reference index and checked preview/approval/post/interruption/cancellation RPCs.
- `inventory_overview_counts()`: an RLS-respecting read function deriving active, in-stock, low-stock, out-of-stock and damaged-item counts from actual balances with exact numeric arithmetic.

Only active Admins can use bulk import and its RPCs. All three new tables enable RLS and grant Admin read access; application users have no direct write grants to staged approvals, row results or posting state. Internal helpers are not callable by authenticated/anonymous clients. Existing ordinary inventory permissions and immutable ledger constraints remain in place. No service-role credential is used.

The earlier Item Master stock proposal remains a separate non-posting review. It is not silently converted into an approved posting and still cannot post rejected quantities. Product-master import itself continues to leave stock unchanged.

## Overview and reports

After each posting response, Inventory Overview, Stock Register and Stock Ledger routes are invalidated. The overview uses exact database sums of usable-minus-reserved quantities, sums damage from balances, and applies reorder thresholds to active items. It does not derive stock from import status or item existence alone. Inactive items are excluded from active-item stock metrics. Stock-register catalogue/balance reads remain paginated and now use lookup maps rather than repeatedly scanning every balance/location for each item.

The downloadable JSON report contains source name/sheet/hash, job and per-row results, stable unit/location/item references, posted transaction IDs, all approval generations/chunks and complete source audit history. Quantity totals are exact decimal strings grouped by stable matching unit; incompatible/unresolved source units and invalid source numbers are reported separately. PCS, KG, MTR and BUNDLE are never added into one quantity total.

## Files

Created:

- `supabase/migrations/202611120003_bulk_opening_stock_import.sql`.
- `app/(erp)/inventory/stock/import/`: index, actions, client forms, `[id]/page.tsx`, `[id]/report/route.ts`.
- `lib/inventory/opening-stock/`: types, guarded sequential runner, error mapping and per-unit reconciliation.
- `tests/helpers/opening-stock-fixture.mjs`, `tests/opening-stock-database.mjs`, `tests/opening-stock-concurrency-database.mjs`, `tests/opening-stock.test.mjs`.
- This report.

Modified:

- `lib/inventory/import/workbook.ts`: bounded worksheet listing and explicit selected-sheet parsing; existing default preserved.
- `lib/inventory/import/types.ts`, `lib/database.types.ts`: stock/source purpose and RPC/table contracts.
- `lib/inventory/stock.ts`: exact overview RPC and efficient balance/location lookup.
- `app/(erp)/inventory/stock/page.tsx`: bulk opening-stock entry point.
- Item Master import index/detail screens: purpose filtering, preserving product-source behavior.
- README and prior integration report: clarify the new separately approved opening workflow.

## Validation and measured results

Tests run only in disposable local databases, including native PostgreSQL with independent connections. The original workbook was read in place, not committed as an application asset.

- Full source: 1,994 mapped rows; clean native fixture posted 1,725 positive rows in 18 bounded batches and skipped 269 zero rows. All 55 rejected-quantity rows left rejected stock unposted. Maximum measured native batch: approximately 252 ms under an 8-second per-statement test budget.
- Existing-stock fixture: one workbook item already had usable stock of 11; its Excel opening was 7. Its balance stayed 11. The importer posted 1,724 other rows and skipped that existing item plus 269 zero rows. No duplicate openings or damage postings were created, and Item Master/COGS records remained exactly unchanged.
- Exact posted totals in that protected fixture: BUNDLE `109.000000`, KG `346453.377000`, MTR `565692.000000`, PCS `3204398.000000`. On a clean fixture the PCS total is `3204405.000000`; other units are unchanged. These are test fixtures, not claims about current production eligibility/counts.
- A separate 2,000-record test verifies 20 bounded transactions, exact quantity precision, progress and unique ledger references.
- Database checks cover preview-only safety, quantity edits, missing items, unit/location mismatch, duplicate selection, zeros/rejected exclusion, safe reuse of source lineage, existing stock/history at other locations, prior zero balances, stale pre/post-approval state, rollback, lost responses, superseded approval generations, cancellation, exact overview metrics and RLS.
- Native concurrency tests cover duplicate requests, overlapping workbooks, genuine statement-timeout rollback/resumption, concurrent ordinary receipt/stock posting and ABA movements.
- Item Master, Purchase/Material Receipt, Sales/Dispatch and Finance regression suites are run separately.

Final verification passed: 131 automated tests, 18 opening-stock database checks, six native PostgreSQL concurrency/timeout checks, and regression suites for Item Master (12), Purchase/Material Receipt (30), Sales/Dispatch (12) and Finance (16). TypeScript and the production webpack build passed. Lint completed with zero errors and one pre-existing unused-variable warning in `lib/hr/documents.ts`. Disposable native test databases were removed and the local test server was stopped. Browser acceptance against a local Supabase test instance remains manual; no production or authenticated browser session was used here.

## Exact local testing

Use Node 22.16+ and repository dependencies. Existing optional test runtimes are under ignored `node_modules/.cache/gp-validation` (PGlite) and `node_modules/.cache/pg-concurrency` (native `pg` client).

1. Prepare a disposable local Supabase database with preceding migrations, including Item Master migrations 001/002. Apply **only migration 003** if those are already applied:

   ```sh
   psql "$LOCAL_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/202611120003_bulk_opening_stock_import.sql
   ```

2. Run local checks:

   ```sh
   npx tsc --noEmit --incremental false
   npm run lint
   node --experimental-strip-types --experimental-test-isolation=none --test tests/*.test.mjs
   node tests/opening-stock-database.mjs
   ITEM_IMPORT_WORKBOOK='/mnt/e/Mayank Sir/Apps/Item master v5.xlsx' node --experimental-strip-types tests/opening-stock-database.mjs
   node tests/item-import-resumable-database.mjs
   node tests/purchase-receipts-database.mjs
   node tests/sales-workflow-database.mjs
   node tests/finance-database.mjs
   npm run build -- --webpack
   ```

3. For independent-connection/timeout checks, use a disposable localhost PostgreSQL server and the optional test client:

   ```sh
   npm install --prefix node_modules/.cache/pg-concurrency --no-save pg
   ITEM_IMPORT_LOCAL_POSTGRES='postgresql://test_user@127.0.0.1:55493/postgres' ITEM_IMPORT_WORKBOOK='/mnt/e/Mayank Sir/Apps/Item master v5.xlsx' node --experimental-strip-types tests/opening-stock-concurrency-database.mjs
   ```

   The script rejects non-local hostnames, creates a unique generated test database and removes only that database. Its role fixtures require a disposable test cluster; do not use a shared application cluster.

4. Configure the application for that local Supabase instance, run `npm run dev`, sign in as a test Admin and open `/inventory/stock/import`. Upload the workbook, read/select Sheet1, or reuse a completed Item Master source. Inspect all mappings, quantities, existing-stock conflicts and six-decimal rounding warnings.
5. Change a quantity and/or location and deselect a row. Confirm that posting is disabled until saving/reviewing the changed preview. Select an effective opening date, reason, existing-stock policy and batch size; explicitly approve posting. Check ledger links and per-unit report reconciliation.
6. Interrupt after a completed batch, reopen, and verify persisted progress. Resume unchanged approvals explicitly; if a stock movement/mapping changed or a batch failed, refresh pending preview and reapprove at a smaller size. Verify old postings remain unchanged and old superseded keys cannot post again.
7. Re-upload the same workbook: existing inventory/history must remain unposted. Review existing rows through ordinary authorized adjustment links, never as a second bulk opening. Test a nonadmin login: confirmation and raw job writes must be denied.
8. Verify Inventory Overview/Stock Register/Stock Ledger after refresh. Preserve existing Purchase, Receipt and Dispatch records. Rejected quantities and damaged balances must not increase as a side effect of opening import.

The new migration was not applied to the configured remote database, and no stock was posted there. A production release/import remains an explicit manual operation. Posted local test entries were confined to disposable databases. Future rejected-stock posting still needs separate accounting approval and implementation.
