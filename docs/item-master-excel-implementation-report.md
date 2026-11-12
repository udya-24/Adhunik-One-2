# Item Master Excel integration — implementation report

> Current confirmation behavior is documented in [the resumable import timeout fix](item-master-import-timeout-fix.md). Migration 002 supersedes the whole-workbook atomic confirmation described in this original report; each bounded batch is now atomic and earlier successful batches are preserved.

Date: 12-Nov-2026. Implemented locally under the approved reconstructed plan and its authoritative amendment. No production migration, production import, commit, push or deployment was performed.

## Completed behavior

An Admin can open **Inventory → Item Master → Excel Import**, upload the source XLSX, inspect its server-generated preview, exclude rows, acknowledge warnings/costs/generated location codes and confirm the selected valid product master rows. Previewing writes private staging/audit data only. A commit creates missing classifications and new products atomically; it never updates existing product fields or stock quantities.

The source is `/mnt/e/Mayank Sir/Apps/Item master v5.xlsx`, SHA-256 `1702c9562fcd612abc9b5c31d60a8d671db7a1a23aab9bf3e2889f1925d6b24c`. Its one sheet, `Sheet1`, has 1,994 products. The workbook was read in place and was not copied into application assets or committed.

| Excel | ERP master/table |
| --- | --- |
| Family | Item Categories / `item_categories` |
| Item group | Item Subcategories / `item_subcategories`, scoped to category |
| Type | Item Types / `item_types` |
| Unit | UOM / `units_of_measurement` |
| Store | Inventory Stock Locations / `stock_locations` |
| Status | Stock Classifications / new `stock_classifications` |

Master normalization reconciles case and incidental whitespace. Distinct wording remains distinct. Inactive and ambiguous matches block affected rows without reactivation, merging or reparenting. Repeated group names retain their actual parent category. Missing locations receive deterministic unique technical codes displayed before confirmation. Existing location defaults and numbering settings remain unchanged.

Workbook codes are preserved. Automatic-numbering conflicts block creation. Matching existing codes reuse stable item UUIDs only when all supplied master fields and COGS agree; conflicting or inactive items are blocked. Unsupported existing fields remain untouched. Duplicate codes block affected rows; identical names with different codes remain separate and carry a warning. The two blank subcategories import as null.

Rate becomes new-item COGS at four decimal places. Zero is preserved with a warning. Original decimals, rounding warnings, value reconciliation differences and source rows remain visible in the preview/report. Reconciliation uses decimal arithmetic and the approved Rs 0.01 tolerance. No brands, dimensions, weights, HSN, specifications or stock movements are invented from product names.

## Configuration and existing module integration

Stock Classification appears in Configuration and Item Master forms, list filters/columns and detail views. The Configuration Stock Locations entry opens the existing Inventory location master. The six mapped masters support Add/Edit/Activate/Deactivate, search/filter and checked deletion; a shared administration screen provides dependency errors, explicit consolidation preview/confirmation and audit history.

Database guards reject new inactive selections and prevent reparenting referenced subcategories through ordinary edits. Renames preserve UUIDs. Deletion is restricted by actual foreign-key dependencies, including current products, balances, transactions and import location links, with a deactivation alternative. Consolidation moves eligible current references, deactivates the source and retains snapshots/history. Parent conflicts must be explicitly resolved; historical stock locations and units with inventory history cannot be consolidated by rewriting their history.

Paginated catalogue reads replace the existing 1,000/2,000/5,000-row fetch limits for active-item selectors, Purchase item choices, Inventory movement/ledger selectors, stock-register items/balances, location choices and item master options. This prevents the 1,994 imported products or their subcategories from disappearing beyond Supabase's per-response row limit. The ordinary Item Master list retains its existing page navigation.

## Separate stock proposal: no posting capability

After committing product masters, an Admin can create or refresh a separate stock preview, confirm a **non-posting review**, reject it or cancel it. It shows source workbook rows and quantities, resolved item/location/unit, current usable/reserved/damaged/available balances and source stock values. Proposed movement and resulting balance remain explicitly undetermined while accounting rules are unresolved.

A review records its revision, actor, timestamp and note. The snapshot includes item/unit/location state, balance timestamp and immutable ledger count; an intervening movement invalidates review even if quantities return to their previous balance. Unit eligibility changes also invalidate review. A changed item unit must still match the stable imported source-unit UUID; review is blocked rather than assuming a conversion. The UI identifies stale reviews, and the database rechecks eligibility, duplicate item/location rows and reconciliation before accepting review.

`posting_enabled` is constrained to false. No stock-import posting RPC exists, and an attempted POST action is rejected. No master import, review, rejection, cancellation or refresh writes `inventory_balances` or `inventory_transactions`. Existing ordinary inventory workflows are preserved.

This is approval of the source review only, not approval of an inventory transaction with unknown accounting semantics. Before any future posting implementation, the user must confirm usable/total/target opening-quantity semantics, rejected-stock accounting, operation selection and effective-date rules. A future explicitly approved incremental change must implement atomic, idempotent posting and the corresponding tests.

## Incremental database migration

New file: `supabase/migrations/202611120001_item_master_excel_import.sql`.

It adds:

- `stock_classifications` and nullable `items.stock_classification_id` with a restrictive FK.
- `item_import_batches`: private source bytes encoded as base64, digest, parser version, raw rows, persisted preview/revision/state and commit summary. Row staging is consolidated into immutable batch JSON rather than a parallel product catalogue.
- `item_import_links`: stable batch/source-row-to-item, location and source-unit references, plus the original resolved classification UUID map.
- `item_master_admin_activities`: lifecycle/consolidation/import/review history, including failed commit attempts logged separately after rollback.
- `item_import_stock_proposals`: versioned snapshots and non-posting review state. Proposal rows are consolidated into snapshot JSON.
- Checked transactional RPCs, normalized master-write guards, active-selection/parent guards, lookup/reference indexes and RLS/grants.

Staging/audit reads are restricted to active Admins. Mutations use authenticated session clients and database Admin checks; internal helpers are not executable by application users. New mutable staging/approval state has no direct write grants. Existing master tables, business relationships, cost snapshots and ledger rules are reused. No historical migration file was edited by this implementation.

Import commits lock affected master/item tables, recompute the stored preview and reject stale state. A failure rolls back that commit's products, masters and links. Successful batch results are immutable through the application and retries return the saved result. A new batch also matches existing business keys, so reimport does not depend solely on a file digest.

## Files created

- `lib/inventory/import/workbook.ts`, `sax.d.ts`, `types.ts`.
- `lib/supabase/read-all.ts`.
- `app/(erp)/inventory/items/import/page.tsx`, `actions.ts`, `forms.tsx`, `[id]/page.tsx`, `[id]/report/route.ts`.
- `app/(erp)/configuration/item-masters/page.tsx`, `actions.ts`, `forms.tsx`.
- The new migration above.
- `tests/item-import.test.mjs`, `tests/item-import-database.mjs`.
- This report. The reconstructed plan was created during the preceding review and its approval status is updated.

## Existing files modified

- `app/(erp)/configuration/item-actions.ts`, `app/(erp)/configuration/page.tsx`.
- `components/configuration/item-configuration-section.tsx`.
- `app/(erp)/inventory/actions.ts`, `app/(erp)/inventory/items/page.tsx`, `app/(erp)/inventory/items/[id]/page.tsx`.
- `app/(erp)/inventory/locations/page.tsx`, `app/(erp)/inventory/ledger/page.tsx`, `app/(erp)/inventory/movements/new/page.tsx`.
- `components/inventory/item-form.tsx`.
- `lib/database.types.ts`, `lib/inventory/data.ts`, `lib/inventory/stock.ts`, `lib/purchase/data.ts`.
- `package.json` and `package-lock.json`: explicit pinned JSZip 3.10.1 and SAX 1.6.1 dependencies, already present transitively. The local Linux dependency installation also recorded bundled optional Tailwind dependency metadata; no unrelated application dependency upgrade was performed.
- `README.md` local-use instructions; `docs/item-master-excel-integration-plan.md` approval status.

All other previously uncommitted files remain outside this implementation. Existing edits in shared files were retained while adding the integration.

## Validation results

- **TypeScript:** `npx tsc --noEmit --incremental false` passed.
- **ESLint:** `npm run lint` passed with zero errors and one pre-existing unused-variable warning in `lib/hr/documents.ts` (`pageH`).
- **Automated tests:** 120 tests passed using Node's single-process test isolation option. This also tests the XLSX parser, shared formulas, decimal precision, invalid inputs and 1,994-row catalogue pagination.
- **Local PostgreSQL import acceptance:** 22 focused checks passed, covering all six mappings, correct parents, exact/normalized reuse, ambiguity/inactive matches, duplicate codes/names, existing-item preservation, zero/rounded COGS, confirmation, retries, stale previews, ordinary normalized writes, safe deletion/deactivation, explicit consolidation, injected rollback, authorization/RLS, audit attempts, stale stock review and disabled posting.
- **Full workbook acceptance:** a separate disposable PostgreSQL runtime imported all 1,994 products, 14 categories, 864 subcategories, 5 types, 4 units, 3 locations and 6 stock classifications. Reimport reused all 1,994 items. Both approved blank subcategories stayed null. Stock balance/transaction counts remained zero. Its stock proposal contained all 1,994 source rows. Together with the focused checks, the full run passed 23 acceptance checks.
- **Finance regression:** 16 local PostgreSQL acceptance checks passed, including COGS snapshots, authorization and document lifecycle.
- **Production build:** Next.js webpack production build passed. The default Turbopack build was attempted but its CSS worker could not bind a local port in this execution environment. The webpack build required permission to spawn local compiler workers. No project build/security setting was weakened to bypass checks.

The environment initially had no working Linux Node executable. A temporary Node 22.16 runtime was downloaded under `/tmp` and the lockfile's missing Linux optional build dependencies were installed locally. No application credential or `.env.local` value was printed or modified.

No browser session against a configured local Supabase instance was exercised. Migration/RPC validation used disposable PGlite databases built from the actual Phase 7A/7B migrations, with isolated identity/storage fixtures and the existing COGS column contract. True multi-connection PostgreSQL contention and deployment-specific RLS/schema drift remain manual integration checks; table locks/FKs/unique request state provide the implemented concurrency protection, but the single-connection harness does not prove scheduling across independent database sessions.

## Exact local testing steps

1. Use a Linux Node 22.16+ runtime. Install repository dependencies with `npm install`.
2. Run the checks below. They do not connect to Supabase or import production data:

   ```sh
   npx tsc --noEmit --incremental false
   npm run lint
   node --experimental-strip-types --experimental-test-isolation=none --test tests/*.test.mjs
   node tests/item-import-database.mjs
   node tests/finance-database.mjs
   ITEM_IMPORT_WORKBOOK='/mnt/e/Mayank Sir/Apps/Item master v5.xlsx' node --experimental-strip-types tests/item-import-database.mjs
   npm run build -- --webpack
   ```

   The database scripts use the repository's optional cached PGlite runtime at `node_modules/.cache/gp-validation`. If it is missing, install it locally without changing application dependencies:

   ```sh
   npm install --prefix node_modules/.cache/gp-validation --no-save @electric-sql/pglite
   ```

3. For browser testing, prepare a disposable local Supabase database with the repository's preceding migrations and test Admin/nonadmin identities. Compare its schema with migration history first; this repository already had unrelated edits to historical migrations. Point local application environment variables at that test instance, not production. Apply only the new migration to that test database:

   ```sh
   psql "$LOCAL_DATABASE_URL" -v ON_ERROR_STOP=1 -f supabase/migrations/202611120001_item_master_excel_import.sql
   ```

4. Run `npm run dev`, sign in as a test Admin, open `/inventory/items/import`, and upload `Item master v5.xlsx`. Verify 1,994 rows, mappings, zero-cost/rounding warnings, the blank subcategories, the duplicate-name warning and technical location codes. Leave rows selected only after reviewing them; acknowledge and commit. Resolve existing-data conflicts in Configuration or exclude affected rows and refresh the preview.
5. Inspect Configuration, Item Master, Purchase choices, stock selectors and the JSON report download. Verify all imported products remain selectable beyond the first 1,000. Upload again and confirm reuse without changes to existing products or cost/history snapshots.
6. Test rename/deactivation, blocked referenced deletion and unused deletion at `/configuration/item-masters`. For consolidation, choose a source and target, review actual affected references, and explicitly confirm. Verify the source deactivates and history stays intact.
7. On a committed batch, create the stock proposal, inspect the source/current balances, confirm non-posting review, refresh/reject/cancel, and verify ledger/balances do not change. A normal test inventory movement or changed unit eligibility must make an older preview stale. Posting must remain unavailable.
8. Sign in with a nonadmin test identity and verify import/configuration administration is denied. In independent local PostgreSQL sessions, exercise simultaneous imports/master edits, referenced deletion and stock movements to verify waiting/revalidation behavior.

## Remaining boundary and rollback

Only stock accounting/posting needs further business approval. The current schema and application cannot post these workbook quantities. Browser acceptance and independent-session concurrency checks should be completed on the local Supabase test instance before release. The new migration has not been applied to the configured remote database.

Take a disposable database snapshot before local schema testing. Failed commits roll back atomically. Successful master imports are corrected by normal editing/deactivation or explicit consolidation, not by deleting referenced products. Existing immutable stock history is never removed; future approved posting corrections must use compensating ledger transactions. No destructive reset or automatic rollback SQL was introduced.
