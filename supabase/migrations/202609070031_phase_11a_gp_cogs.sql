-- Phase 11A: manual GP invoices, current item costing and private documents.
-- company_id follows CRM/Sales: the customer company, not a tenant identifier.
begin;
insert into public.erp_permission_sections(module_key,section_key,module_name,section_name,sort_order) values
('finance','finance.overview','Finance','Overview',900),
('finance','finance.gp_data','Finance','GP Data',910),
('finance','finance.cogs_analytics','Finance','COGS Analytics',920);

alter table public.items add column cogs_unit_cost numeric(15,4) check(cogs_unit_cost >= 0 and cogs_unit_cost < 'Infinity'::numeric);
-- Existing item role rules remain; the new costing field additionally requires Phase 9 Edit.
create function public.guard_item_cogs() returns trigger language plpgsql set search_path='' as $$
begin
 if (tg_op='INSERT' and new.cogs_unit_cost is not null) or (tg_op='UPDATE' and new.cogs_unit_cost is distinct from old.cogs_unit_cost) then
  if auth.uid() is not null and not public.has_erp_permission('inventory.items','EDIT') then raise exception 'Item Master Edit permission required to change COGS'; end if;
 end if;
 return new;
end $$;
create trigger guard_item_cogs before insert or update on public.items for each row execute function public.guard_item_cogs();

-- Configuration uses separate, consistently shaped master tables, not a generic value store.
create table public.gp_types (
 id uuid primary key default gen_random_uuid(),code text not null check(length(trim(code)) between 1 and 80),
 name text not null check(length(trim(name)) between 1 and 120),description text,sort_order integer not null default 0,is_active boolean not null default true,
 created_at timestamptz not null default now(),created_by uuid references auth.users(id) default auth.uid(),
 updated_at timestamptz not null default now(),updated_by uuid references auth.users(id) default auth.uid()
);
create unique index gp_types_code_unique on public.gp_types(upper(trim(code)));
create unique index gp_types_name_unique on public.gp_types(lower(trim(name)));
create trigger gp_types_updated before update on public.gp_types for each row execute function public.set_updated_at();
insert into public.gp_types(code,name,sort_order)values('PROJECT','PROJECT',10),('TRADE','TRADE',20),('TRADE/PROJECT','TRADE/PROJECT',30);
insert into public.system_settings(category,key,value,description)values('GENERAL','LOW_GP_WARNING_THRESHOLD','15','Low GP Warning Threshold % (0–100)');
alter table public.system_settings add constraint valid_low_gp_threshold check(key<>'LOW_GP_WARNING_THRESHOLD' or (value ~ '^[0-9]+([.][0-9]{1,2})?$' and value::numeric between 0 and 100));

create table public.gp_invoices (
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.customer_companies(id) on delete restrict,
 customer_company_id uuid not null references public.customer_companies(id) on delete restrict,
 financial_year_id uuid not null references public.financial_years(id) on delete restrict,
 invoice_no text not null check(length(trim(invoice_no)) between 1 and 100),invoice_date date not null,
 buyer_name_snapshot text not null,state_snapshot text not null default '',
 sales_person_employee_id uuid not null references public.employees(id) on delete restrict,sales_person_name_snapshot text not null,
 gp_type_id uuid not null references public.gp_types(id) on delete restrict,gp_type_snapshot text not null,
 freight numeric(15,2) not null default 0 check(freight>=0 and freight<'Infinity'::numeric),
 status text not null default 'DRAFT' check(status in('DRAFT','CONFIRMED','CANCELLED')),
 version integer not null default 1,created_by uuid not null references auth.users(id) default auth.uid(),created_at timestamptz not null default now(),
 updated_by uuid not null references auth.users(id) default auth.uid(),updated_at timestamptz not null default now(),
 cancelled_by uuid references auth.users(id),cancelled_at timestamptz,cancellation_reason text,
 check(company_id=customer_company_id),
 check((status='CANCELLED' and cancelled_by is not null and cancelled_at is not null and nullif(trim(cancellation_reason),'') is not null) or
 (status<>'CANCELLED' and cancelled_by is null and cancelled_at is null and cancellation_reason is null))
);
create unique index gp_invoices_number_unique on public.gp_invoices(company_id,financial_year_id,upper(trim(invoice_no)));
create index gp_invoices_date on public.gp_invoices(invoice_date desc,id);
create table public.gp_invoice_items (
 id uuid primary key default gen_random_uuid(),gp_invoice_id uuid not null references public.gp_invoices(id) on delete restrict,
 line_number integer not null,item_id uuid not null references public.items(id) on delete restrict,
 item_code_snapshot text not null,item_name_snapshot text not null,
 category_id_snapshot uuid references public.item_categories(id) on delete restrict,category_name_snapshot text,
 rate numeric(15,4) not null check(rate>=0 and rate<'Infinity'::numeric),quantity numeric(15,4) not null check(quantity>0 and quantity<'Infinity'::numeric),
 cogs_unit_snapshot numeric(15,4) check(cogs_unit_snapshot>=0 and cogs_unit_snapshot<'Infinity'::numeric),
 sales_value numeric(25,2) generated always as(round(rate*quantity,2)) stored,
 total_cogs numeric(25,2) generated always as(round(cogs_unit_snapshot*quantity,2)) stored,
 gp_value numeric(25,2) generated always as(round(rate*quantity,2)-round(cogs_unit_snapshot*quantity,2)) stored,
 gp_percentage numeric generated always as(round((round(rate*quantity,2)-round(cogs_unit_snapshot*quantity,2))/nullif(round(rate*quantity,2),0)*100,2)) stored,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(gp_invoice_id,line_number)
);
create index gp_invoice_items_item on public.gp_invoice_items(item_id,gp_invoice_id);
create table public.gp_invoice_documents (
 id uuid primary key default gen_random_uuid(),gp_invoice_id uuid not null references public.gp_invoices(id) on delete restrict,
 document_type text not null check(document_type in('BILL','LR')),file_name text not null,storage_path text not null unique,
 mime_type text not null check(mime_type in('application/pdf','image/jpeg','image/png')),
 file_size bigint not null check(file_size between 1 and 10485760),uploaded_by uuid not null references auth.users(id) default auth.uid(),uploaded_at timestamptz not null default now()
);
create index gp_invoice_documents_parent on public.gp_invoice_documents(gp_invoice_id);
create table public.gp_invoice_activities (
 id uuid primary key default gen_random_uuid(),gp_invoice_id uuid not null references public.gp_invoices(id) on delete restrict,
 activity_type text not null,description text not null,created_by uuid not null references auth.users(id) default auth.uid(),created_at timestamptz not null default now()
);
create index gp_invoice_activities_parent on public.gp_invoice_activities(gp_invoice_id,created_at desc);

-- Minimal lookup projections avoid granting Finance access to employee bank/personal details.
create function public.search_gp_master(p_kind text,p_query text default '') returns jsonb language plpgsql stable security definer set search_path='' as $$
declare result jsonb;term text:='%'||left(trim(p_query),100)||'%';
begin
 if not public.has_erp_permission('finance.gp_data','VIEW') and not public.has_erp_permission('finance.cogs_analytics','VIEW') then raise exception 'Finance View permission required';end if;
 if p_kind='items' then
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into result from(select i.id,i.item_code,i.item_name,i.description,i.model_part_number,i.cogs_unit_cost,c.name category_name,i.category_id,b.name brand from public.items i left join public.item_categories c on c.id=i.category_id left join public.item_brands b on b.id=i.brand_id where i.is_active and (i.item_code ilike term or i.item_name ilike term or i.description ilike term or i.model_part_number ilike term or b.name ilike term) order by i.item_name,i.id limit 50)x;
 elsif p_kind='buyers' then
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into result from(select c.id,c.legal_name,c.company_code,c.trade_name,c.gstin,c.primary_phone,(select a.state from public.customer_addresses a where a.customer_company_id=c.id and a.is_active and a.deleted_at is null order by a.is_primary desc,(a.address_type='BILLING') desc,a.created_at desc,a.id limit 1)state from public.customer_companies c where c.is_active and c.deleted_at is null and (c.legal_name ilike term or c.company_code ilike term or c.trade_name ilike term or c.gstin ilike term or c.primary_phone ilike term)order by c.legal_name,c.id limit 50)x;
 elsif p_kind='employees' then
 select coalesce(jsonb_agg(to_jsonb(x)),'[]') into result from(select id,full_name,employee_code from public.employees where is_active and deleted_at is null and(full_name ilike term or employee_code ilike term)order by full_name,id limit 50)x;
 else raise exception 'Unknown lookup';end if;
 return result;
end $$;

create function public.save_gp_invoice(p_id uuid,p_version integer,p_header jsonb,p_items jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare h public.gp_invoices%rowtype;old_line public.gp_invoice_items%rowtype;m public.items%rowtype;
 buyer public.customer_companies%rowtype;emp public.employees%rowtype;typ public.gp_types%rowtype;
 fy uuid;fy_count integer;d date;row_data jsonb;line_id uuid;keep_ids uuid[]:='{}';n integer:=0;cost numeric;code text;name text;cat uuid;cat_name text;target_status text;
begin
 if not public.has_erp_permission('finance.gp_data','EDIT') then raise exception 'GP Data Edit permission required';end if;
 if p_id is not null then
  select * into h from public.gp_invoices where id=p_id for update;
  if not found then raise exception 'GP invoice not found';end if;
  if h.status<>'DRAFT' then raise exception 'Only drafts can be edited. Reopen a confirmed invoice first.';end if;
  if p_version is distinct from h.version then raise exception 'This invoice changed. Reload before saving.';end if;
 end if;
 if jsonb_typeof(p_items) is distinct from 'array' or jsonb_array_length(p_items) not between 1 and 200 then raise exception 'Add between 1 and 200 Item Master rows';end if;
 d:=(p_header->>'invoice_date')::date;
 if d is null or nullif(trim(p_header->>'invoice_no'),'') is null then raise exception 'Invoice number and date are required';end if;
 select count(*),(array_agg(id))[1] into fy_count,fy from public.financial_years where d between start_date and end_date and deleted_at is null;
 if fy_count<>1 then raise exception 'Configure one Financial Year covering this invoice date';end if;
 select * into buyer from public.customer_companies where id=(p_header->>'customer_company_id')::uuid and ((is_active and deleted_at is null) or id=h.customer_company_id);
 if not found then raise exception 'Select an active buyer from Company Master';end if;
 select * into emp from public.employees where id=(p_header->>'sales_person_employee_id')::uuid and ((is_active and deleted_at is null) or id=h.sales_person_employee_id);
 if not found then raise exception 'Select an active employee';end if;
 select * into typ from public.gp_types where id=(p_header->>'gp_type_id')::uuid and (is_active or id=h.gp_type_id);
 if not found then raise exception 'Select an active GP Type';end if;
 target_status:=coalesce(p_header->>'status','DRAFT');
 if target_status not in('DRAFT','CONFIRMED') then raise exception 'Invalid status';end if;
 if p_id is null then
  insert into public.gp_invoices(company_id,customer_company_id,financial_year_id,invoice_no,invoice_date,buyer_name_snapshot,state_snapshot,sales_person_employee_id,sales_person_name_snapshot,gp_type_id,gp_type_snapshot,freight)
  values(buyer.id,buyer.id,fy,trim(p_header->>'invoice_no'),d,buyer.legal_name,coalesce(p_header->>'state_snapshot',''),emp.id,emp.full_name,typ.id,typ.name,coalesce(nullif(p_header->>'freight','')::numeric,0))returning id into p_id;
 else
  update public.gp_invoices set company_id=buyer.id,customer_company_id=buyer.id,financial_year_id=fy,invoice_no=trim(p_header->>'invoice_no'),invoice_date=d,
   buyer_name_snapshot=case when buyer.id=h.customer_company_id then h.buyer_name_snapshot else buyer.legal_name end,state_snapshot=coalesce(p_header->>'state_snapshot',''),
   sales_person_employee_id=emp.id,sales_person_name_snapshot=case when emp.id=h.sales_person_employee_id then h.sales_person_name_snapshot else emp.full_name end,
   gp_type_id=typ.id,gp_type_snapshot=case when typ.id=h.gp_type_id then h.gp_type_snapshot else typ.name end,
   freight=coalesce(nullif(p_header->>'freight','')::numeric,0),updated_by=auth.uid(),updated_at=now(),version=version+1 where id=p_id;
 end if;
 -- Move existing positions out of the way before reordering; UUIDs and creation dates remain stable.
 update public.gp_invoice_items set line_number=-line_number where gp_invoice_id=p_id;
 for row_data in select value from jsonb_array_elements(p_items) loop
  n:=n+1;old_line:=null;line_id:=nullif(row_data->>'id','')::uuid;
  if line_id is not null then
   select * into old_line from public.gp_invoice_items where id=line_id and gp_invoice_id=p_id;
   if not found or line_id=any(keep_ids) then raise exception 'Invalid or duplicate GP line';end if;
  end if;
  select * into m from public.items where id=(row_data->>'item_id')::uuid;
  if not found or (not m.is_active and m.id is distinct from old_line.item_id) then raise exception 'Select an active Item Master record';end if;
  if m.id=old_line.item_id then
   cost:=old_line.cogs_unit_snapshot;code:=old_line.item_code_snapshot;name:=old_line.item_name_snapshot;cat:=old_line.category_id_snapshot;cat_name:=old_line.category_name_snapshot;
  else
   cost:=m.cogs_unit_cost;code:=m.item_code;name:=m.item_name;cat:=m.category_id;select c.name into cat_name from public.item_categories c where c.id=m.category_id;
  end if;
  if coalesce((row_data->>'refresh_cogs')::boolean,false) then cost:=m.cogs_unit_cost;end if;
  if target_status='CONFIRMED' and cost is null then raise exception 'COGS Missing: update Item Master and refresh COGS before confirming';end if;
  if line_id is null then
   insert into public.gp_invoice_items(gp_invoice_id,line_number,item_id,item_code_snapshot,item_name_snapshot,category_id_snapshot,category_name_snapshot,rate,quantity,cogs_unit_snapshot)
   values(p_id,n,m.id,code,name,cat,cat_name,(row_data->>'rate')::numeric,(row_data->>'quantity')::numeric,cost)returning id into line_id;
  else
   update public.gp_invoice_items set line_number=n,item_id=m.id,item_code_snapshot=code,item_name_snapshot=name,category_id_snapshot=cat,category_name_snapshot=cat_name,
    rate=(row_data->>'rate')::numeric,quantity=(row_data->>'quantity')::numeric,cogs_unit_snapshot=cost,updated_at=now()where id=line_id;
  end if;
  keep_ids:=array_append(keep_ids,line_id);
 end loop;
 delete from public.gp_invoice_items where gp_invoice_id=p_id and not(id=any(keep_ids));
 update public.gp_invoices set status=target_status where id=p_id;
 insert into public.gp_invoice_activities(gp_invoice_id,activity_type,description)values(p_id,case when h.id is null then 'CREATED' else 'UPDATED' end,case when h.id is null then 'GP invoice created' else 'GP invoice updated' end||' · '||target_status);
 return p_id;
end $$;

create function public.change_gp_status(p_id uuid,p_version integer,p_status text,p_reason text) returns void language plpgsql security definer set search_path='' as $$
declare h public.gp_invoices%rowtype;
begin
 if not public.has_erp_permission('finance.gp_data','EDIT') then raise exception 'GP Data Edit permission required';end if;
 select * into h from public.gp_invoices where id=p_id for update;
 if not found or h.version is distinct from p_version then raise exception 'Invoice changed or not found. Reload.';end if;
 if h.status='CANCELLED' or p_status not in('DRAFT','CANCELLED') or (p_status='DRAFT' and h.status<>'CONFIRMED') then raise exception 'Invalid status transition';end if;
 if nullif(trim(p_reason),'') is null then raise exception 'A reason is required';end if;
 update public.gp_invoices set status=p_status,version=version+1,updated_at=now(),updated_by=auth.uid(),
 cancelled_at=case when p_status='CANCELLED' then now() end,cancelled_by=case when p_status='CANCELLED' then auth.uid() end,cancellation_reason=case when p_status='CANCELLED' then trim(p_reason) end where id=p_id;
 insert into public.gp_invoice_activities(gp_invoice_id,activity_type,description)values(p_id,case when p_status='DRAFT' then 'REOPENED' else 'CANCELLED' end,trim(p_reason));
end $$;

-- RLS on every Finance table. No direct transaction writes: validated atomic RPCs only.
alter table public.gp_types enable row level security;
create policy gp_types_read on public.gp_types for select to authenticated using(public.has_erp_permission('configuration.masters','VIEW') or public.has_erp_permission('finance.gp_data','VIEW') or public.has_erp_permission('finance.cogs_analytics','VIEW'));
create policy gp_types_insert on public.gp_types for insert to authenticated with check(public.is_erp_admin() and public.has_erp_permission('configuration.masters','EDIT'));
create policy gp_types_update on public.gp_types for update to authenticated using(public.is_erp_admin() and public.has_erp_permission('configuration.masters','EDIT')) with check(public.is_erp_admin() and public.has_erp_permission('configuration.masters','EDIT'));
grant select,insert,update on public.gp_types to authenticated;
alter table public.gp_invoices enable row level security;
create policy gp_invoices_read on public.gp_invoices for select to authenticated using(public.has_erp_permission('finance.gp_data','VIEW') or public.has_erp_permission('finance.cogs_analytics','VIEW'));
alter table public.gp_invoice_items enable row level security;
create policy gp_items_read on public.gp_invoice_items for select to authenticated using(exists(select 1 from public.gp_invoices h where h.id=gp_invoice_id));
alter table public.gp_invoice_documents enable row level security;
create policy gp_documents_read on public.gp_invoice_documents for select to authenticated using(public.has_erp_permission('finance.gp_data','VIEW') and exists(select 1 from public.gp_invoices h where h.id=gp_invoice_id));
alter table public.gp_invoice_activities enable row level security;
create policy gp_activity_read on public.gp_invoice_activities for select to authenticated using(public.has_erp_permission('finance.gp_data','VIEW') and exists(select 1 from public.gp_invoices h where h.id=gp_invoice_id));
revoke all on public.gp_invoices,public.gp_invoice_items,public.gp_invoice_documents,public.gp_invoice_activities from anon,authenticated;
grant select on public.gp_invoices,public.gp_invoice_items,public.gp_invoice_documents,public.gp_invoice_activities to authenticated;

-- Uploads go through the server's byte-signature validation using the admin Storage client.
-- Authenticated clients can only read linked files; they cannot bypass validation by uploading directly.
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('gp-invoice-documents','gp-invoice-documents',false,10485760,array['application/pdf','image/jpeg','image/png']);
create policy gp_document_objects_read on storage.objects for select to authenticated using(bucket_id='gp-invoice-documents' and exists(select 1 from public.gp_invoice_documents d where d.storage_path=name));
create function public.attach_gp_document(p_id uuid,p_document_id uuid,p_type text,p_name text,p_path text,p_mime text,p_size bigint) returns uuid language plpgsql security definer set search_path='' as $$
declare h public.gp_invoices%rowtype;
begin
 if not public.has_erp_permission('finance.gp_data','EDIT') then raise exception 'GP Data Edit permission required';end if;
 select * into h from public.gp_invoices where id=p_id for update;
 if not found or h.status='CANCELLED' then raise exception 'Invoice unavailable or cancelled';end if;
 if p_name !~ '^[a-zA-Z0-9._-]+$' or p_path<>h.company_id::text||'/'||p_id::text||'/'||p_document_id::text||'/'||p_name then raise exception 'Invalid document path';end if;
 if not exists(select 1 from storage.objects where bucket_id='gp-invoice-documents' and name=p_path) then raise exception 'Uploaded document not found';end if;
 insert into public.gp_invoice_documents(id,gp_invoice_id,document_type,file_name,storage_path,mime_type,file_size)values(p_document_id,p_id,p_type,p_name,p_path,p_mime,p_size);
 insert into public.gp_invoice_activities(gp_invoice_id,activity_type,description)values(p_id,p_type||'_UPLOADED',p_type||' uploaded: '||p_name);
 return p_document_id;
end $$;
revoke all on function public.search_gp_master(text,text),public.save_gp_invoice(uuid,integer,jsonb,jsonb),public.change_gp_status(uuid,integer,text,text),public.attach_gp_document(uuid,uuid,text,text,text,text,bigint) from public,anon;
grant execute on function public.search_gp_master(text,text),public.save_gp_invoice(uuid,integer,jsonb,jsonb),public.change_gp_status(uuid,integer,text,text),public.attach_gp_document(uuid,uuid,text,text,text,text,bigint) to authenticated;
commit;
