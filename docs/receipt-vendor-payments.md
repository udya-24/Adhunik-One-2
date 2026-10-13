Material Receipts and Vendor Payments

Apply `supabase/migrations/202610130001_receipt_vendor_payments.sql` before deploying the application changes. It adds the private `purchase-commercial-documents` bucket, receipt document metadata, company/year GRN counters, vendor payables, payment records and Finance → Vendor Payments permission section. Admin/Manager access follows the existing permission rules; grant other finance users View/Edit through ERP access management.

This installation has one issuing legal entity. Purchase Orders now carry `issuing_company_key`, defaulting to `ADHUNIK`; counters are scoped to this key and calendar year. Customer Companies remain external customers. Any future issuing companies must receive their own keys on their POs.

Historical confirmed receipts receive GRNs and Pending payables using their original PO total. Historical invoice dates stay blank; unknown dates are not fabricated. Cancelled historical receipts receive Cancelled payables. Zero-value invoices are Paid. Review historical payables for payments recorded outside this new ledger before entering new payments.

New receipts require an Invoice Date no later than today's India date. Save Draft supports replacement of the GRN and invoice documents. Confirming rechecks remaining PO quantities, generates the GRN and creates the payable in one database transaction. Replaced draft files remain in private storage for audit retention. Confirmed attachments cannot be replaced.

Each receipt uses the full approved PO value as requested, including partial deliveries. If a supplier invoice covers only a partial delivery, this workflow still creates a payable for the full PO value; invoice allocation across partial deliveries is outside the specified behavior.

Document uploads enforce a 1 MiB limit and matching PDF/JPEG/PNG signatures on the server, with size validation in the browser and Storage bucket. Stored `*_file_url` values are private storage paths; authorized preview/download routes create 60-second signed URLs. The existing Supabase service role configuration is required for signing private documents and failed-upload cleanup.

Payments lock the payable, enforce positive amounts with at most two decimal places, reject overpayment and update Paid Amount/Balance/Status atomically. Receipts with recorded payments cannot be cancelled. Purchase Orders can close after all material is received and their payables are settled; closure remains the existing explicit action.

Local verification:
- `node --experimental-strip-types --test tests/commercial-documents.test.mjs tests/commercial-document-route.test.mjs tests/receipt-queue.test.mjs tests/purchase-pricing.test.mjs tests/payment-receipts.test.mjs tests/permissions.test.mjs`
- `node tests/vendor-payments-database.mjs` (uses the existing cached PGlite runtime)
- `node node_modules/typescript/bin/tsc --noEmit`

The PGlite suite validates the SQL migration, backfill, invoice dates, company numbering, draft confirmation, attachment ownership, payment calculations, cancellation and closure guards. Route tests use mocked Storage responses. Actual upload, preview and download in the connected Supabase project require a post-migration browser smoke test.
