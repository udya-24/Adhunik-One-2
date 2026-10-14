# Dispatch Freight Calculator

Apply `supabase/migrations/202610140001_dispatch_freight_calculator.sql` before opening `/dispatch/freight-calculator`. The migration adds the estimate table, indexes, RLS, draft attachment RPC, and section permissions; existing Packing List grants carry over. It does not rewrite existing Packing Lists or Dispatches.

Source: `Freight Calculator.xlsx`, imported into `lib/dispatch/freight-workbook.json`. Reproduce the import with:

```sh
python3 scripts/import-freight-workbook.py '/path/to/Freight Calculator.xlsx'
```

The extracted artifact retains source SHA-256, formulas, rate rows, 21,761 PIN codes, and the cached Summary reference. Rates are looked up from the extracted workbook rather than defined in application code. The importer rejects changes to key formula shapes, requiring review before using revised logic.

## Calculation behavior

- Item calculations use current linked Item Master dimensions (mm), unit weights (kg), and packed quantities. Carton calculations use Packing List dimensions and gross weights. Missing linked masters, dimensions, weights, or PI values prevent saving; legacy data is never overwritten.
- Volume converts mm³ to m³; volumetric weight reproduces `inches³ × 6 / 1728` from Details of Items. Each line uses the greater of actual and volumetric weight. Shipment weight uses the greater of summed carton and item chargeable weights, retaining packaging weight without double-counting items.
- Shipment value prorates PI line values after discount and before GST to the packed quantity, as stated on the screen.
- Workbook Summary B7–B20 applies the 20 kg minimum, Excel nearest-integer rounding, zone rate, rounded base/fuel/insurance/GST, ODA minimum, e-way bill charge, insurance minimum, and taxable minimum. Minimum freight adjustment appears in Other Charges; handling is zero because the calculator supplies no handling rule.
- Match workbook lookups: city/state from ALL INDIA PIN CODES; zone from the first matching city in that sheet; ODA from PIN CODES FROM 18.08.2025. Do not replace these with the December sheet without revising the workbook rules. Unknown PINs, missing ODA statuses and invalid zones fail explicitly.
- Delhivery is the supplied B2B ledger's current provider. The calculator workbook has a destination tariff only; From PIN resolves origin metadata, but cannot vary rates. Other transport partners and transit-day estimates are unavailable until a corresponding tariff is provided.
- `Adhunik_B2B_Aug_26.xlsx` is historical billing evidence, not a rate/formula workbook. Its billed e-way/minimum charges and origin-specific rates differ from the calculator. This implementation intentionally follows the requested calculator, not historical invoice totals.

## Estimates and Dispatches

Saving recalculates on the server. Every estimate stores a data snapshot for HTML/PDF summaries. Dispatch detail shows its attached estimate or the latest full-Packing-List quote when created. Explicit attachment applies freight and transporter only to editable draft Dispatches with every Packing List carton selected. The server rejects stale snapshots before attachment. A partial package selection detaches the full-list estimate and clears its applied freight; manual freight/transporter changes also detach it. Confirmed dispatch freight cannot be changed through attachment.

Download `/api/freight-calculations/{id}/summary` for a standalone PDF, or use the printable summary page. Both read saved data under the user's access policies.

## Validation

```sh
node --experimental-strip-types --test tests/freight.test.mjs tests/freight-data.test.mjs tests/freight-summary.test.mjs tests/packing.test.mjs tests/dispatch.test.mjs tests/pi-dispatch-handoff.test.mjs tests/permissions.test.mjs
node tests/freight-database.mjs
node node_modules/typescript/bin/tsc --noEmit
```

Database regression uses the repository's optional cached PGlite runtime. It validates the actual migration, permission inheritance, saving, attachment, unchanged package selections, partial selections, manual edits, and authorization checks. The reference workbook test verifies ₹12,000 base + ₹1,800 fuel + ₹300 insurance + ₹150 e-way charge + ₹2,565 GST = ₹16,815 total.

These checks do not apply the migration to a hosted Supabase project or replace an authenticated browser smoke test against real ERP records.
