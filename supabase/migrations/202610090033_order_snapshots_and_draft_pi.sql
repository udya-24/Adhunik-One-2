-- Editable Order address snapshots and complete Draft PI lifecycle. No table changes.
begin;

create or replace function public.normalize_order_address(p_override jsonb,p_default jsonb)
returns jsonb language plpgsql immutable set search_path='' as $$
declare result jsonb:=coalesce(p_default,'{}'::jsonb);key text;value text;
begin
 if p_override is null or p_override='null'::jsonb then return result;end if;
 if jsonb_typeof(p_override)<>'object' then raise exception 'Address snapshot must be an object';end if;
 foreach key in array array['address_line_1','address_line_2','city','district','state','postal_code','country'] loop
  if p_override ? key then
   if jsonb_typeof(p_override->key) not in('string','null') then raise exception 'Address fields must be text';end if;
   value:=nullif(trim(p_override->>key),'');
   if length(value)>500 then raise exception 'Address field is too long';end if;
   result:=result||jsonb_build_object(key,value);
  end if;
 end loop;
 if nullif(trim(result->>'address_line_1'),'') is null then raise exception 'Address line 1 is required';end if;
 return result;
end;
$$;


create or replace function public.convert_inquiry_to_order(p_inquiry_id uuid,p_data jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare i public.inquiries%rowtype;c public.customer_companies%rowtype;billing public.customer_addresses%rowtype;shipping public.customer_addresses%rowtype;term public.payment_terms%rowtype;
 existing_id uuid;new_id uuid;contact uuid;bill_id uuid;ship_id uuid;term_id uuid;
begin
 if not public.has_active_erp_access() then raise exception 'Active ERP access is required';end if;
 select * into i from public.inquiries where id=p_inquiry_id and deleted_at is null for update;
 if not found or not public.can_view_inquiry(p_inquiry_id) then raise exception 'Inquiry not found or not accessible';end if;
 if i.status<>'WON' then raise exception 'Only a Won Inquiry can be converted to an Order';end if;
 select id into existing_id from public.orders where inquiry_id=i.id;
 if existing_id is not null then raise exception 'Inquiry already converted to Order %',existing_id;end if;
 select * into c from public.customer_companies where id=i.company_id and deleted_at is null;
 contact:=coalesce(nullif(p_data->>'contact_id','')::uuid,i.contact_id);
 if contact is not null and not exists(select 1 from public.customer_contacts x where x.id=contact and x.customer_company_id=i.company_id and x.deleted_at is null) then raise exception 'Contact does not belong to Inquiry customer';end if;
 bill_id:=nullif(p_data->>'billing_address_id','')::uuid;ship_id:=nullif(p_data->>'shipping_address_id','')::uuid;
 select * into billing from public.customer_addresses where id=bill_id and customer_company_id=i.company_id and deleted_at is null;
 if not found then raise exception 'Select a valid billing address';end if;
 select * into shipping from public.customer_addresses where id=ship_id and customer_company_id=i.company_id and deleted_at is null;
 if not found then raise exception 'Select a valid shipping address';end if;
 term_id:=nullif(p_data->>'payment_term_id','')::uuid;
 if term_id is not null then select * into term from public.payment_terms where id=term_id and deleted_at is null and is_active; if not found then raise exception 'Select a valid active payment term';end if;end if;
 insert into public.orders(order_number,inquiry_id,company_id,contact_id,order_date,customer_po_number,customer_po_date,expected_delivery_date,payment_term_id,payment_term_snapshot,billing_address_id,shipping_address_id,billing_address_snapshot,shipping_address_snapshot,company_name_snapshot,company_gstin_snapshot,salesperson_id,status,customer_notes,internal_notes,created_by,updated_by,shipping_contact_number)
 values(public.allocate_business_number('ORDER'),i.id,i.company_id,contact,coalesce(nullif(p_data->>'order_date','')::date,(now() at time zone 'Asia/Kolkata')::date),nullif(p_data->>'customer_po_number',''),nullif(p_data->>'customer_po_date','')::date,nullif(p_data->>'expected_delivery_date','')::date,term_id,
  case when term_id is null then null else jsonb_build_object('id',term.id,'code',term.code,'name',term.name,'credit_days',term.credit_days) end,
  billing.id,shipping.id,
  public.normalize_order_address(p_data->'billing_address_snapshot',jsonb_build_object('address_type',billing.address_type,'address_line_1',billing.address_line_1,'address_line_2',billing.address_line_2,'city',billing.city,'district',billing.district,'state',billing.state,'postal_code',billing.postal_code,'country',billing.country)),
  public.normalize_order_address(p_data->'shipping_address_snapshot',jsonb_build_object('address_type',shipping.address_type,'address_line_1',shipping.address_line_1,'address_line_2',shipping.address_line_2,'city',shipping.city,'district',shipping.district,'state',shipping.state,'postal_code',shipping.postal_code,'country',shipping.country)),
  c.legal_name,c.gstin,i.assigned_to,'CONFIRMED',nullif(p_data->>'customer_notes',''),nullif(p_data->>'internal_notes',''),auth.uid(),auth.uid(),case when p_data ? 'shipping_contact_number' then nullif(trim(p_data->>'shipping_contact_number'),'') else c.primary_phone end)
 returning id into new_id;
 insert into public.order_activities(order_id,activity_type,description,new_value,created_by) values(new_id,'CREATED','Created from Inquiry',i.inquiry_number,auth.uid());
 insert into public.inquiry_follow_ups(inquiry_id,activity_type,remarks,outcome,created_by,updated_by) values(i.id,'NOTE','Converted to Order',(select order_number from public.orders where id=new_id),auth.uid(),auth.uid());
 return new_id;
exception when unique_violation then
 raise exception 'This Inquiry has already been converted to an Order';
end
$$;

create or replace function public.prepare_order_update() returns trigger language plpgsql security definer set search_path='' as $$
declare billing public.customer_addresses%rowtype;shipping public.customer_addresses%rowtype;term public.payment_terms%rowtype;
begin
 if old.status='CANCELLED' then raise exception 'Cancelled Orders cannot be edited';end if;
 new.order_number:=old.order_number;new.inquiry_id:=old.inquiry_id;new.company_id:=old.company_id;new.created_by:=old.created_by;new.created_at:=old.created_at;new.updated_by:=auth.uid();
 if new.salesperson_id<>old.salesperson_id and not public.can_manage_crm() then raise exception 'Only Admin or Manager can reassign Order salesperson';end if;
 if new.salesperson_id is distinct from old.salesperson_id and not exists(select 1 from public.erp_profiles where auth_user_id=new.salesperson_id and is_active) then raise exception 'Salesperson must have active ERP access';end if;
 if new.contact_id is distinct from old.contact_id and new.contact_id is not null and not exists(select 1 from public.customer_contacts where id=new.contact_id and customer_company_id=old.company_id and deleted_at is null) then raise exception 'Contact does not belong to Order customer';end if;
 if new.billing_address_id is distinct from old.billing_address_id then select * into billing from public.customer_addresses where id=new.billing_address_id and customer_company_id=old.company_id and deleted_at is null;if not found then raise exception 'Select a valid billing address';end if;new.billing_address_snapshot:=public.normalize_order_address(case when new.billing_address_snapshot is distinct from old.billing_address_snapshot then new.billing_address_snapshot else null end,jsonb_build_object('address_type',billing.address_type,'address_line_1',billing.address_line_1,'address_line_2',billing.address_line_2,'city',billing.city,'district',billing.district,'state',billing.state,'postal_code',billing.postal_code,'country',billing.country));else new.billing_address_snapshot:=public.normalize_order_address(new.billing_address_snapshot,old.billing_address_snapshot);end if;
 if new.shipping_address_id is distinct from old.shipping_address_id then select * into shipping from public.customer_addresses where id=new.shipping_address_id and customer_company_id=old.company_id and deleted_at is null;if not found then raise exception 'Select a valid shipping address';end if;new.shipping_address_snapshot:=public.normalize_order_address(case when new.shipping_address_snapshot is distinct from old.shipping_address_snapshot then new.shipping_address_snapshot else null end,jsonb_build_object('address_type',shipping.address_type,'address_line_1',shipping.address_line_1,'address_line_2',shipping.address_line_2,'city',shipping.city,'district',shipping.district,'state',shipping.state,'postal_code',shipping.postal_code,'country',shipping.country));else new.shipping_address_snapshot:=public.normalize_order_address(new.shipping_address_snapshot,old.shipping_address_snapshot);end if;
 if new.payment_term_id is distinct from old.payment_term_id then if new.payment_term_id is null then new.payment_term_snapshot:=null;else select * into term from public.payment_terms where id=new.payment_term_id and deleted_at is null;if not found then raise exception 'Select a valid payment term';end if;new.payment_term_snapshot:=jsonb_build_object('id',term.id,'code',term.code,'name',term.name,'credit_days',term.credit_days);end if;else new.payment_term_snapshot:=old.payment_term_snapshot;end if;
 return new;
end
$$;

create or replace function public.save_proforma_invoice(p_pi_id uuid,p_order_id uuid,p_data jsonb,p_items jsonb)returns uuid language plpgsql security definer set search_path='' as $$
declare v_billing_snapshot jsonb;v_shipping_snapshot jsonb;o public.orders%rowtype;c public.customer_companies%rowtype;ct public.customer_contacts%rowtype;b public.customer_addresses%rowtype;s public.customer_addresses%rowtype;t public.payment_terms%rowtype;v_id uuid;v_ct uuid;v_b uuid;v_s uuid;v_t uuid;v_sales uuid;v_line jsonb;v_n int:=0;v_old int:=0;v_qty numeric;v_rate numeric;v_pct numeric;v_gross numeric;v_disc numeric;v_net numeric;v_sub numeric:=0;v_discs numeric:=0;v_gst numeric;v_freight numeric;v_currency text;
begin
 if not public.has_active_erp_access()then raise exception 'Active ERP access is required';end if;if jsonb_typeof(p_items)<>'array'or jsonb_array_length(p_items)=0 then raise exception 'Add at least one PI item';end if;
 if p_pi_id is null then select * into o from public.orders where id=p_order_id and deleted_at is null and status<>'CANCELLED' for update;if not found or not public.can_view_order(p_order_id)then raise exception 'Order not found or not accessible';end if;if exists(select 1 from public.proforma_invoices where order_id=o.id and status='DRAFT' and deleted_at is null)then raise exception 'A Draft PI already exists for this Order';end if;
 else select p.order_id into p_order_id from public.proforma_invoices p where p.id=p_pi_id and public.can_manage_proforma_invoice(p.id) for update;if not found then raise exception 'Draft PI not found or not editable';end if;select * into o from public.orders where id=p_order_id;v_id:=p_pi_id;select count(*) into v_old from public.proforma_invoice_items where proforma_invoice_id=v_id;end if;
 select * into c from public.customer_companies where id=o.company_id and deleted_at is null;if not found then raise exception 'Order customer is unavailable';end if;
 v_ct:=nullif(p_data->>'contact_id','')::uuid;if v_ct is not null then select * into ct from public.customer_contacts where id=v_ct and customer_company_id=o.company_id and deleted_at is null and is_active;if not found then raise exception 'Select a valid customer contact';end if;end if;
 -- Existing PIs keep their own snapshots; new PIs inherit the Order, never live master addresses.
 if v_id is null then
  v_b:=o.billing_address_id;v_s:=o.shipping_address_id;
  v_billing_snapshot:=o.billing_address_snapshot;v_shipping_snapshot:=o.shipping_address_snapshot;
 else
  select billing_address_id,shipping_address_id,billing_address_snapshot,shipping_address_snapshot
   into v_b,v_s,v_billing_snapshot,v_shipping_snapshot from public.proforma_invoices where id=v_id;
 end if;
 v_t:=nullif(p_data->>'payment_term_id','')::uuid;if v_t is not null then select * into t from public.payment_terms where id=v_t and deleted_at is null and is_active;if not found then raise exception 'Select a valid payment term';end if;end if;
 v_sales:=coalesce(nullif(p_data->>'salesperson_id','')::uuid,o.salesperson_id);if v_sales<>o.salesperson_id and not public.can_manage_crm()then raise exception 'Only Admin or Manager can reassign the salesperson';end if;if not exists(select 1 from public.erp_profiles where auth_user_id=v_sales and is_active)then raise exception 'Salesperson must have active ERP access';end if;
 v_gst:=coalesce(nullif(p_data->>'gst_percentage','')::numeric,0);v_freight:=coalesce(nullif(p_data->>'freight_amount','')::numeric,0);if v_gst<0 or v_gst>100 then raise exception 'GST percentage must be between 0 and 100';end if;if v_freight<0 then raise exception 'Freight cannot be negative';end if;
 for v_line in select value from jsonb_array_elements(p_items)loop v_n:=v_n+1;v_qty:=nullif(v_line->>'quantity','')::numeric;v_rate:=nullif(v_line->>'unit_price','')::numeric;v_pct:=coalesce(nullif(v_line->>'discount_percentage','')::numeric,0);if nullif(trim(v_line->>'item_description'),'')is null or nullif(trim(v_line->>'unit'),'')is null then raise exception 'Item % requires description and unit',v_n;end if;if v_qty is null or v_qty<=0 or v_rate is null or v_rate<0 or v_pct<0 or v_pct>100 then raise exception 'Item % has invalid quantity, price or discount',v_n;end if;v_gross:=round(v_qty*v_rate,2);v_disc:=round(v_gross*v_pct/100,2);v_net:=round(v_gross-v_disc,2);v_sub:=v_sub+v_net;v_discs:=v_discs+v_disc;end loop;
 v_currency:=upper(coalesce(nullif(p_data->>'currency',''),(select value from public.system_settings where category='LOCALIZATION' and key='DEFAULT_CURRENCY'),'INR'));if v_currency!~'^[A-Z]{3}$'then raise exception 'Currency must be a 3-letter code';end if;
 if v_id is null then insert into public.proforma_invoices(pi_number,order_id,company_id,contact_id,pi_date,our_reference_number,dp_code,project_name,customer_po_number,customer_po_date,billing_address_id,shipping_address_id,billing_address_snapshot,shipping_address_snapshot,customer_name_snapshot,customer_gstin_snapshot,customer_phone_snapshot,customer_email_snapshot,payment_term_id,payment_terms_snapshot,delivery_terms,validity_text,freight_amount,freight_remark,gst_percentage,subtotal,discount_total,taxable_total,gst_amount,grand_total,currency,salesperson_id,created_by,updated_by,shipping_contact_number,other_remarks)values(public.allocate_business_number('PROFORMA_INVOICE'),o.id,o.company_id,v_ct,coalesce(nullif(p_data->>'pi_date','')::date,(now() at time zone 'Asia/Kolkata')::date),nullif(p_data->>'our_reference_number',''),nullif(p_data->>'dp_code',''),nullif(p_data->>'project_name',''),nullif(p_data->>'customer_po_number',''),nullif(p_data->>'customer_po_date','')::date,v_b,v_s,v_billing_snapshot,v_shipping_snapshot,coalesce(nullif(p_data->>'customer_name',''),c.legal_name),coalesce(nullif(p_data->>'customer_gstin',''),c.gstin),coalesce(nullif(p_data->>'customer_phone',''),ct.phone,c.primary_phone),coalesce(nullif(p_data->>'customer_email',''),ct.email,c.primary_email),v_t,case when v_t is null then null else coalesce(nullif(p_data->>'payment_terms',''),t.name)end,nullif(p_data->>'delivery_terms',''),nullif(p_data->>'validity_text',''),round(v_freight,2),nullif(p_data->>'freight_remark',''),v_gst,round(v_sub,2),round(v_discs,2),round(v_sub,2),round(v_sub*v_gst/100,2),round(v_sub+round(v_sub*v_gst/100,2)+v_freight,2),v_currency,v_sales,auth.uid(),auth.uid(),o.shipping_contact_number,o.customer_notes)returning id into v_id;insert into public.proforma_invoice_activities(proforma_invoice_id,activity_type,description,created_by)values(v_id,'CREATED','Draft PI created from Order '||o.order_number,auth.uid());
 else update public.proforma_invoices set contact_id=v_ct,pi_date=coalesce(nullif(p_data->>'pi_date','')::date,pi_date),our_reference_number=nullif(p_data->>'our_reference_number',''),dp_code=nullif(p_data->>'dp_code',''),project_name=nullif(p_data->>'project_name',''),customer_po_number=nullif(p_data->>'customer_po_number',''),customer_po_date=nullif(p_data->>'customer_po_date','')::date,billing_address_id=v_b,shipping_address_id=v_s,billing_address_snapshot=v_billing_snapshot,shipping_address_snapshot=v_shipping_snapshot,customer_name_snapshot=coalesce(nullif(p_data->>'customer_name',''),customer_name_snapshot),customer_gstin_snapshot=nullif(p_data->>'customer_gstin',''),customer_phone_snapshot=nullif(p_data->>'customer_phone',''),customer_email_snapshot=nullif(p_data->>'customer_email',''),payment_term_id=v_t,payment_terms_snapshot=nullif(p_data->>'payment_terms',''),delivery_terms=nullif(p_data->>'delivery_terms',''),validity_text=nullif(p_data->>'validity_text',''),freight_amount=round(v_freight,2),freight_remark=nullif(p_data->>'freight_remark',''),gst_percentage=v_gst,subtotal=round(v_sub,2),discount_total=round(v_discs,2),taxable_total=round(v_sub,2),gst_amount=round(v_sub*v_gst/100,2),grand_total=round(v_sub+round(v_sub*v_gst/100,2)+v_freight,2),currency=v_currency,salesperson_id=v_sales,updated_by=auth.uid(),updated_at=now()where id=v_id;delete from public.proforma_invoice_items where proforma_invoice_id=v_id;insert into public.proforma_invoice_activities(proforma_invoice_id,activity_type,description,created_by)values(v_id,'EDITED','Draft PI edited',auth.uid());end if;
 v_n:=0;for v_line in select value from jsonb_array_elements(p_items)loop v_n:=v_n+1;v_qty:=(v_line->>'quantity')::numeric;v_rate:=(v_line->>'unit_price')::numeric;v_pct:=coalesce(nullif(v_line->>'discount_percentage','')::numeric,0);v_gross:=round(v_qty*v_rate,2);v_disc:=round(v_gross*v_pct/100,2);insert into public.proforma_invoice_items(proforma_invoice_id,line_number,inventory_item_id,item_name,item_description,model_type,hsn_code,unit,quantity,unit_price,discount_percentage,gross_amount,discount_amount,line_total,sort_order)values(v_id,v_n,nullif(v_line->>'inventory_item_id','')::uuid,nullif(v_line->>'item_name',''),trim(v_line->>'item_description'),nullif(v_line->>'model_type',''),nullif(v_line->>'hsn_code',''),trim(v_line->>'unit'),v_qty,v_rate,v_pct,v_gross,v_disc,round(v_gross-v_disc,2),v_n);end loop;
 if p_pi_id is not null and v_old<jsonb_array_length(p_items)then insert into public.proforma_invoice_activities(proforma_invoice_id,activity_type,description,created_by)values(v_id,'ITEM_ADDED','PI item added',auth.uid());elsif p_pi_id is not null and v_old>jsonb_array_length(p_items)then insert into public.proforma_invoice_activities(proforma_invoice_id,activity_type,description,created_by)values(v_id,'ITEM_REMOVED','PI item removed',auth.uid());end if;return v_id;
exception when unique_violation then raise exception 'A Draft PI already exists for this Order or PI number conflicts';end;$$;

create or replace function public.create_proforma_invoice_revision(p_pi_id uuid,p_reason text)returns uuid language plpgsql security definer set search_path='' as $$
declare p public.proforma_invoices%rowtype;v_root uuid;v_revision int;v_id uuid;
begin
 if nullif(trim(p_reason),'')is null then raise exception 'Revision reason is required';end if;select * into p from public.proforma_invoices where id=p_pi_id and status in('DRAFT','ISSUED','ACCEPTED')and deleted_at is null and public.can_view_proforma_invoice(id) for update;if not found then raise exception 'Issued PI not found or not accessible';end if;if not(public.can_manage_crm()or p.created_by=auth.uid()or p.salesperson_id=auth.uid())then raise exception 'You cannot revise this PI';end if;
 v_root:=p.root_pi_id;perform pg_advisory_xact_lock(hashtextextended(v_root::text,0));select coalesce(max(revision_number),0)+1 into v_revision from public.proforma_invoices where root_pi_id=v_root;
 update public.proforma_invoices set status='REVISED',updated_by=auth.uid(),updated_at=now()where root_pi_id=v_root and status in('DRAFT','ISSUED','ACCEPTED');
 insert into public.proforma_invoices(pi_number,order_id,company_id,contact_id,pi_date,our_reference_number,dp_code,project_name,customer_po_number,customer_po_date,billing_address_id,shipping_address_id,billing_address_snapshot,shipping_address_snapshot,customer_name_snapshot,customer_gstin_snapshot,customer_phone_snapshot,customer_email_snapshot,payment_term_id,payment_terms_snapshot,delivery_terms,validity_text,freight_amount,freight_remark,gst_percentage,subtotal,discount_total,taxable_total,gst_amount,grand_total,currency,status,salesperson_id,created_by,updated_by,root_pi_id,revised_from_id,revision_number,revision_reason,document_configuration_snapshot)
 select pi_number,order_id,company_id,contact_id,(now() at time zone 'Asia/Kolkata')::date,our_reference_number,dp_code,project_name,customer_po_number,customer_po_date,billing_address_id,shipping_address_id,billing_address_snapshot,shipping_address_snapshot,customer_name_snapshot,customer_gstin_snapshot,customer_phone_snapshot,customer_email_snapshot,payment_term_id,payment_terms_snapshot,delivery_terms,validity_text,freight_amount,freight_remark,gst_percentage,subtotal,discount_total,taxable_total,gst_amount,grand_total,currency,'ISSUED',salesperson_id,auth.uid(),auth.uid(),v_root,p.id,v_revision,trim(p_reason),document_configuration_snapshot from public.proforma_invoices where id=p.id returning id into v_id;
 insert into public.proforma_invoice_items(proforma_invoice_id,line_number,inventory_item_id,item_name,item_description,model_type,hsn_code,unit,quantity,unit_price,discount_percentage,gross_amount,discount_amount,line_total,sort_order)select v_id,line_number,inventory_item_id,item_name,item_description,model_type,hsn_code,unit,quantity,unit_price,discount_percentage,gross_amount,discount_amount,line_total,sort_order from public.proforma_invoice_items where proforma_invoice_id=p.id;
 update public.proforma_invoices set shipping_contact_number=p.shipping_contact_number,other_remarks=p.other_remarks,issued_at=now(),issued_by=auth.uid(),accepted_at=null,accepted_by=null where id=v_id;
 insert into public.proforma_invoice_activities(proforma_invoice_id,activity_type,description,created_by)values(v_id,'REVISION_CREATED','Revision '||v_revision||' created: '||trim(p_reason),auth.uid());return v_id;
end;$$;

create or replace function public.delete_draft_proforma_invoice(p_pi_id uuid)
returns void language plpgsql security definer set search_path='' as $$
begin
 update public.proforma_invoices set deleted_at=now(),deleted_by=auth.uid(),updated_by=auth.uid(),updated_at=now()
 where id=p_pi_id and status='DRAFT' and public.can_manage_proforma_invoice(id);
 if not found then raise exception 'Draft PI not found or not deletable';end if;
 insert into public.proforma_invoice_activities(proforma_invoice_id,activity_type,description,created_by)
 values(p_pi_id,'STATUS_CHANGED','Draft PI deleted',auth.uid());
end;
$$;
revoke all on function public.delete_draft_proforma_invoice(uuid) from public,anon;
grant execute on function public.delete_draft_proforma_invoice(uuid) to authenticated;


-- Document exports render the latest editable revision; accepted terms remain locked.
commit;
