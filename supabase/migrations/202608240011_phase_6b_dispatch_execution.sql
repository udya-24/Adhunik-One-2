-- Adhunik ERP - Phase 6B Dispatch execution, transport and challan
-- Additive migration. Run once after 202608240010_phase_6a_packing_lists.sql.
begin;

alter table public.numbering_configurations drop constraint if exists numbering_configurations_entity_type_check;
alter table public.numbering_configurations add constraint numbering_configurations_entity_type_check
  check (entity_type in ('EMPLOYEE','CUSTOMER','INQUIRY','ORDER','PROFORMA_INVOICE','PACKING_LIST','DISPATCH'));
insert into public.numbering_configurations(entity_type,prefix,padding,separator,include_financial_year)
values ('DISPATCH','DSP',4,'/',true) on conflict(entity_type) do nothing;
insert into public.numbering_counters(entity_type,current_value)
values ('DISPATCH',0) on conflict(entity_type) do nothing;

alter table public.packing_lists drop constraint if exists packing_lists_status_check;
alter table public.packing_lists add constraint packing_lists_status_check
  check(status in('DRAFT','FINALIZED','PARTIALLY_DISPATCHED','DISPATCHED','CANCELLED'));

create table public.dispatches(
 id uuid primary key default gen_random_uuid(),
 dispatch_number text not null unique,
 company_id uuid not null references public.customer_companies(id) on delete restrict,
 order_id uuid not null references public.orders(id) on delete restrict,
 pi_id uuid not null references public.proforma_invoices(id) on delete restrict,
 packing_list_id uuid not null references public.packing_lists(id) on delete restrict,
 dispatch_date date not null default current_date,
 status text not null default 'DRAFT' check(status in('DRAFT','DISPATCHED','CANCELLED')),
 customer_name_snapshot text not null,
 pi_number_snapshot text not null,
 order_number_snapshot text not null,
 packing_list_number_snapshot text not null,
 customer_po_number_snapshot text,
 project_name_snapshot text,
 shipping_address_snapshot jsonb not null,
 transport_mode text check(transport_mode is null or transport_mode in('ROAD','COURIER','AIR','RAIL','SELF_PICKUP','OTHER')),
 transporter_name text,
 transporter_contact text,
 vehicle_number text,
 driver_name text,
 driver_contact text,
 lr_gr_number text,
 lr_gr_date date,
 tracking_awb_number text,
 freight_type text check(freight_type is null or freight_type in('PAID','TO_PAY','INCLUDED','OTHER')),
 freight_amount numeric(18,2) not null default 0 check(freight_amount>=0),
 freight_paid_by text check(freight_paid_by is null or freight_paid_by in('ADHUNIK','CUSTOMER','OTHER')),
 eway_bill_number text,
 eway_bill_date date,
 eway_bill_expiry_date date,
 remarks text,
 total_packages integer not null default 0 check(total_packages>=0),
 total_net_weight numeric(18,3) not null default 0 check(total_net_weight>=0),
 total_gross_weight numeric(18,3) not null default 0 check(total_gross_weight>=total_net_weight),
 created_by uuid not null references auth.users(id) on delete restrict,
 created_at timestamptz not null default now(),
 updated_by uuid references auth.users(id) on delete set null,
 updated_at timestamptz not null default now(),
 confirmed_by uuid references auth.users(id) on delete restrict,
 confirmed_at timestamptz,
 cancelled_by uuid references auth.users(id) on delete restrict,
 cancelled_at timestamptz,
 cancellation_reason text,
 constraint dispatch_confirmation_details check(status<>'DISPATCHED' or(confirmed_by is not null and confirmed_at is not null)),
 constraint dispatch_cancellation_details check(status<>'CANCELLED' or(cancelled_by is not null and cancelled_at is not null and nullif(trim(cancellation_reason),'')is not null)),
 constraint dispatch_eway_dates check(eway_bill_expiry_date is null or eway_bill_date is null or eway_bill_expiry_date>=eway_bill_date)
);

create table public.dispatch_packages(
 id uuid primary key default gen_random_uuid(),
 dispatch_id uuid not null references public.dispatches(id) on delete cascade,
 packing_list_package_id uuid not null references public.packing_list_packages(id) on delete restrict,
 is_committed boolean not null default false,
 committed_at timestamptz,
 created_at timestamptz not null default now(),
 unique(dispatch_id,packing_list_package_id),
 check((is_committed and committed_at is not null)or(not is_committed and committed_at is null))
);
create unique index dispatch_packages_one_committed_package on public.dispatch_packages(packing_list_package_id) where is_committed;

create table public.dispatch_documents(
 id uuid primary key default gen_random_uuid(),
 dispatch_id uuid not null references public.dispatches(id) on delete restrict,
 document_type text not null check(document_type in('LR_GR','COURIER_RECEIPT','TRANSPORT_RECEIPT','EWAY_BILL','OTHER')),
 file_name text not null,
 file_path text not null unique,
 mime_type text not null check(mime_type in('application/pdf','image/jpeg','image/png','image/webp')),
 file_size bigint not null check(file_size>0 and file_size<=10485760),
 description text,
 uploaded_by uuid not null references auth.users(id) on delete restrict,
 uploaded_at timestamptz not null default now(),
 is_active boolean not null default true
);
create table public.dispatch_activities(
 id uuid primary key default gen_random_uuid(),
 dispatch_id uuid not null references public.dispatches(id) on delete restrict,
 activity_type text not null check(activity_type in('CREATED','EDITED','PACKAGE_ADDED','PACKAGE_REMOVED','TRANSPORT_UPDATED','DOCUMENT_UPLOADED','DOCUMENT_REMOVED','CONFIRMED','CHALLAN_GENERATED','CANCELLED')),
 description text not null,
 created_by uuid not null references auth.users(id) on delete restrict,
 created_at timestamptz not null default now()
);

create index dispatches_packing_list on public.dispatches(packing_list_id,created_at desc);
create index dispatches_pi on public.dispatches(pi_id,dispatch_date desc);
create index dispatches_order on public.dispatches(order_id,dispatch_date desc);
create index dispatches_company on public.dispatches(company_id,dispatch_date desc);
create index dispatches_status_date on public.dispatches(status,dispatch_date desc);
create index dispatches_creator on public.dispatches(created_by);
create index dispatches_transporter on public.dispatches(lower(transporter_name)) where transporter_name is not null;
create index dispatches_lr on public.dispatches(lr_gr_number) where lr_gr_number is not null;
create index dispatches_vehicle on public.dispatches(vehicle_number) where vehicle_number is not null;
create index dispatches_tracking on public.dispatches(tracking_awb_number) where tracking_awb_number is not null;
create index dispatch_packages_dispatch on public.dispatch_packages(dispatch_id);
create index dispatch_documents_parent on public.dispatch_documents(dispatch_id,uploaded_at desc);
create index dispatch_activities_parent on public.dispatch_activities(dispatch_id,created_at desc);

create function public.can_view_dispatch(p_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.dispatches d where d.id=p_id and public.can_view_packing_list(d.packing_list_id))
$$;
create function public.can_manage_dispatch(p_id uuid) returns boolean
language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.dispatches d where d.id=p_id and d.status='DRAFT' and(public.can_manage_crm()or d.created_by=auth.uid()))
$$;

create function public.refresh_packing_list_dispatch_status(p_packing_list_id uuid) returns text
language plpgsql security definer set search_path='' as $$
declare v_total integer;v_done integer;v_status text;
begin
 select count(*) into v_total from public.packing_list_packages where packing_list_id=p_packing_list_id;
 select count(distinct dp.packing_list_package_id) into v_done
 from public.dispatch_packages dp join public.dispatches d on d.id=dp.dispatch_id
 join public.packing_list_packages p on p.id=dp.packing_list_package_id
 where p.packing_list_id=p_packing_list_id and dp.is_committed and d.status='DISPATCHED';
 v_status:=case when v_done=0 then 'FINALIZED' when v_done<v_total then 'PARTIALLY_DISPATCHED' else 'DISPATCHED' end;
 perform set_config('app.dispatch_status_update','1',true);
 update public.packing_lists set status=v_status,updated_at=now(),updated_by=auth.uid()
 where id=p_packing_list_id and status in('FINALIZED','PARTIALLY_DISPATCHED','DISPATCHED');
 return v_status;
end; $$;

create or replace function public.protect_packing_list() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 new.packing_list_number:=old.packing_list_number;new.pi_id:=old.pi_id;new.order_id:=old.order_id;new.company_id:=old.company_id;new.created_by:=old.created_by;new.created_at:=old.created_at;
 if old.status='CANCELLED' then raise exception 'Locked Packing List cannot be edited';end if;
 if old.status in('PARTIALLY_DISPATCHED','DISPATCHED')and coalesce(current_setting('app.dispatch_status_update',true),'0')<>'1' then raise exception 'Dispatched Packing List cannot be edited';end if;
 return new;
end; $$;

create function public.create_dispatch(p_packing_list_id uuid) returns uuid
language plpgsql security definer set search_path='' as $$
declare p public.packing_lists%rowtype;v_id uuid;
begin
 if not public.has_active_erp_access()then raise exception 'Active ERP access is required';end if;
 select * into p from public.packing_lists where id=p_packing_list_id and status in('FINALIZED','PARTIALLY_DISPATCHED')and public.can_view_packing_list(id) for update;
 if not found then raise exception 'Only an accessible Finalized Packing List with available packages can be dispatched';end if;
 if not exists(select 1 from public.packing_list_packages k where k.packing_list_id=p.id and not exists(select 1 from public.dispatch_packages dp join public.dispatches d on d.id=dp.dispatch_id where dp.packing_list_package_id=k.id and dp.is_committed and d.status='DISPATCHED'))then raise exception 'Packing List has no packages available for Dispatch';end if;
 insert into public.dispatches(dispatch_number,company_id,order_id,pi_id,packing_list_id,customer_name_snapshot,pi_number_snapshot,order_number_snapshot,packing_list_number_snapshot,customer_po_number_snapshot,project_name_snapshot,shipping_address_snapshot,created_by,updated_by)
 values(public.allocate_business_number('DISPATCH'),p.company_id,p.order_id,p.pi_id,p.id,p.customer_name_snapshot,p.pi_number_snapshot,p.order_number_snapshot,p.packing_list_number,p.customer_po_number_snapshot,p.project_name_snapshot,p.shipping_address_snapshot,auth.uid(),auth.uid()) returning id into v_id;
 insert into public.dispatch_activities(dispatch_id,activity_type,description,created_by)values(v_id,'CREATED','Dispatch Draft created from Packing List '||p.packing_list_number,auth.uid());
 return v_id;
end; $$;

create function public.save_dispatch(p_id uuid,p_data jsonb,p_package_ids uuid[]) returns void
language plpgsql security definer set search_path='' as $$
declare d public.dispatches%rowtype;v_old integer;v_new integer;
begin
 select * into d from public.dispatches where id=p_id and public.can_manage_dispatch(id) for update;
 if not found then raise exception 'Dispatch Draft not found or not editable';end if;
 if p_package_ids is null then p_package_ids:=array[]::uuid[];end if;
 if exists(select 1 from unnest(p_package_ids) x group by x having count(*)>1)then raise exception 'A package was selected more than once';end if;
 if exists(select 1 from unnest(p_package_ids) x where not exists(select 1 from public.packing_list_packages p where p.id=x and p.packing_list_id=d.packing_list_id))then raise exception 'Selected package does not belong to this Packing List';end if;
 if exists(select 1 from unnest(p_package_ids) x where exists(select 1 from public.dispatch_packages dp join public.dispatches dx on dx.id=dp.dispatch_id where dp.packing_list_package_id=x and dp.is_committed and dx.status='DISPATCHED' and dx.id<>p_id))then raise exception 'A selected package is already Dispatched';end if;
 select count(*) into v_old from public.dispatch_packages where dispatch_id=p_id;
 delete from public.dispatch_packages where dispatch_id=p_id;
 insert into public.dispatch_packages(dispatch_id,packing_list_package_id)select p_id,x from unnest(p_package_ids)x;
 v_new:=cardinality(p_package_ids);
 update public.dispatches set
  dispatch_date=coalesce(nullif(p_data->>'dispatch_date','')::date,dispatch_date),
  shipping_address_snapshot=coalesce(p_data->'shipping_address',shipping_address_snapshot),
  transport_mode=nullif(p_data->>'transport_mode',''),
  transporter_name=nullif(trim(p_data->>'transporter_name'),''),
  transporter_contact=nullif(trim(p_data->>'transporter_contact'),''),
  vehicle_number=upper(nullif(trim(p_data->>'vehicle_number'),'')),
  driver_name=nullif(trim(p_data->>'driver_name'),''),
  driver_contact=nullif(trim(p_data->>'driver_contact'),''),
  lr_gr_number=nullif(trim(p_data->>'lr_gr_number'),''),
  lr_gr_date=nullif(p_data->>'lr_gr_date','')::date,
  tracking_awb_number=nullif(trim(p_data->>'tracking_awb_number'),''),
  freight_type=nullif(p_data->>'freight_type',''),
  freight_amount=coalesce(nullif(p_data->>'freight_amount','')::numeric,0),
  freight_paid_by=nullif(p_data->>'freight_paid_by',''),
  eway_bill_number=nullif(trim(p_data->>'eway_bill_number'),''),
  eway_bill_date=nullif(p_data->>'eway_bill_date','')::date,
  eway_bill_expiry_date=nullif(p_data->>'eway_bill_expiry_date','')::date,
  remarks=nullif(p_data->>'remarks',''),
  total_packages=v_new,
  total_net_weight=coalesce((select sum(coalesce(k.net_weight_kg,0))from public.packing_list_packages k where k.id=any(p_package_ids)),0),
  total_gross_weight=coalesce((select sum(coalesce(k.gross_weight_kg,0))from public.packing_list_packages k where k.id=any(p_package_ids)),0),
  updated_by=auth.uid(),updated_at=now()
 where id=p_id;
 insert into public.dispatch_activities(dispatch_id,activity_type,description,created_by)values(p_id,'EDITED','Dispatch Draft updated',auth.uid());
 if v_new>v_old then insert into public.dispatch_activities(dispatch_id,activity_type,description,created_by)values(p_id,'PACKAGE_ADDED',(v_new-v_old)||' package(s) added',auth.uid());
 elsif v_new<v_old then insert into public.dispatch_activities(dispatch_id,activity_type,description,created_by)values(p_id,'PACKAGE_REMOVED',(v_old-v_new)||' package(s) removed',auth.uid());end if;
end; $$;

create function public.confirm_dispatch(p_id uuid) returns void
language plpgsql security definer set search_path='' as $$
declare d public.dispatches%rowtype;v_ids uuid[];
begin
 if not public.can_manage_crm()then raise exception 'Manager or Admin access is required to confirm Dispatch';end if;
 select * into d from public.dispatches where id=p_id and status='DRAFT' and public.can_view_dispatch(id) for update;
 if not found then raise exception 'Dispatch Draft not found or inaccessible';end if;
 perform pg_advisory_xact_lock(hashtextextended(d.packing_list_id::text,0));
 if not exists(select 1 from public.packing_lists where id=d.packing_list_id and status in('FINALIZED','PARTIALLY_DISPATCHED'))then raise exception 'Packing List is not eligible for Dispatch';end if;
 select array_agg(packing_list_package_id order by packing_list_package_id)into v_ids from public.dispatch_packages where dispatch_id=p_id;
 if coalesce(cardinality(v_ids),0)=0 then raise exception 'Select at least one package';end if;
 perform 1 from public.packing_list_packages where id=any(v_ids) order by id for update;
 if exists(select 1 from unnest(v_ids)x where not exists(select 1 from public.packing_list_packages p where p.id=x and p.packing_list_id=d.packing_list_id))then raise exception 'A selected package no longer belongs to this Packing List';end if;
 if exists(select 1 from public.dispatch_packages dp join public.dispatches dx on dx.id=dp.dispatch_id where dp.packing_list_package_id=any(v_ids)and dp.is_committed and dx.status='DISPATCHED'and dx.id<>p_id)then raise exception 'A selected package has already been Dispatched';end if;
 if d.dispatch_date is null or d.shipping_address_snapshot is null or d.shipping_address_snapshot='{}'::jsonb or d.transport_mode is null then raise exception 'Dispatch Date, Shipping Address and Transport Mode are required';end if;
 if d.freight_amount<0 then raise exception 'Freight Amount cannot be negative';end if;
 update public.dispatch_packages set is_committed=true,committed_at=now()where dispatch_id=p_id;
 update public.dispatches set status='DISPATCHED',confirmed_by=auth.uid(),confirmed_at=now(),updated_by=auth.uid(),updated_at=now()where id=p_id;
 insert into public.dispatch_activities(dispatch_id,activity_type,description,created_by)values(p_id,'CONFIRMED','Dispatch confirmed; packages physically dispatched',auth.uid());
 perform public.refresh_packing_list_dispatch_status(d.packing_list_id);
exception when unique_violation then raise exception 'A selected package was concurrently dispatched by another user';
end; $$;

create function public.cancel_dispatch(p_id uuid,p_reason text) returns void
language plpgsql security definer set search_path='' as $$
declare d public.dispatches%rowtype;
begin
 if nullif(trim(p_reason),'')is null then raise exception 'Cancellation reason is required';end if;
 select * into d from public.dispatches where id=p_id and status in('DRAFT','DISPATCHED')and public.can_view_dispatch(id) for update;
 if not found then raise exception 'Dispatch not found or not cancellable';end if;
 if d.status='DISPATCHED'and not public.can_manage_crm()then raise exception 'Manager or Admin access is required to cancel a confirmed Dispatch';end if;
 if d.status='DRAFT'and not(public.can_manage_crm()or d.created_by=auth.uid())then raise exception 'You cannot cancel this Dispatch Draft';end if;
 perform pg_advisory_xact_lock(hashtextextended(d.packing_list_id::text,0));
 perform set_config('app.dispatch_lifecycle_update','1',true);
 update public.dispatch_packages set is_committed=false,committed_at=null where dispatch_id=p_id;
 update public.dispatches set status='CANCELLED',cancelled_by=auth.uid(),cancelled_at=now(),cancellation_reason=trim(p_reason),updated_by=auth.uid(),updated_at=now()where id=p_id;
 insert into public.dispatch_activities(dispatch_id,activity_type,description,created_by)values(p_id,'CANCELLED','Dispatch cancelled: '||trim(p_reason),auth.uid());
 perform public.refresh_packing_list_dispatch_status(d.packing_list_id);
end; $$;

create function public.get_pi_dispatch_summary(p_pi_id uuid)
returns table(pi_quantity numeric,packed_quantity numeric,dispatched_quantity numeric,packing_status text,dispatch_status text)
language sql stable security definer set search_path='' as $$
 with q as(
  select coalesce(sum(quantity),0)::numeric pi_quantity from public.proforma_invoice_items where proforma_invoice_id=p_pi_id
 ),pk as(
  select coalesce(sum(i.current_packing_quantity),0)::numeric packed_quantity
  from public.packing_list_items i join public.packing_lists p on p.id=i.packing_list_id
  where p.pi_id=p_pi_id and p.status in('FINALIZED','PARTIALLY_DISPATCHED','DISPATCHED')
 ),ds as(
  select coalesce(sum(c.quantity),0)::numeric dispatched_quantity
  from public.dispatch_packages dp join public.dispatches d on d.id=dp.dispatch_id
  join public.packing_list_packages k on k.id=dp.packing_list_package_id
  join public.packing_list_package_contents c on c.package_id=k.id
  where d.pi_id=p_pi_id and d.status='DISPATCHED'and dp.is_committed
 )
 select q.pi_quantity,pk.packed_quantity,ds.dispatched_quantity,
 case when pk.packed_quantity=0 then 'Not Packed' when pk.packed_quantity>=q.pi_quantity then 'Fully Packed' else 'Partially Packed'end,
 case when ds.dispatched_quantity=0 then 'Not Dispatched' when pk.packed_quantity>=q.pi_quantity and ds.dispatched_quantity>=q.pi_quantity then 'Fully Dispatched' else 'Partially Dispatched'end
 from q,pk,ds
$$;

create function public.protect_dispatch() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 new.dispatch_number:=old.dispatch_number;new.company_id:=old.company_id;new.order_id:=old.order_id;new.pi_id:=old.pi_id;new.packing_list_id:=old.packing_list_id;new.created_by:=old.created_by;new.created_at:=old.created_at;
 if old.status<>'DRAFT'and coalesce(current_setting('app.dispatch_lifecycle_update',true),'0')<>'1'then raise exception 'Confirmed or Cancelled Dispatch cannot be edited';end if;
 return new;
end; $$;
create trigger protect_dispatch before update on public.dispatches for each row execute function public.protect_dispatch();
create trigger dispatches_updated_at before update on public.dispatches for each row execute function public.set_updated_at();

create function public.log_dispatch_document() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 insert into public.dispatch_activities(dispatch_id,activity_type,description,created_by)
 values(new.dispatch_id,case when new.is_active then 'DOCUMENT_UPLOADED'else'DOCUMENT_REMOVED'end,
 case when new.is_active then 'Dispatch document uploaded: 'else'Dispatch document removed: 'end||new.file_name,auth.uid());
 return new;
end; $$;
create trigger log_dispatch_document after insert or update of is_active on public.dispatch_documents for each row execute function public.log_dispatch_document();

alter table public.dispatches enable row level security;
alter table public.dispatch_packages enable row level security;
alter table public.dispatch_documents enable row level security;
alter table public.dispatch_activities enable row level security;
create policy "Dispatches visible"on public.dispatches for select to authenticated using(public.can_view_dispatch(id));
create policy "Dispatch packages visible"on public.dispatch_packages for select to authenticated using(public.can_view_dispatch(dispatch_id));
create policy "Dispatch documents visible"on public.dispatch_documents for select to authenticated using(public.can_view_dispatch(dispatch_id));
create policy "Dispatch documents insert"on public.dispatch_documents for insert to authenticated with check(public.can_view_dispatch(dispatch_id)and uploaded_by=auth.uid());
create policy "Dispatch documents update"on public.dispatch_documents for update to authenticated using(public.can_view_dispatch(dispatch_id)and(uploaded_by=auth.uid()or public.can_manage_crm()))with check(public.can_view_dispatch(dispatch_id));
create policy "Dispatch activities visible"on public.dispatch_activities for select to authenticated using(public.can_view_dispatch(dispatch_id));
grant select on public.dispatches,public.dispatch_packages,public.dispatch_documents,public.dispatch_activities to authenticated;
grant insert,update on public.dispatch_documents to authenticated;
revoke all on function public.create_dispatch(uuid),public.save_dispatch(uuid,jsonb,uuid[]),public.confirm_dispatch(uuid),public.cancel_dispatch(uuid,text),public.refresh_packing_list_dispatch_status(uuid),public.get_pi_dispatch_summary(uuid)from public,anon;
grant execute on function public.can_view_dispatch(uuid),public.can_manage_dispatch(uuid),public.create_dispatch(uuid),public.save_dispatch(uuid,jsonb,uuid[]),public.confirm_dispatch(uuid),public.cancel_dispatch(uuid,text),public.get_pi_dispatch_summary(uuid)to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('dispatch-documents','dispatch-documents',false,10485760,array['application/pdf','image/jpeg','image/png','image/webp'])
on conflict(id)do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create policy "Dispatch document objects read"on storage.objects for select to authenticated
 using(bucket_id='dispatch-documents'and public.can_view_dispatch((storage.foldername(name))[1]::uuid));
create policy "Dispatch document objects insert"on storage.objects for insert to authenticated
 with check(bucket_id='dispatch-documents'and public.can_view_dispatch((storage.foldername(name))[1]::uuid));
create policy "Dispatch document objects delete"on storage.objects for delete to authenticated
 using(bucket_id='dispatch-documents'and(owner_id=auth.uid()::text or public.can_manage_crm())and public.can_view_dispatch((storage.foldername(name))[1]::uuid));

-- Phase 6B packing states remain committed for Phase 6A balance validation.
create or replace function public.finalize_packing_list(p_id uuid)returns void language plpgsql security definer set search_path = '' as $$declare vpi uuid;r record;begin select pi_id into vpi from public.packing_lists where id=p_id and public.can_manage_packing_list(id)for update;if not found then raise exception 'Draft Packing List not editable';end if;perform pg_advisory_xact_lock(hashtextextended(vpi::text,0));if not exists(select 1 from public.proforma_invoices where id=vpi and status in('ISSUED','ACCEPTED'))then raise exception 'PI is not eligible';end if;if not exists(select 1 from public.packing_list_items where packing_list_id=p_id and current_packing_quantity>0)then raise exception 'Select a packing quantity';end if;for r in select i.id,i.pi_item_id,i.pi_quantity,i.current_packing_quantity,coalesce((select sum(x.current_packing_quantity)from public.packing_list_items x join public.packing_lists p on p.id=x.packing_list_id where x.pi_item_id=i.pi_item_id and p.status in('FINALIZED','PARTIALLY_DISPATCHED','DISPATCHED')and p.id<>p_id),0)packed,coalesce((select sum(c.quantity)from public.packing_list_package_contents c join public.packing_list_packages k on k.id=c.package_id where c.packing_list_item_id=i.id and k.packing_list_id=p_id),0)allocated from public.packing_list_items i where i.packing_list_id=p_id loop if r.packed+r.current_packing_quantity>r.pi_quantity then raise exception 'Packing exceeds remaining PI balance';end if;if r.allocated<>r.current_packing_quantity then raise exception 'Every packing quantity must be fully allocated';end if;end loop;if exists(select 1 from public.packing_list_package_contents c join public.packing_list_packages k on k.id=c.package_id join public.packing_list_items i on i.id=c.packing_list_item_id where k.packing_list_id=p_id and i.item_volume_mm3>0 group by k.id,k.volume_mm3 having sum(c.quantity*i.item_volume_mm3)>k.volume_mm3)then raise exception 'Allocated theoretical item volume exceeds package volume';end if;if exists(select 1 from public.packing_list_package_contents c join public.packing_list_packages k on k.id=c.package_id join public.packing_list_items i on i.id=c.packing_list_item_id where k.packing_list_id=p_id and i.item_length_mm>0 and i.item_breadth_mm>0 and i.item_height_mm>0 and not((i.item_length_mm<=k.length_mm and i.item_breadth_mm<=k.breadth_mm and i.item_height_mm<=k.height_mm)or(i.item_length_mm<=k.length_mm and i.item_height_mm<=k.breadth_mm and i.item_breadth_mm<=k.height_mm)or(i.item_breadth_mm<=k.length_mm and i.item_length_mm<=k.breadth_mm and i.item_height_mm<=k.height_mm)or(i.item_breadth_mm<=k.length_mm and i.item_height_mm<=k.breadth_mm and i.item_length_mm<=k.height_mm)or(i.item_height_mm<=k.length_mm and i.item_length_mm<=k.breadth_mm and i.item_breadth_mm<=k.height_mm)or(i.item_height_mm<=k.length_mm and i.item_breadth_mm<=k.breadth_mm and i.item_length_mm<=k.height_mm)))then raise exception 'Item dimensions exceed package dimensions';end if;update public.packing_lists set status='FINALIZED',finalized_by=auth.uid(),finalized_at=now(),updated_by=auth.uid(),updated_at=now()where id=p_id;insert into public.packing_list_activities values(default,p_id,'FINALIZED','Packing List finalized',auth.uid(),default);end; $$;

commit;
