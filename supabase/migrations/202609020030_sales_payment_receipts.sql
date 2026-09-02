-- Adhunik ERP — Sales payment receipts and collection-based CRM incentive
begin;

insert into public.erp_permission_sections(module_key,section_key,module_name,section_name,sort_order)
values('sales','sales.payment_receipts','Sales','Payment Receipts',435)
on conflict(section_key)do update set module_name=excluded.module_name,section_name=excluded.section_name,sort_order=excluded.sort_order,is_active=true;

insert into public.erp_user_permissions(profile_id,section_id,can_view,can_edit,created_by,updated_by)
select p.id,s.id,true,true,p.auth_user_id,p.auth_user_id from public.erp_profiles p join public.erp_roles r on r.id=p.role_id cross join public.erp_permission_sections s
where p.is_active and r.code='MANAGER'and s.section_key='sales.payment_receipts' on conflict(profile_id,section_id)do nothing;

create table public.sales_payment_receipts(
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.customer_companies(id)on delete restrict,
 proforma_invoice_id uuid not null references public.proforma_invoices(id)on delete restrict,
 amount_received numeric(18,2)not null check(amount_received>0),payment_received_date date not null,
 payment_reference text,remarks text,status text not null default'VALID'check(status in('VALID','CANCELLED')),
 proof_file_name text not null,proof_storage_path text not null unique,proof_mime_type text not null,proof_file_size bigint not null check(proof_file_size>0 and proof_file_size<=10485760),
 created_by uuid not null references auth.users(id)on delete restrict default auth.uid(),created_at timestamptz not null default now(),
 cancelled_by uuid references auth.users(id)on delete restrict,cancelled_at timestamptz,cancellation_reason text,
 constraint payment_receipt_cancellation check((status='VALID'and cancelled_by is null and cancelled_at is null and cancellation_reason is null)or(status='CANCELLED'and cancelled_by is not null and cancelled_at is not null and nullif(trim(cancellation_reason),'')is not null))
);
create index sales_payment_receipts_pi_date on public.sales_payment_receipts(proforma_invoice_id,payment_received_date desc);
create index sales_payment_receipts_collection_month on public.sales_payment_receipts(payment_received_date,proforma_invoice_id)where status='VALID';
create index sales_payment_receipts_company on public.sales_payment_receipts(company_id,created_at desc);

create or replace function public.can_view_payment_receipt_pi(p_pi_id uuid)returns boolean language sql stable security definer set search_path=''as $$
 select public.has_erp_permission('sales.payment_receipts','VIEW')and public.can_view_proforma_invoice(p_pi_id)
$$;
create or replace function public.can_edit_payment_receipt_pi(p_pi_id uuid)returns boolean language sql stable security definer set search_path=''as $$
 select public.has_erp_permission('sales.payment_receipts','EDIT')and public.can_view_proforma_invoice(p_pi_id)
$$;

create or replace function public.create_sales_payment_receipt(p_id uuid,p_pi_id uuid,p_amount numeric,p_payment_date date,p_reference text,p_remarks text,p_file_name text,p_storage_path text,p_mime_type text,p_file_size bigint)returns uuid language plpgsql security definer set search_path=''as $$
declare x public.proforma_invoices%rowtype;received numeric;
begin
 if not public.can_edit_payment_receipt_pi(p_pi_id)then raise exception'Payment Receipts edit permission required';end if;
 if p_amount is null or p_amount<=0 then raise exception'Amount received must be greater than 0.';end if;
 if p_payment_date is null then raise exception'Payment received date is required.';end if;
 if p_mime_type not in('application/pdf','image/jpeg','image/png','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document')then raise exception'Payment proof must be PDF, JPG, PNG, DOC, or DOCX.';end if;
 if p_file_size is null or p_file_size<=0 or p_file_size>10485760 then raise exception'Payment proof must be no larger than 10 MB.';end if;
 select * into x from public.proforma_invoices where id=p_pi_id and deleted_at is null and status not in('CANCELLED','REVISED')for update;
 if not found then raise exception'PI not found or is not eligible for payment.';end if;
 if p_storage_path<>x.company_id::text||'/'||p_pi_id::text||'/'||p_id::text||'/'||p_file_name then raise exception'Invalid payment proof path.';end if;
 if not exists(select 1 from storage.objects where bucket_id='sales-payment-proofs'and name=p_storage_path)then raise exception'Payment proof upload was not found.';end if;
 select coalesce(sum(amount_received),0)into received from public.sales_payment_receipts where proforma_invoice_id=p_pi_id and status='VALID';
 if round(p_amount,2)>greatest(round(x.grand_total-received,2),0)then raise exception'Amount received cannot exceed the remaining PI amount.';end if;
 insert into public.sales_payment_receipts(id,company_id,proforma_invoice_id,amount_received,payment_received_date,payment_reference,remarks,proof_file_name,proof_storage_path,proof_mime_type,proof_file_size)
 values(p_id,x.company_id,p_pi_id,round(p_amount,2),p_payment_date,nullif(trim(p_reference),''),nullif(trim(p_remarks),''),p_file_name,p_storage_path,p_mime_type,p_file_size);
 return p_id;
end$$;

create or replace function public.cancel_sales_payment_receipt(p_receipt_id uuid,p_reason text)returns void language plpgsql security definer set search_path=''as $$
declare pi_id uuid;
begin
 if nullif(trim(p_reason),'')is null then raise exception'Cancellation reason is required.';end if;
 select proforma_invoice_id into pi_id from public.sales_payment_receipts where id=p_receipt_id and status='VALID'for update;
 if not found or not public.can_edit_payment_receipt_pi(pi_id)then raise exception'Receipt not found or cannot be cancelled.';end if;
 update public.sales_payment_receipts set status='CANCELLED',cancelled_by=auth.uid(),cancelled_at=now(),cancellation_reason=trim(p_reason)where id=p_receipt_id;
end$$;

alter table public.sales_payment_receipts enable row level security;
create policy sales_payment_receipts_read on public.sales_payment_receipts for select to authenticated using(public.can_view_payment_receipt_pi(proforma_invoice_id));
grant select on public.sales_payment_receipts to authenticated;
revoke all on function public.create_sales_payment_receipt(uuid,uuid,numeric,date,text,text,text,text,text,bigint),public.cancel_sales_payment_receipt(uuid,text)from public,anon;
grant execute on function public.can_view_payment_receipt_pi(uuid),public.can_edit_payment_receipt_pi(uuid),public.create_sales_payment_receipt(uuid,uuid,numeric,date,text,text,text,text,text,bigint),public.cancel_sales_payment_receipt(uuid,text)to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)values('sales-payment-proofs','sales-payment-proofs',false,10485760,array['application/pdf','image/jpeg','image/png','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document'])
on conflict(id)do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create policy "Payment proof objects read"on storage.objects for select to authenticated using(bucket_id='sales-payment-proofs'and public.can_view_payment_receipt_pi((storage.foldername(name))[2]::uuid));
create policy "Payment proof objects insert"on storage.objects for insert to authenticated with check(bucket_id='sales-payment-proofs'and public.can_edit_payment_receipt_pi((storage.foldername(name))[2]::uuid)and(storage.foldername(name))[1]=(select company_id::text from public.proforma_invoices where id=(storage.foldername(name))[2]::uuid));

alter table public.payroll_crm_incentive_details drop constraint if exists payroll_crm_incentive_details_payroll_id_proforma_invoice_id_key;
alter table public.payroll_crm_incentive_details add column payment_receipt_id uuid references public.sales_payment_receipts(id)on delete restrict,add column payment_date date,add column amount_received numeric(15,2),add column proof_storage_path text,add column receipt_status text;
create unique index payroll_crm_receipt_unique on public.payroll_crm_incentive_details(payroll_id,payment_receipt_id)where payment_receipt_id is not null;

create or replace function public.payment_receipt_eligible_amount(p_receipt_id uuid)returns numeric language sql stable security definer set search_path=''as $$
 with target as(select r.*,pi.subtotal,pi.grand_total from public.sales_payment_receipts r join public.proforma_invoices pi on pi.id=r.proforma_invoice_id where r.id=p_receipt_id),prior as(select coalesce(sum(round(r.amount_received*t.subtotal/nullif(t.grand_total,0),2)),0)eligible,coalesce(sum(r.amount_received),0)received from target t join public.sales_payment_receipts r on r.proforma_invoice_id=t.proforma_invoice_id and r.status='VALID'and(r.payment_received_date,r.created_at,r.id)<(t.payment_received_date,t.created_at,t.id))select case when t.status<>'VALID'or t.grand_total<=0 then 0 when p.received+t.amount_received>=t.grand_total then greatest(round(t.subtotal-p.eligible,2),0)else round(t.amount_received*t.subtotal/t.grand_total,2)end from target t cross join prior p
$$;

create or replace function public.refresh_payroll_collection_details(p_payroll_id uuid,p_employee_id uuid,p_month smallint,p_year smallint)returns numeric language plpgsql security definer set search_path=''as $$
declare total numeric;
begin
 delete from public.payroll_crm_incentive_details where payroll_id=p_payroll_id;
 insert into public.payroll_crm_incentive_details(payroll_id,proforma_invoice_id,payment_receipt_id,pi_number,pi_date,payment_date,customer,amount_received,eligible_amount,proof_storage_path,receipt_status)
 select p_payroll_id,pi.id,r.id,pi.pi_number,pi.pi_date,r.payment_received_date,pi.customer_name_snapshot,r.amount_received,
 public.payment_receipt_eligible_amount(r.id),r.proof_storage_path,r.status
 from public.sales_payment_receipts r join public.proforma_invoices pi on pi.id=r.proforma_invoice_id join public.erp_profiles ep on ep.auth_user_id=pi.salesperson_id
 where ep.employee_id=p_employee_id and r.status='VALID'and extract(month from r.payment_received_date)=p_month and extract(year from r.payment_received_date)=p_year;
 select coalesce(sum(eligible_amount),0)into total from public.payroll_crm_incentive_details where payroll_id=p_payroll_id;
 return total;
end$$;

-- Replace the Phase 10 preparation function: salary and attendance behavior is unchanged; CRM now comes from valid receipt dates.
create or replace function public.prepare_payroll(p_month smallint,p_year smallint)returns uuid language plpgsql security definer set search_path=''as $$
declare r uuid;e record;s record;a record;p uuid;ratio numeric;eligible numeric;
begin
 if not public.has_erp_permission('hr-payroll.monthly_payroll','EDIT')then raise exception'Monthly Payroll edit permission required';end if;
 insert into public.payroll_runs(month,year)values(p_month,p_year)on conflict(month,year)do update set updated_at=now()where public.payroll_runs.status='DRAFT'returning id into r;if r is null then raise exception'Payroll is already finalized';end if;
 for e in select x.*,d.name department,g.name designation from public.employees x left join public.departments d on d.id=x.department_id left join public.designations g on g.id=x.designation_id where x.is_active and x.deleted_at is null loop
  select * into s from public.employee_salary_structures where employee_id=e.id and effective_from<=make_date(p_year,p_month,1)order by effective_from desc limit 1;select * into a from public.monthly_attendance where employee_id=e.id and month=p_month and year=p_year;ratio:=case when a.total_payable_days>0 then a.paid_days/a.total_payable_days else 0 end;
  insert into public.employee_monthly_payroll(payroll_run_id,employee_id,salary_structure_id,attendance_id,eligibility_error,employee_code,employee_name,department,designation,basic,hra,allowance,other_earnings,fixed_gross,working_days,present_days,weekly_offs,absent_days,total_payable_days,paid_days,payable_basic,payable_hra,payable_allowance,payable_other_earnings,attendance_salary,crm_eligible_amount,net_payable)
  values(r,e.id,s.id,a.id,case when s.id is null then'Missing Salary Structure'when a.id is null then'Missing Attendance'when a.total_payable_days<=0 then'Invalid Total Payable Days'end,e.employee_code,e.full_name,e.department,e.designation,coalesce(s.basic,0),coalesce(s.hra,0),coalesce(s.allowance,0),coalesce(s.other_earnings,0),coalesce(s.fixed_gross,0),coalesce(a.working_days,0),coalesce(a.present_days,0),coalesce(a.weekly_offs,0),coalesce(a.absent_days,0),coalesce(a.total_payable_days,0),coalesce(a.paid_days,0),round(coalesce(s.basic,0)*ratio,2),round(coalesce(s.hra,0)*ratio,2),round(coalesce(s.allowance,0)*ratio,2),round(coalesce(s.other_earnings,0)*ratio,2),round(coalesce(s.fixed_gross,0)*ratio,2),0,round(coalesce(s.fixed_gross,0)*ratio,2))
  on conflict(payroll_run_id,employee_id)do update set salary_structure_id=excluded.salary_structure_id,attendance_id=excluded.attendance_id,eligibility_error=excluded.eligibility_error,employee_code=excluded.employee_code,employee_name=excluded.employee_name,department=excluded.department,designation=excluded.designation,basic=excluded.basic,hra=excluded.hra,allowance=excluded.allowance,other_earnings=excluded.other_earnings,fixed_gross=excluded.fixed_gross,working_days=excluded.working_days,present_days=excluded.present_days,weekly_offs=excluded.weekly_offs,absent_days=excluded.absent_days,total_payable_days=excluded.total_payable_days,paid_days=excluded.paid_days,payable_basic=excluded.payable_basic,payable_hra=excluded.payable_hra,payable_allowance=excluded.payable_allowance,payable_other_earnings=excluded.payable_other_earnings,attendance_salary=excluded.attendance_salary,updated_at=now()returning id into p;
  eligible:=public.refresh_payroll_collection_details(p,e.id,p_month,p_year);
  update public.employee_monthly_payroll set crm_eligible_amount=eligible,crm_incentive_amount=round(eligible*crm_incentive_percentage/100,2),net_payable=round(attendance_salary+eligible*crm_incentive_percentage/100+overtime_amount+adjustment_amount,2),updated_at=now()where id=p;
 end loop;
 insert into public.payroll_audit(payroll_run_id,event_type)values(r,'PAYROLL_PREPARED');return r;
end$$;
revoke all on function public.refresh_payroll_collection_details(uuid,uuid,smallint,smallint)from public,anon,authenticated;

commit;
