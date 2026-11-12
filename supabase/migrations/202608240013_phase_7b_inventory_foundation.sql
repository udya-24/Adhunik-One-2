-- Adhunik ERP - Phase 7B Inventory Foundation and Stock Ledger
-- Run once after 202608240012_phase_7a_enterprise_item_master.sql.
begin;

alter table public.item_types add column code_prefix text;
alter table public.item_types add column number_padding integer not null default 4 check(number_padding between 1 and 10);
alter table public.item_types add column automatic_code_enabled boolean not null default false;
alter table public.item_types add column current_value bigint not null default 0 check(current_value>=0);
create unique index item_types_active_auto_prefix_unique on public.item_types(upper(trim(code_prefix)))where automatic_code_enabled and is_active;
alter table public.item_types add constraint item_types_auto_code_config check(not automatic_code_enabled or(nullif(trim(code_prefix),'')is not null and code_prefix~'^[A-Za-z0-9][A-Za-z0-9_-]*$'));

create or replace function public.allocate_item_code(p_item_type_id uuid)returns text language plpgsql security definer set search_path=''as $$
declare t public.item_types%rowtype;v bigint;v_code text;
begin
 select * into t from public.item_types where id=p_item_type_id and is_active and automatic_code_enabled for update;
 if not found then raise exception 'Active automatic Item Type configuration is required';end if;
 loop
  v:=t.current_value+1;
  update public.item_types set current_value=v,updated_at=now(),updated_by=auth.uid()where id=t.id;
  v_code:=upper(trim(t.code_prefix))||'-'||lpad(v::text,t.number_padding,'0');
  exit when not exists(select 1 from public.items where lower(item_code)=lower(v_code));
  t.current_value:=v;
 end loop;
 return v_code;
end;$$;
create function public.auto_allocate_item_code()returns trigger language plpgsql security definer set search_path=''as $$
begin
 if new.item_type_id is not null and exists(select 1 from public.item_types where id=new.item_type_id and automatic_code_enabled)then
  if tg_op='INSERT'then
   if nullif(trim(new.item_code),'')is not null then raise exception 'Item Code is database-generated for this Item Type';end if;
   new.item_code:=public.allocate_item_code(new.item_type_id);
  elsif new.item_type_id is distinct from old.item_type_id then raise exception 'Item Type cannot switch into automatic coding after creation';end if;
 end if;
 return new;
end;$$;
create trigger auto_allocate_item_code before insert or update on public.items for each row execute function public.auto_allocate_item_code();

create table public.stock_locations(
 id uuid primary key default gen_random_uuid(),code text not null check(length(trim(code))>0),name text not null check(length(trim(name))>0),description text,is_default boolean not null default false,is_active boolean not null default true,
 created_at timestamptz not null default now(),created_by uuid not null references auth.users(id)default auth.uid(),updated_at timestamptz not null default now(),updated_by uuid references auth.users(id)default auth.uid()
);
create unique index stock_locations_code_unique on public.stock_locations(upper(trim(code)));
create unique index stock_locations_name_unique on public.stock_locations(lower(trim(name)));
create unique index stock_locations_one_default on public.stock_locations(is_default)where is_default and is_active;

create table public.inventory_balances(
 item_id uuid not null references public.items(id)on delete restrict,location_id uuid not null references public.stock_locations(id)on delete restrict,
 on_hand_quantity numeric(24,6)not null default 0 check(on_hand_quantity>=0),reserved_quantity numeric(24,6)not null default 0 check(reserved_quantity>=0),damaged_quantity numeric(24,6)not null default 0 check(damaged_quantity>=0),updated_at timestamptz not null default now(),
 primary key(item_id,location_id),constraint inventory_reserved_within_on_hand check(reserved_quantity<=on_hand_quantity)
);
create index inventory_balances_location on public.inventory_balances(location_id,item_id);

create table public.inventory_transactions(
 id uuid primary key default gen_random_uuid(),transaction_type text not null check(transaction_type in('OPENING_STOCK','STOCK_IN','STOCK_OUT','RESERVE','UNRESERVE','DAMAGE','DAMAGE_RECOVERY','ADJUSTMENT_IN','ADJUSTMENT_OUT','TRANSFER_OUT','TRANSFER_IN')),
 item_id uuid not null references public.items(id)on delete restrict,location_id uuid not null references public.stock_locations(id)on delete restrict,quantity numeric(24,6)not null check(quantity>0),
 on_hand_delta numeric(24,6)not null default 0,reserved_delta numeric(24,6)not null default 0,damaged_delta numeric(24,6)not null default 0,
 transaction_date date not null default current_date,reference_type text,reference_id uuid,reference_number text,transfer_group_id uuid,reversal_of uuid references public.inventory_transactions(id)on delete restrict,reason text not null check(length(trim(reason))>0),remarks text,
 created_by uuid not null references auth.users(id)on delete restrict default auth.uid(),created_at timestamptz not null default now()
);
create index inventory_transactions_item_date on public.inventory_transactions(item_id,created_at desc);
create index inventory_transactions_location_date on public.inventory_transactions(location_id,created_at desc);
create index inventory_transactions_type_date on public.inventory_transactions(transaction_type,transaction_date desc);
create index inventory_transactions_creator on public.inventory_transactions(created_by,created_at desc);
create unique index inventory_opening_once on public.inventory_transactions(item_id,location_id)where transaction_type='OPENING_STOCK'and reversal_of is null;
create unique index inventory_dispatch_stockout_once on public.inventory_transactions(reference_id,item_id,location_id)where reference_type='DISPATCH'and transaction_type='STOCK_OUT'and reversal_of is null;
create unique index inventory_reversal_once on public.inventory_transactions(reversal_of)where reversal_of is not null;

create function public.prevent_inventory_history_change()returns trigger language plpgsql set search_path=''as $$begin raise exception 'Inventory ledger history is immutable; create a correcting transaction';end;$$;
create trigger inventory_transactions_immutable before update or delete on public.inventory_transactions for each row execute function public.prevent_inventory_history_change();
create function public.prevent_balance_direct_change()returns trigger language plpgsql set search_path=''as $$begin if coalesce(current_setting('app.inventory_posting',true),'0')<>'1'then raise exception 'Inventory balances can only change through inventory posting functions';end if;return new;end;$$;
create trigger inventory_balances_control before insert or update or delete on public.inventory_balances for each row execute function public.prevent_balance_direct_change();

create function public.post_inventory_movement(p_transaction_type text,p_item_id uuid,p_location_id uuid,p_quantity numeric,p_transaction_date date,p_reference_type text,p_reference_id uuid,p_reference_number text,p_reason text,p_remarks text,p_transfer_group_id uuid default null,p_reversal_of uuid default null)returns uuid language plpgsql security definer set search_path=''as $$
declare i public.items%rowtype;l public.stock_locations%rowtype;b public.inventory_balances%rowtype;v_on numeric:=0;v_res numeric:=0;v_dmg numeric:=0;v_id uuid;v_type text:=upper(trim(p_transaction_type));
begin
 if not public.has_active_erp_access()then raise exception 'Active ERP access is required';end if;
 if p_quantity is null or p_quantity<=0 then raise exception 'Quantity must be greater than zero';end if;
 if nullif(trim(p_reason),'')is null then raise exception 'Reason is required';end if;
 if v_type in('TRANSFER_OUT','TRANSFER_IN')and coalesce(current_setting('app.inventory_transfer',true),'0')<>'1'then raise exception 'Use the atomic Stock Transfer function';end if; if p_reversal_of is not null then if public.current_erp_role()not in('ADMIN','MANAGER')then raise exception 'Manager or Admin access is required for reversals';end if;if not exists(select 1 from public.inventory_transactions x where x.id=p_reversal_of and x.item_id=p_item_id and x.location_id=p_location_id and x.quantity=p_quantity and x.transaction_type='STOCK_OUT'and x.reference_id=p_reference_id)then raise exception 'Invalid inventory reversal';end if;end if;
 if v_type in('OPENING_STOCK','ADJUSTMENT_IN','ADJUSTMENT_OUT')and public.current_erp_role()not in('ADMIN','MANAGER')then raise exception 'Manager or Admin access is required for opening stock and adjustments';end if;
 select * into i from public.items where id=p_item_id and(p_reversal_of is not null or is_active);if not found then raise exception 'Active Item not found';end if;
 select * into l from public.stock_locations where id=p_location_id and(p_reversal_of is not null or is_active);if not found then raise exception 'Active Stock Location not found';end if;
 if v_type='OPENING_STOCK'and exists(select 1 from public.inventory_transactions where item_id=p_item_id and location_id=p_location_id and transaction_type='OPENING_STOCK'and reversal_of is null)then raise exception 'Opening Stock already exists for this Item and Location; use an Adjustment';end if;
 perform set_config('app.inventory_posting','1',true);
 insert into public.inventory_balances(item_id,location_id)values(p_item_id,p_location_id)on conflict do nothing;
 select * into b from public.inventory_balances where item_id=p_item_id and location_id=p_location_id for update;
 case v_type
  when 'OPENING_STOCK'then v_on:=p_quantity;
  when 'STOCK_IN'then v_on:=p_quantity;
  when 'STOCK_OUT'then v_on:=-p_quantity;
  when 'RESERVE'then v_res:=p_quantity;
  when 'UNRESERVE'then v_res:=-p_quantity;
  when 'DAMAGE'then v_on:=-p_quantity;v_dmg:=p_quantity;
  when 'DAMAGE_RECOVERY'then v_on:=p_quantity;v_dmg:=-p_quantity;
  when 'ADJUSTMENT_IN'then v_on:=p_quantity;
  when 'ADJUSTMENT_OUT'then v_on:=-p_quantity;
  when 'TRANSFER_OUT'then v_on:=-p_quantity;
  when 'TRANSFER_IN'then v_on:=p_quantity;
  else raise exception 'Unsupported inventory transaction type';
 end case;
 if b.on_hand_quantity+v_on<0 then raise exception 'Insufficient usable On Hand stock';end if;
 if b.reserved_quantity+v_res<0 then raise exception 'Cannot release more than Reserved stock';end if;
 if b.damaged_quantity+v_dmg<0 then raise exception 'Cannot recover more than Damaged stock';end if;
 if b.reserved_quantity+v_res>b.on_hand_quantity+v_on then raise exception 'Insufficient Available stock';end if;
 if v_on<0 and b.on_hand_quantity-b.reserved_quantity<p_quantity then raise exception 'Insufficient Available stock';end if;
 insert into public.inventory_transactions(transaction_type,item_id,location_id,quantity,on_hand_delta,reserved_delta,damaged_delta,transaction_date,reference_type,reference_id,reference_number,transfer_group_id,reversal_of,reason,remarks,created_by)
 values(v_type,p_item_id,p_location_id,p_quantity,v_on,v_res,v_dmg,coalesce(p_transaction_date,current_date),nullif(trim(p_reference_type),''),p_reference_id,nullif(trim(p_reference_number),''),p_transfer_group_id,p_reversal_of,trim(p_reason),nullif(trim(p_remarks),''),auth.uid())returning id into v_id;
 update public.inventory_balances set on_hand_quantity=on_hand_quantity+v_on,reserved_quantity=reserved_quantity+v_res,damaged_quantity=damaged_quantity+v_dmg,updated_at=now()where item_id=p_item_id and location_id=p_location_id;
 return v_id;
end;$$;

create function public.transfer_inventory_stock(p_item_id uuid,p_from_location_id uuid,p_to_location_id uuid,p_quantity numeric,p_transaction_date date,p_reference_number text,p_reason text,p_remarks text)returns uuid language plpgsql security definer set search_path=''as $$
declare v_group uuid:=gen_random_uuid();
begin
 perform set_config('app.inventory_transfer','1',true);
 if p_from_location_id=p_to_location_id then raise exception 'Source and destination locations must differ';end if;
 perform pg_advisory_xact_lock(hashtextextended(p_item_id::text||least(p_from_location_id::text,p_to_location_id::text),0));
 perform public.post_inventory_movement('TRANSFER_OUT',p_item_id,p_from_location_id,p_quantity,p_transaction_date,'TRANSFER',v_group,p_reference_number,p_reason,p_remarks,v_group,null);
 perform public.post_inventory_movement('TRANSFER_IN',p_item_id,p_to_location_id,p_quantity,p_transaction_date,'TRANSFER',v_group,p_reference_number,p_reason,p_remarks,v_group,null);
 return v_group;
end;$$;

create function public.protect_stock_location()returns trigger language plpgsql set search_path=''as $$
begin
 new.code:=upper(trim(new.code));new.name:=trim(new.name);new.created_at:=old.created_at;new.created_by:=old.created_by;
 if old.is_active and not new.is_active and exists(select 1 from public.inventory_balances where location_id=old.id and(on_hand_quantity<>0 or reserved_quantity<>0 or damaged_quantity<>0))then raise exception 'Transfer or adjust all stock before deactivating this Location';end if;
 return new;
end;$$;
create trigger protect_stock_location before update on public.stock_locations for each row execute function public.protect_stock_location();
create trigger stock_locations_updated_at before update on public.stock_locations for each row execute function public.set_updated_at();

alter table public.dispatches add column stock_location_id uuid references public.stock_locations(id)on delete restrict;
create index dispatches_stock_location on public.dispatches(stock_location_id)where stock_location_id is not null;

create or replace function public.create_dispatch(p_packing_list_id uuid)returns uuid language plpgsql security definer set search_path=''as $$
declare p public.packing_lists%rowtype;v_id uuid;v_location uuid;
begin
 if not public.has_active_erp_access()then raise exception 'Active ERP access is required';end if;
 select * into p from public.packing_lists where id=p_packing_list_id and status in('FINALIZED','PARTIALLY_DISPATCHED')and public.can_view_packing_list(id)for update;
 if not found then raise exception 'Only an accessible Finalized Packing List with available packages can be dispatched';end if;
 if not exists(select 1 from public.packing_list_packages k where k.packing_list_id=p.id and not exists(select 1 from public.dispatch_packages dp join public.dispatches d on d.id=dp.dispatch_id where dp.packing_list_package_id=k.id and dp.is_committed and d.status='DISPATCHED'))then raise exception 'Packing List has no packages available for Dispatch';end if;
 select id into v_location from public.stock_locations where is_default and is_active;
 insert into public.dispatches(dispatch_number,company_id,order_id,pi_id,packing_list_id,stock_location_id,customer_name_snapshot,pi_number_snapshot,order_number_snapshot,packing_list_number_snapshot,customer_po_number_snapshot,project_name_snapshot,shipping_address_snapshot,created_by,updated_by)
 values(public.allocate_business_number('DISPATCH'),p.company_id,p.order_id,p.pi_id,p.id,v_location,p.customer_name_snapshot,p.pi_number_snapshot,p.order_number_snapshot,p.packing_list_number,p.customer_po_number_snapshot,p.project_name_snapshot,p.shipping_address_snapshot,auth.uid(),auth.uid())returning id into v_id;
 insert into public.dispatch_activities(dispatch_id,activity_type,description,created_by)values(v_id,'CREATED','Dispatch Draft created from Packing List '||p.packing_list_number,auth.uid());return v_id;
end;$$;

create or replace function public.save_dispatch(p_id uuid,p_data jsonb,p_package_ids uuid[])returns void language plpgsql security definer set search_path=''as $$
declare d public.dispatches%rowtype;v_old int;v_new int;v_location uuid;
begin
 select * into d from public.dispatches where id=p_id and public.can_manage_dispatch(id)for update;if not found then raise exception 'Dispatch Draft not found or not editable';end if;
 if p_package_ids is null then p_package_ids:=array[]::uuid[];end if;if exists(select 1 from unnest(p_package_ids)x group by x having count(*)>1)then raise exception 'A package was selected more than once';end if;
 if exists(select 1 from unnest(p_package_ids)x where not exists(select 1 from public.packing_list_packages p where p.id=x and p.packing_list_id=d.packing_list_id))then raise exception 'Selected package does not belong to this Packing List';end if;
 if exists(select 1 from unnest(p_package_ids)x where exists(select 1 from public.dispatch_packages dp join public.dispatches dx on dx.id=dp.dispatch_id where dp.packing_list_package_id=x and dp.is_committed and dx.status='DISPATCHED'and dx.id<>p_id))then raise exception 'A selected package is already Dispatched';end if;
 v_location:=nullif(p_data->>'stock_location_id','')::uuid;if v_location is not null and not exists(select 1 from public.stock_locations where id=v_location and is_active)then raise exception 'Select an active Stock Location';end if;
 select count(*)into v_old from public.dispatch_packages where dispatch_id=p_id;delete from public.dispatch_packages where dispatch_id=p_id;insert into public.dispatch_packages(dispatch_id,packing_list_package_id)select p_id,x from unnest(p_package_ids)x;v_new:=cardinality(p_package_ids);
 update public.dispatches set dispatch_date=coalesce(nullif(p_data->>'dispatch_date','')::date,dispatch_date),stock_location_id=v_location,shipping_address_snapshot=coalesce(p_data->'shipping_address',shipping_address_snapshot),transport_mode=nullif(p_data->>'transport_mode',''),transporter_name=nullif(trim(p_data->>'transporter_name'),''),transporter_contact=nullif(trim(p_data->>'transporter_contact'),''),vehicle_number=upper(nullif(trim(p_data->>'vehicle_number'),'')),driver_name=nullif(trim(p_data->>'driver_name'),''),driver_contact=nullif(trim(p_data->>'driver_contact'),''),lr_gr_number=nullif(trim(p_data->>'lr_gr_number'),''),lr_gr_date=nullif(p_data->>'lr_gr_date','')::date,tracking_awb_number=nullif(trim(p_data->>'tracking_awb_number'),''),freight_type=nullif(p_data->>'freight_type',''),freight_amount=coalesce(nullif(p_data->>'freight_amount','')::numeric,0),freight_paid_by=nullif(p_data->>'freight_paid_by',''),eway_bill_number=nullif(trim(p_data->>'eway_bill_number'),''),eway_bill_date=nullif(p_data->>'eway_bill_date','')::date,eway_bill_expiry_date=nullif(p_data->>'eway_bill_expiry_date','')::date,remarks=nullif(p_data->>'remarks',''),total_packages=v_new,total_net_weight=coalesce((select sum(coalesce(k.net_weight_kg,0))from public.packing_list_packages k where k.id=any(p_package_ids)),0),total_gross_weight=coalesce((select sum(coalesce(k.gross_weight_kg,0))from public.packing_list_packages k where k.id=any(p_package_ids)),0),updated_by=auth.uid(),updated_at=now()where id=p_id;
 insert into public.dispatch_activities(dispatch_id,activity_type,description,created_by)values(p_id,'EDITED','Dispatch Draft updated',auth.uid());if v_new>v_old then insert into public.dispatch_activities(dispatch_id,activity_type,description,created_by)values(p_id,'PACKAGE_ADDED',(v_new-v_old)||' package(s) added',auth.uid());elsif v_new<v_old then insert into public.dispatch_activities(dispatch_id,activity_type,description,created_by)values(p_id,'PACKAGE_REMOVED',(v_old-v_new)||' package(s) removed',auth.uid());end if;
end;$$;

create or replace function public.confirm_dispatch(p_id uuid)returns void language plpgsql security definer set search_path=''as $$
declare d public.dispatches%rowtype;v_ids uuid[];r record;
begin
 if not public.can_manage_crm()then raise exception 'Manager or Admin access is required to confirm Dispatch';end if;
 select * into d from public.dispatches where id=p_id and status='DRAFT'and public.can_view_dispatch(id)for update;if not found then raise exception 'Dispatch Draft not found or inaccessible';end if;
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

create or replace function public.cancel_dispatch(p_id uuid,p_reason text)returns void language plpgsql security definer set search_path=''as $$
declare d public.dispatches%rowtype;r record;
begin
 if nullif(trim(p_reason),'')is null then raise exception 'Cancellation reason is required';end if;
 select * into d from public.dispatches where id=p_id and status in('DRAFT','DISPATCHED')and public.can_view_dispatch(id)for update;if not found then raise exception 'Dispatch not found or not cancellable';end if;
 if d.status='DISPATCHED'and not public.can_manage_crm()then raise exception 'Manager or Admin access is required to cancel a confirmed Dispatch';end if;
 if d.status='DRAFT'and not(public.can_manage_crm()or d.created_by=auth.uid())then raise exception 'You cannot cancel this Dispatch Draft';end if;
 perform pg_advisory_xact_lock(hashtextextended(d.packing_list_id::text,0));
 if d.status='DISPATCHED'then
  for r in select * from public.inventory_transactions where reference_type='DISPATCH'and reference_id=d.id and transaction_type='STOCK_OUT'and reversal_of is null loop
   perform public.post_inventory_movement('STOCK_IN',r.item_id,r.location_id,r.quantity,current_date,'DISPATCH_REVERSAL',d.id,d.dispatch_number,'Dispatch cancellation: '||trim(p_reason),null,null,r.id);
  end loop;
 end if;
 perform set_config('app.dispatch_lifecycle_update','1',true);update public.dispatch_packages set is_committed=false,committed_at=null where dispatch_id=p_id;update public.dispatches set status='CANCELLED',cancelled_by=auth.uid(),cancelled_at=now(),cancellation_reason=trim(p_reason),updated_by=auth.uid(),updated_at=now()where id=p_id;insert into public.dispatch_activities(dispatch_id,activity_type,description,created_by)values(p_id,'CANCELLED','Dispatch cancelled: '||trim(p_reason),auth.uid());perform public.refresh_packing_list_dispatch_status(d.packing_list_id);
end;$$;

alter table public.stock_locations enable row level security;alter table public.inventory_balances enable row level security;alter table public.inventory_transactions enable row level security;
create policy "ERP read stock locations"on public.stock_locations for select to authenticated using(public.has_active_erp_access());create policy "Admins insert stock locations"on public.stock_locations for insert to authenticated with check(public.is_erp_admin()and created_by=auth.uid());create policy "Admins update stock locations"on public.stock_locations for update to authenticated using(public.is_erp_admin())with check(public.is_erp_admin());
create policy "ERP read inventory balances"on public.inventory_balances for select to authenticated using(public.has_active_erp_access());create policy "ERP read inventory ledger"on public.inventory_transactions for select to authenticated using(public.has_active_erp_access());
grant select,insert,update on public.stock_locations to authenticated;grant select on public.inventory_balances,public.inventory_transactions to authenticated;
revoke all on function public.allocate_item_code(uuid),public.post_inventory_movement(text,uuid,uuid,numeric,date,text,uuid,text,text,text,uuid,uuid),public.transfer_inventory_stock(uuid,uuid,uuid,numeric,date,text,text,text)from public,anon;
grant execute on function public.post_inventory_movement(text,uuid,uuid,numeric,date,text,uuid,text,text,text,uuid,uuid),public.transfer_inventory_stock(uuid,uuid,uuid,numeric,date,text,text,text)to authenticated;
comment on table public.inventory_transactions is 'Immutable quantity ledger and source of inventory audit history.';
comment on table public.inventory_balances is 'Transactionally maintained read model; never directly editable.';
commit;
