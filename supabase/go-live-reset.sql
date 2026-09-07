-- ================================================================
-- ADHUNIK ERP CONTROLLED GO-LIVE DATABASE RESET
-- GENERATED FOR MANUAL REVIEW. DESTRUCTIVE. NOT A MIGRATION.
-- Run this entire file only after backups and final preview approval.
-- Storage objects are handled separately by the read-only manifest.
-- ================================================================

begin;

set local lock_timeout = '10s';
set local statement_timeout = '10min';

-- Serialize the one-time reset against other reset sessions.
select pg_advisory_xact_lock(hashtextextended('adhunik-go-live-reset-v1', 0));

-- Required schema/function pre-flight.
do $$
declare
  required_table text;
  required_column record;
  required_tables constant text[] := array[
    'items','item_activities','customer_companies','customer_contacts','customer_addresses',
    'suppliers','supplier_activities','inquiries','inquiry_assignments','inquiry_status_history',
    'inquiry_follow_ups','inquiry_attachments','orders','order_activities','order_attachments',
    'proforma_invoices','proforma_invoice_items','proforma_invoice_activities','proforma_invoice_documents',
    'sales_payment_receipts','packing_lists','packing_list_items','packing_list_packages',
    'packing_list_package_contents','packing_list_activities','dispatches','dispatch_packages',
    'dispatch_documents','dispatch_activities','purchase_indents','purchase_indent_items',
    'purchase_indent_activities','purchase_requisitions','purchase_requisition_items',
    'purchase_requisition_activities','purchase_orders','purchase_order_items','purchase_order_activities',
    'material_receipts','material_receipt_items','material_receipt_activities',
    'material_receipt_inventory_postings','inventory_transactions','inventory_balances',
    'monthly_attendance','payroll_runs','employee_monthly_payroll','payroll_crm_incentive_details',
    'payroll_audit','employee_salary_structures','employees','hr_letters','hr_activity',
    'numbering_configurations','numbering_counters','procurement_year_counters',
    'purchase_number_counters','purchase_pon_counters','erp_profiles','erp_roles',
    'erp_permission_sections','erp_user_permissions','erp_access_audit','departments','designations',
    'teams','employment_types','system_settings'
  ];
begin
  foreach required_table in array required_tables loop
    if to_regclass('public.' || required_table) is null then
      raise exception 'RESET ABORTED: required table public.% is missing', required_table;
    end if;
  end loop;

  for required_column in
    select * from (values
      ('items','id'), ('items','item_code'),
      ('customer_companies','id'), ('customer_companies','legal_name'),
      ('suppliers','id'), ('suppliers','supplier_code'),
      ('inventory_transactions','item_id'), ('inventory_transactions','reference_type'),
      ('inventory_transactions','reference_id'), ('inventory_transactions','reversal_of'),
      ('material_receipt_inventory_postings','inventory_transaction_id'),
      ('proforma_invoices','root_pi_id'), ('proforma_invoices','revised_from_id'),
      ('purchase_orders','root_po_id'), ('purchase_orders','parent_po_id'),
      ('sales_payment_receipts','proof_storage_path'),
      ('numbering_counters','entity_type'), ('numbering_counters','current_value'),
      ('procurement_year_counters','calendar_year'),
      ('hr_activity','entity_type'), ('hr_activity','entity_id')
    ) expected(table_name, column_name)
  loop
    if not exists (
      select 1 from information_schema.columns c
      where c.table_schema = 'public'
        and c.table_name = required_column.table_name
        and c.column_name = required_column.column_name
    ) then
      raise exception 'RESET ABORTED: required column public.%.% is missing', required_column.table_name, required_column.column_name;
    end if;
  end loop;

  if to_regprocedure('public.allocate_business_number(text)') is null
     or to_regprocedure('public.allocate_procurement_number(text)') is null then
    raise exception 'RESET ABORTED: expected numbering allocator function is missing';
  end if;

  if (select count(*) from public.numbering_counters where entity_type = 'EMPLOYEE') <> 1 then
    raise exception 'RESET ABORTED: protected EMPLOYEE numbering counter is missing or duplicated';
  end if;

  if not exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'inventory_transactions'
      and t.tgname = 'inventory_transactions_immutable' and not t.tgisinternal
  ) then
    raise exception 'RESET ABORTED: expected inventory immutability trigger is missing';
  end if;

  if not exists (
    select 1 from pg_trigger t
    join pg_class c on c.oid = t.tgrelid
    join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'inventory_balances'
      and t.tgname = 'inventory_balances_control' and not t.tgisinternal
  ) then
    raise exception 'RESET ABORTED: expected inventory balance-control trigger is missing';
  end if;
end $$;

-- Lock every reset-target table so no new test transaction can race this script.
lock table
  public.items, public.item_activities,
  public.customer_companies, public.customer_contacts, public.customer_addresses,
  public.suppliers, public.supplier_activities,
  public.inquiries, public.inquiry_assignments, public.inquiry_status_history,
  public.inquiry_follow_ups, public.inquiry_attachments,
  public.orders, public.order_activities, public.order_attachments,
  public.proforma_invoices, public.proforma_invoice_items,
  public.proforma_invoice_activities, public.proforma_invoice_documents,
  public.sales_payment_receipts,
  public.packing_lists, public.packing_list_items, public.packing_list_packages,
  public.packing_list_package_contents, public.packing_list_activities,
  public.dispatches, public.dispatch_packages, public.dispatch_documents, public.dispatch_activities,
  public.purchase_indents, public.purchase_indent_items, public.purchase_indent_activities,
  public.purchase_requisitions, public.purchase_requisition_items, public.purchase_requisition_activities,
  public.purchase_orders, public.purchase_order_items, public.purchase_order_activities,
  public.material_receipts, public.material_receipt_items, public.material_receipt_activities,
  public.material_receipt_inventory_postings,
  public.inventory_transactions, public.inventory_balances,
  public.monthly_attendance, public.payroll_runs, public.employee_monthly_payroll,
  public.payroll_crm_incentive_details, public.payroll_audit,
  public.hr_letters, public.hr_activity,
  public.numbering_counters, public.procurement_year_counters,
  public.purchase_number_counters, public.purchase_pon_counters
in access exclusive mode;

-- Stable approved master IDs and identity assertions.
create temporary table approved_reset_items(id uuid primary key, item_code text, item_name text) on commit drop;
insert into approved_reset_items values
  ('f31df934-4e55-47ba-ab69-b1d42627ed89', 'Test-MCB-001', 'MCB testing'),
  ('3738f482-7292-4a06-996d-2f13c03d6c37', 'EVCAR-0001', 'Car ev tata CURV Facelift edition');

create temporary table approved_reset_customers(id uuid primary key, legal_name text) on commit drop;
insert into approved_reset_customers values
  ('c49d173b-6616-4eb3-a7aa-a4e7e78744a0', 'Tata Motors'),
  ('1599564f-6c56-46dd-880d-aca5ceab9a0d', 'Mahindera'),
  ('bc5a7108-089d-4d7c-b57a-76c9092140f9', 'Tech Mahindera');

create temporary table approved_reset_suppliers(id uuid primary key, supplier_code text, supplier_name text) on commit drop;
insert into approved_reset_suppliers values
  ('de445868-eeda-4a79-92f4-35485a3112d0', 'SUP/0001', 'Shalimar Cotton Mills');

create temporary table approved_reset_hr_letters(id uuid primary key, employee_code text, letter_type text, letter_date date) on commit drop;
insert into approved_reset_hr_letters values
  ('65edf692-d821-4821-8b8f-9e5e187d8f00', 'ADH-EMP-0003', 'LOI', '2026-08-27');

do $$
declare expected_pi text;
begin
  if exists (
    select 1 from approved_reset_items a
    left join public.items i on i.id = a.id
    where i.id is null or i.item_code <> a.item_code or i.item_name <> a.item_name
  ) or exists (select 1 from public.items i where not exists (select 1 from approved_reset_items a where a.id = i.id)) then
    raise exception 'RESET ABORTED: Item Master differs from the explicitly approved two-row set; review new/changed items';
  end if;

  if exists (
    select 1 from approved_reset_customers a
    left join public.customer_companies c on c.id = a.id
    where c.id is null or c.legal_name <> a.legal_name
  ) or exists (select 1 from public.customer_companies c where not exists (select 1 from approved_reset_customers a where a.id = c.id)) then
    raise exception 'RESET ABORTED: Customer Master differs from the explicitly approved three-row set; NEW CUSTOMER REQUIRES REVIEW';
  end if;

  if exists (
    select 1 from approved_reset_suppliers a
    left join public.suppliers s on s.id = a.id
    where s.id is null or s.supplier_code <> a.supplier_code or s.supplier_name <> a.supplier_name
  ) or exists (select 1 from public.suppliers s where not exists (select 1 from approved_reset_suppliers a where a.id = s.id)) then
    raise exception 'RESET ABORTED: Supplier Master differs from the explicitly approved one-row set; review new/changed suppliers';
  end if;

  if exists (
    select 1 from approved_reset_hr_letters a
    left join public.hr_letters h on h.id = a.id
    where h.id is null or h.employee_code <> a.employee_code or h.letter_type <> a.letter_type or h.letter_date <> a.letter_date
  ) then
    raise exception 'RESET ABORTED: approved Rohit LOI is missing or changed';
  end if;

  if exists (
    select 1 from public.inventory_transactions t
    where not exists (select 1 from approved_reset_items a where a.id = t.item_id)
  ) or exists (
    select 1 from public.inventory_balances b
    where not exists (select 1 from approved_reset_items a where a.id = b.item_id)
  ) then
    raise exception 'RESET ABORTED: inventory contains a non-approved item; inventory requires manual review';
  end if;

  if exists (
    select 1 from public.inventory_transactions t
    where t.reference_type = 'MATERIAL_RECEIPT'
      and not exists (select 1 from public.material_receipts r where r.id = t.reference_id)
  ) or exists (
    select 1 from public.inventory_transactions t
    where t.reference_type in ('DISPATCH','DISPATCH_REVERSAL')
      and not exists (select 1 from public.dispatches d where d.id = t.reference_id)
  ) then
    raise exception 'RESET ABORTED: an inventory document reference is orphaned or unattributable';
  end if;

  select concat_ws(c.separator, nullif(c.prefix, ''), fy.code,
                   lpad('1', c.padding, '0'), nullif(c.suffix, ''))
  into expected_pi
  from public.numbering_configurations c
  join public.financial_years fy on fy.is_current and fy.is_active and fy.deleted_at is null
  where c.entity_type = 'PROFORMA_INVOICE' and c.is_active
    and c.include_financial_year and not c.include_year;

  if expected_pi is null or expected_pi <> 'PI-2026-0001' then
    raise exception 'PI NUMBERING CONFIGURATION MUST BE FIXED BEFORE GO-LIVE RESET. Current computed first number: %', coalesce(expected_pi, '<unavailable>');
  end if;
end $$;

-- Preserve protected counts and employee numbering before any removal.
create temporary table protected_counts(name text primary key, row_count bigint) on commit drop;
insert into protected_counts values
  ('employees', (select count(*) from public.employees)),
  ('employee_salary_structures', (select count(*) from public.employee_salary_structures)),
  ('erp_profiles', (select count(*) from public.erp_profiles)),
  ('erp_roles', (select count(*) from public.erp_roles)),
  ('erp_permission_sections', (select count(*) from public.erp_permission_sections)),
  ('erp_user_permissions', (select count(*) from public.erp_user_permissions)),
  ('erp_access_audit', (select count(*) from public.erp_access_audit)),
  ('departments', (select count(*) from public.departments)),
  ('designations', (select count(*) from public.designations)),
  ('teams', (select count(*) from public.teams)),
  ('employment_types', (select count(*) from public.employment_types)),
  ('system_settings', (select count(*) from public.system_settings)),
  ('employee_number_counter', (select current_value from public.numbering_counters where entity_type = 'EMPLOYEE'));

-- Payroll and attendance children first.
delete from public.payroll_audit;
delete from public.payroll_crm_incentive_details;
delete from public.employee_monthly_payroll;
delete from public.payroll_runs;
delete from public.hr_activity
where entity_type = 'MONTHLY_ATTENDANCE'
  and description in (select month::text || '/' || year::text from public.monthly_attendance);
delete from public.monthly_attendance;

-- Inventory evidence is fully attributable to the explicitly approved items.
-- Posting links must go first. The immutable-ledger trigger is disabled only
-- for the exact approved-item removal and is restored inside this transaction.
delete from public.material_receipt_inventory_postings;
alter table public.inventory_transactions disable trigger inventory_transactions_immutable;
delete from public.inventory_transactions t
where exists (select 1 from approved_reset_items a where a.id = t.item_id);
alter table public.inventory_transactions enable trigger inventory_transactions_immutable;

alter table public.inventory_balances disable trigger inventory_balances_control;
delete from public.inventory_balances b
where exists (select 1 from approved_reset_items a where a.id = b.item_id);
alter table public.inventory_balances enable trigger inventory_balances_control;

do $$
begin
  if exists (
    select 1 from public.inventory_balances b
    join approved_reset_items a on a.id = b.item_id
  ) then
    raise exception 'RESET ABORTED: approved test-item inventory balances were not removed';
  end if;
end $$;

-- Dispatch, then packing.
delete from public.dispatch_documents;
delete from public.dispatch_activities;
delete from public.dispatch_packages;
delete from public.dispatches;

delete from public.packing_list_package_contents;
delete from public.packing_list_packages;
delete from public.packing_list_items;
delete from public.packing_list_activities;
delete from public.packing_lists;

-- Sales receipts and PI graph.
delete from public.sales_payment_receipts;
delete from public.proforma_invoice_documents;
delete from public.proforma_invoice_activities;
delete from public.proforma_invoice_items;
delete from public.proforma_invoices;

-- CRM order/inquiry graph.
delete from public.order_attachments;
delete from public.order_activities;
delete from public.orders;

delete from public.inquiry_attachments;
delete from public.inquiry_follow_ups;
delete from public.inquiry_assignments;
delete from public.inquiry_status_history;
delete from public.inquiries;

-- Procurement graph after inventory posting links are gone.
delete from public.material_receipt_activities;
delete from public.material_receipt_items;
delete from public.material_receipts;

delete from public.purchase_order_activities;
delete from public.purchase_order_items;
delete from public.purchase_orders;

delete from public.purchase_requisition_activities;
delete from public.purchase_requisition_items;
delete from public.purchase_requisitions;

delete from public.purchase_indent_activities;
delete from public.purchase_indent_items;
delete from public.purchase_indents;

-- Explicitly approved masters only.
delete from public.item_activities a using approved_reset_items approved where a.item_id = approved.id;
delete from public.items i using approved_reset_items approved where i.id = approved.id;

delete from public.supplier_activities a using approved_reset_suppliers approved where a.supplier_id = approved.id;
delete from public.suppliers s using approved_reset_suppliers approved where s.id = approved.id;

delete from public.customer_contacts c using approved_reset_customers approved where c.customer_company_id = approved.id;
delete from public.customer_addresses a using approved_reset_customers approved where a.customer_company_id = approved.id;
delete from public.customer_companies c using approved_reset_customers approved where c.id = approved.id;

-- Explicit test LOI and only its directly linked audit activity.
delete from public.hr_activity a using approved_reset_hr_letters approved
where a.entity_type = 'HR_LETTER' and a.entity_id = approved.id;
delete from public.hr_letters h using approved_reset_hr_letters approved where h.id = approved.id;

-- Approved global business counter baselines. Employee is intentionally absent.
update public.numbering_counters
set current_value = 0, updated_at = now()
where entity_type in (
  'CUSTOMER','SUPPLIER','INQUIRY','ORDER','PROFORMA_INVOICE','PACKING_LIST','DISPATCH'
);

-- Current calendar-year procurement baselines.
update public.procurement_year_counters
set current_value = 0, updated_at = now()
where calendar_year = 2026
  and entity_type in ('PURCHASE_INDENT','PURCHASE_ORDER','MATERIAL_RECEIPT');

-- Legacy counters corresponding only to the removed pre-go-live purchase flow.
update public.purchase_number_counters
set current_value = 0, updated_at = now()
where entity_type in ('PURCHASE_INDENT','PURCHASE_REQUISITION');

update public.purchase_pon_counters
set current_value = 0, updated_at = now()
where calendar_year = 2026;

-- Post-reset target and trigger validation.
do $$
declare
  remaining bigint;
begin
  select sum(n) into remaining from (
    select count(*) n from public.inquiries
    union all select count(*) from public.orders
    union all select count(*) from public.proforma_invoices
    union all select count(*) from public.sales_payment_receipts
    union all select count(*) from public.packing_lists
    union all select count(*) from public.dispatches
    union all select count(*) from public.purchase_indents
    union all select count(*) from public.purchase_requisitions
    union all select count(*) from public.purchase_orders
    union all select count(*) from public.material_receipts
    union all select count(*) from public.monthly_attendance
    union all select count(*) from public.payroll_runs
    union all select count(*) from public.employee_monthly_payroll
    union all select count(*) from public.payroll_crm_incentive_details
    union all select count(*) from public.payroll_audit
  ) target_counts;
  if remaining <> 0 then raise exception 'RESET ABORTED: % reset-target transaction rows remain', remaining; end if;

  if exists (select 1 from public.items i join approved_reset_items a on a.id = i.id)
     or exists (select 1 from public.customer_companies c join approved_reset_customers a on a.id = c.id)
     or exists (select 1 from public.suppliers s join approved_reset_suppliers a on a.id = s.id)
     or exists (select 1 from public.hr_letters h join approved_reset_hr_letters a on a.id = h.id) then
    raise exception 'RESET ABORTED: one or more explicitly approved master/LOI rows remain';
  end if;

  if exists (select 1 from public.inventory_transactions t join approved_reset_items a on a.id = t.item_id)
     or exists (select 1 from public.inventory_balances b join approved_reset_items a on a.id = b.item_id)
     or exists (select 1 from public.material_receipt_inventory_postings) then
    raise exception 'RESET ABORTED: approved test inventory rows remain';
  end if;

  if not exists (
    select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'inventory_transactions'
      and t.tgname = 'inventory_transactions_immutable' and t.tgenabled = 'O'
  ) then raise exception 'RESET ABORTED: inventory immutability trigger was not restored'; end if;

  if not exists (
    select 1 from pg_trigger t join pg_class c on c.oid = t.tgrelid join pg_namespace n on n.oid = c.relnamespace
    where n.nspname = 'public' and c.relname = 'inventory_balances'
      and t.tgname = 'inventory_balances_control' and t.tgenabled = 'O'
  ) then raise exception 'RESET ABORTED: inventory balance-control trigger was not restored'; end if;

  if exists (
    select 1 from public.numbering_counters
    where entity_type in ('CUSTOMER','SUPPLIER','INQUIRY','ORDER','PROFORMA_INVOICE','PACKING_LIST','DISPATCH')
      and current_value <> 0
  ) or (select count(*) from public.numbering_counters where entity_type in ('CUSTOMER','SUPPLIER','INQUIRY','ORDER','PROFORMA_INVOICE','PACKING_LIST','DISPATCH')) <> 7 then
    raise exception 'RESET ABORTED: approved business counters are missing or not zero';
  end if;

  if exists (
    select 1 from public.procurement_year_counters
    where calendar_year = 2026 and entity_type in ('PURCHASE_INDENT','PURCHASE_ORDER','MATERIAL_RECEIPT')
      and current_value <> 0
  ) or (select count(*) from public.procurement_year_counters where calendar_year = 2026 and entity_type in ('PURCHASE_INDENT','PURCHASE_ORDER','MATERIAL_RECEIPT')) <> 3 then
    raise exception 'RESET ABORTED: approved 2026 procurement counters are missing or not zero';
  end if;
end $$;

-- Protected-row and employee-number validation.
do $$
begin
  if (select count(*) from public.employees) <> (select row_count from protected_counts where name = 'employees')
     or (select count(*) from public.employee_salary_structures) <> (select row_count from protected_counts where name = 'employee_salary_structures')
     or (select count(*) from public.erp_profiles) <> (select row_count from protected_counts where name = 'erp_profiles')
     or (select count(*) from public.erp_roles) <> (select row_count from protected_counts where name = 'erp_roles')
     or (select count(*) from public.erp_permission_sections) <> (select row_count from protected_counts where name = 'erp_permission_sections')
     or (select count(*) from public.erp_user_permissions) <> (select row_count from protected_counts where name = 'erp_user_permissions')
     or (select count(*) from public.erp_access_audit) <> (select row_count from protected_counts where name = 'erp_access_audit')
     or (select count(*) from public.departments) <> (select row_count from protected_counts where name = 'departments')
     or (select count(*) from public.designations) <> (select row_count from protected_counts where name = 'designations')
     or (select count(*) from public.teams) <> (select row_count from protected_counts where name = 'teams')
     or (select count(*) from public.employment_types) <> (select row_count from protected_counts where name = 'employment_types')
     or (select count(*) from public.system_settings) <> (select row_count from protected_counts where name = 'system_settings')
     or (select current_value from public.numbering_counters where entity_type = 'EMPLOYEE') <> (select row_count from protected_counts where name = 'employee_number_counter') then
    raise exception 'RESET ABORTED: protected configuration/master counts or employee numbering changed';
  end if;
end $$;

-- Review these result sets in SQL Editor before accepting the COMMIT result.
select 'employees' as protected_data, count(*) as row_count from public.employees
union all select 'employee_salary_structures', count(*) from public.employee_salary_structures
union all select 'erp_profiles', count(*) from public.erp_profiles
union all select 'erp_roles', count(*) from public.erp_roles
union all select 'erp_permission_sections', count(*) from public.erp_permission_sections
union all select 'departments', count(*) from public.departments
union all select 'designations', count(*) from public.designations
union all select 'teams', count(*) from public.teams;

select entity_type, current_value
from public.numbering_counters
where entity_type in ('CUSTOMER','SUPPLIER','INQUIRY','ORDER','PROFORMA_INVOICE','PACKING_LIST','DISPATCH','EMPLOYEE')
order by entity_type;

select entity_type, calendar_year, current_value
from public.procurement_year_counters
where calendar_year = 2026
order by entity_type;

commit;
