-- ADHUNIK ERP GO-LIVE RESET PREVIEW
-- READ-ONLY: run this entire file in Supabase SQL Editor.

select 'generated_at_utc' as metric, now()::text as value;

select * from (
  select 'customer_companies' as table_name, count(*)::bigint as record_count from public.customer_companies
  union all select 'customer_contacts', count(*) from public.customer_contacts
  union all select 'customer_addresses', count(*) from public.customer_addresses
  union all select 'suppliers', count(*) from public.suppliers
  union all select 'supplier_activities', count(*) from public.supplier_activities
  union all select 'items', count(*) from public.items
  union all select 'item_activities', count(*) from public.item_activities
  union all select 'inquiries', count(*) from public.inquiries
  union all select 'inquiry_assignments', count(*) from public.inquiry_assignments
  union all select 'inquiry_status_history', count(*) from public.inquiry_status_history
  union all select 'inquiry_follow_ups', count(*) from public.inquiry_follow_ups
  union all select 'inquiry_attachments', count(*) from public.inquiry_attachments
  union all select 'orders', count(*) from public.orders
  union all select 'order_activities', count(*) from public.order_activities
  union all select 'order_attachments', count(*) from public.order_attachments
  union all select 'proforma_invoices', count(*) from public.proforma_invoices
  union all select 'proforma_invoice_items', count(*) from public.proforma_invoice_items
  union all select 'proforma_invoice_activities', count(*) from public.proforma_invoice_activities
  union all select 'proforma_invoice_documents', count(*) from public.proforma_invoice_documents
  union all select 'sales_payment_receipts', count(*) from public.sales_payment_receipts
  union all select 'packing_lists', count(*) from public.packing_lists
  union all select 'packing_list_items', count(*) from public.packing_list_items
  union all select 'packing_list_packages', count(*) from public.packing_list_packages
  union all select 'packing_list_package_contents', count(*) from public.packing_list_package_contents
  union all select 'packing_list_activities', count(*) from public.packing_list_activities
  union all select 'dispatches', count(*) from public.dispatches
  union all select 'dispatch_packages', count(*) from public.dispatch_packages
  union all select 'dispatch_documents', count(*) from public.dispatch_documents
  union all select 'dispatch_activities', count(*) from public.dispatch_activities
  union all select 'purchase_indents', count(*) from public.purchase_indents
  union all select 'purchase_indent_items', count(*) from public.purchase_indent_items
  union all select 'purchase_indent_activities', count(*) from public.purchase_indent_activities
  union all select 'purchase_requisitions', count(*) from public.purchase_requisitions
  union all select 'purchase_requisition_items', count(*) from public.purchase_requisition_items
  union all select 'purchase_requisition_activities', count(*) from public.purchase_requisition_activities
  union all select 'purchase_orders', count(*) from public.purchase_orders
  union all select 'purchase_order_items', count(*) from public.purchase_order_items
  union all select 'purchase_order_activities', count(*) from public.purchase_order_activities
  union all select 'material_receipts', count(*) from public.material_receipts
  union all select 'material_receipt_items', count(*) from public.material_receipt_items
  union all select 'material_receipt_activities', count(*) from public.material_receipt_activities
  union all select 'material_receipt_inventory_postings', count(*) from public.material_receipt_inventory_postings
  union all select 'inventory_transactions', count(*) from public.inventory_transactions
  union all select 'inventory_balances', count(*) from public.inventory_balances
  union all select 'monthly_attendance', count(*) from public.monthly_attendance
  union all select 'payroll_runs', count(*) from public.payroll_runs
  union all select 'employee_monthly_payroll', count(*) from public.employee_monthly_payroll
  union all select 'payroll_crm_incentive_details', count(*) from public.payroll_crm_incentive_details
  union all select 'payroll_audit', count(*) from public.payroll_audit
  union all select 'employee_salary_structures', count(*) from public.employee_salary_structures
  union all select 'hr_letters', count(*) from public.hr_letters
  union all select 'hr_activity', count(*) from public.hr_activity
  union all select 'erp_access_audit', count(*) from public.erp_access_audit
) counts
order by table_name;

select 'INQUIRY' as document, min(inquiry_number) as first_number, max(inquiry_number) as last_number, count(*) as rows from public.inquiries
union all select 'ORDER', min(order_number), max(order_number), count(*) from public.orders
union all select 'PROFORMA_INVOICE', min(pi_number), max(pi_number), count(*) from public.proforma_invoices
union all select 'PACKING_LIST', min(packing_list_number), max(packing_list_number), count(*) from public.packing_lists
union all select 'DISPATCH', min(dispatch_number), max(dispatch_number), count(*) from public.dispatches
union all select 'PURCHASE_INDENT', min(indent_number), max(indent_number), count(*) from public.purchase_indents
union all select 'PURCHASE_ORDER', min(po_number), max(po_number), count(*) from public.purchase_orders where revision_number = 0
union all select 'MATERIAL_RECEIPT', min(receipt_number), max(receipt_number), count(*) from public.material_receipts;

select entity_type, prefix, separator, padding, suffix, include_year, include_financial_year, is_active
from public.numbering_configurations
order by entity_type;

select entity_type, current_value, updated_at
from public.numbering_counters
order by entity_type;

select entity_type, calendar_year, current_value, updated_at
from public.procurement_year_counters
order by entity_type, calendar_year;

select entity_type, financial_year_id, current_value, updated_at
from public.purchase_number_counters
order by entity_type, financial_year_id;

select calendar_year, current_value, updated_at
from public.purchase_pon_counters
order by calendar_year;

select id, supplier_code, supplier_name, trade_name, gstin, contact_person, phone, email, city, state, is_active, created_at
from public.suppliers
order by supplier_name;

select id, company_code, legal_name, trade_name, gstin, is_active, created_at
from public.customer_companies
order by legal_name;

select id, item_code, item_name, model_part_number, is_active, created_at
from public.items
order by item_code;

select status, count(*) as receipts, sum(amount_received) as total_received,
       count(*) filter (where proof_storage_path is not null) as proof_paths
from public.sales_payment_receipts
group by status
order by status;

select id, proforma_invoice_id, status, amount_received, payment_received_date,
       proof_file_name, proof_storage_path
from public.sales_payment_receipts
order by payment_received_date, id;

select year, month, count(*) as attendance_rows, count(distinct employee_id) as employees
from public.monthly_attendance
group by year, month
order by year, month;

select year, month, status, count(*) as runs
from public.payroll_runs
group by year, month, status
order by year, month, status;

select pr.year, pr.month, ep.status, count(*) as employee_rows, sum(ep.net_payable) as net_payable
from public.employee_monthly_payroll ep
join public.payroll_runs pr on pr.id = ep.payroll_run_id
group by pr.year, pr.month, ep.status
order by pr.year, pr.month, ep.status;

select ss.id, ss.employee_id, e.employee_code, e.full_name, ss.effective_from, ss.fixed_gross
from public.employee_salary_structures ss
join public.employees e on e.id = ss.employee_id
order by e.employee_code, ss.effective_from;

select id, employee_id, letter_type, status, letter_date, employee_name, employee_code, subject, created_at
from public.hr_letters
order by created_at;

select bucket_id, count(*) as object_count, coalesce(sum((metadata ->> 'size')::bigint), 0) as total_bytes
from storage.objects
where bucket_id in (
  'crm-inquiry-attachments', 'crm-order-attachments', 'pi-documents',
  'sales-payment-proofs', 'item-images', 'dispatch-documents',
  'employee-photos', 'pi-branding', 'hr-letter-assets'
)
group by bucket_id
order by bucket_id;

select bucket_id, name, created_at, updated_at, metadata ->> 'size' as size_bytes
from storage.objects
where bucket_id in (
  'crm-inquiry-attachments', 'crm-order-attachments', 'pi-documents',
  'sales-payment-proofs', 'item-images', 'dispatch-documents'
)
order by bucket_id, name;

select tc.table_name, kcu.column_name, ccu.table_schema as referenced_schema,
       ccu.table_name as referenced_table, ccu.column_name as referenced_column,
       rc.delete_rule
from information_schema.table_constraints tc
join information_schema.key_column_usage kcu
  on kcu.constraint_name = tc.constraint_name and kcu.constraint_schema = tc.constraint_schema
join information_schema.constraint_column_usage ccu
  on ccu.constraint_name = tc.constraint_name and ccu.constraint_schema = tc.constraint_schema
join information_schema.referential_constraints rc
  on rc.constraint_name = tc.constraint_name and rc.constraint_schema = tc.constraint_schema
where tc.constraint_type = 'FOREIGN KEY'
  and tc.table_schema = 'public'
order by referenced_table, table_name, column_name;
