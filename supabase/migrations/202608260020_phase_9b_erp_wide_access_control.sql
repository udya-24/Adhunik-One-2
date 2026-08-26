-- Adhunik ERP - Phase 9B ERP-wide section access
begin;
insert into public.erp_permission_sections(module_key,section_key,module_name,section_name,sort_order)values
('employees','employees.directory','Employees','Employee Directory',100),
('configuration','configuration.companies','Configuration','Companies & Contacts',200),('configuration','configuration.masters','Configuration','Business & Item Masters',210),('configuration','configuration.document_settings','Configuration','Document Settings',220),
('crm','crm.overview','CRM','Overview',300),('crm','crm.inquiries','CRM','Inquiries',310),('crm','crm.orders','CRM','Orders',320),('crm','crm.follow_ups','CRM','Follow-ups',330),
('sales','sales.overview','Sales','Overview',400),('sales','sales.proforma_invoices','Sales','Proforma Invoices',410),
('dispatch','dispatch.overview','Dispatch','Overview',500),('dispatch','dispatch.packing_lists','Dispatch','Packing Lists',510),('dispatch','dispatch.dispatches','Dispatch','Dispatches',520),
('inventory','inventory.overview','Inventory','Overview',600),('inventory','inventory.items','Inventory','Item Master',610),('inventory','inventory.stock','Inventory','Stock Register',620),('inventory','inventory.stock_in','Inventory','Stock In & Pending Receipts',630),('inventory','inventory.movements','Inventory','Stock Movements',640),('inventory','inventory.ledger','Inventory','Stock Ledger',650),('inventory','inventory.locations','Inventory','Stock Locations',660)
on conflict(section_key)do update set module_name=excluded.module_name,section_name=excluded.section_name,sort_order=excluded.sort_order,is_active=true;

create or replace function public.get_my_erp_permissions()returns table(section_key text,can_view boolean,can_edit boolean)language sql stable security definer set search_path=''as $$
 select s.section_key,case when r.code='ADMIN'then true else coalesce(up.can_view,false)end,case when r.code='ADMIN'then true else coalesce(up.can_edit,false)end
 from public.erp_profiles p join public.erp_roles r on r.id=p.role_id cross join public.erp_permission_sections s left join public.erp_user_permissions up on up.profile_id=p.id and up.section_id=s.id
 where p.auth_user_id=auth.uid()and p.is_active and r.is_active and s.is_active order by s.sort_order
$$;
revoke all on function public.get_my_erp_permissions()from public,anon;grant execute on function public.get_my_erp_permissions()to authenticated;

create or replace function public.authorized_post_material_receipt_to_inventory(p_receipt_id uuid,p_location_id uuid,p_items jsonb,p_request_id uuid)returns void language plpgsql security definer set search_path=''as $$begin
 if not public.has_erp_permission('purchase.material_receipts','VIEW')then raise exception'Material Receipts view permission required';end if;
 if not public.has_erp_permission('inventory.stock_in','EDIT')then raise exception'Inventory Stock In edit permission required';end if;
 perform public.post_material_receipt_to_inventory(p_receipt_id,p_location_id,p_items,p_request_id);
end$$;
revoke all on function public.authorized_post_material_receipt_to_inventory(uuid,uuid,jsonb,uuid)from public,anon;grant execute on function public.authorized_post_material_receipt_to_inventory(uuid,uuid,jsonb,uuid)to authenticated;
revoke execute on function public.post_material_receipt_to_inventory(uuid,uuid,jsonb,uuid)from authenticated;
commit;
