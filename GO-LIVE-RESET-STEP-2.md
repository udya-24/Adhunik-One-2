==================================================
DANGER — DESTRUCTIVE GO-LIVE RESET
==================================================

TAKE A FULL SUPABASE DATABASE BACKUP BEFORE RUNNING THIS SQL.

ALSO BACK UP / EXPORT APPROVED SUPABASE STORAGE OBJECTS IF THEY MAY BE REQUIRED LATER.

THIS RESET IS IRREVERSIBLE AFTER COMMIT WITHOUT A BACKUP.

==================================================

# GO-LIVE RESET — STEP 2 READY

Generated 2026-09-02 UTC. The package is local and has not been executed.

## Pre-reset current counts

Latest read-only inspection:

| Area | Table | Rows |
|---|---|---:|
| Items | `items` | 2 |
| Item activity | `item_activities` | 4 |
| Customers / contacts / addresses | `customer_companies` / `customer_contacts` / `customer_addresses` | 3 / 2 / 2 |
| Suppliers / activity | `suppliers` / `supplier_activities` | 1 / 2 |
| Inquiries | `inquiries` | 21 |
| Orders | `orders` | 21 |
| PIs / items / activities / documents | PI tables | 18 / 20 / 49 / 6 |
| Payment receipts | `sales_payment_receipts` | 2 (₹250.86) |
| Packing lists | `packing_lists` | 20 |
| Dispatches | `dispatches` | 7 |
| Purchase indents / requisitions | header tables | 10 / 4 |
| Purchase orders | `purchase_orders` | 11 (9 normal + 2 revisions) |
| Material receipts / inventory postings | header/posting tables | 3 / 3 |
| Inventory transactions / balances | inventory tables | 10 / 2 |
| Attendance | `monthly_attendance` | 3 |
| Payroll runs / employee rows / incentive details / audit | payroll tables | 2 / 6 / 9 / 35 |
| Salary structures | `employee_salary_structures` | 4 — KEEP |
| Approved test LOI | `hr_letters` | 1 |

Run `supabase/go-live-reset-preview.sql` again immediately before execution because transactional counts may change. The reset script deliberately does not fail merely because transaction counts differ, but it does fail if the explicitly approved master rows differ or unexpected master/inventory rows appear.

## Expected post-reset counts

Zero: inquiries, orders, PIs, PI children, receipts, packing lists, dispatches, indents, requisitions, POs/revisions, material receipts/postings, attendance, payroll transactions/audit/incentives, approved item/customer/supplier rows and children, approved-item inventory rows, and the approved Rohit LOI/activity.

Unchanged: employees, salary structures, identity/access, access audit, departments, designations, teams, employment types, system settings, configuration masters, financial years, units, item classification masters, package types, stock locations, document/letter configuration, functions, triggers, RLS, buckets, migrations, and schema.

## 1. Approved Deletion Scope

The script removes all pre-go-live transactional rows from CRM inquiries/orders; PI headers, revisions, items, activities and documents; payment receipts; packing and dispatch; purchase indents, legacy requisitions, POs/revisions, receipts; test attendance and payroll; and their enumerated children/audit rows.

It also removes inventory history/balances only for the two approved test item UUIDs, then deletes the approved item/customer/supplier masters and the one approved LOI.

Storage objects are not removed by the database script.

## 2. Protected Data

Employees, employee addresses/teams/photos, salary structures, employee numbering, auth users, profiles, roles, permissions, access audit, invitations, organizational/configuration masters, financial years, settings, item classification masters, units, package types, stock locations, PI branding/settings, HR letter settings/templates/assets, functions, triggers, RLS, buckets, migrations, and schema remain.

The current public schema does not expose standalone `companies` or `branches` tables. Company/branch configuration represented through protected settings/snapshots is not targeted. The script captures and compares protected `system_settings` count as part of its safety checks.

## 3. Master Data

Deletion is constrained by UUID and identifying values:

- `f31df934-4e55-47ba-ab69-b1d42627ed89` — `Test-MCB-001`, MCB testing
- `3738f482-7292-4a06-996d-2f13c03d6c37` — `EVCAR-0001`, Car ev tata CURV Facelift edition
- `c49d173b-6616-4eb3-a7aa-a4e7e78744a0` — Tata Motors
- `1599564f-6c56-46dd-880d-aca5ceab9a0d` — Mahindera
- `bc5a7108-089d-4d7c-b57a-76c9092140f9` — Tech Mahindera
- `de445868-eeda-4a79-92f4-35485a3112d0` — `SUP/0001`, Shalimar Cotton Mills
- `65edf692-d821-4821-8b8f-9e5e187d8f00` — Rohit `ADH-EMP-0003` LOI dated 2026-08-27

Any added or changed item/customer/supplier makes pre-flight abort. The LOI identity must also match.

## 4. Transaction Counts

The latest counts are in “Pre-reset current counts” above. Transactional tables are intentionally treated as the complete approved pre-go-live set at execution time; exact Step 1 counts are not hard-coded.

## 5. Inventory Handling

All 10 current ledger rows point to the approved item UUIDs:

- 3 `MATERIAL_RECEIPT` stock-ins, each backed by `material_receipt_inventory_postings`.
- 3 `DISPATCH` stock-outs, each referencing an approved dispatch.
- 1 opening-stock and 3 adjustment-in test transactions for the same approved items.

Pre-flight aborts if any inventory transaction or balance belongs to another item, or if an MR/dispatch reference is orphaned. The script locks inventory tables, removes exact MR posting links, temporarily disables only the named immutable-history and balance-control triggers, removes ledger/balance rows for the two approved item IDs, and immediately restores both triggers. It asserts that no approved-item balance remains before attempting Item Master removal and verifies both triggers are enabled again before commit. Stock locations remain untouched.

No unrestricted `DELETE FROM inventory_transactions` or `DELETE FROM inventory_balances` is used.

## 6. Storage

Currently approved files by metadata/live path:

| Bucket | Files |
|---|---:|
| `crm-inquiry-attachments` | 1 |
| `crm-order-attachments` | 0 |
| `pi-documents` | 6 |
| `sales-payment-proofs` | 2 |
| `item-images` | 0 |
| `dispatch-documents` | 0 |

Run and export `supabase/go-live-storage-cleanup-manifest.sql` before the database reset. It reads live Storage objects and maps only paths belonging to approved records. Database row deletion does not remove Storage files. Never include `employee-photos`, `pi-branding`, or `hr-letter-assets` in this cleanup.

## 7. Numbering Reset

| Document | Current counter | Reset baseline | Expected first go-live number |
|---|---:|---:|---|
| Customer | 1 | 0 | `CUS-0001` |
| Supplier | 1 | 0 | `SUP/0001` |
| Inquiry | 21 | 0 | `INQ-2026-0001` |
| Order | 21 | 0 | `ORD-2026-0001` |
| PI | 17 | 0 | `PI-2026-0001` |
| Packing List | 20 | 0 | `PL/2026/0001` |
| Dispatch | 7 | 0 | `DSP/2026/0001` |
| Purchase Indent (2026) | 10 | 0 | `IND/2026/0001` |
| Purchase Order (2026) | 9 | 0 | `PO/2026/0001` |
| Material Receipt (2026) | 3 | 0 | `MR/2026/0001` |

Legacy purchase-indent/requisition and 2026 PON counters associated with the removed legacy flow are also set to 0. No item counter exists. PO and PI revisions have no separate counter and do not consume normal document numbers.

## 8. PI Numbering

The active PI configuration is prefix `PI`, separator `-`, padding 4, financial-year inclusion enabled, and current active financial-year code `2026`. The exact computed first PI after baseline reset is **`PI-2026-0001`**.

The script computes and asserts this result before performing destructive work. If configuration changes and the value differs, it aborts with `PI NUMBERING CONFIGURATION MUST BE FIXED BEFORE GO-LIVE RESET`.

## 9. Employee Numbering

**NOT RESET.** Current employee counter is 13. The script captures its pre-reset value and verifies it is unchanged before commit. It does not touch `employee_code_seq` or employee codes.

## 10. Salary Structures

**KEEP.** All 4 current `employee_salary_structures` rows remain. The script captures their live pre-reset count and requires the same count before commit rather than hard-coding 4.

## 11. Reset SQL

`supabase/go-live-reset.sql` — **GENERATED BUT NOT EXECUTED.** It is an operational SQL file, not a migration.

## 12. Storage Manifest

`supabase/go-live-storage-cleanup-manifest.sql` — **READ-ONLY.** Run/export it before database reset; use the exported exact object list for a separately approved Storage operation afterward.

## 13. Transaction Safety

The reset uses one transaction:

1. `BEGIN` and advisory lock.
2. Required schema/function/trigger checks.
3. Exclusive target-table locks.
4. Stable master identity, unexpected-row, inventory-attribution, and PI-format checks.
5. Protected-count snapshot.
6. Foreign-key-ordered removal.
7. Approved counter baselines.
8. Zero-target, trigger-restoration, counter, protected-count, salary, and employee-number validations.
9. Result summaries and `COMMIT`.

Any error before commit rolls the transaction back, including the temporary trigger-state change.

## 14. Backup

**FULL SUPABASE DATABASE BACKUP REQUIRED BEFORE EXECUTION.** Export any Storage objects that might be needed later; database backup and Storage backup are separate concerns.

## 15. Exact Manual Execution Instructions

1. Stop all test data entry and application writes.
2. Take a full Supabase database backup.
3. Back up required Storage files.
4. Run the **entire** `supabase/go-live-reset-preview.sql` in Supabase SQL Editor.
5. Run the **entire** `supabase/go-live-storage-cleanup-manifest.sql`; export and review its results.
6. Compare both outputs with the approved scope and this report.
7. Review `supabase/go-live-reset.sql` line by line.
8. Run the **entire `supabase/go-live-reset.sql`** in Supabase SQL Editor—not selected fragments.
9. Confirm it reaches `COMMIT` with no exception and review its final protected/counter result sets.
10. Re-run the read-only preview for post-reset verification.
11. Separately remove only the Storage paths from the exported, approved manifest.
12. Verify the ERP opens and protected HR/access/configuration data remains.
13. Create controlled first production documents and confirm each approved sequence begins at `0001`.

This package has not performed any of these execution steps.

## 16. Application Changes

None.

## 17. Migration

No schema migration is required. `supabase/go-live-reset.sql` is deliberately outside `supabase/migrations/`.

## 18. Git

Changes remain local. No Git commit, GitHub push, Vercel deployment, or Supabase mutation was performed.
