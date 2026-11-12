# ADHUNIK ONE ERP Item Master Excel integration plan — final Configuration decisions

Date: 2026-11-12

This amendment governs Configuration mapping and stock-import approval in the previously prepared implementation plan. All remaining Item Master, costing, inventory, Excel import, security and validation requirements from that plan remain in force. This is a planning document, not authorization to run an import.

## Configuration mapping

Reuse existing Configuration masters; do not introduce separate Item Families or Item Groups masters.

| Excel column | ERP Configuration master |
| --- | --- |
| Family | Item Categories |
| Item group | Item Subcategories |
| Type | Item Types |
| Unit | Units of Measurement |
| Store | Inventory Stock Locations |
| Status | New Stock Classification master |

Status describes stock classification and must not be confused with a record's active/inactive state.

## Classification import and relationship preservation

1. Extract every unique classification value from the actual workbook and resolve it in the mapped master. Reuse exact matches first, then unambiguous normalized equivalents; create missing values. Normalization may reconcile case and incidental whitespace, but must not infer equivalence from similar meanings, abbreviations or different wording. Preserve original workbook values in import traceability.
2. MCC and SWITCHGEARS remain separate classifications. Any consolidation of distinct classifications requires an explicit administrator action after import.
3. Resolve Item Categories before Item Subcategories. Resolve each subcategory within its parent category using the workbook's actual Family and Item group combination; never match Item group globally without checking its parent.
4. Where one Item group appears under multiple Families, preserve each observed parent-child combination using the existing data model. If existing uniqueness constraints prevent that representation, report the conflict for administrator resolution; do not silently reparent, merge or discard values.
5. Preserve every existing master record, identifier and relationship. Do not replace masters, change existing parent links, or reactivate inactive matches silently. Ambiguous matches and inactive matches require an explicit resolution before affected rows can proceed.
6. Blank or invalid classifications must be reported according to the prior plan's validation rules; do not invent placeholder classifications or silently drop supplied values.
7. Make resolution repeatable: importing the same workbook again must reuse resolved classifications and parent-child combinations without introducing duplicates. Include counts and row-level issues for reused, created and unresolved values in the preview and import report.

## Administrative management

Provide Add, Edit, Activate, Deactivate and safe Delete for all mapped Configuration masters, including the new Stock Classification master. Imported values remain editable under the same administrative controls as other master records.

Administrators must be able to clean up names, explicitly consolidate classifications and deactivate unused classifications after import. Consolidation must preview affected references, require an explicit target and administrator confirmation, preserve relationship integrity and transaction history, and be auditable. Never automatically consolidate based on assumed similarities.

Renaming must preserve stable identifiers and references. Deactivation must retain existing references and history while preventing new selection as required by the prior plan. Reject deletion when a record is referenced by products, transactions, or dependent records such as subcategories. Enforce these protections on the server and through database constraints where supported, including concurrent requests; do not rely only on disabled UI controls. Show the reason deletion is blocked and offer deactivation. Do not cascade-delete referenced ERP data.

Apply the prior plan's authorization, validation and audit requirements to all administrative operations and imports.

## Separate stock quantity preview and approval

Importing item details or classifications must not automatically import stock quantities or overwrite inventory balances.

Before any quantity posting, implement a separate stock preview and approval workflow:

1. Stage stock quantities without modifying inventory. Validate item and stock-location mappings, units, duplicate rows and all quantity rules from the prior plan.
2. Show the source workbook and rows, item, location, current balance, proposed quantity, proposed movement or adjustment and resulting balance. Clearly identify the proposed operation; do not assume whether an Excel quantity is an opening balance, adjustment or replacement balance.
3. Block unresolved mapping and validation errors. Require an authorized administrator's explicit approval of the reviewed stock proposal before posting. Classification or item-import approval does not imply stock approval.
4. Bind approval to the precise staged data and inventory state reviewed. If source data, mappings or balances change before posting, invalidate the affected approval and require a fresh preview and approval.
5. Post through the existing inventory transaction and audit mechanisms with the prior plan's costing and inventory rules. Use atomic posting and duplicate-post prevention so retries cannot apply quantities twice. Record who approved and posted, when, and the approved before/after balances and source batch.
6. Cancelling or rejecting a stock proposal leaves existing inventory balances unchanged. Never directly overwrite balances as an automatic side effect of Excel import.

## Local validation and release boundary

Verify locally before any release:

- All six Excel mappings use the designated masters; only Stock Classification is new.
- Exact and normalized equivalents are reused, missing classifications are created, and repeat imports introduce no duplicates.
- MCC and SWITCHGEARS remain distinct; ambiguous matches are surfaced.
- Actual Family/Item group combinations retain correct parent links, including repeated group names under different Families and conflicts with existing records.
- Existing master records and relationships remain intact; imported values support all required administrator actions.
- Referenced records cannot be deleted; deactivation retains history; unauthorized operations are rejected.
- Item/classification imports leave inventory balances unchanged. Stock posting requires a separate approved preview; stale approval, failed posting and retries cannot silently change or double-post inventory.
- Remaining Item Master, costing, inventory, import, security and validation acceptance criteria from the earlier plan continue to pass.

Do not push to GitHub or deploy automatically. Local test results must be recorded before a later, explicitly authorized push or deployment.
