alter table public.purchase_orders
 add column root_po_id uuid references public.purchase_orders(id) on delete restrict,
 add column parent_po_id uuid references public.purchase_orders(id) on delete restrict,
 add column revision_number integer not null default 0 check(revision_number>=0),
 add column revision_reason text,
 add column revised_at timestamptz,
 add column revised_by uuid references auth.users(id);
update public.purchase_orders set root_po_id=id;
alter table public.purchase_orders alter column root_po_id set not null;
alter table public.purchase_order_items add column root_po_item_id uuid references public.purchase_order_items(id) on delete restrict;
update public.purchase_order_items set root_po_item_id=id;
alter table public.purchase_order_items alter column root_po_item_id set not null;

drop index if exists public.purchase_orders_one_per_indent;
drop index if exists public.purchase_order_items_indent_source;
create unique index purchase_orders_one_original_per_indent on public.purchase_orders(indent_id) where revision_number=0;
create unique index purchase_order_items_indent_source on public.purchase_order_items(purchase_order_id,indent_item_id)where indent_item_id is not null;
create unique index purchase_orders_root_revision on public.purchase_orders(root_po_id,revision_number);
create unique index purchase_orders_one_open_revision on public.purchase_orders(root_po_id) where revision_number>0 and status='DRAFT';
create unique index purchase_orders_one_current_version on public.purchase_orders(root_po_id) where status in('CONFIRMED','PARTIALLY_RECEIVED','FULLY_RECEIVED','CLOSED');
create index purchase_orders_revision_history on public.purchase_orders(root_po_id,revision_number);
create index purchase_order_items_root_line on public.purchase_order_items(root_po_item_id);
alter table public.purchase_orders drop constraint purchase_orders_status_check;
alter table public.purchase_orders add constraint purchase_orders_status_check check(status in('DRAFT','CONFIRMED','PARTIALLY_RECEIVED','FULLY_RECEIVED','CANCELLED','CLOSED','SUPERSEDED'));
alter table public.purchase_orders add constraint purchase_orders_revision_identity check((revision_number=0 and parent_po_id is null and revision_reason is null)or(revision_number>0 and parent_po_id is not null and nullif(trim(revision_reason),'')is not null));

create or replace function public.create_purchase_order_revision(p_id uuid,p_reason text)returns uuid language plpgsql security definer set search_path=''as $$
declare p public.purchase_orders%rowtype;v_id uuid;v_revision integer;v_number text;
begin
 if not public.has_erp_permission('purchase.orders','EDIT')then raise exception'Purchase Orders edit permission required';end if;
 if nullif(trim(p_reason),'')is null then raise exception'Revision Reason is required';end if;
 select * into p from public.purchase_orders where id=p_id for update;
 if not found then raise exception'Purchase Order not found';end if;
 perform pg_advisory_xact_lock(hashtextextended(p.root_po_id::text,0));
 select * into p from public.purchase_orders where id=p_id for update;
 if p.status not in('CONFIRMED','PARTIALLY_RECEIVED','FULLY_RECEIVED','CLOSED')then raise exception'Only the current confirmed PO can be revised';end if;
 if exists(select 1 from public.purchase_orders where root_po_id=p.root_po_id and revision_number>0 and status='DRAFT')then raise exception'An open Draft revision already exists';end if;
 select coalesce(max(revision_number),0)+1 into v_revision from public.purchase_orders where root_po_id=p.root_po_id;
 v_number:=(select po_number from public.purchase_orders where id=p.root_po_id)||'-Revised-'||lpad(v_revision::text,2,'0');
 insert into public.purchase_orders(po_number,po_date,requisition_id,indent_id,supplier_id,supplier_code_snapshot,supplier_name_snapshot,supplier_gstin_snapshot,supplier_address_snapshot,supplier_contact_snapshot,supplier_phone_snapshot,supplier_email_snapshot,billing_address_snapshot,delivery_address_snapshot,payment_terms,delivery_terms,expected_delivery_date,remarks,terms_conditions,gst_rate,subtotal,gst_amount,freight_amount,grand_total,status,created_by,updated_by,root_po_id,parent_po_id,revision_number,revision_reason,revised_at,revised_by)
 select v_number,po_date,requisition_id,indent_id,supplier_id,supplier_code_snapshot,supplier_name_snapshot,supplier_gstin_snapshot,supplier_address_snapshot,supplier_contact_snapshot,supplier_phone_snapshot,supplier_email_snapshot,billing_address_snapshot,delivery_address_snapshot,payment_terms,delivery_terms,expected_delivery_date,remarks,terms_conditions,gst_rate,subtotal,gst_amount,freight_amount,grand_total,'DRAFT',auth.uid(),auth.uid(),root_po_id,id,v_revision,trim(p_reason),now(),auth.uid() from public.purchase_orders where id=p.id returning id into v_id;
 insert into public.purchase_order_items(purchase_order_id,requisition_item_id,indent_item_id,line_number,item_id,item_code_snapshot,item_name_snapshot,description_snapshot,hsn_code_snapshot,unit_snapshot,pon_quantity,quantity,unit_rate,line_amount,expected_delivery_date,remarks,root_po_item_id)
 select v_id,requisition_item_id,indent_item_id,line_number,item_id,item_code_snapshot,item_name_snapshot,description_snapshot,hsn_code_snapshot,unit_snapshot,pon_quantity,quantity,unit_rate,line_amount,expected_delivery_date,remarks,root_po_item_id from public.purchase_order_items where purchase_order_id=p.id order by line_number;
 insert into public.purchase_order_activities(purchase_order_id,activity_type,description,created_by)values(v_id,'PO_REVISION_CREATED','Revision '||lpad(v_revision::text,2,'0')||' created. Reason: '||trim(p_reason),auth.uid());
 insert into public.purchase_order_activities(purchase_order_id,activity_type,description,created_by)values(p.id,'PO_REVISION_CREATED','Revision '||v_number||' created. Reason: '||trim(p_reason),auth.uid());
 return v_id;
end$$;

create function public.set_purchase_order_revision_root()returns trigger language plpgsql set search_path=''as $$begin if new.root_po_id is null then new.root_po_id:=new.id;end if;return new;end$$;
create function public.set_purchase_order_item_revision_root()returns trigger language plpgsql set search_path=''as $$begin if new.root_po_item_id is null then new.root_po_item_id:=new.id;end if;return new;end$$;
create trigger purchase_orders_revision_root before insert on public.purchase_orders for each row execute function public.set_purchase_order_revision_root();
create trigger purchase_order_items_revision_root before insert on public.purchase_order_items for each row execute function public.set_purchase_order_item_revision_root();

create or replace function public.authorized_save_purchase_order(p_id uuid,p_header jsonb,p_items jsonb)returns uuid language plpgsql security definer set search_path=''as $$
declare result uuid;
begin
 if not public.has_erp_permission('purchase.orders','EDIT')then raise exception'Purchase Orders edit permission required';end if;
 result:=public.save_purchase_order(p_id,p_header,p_items);
 if exists(select 1 from public.purchase_order_items poi where poi.purchase_order_id=p_id and poi.quantity<coalesce((select sum(mri.received_quantity)from public.material_receipt_items mri join public.material_receipts mr on mr.id=mri.material_receipt_id join public.purchase_order_items family_item on family_item.id=mri.purchase_order_item_id where family_item.root_po_item_id=poi.root_po_item_id and mr.status='CONFIRMED'),0))then raise exception'Revised ordered quantity cannot be below quantity already received';end if;
 return result;
end$$;

create function public.refresh_purchase_order_revision_receipt_status(p_id uuid)returns void language plpgsql security definer set search_path=''as $$
declare any_received boolean;all_received boolean;
begin
 select coalesce(bool_or(received>0),false),coalesce(bool_and(received>=quantity),false)into any_received,all_received from(select poi.quantity,coalesce((select sum(mri.received_quantity)from public.material_receipt_items mri join public.material_receipts mr on mr.id=mri.material_receipt_id join public.purchase_order_items family_item on family_item.id=mri.purchase_order_item_id where family_item.root_po_item_id=poi.root_po_item_id and mr.status='CONFIRMED'),0)received from public.purchase_order_items poi where poi.purchase_order_id=p_id)q;
 update public.purchase_orders set status=case when all_received then'FULLY_RECEIVED'when any_received then'PARTIALLY_RECEIVED'else'CONFIRMED'end,updated_at=now(),updated_by=auth.uid()where id=p_id and status in('CONFIRMED','PARTIALLY_RECEIVED','FULLY_RECEIVED');
end$$;

create or replace function public.refresh_purchase_order_receipt_status(p_id uuid)returns void language plpgsql security definer set search_path=''as $$declare r integer;begin select revision_number into r from public.purchase_orders where id=p_id;if r>0 then perform public.refresh_purchase_order_revision_receipt_status(p_id);else update public.purchase_orders set status=case when not exists(select 1 from public.purchase_order_items oi where oi.purchase_order_id=p_id and coalesce((select sum(ri.received_quantity)from public.material_receipt_items ri join public.material_receipts mr on mr.id=ri.material_receipt_id where ri.purchase_order_item_id=oi.id and mr.status='CONFIRMED'),0)<oi.quantity)then'FULLY_RECEIVED'when exists(select 1 from public.material_receipt_items ri join public.material_receipts mr on mr.id=ri.material_receipt_id join public.purchase_order_items oi on oi.id=ri.purchase_order_item_id where oi.purchase_order_id=p_id and mr.status='CONFIRMED')then'PARTIALLY_RECEIVED'else'CONFIRMED'end,updated_at=now(),updated_by=auth.uid()where id=p_id and status not in('CANCELLED','CLOSED','SUPERSEDED');end if;end$$;

create or replace function public.authorized_confirm_purchase_order(p_id uuid)returns void language plpgsql security definer set search_path=''as $$
declare p public.purchase_orders%rowtype;prior_id uuid;
begin
 if not public.has_erp_permission('purchase.orders','EDIT')then raise exception'Purchase Orders edit permission required';end if;
 select * into p from public.purchase_orders where id=p_id and status='DRAFT'for update;
 if not found then raise exception'Draft PO not found';end if;
 if p.revision_number>0 then
  perform pg_advisory_xact_lock(hashtextextended(p.root_po_id::text,0));
  if exists(select 1 from public.purchase_order_items poi where poi.purchase_order_id=p_id and poi.quantity<coalesce((select sum(mri.received_quantity)from public.material_receipt_items mri join public.material_receipts mr on mr.id=mri.material_receipt_id join public.purchase_order_items family_item on family_item.id=mri.purchase_order_item_id where family_item.root_po_item_id=poi.root_po_item_id and mr.status='CONFIRMED'),0))then raise exception'Revised ordered quantity cannot be below quantity already received';end if;
  select id into prior_id from public.purchase_orders where root_po_id=p.root_po_id and status in('CONFIRMED','PARTIALLY_RECEIVED','FULLY_RECEIVED','CLOSED')for update;
  if prior_id is null then raise exception'Current confirmed PO version not found';end if;
  update public.purchase_orders set status='SUPERSEDED',updated_at=now(),updated_by=auth.uid()where id=prior_id;
  insert into public.purchase_order_activities values(default,prior_id,'PO_SUPERSEDED','Superseded by '||p.po_number,auth.uid(),default);
 end if;
 perform public.confirm_purchase_order(p_id);
 if p.revision_number>0 then perform public.refresh_purchase_order_revision_receipt_status(p_id);end if;
 if p.revision_number>0 then insert into public.purchase_order_activities values(default,p_id,'PO_REVISION_CONFIRMED','Revised Purchase Order confirmed',auth.uid(),default);end if;
end$$;

create or replace function public.authorized_cancel_purchase_order(p_id uuid,p_reason text)returns void language plpgsql security definer set search_path=''as $$
declare p public.purchase_orders%rowtype;
begin
 if not public.has_erp_permission('purchase.orders','EDIT')then raise exception'Purchase Orders edit permission required';end if;
 select * into p from public.purchase_orders where id=p_id;
 if p.revision_number>0 and p.status<>'DRAFT'then raise exception'Only a Draft PO revision can be cancelled';end if;
 perform public.cancel_purchase_order(p_id,p_reason);
 if p.revision_number>0 then insert into public.purchase_order_activities values(default,p_id,'PO_REVISION_CANCELLED','PO revision cancelled: '||trim(p_reason),auth.uid(),default);end if;
end$$;

create or replace function public.authorized_create_purchase_order_revision(p_id uuid,p_reason text)returns uuid language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.orders','EDIT')then raise exception'Purchase Orders edit permission required';end if;return public.create_purchase_order_revision(p_id,p_reason);end$$;
revoke all on function public.create_purchase_order_revision(uuid,text),public.authorized_create_purchase_order_revision(uuid,text)from public,anon;
grant execute on function public.create_purchase_order_revision(uuid,text),public.authorized_create_purchase_order_revision(uuid,text)to authenticated;
comment on column public.purchase_orders.root_po_id is 'UUID of the original PO shared by every immutable version.';
comment on column public.purchase_order_items.root_po_item_id is 'Stable line identity used to aggregate receipts across PO revisions.';

create or replace function public.authorized_record_material_receipt(p_po_id uuid,p_header jsonb,p_items jsonb)returns uuid language plpgsql security definer set search_path=''as $$
declare po public.purchase_orders%rowtype;x jsonb;oi public.purchase_order_items%rowtype;received numeric;requested numeric;
begin
 if not public.has_erp_permission('purchase.material_receipts','EDIT')then raise exception'Material Receipts edit permission required';end if;
 select * into po from public.purchase_orders where id=p_po_id and status in('CONFIRMED','PARTIALLY_RECEIVED')for update;
 if not found then raise exception'Current confirmed PO required';end if;
 if exists(select 1 from public.purchase_orders where root_po_id=po.root_po_id and status in('CONFIRMED','PARTIALLY_RECEIVED','FULLY_RECEIVED','CLOSED')and id<>po.id)then raise exception'Material Receipt must use the current confirmed PO version';end if;
 for x in select value from jsonb_array_elements(p_items)loop
  requested:=coalesce(nullif(x->>'received_quantity','')::numeric,0);
  if requested>0 then
   select * into oi from public.purchase_order_items where id=(x->>'purchase_order_item_id')::uuid and purchase_order_id=po.id;
   if not found then raise exception'Invalid PO item';end if;
   select coalesce(sum(mri.received_quantity),0)into received from public.material_receipt_items mri join public.material_receipts mr on mr.id=mri.material_receipt_id join public.purchase_order_items family_item on family_item.id=mri.purchase_order_item_id where family_item.root_po_item_id=oi.root_po_item_id and mr.status='CONFIRMED';
   if received+requested>oi.quantity then raise exception'Receipt quantity on line % exceeds revised ordered quantity; already received %',oi.line_number,received;end if;
  end if;
 end loop;
 return public.record_material_receipt(p_po_id,p_header,p_items);
end$$;
