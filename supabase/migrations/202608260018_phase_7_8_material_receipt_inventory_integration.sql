-- Adhunik ERP - Phase 7 / Phase 8 Material Receipt to Inventory integration
begin;
create table public.material_receipt_inventory_postings(
 id uuid primary key default gen_random_uuid(),material_receipt_id uuid not null references public.material_receipts(id) on delete restrict,
 material_receipt_item_id uuid not null references public.material_receipt_items(id) on delete restrict,inventory_transaction_id uuid not null unique references public.inventory_transactions(id) on delete restrict,
 purchase_order_id uuid not null references public.purchase_orders(id) on delete restrict,supplier_id uuid not null references public.suppliers(id) on delete restrict,
 posting_request_id uuid not null,quantity numeric(24,6) not null check(quantity>0),posted_by uuid not null references auth.users(id) on delete restrict default auth.uid(),posted_at timestamptz not null default now(),
 unique(material_receipt_item_id,posting_request_id)
);
create index material_receipt_inventory_postings_receipt on public.material_receipt_inventory_postings(material_receipt_id,posted_at desc);
create index material_receipt_inventory_postings_item on public.material_receipt_inventory_postings(material_receipt_item_id);
create index material_receipt_inventory_postings_request on public.material_receipt_inventory_postings(material_receipt_id,posting_request_id);
alter table public.material_receipt_inventory_postings enable row level security;
create policy erp_read_receipt_inventory_postings on public.material_receipt_inventory_postings for select to authenticated using(public.has_active_erp_access());
grant select on public.material_receipt_inventory_postings to authenticated;
create function public.post_material_receipt_to_inventory(p_receipt_id uuid,p_location_id uuid,p_items jsonb,p_request_id uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare r public.material_receipts%rowtype;ri public.material_receipt_items%rowtype;x jsonb;requested numeric;posted numeric;transaction_id uuid;posted_lines integer:=0;result_status text;
begin
 if not public.has_active_erp_access() then raise exception 'Active ERP access with Inventory Stock In permission is required';end if;
 if p_request_id is null then raise exception 'Posting request ID is required';end if;
 select * into r from public.material_receipts where id=p_receipt_id for update;
 if not found then raise exception 'Material Receipt not found';end if;
 if r.status<>'CONFIRMED' then raise exception 'Only confirmed Material Receipts can be posted to Inventory';end if;
 if exists(select 1 from public.material_receipt_inventory_postings where material_receipt_id=r.id and posting_request_id=p_request_id) then
  select case when not exists(select 1 from public.material_receipt_items i where i.material_receipt_id=r.id and i.accepted_quantity>coalesce((select sum(p.quantity) from public.material_receipt_inventory_postings p where p.material_receipt_item_id=i.id),0)) then 'FULLY_POSTED' when exists(select 1 from public.material_receipt_inventory_postings p where p.material_receipt_id=r.id) then 'PARTIALLY_POSTED' else 'NOT_POSTED' end into result_status;
  return jsonb_build_object('receipt_id',r.id,'status',result_status,'idempotent_replay',true);
 end if;
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'At least one Stock In quantity is required';end if;
 for x in select value from jsonb_array_elements(p_items) loop
  requested:=coalesce(nullif(x->>'quantity','')::numeric,0);
  if requested<0 then raise exception 'Stock In quantity cannot be negative';end if;
  if requested>0 then
   select * into ri from public.material_receipt_items where id=(x->>'material_receipt_item_id')::uuid and material_receipt_id=r.id for update;
   if not found then raise exception 'Invalid Material Receipt item';end if;
   if ri.item_id is null then raise exception 'Item % is not linked to Item Master and cannot be posted',ri.item_name_snapshot;end if;
   select coalesce(sum(p.quantity),0) into posted from public.material_receipt_inventory_postings p where p.material_receipt_item_id=ri.id;
   if requested>ri.accepted_quantity-posted then raise exception 'Stock In quantity for % exceeds remaining accepted quantity of %',ri.item_name_snapshot,ri.accepted_quantity-posted;end if;
   transaction_id:=public.post_inventory_movement('STOCK_IN',ri.item_id,p_location_id,requested,r.receipt_date,'MATERIAL_RECEIPT',r.id,r.receipt_number,'Accepted material posted from Material Receipt','PO '||(select po_number from public.purchase_orders where id=r.purchase_order_id)||' - Supplier '||r.supplier_name_snapshot,null,null);
   insert into public.material_receipt_inventory_postings(material_receipt_id,material_receipt_item_id,inventory_transaction_id,purchase_order_id,supplier_id,posting_request_id,quantity,posted_by) values(r.id,ri.id,transaction_id,r.purchase_order_id,r.supplier_id,p_request_id,requested,auth.uid());
   insert into public.material_receipt_activities(material_receipt_id,activity_type,description,created_by) values(r.id,'INVENTORY_POSTED_FROM_MATERIAL_RECEIPT',requested||' '||ri.unit_snapshot||' of '||ri.item_name_snapshot||' posted to Inventory',auth.uid());
   posted_lines:=posted_lines+1;
  end if;
 end loop;
 if posted_lines=0 then raise exception 'Enter at least one Stock In quantity greater than zero';end if;
 select case when not exists(select 1 from public.material_receipt_items i where i.material_receipt_id=r.id and i.accepted_quantity>coalesce((select sum(p.quantity) from public.material_receipt_inventory_postings p where p.material_receipt_item_id=i.id),0)) then 'FULLY_POSTED' when exists(select 1 from public.material_receipt_inventory_postings p where p.material_receipt_id=r.id) then 'PARTIALLY_POSTED' else 'NOT_POSTED' end into result_status;
 return jsonb_build_object('receipt_id',r.id,'status',result_status,'posted_lines',posted_lines,'idempotent_replay',false);
end;$$;
revoke all on function public.post_material_receipt_to_inventory(uuid,uuid,jsonb,uuid) from public,anon;
grant execute on function public.post_material_receipt_to_inventory(uuid,uuid,jsonb,uuid) to authenticated;
create or replace function public.cancel_material_receipt(p_id uuid,p_reason text)returns void language plpgsql security definer set search_path=''as $$
declare po uuid;
begin
 if not public.is_erp_manager()or nullif(trim(p_reason),'')is null then raise exception'Authorization and reason required';end if;
 perform 1 from public.material_receipts where id=p_id for update;
 if exists(select 1 from public.material_receipt_inventory_postings where material_receipt_id=p_id)then raise exception'Inventory has already been posted from this Material Receipt. Reverse the inventory transaction before cancelling the receipt.';end if;
 update public.material_receipts set status='CANCELLED',cancelled_at=now(),cancelled_by=auth.uid(),cancellation_reason=trim(p_reason)where id=p_id and status='CONFIRMED'returning purchase_order_id into po;
 if po is null then raise exception'Receipt cannot be cancelled';end if;
 insert into public.material_receipt_activities values(default,p_id,'CANCELLED','Material Receipt cancelled: '||trim(p_reason),auth.uid(),default);
 perform public.refresh_purchase_order_receipt_status(po);
end$$;
comment on function public.post_material_receipt_to_inventory(uuid,uuid,jsonb,uuid) is 'Atomically posts reviewed accepted MR quantities through the Phase 7 inventory engine with locking and idempotency.';
commit;
