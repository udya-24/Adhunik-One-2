-- Adhunik ERP - Phase 5B PI documents, issuance and revisions
begin;
alter table public.proforma_invoices add column if not exists revision_number integer not null default 0;
alter table public.proforma_invoices add column if not exists root_pi_id uuid references public.proforma_invoices(id) on delete restrict;
alter table public.proforma_invoices add column if not exists revised_from_id uuid references public.proforma_invoices(id) on delete restrict;
alter table public.proforma_invoices add column if not exists revision_reason text;
alter table public.proforma_invoices add column if not exists document_configuration_snapshot jsonb;
alter table public.proforma_invoices add column if not exists issued_at timestamptz;
alter table public.proforma_invoices add column if not exists issued_by uuid references auth.users(id) on delete restrict;
alter table public.proforma_invoices add column if not exists accepted_at timestamptz;
alter table public.proforma_invoices add column if not exists accepted_by uuid references auth.users(id) on delete restrict;
update public.proforma_invoices set root_pi_id=id where root_pi_id is null;
alter table public.proforma_invoices alter column root_pi_id set not null;
alter table public.proforma_invoices drop constraint if exists proforma_invoices_pi_number_key;
alter table public.proforma_invoices drop constraint if exists proforma_invoices_status_check;
alter table public.proforma_invoices add constraint proforma_invoices_status_check check(status in('DRAFT','ISSUED','REVISED','ACCEPTED','CANCELLED'));
alter table public.proforma_invoices drop constraint if exists pi_revision_reason_required;
alter table public.proforma_invoices add constraint pi_revision_reason_required check(revision_number=0 or nullif(trim(revision_reason),'')is not null);
create unique index if not exists proforma_invoices_number_revision on public.proforma_invoices(pi_number,revision_number);
create index if not exists proforma_invoices_root_revision on public.proforma_invoices(root_pi_id,revision_number desc);
create unique index if not exists proforma_invoices_current_version on public.proforma_invoices(root_pi_id) where status in('DRAFT','ISSUED','ACCEPTED')and deleted_at is null;

create table if not exists public.pi_document_settings(
 id boolean primary key default true check(id),header_image_path text,footer_image_path text,company_display_name text not null default 'ADHUNIK',registered_office_address text,gstin text,pan text,phone text,email text,website text,
 bank_name text,bank_branch text,account_name text,account_number text,account_type text,ifsc text,micr text,declaration_text text,authorized_signatory_employee_id uuid references public.employees(id) on delete set null,signature_image_path text,
 created_at timestamptz not null default now(),created_by uuid references auth.users(id) on delete set null,updated_at timestamptz not null default now(),updated_by uuid references auth.users(id) on delete set null
);
insert into public.pi_document_settings(id)values(true)on conflict(id)do nothing;
create table if not exists public.proforma_invoice_documents(
 id uuid primary key default gen_random_uuid(),proforma_invoice_id uuid not null references public.proforma_invoices(id) on delete restrict,revision_number integer not null,document_type text not null check(document_type in('PDF','DOCX')),file_name text not null,file_path text not null unique,mime_type text not null,file_size bigint not null check(file_size>0),generated_by uuid not null references auth.users(id) on delete restrict,generated_at timestamptz not null default now(),is_current boolean not null default true,
 unique(proforma_invoice_id,document_type,is_current)
);
create index if not exists pi_documents_parent on public.proforma_invoice_documents(proforma_invoice_id,generated_at desc);

alter table public.proforma_invoice_activities drop constraint if exists proforma_invoice_activities_activity_type_check;
alter table public.proforma_invoice_activities add constraint proforma_invoice_activities_activity_type_check check(activity_type in('CREATED','EDITED','ITEM_ADDED','ITEM_REMOVED','STATUS_CHANGED','CANCELLED','PREVIEWED','ISSUED','PDF_GENERATED','WORD_GENERATED','REVISION_CREATED','REVISION_ISSUED','ACCEPTED'));

create or replace function public.assign_pi_root()returns trigger language plpgsql security definer set search_path='' as $$begin if new.root_pi_id is null then new.root_pi_id:=new.id;end if;return new;end;$$;
drop trigger if exists assign_pi_root on public.proforma_invoices;create trigger assign_pi_root before insert on public.proforma_invoices for each row execute function public.assign_pi_root();
create or replace function public.prepare_pi_update()returns trigger language plpgsql security definer set search_path='' as $$
begin
 new.pi_number:=old.pi_number;new.order_id:=old.order_id;new.company_id:=old.company_id;new.root_pi_id:=old.root_pi_id;new.revision_number:=old.revision_number;new.revised_from_id:=old.revised_from_id;new.revision_reason:=old.revision_reason;new.created_by:=old.created_by;new.created_at:=old.created_at;
 if old.status<>'DRAFT'then
  new.contact_id:=old.contact_id;new.pi_date:=old.pi_date;new.our_reference_number:=old.our_reference_number;new.dp_code:=old.dp_code;new.project_name:=old.project_name;new.customer_po_number:=old.customer_po_number;new.customer_po_date:=old.customer_po_date;new.billing_address_id:=old.billing_address_id;new.shipping_address_id:=old.shipping_address_id;new.billing_address_snapshot:=old.billing_address_snapshot;new.shipping_address_snapshot:=old.shipping_address_snapshot;new.customer_name_snapshot:=old.customer_name_snapshot;new.customer_gstin_snapshot:=old.customer_gstin_snapshot;new.customer_phone_snapshot:=old.customer_phone_snapshot;new.customer_email_snapshot:=old.customer_email_snapshot;new.payment_term_id:=old.payment_term_id;new.payment_terms_snapshot:=old.payment_terms_snapshot;new.delivery_terms:=old.delivery_terms;new.validity_text:=old.validity_text;new.freight_amount:=old.freight_amount;new.freight_remark:=old.freight_remark;new.gst_percentage:=old.gst_percentage;new.subtotal:=old.subtotal;new.discount_total:=old.discount_total;new.taxable_total:=old.taxable_total;new.gst_amount:=old.gst_amount;new.grand_total:=old.grand_total;new.currency:=old.currency;new.salesperson_id:=old.salesperson_id;new.document_configuration_snapshot:=old.document_configuration_snapshot;
 end if;return new;
end;$$;
drop trigger if exists protect_proforma_invoice on public.proforma_invoices;drop trigger if exists prepare_pi_update on public.proforma_invoices;create trigger prepare_pi_update before update on public.proforma_invoices for each row execute function public.prepare_pi_update();

create or replace function public.issue_proforma_invoice(p_pi_id uuid)returns void language plpgsql security definer set search_path='' as $$
declare p public.proforma_invoices%rowtype;cfg public.pi_document_settings%rowtype;sig jsonb;item_count int;
begin
 select * into p from public.proforma_invoices where id=p_pi_id and status='DRAFT' and public.can_manage_proforma_invoice(id) for update;if not found then raise exception 'Draft PI not found or already finalized';end if;
 select count(*) into item_count from public.proforma_invoice_items where proforma_invoice_id=p.id;if item_count=0 or p.pi_number is null or p.customer_name_snapshot is null or p.billing_address_snapshot is null or p.shipping_address_snapshot is null or p.grand_total<0 or p.gst_percentage not between 0 and 100 or p.freight_amount<0 then raise exception 'PI is incomplete and cannot be issued';end if;
 select * into cfg from public.pi_document_settings where id=true;
 select jsonb_build_object('employee_id',e.id,'name',e.full_name,'designation',d.name,'email',e.official_email,'phone',e.phone,'signature_image_path',cfg.signature_image_path)into sig from public.employees e left join public.designations d on d.id=e.designation_id where e.id=cfg.authorized_signatory_employee_id;
 update public.proforma_invoices set status='ISSUED',issued_at=now(),issued_by=auth.uid(),updated_at=now(),updated_by=auth.uid(),document_configuration_snapshot=case when p.revision_number>0 and p.document_configuration_snapshot is not null then p.document_configuration_snapshot else jsonb_build_object('header_image_path',cfg.header_image_path,'footer_image_path',cfg.footer_image_path,'company_display_name',cfg.company_display_name,'registered_office_address',cfg.registered_office_address,'gstin',cfg.gstin,'pan',cfg.pan,'phone',cfg.phone,'email',cfg.email,'website',cfg.website,'bank_name',cfg.bank_name,'bank_branch',cfg.bank_branch,'account_name',cfg.account_name,'account_number',cfg.account_number,'account_type',cfg.account_type,'ifsc',cfg.ifsc,'micr',cfg.micr,'declaration_text',cfg.declaration_text,'signatory',sig)end where id=p.id;
 insert into public.proforma_invoice_activities(proforma_invoice_id,activity_type,description,created_by)values(p.id,case when p.revision_number=0 then 'ISSUED' else 'REVISION_ISSUED'end,case when p.revision_number=0 then 'PI issued' else 'Revision '||p.revision_number||' issued'end,auth.uid());
end;$$;

create or replace function public.create_proforma_invoice_revision(p_pi_id uuid,p_reason text)returns uuid language plpgsql security definer set search_path='' as $$
declare p public.proforma_invoices%rowtype;v_root uuid;v_revision int;v_id uuid;
begin
 if nullif(trim(p_reason),'')is null then raise exception 'Revision reason is required';end if;select * into p from public.proforma_invoices where id=p_pi_id and status in('ISSUED','ACCEPTED')and public.can_view_proforma_invoice(id) for update;if not found then raise exception 'Issued PI not found or not accessible';end if;if not(public.can_manage_crm()or p.created_by=auth.uid()or p.salesperson_id=auth.uid())then raise exception 'You cannot revise this PI';end if;
 v_root:=p.root_pi_id;perform pg_advisory_xact_lock(hashtextextended(v_root::text,0));select coalesce(max(revision_number),0)+1 into v_revision from public.proforma_invoices where root_pi_id=v_root;
 update public.proforma_invoices set status='REVISED',updated_by=auth.uid(),updated_at=now()where root_pi_id=v_root and status in('ISSUED','ACCEPTED');
 insert into public.proforma_invoices(pi_number,order_id,company_id,contact_id,pi_date,our_reference_number,dp_code,project_name,customer_po_number,customer_po_date,billing_address_id,shipping_address_id,billing_address_snapshot,shipping_address_snapshot,customer_name_snapshot,customer_gstin_snapshot,customer_phone_snapshot,customer_email_snapshot,payment_term_id,payment_terms_snapshot,delivery_terms,validity_text,freight_amount,freight_remark,gst_percentage,subtotal,discount_total,taxable_total,gst_amount,grand_total,currency,status,salesperson_id,created_by,updated_by,root_pi_id,revised_from_id,revision_number,revision_reason,document_configuration_snapshot)
 select pi_number,order_id,company_id,contact_id,current_date,our_reference_number,dp_code,project_name,customer_po_number,customer_po_date,billing_address_id,shipping_address_id,billing_address_snapshot,shipping_address_snapshot,customer_name_snapshot,customer_gstin_snapshot,customer_phone_snapshot,customer_email_snapshot,payment_term_id,payment_terms_snapshot,delivery_terms,validity_text,freight_amount,freight_remark,gst_percentage,subtotal,discount_total,taxable_total,gst_amount,grand_total,currency,'DRAFT',salesperson_id,auth.uid(),auth.uid(),v_root,p.id,v_revision,trim(p_reason),document_configuration_snapshot from public.proforma_invoices where id=p.id returning id into v_id;
 insert into public.proforma_invoice_items(proforma_invoice_id,line_number,inventory_item_id,item_name,item_description,model_type,hsn_code,unit,quantity,unit_price,discount_percentage,gross_amount,discount_amount,line_total,sort_order)select v_id,line_number,inventory_item_id,item_name,item_description,model_type,hsn_code,unit,quantity,unit_price,discount_percentage,gross_amount,discount_amount,line_total,sort_order from public.proforma_invoice_items where proforma_invoice_id=p.id;
 insert into public.proforma_invoice_activities(proforma_invoice_id,activity_type,description,created_by)values(v_id,'REVISION_CREATED','Revision '||v_revision||' created: '||trim(p_reason),auth.uid());return v_id;
end;$$;
create or replace function public.accept_proforma_invoice(p_pi_id uuid)returns void language plpgsql security definer set search_path='' as $$begin update public.proforma_invoices set status='ACCEPTED',accepted_at=now(),accepted_by=auth.uid(),updated_at=now(),updated_by=auth.uid()where id=p_pi_id and status='ISSUED'and(public.can_manage_crm()or created_by=auth.uid()or salesperson_id=auth.uid());if not found then raise exception 'Issued PI not found or not acceptable';end if;insert into public.proforma_invoice_activities(proforma_invoice_id,activity_type,description,created_by)values(p_pi_id,'ACCEPTED','PI marked Accepted',auth.uid());end;$$;

create or replace function public.cancel_proforma_invoice(p_pi_id uuid,p_reason text)returns void language plpgsql security definer set search_path='' as $$
begin if nullif(trim(p_reason),'')is null then raise exception 'Cancellation reason is required';end if;update public.proforma_invoices set status='CANCELLED',cancellation_reason=trim(p_reason),cancelled_at=now(),cancelled_by=auth.uid(),updated_by=auth.uid(),updated_at=now()where id=p_pi_id and status not in('CANCELLED','REVISED')and(public.can_manage_crm()or created_by=auth.uid()or salesperson_id=auth.uid());if not found then raise exception 'PI not found, inaccessible or already finalized';end if;insert into public.proforma_invoice_activities(proforma_invoice_id,activity_type,description,created_by)values(p_pi_id,'CANCELLED','PI cancelled: '||trim(p_reason),auth.uid());end;$$;
alter table public.pi_document_settings enable row level security;alter table public.proforma_invoice_documents enable row level security;
drop policy if exists "ERP read PI document settings" on public.pi_document_settings;drop policy if exists "Admin manage PI document settings" on public.pi_document_settings;drop policy if exists "Sales visible PI documents" on public.proforma_invoice_documents;
create policy "ERP read PI document settings" on public.pi_document_settings for select to authenticated using(public.has_active_erp_access());create policy "Admin manage PI document settings" on public.pi_document_settings for all to authenticated using(public.is_erp_admin())with check(public.is_erp_admin());create policy "Sales visible PI documents" on public.proforma_invoice_documents for select to authenticated using(public.can_view_proforma_invoice(proforma_invoice_id));
grant select on public.pi_document_settings,public.proforma_invoice_documents to authenticated;grant insert,update on public.pi_document_settings to authenticated;revoke all on function public.issue_proforma_invoice(uuid),public.create_proforma_invoice_revision(uuid,text),public.accept_proforma_invoice(uuid)from public,anon;grant execute on function public.issue_proforma_invoice(uuid),public.create_proforma_invoice_revision(uuid,text),public.accept_proforma_invoice(uuid)to authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)values('pi-branding','pi-branding',false,5242880,array['image/jpeg','image/png','image/webp']),('pi-documents','pi-documents',false,15728640,array['application/pdf','application/vnd.openxmlformats-officedocument.wordprocessingml.document'])on conflict(id)do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists "ERP read PI branding" on storage.objects;drop policy if exists "Admin insert PI branding" on storage.objects;drop policy if exists "Admin update PI branding" on storage.objects;drop policy if exists "Admin delete PI branding" on storage.objects;drop policy if exists "Sales read PI documents" on storage.objects;
create policy "ERP read PI branding" on storage.objects for select to authenticated using(bucket_id='pi-branding'and public.has_active_erp_access());create policy "Admin insert PI branding" on storage.objects for insert to authenticated with check(bucket_id='pi-branding'and public.is_erp_admin());create policy "Admin update PI branding" on storage.objects for update to authenticated using(bucket_id='pi-branding'and public.is_erp_admin())with check(bucket_id='pi-branding'and public.is_erp_admin());create policy "Admin delete PI branding" on storage.objects for delete to authenticated using(bucket_id='pi-branding'and public.is_erp_admin());create policy "Sales read PI documents" on storage.objects for select to authenticated using(bucket_id='pi-documents'and public.can_view_proforma_invoice((storage.foldername(name))[1]::uuid));
commit;



