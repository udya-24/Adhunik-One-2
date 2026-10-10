-- Mandatory management approval; numbering and existing permission grants are unchanged.
begin;
alter table public.purchase_orders
 add column approved_by uuid references auth.users(id),
 add column approved_date date,
 add column approved_at timestamptz,
 add column approval_source text;
alter table public.purchase_orders drop constraint purchase_orders_status_check;
alter table public.purchase_orders add constraint purchase_orders_status_check
 check(status in('DRAFT','CONFIRMED','APPROVED','PARTIALLY_RECEIVED','FULLY_RECEIVED','CANCELLED','CLOSED','SUPERSEDED'));
drop index if exists public.purchase_orders_one_current_version;
create unique index purchase_orders_one_current_version on public.purchase_orders(root_po_id)
 where status in('CONFIRMED','APPROVED','PARTIALLY_RECEIVED','FULLY_RECEIVED','CLOSED');

-- Orders already in receipt processing keep their workflow. This is an explicit
-- legacy exemption, not a management approval attributed to a fabricated user/date.
update public.purchase_orders p set approval_source='LEGACY_RECEIPT',
 status=case when p.status='CONFIRMED' then 'APPROVED' else p.status end
 where p.status in('PARTIALLY_RECEIVED','FULLY_RECEIVED','CLOSED')
 or (p.status in('CONFIRMED','SUPERSEDED') and exists(
  select 1 from public.material_receipts r join public.purchase_orders family on family.id=r.purchase_order_id
  where family.root_po_id=p.root_po_id
 ));
insert into public.purchase_order_activities(purchase_order_id,activity_type,description,created_by)
 select p.id,'LEGACY_RECEIPT_APPROVAL_EXEMPTION','Existing receipt workflow retained; Management approval was not recorded retroactively.',coalesce(p.confirmed_by,p.created_by)
 from public.purchase_orders p where p.approval_source='LEGACY_RECEIPT';
update public.purchase_orders p set status='CANCELLED',cancelled_at=now(),cancelled_by=coalesce(p.updated_by,p.created_by),
 cancellation_reason='Draft revision cancelled because the existing receipt workflow is locked',updated_at=now()
 where p.status='DRAFT' and exists(select 1 from public.purchase_orders family where family.root_po_id=p.root_po_id and family.approval_source is not null);
insert into public.purchase_order_activities(purchase_order_id,activity_type,description,created_by)
 select p.id,'PO_REVISION_CANCELLED',p.cancellation_reason,coalesce(p.cancelled_by,p.created_by)
 from public.purchase_orders p where p.cancellation_reason='Draft revision cancelled because the existing receipt workflow is locked';
alter table public.purchase_orders add constraint purchase_orders_approval_metadata check(
 (approval_source is null and approved_by is null and approved_at is null and approved_date is null)
 or (approval_source is not null and (
  (approval_source='MANAGEMENT' and approved_by is not null and approved_at is not null and approved_date is not null and approved_date=(approved_at at time zone 'Asia/Kolkata')::date)
  or (approval_source='LEGACY_RECEIPT' and approved_by is null and approved_at is null and approved_date is null)
 ))
);
alter table public.purchase_orders add constraint purchase_orders_receipt_requires_approval
 check(status not in('APPROVED','PARTIALLY_RECEIVED','FULLY_RECEIVED','CLOSED') or approval_source is not null);

create or replace function public.assert_purchase_order_unapproved(p_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare root_id uuid;
begin
 select root_po_id into root_id from public.purchase_orders where id=p_id;
 perform pg_advisory_xact_lock(hashtextextended(root_id::text,0));
 if exists(select 1 from public.purchase_orders where root_po_id=root_id and approval_source is not null) then
  raise exception 'This Purchase Order has already been approved by Management. Approved Purchase Orders cannot be revised.';
 end if;
end $$;
revoke all on function public.assert_purchase_order_unapproved(uuid) from public,anon,authenticated;

-- Database guards protect all commercial snapshots and lines, including stale drafts
-- and mutations outside the normal page controls.
create or replace function public.guard_approved_purchase_order() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' then
  if exists(select 1 from public.purchase_orders where root_po_id=new.root_po_id and approval_source is not null) then
   raise exception 'This Purchase Order has already been approved by Management. Approved Purchase Orders cannot be revised.';
  end if;
 elsif exists(select 1 from public.purchase_orders where root_po_id=old.root_po_id and approval_source is not null) then
  if (to_jsonb(new)-array['status','updated_at','updated_by','cancelled_at','cancelled_by','cancellation_reason','closed_at'])
    is distinct from (to_jsonb(old)-array['status','updated_at','updated_by','cancelled_at','cancelled_by','cancellation_reason','closed_at']) then
   raise exception 'Approved Purchase Orders are read-only. Commercial modifications are not allowed.';
  end if;
  if old.approval_source is not null and new.status in('DRAFT','CONFIRMED','SUPERSEDED') then
   raise exception 'Approved Purchase Orders are read-only.';
  end if;
 end if;
 return new;
end $$;
create trigger purchase_orders_management_lock before insert or update on public.purchase_orders
 for each row execute function public.guard_approved_purchase_order();
create or replace function public.guard_approved_purchase_order_item() returns trigger
language plpgsql security definer set search_path='' as $$
declare po_id uuid;old_po_id uuid;
begin
 if tg_op='DELETE' then po_id:=old.purchase_order_id;else po_id:=new.purchase_order_id;end if;
 if tg_op='UPDATE' then old_po_id:=old.purchase_order_id;end if;
 if exists(select 1 from public.purchase_orders p join public.purchase_orders family on family.root_po_id=p.root_po_id
  where (p.id=po_id or p.id=old_po_id) and family.approval_source is not null) then
  raise exception 'Approved Purchase Orders are read-only. Item modifications are not allowed.';
 end if;
 if tg_op='DELETE' then return old;end if;
 return new;
end $$;
create trigger purchase_order_items_management_lock before insert or update or delete on public.purchase_order_items
 for each row execute function public.guard_approved_purchase_order_item();
revoke all on function public.guard_approved_purchase_order(),public.guard_approved_purchase_order_item() from public,anon,authenticated;

create or replace function public.authorized_approve_purchase_order(p_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare p public.purchase_orders%rowtype;approval_time timestamptz:=now();
begin
 if not public.has_erp_permission('purchase.orders','EDIT') or not public.is_erp_manager() then
  raise exception 'Management approval requires Admin or Manager access with Purchase Orders edit permission';
 end if;
 perform pg_advisory_xact_lock(hashtextextended((select root_po_id::text from public.purchase_orders where id=p_id),0));
 select * into p from public.purchase_orders where id=p_id for update;
 if not found then raise exception 'Purchase Order not found';end if;
 -- Safe replay of a completed management approval without duplicate audit entries.
 if p.approval_source='MANAGEMENT' and p.status in('APPROVED','PARTIALLY_RECEIVED','FULLY_RECEIVED','CLOSED') then return;end if;
 if p.status<>'CONFIRMED' or p.approval_source is not null then raise exception 'Only the latest confirmed Purchase Order can be approved';end if;
 if exists(select 1 from public.purchase_orders where root_po_id=p.root_po_id and revision_number>p.revision_number
  and status in('CONFIRMED','APPROVED','PARTIALLY_RECEIVED','FULLY_RECEIVED','CLOSED')) then
  raise exception 'Only the latest confirmed Purchase Order can be approved';
 end if;
 update public.purchase_orders set status='APPROVED',approval_source='MANAGEMENT',approved_by=auth.uid(),
 approved_date=(approval_time at time zone 'Asia/Kolkata')::date,approved_at=approval_time,updated_at=approval_time,updated_by=auth.uid() where id=p_id;
 insert into public.purchase_order_activities(purchase_order_id,activity_type,description,created_by)
 values(p_id,'MANAGEMENT_APPROVED','Purchase Order approved by Management',auth.uid());
 with cancelled as (
  update public.purchase_orders set status='CANCELLED',cancelled_at=approval_time,cancelled_by=auth.uid(),
  cancellation_reason='Draft revision cancelled because the Purchase Order was approved by Management',updated_at=approval_time,updated_by=auth.uid()
  where root_po_id=p.root_po_id and status='DRAFT' returning id,cancellation_reason
 ) insert into public.purchase_order_activities(purchase_order_id,activity_type,description,created_by)
 select id,'PO_REVISION_CANCELLED',cancellation_reason,auth.uid() from cancelled;
end $$;
revoke all on function public.authorized_approve_purchase_order(uuid) from public,anon;
grant execute on function public.authorized_approve_purchase_order(uuid) to authenticated;

create or replace function public.refresh_purchase_order_revision_receipt_status(p_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare any_received boolean;all_received boolean;
begin
 select coalesce(bool_or(received>0),false),coalesce(bool_and(received>=quantity),false) into any_received,all_received
 from(select poi.quantity,coalesce((select sum(mri.received_quantity) from public.material_receipt_items mri
  join public.material_receipts mr on mr.id=mri.material_receipt_id
  join public.purchase_order_items family_item on family_item.id=mri.purchase_order_item_id
  where family_item.root_po_item_id=poi.root_po_item_id and mr.status='CONFIRMED'),0) received
  from public.purchase_order_items poi where poi.purchase_order_id=p_id)q;
 update public.purchase_orders set status=case when all_received then 'FULLY_RECEIVED' when any_received then 'PARTIALLY_RECEIVED' else 'APPROVED' end,
 updated_at=now(),updated_by=auth.uid() where id=p_id and approval_source is not null and status in('APPROVED','PARTIALLY_RECEIVED','FULLY_RECEIVED');
end $$;
create or replace function public.refresh_purchase_order_receipt_status(p_id uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 perform public.refresh_purchase_order_revision_receipt_status(p_id);
end $$;
create or replace function public.purchase_receipt_workspace() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not public.has_erp_permission('purchase.material_receipts','VIEW') then raise exception 'Material Receipts view permission required'; end if;
 return jsonb_build_object(
  'orders',coalesce((select jsonb_agg(jsonb_build_object('id',p.id,'root_po_id',p.root_po_id,'revision_number',p.revision_number,'status',p.status,'approval_source',p.approval_source,'po_number',p.po_number,'supplier_name_snapshot',p.supplier_name_snapshot,'po_date',p.po_date,'expected_delivery_date',p.expected_delivery_date)) from public.purchase_orders p),'[]'::jsonb),
  'items',coalesce((select jsonb_agg(jsonb_build_object('id',i.id,'root_po_item_id',i.root_po_item_id,'purchase_order_id',i.purchase_order_id,'quantity',i.quantity,'line_number',i.line_number,'item_code_snapshot',i.item_code_snapshot,'item_name_snapshot',i.item_name_snapshot,'unit_snapshot',i.unit_snapshot) order by i.line_number) from public.purchase_order_items i),'[]'::jsonb),
  'receipts',coalesce((select jsonb_agg(jsonb_build_object('id',r.id,'purchase_order_id',r.purchase_order_id,'receipt_number',r.receipt_number,'status',r.status) order by r.receipt_date,r.created_at) from public.material_receipts r),'[]'::jsonb),
  'received',coalesce((select jsonb_object_agg(q.root_po_item_id,q.received) from (
   select i.root_po_item_id,sum(ri.received_quantity) received
   from public.material_receipt_items ri join public.material_receipts r on r.id=ri.material_receipt_id
   join public.purchase_order_items i on i.id=ri.purchase_order_item_id where r.status='CONFIRMED' group by i.root_po_item_id
  )q),'{}'::jsonb)
 );
end $$;
create or replace function public.cancel_purchase_order(p_id uuid,p_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare p public.purchase_orders%rowtype;
begin
 if not public.is_erp_manager() or nullif(trim(p_reason),'') is null then raise exception 'Authorization and reason required'; end if;
 perform pg_advisory_xact_lock(hashtextextended((select root_po_id::text from public.purchase_orders where id=p_id),0));
 select * into p from public.purchase_orders where id=p_id for update;
 if not found then raise exception 'Purchase Order not found'; end if;
 if exists(select 1 from public.material_receipts r join public.purchase_orders family on family.id=r.purchase_order_id where family.root_po_id=p.root_po_id) then
  raise exception 'Material Receipt already exists. Purchase Order cannot be cancelled.';
 end if;
 update public.purchase_orders set status='CANCELLED',cancelled_at=now(),cancelled_by=auth.uid(),cancellation_reason=trim(p_reason),updated_at=now(),updated_by=auth.uid()
 where id=p_id and status in('DRAFT','CONFIRMED','APPROVED');
 if not found then raise exception 'PO cannot be cancelled'; end if;
 -- A cancelled current order must not leave a confirmable draft revision behind.
 if p.status in('CONFIRMED','APPROVED') then
  update public.purchase_orders set status='CANCELLED',cancelled_at=now(),cancelled_by=auth.uid(),cancellation_reason=trim(p_reason),updated_at=now(),updated_by=auth.uid()
  where root_po_id=p.root_po_id and status='DRAFT';
 end if;
 insert into public.purchase_order_activities values(default,p_id,'CANCELLED','Purchase Order cancelled: '||trim(p_reason),auth.uid(),default);
end $$;
create or replace function public.record_material_receipt(p_po_id uuid,p_header jsonb,p_items jsonb)returns uuid language plpgsql security definer set search_path=''as $$declare po public.purchase_orders%rowtype;v uuid;n text;x jsonb;oi public.purchase_order_items%rowtype;prev numeric;recv numeric;acc numeric;rej numeric;i integer:=0;begin if not public.is_erp_manager()then raise exception'Unauthorized';end if;perform pg_advisory_xact_lock(hashtextextended((select root_po_id::text from public.purchase_orders where id=p_po_id),0));select * into po from public.purchase_orders where id=p_po_id and status in('APPROVED','PARTIALLY_RECEIVED') and approval_source is not null for update;if not found then raise exception'Open approved PO required';end if;n:=public.allocate_procurement_number('MATERIAL_RECEIPT');insert into public.material_receipts(receipt_number,receipt_date,purchase_order_id,supplier_id,supplier_name_snapshot,supplier_challan_number,supplier_invoice_number,received_at,received_by,remarks,confirmed_by)values(n,coalesce(nullif(p_header->>'receipt_date','')::date,current_date),po.id,po.supplier_id,po.supplier_name_snapshot,nullif(trim(p_header->>'challan'),''),nullif(trim(p_header->>'invoice'),''),nullif(trim(p_header->>'received_at'),''),auth.uid(),nullif(trim(p_header->>'remarks'),''),auth.uid())returning id into v;for x in select value from jsonb_array_elements(p_items)loop recv:=coalesce(nullif(x->>'received_quantity','')::numeric,0);if recv>0 then i:=i+1;select * into oi from public.purchase_order_items where id=(x->>'purchase_order_item_id')::uuid and purchase_order_id=po.id;if not found then raise exception'Invalid PO item';end if;select coalesce(sum(ri.received_quantity),0)into prev from public.material_receipt_items ri join public.material_receipts r on r.id=ri.material_receipt_id join public.purchase_order_items family_item on family_item.id=ri.purchase_order_item_id where family_item.root_po_item_id=oi.root_po_item_id and r.status='CONFIRMED';acc:=coalesce(nullif(x->>'accepted_quantity','')::numeric,0);rej:=coalesce(nullif(x->>'rejected_quantity','')::numeric,0);if recv<=0 or prev+recv>oi.quantity or acc<0 or rej<0 or acc+rej<>recv then raise exception'Invalid receipt quantity for line %',oi.line_number;end if;insert into public.material_receipt_items(material_receipt_id,purchase_order_item_id,line_number,item_id,item_code_snapshot,item_name_snapshot,unit_snapshot,ordered_quantity,previously_received_quantity,received_quantity,accepted_quantity,rejected_quantity,pending_quantity,remarks)values(v,oi.id,oi.line_number,oi.item_id,oi.item_code_snapshot,oi.item_name_snapshot,oi.unit_snapshot,oi.quantity,prev,recv,acc,rej,oi.quantity-prev-recv,nullif(trim(x->>'remarks'),''));end if;end loop;if i=0 then raise exception'Enter at least one received quantity';end if;insert into public.material_receipt_activities values(default,v,'CONFIRMED','Material Receipt recorded and confirmed; inventory unchanged',auth.uid(),default);insert into public.purchase_order_activities values(default,po.id,'MATERIAL_RECEIPT','Material Receipt '||n||' confirmed; inventory unchanged',auth.uid(),default);perform public.refresh_purchase_order_receipt_status(po.id);return v;end$$;
create or replace function public.authorized_record_material_receipt(p_po_id uuid,p_header jsonb,p_items jsonb)returns uuid language plpgsql security definer set search_path=''as $$
declare po public.purchase_orders%rowtype;x jsonb;oi public.purchase_order_items%rowtype;received numeric;requested numeric;
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
 return public.record_material_receipt(p_po_id,p_header,p_items);
end$$;
create or replace function public.cancel_material_receipt(p_id uuid,p_reason text)returns void language plpgsql security definer set search_path=''as $$declare po uuid;root_id uuid;begin if not public.is_erp_manager()or nullif(trim(p_reason),'')is null then raise exception'Authorization and reason required';end if;select p.root_po_id into root_id from public.material_receipts mr join public.purchase_orders p on p.id=mr.purchase_order_id where mr.id=p_id;perform pg_advisory_xact_lock(hashtextextended(root_id::text,0));perform 1 from public.material_receipts where id=p_id for update;if exists(select 1 from public.material_receipt_inventory_postings where material_receipt_id=p_id)then raise exception'Inventory has already been posted from this Material Receipt. Reverse the inventory transaction before cancelling the receipt.';end if;update public.material_receipts set status='CANCELLED',cancelled_at=now(),cancelled_by=auth.uid(),cancellation_reason=trim(p_reason)where id=p_id and status='CONFIRMED'returning purchase_order_id into po;if po is null then raise exception'Receipt cannot be cancelled';end if;insert into public.material_receipt_activities values(default,p_id,'CANCELLED','Material Receipt cancelled: '||trim(p_reason),auth.uid(),default);select id into po from public.purchase_orders where root_po_id=root_id and status in('APPROVED','PARTIALLY_RECEIVED','FULLY_RECEIVED');if po is not null then perform public.refresh_purchase_order_revision_receipt_status(po);end if;end$$;
create or replace function public.create_purchase_order_revision(p_id uuid,p_reason text)returns uuid language plpgsql security definer set search_path=''as $$
declare p public.purchase_orders%rowtype;v_id uuid;v_revision integer;v_number text;
begin
 if not public.has_erp_permission('purchase.orders','EDIT')then raise exception'Purchase Orders edit permission required';end if;
 perform public.assert_purchase_order_unapproved(p_id);
 if nullif(trim(p_reason),'')is null then raise exception'Revision Reason is required';end if;
 select * into p from public.purchase_orders where id=p_id;
 if not found then raise exception'Purchase Order not found';end if;
 perform pg_advisory_xact_lock(hashtextextended(p.root_po_id::text,0));
 select * into p from public.purchase_orders where id=p_id for update;
 if p.status not in('CONFIRMED','PARTIALLY_RECEIVED','FULLY_RECEIVED','CLOSED')then raise exception'Only the current confirmed PO can be revised';end if;
 if exists(select 1 from public.purchase_orders where root_po_id=p.root_po_id and revision_number>0 and status='DRAFT')then raise exception'An open Draft revision already exists';end if;
 select coalesce(max(revision_number),0)+1 into v_revision from public.purchase_orders where root_po_id=p.root_po_id;
 v_number:=(select po_number from public.purchase_orders where id=p.root_po_id)||'-Revised-'||lpad(v_revision::text,greatest(2,length(v_revision::text)),'0');
 insert into public.purchase_orders(po_number,po_date,requisition_id,indent_id,supplier_id,supplier_code_snapshot,supplier_name_snapshot,supplier_gstin_snapshot,supplier_address_snapshot,supplier_contact_snapshot,supplier_phone_snapshot,supplier_email_snapshot,billing_address_snapshot,delivery_address_snapshot,payment_terms,delivery_terms,expected_delivery_date,remarks,terms_conditions,gst_rate,subtotal,gst_amount,freight_amount,grand_total,status,created_by,updated_by,root_po_id,parent_po_id,revision_number,revision_reason,revised_at,revised_by)
 select v_number,po_date,requisition_id,indent_id,supplier_id,supplier_code_snapshot,supplier_name_snapshot,supplier_gstin_snapshot,supplier_address_snapshot,supplier_contact_snapshot,supplier_phone_snapshot,supplier_email_snapshot,billing_address_snapshot,delivery_address_snapshot,payment_terms,delivery_terms,expected_delivery_date,remarks,terms_conditions,gst_rate,subtotal,gst_amount,freight_amount,grand_total,'DRAFT',auth.uid(),auth.uid(),root_po_id,id,v_revision,trim(p_reason),now(),auth.uid() from public.purchase_orders where id=p.id returning id into v_id;
 insert into public.purchase_order_items(purchase_order_id,requisition_item_id,indent_item_id,line_number,item_id,item_code_snapshot,item_name_snapshot,description_snapshot,hsn_code_snapshot,unit_snapshot,pon_quantity,quantity,unit_rate,line_amount,expected_delivery_date,remarks,root_po_item_id)
 select v_id,requisition_item_id,indent_item_id,line_number,item_id,item_code_snapshot,item_name_snapshot,description_snapshot,hsn_code_snapshot,unit_snapshot,pon_quantity,quantity,unit_rate,line_amount,expected_delivery_date,remarks,root_po_item_id from public.purchase_order_items where purchase_order_id=p.id order by line_number;
 insert into public.purchase_order_activities(purchase_order_id,activity_type,description,created_by)values(v_id,'PO_REVISION_CREATED','Revision '||lpad(v_revision::text,greatest(2,length(v_revision::text)),'0')||' created. Reason: '||trim(p_reason),auth.uid());
 insert into public.purchase_order_activities(purchase_order_id,activity_type,description,created_by)values(p.id,'PO_REVISION_CREATED','Revision '||v_number||' created. Reason: '||trim(p_reason),auth.uid());
 return v_id;
end$$;
create or replace function public.authorized_confirm_purchase_order(p_id uuid)returns void language plpgsql security definer set search_path=''as $$
declare p public.purchase_orders%rowtype;prior_id uuid;
begin
 if not public.has_erp_permission('purchase.orders','EDIT')then raise exception'Purchase Orders edit permission required';end if;
 perform public.assert_purchase_order_unapproved(p_id);
 perform pg_advisory_xact_lock(hashtextextended((select root_po_id::text from public.purchase_orders where id=p_id),0));
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
create or replace function public.authorized_save_purchase_order(p_id uuid,p_header jsonb,p_items jsonb)returns uuid language plpgsql security definer set search_path=''as $$
declare result uuid;
begin
 if not public.has_erp_permission('purchase.orders','EDIT')then raise exception'Purchase Orders edit permission required';end if;
 perform public.assert_purchase_order_unapproved(p_id);
 result:=public.save_purchase_order(p_id,p_header,p_items);
 if exists(select 1 from public.purchase_order_items poi where poi.purchase_order_id=p_id and poi.quantity<coalesce((select sum(mri.received_quantity)from public.material_receipt_items mri join public.material_receipts mr on mr.id=mri.material_receipt_id join public.purchase_order_items family_item on family_item.id=mri.purchase_order_item_id where family_item.root_po_item_id=poi.root_po_item_id and mr.status='CONFIRMED'),0))then raise exception'Revised ordered quantity cannot be below quantity already received';end if;
 return result;
end$$;

create or replace function public.audit_purchase_order_approval_flow() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if old.status='DRAFT' and new.status='CONFIRMED' then
  insert into public.purchase_order_activities(purchase_order_id,activity_type,description,created_by)
  values(new.id,'SENT_FOR_MANAGEMENT_APPROVAL','Purchase Order sent for Management Approval',coalesce(auth.uid(),new.confirmed_by,new.created_by));
 elsif old.status<>'FULLY_RECEIVED' and new.status='FULLY_RECEIVED' then
  insert into public.purchase_order_activities(purchase_order_id,activity_type,description,created_by)
  values(new.id,'COMPLETED','Purchase Order completed; all ordered material received',coalesce(auth.uid(),new.created_by));
 end if;
 return new;
end $$;
create trigger purchase_orders_approval_flow_audit after update of status on public.purchase_orders
 for each row execute function public.audit_purchase_order_approval_flow();
insert into public.purchase_order_activities(purchase_order_id,activity_type,description,created_by)
 select p.id,'SENT_FOR_MANAGEMENT_APPROVAL','Purchase Order sent for Management Approval',coalesce(p.confirmed_by,p.created_by)
 from public.purchase_orders p where p.status='CONFIRMED' and p.approval_source is null
 and not exists(select 1 from public.purchase_order_activities a where a.purchase_order_id=p.id and a.activity_type='SENT_FOR_MANAGEMENT_APPROVAL');
create or replace function public.audit_purchase_order_inventory_posting() returns trigger
language plpgsql security definer set search_path='' as $$
declare target_id uuid;receipt_number text;
begin
 select p.id into target_id from public.purchase_orders p where p.root_po_id=(select root_po_id from public.purchase_orders where id=new.purchase_order_id)
 and p.status in('CONFIRMED','APPROVED','PARTIALLY_RECEIVED','FULLY_RECEIVED','CLOSED') order by revision_number desc limit 1;
 select r.receipt_number into receipt_number from public.material_receipts r where r.id=new.material_receipt_id;
 insert into public.purchase_order_activities(purchase_order_id,activity_type,description,created_by)
 values(coalesce(target_id,new.purchase_order_id),'INVENTORY_POSTED',new.quantity||' posted to Inventory from Material Receipt '||receipt_number,new.posted_by);
 return new;
end $$;
create trigger purchase_orders_inventory_posting_audit after insert on public.material_receipt_inventory_postings
 for each row execute function public.audit_purchase_order_inventory_posting();
revoke all on function public.audit_purchase_order_approval_flow(),public.audit_purchase_order_inventory_posting() from public,anon,authenticated;
commit;
