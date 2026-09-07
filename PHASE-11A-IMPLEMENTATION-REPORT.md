# PHASE 11A — IMPLEMENTATION REPORT

## 1. Summary

Implemented local Finance → Overview, GP Data and COGS Analytics using the existing ERP shell, section tabs, cards, tables and forms. Manual entry only; no Excel/CSV import or accounting engine.

Inspected the repository's Supabase migrations/types, Phase 9 permission architecture, Configuration, Item Master, Customer Master, Employee Master and private document patterns. The connected Supabase database was not changed. Existing unrelated local modifications were preserved.

## 2. Item Master Changes

Added `items.cogs_unit_cost`, nullable `numeric(15,4)`, with a database constraint rejecting negative/non-finite costs. The existing Item create/edit form includes **COGS / Unit Cost (₹)**. Item Detail displays the cost in a Costing section, formatted as Indian currency (for example ₹1,500.00), or COGS Missing.

The existing Item Master role rules remain. Changing the costing field additionally requires `inventory.items` Edit permission at the database boundary. Existing item activity triggers record Item Master edits.

## 3. Item Selection

**GP Stock Item Name comes only from the existing `public.items` Item Master.**

Data path: `components/finance/gp-form.tsx` → `MasterSelector` in `components/finance/master-selector.tsx` → `/api/finance/lookups?kind=items` → `public.search_gp_master` → `public.items`, joined with `item_brands` and `item_categories`.

Search supports item code, name, description, brand and model/part number. Item Name is prominent. Only an actual selected UUID is submitted. There is no manual/custom item option or automatic Item Master creation. The database validates the relationship independently of the browser.

Buyer lookup uses `customer_companies`, including code, legal/trade name, GSTIN and phone search. State is prefilled from an active address and remains independently editable on the GP invoice. Sales Person lookup uses the existing `employees` table and returns only ID, code and name.

## 4. COGS Snapshot

GP lines retain item UUID, code/name snapshots, category snapshots and `cogs_unit_snapshot`. Normal rate/quantity edits preserve these snapshots. Changing an item captures the new item's current details/cost. **Refresh COGS from master** explicitly updates the draft's cost snapshot on save.

Master cost/name changes do not rewrite existing GP records. GP edits do not modify Item Master. Confirmed invoices require an audited reopen before editing; optimistic version checks reject stale saves.

## 5. GP Types

Added Configuration → GP Types at `/configuration?section=gp-types`, using the existing master editor/toggle infrastructure and a consistently shaped `gp_types` table. Seeded PROJECT, TRADE and TRADE/PROJECT as editable database records, not application enums.

Configuration administrators can add, edit, activate and deactivate types. New entries require active types; an existing invoice can retain its inactive type and historical label. Finance permission alone does not grant Configuration management rights.

## 6. GP Data

Tables: `gp_invoices`, `gp_invoice_items`, `gp_invoice_documents`, `gp_invoice_activities`.

One header owns multiple item rows and stores freight once. Invoice number/date are manual. The save RPC validates relationships, captures snapshots and saves header/items atomically. Statuses are DRAFT, CONFIRMED and CANCELLED. Cancellation retains records/documents and requires a reason.

The existing ERP's `company_id` means customer company, not a tenant or issuing legal entity. GP follows that convention; `company_id = customer_company_id` is enforced. Invoice-number uniqueness is case-insensitive within customer company and configured financial year. A date must belong to exactly one existing Financial Year. No new company master or numbering sequence was introduced.

## 7. Calculations

- Sales = Rate × Quantity.
- Total COGS = COGS / Unit × Quantity.
- GP = Sales − Total COGS.
- GP % = GP / Sales × 100.
- Overall GP % uses summed GP and summed Sales; it never averages line percentages.
- **Freight is NOT included in GP.**

PostgreSQL numeric generated columns calculate authoritative line values. Currency line totals round to two decimals. Browser previews use integer decimal arithmetic. Zero sales produces NULL / N/A GP %. The required 1900 × 2 sale with 1500 unit COGS produces Sales 3800, COGS 3000, GP 800 and GP 21.05%; freight 500 does not change that result.

## 8. Documents

Bill and LR belong to the invoice header; multiple documents of each type are supported. Upload through the detail page, with register links directly to the document section. Authorized GP viewers can view/download.

Supported formats: PDF, JPG/JPEG and PNG, up to 10 MB each. The server validates extension, MIME type, size and file signature. Uploads use private `gp-invoice-documents` Storage and unique paths. The server's existing admin client uploads validated bytes; authenticated browser clients cannot bypass validation with direct Storage uploads. Metadata attachment rechecks permissions and invoice status. Failed attachment attempts clean up the unlinked upload.

## 9. COGS Analytics

Implemented summary Sales, COGS, GP, overall GP %, informational freight, invoice count, quantity, low-GP count, loss count and missing-COGS invoice count.

Breakdowns: buyer, item, category, salesperson, state, GP type, month, quarter and year, with invoice drill-down for users who also have GP Data View permission. Item/category calculations use GP snapshots. Time periods derive from invoice dates.

Filters: invoice/buyer text search, date range, buyer, state, salesperson, GP type, item, category, GP classification and lifecycle status. Analytics include drafts and confirmed invoices by default and exclude cancelled invoices. Item/category analytics aggregate matching lines; freight is counted once per matching invoice. Register item/category filters select invoices but display whole-invoice totals. The GP Status filter classifies the whole invoice, as indicated in the UI.

Data loading pages through Supabase results instead of silently stopping at its default row cap. This phase loads the authorized reporting dataset into the client; very large future datasets may warrant database-side reporting/pagination.

## 10. Missing COGS

Missing cost stays NULL, never zero. Drafts can be saved; confirmation is rejected if any line lacks COGS. Totals that depend on missing costs show N/A rather than misleading partial profit.

The queue lists distinct affected items and GP draft rows, item code/name, invoice number/date, and links to Item Master/GP entry. After updating the master, Finance explicitly refreshes the draft cost.

## 11. Low GP

`system_settings`, category GENERAL, key `LOW_GP_WARNING_THRESHOLD`, contains the default 15. The GP Types Configuration screen edits it, with database/server validation from 0 to 100 (up to two decimal places).

Runtime calculations read the configured value; there is no hard-coded 15% fallback. Negative GP is Loss; nonnegative GP below the configured threshold is Low GP. Zero-sales/no-loss rows show N/A.

## 12. Security

Added Phase 9 sections `finance.overview`, `finance.gp_data`, and `finance.cogs_analytics`. The existing ERP Access matrix discovers their migration records; module tabs/sidebar use the matching section definitions. Admin access remains implicit. Assign non-admin Finance permissions through the existing ERP Access screen after applying the migration.

Routes/actions check section permissions. RLS covers all Finance tables. Authenticated users have no direct transactional insert/update/delete access; validated security-definer RPCs enforce Edit permission and atomic saves. Configuration writes remain admin-controlled. Item COGS changes additionally check Item Master Edit permission.

Analytics-only permission allows financial rows but not Bill/LR metadata or Storage objects. Private Storage access requires a linked document visible through RLS. Download routes issue 60-second signed URLs. Employee lookup exposes no bank or personal details. Company references/path validation follow the existing single-business, customer-company architecture; no unsupported multi-tenant claims are made.

## 13. Database Migration

**DO I NEED TO RUN THE ENTIRE SQL MIGRATION FILE IN SUPABASE SQL EDITOR? YES.**

Run the complete file:

`supabase/migrations/202609070031_phase_11a_gp_cogs.sql`

Apply it once to the existing database after its prior migrations through Phase 10/payment receipts. It includes a transaction, schema changes, GP configuration seeds, permission sections, functions, RLS, the private bucket and Storage policy. No existing migration was edited by this implementation. The new migration has not been applied to your connected Supabase project.

## 14. Storage

No separate manual bucket or policy creation is needed: the complete migration creates them. The existing server environment needs `SUPABASE_SERVICE_ROLE_KEY`; its presence in `.env.local` was confirmed without exposing its value.

Server Action request limit was increased from 6 MB to 12 MB to accommodate the allowed 10 MB file plus multipart overhead. The application and bucket still enforce 10 MB per document.

## 15. Testing

**21 Node tests passed:** 12 Finance calculation/document tests, 5 existing permission tests and 4 existing Item Master tests. **16 local PostgreSQL acceptance checks passed** using a temporary PGlite runtime with representative pre-existing master/auth/Storage fixtures. The entire new migration executed successfully there.

Acceptance coverage:

| Requested test | Local automated evidence |
| --- | --- |
| 1. Item Master COGS | Database cost persistence and Indian currency formatting passed; actual edit/detail browser flow pending. |
| 2. GP Type | New configurable type accepted; inactive type rejected for new invoices and retained for existing invoices. |
| 3. Item source | Item UUID relationship validated; nonexistent item rejected; selector implementation reviewed. |
| 4. GP calculation | Exact required example passed. |
| 5. Freight exclusion | GP remained 800 / 21.05% with freight 500. |
| 6. Multiple items | One header, multiple lines and freight counted once passed. |
| 7. Overall GP % | Weighted totals passed. |
| 8. COGS snapshot | Old cost preserved on master/draft changes; new invoice gets new cost; explicit refresh updates old draft. |
| 9. Missing COGS | NULL preserved; confirmation rejected and transaction rolled back. |
| 10. Buyer | Existing master reference enforced; searchable browser interaction pending. |
| 11. Salesperson | Existing employee FK and minimal authorized lookup tested. |
| 12. Bill / LR | Byte validation, metadata linkage, audit and private Storage RLS tested locally; real Supabase upload/signed-download browser test pending. |
| 13. Low GP | Configurable threshold, equality boundary and validation passed. |
| 14. Loss | Negative GP and zero-sales loss passed. |
| 15. Analytics | Every requested grouping reconciled; item filtering, distinct invoice counts, cancellation and missing values tested. |
| 16. Permissions | View cannot mutate; unauthorized users see no Finance rows/files; analytics-only cannot read documents; Finance Edit cannot manage GP Types. |

Also tested stale-version rejection, immutable confirmation, audited reopen/cancellation, duplicate numbering, invalid values and zero-sales protection.

The connected Supabase database, real Storage service and authenticated browser flows were not exercised. Run those acceptance flows after applying the migration; local fixture tests do not substitute for deployment-environment verification.

Reproduce Node checks:

```sh
node --test tests/finance.test.mjs tests/permissions.test.mjs tests/item-master.test.mjs
```

Reproduce PostgreSQL checks (temporary dependency only; does not change application package manifests):

```sh
npm install --prefix node_modules/.cache/gp-validation --no-save --package-lock=false @electric-sql/pglite
node tests/finance-database.mjs
```

## 16. Lint

`npm run lint` **PASSED**, exit 0. Zero errors; one pre-existing unrelated warning: unused `pageH` in `lib/hr/documents.ts:3`. No lint/type rules were weakened.

## 17. Build

`npm run build` **PASSED**, exit 0. Production compilation, TypeScript, page generation and Finance route registration completed successfully. Next.js reported an existing parent-directory lockfile warning; it did not block the build.

Checks used the installed Windows Node v24.15.0 runtime from WSL. No deployment was performed.

## 18. Git / Deployment

Changes remain **LOCAL**.

- No Git commit.
- No Git push.
- No GitHub publication.
- No Vercel deployment.
- No connected Supabase migration or remote data mutation.
- Existing unrelated local changes preserved.
