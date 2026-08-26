-- Adhunik ERP - Phase 9A simple section access control (Purchase pilot)
begin;
create table public.erp_permission_sections(
 id uuid primary key default gen_random_uuid(),module_key text not null,section_key text not null,module_name text not null,section_name text not null,
 sort_order integer not null default 0,is_active boolean not null default true,created_at timestamptz not null default now(),
 unique(module_key,section_key),unique(section_key),check(section_key=module_key||'.'||split_part(section_key,'.',2))
);
create table public.erp_user_permissions(
 id uuid primary key default gen_random_uuid(),profile_id uuid not null references public.erp_profiles(id) on delete restrict,section_id uuid not null references public.erp_permission_sections(id) on delete restrict,
 can_view boolean not null default false,can_edit boolean not null default false,created_at timestamptz not null default now(),created_by uuid not null references auth.users(id) on delete restrict,
 updated_at timestamptz not null default now(),updated_by uuid not null references auth.users(id) on delete restrict,unique(profile_id,section_id),check(not can_edit or can_view)
);
create table public.erp_access_audit(
 id uuid primary key default gen_random_uuid(),target_profile_id uuid not null references public.erp_profiles(id) on delete restrict,event_type text not null check(event_type in('ERP_ACCESS_UPDATED','ERP_ACCESS_COPIED')),
 previous_permissions jsonb not null default'[]',new_permissions jsonb not null default'[]',source_profile_id uuid references public.erp_profiles(id) on delete restrict,
 changed_by uuid not null references auth.users(id) on delete restrict default auth.uid(),changed_at timestamptz not null default now()
);
create index erp_user_permissions_profile on public.erp_user_permissions(profile_id);
create index erp_user_permissions_section on public.erp_user_permissions(section_id);
create index erp_access_audit_target on public.erp_access_audit(target_profile_id,changed_at desc);
insert into public.erp_permission_sections(module_key,section_key,module_name,section_name,sort_order)values
('purchase','purchase.overview','Purchase','Overview',10),('purchase','purchase.indents','Purchase','Purchase Indents',20),
('purchase','purchase.suppliers','Purchase','Supplier Master',30),('purchase','purchase.orders','Purchase','Purchase Orders',40),
('purchase','purchase.material_receipts','Purchase','Material Receipts',50);

create function public.has_erp_permission(p_section_key text,p_access_type text default'VIEW')returns boolean language sql stable security definer set search_path=''as $$
 select exists(select 1 from public.erp_profiles p join public.erp_roles r on r.id=p.role_id left join public.erp_user_permissions up on up.profile_id=p.id left join public.erp_permission_sections s on s.id=up.section_id and s.is_active
 where p.auth_user_id=auth.uid()and p.is_active and r.is_active and(r.code='ADMIN'or(s.section_key=p_section_key and case upper(p_access_type)when'EDIT'then up.can_edit when'VIEW'then up.can_view else false end)))
$$;
create function public.has_erp_module_access(p_module_key text)returns boolean language sql stable security definer set search_path=''as $$
 select exists(select 1 from public.erp_profiles p join public.erp_roles r on r.id=p.role_id left join public.erp_user_permissions up on up.profile_id=p.id and up.can_view left join public.erp_permission_sections s on s.id=up.section_id and s.is_active
 where p.auth_user_id=auth.uid()and p.is_active and r.is_active and(r.code='ADMIN'or s.module_key=p_module_key))
$$;
revoke all on function public.has_erp_permission(text,text),public.has_erp_module_access(text)from public,anon;
grant execute on function public.has_erp_permission(text,text),public.has_erp_module_access(text)to authenticated;

create function public.save_erp_user_permissions(p_profile_id uuid,p_permissions jsonb)returns void language plpgsql security definer set search_path=''as $$
declare old_set jsonb;new_set jsonb;x jsonb;section_row public.erp_permission_sections%rowtype;target_role text;
begin
 if not public.is_erp_admin()then raise exception'Only Admin can manage ERP permissions';end if;
 select r.code into target_role from public.erp_profiles p join public.erp_roles r on r.id=p.role_id where p.id=p_profile_id;
 if target_role is null then raise exception'ERP profile not found';end if;if target_role='ADMIN'then raise exception'Admin access is implicit and cannot be edited';end if;
 if jsonb_typeof(p_permissions)<>'array'then raise exception'Permissions must be an array';end if;
 select coalesce(jsonb_agg(jsonb_build_object('section_key',s.section_key,'can_view',up.can_view,'can_edit',up.can_edit)order by s.sort_order),'[]')into old_set from public.erp_user_permissions up join public.erp_permission_sections s on s.id=up.section_id where up.profile_id=p_profile_id;
 delete from public.erp_user_permissions where profile_id=p_profile_id;
 for x in select value from jsonb_array_elements(p_permissions)loop
  select * into section_row from public.erp_permission_sections where section_key=x->>'section_key'and is_active;
  if not found then raise exception'Unknown or inactive permission section: %',x->>'section_key';end if;
  if coalesce((x->>'can_edit')::boolean,false)and not coalesce((x->>'can_view')::boolean,false)then raise exception'Edit permission requires View permission';end if;
  if coalesce((x->>'can_view')::boolean,false)then insert into public.erp_user_permissions(profile_id,section_id,can_view,can_edit,created_by,updated_by)values(p_profile_id,section_row.id,true,coalesce((x->>'can_edit')::boolean,false),auth.uid(),auth.uid());end if;
 end loop;
 select coalesce(jsonb_agg(jsonb_build_object('section_key',s.section_key,'can_view',up.can_view,'can_edit',up.can_edit)order by s.sort_order),'[]')into new_set from public.erp_user_permissions up join public.erp_permission_sections s on s.id=up.section_id where up.profile_id=p_profile_id;
 insert into public.erp_access_audit(target_profile_id,event_type,previous_permissions,new_permissions,changed_by)values(p_profile_id,'ERP_ACCESS_UPDATED',old_set,new_set,auth.uid());
end$$;
create function public.copy_erp_user_permissions(p_target_profile_id uuid,p_source_profile_id uuid)returns void language plpgsql security definer set search_path=''as $$
declare source_role text;target_role text;old_set jsonb;new_set jsonb;
begin
 if not public.is_erp_admin()then raise exception'Only Admin can copy ERP permissions';end if;
 select r.code into source_role from public.erp_profiles p join public.erp_roles r on r.id=p.role_id where p.id=p_source_profile_id;
 select r.code into target_role from public.erp_profiles p join public.erp_roles r on r.id=p.role_id where p.id=p_target_profile_id;
 if source_role is null or target_role is null then raise exception'ERP profile not found';end if;
 if source_role='ADMIN'then raise exception'Admin implicit full access cannot be copied';end if;if target_role='ADMIN'then raise exception'Admin access is implicit and cannot be edited';end if;
 select coalesce(jsonb_agg(jsonb_build_object('section_key',s.section_key,'can_view',up.can_view,'can_edit',up.can_edit)order by s.sort_order),'[]')into old_set from public.erp_user_permissions up join public.erp_permission_sections s on s.id=up.section_id where up.profile_id=p_target_profile_id;
 delete from public.erp_user_permissions where profile_id=p_target_profile_id;
 insert into public.erp_user_permissions(profile_id,section_id,can_view,can_edit,created_by,updated_by)select p_target_profile_id,section_id,can_view,can_edit,auth.uid(),auth.uid()from public.erp_user_permissions where profile_id=p_source_profile_id;
 select coalesce(jsonb_agg(jsonb_build_object('section_key',s.section_key,'can_view',up.can_view,'can_edit',up.can_edit)order by s.sort_order),'[]')into new_set from public.erp_user_permissions up join public.erp_permission_sections s on s.id=up.section_id where up.profile_id=p_target_profile_id;
 insert into public.erp_access_audit(target_profile_id,event_type,previous_permissions,new_permissions,source_profile_id,changed_by)values(p_target_profile_id,'ERP_ACCESS_COPIED',old_set,new_set,p_source_profile_id,auth.uid());
end$$;
revoke all on function public.save_erp_user_permissions(uuid,jsonb),public.copy_erp_user_permissions(uuid,uuid)from public,anon;
grant execute on function public.save_erp_user_permissions(uuid,jsonb),public.copy_erp_user_permissions(uuid,uuid)to authenticated;
create function public.authorized_save_purchase_indent(p_id uuid,p_header jsonb,p_items jsonb)returns uuid language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.indents','EDIT')then raise exception'Purchase Indents edit permission required';end if;return public.save_purchase_indent(p_id,p_header,p_items);end$$;
create function public.authorized_submit_purchase_indent(p_id uuid)returns void language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.indents','EDIT')then raise exception'Purchase Indents edit permission required';end if;perform public.submit_purchase_indent(p_id);end$$;
create function public.authorized_cancel_purchase_indent(p_id uuid,p_reason text)returns void language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.indents','EDIT')then raise exception'Purchase Indents edit permission required';end if;perform public.cancel_purchase_indent(p_id,p_reason);end$$;
create function public.authorized_convert_indent_to_pr(p_indent_id uuid)returns uuid language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.indents','EDIT')then raise exception'Purchase Indents edit permission required';end if;return public.convert_indent_to_pr(p_indent_id);end$$;
create function public.authorized_save_purchase_requisition(p_id uuid,p_header jsonb,p_items jsonb)returns uuid language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.indents','EDIT')then raise exception'Purchase Indents edit permission required';end if;return public.save_purchase_requisition(p_id,p_header,p_items);end$$;
create function public.authorized_confirm_purchase_requisition(p_id uuid)returns void language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.indents','EDIT')then raise exception'Purchase Indents edit permission required';end if;perform public.confirm_purchase_requisition(p_id);end$$;
create function public.authorized_cancel_purchase_requisition(p_id uuid,p_reason text)returns void language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.indents','EDIT')then raise exception'Purchase Indents edit permission required';end if;perform public.cancel_purchase_requisition(p_id,p_reason);end$$;

create function public.authorized_save_supplier(p_id uuid,p_data jsonb)returns uuid language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.suppliers','EDIT')then raise exception'Supplier Master edit permission required';end if;return public.save_supplier(p_id,p_data);end$$;
create function public.authorized_toggle_supplier(p_id uuid,p_active boolean)returns void language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.suppliers','EDIT')then raise exception'Supplier Master edit permission required';end if;perform public.toggle_supplier(p_id,p_active);end$$;
create function public.authorized_select_pon_supplier(p_requisition_id uuid,p_supplier_id uuid)returns void language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.orders','EDIT')then raise exception'Purchase Orders edit permission required';end if;perform public.select_pon_supplier(p_requisition_id,p_supplier_id);end$$;
create function public.authorized_create_purchase_order(p_requisition_id uuid)returns uuid language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.orders','EDIT')then raise exception'Purchase Orders edit permission required';end if;return public.create_purchase_order(p_requisition_id);end$$;
create function public.authorized_create_purchase_order_from_indent(p_indent_id uuid)returns uuid language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.orders','EDIT')then raise exception'Purchase Orders edit permission required';end if;return public.create_purchase_order_from_indent(p_indent_id);end$$;
create function public.authorized_save_purchase_order(p_id uuid,p_header jsonb,p_items jsonb)returns uuid language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.orders','EDIT')then raise exception'Purchase Orders edit permission required';end if;return public.save_purchase_order(p_id,p_header,p_items);end$$;
create function public.authorized_confirm_purchase_order(p_id uuid)returns void language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.orders','EDIT')then raise exception'Purchase Orders edit permission required';end if;perform public.confirm_purchase_order(p_id);end$$;
create function public.authorized_cancel_purchase_order(p_id uuid,p_reason text)returns void language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.orders','EDIT')then raise exception'Purchase Orders edit permission required';end if;perform public.cancel_purchase_order(p_id,p_reason);end$$;
create function public.authorized_close_purchase_order(p_id uuid)returns void language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.orders','EDIT')then raise exception'Purchase Orders edit permission required';end if;perform public.close_purchase_order(p_id);end$$;
create function public.authorized_record_material_receipt(p_po_id uuid,p_header jsonb,p_items jsonb)returns uuid language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.material_receipts','EDIT')then raise exception'Material Receipts edit permission required';end if;return public.record_material_receipt(p_po_id,p_header,p_items);end$$;
create function public.authorized_cancel_material_receipt(p_id uuid,p_reason text)returns void language plpgsql security definer set search_path=''as $$begin if not public.has_erp_permission('purchase.material_receipts','EDIT')then raise exception'Material Receipts edit permission required';end if;perform public.cancel_material_receipt(p_id,p_reason);end$$;
revoke execute on function public.save_purchase_indent(uuid,jsonb,jsonb),public.submit_purchase_indent(uuid),public.cancel_purchase_indent(uuid,text),public.convert_indent_to_pr(uuid),public.save_purchase_requisition(uuid,jsonb,jsonb),public.confirm_purchase_requisition(uuid),public.cancel_purchase_requisition(uuid,text)from authenticated;
revoke execute on function public.save_supplier(uuid,jsonb),public.toggle_supplier(uuid,boolean),public.select_pon_supplier(uuid,uuid),public.create_purchase_order(uuid),public.create_purchase_order_from_indent(uuid),public.save_purchase_order(uuid,jsonb,jsonb),public.confirm_purchase_order(uuid),public.cancel_purchase_order(uuid,text),public.close_purchase_order(uuid),public.record_material_receipt(uuid,jsonb,jsonb),public.cancel_material_receipt(uuid,text)from authenticated;
grant execute on function public.authorized_save_purchase_indent(uuid,jsonb,jsonb),public.authorized_submit_purchase_indent(uuid),public.authorized_cancel_purchase_indent(uuid,text),public.authorized_convert_indent_to_pr(uuid),public.authorized_save_purchase_requisition(uuid,jsonb,jsonb),public.authorized_confirm_purchase_requisition(uuid),public.authorized_cancel_purchase_requisition(uuid,text)to authenticated;
grant execute on function public.authorized_save_supplier(uuid,jsonb),public.authorized_toggle_supplier(uuid,boolean),public.authorized_select_pon_supplier(uuid,uuid),public.authorized_create_purchase_order(uuid),public.authorized_create_purchase_order_from_indent(uuid),public.authorized_save_purchase_order(uuid,jsonb,jsonb),public.authorized_confirm_purchase_order(uuid),public.authorized_cancel_purchase_order(uuid,text),public.authorized_close_purchase_order(uuid),public.authorized_record_material_receipt(uuid,jsonb,jsonb),public.authorized_cancel_material_receipt(uuid,text)to authenticated;

do $$begin
 execute'drop policy if exists '||quote_ident('ERP users read visible indents')||' on public.purchase_indents';
 execute'drop policy if exists '||quote_ident('ERP users read visible indent items')||' on public.purchase_indent_items';
 execute'drop policy if exists '||quote_ident('ERP users read visible indent activity')||' on public.purchase_indent_activities';
 execute'drop policy if exists '||quote_ident('Managers read requisitions')||' on public.purchase_requisitions';
 execute'drop policy if exists '||quote_ident('Managers read requisition items')||' on public.purchase_requisition_items';
 execute'drop policy if exists '||quote_ident('Managers read requisition activity')||' on public.purchase_requisition_activities';
 execute'drop policy if exists '||quote_ident('Managers read suppliers')||' on public.suppliers';
 execute'drop policy if exists '||quote_ident('Managers read supplier activity')||' on public.supplier_activities';
 execute'drop policy if exists '||quote_ident('Managers read purchase orders')||' on public.purchase_orders';
 execute'drop policy if exists '||quote_ident('Managers read purchase order items')||' on public.purchase_order_items';
 execute'drop policy if exists '||quote_ident('Managers read purchase order activity')||' on public.purchase_order_activities';
 execute'drop policy if exists '||quote_ident('Managers read material receipts')||' on public.material_receipts';
 execute'drop policy if exists '||quote_ident('Managers read material receipt items')||' on public.material_receipt_items';
 execute'drop policy if exists '||quote_ident('Managers read material receipt activity')||' on public.material_receipt_activities';
end$$;
create policy purchase_indents_permission_read on public.purchase_indents for select to authenticated using(public.has_erp_permission('purchase.indents','VIEW'));
create policy purchase_indent_items_permission_read on public.purchase_indent_items for select to authenticated using(public.has_erp_permission('purchase.indents','VIEW'));
create policy purchase_indent_activity_permission_read on public.purchase_indent_activities for select to authenticated using(public.has_erp_permission('purchase.indents','VIEW'));
create policy purchase_requisitions_permission_read on public.purchase_requisitions for select to authenticated using(public.has_erp_permission('purchase.indents','VIEW'));
create policy purchase_requisition_items_permission_read on public.purchase_requisition_items for select to authenticated using(public.has_erp_permission('purchase.indents','VIEW'));
create policy purchase_requisition_activity_permission_read on public.purchase_requisition_activities for select to authenticated using(public.has_erp_permission('purchase.indents','VIEW'));
create policy suppliers_permission_read on public.suppliers for select to authenticated using(public.has_erp_permission('purchase.suppliers','VIEW'));
create policy supplier_activity_permission_read on public.supplier_activities for select to authenticated using(public.has_erp_permission('purchase.suppliers','VIEW'));
create policy purchase_orders_permission_read on public.purchase_orders for select to authenticated using(public.has_erp_permission('purchase.orders','VIEW'));
create policy purchase_order_items_permission_read on public.purchase_order_items for select to authenticated using(public.has_erp_permission('purchase.orders','VIEW'));
create policy purchase_order_activity_permission_read on public.purchase_order_activities for select to authenticated using(public.has_erp_permission('purchase.orders','VIEW'));
create policy material_receipts_permission_read on public.material_receipts for select to authenticated using(public.has_erp_permission('purchase.material_receipts','VIEW'));
create policy material_receipt_items_permission_read on public.material_receipt_items for select to authenticated using(public.has_erp_permission('purchase.material_receipts','VIEW'));
create policy material_receipt_activity_permission_read on public.material_receipt_activities for select to authenticated using(public.has_erp_permission('purchase.material_receipts','VIEW'));

alter table public.erp_permission_sections enable row level security;alter table public.erp_user_permissions enable row level security;alter table public.erp_access_audit enable row level security;
create policy erp_permission_sections_admin_read on public.erp_permission_sections for select to authenticated using(public.is_erp_admin());
create policy erp_user_permissions_admin_read on public.erp_user_permissions for select to authenticated using(public.is_erp_admin());
create policy erp_access_audit_admin_read on public.erp_access_audit for select to authenticated using(public.is_erp_admin());
grant select on public.erp_permission_sections,public.erp_user_permissions,public.erp_access_audit to authenticated;

-- Preserve existing non-Admin access explicitly; future accounts receive no Purchase access until Admin assigns it.
insert into public.erp_user_permissions(profile_id,section_id,can_view,can_edit,created_by,updated_by)
select p.id,s.id,true,true,p.auth_user_id,p.auth_user_id from public.erp_profiles p join public.erp_roles r on r.id=p.role_id cross join public.erp_permission_sections s where p.is_active and r.code='MANAGER';
insert into public.erp_user_permissions(profile_id,section_id,can_view,can_edit,created_by,updated_by)
select p.id,s.id,true,true,p.auth_user_id,p.auth_user_id from public.erp_profiles p join public.erp_roles r on r.id=p.role_id join public.erp_permission_sections s on s.section_key='purchase.indents' where p.is_active and r.code='USER';
commit;
