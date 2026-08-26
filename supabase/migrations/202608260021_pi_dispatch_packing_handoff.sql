-- Adhunik ERP - PI to Dispatch packing handoff
begin;

create or replace function public.can_view_packing_list(p_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1
    from public.packing_lists p
    where p.id=p_id
      and (
        public.has_erp_permission('dispatch.packing_lists','VIEW')
        or public.can_view_proforma_invoice(p.pi_id)
      )
  )
$$;

create or replace function public.can_manage_packing_list(p_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1
    from public.packing_lists p
    where p.id=p_id
      and p.status='DRAFT'
      and public.has_erp_permission('dispatch.packing_lists','EDIT')
  )
$$;

create or replace function public.get_awaiting_packing()
returns table(
  id uuid,
  pi_number text,
  pi_date date,
  customer_name text,
  order_number text,
  total_items bigint,
  total_quantity numeric,
  remaining_quantity numeric,
  packing_status text
)
language plpgsql stable security definer set search_path='' as $$
begin
  if not public.has_erp_permission('dispatch.packing_lists','VIEW') then
    raise exception 'Packing Lists view permission required';
  end if;

  return query
  with packed as (
    select pli.pi_item_id,sum(pli.current_packing_quantity) quantity
    from public.packing_list_items pli
    join public.packing_lists pl on pl.id=pli.packing_list_id
    where pl.status in('FINALIZED','PARTIALLY_DISPATCHED','DISPATCHED')
    group by pli.pi_item_id
  )
  select
    pi.id,
    pi.pi_number,
    pi.pi_date,
    pi.customer_name_snapshot,
    o.order_number,
    count(pii.id),
    coalesce(sum(pii.quantity),0),
    coalesce(sum(greatest(pii.quantity-coalesce(packed.quantity,0),0)),0),
    'AWAITING PACKING'::text
  from public.proforma_invoices pi
  join public.orders o on o.id=pi.order_id
  join public.proforma_invoice_items pii on pii.proforma_invoice_id=pi.id
  left join packed on packed.pi_item_id=pii.id
  where pi.status in('ISSUED','ACCEPTED')
    and pi.deleted_at is null
    and not exists(
      select 1 from public.packing_lists draft
      where draft.pi_id=pi.id and draft.status='DRAFT'
    )
  group by pi.id,pi.pi_number,pi.pi_date,pi.customer_name_snapshot,o.order_number
  having sum(greatest(pii.quantity-coalesce(packed.quantity,0),0))>0
  order by pi.pi_date,pi.pi_number;
end
$$;

create or replace function public.create_packing_list(p_pi_id uuid)
returns uuid language plpgsql security definer set search_path='' as $$
declare p public.proforma_invoices%rowtype;o public.orders%rowtype;v uuid;
begin
  if not public.has_erp_permission('dispatch.packing_lists','EDIT') then
    raise exception 'Packing Lists edit permission required';
  end if;
  perform pg_advisory_xact_lock(hashtextextended(p_pi_id::text,0));
  select * into p from public.proforma_invoices
    where id=p_pi_id and status in('ISSUED','ACCEPTED') and deleted_at is null;
  if not found then raise exception 'Only an Issued or Accepted PI can be packed';end if;
  if exists(select 1 from public.packing_lists where pi_id=p_pi_id and status='DRAFT') then
    raise exception 'This PI already has a draft Packing List';
  end if;
  if not exists(
    select 1 from public.proforma_invoice_items pii
    where pii.proforma_invoice_id=p_pi_id
      and pii.quantity>coalesce((
        select sum(pli.current_packing_quantity)
        from public.packing_list_items pli
        join public.packing_lists pl on pl.id=pli.packing_list_id
        where pli.pi_item_id=pii.id
          and pl.status in('FINALIZED','PARTIALLY_DISPATCHED','DISPATCHED')
      ),0)
  ) then raise exception 'This PI is already fully packed';end if;
  select * into o from public.orders where id=p.order_id;
  insert into public.packing_lists(packing_list_number,pi_id,order_id,company_id,customer_name_snapshot,pi_number_snapshot,order_number_snapshot,customer_po_number_snapshot,project_name_snapshot,shipping_address_snapshot,created_by,updated_by)
  values(public.allocate_business_number('PACKING_LIST'),p.id,p.order_id,p.company_id,p.customer_name_snapshot,p.pi_number,o.order_number,p.customer_po_number,p.project_name,p.shipping_address_snapshot,auth.uid(),auth.uid()) returning id into v;
  insert into public.packing_list_items(packing_list_id,pi_item_id,line_number,item_name_snapshot,item_description_snapshot,model_snapshot,hsn_snapshot,unit_snapshot,pi_quantity,item_id,unit_weight_kg,item_length_mm,item_breadth_mm,item_height_mm,sort_order)
  select v,pii.id,pii.line_number,pii.item_name,pii.item_description,pii.model_type,pii.hsn_code,pii.unit,pii.quantity,pii.inventory_item_id,i.unit_weight_kg,i.length_mm,i.breadth_mm,i.height_mm,pii.sort_order
  from public.proforma_invoice_items pii left join public.items i on i.id=pii.inventory_item_id
  where pii.proforma_invoice_id=p.id;
  insert into public.packing_list_activities values(default,v,'CREATED','Packing List created from PI '||p.pi_number,auth.uid(),default);
  return v;
end
$$;

create or replace function public.reopen_packing_list(p_id uuid,p_reason text)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not public.has_erp_permission('dispatch.packing_lists','EDIT') or nullif(trim(p_reason),'') is null then
    raise exception 'Packing Lists edit permission and reason required';
  end if;
  update public.packing_lists set status='DRAFT',reopened_by=auth.uid(),reopened_at=now(),reopen_reason=trim(p_reason),finalized_by=null,finalized_at=null,updated_by=auth.uid(),updated_at=now()
  where id=p_id and status='FINALIZED';
  if not found then raise exception 'Finalized Packing List not found';end if;
  insert into public.packing_list_activities values(default,p_id,'REOPENED','Reopened: '||trim(p_reason),auth.uid(),default);
end
$$;

create or replace function public.cancel_packing_list(p_id uuid,p_reason text)
returns void language plpgsql security definer set search_path='' as $$
begin
  if not public.has_erp_permission('dispatch.packing_lists','EDIT') then
    raise exception 'Packing Lists edit permission required';
  end if;
  if nullif(trim(p_reason),'') is null then raise exception 'Cancellation reason required';end if;
  update public.packing_lists set status='CANCELLED',cancelled_by=auth.uid(),cancelled_at=now(),cancellation_reason=trim(p_reason),updated_by=auth.uid(),updated_at=now()
  where id=p_id and status in('DRAFT','FINALIZED');
  if not found then raise exception 'Packing List not cancellable';end if;
  insert into public.packing_list_activities values(default,p_id,'CANCELLED','Cancelled: '||trim(p_reason),auth.uid(),default);
end
$$;

revoke all on function public.get_awaiting_packing() from public,anon;
grant execute on function public.get_awaiting_packing() to authenticated;
commit;
