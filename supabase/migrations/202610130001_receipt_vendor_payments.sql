begin;
-- The installation currently has one issuing legal entity. Customer companies are not tenants.
alter table public.purchase_orders add column issuing_company_key text not null default 'ADHUNIK';
alter table public.material_receipts add column invoice_date date, add column grn_number text,
 add column invoice_value numeric(18,2), add column issuing_company_key text not null default 'ADHUNIK',
 add column grn_file_name text, add column grn_file_url text, add column invoice_file_name text, add column invoice_file_url text;
alter table public.material_receipts drop constraint material_receipts_status_check;
alter table public.material_receipts add constraint material_receipts_status_check check(status in('DRAFT','CONFIRMED','CANCELLED'));
create table public.grn_counters(company_key text not null,calendar_year integer not null,current_value bigint not null,primary key(company_key,calendar_year));
alter table public.material_receipts alter column confirmed_at drop not null,alter column confirmed_by drop not null;
create unique index receipt_company_grn on public.material_receipts(issuing_company_key,grn_number);
create table public.vendor_payments(
 id uuid primary key default gen_random_uuid(),material_receipt_id uuid not null unique references public.material_receipts(id),
 purchase_order_id uuid not null references public.purchase_orders(id),supplier_name text not null,po_number text not null,
 receipt_number text not null,grn_number text,invoice_number text,invoice_date date,invoice_value numeric(18,2) not null check(invoice_value>=0),
 paid_amount numeric(18,2) not null default 0 check(paid_amount>=0 and paid_amount<=invoice_value),
 status text not null default 'Pending' check(status in('Pending','Partially Paid','Paid','Cancelled')),created_at timestamptz not null default now());
create table public.vendor_payment_records(
 id uuid primary key default gen_random_uuid(),vendor_payment_id uuid not null references public.vendor_payments(id),
 payment_date date not null,payment_mode text not null,bank text,reference_number text,utr_number text,
 amount numeric(18,2) not null check(amount>0),remarks text,proof_name text,proof_path text,created_by uuid not null references auth.users(id),created_at timestamptz not null default now());
insert into public.erp_permission_sections(module_key,section_key,module_name,section_name,sort_order) values('finance','finance.vendor_payments','Finance','Vendor Payments',930);
create function public.prepare_receipt_commercials() returns trigger language plpgsql security definer set search_path='' as $$
declare p public.purchase_orders%rowtype; n bigint; y integer;
begin
 select * into strict p from public.purchase_orders where id=new.purchase_order_id;
 if tg_op='INSERT' and current_setting('app.receipt_draft',true)='true' then new.status:='DRAFT';end if;
 new.issuing_company_key:=p.issuing_company_key;new.invoice_value:=p.grand_total;
 if new.status='CONFIRMED' and new.grn_number is null then
 y:=extract(year from now() at time zone 'Asia/Kolkata');
 insert into public.grn_counters values(p.issuing_company_key,y,1) on conflict(company_key,calendar_year) do update set current_value=public.grn_counters.current_value+1 returning current_value into n;
 new.grn_number:='GRN/'||y||'/'||lpad(n::text,greatest(4,length(n::text)),'0');end if;
 -- Existing receipt RPC uses the invoice date carried by the authorized wrapper below.
 if tg_op='INSERT' then new.invoice_date:=nullif(current_setting('app.receipt_invoice_date',true),'')::date;
 new.grn_file_name:=nullif(current_setting('app.receipt_grn_name',true),'');new.grn_file_url:=nullif(current_setting('app.receipt_grn_path',true),'');
 new.invoice_file_name:=nullif(current_setting('app.receipt_invoice_name',true),'');new.invoice_file_url:=nullif(current_setting('app.receipt_invoice_path',true),'');
 if new.invoice_date is null or new.invoice_date>(now() at time zone 'Asia/Kolkata')::date then raise exception 'Valid Invoice Date required';end if;
 if new.status='DRAFT' then new.confirmed_at:=null;new.confirmed_by:=null;end if;end if;
 return new;end$$;
create trigger receipt_commercials before insert or update of status on public.material_receipts for each row execute function public.prepare_receipt_commercials();
create function public.sync_receipt_vendor_payment() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='CONFIRMED' then
 insert into public.vendor_payments(material_receipt_id,purchase_order_id,supplier_name,po_number,receipt_number,grn_number,invoice_number,invoice_date,invoice_value)
 select new.id,new.purchase_order_id,new.supplier_name_snapshot,p.po_number,new.receipt_number,new.grn_number,new.supplier_invoice_number,new.invoice_date,new.invoice_value from public.purchase_orders p where p.id=new.purchase_order_id on conflict(material_receipt_id) do nothing;
 update public.vendor_payments set status='Paid' where material_receipt_id=new.id and invoice_value=0;
 elsif new.status='CANCELLED' then
 perform 1 from public.vendor_payments where material_receipt_id=new.id for update;
 if exists(select 1 from public.vendor_payments where material_receipt_id=new.id and paid_amount>0) then raise exception 'Receipt has recorded vendor payments and cannot be cancelled';end if;
 update public.vendor_payments set status='Cancelled' where material_receipt_id=new.id;end if;return new;end$$;
create trigger receipt_vendor_payment after insert or update of status on public.material_receipts for each row execute function public.sync_receipt_vendor_payment();
-- Backfill without changing historical invoice dates or inventing document metadata.
update public.material_receipts r set invoice_value=p.grand_total,issuing_company_key=p.issuing_company_key from public.purchase_orders p where p.id=r.purchase_order_id;
do $$declare r record;n bigint;y integer;begin for r in select * from public.material_receipts where status='CONFIRMED' order by created_at,id loop
 y:=extract(year from r.receipt_date);insert into public.grn_counters values(r.issuing_company_key,y,1) on conflict(company_key,calendar_year) do update set current_value=public.grn_counters.current_value+1 returning current_value into n;
 update public.material_receipts set grn_number='GRN/'||y||'/'||lpad(n::text,greatest(4,length(n::text)),'0') where id=r.id;end loop;end$$;
insert into public.vendor_payments(material_receipt_id,purchase_order_id,supplier_name,po_number,receipt_number,grn_number,invoice_number,invoice_date,invoice_value,status)
 select r.id,p.id,r.supplier_name_snapshot,p.po_number,r.receipt_number,r.grn_number,r.supplier_invoice_number,r.invoice_date,r.invoice_value,case when r.status='CANCELLED' then 'Cancelled' when r.invoice_value=0 then 'Paid' else 'Pending' end from public.material_receipts r join public.purchase_orders p on p.id=r.purchase_order_id;
create function public.validate_commercial_path(p_path text) returns void language plpgsql security definer set search_path='' as $$begin
 if nullif(p_path,'') is not null and not exists(select 1 from storage.objects where bucket_id='purchase-commercial-documents' and name=p_path and owner_id=auth.uid()::text) then raise exception 'Invalid uploaded document';end if;end$$;
create or replace function public.authorized_record_material_receipt(p_po_id uuid,p_header jsonb,p_items jsonb)returns uuid language plpgsql security definer set search_path=''as $$
declare po public.purchase_orders%rowtype;x jsonb;oi public.purchase_order_items%rowtype;received numeric;requested numeric;result uuid;
begin
 if not public.has_erp_permission('purchase.material_receipts','EDIT')then raise exception'Material Receipts edit permission required';end if;
 perform pg_advisory_xact_lock(hashtextextended((select root_po_id::text from public.purchase_orders where id=p_po_id),0));
 select * into po from public.purchase_orders where id=p_po_id and status in('APPROVED','PARTIALLY_RECEIVED') and approval_source is not null for update;
 if not found then raise exception'Current approved PO required';end if;
 if exists(select 1 from public.purchase_orders where root_po_id=po.root_po_id and status in('CONFIRMED','APPROVED','PARTIALLY_RECEIVED','FULLY_RECEIVED','CLOSED')and id<>po.id)then raise exception'Material Receipt must use the current approved PO version';end if;
 for x in select value from jsonb_array_elements(p_items)loop
  requested:=coalesce(nullif(x->>'received_quantity','')::numeric,0);
  if requested>0 then
   select * into oi from public.purchase_order_items where id=(x->>'purchase_order_item_id')::uuid and purchase_order_id=po.id;
   if not found then raise exception'Invalid PO item';end if;
   select coalesce(sum(mri.received_quantity),0)into received from public.material_receipt_items mri join public.material_receipts mr on mr.id=mri.material_receipt_id join public.purchase_order_items family_item on family_item.id=mri.purchase_order_item_id where family_item.root_po_item_id=oi.root_po_item_id and mr.status='CONFIRMED';
   if received+requested>oi.quantity then raise exception'Receipt quantity on line % exceeds revised ordered quantity; already received %',oi.line_number,received;end if;
  end if;
 end loop;
 if nullif(p_header->>'invoice_date','') is null or (p_header->>'invoice_date')::date>(now() at time zone 'Asia/Kolkata')::date then raise exception 'Invoice Date is required and cannot be in the future';end if;
 perform set_config('app.receipt_draft',coalesce(p_header->>'draft','false'),true);
 perform public.validate_commercial_path(p_header->>'grn_file_url');perform public.validate_commercial_path(p_header->>'invoice_file_url');
 perform set_config('app.receipt_invoice_date',p_header->>'invoice_date',true);
 perform set_config('app.receipt_grn_name',coalesce(p_header->>'grn_file_name',''),true);perform set_config('app.receipt_grn_path',coalesce(p_header->>'grn_file_url',''),true);
 perform set_config('app.receipt_invoice_name',coalesce(p_header->>'invoice_file_name',''),true);perform set_config('app.receipt_invoice_path',coalesce(p_header->>'invoice_file_url',''),true);
 result:=public.record_material_receipt(p_po_id,p_header,p_items);
 if p_header->>'draft'='true' then
 update public.material_receipt_activities set activity_type='DRAFT',description='Material Receipt saved as Draft; inventory unchanged' where material_receipt_id=result and activity_type='CONFIRMED';
 update public.purchase_order_activities set description=replace(description,'confirmed','saved as Draft') where purchase_order_id=po.id and activity_type='MATERIAL_RECEIPT' and description like '%'||(select receipt_number from public.material_receipts where id=result)||'%';end if;
 return result;
end$$;
create function public.record_vendor_payment(p_id uuid,p_data jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare v public.vendor_payments%rowtype;a numeric;result uuid;d date;
begin
 if not public.has_erp_permission('finance.vendor_payments','EDIT') then raise exception 'Vendor Payments Edit permission required';end if;
 select * into v from public.vendor_payments where id=p_id for update;
 if not found or v.status in('Paid','Cancelled') then raise exception 'No outstanding vendor payment';end if;
 perform public.validate_commercial_path(p_data->>'proof_path');
 a:=(p_data->>'amount')::numeric;d:=(p_data->>'payment_date')::date;
 if a is null or a<=0 or a::text in('NaN','Infinity','-Infinity') or a<>round(a,2) or a>v.invoice_value-v.paid_amount then raise exception 'Amount must be positive, with up to two decimals, and cannot exceed outstanding amount';end if;
 if d is null or d>(now() at time zone 'Asia/Kolkata')::date or nullif(trim(p_data->>'payment_mode'),'') is null then raise exception 'Payment date and mode required; date cannot be in the future';end if;
 insert into public.vendor_payment_records(vendor_payment_id,payment_date,payment_mode,bank,reference_number,utr_number,amount,remarks,proof_name,proof_path,created_by)
 values(p_id,d,p_data->>'payment_mode',p_data->>'bank',p_data->>'reference_number',p_data->>'utr_number',a,p_data->>'remarks',p_data->>'proof_name',p_data->>'proof_path',auth.uid()) returning id into result;
 update public.vendor_payments set paid_amount=paid_amount+a,status=case when paid_amount+a=invoice_value then 'Paid' else 'Partially Paid' end where id=p_id;return result;end$$;
alter table public.vendor_payments enable row level security;alter table public.vendor_payment_records enable row level security;alter table public.grn_counters enable row level security;
create policy vendor_payments_read on public.vendor_payments for select to authenticated using(public.has_erp_permission('finance.vendor_payments','VIEW'));
create policy vendor_records_read on public.vendor_payment_records for select to authenticated using(public.has_erp_permission('finance.vendor_payments','VIEW'));
grant select on public.vendor_payments,public.vendor_payment_records to authenticated;
revoke all on function public.record_vendor_payment(uuid,jsonb) from public,anon;grant execute on function public.record_vendor_payment(uuid,jsonb) to authenticated;
revoke all on function public.prepare_receipt_commercials(),public.sync_receipt_vendor_payment() from public,anon,authenticated;
insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('purchase-commercial-documents','purchase-commercial-documents',false,1048576,array['application/pdf','image/jpeg','image/png']);
create policy commercial_document_insert on storage.objects for insert to authenticated with check(bucket_id='purchase-commercial-documents' and (public.has_erp_permission('purchase.material_receipts','EDIT') or public.has_erp_permission('finance.vendor_payments','EDIT')));
create function public.confirm_draft_material_receipt(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare r public.material_receipts%rowtype;p public.purchase_orders%rowtype;x record;previous numeric;
begin
 if not public.has_erp_permission('purchase.material_receipts','EDIT') then raise exception 'Receipt Edit permission required';end if;
 select po.* into p from public.purchase_orders po join public.material_receipts mr on mr.purchase_order_id=po.id where mr.id=p_id;
 perform pg_advisory_xact_lock(hashtextextended(p.root_po_id::text,0));
 select * into p from public.purchase_orders where id=p.id for update;
 select * into r from public.material_receipts where id=p_id and status='DRAFT' for update;
 if not found or p.status not in('APPROVED','PARTIALLY_RECEIVED') or p.approval_source is null then raise exception 'Draft receipt and current approved PO required';end if;
 if exists(select 1 from public.purchase_orders where root_po_id=p.root_po_id and revision_number>p.revision_number and status in('APPROVED','PARTIALLY_RECEIVED','FULLY_RECEIVED','CLOSED')) then raise exception 'PO has been superseded';end if;
 if r.invoice_date is null or r.invoice_date>(now() at time zone 'Asia/Kolkata')::date then raise exception 'Valid Invoice Date required';end if;
 for x in select ri.*,oi.root_po_item_id,oi.quantity from public.material_receipt_items ri join public.purchase_order_items oi on oi.id=ri.purchase_order_item_id where ri.material_receipt_id=p_id loop
 select coalesce(sum(mri.received_quantity),0) into previous from public.material_receipt_items mri join public.material_receipts mr on mr.id=mri.material_receipt_id join public.purchase_order_items oi on oi.id=mri.purchase_order_item_id where oi.root_po_item_id=x.root_po_item_id and mr.status='CONFIRMED';
 if x.received_quantity+coalesce((select sum(mri.received_quantity) from public.material_receipt_items mri join public.material_receipts mr on mr.id=mri.material_receipt_id join public.purchase_order_items oi on oi.id=mri.purchase_order_item_id where oi.root_po_item_id=x.root_po_item_id and mr.status='CONFIRMED'),0)>x.quantity then raise exception 'Receipt exceeds remaining PO quantity';end if;
 update public.material_receipt_items set previously_received_quantity=previous,pending_quantity=x.quantity-previous-x.received_quantity where id=x.id;
 end loop;
 update public.material_receipts set status='CONFIRMED',confirmed_at=now(),confirmed_by=auth.uid() where id=p_id;
 perform public.refresh_purchase_order_revision_receipt_status(p.id);
 insert into public.material_receipt_activities(material_receipt_id,activity_type,description,created_by) values(p_id,'CONFIRMED','Draft Material Receipt confirmed; vendor payable created',auth.uid());end$$;
create function public.replace_receipt_document(p_id uuid,p_kind text,p_name text,p_path text) returns text language plpgsql security definer set search_path='' as $$
declare r public.material_receipts%rowtype;old_path text;
begin
 if not public.has_erp_permission('purchase.material_receipts','EDIT') then raise exception 'Receipt Edit permission required';end if;
 select * into r from public.material_receipts where id=p_id and status='DRAFT' for update;
 if not found then raise exception 'Documents may only be replaced on Draft receipts';end if;
 perform public.validate_commercial_path(p_path);
 if p_kind='grn' then old_path:=r.grn_file_url;update public.material_receipts set grn_file_name=p_name,grn_file_url=p_path where id=p_id;
 elsif p_kind='invoice' then old_path:=r.invoice_file_url;update public.material_receipts set invoice_file_name=p_name,invoice_file_url=p_path where id=p_id;
 else raise exception 'Invalid document type';end if;
 insert into public.material_receipt_activities(material_receipt_id,activity_type,description,created_by) values(p_id,'DOCUMENT_REPLACED',p_kind||' document replaced with '||p_name||'; previous storage path: '||coalesce(old_path,'none'),auth.uid());
 return old_path;end$$;
-- Closing requires material completion and settlement of every confirmed receipt in the PO family.
create function public.guard_purchase_finance_close() returns trigger language plpgsql security definer set search_path='' as $$begin
 if new.status='CLOSED' and old.status<>'CLOSED' and (old.status<>'FULLY_RECEIVED' or exists(select 1 from public.vendor_payments v join public.purchase_orders p on p.id=v.purchase_order_id where p.root_po_id=new.root_po_id and v.status not in('Paid','Cancelled'))) then raise exception 'Receive all material and settle vendor payments before closing the PO';end if;return new;end$$;
create trigger purchase_finance_close before update of status on public.purchase_orders for each row execute function public.guard_purchase_finance_close();
revoke all on function public.validate_commercial_path(text),public.guard_purchase_finance_close() from public,anon,authenticated;
revoke all on function public.confirm_draft_material_receipt(uuid),public.replace_receipt_document(uuid,text,text,text) from public,anon;
grant execute on function public.confirm_draft_material_receipt(uuid),public.replace_receipt_document(uuid,text,text,text) to authenticated;
create or replace function public.purchase_receipt_workspace() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not public.has_erp_permission('purchase.material_receipts','VIEW') then raise exception 'Material Receipts view permission required'; end if;
 return jsonb_build_object(
  'orders',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'root_po_id',p.root_po_id,'revision_number',p.revision_number,'status',p.status,'approval_source',p.approval_source,'grand_total',p.grand_total,'po_number',p.po_number,'supplier_name_snapshot',p.supplier_name_snapshot,'po_date',p.po_date,'expected_delivery_date',p.expected_delivery_date)) from public.purchase_orders p),'[]'::jsonb),
  'items',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'root_po_item_id',i.root_po_item_id,'purchase_order_id',i.purchase_order_id,'quantity',i.quantity,'line_number',i.line_number,'item_code_snapshot',i.item_code_snapshot,'item_name_snapshot',i.item_name_snapshot,'unit_snapshot',i.unit_snapshot) order by i.line_number) from public.purchase_order_items i),'[]'::jsonb),
  'receipts',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'purchase_order_id',r.purchase_order_id,'receipt_number',r.receipt_number,'status',r.status) order by r.receipt_date,r.created_at) from public.material_receipts r),'[]'::jsonb),
  'received',coalesce((select jsonb_object_agg(q.root_po_item_id,q.received) from (
   select i.root_po_item_id,sum(ri.received_quantity) received
   from public.material_receipt_items ri join public.material_receipts r on r.id=ri.material_receipt_id
   join public.purchase_order_items i on i.id=ri.purchase_order_item_id where r.status='CONFIRMED' group by i.root_po_item_id
  )q),'{}'::jsonb)
 );
end $$;
commit;
