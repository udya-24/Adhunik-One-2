# Item pricing and inventory valuation upgrade

Implemented locally on 13-Nov-2026. No production data/schema was read or modified for this upgrade, and nothing was pushed or deployed. The working tree was clean at the start. Historical migrations, original Item Master import history, and the existing Purchase/Sales/Dispatch/Finance functions are preserved.

## Workbook and field mapping

The user confirmed that `Item master v5(1).xlsx` is the same unchanged workbook as the available `/mnt/e/Mayank Sir/Apps/Item master v5.xlsx`. That original file was used read-only for local validation; it was not copied into the application or committed.

| Source | Handling |
| --- | --- |
| New code | Match the permanent existing item code with trim/case normalization |
| Item name | Display source/current item names; name differences warn without renaming products |
| Rate (Rs) | Purchase Price / existing `items.cogs_unit_cost`; **never Selling Price** |
| Opening qty | Source usable quantity for reconciliation only in the price flow |
| Rejected qty | Source rejected quantity for reconciliation only in the price flow |
| Value (Rs) | Original usable source value and exact source reconciliation difference |
| Rejected value (Rs) | Original rejected source value and exact source reconciliation difference |
| Unit | Validate cost-per-unit against the item's active base unit; no inferred conversion |

The original Item Master import continues to populate COGS for new products, preserve zero, and reject conflicting existing-item costs. Existing-product COGS changes now have a separate price-only approval flow. Selling Price is not an Excel column in this workbook and is never inferred from its Rate.

## Schema and pricing fields

Reuse the existing `items.cogs_unit_cost numeric(15,4)` without a rename, precision change or backfill. Add nullable `items.selling_price numeric(15,4)`, checked non-negative/finite. Null means unknown; a confirmed zero remains zero for either price. The selling field has its own Item Master Edit permission guard.

Item create/edit forms support both prices independently. Price inputs are validated and sent as exact decimal strings. Item reads overlay exact database text values for these fields, so large four-decimal prices do not pass through JavaScript floating point before editing. Edit forms bind the original `updated_at`: if another writer changed the item, the stale edit must reload before saving. Current Inventory Value is a derived read-only field; it is never a writable or cached database balance.

Both prices and usable/rejected/damaged/physical values appear in Item Master list/detail and Stock Register. Item edit shows saved usable inventory value as read-only; it recalculates after saving COGS. Stock detail includes the shared valuation panel. The new selling field does not change existing Sales line-pricing behavior or saved financial document snapshots.

## Valuation rules and precision

The existing balance schema already stores **usable** on hand independently from rejected and damaged stock:

- Usable Inventory Value = actual usable `on_hand_quantity` × current COGS.
- Rejected Inventory Value = actual `rejected_quantity` × current COGS.
- Damaged Inventory Value = actual `damaged_quantity` × current COGS.
- Total Physical Stock Value = usable + rejected + damaged values.

Reserved quantity remains part of usable on-hand inventory value. Available quantity is a separate planning concept (usable on hand minus reserved). Rejected/damaged stock never enters usable value. All actual balance rows, including stock attached to inactive items, are valued; the existing active-item count cards retain their previous catalogue semantics.

SQL read functions `inventory_valuation_rows`, `inventory_valuation_summary` and `item_pricing_valuation` multiply/sum PostgreSQL numeric values exactly. Six-decimal quantities × four-decimal COGS retain ten fractional digits before final display; sums are not restricted to a currency field precision. Values return as decimal strings. The INR formatter rounds only the final displayed amount to two places and supports values beyond JavaScript's safe-integer range.

Unknown COGS is not silently treated as zero. A nonzero stocked item without COGS has unknown corresponding row values. Summary panels show known-value totals with an explicit incomplete-total warning and a missing-COGS count. A legitimate zero COGS produces zero value and does not count as missing.

Inventory Overview adds all four value metrics, a breakdown by stock classification, and location/classification filters. Item Master offers a valuation-location filter; Stock Register supports location/classification filtering. Stock Register valuation reads use bounded pages and stable item/location ordering; Item Master requests pricing/valuation only for its displayed 25 item IDs.

Excel preview quantities and `Value (Rs)` are never valuation inputs. If Item Master has been imported but opening stock has not been posted, inventory values correctly remain zero until a separate approved inventory operation creates balances. No FIFO, weighted-average costing, inventory revaluation journal, purchase document or financial accounting posting is introduced.

## Price-only import workflow

Open **Inventory → Item Master → Import / Update COGS** (`/inventory/items/import/prices`). An active Admin with **Item Master Edit** permission can reuse a committed Item Master source or upload the original workbook. Source reuse reads the preserved original raw rows, not a potentially stale derived preview. No classification/location/product is created by the price flow.

The 100-row paginated preview shows selection, permanent code, item name/unit, old COGS, original Rate, proposed four-decimal COGS, preserved independent Selling Price, change/validation state and source reconciliation. Cross-page selection is retained. Changed valid rows are READY; identical costs, including zeros, are UNCHANGED; missing/inactive products, duplicate codes, invalid rates, unsupported formulas or unit mismatches are INVALID. Missing/incompatible stock-source values do not become stock postings or silently become prices.

Cost proposals use the existing COGS precision. If the source Rate needs four-decimal rounding, the preview explicitly warns and displays the exact proposed value alongside the source. Reconciliation of source usable/rejected values uses the original unrounded source rate, so that diagnostic is distinct from valuation at the saved COGS.

For reused sources, stable original unit links allow a harmless unit rename while rejecting a changed base-unit UUID. Fresh uploads require the source Unit to match the active current unit unambiguously. No cost conversion is invented. COGS cannot be approved onto an inactive item/unit.

The Admin selects changed rows, enters a reason and explicitly acknowledges the cost-only update. Database approval binds the revision, selected item/unit UUIDs, old/proposed costs, actor and reason to persistent chunk records. Approval setup alone does not update any price. The approved runner then processes one request per chunk, with **at most 100 prices per transaction**.

Each chunk locks the relevant items/units, verifies the approval and current old COGS/base unit/activity, updates only COGS and update attribution in one set operation, inserts immutable price-change audit, and marks row/chunk outcomes atomically. Selling Price is absent from that UPDATE. A selling edit after approval remains preserved; a competing COGS or unit change pauses for fresh review.

Failed chunks roll back their own price/audit changes; earlier successful chunks remain saved. Closing the page stops further dispatch. Reopen and explicitly resume an unchanged current approval. After a failure/stale price, use Refresh pending prices, review new old→proposed values and approve again. Posted rows stay immutable and cannot be selected again. Unique source-row audit references, persistent chunk keys and terminal posted states prevent duplicate audit on lost-success retry. Transport/statement cancellation is reconciled in a separate request; no price mutation automatically retries.

Re-uploading the same source after costs already match shows UNCHANGED rows and requires no price update. Reusing it after later intentional cost edits can propose another explicitly approved change; it cannot repost stock. Price source metadata, all original row cells, old/new cost, unit/item identity, approval snapshots, actors, reason and timestamps are retained in the price import/audit tables.

## Preserved behavior and material notes

- Existing products are matched and updated in place; no new products are created by price-only import.
- Original source batches, stock approvals, balances, stock ledger, rejected/damaged quantities and configuration masters are not rewritten.
- `item_price_changes` is immutable. Application roles have no direct write grant to staged rows, approvals, results or audit. Bulk RPCs enforce active Admin plus Item Master Edit; valuation reads remain SECURITY INVOKER under existing item/balance RLS.
- Manual current COGS still affects future document defaults under existing behavior. Saved GP/PI/packing snapshots are not refreshed or posted by this upgrade.
- A COGS edit updates the item's normal version timestamp. Existing unposted opening-stock approvals that bind that timestamp may correctly become stale and require Refresh pending preview and new stock approval. Already posted stock and historical approvals remain preserved; the price operation never resumes/posts them.
- This is current-cost operational valuation, not a historical costing method. Viewing a valuation after an ordinary stock movement or approved COGS change recalculates from the then-current balances/cost.

## Incremental migration and manual steps

New migration: **`supabase/migrations/202611130004_item_pricing_and_valuation.sql`**. Historical migration files were not edited.

It adds Selling Price and its guard; exact RLS-respecting read functions; `item_price_imports`, `item_price_import_rows`, `item_price_import_chunks`, `item_price_changes`; selection/progress/paging/source-reuse/refresh/approval/chunk/interruption functions; immutable price audit and permissions. Existing unique indexes provide row/chunk pagination; extra indexes cover chunk row lookup and recent jobs. There is no business-data backfill or automatic price/stock update.

Prerequisites: the existing enterprise item/stock/permissions/Finance schema with COGS, and the preceding Item Master, opening/rejected-stock and import read/recovery migrations through `202611130003`. Check actual migration history; do not rerun historical files already applied.

1. Apply to a disposable local Supabase database first:

   ```sh
   psql "$LOCAL_DATABASE_URL" -v ON_ERROR_STOP=1 \
     -f supabase/migrations/202611130004_item_pricing_and_valuation.sql
   ```

2. Use the updated application together with that schema. Sign in as a test Admin with Item Master Edit permission. Test manual create/edit: distinct COGS and Selling Price, blank unknowns and explicit zeros; verify stale-item save protection.
3. Reuse the already committed workbook under Import / Update COGS. Inspect old/proposed costs, units, source differences and rounding. The unchanged original-workbook fixture needs no updates. Approve only deliberate differences in a test instance; do not repeat Item Master creation or stock import to change prices.
4. Confirm price-only approval leaves Selling Price, stock balances, stock ledger and saved Finance data unchanged. Interrupt/resume in the test instance and verify posted records stay posted.
5. Open Inventory Overview, Stock Register and Item Master; filter location/classification and verify all four values. Test a missing COGS and a zero COGS separately. Use `docs/sql/item-pricing-verification.sql` for read-only operator checks.
6. Any production migration, application deployment or price/stock posting remains a separate explicitly authorized operation. No such action was performed here.

Do not roll back by dropping price audit records or altering old ledger entries. Any later correction to approved costs should be a forward, reviewed price change. Older source workbook/price approvals remain durable history.

## Local validation results

- **139 automated tests passed**, including new exact price-input/INR-display and safe sequential price-runner tests.
- **17 new pricing/valuation database checks passed** with all incremental migrations and the actual existing COGS permission guard. Tests cover migration preservation, exact current-stock values, genuine zero vs missing cost, independent Selling Price, old/new preview and explicit approval, all other product fields preserved, exact unchanged balances/ledger, malformed/unmatched/inactive/duplicate/unit conflicts, competing costs, atomic rollback, safe refresh/resume, immutable audit/RLS/private helpers, renamed source units, lost-success protection, selling edits after approval and preservation of earlier completed chunks.
- **2,000 changed prices** completed in **20 bounded chunks** with exact stored COGS and no duplicate price changes. The final local run measured a maximum chunk of **114 ms** and about **1.66 seconds** for approval/processing. These are fixture/hardware measurements, not a hosted timeout guarantee.
- The actual **1,994-row workbook** matched all fixture ERP COGS, including genuine zero values: 1,994 UNCHANGED, zero invalid and zero proposed changes. The fixture products were created with the existing Item Master import before price preview. This is not a claim that every production price was rechecked or changed.
- Opening/rejected-stock regression: **9 checks passed**; resumable Item Master: **12**; Purchase/Material Receipt: **30**; Sales/Dispatch: **12**; Finance: **16**. Existing regression scripts retain their own isolated fixtures; the new pricing suite exercises current-cost valuation, separate rejected/usable stock and the real COGS guard together.
- TypeScript passed. Lint has zero errors and the existing unused `pageH` warning in `lib/hr/documents.ts`.
- Production webpack build passed on the final source, including TypeScript and 67 static pages. The build ran locally outside the sandbox for reliable Next.js subprocess execution; no deployment occurred.

Tests ran only in disposable local PGlite PostgreSQL instances, without production credentials or API requests. Authenticated browser acceptance and native multi-connection/real statement-timeout cancellation for the new price flow remain manual. Trigger-failure, stale-price, lost-success, explicit interruption reconciliation and runner tests cover transaction/resume behavior; they are not a substitute for a new hosted cancellation trace.

Reproduce with Node 22.16+ and the existing optional PGlite test runtime:

```sh
npx tsc --noEmit --incremental false
npm run lint
node --experimental-strip-types --experimental-test-isolation=none --test tests/*.test.mjs
ITEM_IMPORT_WORKBOOK='/mnt/e/Mayank Sir/Apps/Item master v5.xlsx' \
  node --experimental-strip-types tests/item-pricing-database.mjs
node tests/rejected-opening-stock-database.mjs
node tests/item-import-resumable-database.mjs
node tests/purchase-receipts-database.mjs
node tests/sales-workflow-database.mjs
node tests/finance-database.mjs
npm run build -- --webpack
```

## Files

New: `supabase/migrations/202611130004_item_pricing_and_valuation.sql`; `lib/inventory/pricing/{types,money,data,runner}.ts`; `components/inventory/valuation-panel.tsx`; `app/(erp)/inventory/items/import/prices/` (history, source upload/reuse, review, actions); `tests/item-pricing.test.mjs`; `tests/item-pricing-database.mjs`; `docs/sql/item-pricing-verification.sql`; this report.

Updated: `lib/database.types.ts`; `lib/inventory/data.ts`; `lib/inventory/stock.ts`; `components/inventory/item-form.tsx`; `app/(erp)/inventory/actions.ts`; Inventory Overview; Stock Register and stock detail; Item Master list/detail; Item Master import entry link; README. No Purchase/Sales/Dispatch/Finance service or historical migration was changed.
