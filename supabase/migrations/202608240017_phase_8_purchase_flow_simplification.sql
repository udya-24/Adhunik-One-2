-- Adhunik ERP — Phase 8 workflow correction: Purchase Indent directly to Purchase Order
begin;

alter table public.procurement_year_counters drop constraint if exists procurement_year_counters_entity_type_check;
alter table public.procurement_year_counters add constraint procurement_year_counters_entity_type_check check(entity_type in('PURCHASE_INDENT','PURCHASE_ORDER','MATERIAL_RECEIPT'));
update public.numbering_configurations set prefix='IND',separator='/',padding=4,include_year=true,include_financial_year=false,updated_at=now(),updated_by=auth.uid()where entity_type='PURCHASE_INDENT';
insert into public.procurement_year_counters(entity_type,calendar_year,current_value)
select 'PURCHASE_INDENT',substring(indent_number from '^IND/([0-9]{4})/')::integer,max(substring(indent_number from '/([0-9]+)$')::bigint)
from public.purchase_indents where indent_number~'^IND/[0-9]{4}/[0-9]+$'group by substring(indent_number from '^IND/([0-9]{4})/')::integer
on conflict(entity_type,calendar_year)do update set current_value=greatest(public.procurement_year_counters.current_value,excluded.current_value),updated_at=now();

create or replace function public.allocate_procurement_number(p_type text)returns text language plpgsql security definer set search_path=''as $$
declare y integer:=extract(year from current_date)::integer;n bigint;p text;
begin
 if p_type not in('PURCHASE_INDENT','PURCHASE_ORDER','MATERIAL_RECEIPT')then raise exception'Invalid procurement number type';end if;
 p:=case p_type when'PURCHASE_INDENT'then'IND'when'PURCHASE_ORDER'then'PO'else'MR'end;
 insert into public.procurement_year_counters values(p_type,y,1,now())on conflict(entity_type,calendar_year)do update set current_value=public.procurement_year_counters.current_value+1,updated_at=now()returning current_value into n;
 return p||'/'||y||'/'||lpad(n::text,4,'0');
end$$;
revoke all on function public.allocate_procurement_number(text)from public,anon,authenticated;

alter table public.purchase_indents drop constraint if exists purchase_indents_status_check;
alter table public.purchase_indents add constraint purchase_indents_status_check check(status in('DRAFT','SUBMITTED','CONVERTED','CONVERTED_TO_PR','CANCELLED'));

alter table public.purchase_orders alter column requisition_id drop not null;
alter table public.purchase_orders alter column supplier_id drop not null;
alter table public.purchase_orders alter column supplier_code_snapshot drop not null;
alter table public.purchase_orders alter column supplier_name_snapshot drop not null;
alter table public.purchase_order_items alter column requisition_item_id drop not null;
alter table public.purchase_order_items add column indent_item_id uuid references public.purchase_indent_items(id)on delete restrict;
create unique index purchase_orders_one_per_indent on public.purchase_orders(indent_id);
create unique index purchase_order_items_indent_source on public.purchase_order_items(indent_item_id)where indent_item_id is not null;
alter table public.purchase_order_items add constraint purchase_order_items_source_required check(requisition_item_id is not null or indent_item_id is not null);

create or replace function public.save_purchase_indent(p_id uuid,p_header jsonb,p_items jsonb)returns uuid language plpgsql security definer set search_path=''as $$declare v uuid:=p_id;fy uuid;n text;o uuid;s text;begin if not public.has_active_erp_access()then raise exception'Unauthorized';end if;if nullif(trim(p_header->>'purpose'),'')is null or nullif(p_header->>'department_id','')is null or nullif(p_header->>'required_date','')is null then raise exception'Department, required date and purpose are required';end if;perform 1 from public.purchase_normalize_items(p_items);if v is null then select id into fy from public.financial_years where is_current and is_active and deleted_at is null limit 1;n:=public.allocate_procurement_number('PURCHASE_INDENT');insert into public.purchase_indents(indent_number,financial_year_id,indent_date,department_id,requested_by,required_date,priority,purpose,remarks,created_by,updated_by)values(n,fy,coalesce(nullif(p_header->>'indent_date','')::date,current_date),(p_header->>'department_id')::uuid,auth.uid(),(p_header->>'required_date')::date,coalesce(nullif(p_header->>'priority',''),'NORMAL'),trim(p_header->>'purpose'),nullif(trim(p_header->>'remarks'),''),auth.uid(),auth.uid())returning id into v;insert into public.purchase_indent_activities(indent_id,activity_type,description,created_by)values(v,'CREATED','Draft Purchase Indent created',auth.uid());else select requested_by,status into o,s from public.purchase_indents where id=v for update;if not found or s<>'DRAFT'or(o<>auth.uid()and not public.is_erp_manager())then raise exception'Draft indent not found or unauthorized';end if;update public.purchase_indents set indent_date=coalesce(nullif(p_header->>'indent_date','')::date,indent_date),department_id=(p_header->>'department_id')::uuid,required_date=(p_header->>'required_date')::date,priority=coalesce(nullif(p_header->>'priority',''),'NORMAL'),purpose=trim(p_header->>'purpose'),remarks=nullif(trim(p_header->>'remarks'),''),updated_at=now(),updated_by=auth.uid()where id=v;delete from public.purchase_indent_items where indent_id=v;end if;insert into public.purchase_indent_items(indent_id,line_number,source_type,item_id,item_code_snapshot,item_name_snapshot,description_snapshot,hsn_code_snapshot,unit_snapshot,quantity,required_date,remarks)select v,* from public.purchase_normalize_items(p_items);return v;end$$;

create or replace function public.create_purchase_order_from_indent(p_indent_id uuid)returns uuid language plpgsql security definer set search_path=''as $$
declare h public.purchase_indents%rowtype;v uuid;n text;a text;
begin
 if not public.is_erp_manager()then raise exception'Only Admin or Manager can convert an Indent';end if;
 select * into h from public.purchase_indents where id=p_indent_id for update;if not found then raise exception'Purchase Indent not found';end if;
 select id into v from public.purchase_orders where indent_id=p_indent_id;if v is not null then return v;end if;
 if h.status<>'SUBMITTED'then raise exception'Only a submitted Purchase Indent can be converted';end if;
 if not exists(select 1 from public.purchase_indent_items where indent_id=h.id)then raise exception'Indent has no items';end if;
 select coalesce(registered_office_address,'Address not configured')into a from public.pi_document_settings where id=true;
 n:=public.allocate_procurement_number('PURCHASE_ORDER');
 insert into public.purchase_orders(po_number,po_date,requisition_id,indent_id,supplier_id,supplier_code_snapshot,supplier_name_snapshot,billing_address_snapshot,delivery_address_snapshot,expected_delivery_date,gst_rate,freight_amount,created_by,updated_by)
 values(n,current_date,null,h.id,null,null,null,coalesce(a,'Address not configured'),coalesce(a,'Address not configured'),h.required_date,0,0,auth.uid(),auth.uid())returning id into v;
 insert into public.purchase_order_items(purchase_order_id,requisition_item_id,indent_item_id,line_number,item_id,item_code_snapshot,item_name_snapshot,description_snapshot,hsn_code_snapshot,unit_snapshot,pon_quantity,quantity,unit_rate,line_amount,expected_delivery_date,remarks)
 select v,null,i.id,i.line_number,i.item_id,i.item_code_snapshot,i.item_name_snapshot,i.description_snapshot,i.hsn_code_snapshot,i.unit_snapshot,i.quantity,i.quantity,0,0,i.required_date,i.remarks from public.purchase_indent_items i where i.indent_id=h.id order by i.line_number;
 update public.purchase_indents set status='CONVERTED',updated_at=now(),updated_by=auth.uid()where id=h.id;
 insert into public.purchase_indent_activities values(default,h.id,'PO_CREATED_FROM_INDENT','Purchase Order '||n||' created directly from Indent',auth.uid(),default);
 insert into public.purchase_order_activities values(default,v,'CREATED','Purchase Order created directly from '||h.indent_number,auth.uid(),default);
 return v;
end$$;

create or replace function public.save_purchase_order(p_id uuid,p_header jsonb,p_items jsonb)returns uuid language plpgsql security definer set search_path=''as $$
declare x jsonb;i integer:=0;q numeric;rate numeric;cap numeric;g numeric:=coalesce(nullif(p_header->>'gst_rate','')::numeric,0);f numeric:=coalesce(nullif(p_header->>'freight_amount','')::numeric,0);sid uuid:=nullif(p_header->>'supplier_id','')::uuid;s public.suppliers%rowtype;
begin
 if not public.is_erp_manager()then raise exception'Unauthorized';end if;
 perform 1 from public.purchase_orders where id=p_id and status='DRAFT'for update;if not found then raise exception'Draft PO not found';end if;
 if g<0 or f<0 then raise exception'GST and Freight must not be negative';end if;if jsonb_typeof(p_items)<>'array'or jsonb_array_length(p_items)=0 then raise exception'At least one item is required';end if;
 if sid is not null then select * into s from public.suppliers where id=sid and is_active;if not found then raise exception'Select an active Supplier';end if;end if;
 update public.purchase_orders set po_date=coalesce(nullif(p_header->>'po_date','')::date,po_date),supplier_id=sid,supplier_code_snapshot=s.supplier_code,supplier_name_snapshot=s.supplier_name,supplier_gstin_snapshot=s.gstin,supplier_address_snapshot=concat_ws(', ',s.address_line_1,s.address_line_2,s.city,s.state,s.pin_code,s.country),supplier_contact_snapshot=s.contact_person,supplier_phone_snapshot=s.phone,supplier_email_snapshot=s.email,billing_address_snapshot=trim(p_header->>'billing_address'),delivery_address_snapshot=trim(p_header->>'delivery_address'),payment_terms=nullif(trim(p_header->>'payment_terms'),''),delivery_terms=nullif(trim(p_header->>'delivery_terms'),''),expected_delivery_date=nullif(p_header->>'expected_delivery_date','')::date,remarks=nullif(trim(p_header->>'remarks'),''),terms_conditions=nullif(trim(p_header->>'terms_conditions'),''),gst_rate=g,freight_amount=f,updated_by=auth.uid()where id=p_id;
 for x in select value from jsonb_array_elements(p_items)loop i:=i+1;q:=(x->>'quantity')::numeric;rate:=coalesce(nullif(x->>'unit_rate','')::numeric,0);select pon_quantity into cap from public.purchase_order_items where id=(x->>'id')::uuid and purchase_order_id=p_id;if not found or q<=0 or q>cap or rate<0 then raise exception'Invalid quantity/rate on line %',i;end if;update public.purchase_order_items set quantity=q,unit_rate=rate,description_snapshot=nullif(trim(x->>'description'),''),expected_delivery_date=nullif(x->>'expected_delivery_date','')::date,remarks=nullif(trim(x->>'remarks'),'')where id=(x->>'id')::uuid;end loop;
 perform public.recalculate_purchase_order(p_id);insert into public.purchase_order_activities values(default,p_id,'UPDATED','Draft Purchase Order updated',auth.uid(),default);return p_id;
end$$;

grant execute on function public.create_purchase_order_from_indent(uuid)to authenticated;
commit;