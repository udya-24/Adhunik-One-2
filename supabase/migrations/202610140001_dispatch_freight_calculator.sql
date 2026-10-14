begin;
insert into public.erp_permission_sections(module_key,section_key,module_name,section_name,sort_order)
values('dispatch','dispatch.freight_calculator','Dispatch','Freight Calculator',515)
on conflict(section_key) do nothing;
-- Preserve existing Dispatch access when adding the new section.
insert into public.erp_user_permissions(profile_id,section_id,can_view,can_edit,created_by,updated_by)
select p.profile_id,s.id,p.can_view,p.can_edit,p.created_by,p.updated_by
from public.erp_user_permissions p join public.erp_permission_sections old on old.id=p.section_id
cross join public.erp_permission_sections s
where old.section_key='dispatch.packing_lists' and s.section_key='dispatch.freight_calculator'
on conflict(profile_id,section_id) do nothing;
create table public.freight_calculations(
 id uuid primary key default gen_random_uuid(),
 packing_list_id uuid not null references public.packing_lists(id),
 dispatch_id uuid references public.dispatches(id),
 transport_partner text not null, from_pin text not null check(from_pin ~ '^[1-9][0-9]{5}$'), to_pin text not null check(to_pin ~ '^[1-9][0-9]{5}$'),
 origin_city text not null,destination_city text not null,origin_state text not null,destination_state text not null,zone text not null,location_type text not null,
 actual_weight numeric not null check(actual_weight>0),volumetric_weight numeric not null check(volumetric_weight>0),chargeable_weight numeric not null check(chargeable_weight>0),
 shipment_value numeric not null check(shipment_value>0),rate numeric not null check(rate>=0),
 base_freight numeric not null check(base_freight>=0),fuel_charge numeric not null check(fuel_charge>=0),oda_charge numeric not null check(oda_charge>=0),insurance numeric not null check(insurance>=0),handling_charge numeric not null check(handling_charge>=0),other_charge numeric not null check(other_charge>=0),gst numeric not null check(gst>=0),total_freight numeric not null check(total_freight>=0),
 transit_days integer,calculation_snapshot jsonb not null,
 calculated_at timestamptz not null default now(),created_by uuid not null references auth.users(id),
 check(total_freight=base_freight+fuel_charge+oda_charge+insurance+handling_charge+other_charge+gst)
);
create index freight_packing_list_latest on public.freight_calculations(packing_list_id,calculated_at desc);
create unique index freight_one_per_dispatch on public.freight_calculations(dispatch_id) where dispatch_id is not null;
alter table public.freight_calculations enable row level security;
create policy "Freight visible" on public.freight_calculations for select to authenticated using(public.can_view_packing_list(packing_list_id) and public.has_erp_permission('dispatch.freight_calculator','VIEW'));
create policy "Freight insert" on public.freight_calculations for insert to authenticated with check(public.can_view_packing_list(packing_list_id) and public.has_erp_permission('dispatch.freight_calculator','EDIT') and created_by=auth.uid() and dispatch_id is null);
grant select,insert on public.freight_calculations to authenticated;
create function public.attach_freight_estimate(p_estimate uuid,p_dispatch uuid) returns void
language plpgsql security definer set search_path='' as $$
declare f public.freight_calculations%rowtype; d public.dispatches%rowtype;
begin
 if not public.has_erp_permission('dispatch.freight_calculator','EDIT') or not public.can_manage_dispatch(p_dispatch) then raise exception 'Freight edit and draft dispatch access required.'; end if;
 select * into d from public.dispatches where id=p_dispatch for update;
 select * into f from public.freight_calculations where id=p_estimate for update;
 if f.id is null or f.packing_list_id<>d.packing_list_id or (f.dispatch_id is not null and f.dispatch_id<>d.id) then raise exception 'Estimate must belong to this Packing List and be unattached.';end if;
 if exists(select 1 from public.packing_list_packages p where p.packing_list_id=d.packing_list_id and not exists(select 1 from public.dispatch_packages dp where dp.dispatch_id=d.id and dp.packing_list_package_id=p.id)) then raise exception 'This estimate covers the full Packing List. Partial dispatch needs a separate estimate.';end if;
 update public.freight_calculations set dispatch_id=null where dispatch_id=d.id;
 update public.freight_calculations set dispatch_id=d.id where id=f.id;
 update public.dispatches set freight_amount=f.total_freight,transporter_name=f.transport_partner,updated_by=auth.uid(),updated_at=now() where id=d.id;
 insert into public.dispatch_activities(dispatch_id,activity_type,description,created_by)values(d.id,'TRANSPORT_UPDATED','Freight estimate attached',auth.uid());
end $$;
revoke all on function public.attach_freight_estimate(uuid,uuid) from public,anon;
grant execute on function public.attach_freight_estimate(uuid,uuid) to authenticated;
-- An attached full-list estimate must not silently remain attached to a partial draft.
create function public.invalidate_partial_freight() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if exists(select 1 from public.freight_calculations where dispatch_id=old.dispatch_id) and exists(select 1 from public.packing_list_packages p join public.dispatches d on d.packing_list_id=p.packing_list_id where d.id=old.dispatch_id and not exists(select 1 from public.dispatch_packages dp where dp.dispatch_id=d.id and dp.packing_list_package_id=p.id)) then
 update public.freight_calculations set dispatch_id=null where dispatch_id=old.dispatch_id;
 update public.dispatches set freight_amount=0 where id=old.dispatch_id and status='DRAFT';
 end if;
 return old;
end $$;
create constraint trigger invalidate_partial_freight after delete on public.dispatch_packages deferrable initially deferred for each row execute function public.invalidate_partial_freight();
create function public.invalidate_changed_freight() returns trigger language plpgsql security definer set search_path='' as $$
begin
 update public.freight_calculations set dispatch_id=null where dispatch_id=new.id and (total_freight<>new.freight_amount or transport_partner is distinct from new.transporter_name);
 return new;
end $$;
create trigger invalidate_changed_freight after update of freight_amount,transporter_name on public.dispatches for each row execute function public.invalidate_changed_freight();
commit;
