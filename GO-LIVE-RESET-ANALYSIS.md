# GO-LIVE RESET ANALYSIS

Analysis timestamp: 2026-09-02 UTC. This is a read-only Step 1 report based on the live Supabase REST schema/data, all migrations through `202609020030_sales_payment_receipts.sql`, generated database types, data-access code, server actions, functions, triggers, and storage configuration. No database row, counter, storage object, schema, migration, or application file was changed.

## 1. Executive Summary

The live project contains a compact development/test transaction chain spanning CRM, sales, dispatch, procurement, inventory, attendance, and payroll. The target transaction set can be reset, but it is highly interconnected through restrictive foreign keys and audit/activity rows. Material receipts are not isolated: 3 receipt-item postings point to inventory transactions, and the database currently has 10 inventory transactions and 2 balances.

The master-data decision is different:

- The 2 items visibly look like test/demo records and are candidates for removal after all item references are cleared.
- All 3 customers are candidates for review/removal, but names resembling real companies do not prove that the records are real or disposable.
- The sole supplier, Shalimar Cotton Mills, is **UNCERTAIN**. It must not be removed automatically.
- Employees, identity/access, configuration, salary structures, and HR configuration remain protected.

Before any future reset: **TAKE A FULL SUPABASE DATABASE BACKUP.** Storage objects require a separate backup/export because database backup alone is not a dependable backup of bucket objects.

## 2. Data Preview

Live counts:

| Module | Actual table(s) | Count | Planned action |
|---|---|---:|---|
| Item Master | `items`, `item_activities` | 2, 4 | REVIEW then remove target rows and children |
| Customer Master | `customer_companies`, `customer_contacts`, `customer_addresses` | 3, 2, 2 | REVIEW then remove target rows and children |
| Vendor Master | `suppliers`, `supplier_activities` | 1, 2 | REVIEW; no automatic supplier removal |
| CRM Inquiries | `inquiries` plus 4 child tables | 21 | Transaction reset candidate |
| CRM Orders | `orders`, `order_activities`, `order_attachments` | 21, 25, 0 | Transaction reset candidate |
| Proforma Invoices | `proforma_invoices`, items, activities, documents | 18, 20, 49, 6 | Transaction reset candidate |
| Payment Receipts | `sales_payment_receipts` | 2; ₹250.86 total | Transaction reset candidate |
| Packing Lists | `packing_lists` plus item/package/activity tables | 20 | Transaction reset candidate |
| Dispatches | `dispatches`, packages, documents, activities | 7, 7, 0, 37 | Transaction reset candidate |
| Purchase Indents | `purchase_indents` plus items/activities | 10, 13, 30 | Transaction reset candidate |
| Purchase Requisitions | `purchase_requisitions` plus items/activities | 4, 6, 17 | Derived purchase-flow data; reset candidate |
| Purchase Orders | `purchase_orders`, items, activities | 11, 13, 32 | 9 normal + 2 revisions; reset candidate |
| Material Receipts | `material_receipts`, items, activities, inventory postings | 3, 3, 6, 3 | Reset only with inventory reconciliation |
| Attendance | `monthly_attendance` | 3 | Test attendance reset candidate |
| Payroll | runs, employee payroll, incentive details, audit | 2, 6, 9, 35 | Test payroll reset candidate |

Table classification (each named table inherits the classification shown):

| Classification | Tables |
|---|---|
| Proposed reset | `inquiries`, `orders`, `proforma_invoices`, `sales_payment_receipts`, `packing_lists`, `dispatches`, `purchase_indents`, `purchase_requisitions`, `purchase_orders`, `material_receipts`, `monthly_attendance`, `payroll_runs`, `employee_monthly_payroll` |
| Derived/child | `inquiry_assignments`, `inquiry_status_history`, `inquiry_follow_ups`, `inquiry_attachments`, `order_activities`, `order_attachments`, `proforma_invoice_items`, `proforma_invoice_activities`, `proforma_invoice_documents`, `packing_list_items`, `packing_list_packages`, `packing_list_package_contents`, `packing_list_activities`, `dispatch_packages`, `dispatch_documents`, `dispatch_activities`, `purchase_indent_items`, `purchase_indent_activities`, `purchase_requisition_items`, `purchase_requisition_activities`, `purchase_order_items`, `purchase_order_activities`, `material_receipt_items`, `material_receipt_activities`, `material_receipt_inventory_postings`, `payroll_crm_incentive_details`, `payroll_audit` |
| Review | `items`, `item_activities`, `customer_companies`, `customer_contacts`, `customer_addresses`, `suppliers`, `supplier_activities`, affected `inventory_transactions`, affected `inventory_balances`, `hr_letters`, related `hr_activity`, affected numbering/counter rows and transactional Storage objects |
| Keep | `item_categories`, `item_subcategories`, `item_types`, `item_brands`, `units_of_measurement`, `package_types`, `stock_locations`, `employee_salary_structures`, `hr_letter_settings`, `hr_letter_templates`, `pi_document_settings`, `financial_years`, `payment_terms`, `system_settings` |
| System — never reset | `employees`, `employee_addresses`, `employee_teams`, `departments`, `designations`, `teams`, `employment_types`, `customer_types`, `erp_profiles`, `erp_roles`, `erp_permission_sections`, `erp_user_permissions`, `erp_access_audit`, `employee_invitations`, `auth.users`, schema functions/triggers/policies/migrations/buckets |

## 3. Item Master

`items.id` is the UUID primary key. Classification/type relationships are `category_id -> item_categories`, optional `subcategory_id -> item_subcategories`, optional `item_type_id -> item_types`, optional `brand_id -> item_brands`, and `unit_id -> units_of_measurement`. There is no company column on `items`.

Live records:

- `Test-MCB-001` / “MCB testing” — LIKELY TEST/DUMMY.
- `EVCAR-0001` / “Car ev tata CURV Facelift edition” — LIKELY TEST/DUMMY from its demo-like context, but review before removal.

Incoming dependencies are `item_activities.item_id`, `proforma_invoice_items.inventory_item_id`, `packing_list_items.item_id`, `purchase_indent_items.item_id`, `purchase_requisition_items.item_id`, `purchase_order_items.item_id`, `material_receipt_items.item_id`, `inventory_balances.item_id`, and `inventory_transactions.item_id`. Most are restrictive, so items cannot safely be removed first.

Item codes are entered by the application/user and only checked for trimmed content and uniqueness (case-insensitive unique index). There is no item-code sequence or counter. No item counter reset is required; go-live code `...0001` must be chosen through the business convention used when creating the first production item.

## 4. Customer Master

`customer_companies.id` is the parent. `customer_contacts.customer_company_id` and `customer_addresses.customer_company_id` use restrictive foreign keys. Inquiries, orders, PIs, payment receipts, packing lists, and dispatches also point directly to the company. Contacts are referenced by inquiries, orders, and PIs; addresses are referenced by orders and PIs. Snapshot JSON/text fields preserve historic address/contact/customer values inside transactions.

Live customers are Tata Motors, Mahindera, and Tech Mahindera. These look like demo data in context, but company-name resemblance is not proof; classify all three as **REVIEW** before the future reset.

Customer numbering uses `allocate_business_number('CUSTOMER')`, `numbering_configurations`, and `numbering_counters`. Only Tech Mahindera has `CUS-0001`; current counter is 1. A future approved customer reset can set the CUSTOMER counter baseline to 0 so the allocator produces `CUS-0001`. The other two null codes predate the configured trigger and should be noted during review.

## 5. Vendor Master

The actual master is `suppliers`; contact, address, banking, and tax fields are columns on the same row. There are no separate supplier contact/address/bank tables. `supplier_activities` is its child. Purchase requisitions (legacy supplier selection), purchase orders, material receipts, and material-receipt inventory postings reference suppliers.

| Classification | Records | Reason |
|---|---|---|
| LIKELY TEST/DUMMY | None safely proven | Development-era creation alone is insufficient |
| LIKELY REAL | None safely proven | The visible row is plausible but unverified |
| UNCERTAIN | `SUP/0001` — Shalimar Cotton Mills | Plausible name/contact; GST value looks placeholder-like, but evidence is mixed |

Manual review is mandatory. Supplier numbering is `allocate_business_number('SUPPLIER')` backed by `numbering_counters`; current value is 1. Reset only if the supplier is explicitly approved for removal.

## 6. CRM

Inquiries use `inquiries` with `inquiry_assignments` (21), `inquiry_status_history` (29), `inquiry_follow_ups` (22), and `inquiry_attachments` (1). There is no inquiry-items table: requirement content is stored on the inquiry header. Orders are one-to-one with inquiries and use `orders`, `order_activities` (25), and `order_attachments` (0). Order commercial/customer/shipping details are stored on the header as live references plus snapshots.

Numbers are `INQ-2026-0001` through `INQ-2026-0021` and `ORD-2026-0001` through `ORD-2026-0021`. Both use `allocate_business_number`, configuration rows, and global `numbering_counters` values of 21. Their future baseline is 0, producing `...0001` on the next allocation.

Inquiry/order attachment metadata is separate from Storage objects, so row cleanup alone can orphan files.

## 7. Sales

The PI structure is `proforma_invoices` (header, customer/contact/address snapshots, shipping contact, commercial terms, GST, freight, remarks, status and revision links), `proforma_invoice_items`, `proforma_invoice_activities`, and `proforma_invoice_documents`. Six generated document metadata rows exist.

There are 18 PI rows but only 17 normal allocations: one PI revision reuses `PI-2026-0014`, and one early malformed value is `PI-FINANCIAL YEAR-0001`. Current allocator counter is 17. Revisions are created by copying the root number and incrementing `revision_number`, so they do not consume the normal counter.

Payment receipts are in `sales_payment_receipts`, linked restrictively to company and PI. Both live receipts are VALID, total ₹250.86, and both have proof paths. Cancellation identity/time/reason and creator identity are stored on the row. Eligible CRM collections are copied into `payroll_crm_incentive_details`; the latest migration adds `payment_receipt_id`, proof path, payment date, amount received, and receipt status to those payroll snapshots.

## 8. Dispatch

Packing uses `packing_lists`, `packing_list_items`, `packing_list_packages`, `packing_list_package_contents`, and `packing_list_activities`. Counts are 20, 23, 14, 18, and 57. It links to PI, PI items, order, company, item master, and package types.

Dispatch uses `dispatches`, `dispatch_packages`, `dispatch_documents`, and `dispatch_activities`. Counts are 7, 7, 0, and 37. The header contains PI/order/packing links and snapshots plus transporter, freight, vehicle, LR/GR, tracking, e-way bill, and stock-location data. Dispatch confirmation can post `STOCK_OUT` inventory transactions; existing inventory transactions must be classified by `reference_type/reference_id` before removal.

Ranges are `PL/2026/0001`–`PL/2026/0020` and `DSP/2026/0001`–`DSP/2026/0007`. Both use `allocate_business_number` and global counter values 20 and 7.

## 9. Purchase

The full flow is indent -> optional requisition/PON -> PO -> receipt -> inventory posting. Requisitions remain in the schema even though the newer direct-indent PO path permits null `requisition_id`.

PO revisions are rows in `purchase_orders` with `root_po_id`, `parent_po_id`, `revision_number`, reason/time/user, copied items, activities, and status `SUPERSEDED` on the prior row. The database has 9 normal POs and 2 `Revised-01` rows. A revision derives `<root>-Revised-NN` and does not call the normal allocator.

Current ranges are `IND/2026/0001`–`0010`, normal `PO/2026/0001`–`0009`, and `MR/2026/0001`–`0003`. Current production allocators use `procurement_year_counters` per calendar year: IND=10, PO=9, MR=3. Older `purchase_number_counters` and `purchase_pon_counters` rows remain as legacy counters for the requisition-era flow and should be reviewed/reset only if their related rows are included.

Material receipt posting creates `material_receipt_inventory_postings` linking receipt, receipt item, PO, supplier, and `inventory_transactions`. Cancellation posts inventory reversals rather than erasing stock history. The future reset must identify all MR- and dispatch-derived transactions, reconcile/rebuild `inventory_balances`, and preserve unrelated/manual inventory transactions.

## 10. HR & Payroll

Attendance is `monthly_attendance`, unique by employee/month/year. Three rows exist, all for August 2026. Payroll has 2 runs: August 2026 FINALIZED and September 2026 DRAFT. There are 6 employee payroll rows, 9 CRM incentive detail snapshots, and 35 payroll audit rows.

Deletion order within HR is payroll audit and incentive details, employee payroll rows, payroll runs, then attendance. Employee master remains. `payroll_audit` has nullable foreign keys with default NO ACTION behavior, so it should be handled before its referenced payroll rows rather than left dangling.

Salary structures are separate and protected: 4 structures across 3 employees, effective 2026-08-01 (3) and 2026-09-01 (1). They are referenced by employee payroll. Do not include them in an automatic reset.

Optional test data: one finalized LOI exists for Rohit (`ADH-EMP-0003`), dated 2026-08-27. No Appointment Letter row exists. The LOI remains a manual-review item, not part of the reset set.

## 11. Storage Cleanup

Relevant configured buckets/path conventions:

- `crm-inquiry-attachments`: `<inquiry-id>/<uuid>-<file>`; metadata in `inquiry_attachments`.
- `crm-order-attachments`: `<order-id>/<uuid>-<file>`; metadata in `order_attachments`.
- `pi-documents`: `<pi-id>/<revision>/<uuid>-<file>`; metadata in `proforma_invoice_documents`.
- `sales-payment-proofs`: `<company-id>/<pi-id>/<receipt-id>/<file>`; metadata is on `sales_payment_receipts`.
- `item-images`: item images referenced by `items.image_path`.
- `dispatch-documents`: dispatch document files referenced by `dispatch_documents`.
- Protected/non-transaction buckets: `employee-photos`, `pi-branding`, `hr-letter-assets`.

Database foreign keys do not cascade to Storage. Orphaned objects will remain unless the future workflow first exports an object manifest/backup and then explicitly removes only approved paths. The read-only preview lists every relevant object and aggregates count/size per bucket.

## 12. Audit Logs

Module activity tables use real foreign keys and generally block parent removal unless handled first. They are transactional children, not an independent immutable audit archive. `payroll_audit` similarly references payroll runs/rows. `erp_access_audit` is unrelated to reset-target documents and must remain untouched. `hr_activity` remains unless an optional HR-letter cleanup is separately approved.

Recommended go-live handling: preserve identity/access audit; include target module activity/history rows in the transaction reset; export an audit snapshot before the reset if historical traceability is desired.

## 13. Numbering Counters

| Document | Current number / counter | Mechanism | Future baseline |
|---|---|---|---:|
| Customer | `CUS-0001`; 1 | `allocate_business_number` + `numbering_counters` | 0 if all approved customers removed |
| Supplier | `SUP/0001`; 1 | same global allocator | REVIEW |
| Inquiry | `INQ-2026-0021`; 21 | same global allocator | 0 |
| Order | `ORD-2026-0021`; 21 | same global allocator | 0 |
| PI | normal counter 17 | same allocator; financial-year formatting configuration | 0 |
| Packing List | `PL/2026/0020`; 20 | same global allocator | 0 |
| Dispatch | `DSP/2026/0007`; 7 | same global allocator | 0 |
| Purchase Indent | `IND/2026/0010`; 10 | `allocate_procurement_number` + `procurement_year_counters` | 0 for 2026 |
| Purchase Order | normal `PO/2026/0009`; 9 | same yearly procurement allocator | 0 for 2026 |
| PO revision | two `Revised-01` rows | derived from root PO + revision max | no independent counter |
| Material Receipt | `MR/2026/0003`; 3 | yearly procurement allocator | 0 for 2026 |
| Purchase Requisition/PON | legacy rows/counters exist | `purchase_number_counters` / `purchase_pon_counters` | REVIEW with requisitions |
| Item | codes are user/application supplied | no counter | none |
| Employee | current counter 13 | protected global allocator and legacy sequence history | **DO NOT RESET** |

Important PI issue: configuration requests a financial-year token, but actual later values are `PI-2026-...` while the first is literally `PI-FINANCIAL YEAR-0001`. Validate the current financial-year formatting before Step 2; the reset should not silently change configuration.

## 14. Foreign-Key Dependency Order

Exact high-level safe order for the future transactional reset (self-referencing revisions must be processed leaves-first):

1. Export/backup and inventory the approved Storage object paths.
2. `payroll_audit` and `payroll_crm_incentive_details`.
3. `employee_monthly_payroll`, then `payroll_runs`, then `monthly_attendance`.
4. `dispatch_documents`, `dispatch_activities`, `dispatch_packages`, dispatch-derived inventory transactions/balance effects, then `dispatches`.
5. `packing_list_package_contents`, `packing_list_packages`, `packing_list_items`, `packing_list_activities`, then `packing_lists`.
6. `sales_payment_receipts` and their approved proof objects.
7. `proforma_invoice_documents`, `proforma_invoice_activities`, then PI revision rows leaves-first, `proforma_invoice_items`, and root `proforma_invoices`.
8. `order_attachments`, `order_activities`, then `orders`.
9. `inquiry_attachments`, `inquiry_follow_ups`, `inquiry_assignments`, `inquiry_status_history`, then `inquiries`.
10. Material-receipt inventory postings plus their exact inventory transaction/balance effects; then `material_receipt_activities`, `material_receipt_items`, and `material_receipts`.
11. `purchase_order_activities`, PO revision items/rows leaves-first, normal PO items/rows.
12. `purchase_requisition_activities`, `purchase_requisition_items`, `purchase_requisitions`.
13. `purchase_indent_activities`, `purchase_indent_items`, `purchase_indents`.
14. Item-linked remaining inventory/activities and every other item FK, then approved `items`.
15. Approved `supplier_activities`/`suppliers` only after manual supplier decision.
16. Customer contacts/addresses only after all transaction references are gone, then approved customer companies.
17. Only after successful row cleanup, set approved counter baselines inside the same future transaction where compatible; perform Storage cleanup from the saved manifest separately.

The final Step 2 script must re-query live foreign keys and counts immediately before execution and use one PostgreSQL transaction for database changes so failures are atomic where possible.

## 15. KEEP LIST

Companies/branches configuration, employees, auth users, profiles/login linkage, departments, designations, teams, roles, Phase 9 permission tables, ERP access configuration, system settings, approval/company configuration, financial years, payment terms, package types, units, item classification masters unless separately approved, stock locations, PI/HR document settings, HR templates/header/footer, salary structures, all database functions/triggers/RLS/policies/buckets/migrations/schema, employee numbering, employee photos, branding assets, and `erp_access_audit`.

## 16. PROPOSED RESET LIST

After explicit approval: CRM inquiries/orders and children; PIs/items/activities/documents; payment receipts/proof objects; packing and dispatch rows/children/documents; purchase indents/requisitions/POs/revisions/receipts and children; precisely attributable inventory postings/transactions/balance effects; test attendance/payroll/incentive/audit rows; approved test items/customers; and only the corresponding approved counters.

## 17. REVIEW LIST

- All 3 customer records.
- Sole supplier Shalimar Cotton Mills and supplier counter.
- Item `EVCAR-0001` despite likely demo context.
- Any inventory transaction not provably derived from a reset-target receipt/dispatch.
- Legacy purchase requisitions and their older counters.
- The finalized LOI for Rohit.
- Salary structures (default KEEP).
- Every Storage object against the generated manifest.
- PI financial-year formatting anomaly.

## 18. Read-Only Preview SQL

File: `supabase/go-live-reset-preview.sql`.

**THIS SQL IS READ-ONLY.** Run the **entire** file in Supabase SQL Editor immediately before approving Step 2. It returns current counts, number ranges, counter/configuration values, master-data review rows, receipt totals/proof paths, HR periods, salary structures, optional HR letters, Storage manifests, and the current foreign-key catalog.

## 19. Next Step

Stop here. After the preview output and REVIEW decisions are supplied and the reset list is approved, Step 2 is creation of the actual Go-Live Reset SQL and a separately controlled Storage cleanup manifest. No destructive script has been created or executed in this step.
