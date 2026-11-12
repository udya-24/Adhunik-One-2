-- Adhunik ERP - Phase 4B Inquiry Conversion and Order Foundation
begin;
alter table public.numbering_configurations drop constraint if exists numbering_configurations_entity_type_check;
alter table public.numbering_configurations add constraint numbering_configurations_entity_type_check check(entity_type in('EMPLOYEE','CUSTOMER','INQUIRY','ORDER'));
insert into public.numbering_configurations(entity_type,prefix,padding,separator,include_year) values('ORDER','ORD',4,'-',true) on conflict(entity_type) do nothing;

create table if not exists public.orders(
 id uuid primary key default gen_random_uuid(),order_number text not null unique,
 inquiry_id uuid not null unique references public.inquiries(id) on delete restrict,
 company_id uuid not null references public.customer_companies(id) on delete restrict,
 contact_id uuid references public.customer_contacts(id) on delete restrict,
 order_date date not null default current_date,customer_po_number text,customer_po_date date,expected_delivery_date date,
 payment_term_id uuid references public.payment_terms(id) on delete restrict,payment_term_snapshot jsonb,
 billing_address_id uuid references public.customer_addresses(id) on delete restrict,shipping_address_id uuid references public.customer_addresses(id) on delete restrict,
 billing_address_snapshot jsonb not null,shipping_address_snapshot jsonb not null,
 company_name_snapshot text not null,company_gstin_snapshot text,
 salesperson_id uuid not null references auth.users(id) on delete restrict,
 status text not null default 'CONFIRMED' check(status in('CONFIRMED','IN_PROCESS','COMPLETED','CANCELLED')),
 customer_notes text,internal_notes text,
 created_by uuid not null references auth.users(id) on delete restrict,created_at timestamptz not null default now(),
 updated_by uuid references auth.users(id) on delete set null,updated_at timestamptz not null default now(),
 cancelled_at timestamptz,cancelled_by uuid references auth.users(id) on delete restrict,cancellation_reason text,
 closed_at timestamptz,deleted_at timestamptz,deleted_by uuid references auth.users(id) on delete set null,
 constraint order_cancellation_details check((status='CANCELLED' and cancellation_reason is not null and cancelled_at is not null and cancelled_by is not null) or(status<>'CANCELLED' and cancellation_reason is null and cancelled_at is null and cancelled_by is null))
);
insert into public.numbering_counters(entity_type,current_value)
select 'ORDER',coalesce(max((substring(order_number from '([0-9]+)$'))::bigint),0) from public.orders where order_number~'[0-9]+$'
on conflict(entity_type) do update set current_value=greatest(public.numbering_counters.current_value,excluded.current_value);

create table if not exists public.order_attachments(
 id uuid primary key default gen_random_uuid(),order_id uuid not null references public.orders(id) on delete restrict,
 document_type text not null default 'OTHER' check(document_type in('CUSTOMER_PO','REVISED_PO','BOQ','DRAWING','SPECIFICATION','EMAIL_CONFIRMATION','OTHER')),
 file_name text not null,file_path text not null unique,mime_type text not null,file_size bigint not null check(file_size between 1 and 10485760),
 uploaded_by uuid not null references auth.users(id) on delete restrict,uploaded_at timestamptz not null default now(),is_active boolean not null default true
);
create table if not exists public.order_activities(
 id uuid primary key default gen_random_uuid(),order_id uuid not null references public.orders(id) on delete restrict,
 activity_type text not null check(activity_type in('CREATED','UPDATED','STATUS_CHANGED','REASSIGNED','DOCUMENT_UPLOADED','DOCUMENT_REMOVED','CANCELLED')),
 description text not null,previous_value text,new_value text,created_by uuid not null references auth.users(id) on delete restrict,created_at timestamptz not null default now()
);
create unique index if not exists orders_inquiry_unique on public.orders(inquiry_id);
create index if not exists orders_company on public.orders(company_id) where deleted_at is null;
create index if not exists orders_contact on public.orders(contact_id) where contact_id is not null and deleted_at is null;
create index if not exists orders_salesperson on public.orders(salesperson_id,status) where deleted_at is null;
create index if not exists orders_status_date on public.orders(status,order_date desc) where deleted_at is null;
create index if not exists orders_po on public.orders(customer_po_number) where customer_po_number is not null and deleted_at is null;
create index if not exists orders_delivery on public.orders(expected_delivery_date) where expected_delivery_date is not null and deleted_at is null;
create index if not exists order_attachments_order on public.order_attachments(order_id,uploaded_at desc) where is_active;
create index if not exists order_activities_order on public.order_activities(order_id,created_at desc);

create or replace function public.can_view_order(p_order_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.orders o where o.id=p_order_id and o.deleted_at is null and(
  public.current_erp_role()='ADMIN' or o.created_by=auth.uid() or o.salesperson_id=auth.uid() or public.can_view_inquiry(o.inquiry_id)
 ))
$$;

create or replace function public.can_manage_order(p_order_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.orders o where o.id=p_order_id and o.deleted_at is null and(public.can_manage_crm() or o.created_by=auth.uid() or o.salesperson_id=auth.uid()))
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
 insert into public.orders(order_number,inquiry_id,company_id,contact_id,order_date,customer_po_number,customer_po_date,expected_delivery_date,payment_term_id,payment_term_snapshot,billing_address_id,shipping_address_id,billing_address_snapshot,shipping_address_snapshot,company_name_snapshot,company_gstin_snapshot,salesperson_id,status,customer_notes,internal_notes,created_by,updated_by)
 values(public.allocate_business_number('ORDER'),i.id,i.company_id,contact,coalesce(nullif(p_data->>'order_date','')::date,current_date),nullif(p_data->>'customer_po_number',''),nullif(p_data->>'customer_po_date','')::date,nullif(p_data->>'expected_delivery_date','')::date,term_id,
  case when term_id is null then null else jsonb_build_object('id',term.id,'code',term.code,'name',term.name,'credit_days',term.credit_days) end,
  billing.id,shipping.id,
  jsonb_build_object('address_type',billing.address_type,'address_line_1',billing.address_line_1,'address_line_2',billing.address_line_2,'city',billing.city,'district',billing.district,'state',billing.state,'postal_code',billing.postal_code,'country',billing.country),
  jsonb_build_object('address_type',shipping.address_type,'address_line_1',shipping.address_line_1,'address_line_2',shipping.address_line_2,'city',shipping.city,'district',shipping.district,'state',shipping.state,'postal_code',shipping.postal_code,'country',shipping.country),
  c.legal_name,c.gstin,i.assigned_to,'CONFIRMED',nullif(p_data->>'customer_notes',''),nullif(p_data->>'internal_notes',''),auth.uid(),auth.uid())
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
 if new.billing_address_id is distinct from old.billing_address_id then select * into billing from public.customer_addresses where id=new.billing_address_id and customer_company_id=old.company_id and deleted_at is null;if not found then raise exception 'Select a valid billing address';end if;new.billing_address_snapshot:=jsonb_build_object('address_type',billing.address_type,'address_line_1',billing.address_line_1,'address_line_2',billing.address_line_2,'city',billing.city,'district',billing.district,'state',billing.state,'postal_code',billing.postal_code,'country',billing.country);else new.billing_address_snapshot:=old.billing_address_snapshot;end if;
 if new.shipping_address_id is distinct from old.shipping_address_id then select * into shipping from public.customer_addresses where id=new.shipping_address_id and customer_company_id=old.company_id and deleted_at is null;if not found then raise exception 'Select a valid shipping address';end if;new.shipping_address_snapshot:=jsonb_build_object('address_type',shipping.address_type,'address_line_1',shipping.address_line_1,'address_line_2',shipping.address_line_2,'city',shipping.city,'district',shipping.district,'state',shipping.state,'postal_code',shipping.postal_code,'country',shipping.country);else new.shipping_address_snapshot:=old.shipping_address_snapshot;end if;
 if new.payment_term_id is distinct from old.payment_term_id then if new.payment_term_id is null then new.payment_term_snapshot:=null;else select * into term from public.payment_terms where id=new.payment_term_id and deleted_at is null;if not found then raise exception 'Select a valid payment term';end if;new.payment_term_snapshot:=jsonb_build_object('id',term.id,'code',term.code,'name',term.name,'credit_days',term.credit_days);end if;else new.payment_term_snapshot:=old.payment_term_snapshot;end if;
 return new;
end
$$;
create or replace function public.log_order_update() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status<>old.status then insert into public.order_activities(order_id,activity_type,description,previous_value,new_value,created_by) values(new.id,case when new.status='CANCELLED' then 'CANCELLED' else 'STATUS_CHANGED' end,'Order status changed',old.status,new.status,auth.uid());
 elsif new.salesperson_id<>old.salesperson_id then insert into public.order_activities(order_id,activity_type,description,previous_value,new_value,created_by) values(new.id,'REASSIGNED','Order salesperson reassigned',old.salesperson_id::text,new.salesperson_id::text,auth.uid());
 else insert into public.order_activities(order_id,activity_type,description,created_by) values(new.id,'UPDATED','Order details updated',auth.uid());end if;return new;
end
$$;
create or replace function public.cancel_order(p_order_id uuid,p_reason text) returns void language plpgsql security definer set search_path='' as $$
begin
 if nullif(trim(p_reason),'') is null then raise exception 'Cancellation reason is required';end if;
 update public.orders set status='CANCELLED',cancellation_reason=trim(p_reason),cancelled_at=now(),cancelled_by=auth.uid()
 where id=p_order_id and public.can_manage_order(id) and status<>'CANCELLED';
 if not found then raise exception 'Order not found, inaccessible or already cancelled';end if;
end
$$;
create or replace function public.log_order_attachment() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' then insert into public.order_activities(order_id,activity_type,description,new_value,created_by) values(new.order_id,'DOCUMENT_UPLOADED','Order document uploaded',new.document_type||': '||new.file_name,auth.uid());
 elsif old.is_active and not new.is_active then insert into public.order_activities(order_id,activity_type,description,previous_value,created_by) values(new.order_id,'DOCUMENT_REMOVED','Order document removed',new.file_name,auth.uid());end if;return new;
end
$$;
create or replace function public.prepare_order_attachment() returns trigger language plpgsql security definer set search_path='' as $$begin new.uploaded_by:=auth.uid();return new;end$$;
drop trigger if exists prepare_order_update on public.orders;create trigger prepare_order_update before update on public.orders for each row execute function public.prepare_order_update();
drop trigger if exists set_orders_updated_at on public.orders;create trigger set_orders_updated_at before update on public.orders for each row execute function public.set_updated_at();
drop trigger if exists log_order_update on public.orders;create trigger log_order_update after update on public.orders for each row execute function public.log_order_update();
drop trigger if exists log_order_attachment on public.order_attachments;create trigger log_order_attachment after insert or update of is_active on public.order_attachments for each row execute function public.log_order_attachment();
drop trigger if exists prepare_order_attachment on public.order_attachments;create trigger prepare_order_attachment before insert on public.order_attachments for each row execute function public.prepare_order_attachment();

alter table public.orders enable row level security;alter table public.order_attachments enable row level security;alter table public.order_activities enable row level security;
drop policy if exists "CRM visible orders" on public.orders;drop policy if exists "CRM update orders" on public.orders;
drop policy if exists "CRM visible order attachments" on public.order_attachments;drop policy if exists "CRM create order attachments" on public.order_attachments;drop policy if exists "CRM update order attachments" on public.order_attachments;
drop policy if exists "CRM visible order activities" on public.order_activities;
create policy "CRM visible orders" on public.orders for select to authenticated using(public.can_view_order(id));
create policy "CRM update orders" on public.orders for update to authenticated using(public.can_manage_order(id)) with check(public.can_manage_order(id));
create policy "CRM visible order attachments" on public.order_attachments for select to authenticated using(public.can_view_order(order_id));
create policy "CRM create order attachments" on public.order_attachments for insert to authenticated with check(public.can_view_order(order_id));
create policy "CRM update order attachments" on public.order_attachments for update to authenticated using((uploaded_by=auth.uid() or public.can_manage_crm()) and public.can_view_order(order_id));
create policy "CRM visible order activities" on public.order_activities for select to authenticated using(public.can_view_order(order_id));
grant select,update on public.orders to authenticated;grant select,insert,update on public.order_attachments to authenticated;grant select on public.order_activities to authenticated;
revoke all on function public.convert_inquiry_to_order(uuid,jsonb),public.cancel_order(uuid,text) from public,anon;
grant execute on function public.can_view_order(uuid),public.can_manage_order(uuid),public.convert_inquiry_to_order(uuid,jsonb),public.cancel_order(uuid,text) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('crm-order-attachments','crm-order-attachments',false,10485760,array['application/pdf','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','image/jpeg','image/png','image/webp'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists "CRM order objects read" on storage.objects;drop policy if exists "CRM order objects insert" on storage.objects;drop policy if exists "CRM order objects delete" on storage.objects;
create policy "CRM order objects read" on storage.objects for select to authenticated using(bucket_id='crm-order-attachments' and public.can_view_order((storage.foldername(name))[1]::uuid));
create policy "CRM order objects insert" on storage.objects for insert to authenticated with check(bucket_id='crm-order-attachments' and public.can_view_order((storage.foldername(name))[1]::uuid));
create policy "CRM order objects delete" on storage.objects for delete to authenticated using(bucket_id='crm-order-attachments' and(owner_id=auth.uid()::text or public.can_manage_crm()) and public.can_view_order((storage.foldername(name))[1]::uuid));
commit;
