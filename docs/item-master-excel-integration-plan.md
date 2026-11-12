# Item Master Excel integration — reconstructed plan

Date: 12-Nov-2026. Status: core implementation approved by the user; stock posting remains disabled pending accounting rules.

This is a reconstruction from repository evidence and the actual workbook, not a recovered copy of the missing original. `item-master-excel-integration-plan-amendment.md` remains authoritative wherever it changes this plan. Approved decisions below come from that amendment and the user's recovery request. Proposed choices and unresolved business rules are explicitly marked; approval of this document does not authorize production migration or data import.

## 1. Evidence and scope

Inspected the complete amendment, AGENTS.md, README.md, package.json, Configuration item actions and screens, Inventory item actions/forms/data and stock locations, item and inventory tests, security access helpers and section permissions, and migrations for Phase 7A, Phase 7B, Phase 9B and Phase 11A COGS. Existing working-tree edits, including edits to historical migrations, must be preserved. New work must use incremental migrations only.

Schema findings are from local migration files and application types, not a verified live database. No remote database was queried and no credentials or production records were used. Before testing migrations, verify the actual local schema against migration history; report drift instead of assuming edited historical files describe the deployed schema.

No general Item Master workbook import workflow or installed XLSX parser was found. The existing `scripts/import-freight-workbook.py` uses standard-library ZIP/XML extraction for a fixed freight workbook; attachment upload controls are not import pipelines. Reuse established validation, UI, Supabase session and inventory transaction conventions; do not use the freight data model for item data.

## 2. Located workbook and observed data

Confirmed source: `/mnt/e/Mayank Sir/Apps/Item master v5.xlsx`.

SHA-256: `1702c9562fcd612abc9b5c31d60a8d671db7a1a23aab9bf3e2889f1925d6b24c`.

It contains one sheet, `Sheet1`, range `A1:O1995`: one header row and 1,994 nonempty data rows. It matches all six approved column names. The user subsequently confirmed this file as the intended source.

| Column | Header | Proposed handling |
| --- | --- | --- |
| A | New code | `items.item_code`; retain original in traceability |
| B | Item name | `items.item_name` |
| C | Item group | Subcategory within the row's Family |
| D | Type | Item Type |
| E | Family | Item Category |
| F | Store | Existing Stock Location master; staged item/location association |
| G | Unit | Unit of Measurement |
| H | Status | New Stock Classification; never item activity state |
| I | Opening qty | Stock proposal source only; no master-import posting |
| J | Rejected qty | Stock proposal source only; interpretation unresolved |
| K | Rate (Rs) | Proposed `items.cogs_unit_cost`, subject to approval |
| L | Value (Rs) | Source reconciliation only; formula `I*K` |
| M | Rejected value (Rs) | Source reconciliation only; formula `J*K` |
| N | Uses in 6 months | Source metadata only; no fabricated ERP movements |
| O | Last used | Source metadata only; Excel date conversion for preview |

Observed classification counts are workbook values, not counts of records to create:

- 14 Families: DBX, GEN, LED, MCB, SWG, CBL, FAN, GLM, GPS, GYS, MCC, RCC, SNE, WD.
- 5 Types: Consumable, Finished good, Other, Packaging, Raw material.
- 3 Stores: Store A1, Store B, Store A2.
- 4 Units: PCS, KG, MTR, BUNDLE.
- 6 Status values: Dead stock: review; Keep: active; Keep: slow; Keep: no stock yet; Rejected only; Rejected stock only. Keep both rejected labels distinct.
- 856 nonblank distinct Item group labels. There are 865 Family/group combinations including one blank-group combination; 864 nonblank combinations. Eight group labels occur under multiple Families, including Hrc Fuse under DBX/SWG and Motor under FAN/GEN.
- Item group is blank on sheet rows 1912 (`RM-WD-0001`, PC GREY) and 1913 (`RM-WD-0002`, PC WHITE).
- All codes and names are populated. No duplicate codes under case/whitespace normalization were found. One normalized name appears twice: SOLAR ST LIGHT OLD STOCK 15W, rows 727 and 1718, with different codes. Flag for review; never merge by name alone.
- Opening qty, Rejected qty and Rate are populated, numeric and nonnegative in this file; 55 rows have nonzero Rejected qty, and 200 rows have zero Rate. These observations do not establish their business meaning.
- Value and Rejected value are formulas on all 1,994 rows. Last used is populated on 1,115 rows. The workbook uses the default 1900 date system. Numeric XML includes floating-point residue, so decimal precision needs explicit handling before persistence.

Missing workbook fields include make/brand, model/part number, HSN, dimensions, weight, description and reorder/minimum stock levels. Preserve existing values and leave unsupported new-item fields null. Do not parse implied specifications from names or fabricate measurements.

## 3. Approved master mapping and reuse

| Excel | Configuration master | Existing/proposed table |
| --- | --- | --- |
| Family | Item Categories | `item_categories` |
| Item group | Item Subcategories | `item_subcategories` |
| Type | Item Types | `item_types` |
| Unit | Units of Measurement | `units_of_measurement` |
| Store | Inventory Stock Locations | `stock_locations` |
| Status | Stock Classification | proposed `stock_classifications` |

Reuse `items`, `item_activities`, `inventory_balances`, `inventory_transactions`, ERP profiles/roles/section permissions and existing item references in purchase, PI, packing, dispatch and GP workflows. Do not create Item Families or Item Groups tables. Existing Stock Locations live at `/inventory/locations`; expose the same records through Configuration navigation rather than duplicating that master.

Resolve exact names first, then unambiguous normalized equivalents. Proposed normalization is trimming, collapsing incidental whitespace and case folding, consistently in TypeScript and PostgreSQL. Preserve raw values. Do not equate abbreviations, punctuation variants or meanings: MCC, SWG and an existing SWITCHGEARS record remain distinct unless an administrator explicitly consolidates them.

Resolve categories first; match subcategories by resolved category UUID plus normalized name. Existing indexes already scope subcategory names and codes by category. Preserve repeated names under different parents. Block ambiguity, inactive matches, name/code disagreement and schema uniqueness conflicts; do not reparent, reactivate, discard or merge automatically. Reruns must reuse stable UUIDs.

Existing indexes use lower/trim names and upper/trim codes. Before enforcing stronger whitespace normalization, report collisions among existing records. Do not drop constraints or auto-clean records. Use transaction locks and database checks for all relevant import and manual master writes so concurrent requests cannot introduce normalized duplicates; add stronger unique indexes only after preflight confirms they can be installed without data changes.

## 4. Proposed import workflow

1. Admin uploads/selects an XLSX file. Server parses and validates it, records its digest, original name, sheet, row numbers, raw values, parser version and selected mapping. Retain a private source artifact for audit; never place workbook data in a public bundle.
2. Validate sheet/header selection explicitly. Detect missing/duplicate headers, unsupported/encrypted/corrupt files, malformed cells, Excel error values and excessive file/expanded ZIP size or row counts. Do not execute formulas, macros or external links. Restrict formulas to approved reconciliation columns; verify formula shape and cached-value consistency without assuming caches are current.
3. Build a read-only preview with classification reused/new/unresolved counts and item create/unchanged/conflict/error counts, row-level messages, original values and proposed UUID links. No business masters or balances change during preview; staging metadata may be persisted.
4. Admin resolves inactive/ambiguous values explicitly, corrects source errors, or explicitly excludes affected rows. Re-preview after changes. No placeholder classifications. Proposed blank-group policy: allow null subcategory because the ERP permits it, show both affected rows prominently; requires approval.
5. Compare item codes case-insensitively with all existing items, including inactive ones. Identical existing records are skipped/reused; changed records are conflicts, not updates. Proposed initial scope is create-only plus explicit reuse; existing-item edits stay in normal Item Master until a separately approved field-diff update feature exists. Duplicate codes within a workbook block affected rows; matching names with different codes are warnings requiring acknowledgement.
6. Bind confirmation to an immutable staged revision and server-computed digest. At execution recheck authorization, current master state, item conflicts and mapping versions. If relevant data changed, invalidate preview and require review again.
7. Commit the explicitly selected valid rows and required classifications in one transaction. Recheck parent/active constraints inside the transaction, create missing values, insert items, retain source-to-item UUID links, and use existing item activity triggers. A failure rolls back all business changes in that commit; record the failed attempt separately after rollback. Excluded rows remain reported. Do not claim rolled-back rows were created.
8. A unique commit request key, batch lock and immutable successful result make retries idempotent. File digest identifies a source but does not prohibit a corrected mapping revision. Repeat imports also resolve existing business keys, rather than relying solely on a file hash. Report created/updated/skipped/failed counts; initial updated count is zero. Include reused/created/unresolved classification counts and downloadable row issues.

Preserve workbook codes. Phase 7B's `auto_allocate_item_code` currently rejects supplied codes for automatic Item Types. Proposed initial behavior is to block such matches for explicit administrator resolution, rather than change type settings, consume number counters or silently substitute generated codes. A protected explicit-code import exception would require separate approval.

Stock Location has a required unique code while the workbook supplies a name only. Proposed approach: preview a deterministic collision-checked technical code for each new location, editable before confirmation; do not change existing location codes or default flags. New Item Types keep automatic numbering disabled and other new masters use existing schema defaults. These are proposed technical defaults, not inferred workbook facts.

## 5. Costing and quantity precision

The existing COGS field is `items.cogs_unit_cost numeric(15,4)`, guarded by Item Master Edit permission. The quantity ledger uses `numeric(24,6)`. Workbook Rate is a plausible source for COGS but the missing plan's intended costing basis cannot be recovered. Confirm Rate-to-COGS and whether explicit zero means a real zero cost or unknown cost. Until decided, retain Rate in staging and block any unapproved cost mapping; never overwrite existing COGS or historical GP snapshots.

Use decimal arithmetic. Proposed policy: show rounding to target precision in preview, require acknowledgement for changed values, reject overflow/nonfinite/negative values and do not treat missing numbers as zero. Reconcile Value against Opening qty times Rate and Rejected value against Rejected qty times Rate, with a documented approved currency tolerance; discrepancies block the stock proposal until resolved. Currency precision/tolerance is an assumption requiring approval. Source values stay available even when target values are rounded.

## 6. Separate stock preview, approval and posting

Product import may create classifications and items, but must never create balances or post quantity movements. Store mappings are staged lineage, not a balance insert. Proposed item representation is one nullable `stock_classification_id`; Store remains per-source-row/per-location because balances already support multiple locations. Confirm this item-level Status assumption if a product can have different classifications at different stores.

After item mapping, create a separate stock proposal. Require an explicit operation, effective date, reason, unit mapping and administrator selection; the header Opening qty is evidence, not permission to post opening stock. Show workbook/sheet/rows, stable item/location IDs, raw quantities, current on-hand/reserved/damaged/available, proposed movement type and deltas, and resulting balances. Reject unresolved or inactive mappings, duplicate item/location entries unless explicitly resolved, incompatible units, negative/overflow inputs and violations of inventory rules. Zero deltas produce no movement.

Unresolved business rules: whether Opening qty is usable stock, total stock including rejected stock, or a target balance; whether Rejected qty maps to damaged inventory; and whether balances should be openings, additions or target adjustments. Do not subtract or add rejected quantities based on assumption. Disable posting until these choices are explicit in the proposal and confirmed.

Use `post_inventory_movement` and its current inventory checks, not direct balance writes. Existing opening-once, availability and reserved-within-on-hand constraints remain enforced. Posting rejected stock may need an additive inventory RPC if current DAMAGE semantics cannot express the approved operation; do not imitate DAMAGE by overwriting a balance.

Persist a versioned preview with source/mapping digest, operation, quantities and inventory state/version, including absence of balances. Record who approved and when. Posting checks all reviewed data again under locks in stable item/location order, coordinated with the existing movement function's locking protocol. Detect any intervening balance change, including a change that later returns to the same quantity; use a transactional balance version/ledger watermark rather than quantity equality alone. A missing balance also needs serialization against concurrent first postings.

Any changed source, mapping, item/unit/location eligibility or inventory state invalidates approval and requires fresh preview/approval. Approve and post may be one explicit admin action if all checks occur in the same transaction. Record before/after balances, approver/poster, timestamps, batch/row lineage and transaction UUIDs. Lock proposal state and enforce unique posting keys so concurrency/retries cannot double-post. Failure rolls back all proposal movements. Rejection/cancellation changes only proposal state. Posted corrections use existing auditable reversal/correcting movements; never delete ledger history.

## 7. Configuration lifecycle and explicit consolidation

All six mapped masters must support search/filter, Add, Edit, Activate, Deactivate and safe Delete, with the existing visual design. Stock Locations currently lacks search/filter and the item master screens currently lack deletion/consolidation; implement these rather than claiming they exist.

Renames retain UUIDs. Server/database checks prevent new selection of inactive values while retaining unchanged historical references. Prevent reparenting a referenced subcategory into an inconsistent category. Reject deleting any referenced value, including dependent subcategories, items, balances, immutable transactions, GP snapshots and durable import references. Return the concrete reason and offer deactivation. Retain audit text snapshots without cascading deletes. Do not grant unrestricted direct deletion merely to enable a UI button.

Explicit consolidation requires a source, target, affected-reference preview and administrator confirmation. Lock and revalidate both records, check parent and unit compatibility, migrate only eligible current references atomically, deactivate the source and preserve history/audit snapshots. Keep immutable inventory transaction references intact; for locations with historical ledger/balance references, block consolidation and offer deactivation unless a separately designed auditable migration is approved. Do not rewrite historical transactions, GP snapshots or import source data. Report unsupported consolidation cases rather than silently dropping references.

## 8. Proposed incremental database changes

Names below are proposed implementation names, not existing tables:

- `stock_classifications`: UUID, nullable code, name, description, sort order, active state and actor/time metadata, consistent normalized uniqueness, RLS and restrictive foreign keys.
- Nullable `items.stock_classification_id` referencing that master. No duplicate family/group/location tables and no item-level balance columns.
- `item_import_batches` and `item_import_rows`: private source storage reference/digest, schema/parser version, staged revision/state, raw and parsed data, validation/resolution results, approved selection, immutable commit result, request keys, item/master UUID lineage and actor/time metadata. Rows distinguish excluded/errors from committed/skipped results.
- `item_import_stock_proposals` and `item_import_stock_proposal_rows`: revision, explicit operation, source rows, resolved IDs, reviewed balance/version, proposed deltas/results, approval/posting state, unique retry keys and resulting inventory transaction references. Supporting detail tables may be consolidated if integrity stays enforceable.
- `item_master_admin_activities`: audit for lifecycle and consolidation across existing mapped masters; keep `item_activities` for product history. Restrict mutation of audit history.
- Add a reliable inventory balance version if existing timestamps/ledger state cannot provide the required stale-state guarantee; review the latest posting implementation before choosing the exact lock/version change. Preserve normal posting behavior.
- Transactional RPCs for preview finalization/commit, stock approval/posting, safe deletion and consolidation. Add database guards for active selections and parent preservation, concurrency-safe normalization, restrictive dependencies, state transitions and request uniqueness. No historical migration edits.

Use authenticated session clients. Imports, classification creation/lifecycle/consolidation and stock approval/posting require an active Admin, checked in server actions and database RPCs; retain existing normal Item Master permissions and COGS checks. Reuse `configuration.masters`, `inventory.items`, `inventory.locations` and `inventory.movements` section access as relevant. Do not broaden unrelated role access. New tables and private source storage need RLS, controlled read policies, no anonymous access, and no direct mutable access to approval/audit/posting state. Security-definer functions require explicit actor/permission checks, qualified names, fixed search_path, and restricted execute grants. Never use a browser service-role key.

## 9. Proposed application files

Modify existing files in place, preserving unrelated edits:

- `app/(erp)/configuration/item-actions.ts`, `components/configuration/item-configuration-section.tsx`, `app/(erp)/configuration/page.tsx` and relevant Configuration navigation for Stock Classification and a link to the shared location master, deletion and consolidation.
- `app/(erp)/inventory/stock-actions.ts`, `app/(erp)/inventory/locations/page.tsx`, location components for lifecycle/search and safe deletion.
- `lib/database.types.ts`, `lib/inventory/data.ts`, `lib/inventory/item.ts`, Inventory item actions, item form, list/detail/edit/new screens for classification and active-value handling.
- New `app/(erp)/inventory/items/import/` pages/actions and import components, `lib/inventory/import/` parser/validation/resolution/preview helpers, and a separate stock-proposal review route/action.
- New incremental files under `supabase/migrations/`; new import unit/database tests plus targeted existing test updates; README local-use instructions and an implementation report.
- `package.json` and lockfile only if a maintained XLSX parser is required. Choose and verify its current official documentation during implementation; no dependency is installed by this plan. Read relevant installed Next.js guides before application code changes, per AGENTS.md.

## 10. Validation and rollback acceptance

Use sanitized fixtures and this workbook read-only; do not commit the user's raw workbook or hardcode its contents into the production application. Tests must cover all six mappings, exact/normalized matches, case/whitespace collisions, missing values, inactive/ambiguous matches, 864 nonblank parent/group pairs, repeated group names, preserved MCC/SWG/SWITCHGEARS distinctions, and separate rejected Status labels.

Test duplicate codes, different codes with identical names, existing-item conflicts, auto-code conflicts, missing unsupported fields, decimal/date/formula errors, cost mapping, unchanged existing UUIDs/relationships, repeat imports, request retries and concurrent classification/import requests. Test all lifecycle actions, parent edits, referenced deletion, direct database bypass attempts, explicit consolidation/audit and inactive historical selection preservation.

Local PostgreSQL acceptance tests must execute the new migration/RPCs and test rollback after a deliberately induced mid-commit failure, stale previews, RLS under anon/nonadmin/admin roles, unchanged stock after master import, rejected/cancelled proposals, changed mappings/units/balances, concurrent first-balance creation, stale approval even after balances return to previous values, atomic multirow posting and duplicate-post prevention. Reuse the repository's optional PGlite test pattern; use local PostgreSQL for concurrency tests if independent connections/locks cannot be faithfully tested by that harness. Never substitute source-text assertions for transactional guarantees.

After implementation run `npx tsc --noEmit`, `npm run lint`, `node --experimental-strip-types --test tests/*.test.mjs`, the new local database acceptance script and `npm run build`. Record preexisting failures separately from regressions; run targeted existing database suites when shared inventory/permission behavior changes. Manual local testing: migrate a disposable database, sign in with test roles, preview the workbook, resolve issues, commit master data, repeat, verify Configuration and Item Master, then separately preview/approve stock using approved business rules. Confirm ledger/balances remain unchanged before stock approval.

Before local migrations, snapshot the disposable test database. Schema rollout is additive and transactional where supported. Import commit failures roll back business data; successful imports are not undone by deleting referenced masters/items. Deactivate unused data or use a separately reviewed correction; preserve audits. Failed stock posting rolls back atomically, and posted stock corrections use compensating ledger entries. No production rollback SQL, destructive reset, automatic commit, push, deployment or production migration/import is authorized.

## 11. Approval decisions still needed

1. Confirm `Item master v5.xlsx` is the intended source.
2. Approve or amend the proposed create-only/reuse policy, nullable blank subcategories on rows 1912/1913, duplicate-name acknowledgement, generated location-code preview, and blocking automatic-code conflicts.
3. Confirm Rate-to-COGS, zero-cost interpretation, decimal rounding acknowledgement and value-reconciliation currency tolerance. Proposed tolerance: Rs 0.01, subject to approval.
4. Confirm item-level Stock Classification rather than classification per item/location; Store associations remain staging/stock lineage rather than a new default item store.
5. Define stock quantity semantics, rejected-stock treatment and effective-date rules before enabling stock posting. Product/classification implementation can proceed after plan approval while posting stays blocked on these business rules.

The user subsequently approved core implementation: create/reuse without overwrites; nullable blank subcategories; separate duplicate-name products with warnings; previewed technical location codes; blocking automatic-code conflicts; new-item Rate-to-COGS with zero warnings, four decimals and Rs 0.01 tolerance; item-level Stock Classification; and non-posting stock review. The decisions above are retained as reconstruction history. Actual stock posting remains unapproved and disabled. No production execution, commit, push or deployment is authorized.
