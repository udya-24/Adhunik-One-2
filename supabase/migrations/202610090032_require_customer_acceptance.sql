-- Packing and dispatch require acceptance of the latest PI revision. No table changes.
begin;

create or replace function public.is_pi_accepted(p_pi_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.proforma_invoices p
 where p.id=p_pi_id and p.status='ACCEPTED' and p.deleted_at is null
 and not exists(select 1 from public.proforma_invoices newer
 where newer.root_pi_id=p.root_pi_id and newer.revision_number>p.revision_number and newer.deleted_at is null))
$$;

-- Hold the PI row until the transaction completes, serializing with revision/acceptance.
create or replace function public.require_accepted_pi(p_pi_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.proforma_invoices where id=p_pi_id for update;
 if not public.is_pi_accepted(p_pi_id) then
  raise exception 'The latest PI revision must be Accepted before packing or dispatch';
 end if;
end;
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
  where public.is_pi_accepted(pi.id)
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
    where id=p_pi_id and status='ACCEPTED' and deleted_at is null for update;
  if not found then raise exception 'Only an Accepted PI can be packed';end if;
  perform public.require_accepted_pi(p_pi_id);
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

create or replace function public.create_proforma_invoice_revision(p_pi_id uuid,p_reason text)returns uuid language plpgsql security definer set search_path='' as $$
declare p public.proforma_invoices%rowtype;v_root uuid;v_revision int;v_id uuid;
begin
 if nullif(trim(p_reason),'')is null then raise exception 'Revision reason is required';end if;select * into p from public.proforma_invoices where id=p_pi_id and status in('ISSUED','ACCEPTED')and public.can_view_proforma_invoice(id) for update;if not found then raise exception 'Issued PI not found or not accessible';end if;if not(public.can_manage_crm()or p.created_by=auth.uid()or p.salesperson_id=auth.uid())then raise exception 'You cannot revise this PI';end if;
 v_root:=p.root_pi_id;perform pg_advisory_xact_lock(hashtextextended(v_root::text,0));select coalesce(max(revision_number),0)+1 into v_revision from public.proforma_invoices where root_pi_id=v_root;
 update public.proforma_invoices set status='REVISED',updated_by=auth.uid(),updated_at=now()where root_pi_id=v_root and status in('ISSUED','ACCEPTED');
 insert into public.proforma_invoices(pi_number,order_id,company_id,contact_id,pi_date,our_reference_number,dp_code,project_name,customer_po_number,customer_po_date,billing_address_id,shipping_address_id,billing_address_snapshot,shipping_address_snapshot,customer_name_snapshot,customer_gstin_snapshot,customer_phone_snapshot,customer_email_snapshot,payment_term_id,payment_terms_snapshot,delivery_terms,validity_text,freight_amount,freight_remark,gst_percentage,subtotal,discount_total,taxable_total,gst_amount,grand_total,currency,status,salesperson_id,created_by,updated_by,root_pi_id,revised_from_id,revision_number,revision_reason,document_configuration_snapshot)
 select pi_number,order_id,company_id,contact_id,current_date,our_reference_number,dp_code,project_name,customer_po_number,customer_po_date,billing_address_id,shipping_address_id,billing_address_snapshot,shipping_address_snapshot,customer_name_snapshot,customer_gstin_snapshot,customer_phone_snapshot,customer_email_snapshot,payment_term_id,payment_terms_snapshot,delivery_terms,validity_text,freight_amount,freight_remark,gst_percentage,subtotal,discount_total,taxable_total,gst_amount,grand_total,currency,'ISSUED',salesperson_id,auth.uid(),auth.uid(),v_root,p.id,v_revision,trim(p_reason),document_configuration_snapshot from public.proforma_invoices where id=p.id returning id into v_id;
 insert into public.proforma_invoice_items(proforma_invoice_id,line_number,inventory_item_id,item_name,item_description,model_type,hsn_code,unit,quantity,unit_price,discount_percentage,gross_amount,discount_amount,line_total,sort_order)select v_id,line_number,inventory_item_id,item_name,item_description,model_type,hsn_code,unit,quantity,unit_price,discount_percentage,gross_amount,discount_amount,line_total,sort_order from public.proforma_invoice_items where proforma_invoice_id=p.id;
 update public.proforma_invoices set shipping_contact_number=p.shipping_contact_number,other_remarks=p.other_remarks,issued_at=now(),issued_by=auth.uid(),accepted_at=null,accepted_by=null where id=v_id;
 insert into public.proforma_invoice_activities(proforma_invoice_id,activity_type,description,created_by)values(v_id,'REVISION_CREATED','Revision '||v_revision||' created: '||trim(p_reason),auth.uid());return v_id;
end;$$;

create or replace function public.can_manage_proforma_invoice(p_pi_id uuid)returns boolean language sql stable security definer set search_path='' as $$select exists(select 1 from public.proforma_invoices p where p.id=p_pi_id and p.deleted_at is null and (p.status='DRAFT' or (p.status='ISSUED' and p.revision_number>0 and p.accepted_at is null)) and(public.can_manage_crm() or p.created_by=auth.uid() or p.salesperson_id=auth.uid()))$$;

create or replace function public.prepare_pi_update()returns trigger language plpgsql security definer set search_path='' as $$
begin
 new.pi_number:=old.pi_number;new.order_id:=old.order_id;new.company_id:=old.company_id;new.root_pi_id:=old.root_pi_id;new.revision_number:=old.revision_number;new.revised_from_id:=old.revised_from_id;new.revision_reason:=old.revision_reason;new.created_by:=old.created_by;new.created_at:=old.created_at;
 if not (old.status='DRAFT' or (old.status='ISSUED' and old.revision_number>0 and old.accepted_at is null and new.status='ISSUED'))then
  new.contact_id:=old.contact_id;new.pi_date:=old.pi_date;new.our_reference_number:=old.our_reference_number;new.dp_code:=old.dp_code;new.project_name:=old.project_name;new.customer_po_number:=old.customer_po_number;new.customer_po_date:=old.customer_po_date;new.billing_address_id:=old.billing_address_id;new.shipping_address_id:=old.shipping_address_id;new.billing_address_snapshot:=old.billing_address_snapshot;new.shipping_address_snapshot:=old.shipping_address_snapshot;new.customer_name_snapshot:=old.customer_name_snapshot;new.customer_gstin_snapshot:=old.customer_gstin_snapshot;new.customer_phone_snapshot:=old.customer_phone_snapshot;new.customer_email_snapshot:=old.customer_email_snapshot;new.payment_term_id:=old.payment_term_id;new.payment_terms_snapshot:=old.payment_terms_snapshot;new.delivery_terms:=old.delivery_terms;new.validity_text:=old.validity_text;new.freight_amount:=old.freight_amount;new.freight_remark:=old.freight_remark;new.gst_percentage:=old.gst_percentage;new.subtotal:=old.subtotal;new.discount_total:=old.discount_total;new.taxable_total:=old.taxable_total;new.gst_amount:=old.gst_amount;new.grand_total:=old.grand_total;new.currency:=old.currency;new.salesperson_id:=old.salesperson_id;new.document_configuration_snapshot:=old.document_configuration_snapshot;
 end if;
 if old.status in('ACCEPTED','REVISED','CANCELLED') then new.shipping_contact_number:=old.shipping_contact_number;new.other_remarks:=old.other_remarks;end if;return new;
end;$$;

create or replace function public.save_proforma_invoice_extras(
  p_pi_id uuid,
  p_shipping_contact_number text,
  p_other_remarks text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.proforma_invoices
     set shipping_contact_number = p_shipping_contact_number,
         other_remarks = p_other_remarks,
         updated_by = auth.uid(),
         updated_at = now()
   where id = p_pi_id
     and public.can_manage_proforma_invoice(id);
  if not found then
    raise exception 'Draft PI not found or not editable';
  end if;
end;
$$;

create or replace function public.can_manage_packing_list(p_id uuid)
returns boolean language sql stable security definer set search_path='' as $$
  select exists(
    select 1
    from public.packing_lists p
    where p.id=p_id
      and p.status='DRAFT' and public.is_pi_accepted(p.pi_id)
      and public.has_erp_permission('dispatch.packing_lists','EDIT')
  )
$$;

create or replace function public.create_dispatch(p_packing_list_id uuid)returns uuid language plpgsql security definer set search_path=''as $$
declare p public.packing_lists%rowtype;v_id uuid;v_location uuid;
begin
 if not public.has_active_erp_access()then raise exception 'Active ERP access is required';end if;
 select * into p from public.packing_lists where id=p_packing_list_id and status in('FINALIZED','PARTIALLY_DISPATCHED')and public.can_view_packing_list(id)for update;
 if not found then raise exception 'Only an accessible Finalized Packing List with available packages can be dispatched';end if;
 perform public.require_accepted_pi(p.pi_id);
 if not exists(select 1 from public.packing_list_packages k where k.packing_list_id=p.id and not exists(select 1 from public.dispatch_packages dp join public.dispatches d on d.id=dp.dispatch_id where dp.packing_list_package_id=k.id and dp.is_committed and d.status='DISPATCHED'))then raise exception 'Packing List has no packages available for Dispatch';end if;
 select id into v_location from public.stock_locations where is_default and is_active;
 insert into public.dispatches(dispatch_number,company_id,order_id,pi_id,packing_list_id,stock_location_id,customer_name_snapshot,pi_number_snapshot,order_number_snapshot,packing_list_number_snapshot,customer_po_number_snapshot,project_name_snapshot,shipping_address_snapshot,created_by,updated_by)
 values(public.allocate_business_number('DISPATCH'),p.company_id,p.order_id,p.pi_id,p.id,v_location,p.customer_name_snapshot,p.pi_number_snapshot,p.order_number_snapshot,p.packing_list_number,p.customer_po_number_snapshot,p.project_name_snapshot,p.shipping_address_snapshot,auth.uid(),auth.uid())returning id into v_id;
 insert into public.dispatch_activities(dispatch_id,activity_type,description,created_by)values(v_id,'CREATED','Dispatch Draft created from Packing List '||p.packing_list_number,auth.uid());return v_id;
end;$$;

create or replace function public.finalize_packing_list(p_id uuid)returns void language plpgsql security definer set search_path = '' as $$declare vpi uuid;r record;begin select pi_id into vpi from public.packing_lists where id=p_id and public.can_manage_packing_list(id)for update;if not found then raise exception 'Draft Packing List not editable';end if;perform pg_advisory_xact_lock(hashtextextended(vpi::text,0));perform public.require_accepted_pi(vpi);if not exists(select 1 from public.packing_list_items where packing_list_id=p_id and current_packing_quantity>0)then raise exception 'Select a packing quantity';end if;for r in select i.id,i.pi_item_id,i.pi_quantity,i.current_packing_quantity,coalesce((select sum(x.current_packing_quantity)from public.packing_list_items x join public.packing_lists p on p.id=x.packing_list_id where x.pi_item_id=i.pi_item_id and p.status in('FINALIZED','PARTIALLY_DISPATCHED','DISPATCHED')and p.id<>p_id),0)packed,coalesce((select sum(c.quantity)from public.packing_list_package_contents c join public.packing_list_packages k on k.id=c.package_id where c.packing_list_item_id=i.id and k.packing_list_id=p_id),0)allocated from public.packing_list_items i where i.packing_list_id=p_id loop if r.packed+r.current_packing_quantity>r.pi_quantity then raise exception 'Packing exceeds remaining PI balance';end if;if r.allocated<>r.current_packing_quantity then raise exception 'Every packing quantity must be fully allocated';end if;end loop;if exists(select 1 from public.packing_list_package_contents c join public.packing_list_packages k on k.id=c.package_id join public.packing_list_items i on i.id=c.packing_list_item_id where k.packing_list_id=p_id and i.item_volume_mm3>0 group by k.id,k.volume_mm3 having sum(c.quantity*i.item_volume_mm3)>k.volume_mm3)then raise exception 'Allocated theoretical item volume exceeds package volume';end if;if exists(select 1 from public.packing_list_package_contents c join public.packing_list_packages k on k.id=c.package_id join public.packing_list_items i on i.id=c.packing_list_item_id where k.packing_list_id=p_id and i.item_length_mm>0 and i.item_breadth_mm>0 and i.item_height_mm>0 and not((i.item_length_mm<=k.length_mm and i.item_breadth_mm<=k.breadth_mm and i.item_height_mm<=k.height_mm)or(i.item_length_mm<=k.length_mm and i.item_height_mm<=k.breadth_mm and i.item_breadth_mm<=k.height_mm)or(i.item_breadth_mm<=k.length_mm and i.item_length_mm<=k.breadth_mm and i.item_height_mm<=k.height_mm)or(i.item_breadth_mm<=k.length_mm and i.item_height_mm<=k.breadth_mm and i.item_length_mm<=k.height_mm)or(i.item_height_mm<=k.length_mm and i.item_length_mm<=k.breadth_mm and i.item_breadth_mm<=k.height_mm)or(i.item_height_mm<=k.length_mm and i.item_breadth_mm<=k.breadth_mm and i.item_length_mm<=k.height_mm)))then raise exception 'Item dimensions exceed package dimensions';end if;update public.packing_lists set status='FINALIZED',finalized_by=auth.uid(),finalized_at=now(),updated_by=auth.uid(),updated_at=now()where id=p_id;insert into public.packing_list_activities values(default,p_id,'FINALIZED','Packing List finalized',auth.uid(),default);end; $$;

create or replace function public.confirm_dispatch(p_id uuid)returns void language plpgsql security definer set search_path=''as $$
declare d public.dispatches%rowtype;v_ids uuid[];r record;
begin
 if not public.can_manage_crm()then raise exception 'Manager or Admin access is required to confirm Dispatch';end if;
 select * into d from public.dispatches where id=p_id and status='DRAFT'and public.can_view_dispatch(id)for update;if not found then raise exception 'Dispatch Draft not found or inaccessible';end if;
 perform public.require_accepted_pi(d.pi_id);
 perform pg_advisory_xact_lock(hashtextextended(d.packing_list_id::text,0));
 if not exists(select 1 from public.packing_lists where id=d.packing_list_id and status in('FINALIZED','PARTIALLY_DISPATCHED'))then raise exception 'Packing List is not eligible for Dispatch';end if;
 select array_agg(packing_list_package_id order by packing_list_package_id)into v_ids from public.dispatch_packages where dispatch_id=p_id;if coalesce(cardinality(v_ids),0)=0 then raise exception 'Select at least one package';end if;
 perform 1 from public.packing_list_packages where id=any(v_ids)order by id for update;
 if exists(select 1 from public.dispatch_packages dp join public.dispatches dx on dx.id=dp.dispatch_id where dp.packing_list_package_id=any(v_ids)and dp.is_committed and dx.status='DISPATCHED'and dx.id<>p_id)then raise exception 'A selected package has already been Dispatched';end if;
 if d.dispatch_date is null or d.shipping_address_snapshot='{}'::jsonb or d.transport_mode is null then raise exception 'Dispatch Date, Shipping Address and Transport Mode are required';end if;
 if exists(select 1 from public.packing_list_package_contents c join public.packing_list_packages k on k.id=c.package_id join public.packing_list_items i on i.id=c.packing_list_item_id where k.id=any(v_ids)and i.item_id is not null)and d.stock_location_id is null then raise exception 'Select the Source Stock Location for inventory-linked Items';end if;
 for r in select i.item_id,sum(c.quantity)::numeric quantity from public.packing_list_package_contents c join public.packing_list_packages k on k.id=c.package_id join public.packing_list_items i on i.id=c.packing_list_item_id where k.id=any(v_ids)and i.item_id is not null group by i.item_id loop
  perform public.post_inventory_movement('STOCK_OUT',r.item_id,d.stock_location_id,r.quantity,d.dispatch_date,'DISPATCH',d.id,d.dispatch_number,'Confirmed Dispatch',null,null,null);
 end loop;
 update public.dispatch_packages set is_committed=true,committed_at=now()where dispatch_id=p_id;
 update public.dispatches set status='DISPATCHED',confirmed_by=auth.uid(),confirmed_at=now(),updated_by=auth.uid(),updated_at=now()where id=p_id;
 insert into public.dispatch_activities(dispatch_id,activity_type,description,created_by)values(p_id,'CONFIRMED','Dispatch confirmed; packages physically dispatched and linked inventory posted',auth.uid());perform public.refresh_packing_list_dispatch_status(d.packing_list_id);
exception when unique_violation then raise exception 'Dispatch inventory or package posting was already completed concurrently';
end;$$;

create or replace function public.accept_proforma_invoice(p_pi_id uuid)returns void language plpgsql security definer set search_path='' as $$begin update public.proforma_invoices set status='ACCEPTED',accepted_at=now(),accepted_by=auth.uid(),updated_at=now(),updated_by=auth.uid()where id=p_pi_id and status='ISSUED' and deleted_at is null and not exists(select 1 from public.proforma_invoices newer where newer.root_pi_id=proforma_invoices.root_pi_id and newer.revision_number>proforma_invoices.revision_number and newer.deleted_at is null)and(public.can_manage_crm()or created_by=auth.uid()or salesperson_id=auth.uid());if not found then raise exception 'Issued PI not found or not acceptable';end if;insert into public.proforma_invoice_activities(proforma_invoice_id,activity_type,description,created_by)values(p_pi_id,'ACCEPTED','PI marked Accepted',auth.uid());end;$$;

create or replace function public.save_dispatch(p_id uuid,p_data jsonb,p_package_ids uuid[])returns void language plpgsql security definer set search_path=''as $$
declare d public.dispatches%rowtype;v_old int;v_new int;v_location uuid;
begin
 select * into d from public.dispatches where id=p_id and public.can_manage_dispatch(id)for update;if not found then raise exception 'Dispatch Draft not found or not editable';end if;
 perform public.require_accepted_pi(d.pi_id);
 if p_package_ids is null then p_package_ids:=array[]::uuid[];end if;if exists(select 1 from unnest(p_package_ids)x group by x having count(*)>1)then raise exception 'A package was selected more than once';end if;
 if exists(select 1 from unnest(p_package_ids)x where not exists(select 1 from public.packing_list_packages p where p.id=x and p.packing_list_id=d.packing_list_id))then raise exception 'Selected package does not belong to this Packing List';end if;
 if exists(select 1 from unnest(p_package_ids)x where exists(select 1 from public.dispatch_packages dp join public.dispatches dx on dx.id=dp.dispatch_id where dp.packing_list_package_id=x and dp.is_committed and dx.status='DISPATCHED'and dx.id<>p_id))then raise exception 'A selected package is already Dispatched';end if;
 v_location:=nullif(p_data->>'stock_location_id','')::uuid;if v_location is not null and not exists(select 1 from public.stock_locations where id=v_location and is_active)then raise exception 'Select an active Stock Location';end if;
 select count(*)into v_old from public.dispatch_packages where dispatch_id=p_id;delete from public.dispatch_packages where dispatch_id=p_id;insert into public.dispatch_packages(dispatch_id,packing_list_package_id)select p_id,x from unnest(p_package_ids)x;v_new:=cardinality(p_package_ids);
 update public.dispatches set dispatch_date=coalesce(nullif(p_data->>'dispatch_date','')::date,dispatch_date),stock_location_id=v_location,shipping_address_snapshot=coalesce(p_data->'shipping_address',shipping_address_snapshot),transport_mode=nullif(p_data->>'transport_mode',''),transporter_name=nullif(trim(p_data->>'transporter_name'),''),transporter_contact=nullif(trim(p_data->>'transporter_contact'),''),vehicle_number=upper(nullif(trim(p_data->>'vehicle_number'),'')),driver_name=nullif(trim(p_data->>'driver_name'),''),driver_contact=nullif(trim(p_data->>'driver_contact'),''),lr_gr_number=nullif(trim(p_data->>'lr_gr_number'),''),lr_gr_date=nullif(p_data->>'lr_gr_date','')::date,tracking_awb_number=nullif(trim(p_data->>'tracking_awb_number'),''),freight_type=nullif(p_data->>'freight_type',''),freight_amount=coalesce(nullif(p_data->>'freight_amount','')::numeric,0),freight_paid_by=nullif(p_data->>'freight_paid_by',''),eway_bill_number=nullif(trim(p_data->>'eway_bill_number'),''),eway_bill_date=nullif(p_data->>'eway_bill_date','')::date,eway_bill_expiry_date=nullif(p_data->>'eway_bill_expiry_date','')::date,remarks=nullif(p_data->>'remarks',''),total_packages=v_new,total_net_weight=coalesce((select sum(coalesce(k.net_weight_kg,0))from public.packing_list_packages k where k.id=any(p_package_ids)),0),total_gross_weight=coalesce((select sum(coalesce(k.gross_weight_kg,0))from public.packing_list_packages k where k.id=any(p_package_ids)),0),updated_by=auth.uid(),updated_at=now()where id=p_id;
 insert into public.dispatch_activities(dispatch_id,activity_type,description,created_by)values(p_id,'EDITED','Dispatch Draft updated',auth.uid());if v_new>v_old then insert into public.dispatch_activities(dispatch_id,activity_type,description,created_by)values(p_id,'PACKAGE_ADDED',(v_new-v_old)||' package(s) added',auth.uid());elsif v_new<v_old then insert into public.dispatch_activities(dispatch_id,activity_type,description,created_by)values(p_id,'PACKAGE_REMOVED',(v_old-v_new)||' package(s) removed',auth.uid());end if;
end;$$;

revoke all on function public.require_accepted_pi(uuid) from public,anon,authenticated;
revoke all on function public.is_pi_accepted(uuid) from public,anon;
grant execute on function public.is_pi_accepted(uuid) to authenticated;
commit;
