-- Adhunik ERP - Phase 4A CRM Inquiry Management
begin;
alter table public.numbering_configurations drop constraint if exists numbering_configurations_entity_type_check;
alter table public.numbering_configurations add constraint numbering_configurations_entity_type_check check(entity_type in('EMPLOYEE','CUSTOMER','INQUIRY'));
insert into public.numbering_configurations(entity_type,prefix,padding,separator,include_year) values('INQUIRY','INQ',4,'-',true) on conflict(entity_type) do nothing;
insert into public.numbering_counters(entity_type,current_value) values('INQUIRY',0) on conflict(entity_type) do nothing;

create table if not exists public.inquiries(
 id uuid primary key default gen_random_uuid(),inquiry_number text not null unique,
 company_id uuid not null references public.customer_companies(id) on delete restrict,contact_id uuid references public.customer_contacts(id) on delete restrict,
 inquiry_date date not null default current_date,subject text not null check(length(trim(subject))>0),requirement_description text not null check(length(trim(requirement_description))>0),notes text,
 inquiry_source text check(inquiry_source is null or inquiry_source in('PHONE','EMAIL','WEBSITE','GEM','REFERRAL','EXISTING_CUSTOMER','WALK_IN','OTHER')),
 priority text not null default 'MEDIUM' check(priority in('LOW','MEDIUM','HIGH')),expected_value numeric(18,2) check(expected_value is null or expected_value>=0),expected_closing_date date,
 status text not null default 'NEW' check(status in('NEW','IN_PROGRESS','WON','LOST','CLOSED')),
 assigned_to uuid not null references auth.users(id) on delete restrict,created_by uuid not null references auth.users(id) on delete restrict,
 lost_reason text check(lost_reason is null or lost_reason in('PRICE','COMPETITOR','TECHNICAL','DELIVERY','CUSTOMER_CANCELLED','NO_RESPONSE','BUDGET','OTHER')),
 lost_notes text,closure_notes text,won_at timestamptz,closed_at timestamptz,
 created_at timestamptz not null default now(),updated_at timestamptz not null default now(),updated_by uuid references auth.users(id) on delete set null,
 deleted_at timestamptz,deleted_by uuid references auth.users(id) on delete set null,
 constraint inquiry_status_details check((status<>'LOST' or lost_reason is not null) and (status='LOST' or lost_reason is null))
);
insert into public.numbering_counters(entity_type,current_value)
select 'INQUIRY',coalesce(max((substring(inquiry_number from '([0-9]+)$'))::bigint),0) from public.inquiries where inquiry_number~'[0-9]+$'
on conflict(entity_type) do update set current_value=greatest(public.numbering_counters.current_value,excluded.current_value);

create table if not exists public.inquiry_status_history(
 id uuid primary key default gen_random_uuid(),inquiry_id uuid not null references public.inquiries(id) on delete restrict,
 previous_status text,new_status text not null,changed_by uuid not null references auth.users(id) on delete restrict,
 changed_at timestamptz not null default now(),notes text
);
create table if not exists public.inquiry_follow_ups(
 id uuid primary key default gen_random_uuid(),inquiry_id uuid not null references public.inquiries(id) on delete restrict,
 activity_type text not null check(activity_type in('CALL','EMAIL','WHATSAPP','MEETING','NOTE','OTHER')),
 activity_date timestamptz not null default now(),remarks text not null check(length(trim(remarks))>0),outcome text,next_follow_up_at timestamptz,
 created_by uuid not null references auth.users(id) on delete restrict,created_at timestamptz not null default now(),updated_at timestamptz not null default now(),updated_by uuid references auth.users(id) on delete set null
);
create table if not exists public.inquiry_assignments(
 id uuid primary key default gen_random_uuid(),inquiry_id uuid not null references public.inquiries(id) on delete restrict,
 previous_assigned_to uuid references auth.users(id) on delete restrict,assigned_to uuid not null references auth.users(id) on delete restrict,
 assigned_by uuid not null references auth.users(id) on delete restrict,assigned_at timestamptz not null default now(),remarks text
);
create table if not exists public.inquiry_attachments(
 id uuid primary key default gen_random_uuid(),inquiry_id uuid not null references public.inquiries(id) on delete restrict,
 file_name text not null,file_path text not null unique,mime_type text not null,file_size bigint not null check(file_size between 1 and 10485760),
 uploaded_by uuid not null references auth.users(id) on delete restrict,uploaded_at timestamptz not null default now(),is_active boolean not null default true
);
create index if not exists inquiries_company on public.inquiries(company_id) where deleted_at is null;
create index if not exists inquiries_contact on public.inquiries(contact_id) where contact_id is not null and deleted_at is null;
create index if not exists inquiries_assigned on public.inquiries(assigned_to,status) where deleted_at is null;
create index if not exists inquiries_creator on public.inquiries(created_by) where deleted_at is null;
create index if not exists inquiries_date on public.inquiries(inquiry_date desc) where deleted_at is null;
create index if not exists inquiries_closing on public.inquiries(expected_closing_date) where deleted_at is null;
create index if not exists inquiry_status_history_inquiry on public.inquiry_status_history(inquiry_id,changed_at desc);
create index if not exists follow_ups_inquiry on public.inquiry_follow_ups(inquiry_id,activity_date desc);
create index if not exists follow_ups_next on public.inquiry_follow_ups(next_follow_up_at) where next_follow_up_at is not null;
create index if not exists assignments_inquiry on public.inquiry_assignments(inquiry_id,assigned_at desc);
create index if not exists attachments_inquiry on public.inquiry_attachments(inquiry_id) where is_active;

create or replace function public.current_erp_role() returns text language sql stable security definer set search_path='' as $$
 select r.code from public.erp_profiles p join public.erp_roles r on r.id=p.role_id where p.auth_user_id=auth.uid() and p.is_active and r.is_active limit 1
$$;
create or replace function public.can_manage_crm() returns boolean language sql stable security definer set search_path='' as $$
 select coalesce(public.current_erp_role() in('ADMIN','MANAGER'),false)
$$;
create or replace function public.can_view_inquiry(p_inquiry_id uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.inquiries i where i.id=p_inquiry_id and i.deleted_at is null and(
  public.current_erp_role()='ADMIN' or i.created_by=auth.uid() or i.assigned_to=auth.uid() or
  (public.current_erp_role()='MANAGER' and exists(
   select 1 from public.erp_profiles me join public.employees manager on manager.id=me.employee_id
   join public.erp_profiles member on member.auth_user_id in(i.created_by,i.assigned_to)
   join public.employees employee on employee.id=member.employee_id
   where me.auth_user_id=auth.uid() and(employee.reporting_manager_id=manager.id or exists(
    select 1 from public.employee_teams mt join public.employee_teams et on et.team_id=mt.team_id
    where mt.employee_id=manager.id and et.employee_id=employee.id
   ))
  ))
 ))
$$;
create or replace function public.reassign_inquiry(p_inquiry_id uuid,p_assigned_to uuid,p_remarks text default null) returns void language plpgsql security definer set search_path='' as $$
begin
 if not public.can_manage_crm() then raise exception 'Only Admin or Manager can reassign inquiries';end if;
 if not exists(select 1 from public.erp_profiles where auth_user_id=p_assigned_to and is_active) then raise exception 'Assignee must have active ERP access';end if;
 perform set_config('app.assignment_remarks',coalesce(p_remarks,''),true);
 update public.inquiries set assigned_to=p_assigned_to where id=p_inquiry_id and public.can_view_inquiry(id);
 if not found then raise exception 'Inquiry not found or not visible';end if;
end
$$;
create or replace function public.create_inquiry(p_data jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare new_id uuid;requested_assignee uuid;effective_assignee uuid;
begin
 if not public.has_active_erp_access() then raise exception 'Active ERP access is required';end if;
 requested_assignee:=nullif(p_data->>'assigned_to','')::uuid;
 effective_assignee:=case when public.can_manage_crm() and requested_assignee is not null then requested_assignee else auth.uid() end;
 if not exists(select 1 from public.erp_profiles where auth_user_id=effective_assignee and is_active) then raise exception 'Assignee must have active ERP access';end if;
 insert into public.inquiries(inquiry_number,company_id,contact_id,inquiry_date,subject,requirement_description,notes,inquiry_source,priority,expected_value,expected_closing_date,status,assigned_to,created_by,lost_reason,lost_notes,closure_notes,updated_by)
 values('PENDING',(p_data->>'company_id')::uuid,nullif(p_data->>'contact_id','')::uuid,coalesce(nullif(p_data->>'inquiry_date','')::date,current_date),trim(p_data->>'subject'),trim(p_data->>'requirement_description'),nullif(p_data->>'notes',''),nullif(p_data->>'inquiry_source',''),coalesce(nullif(p_data->>'priority',''),'MEDIUM'),nullif(p_data->>'expected_value','')::numeric,nullif(p_data->>'expected_closing_date','')::date,coalesce(nullif(p_data->>'status',''),'NEW'),effective_assignee,auth.uid(),nullif(p_data->>'lost_reason',''),nullif(p_data->>'lost_notes',''),nullif(p_data->>'closure_notes',''),auth.uid())
 returning id into new_id;
 return new_id;
end
$$;
revoke all on function public.create_inquiry(jsonb) from public,anon;
grant execute on function public.create_inquiry(jsonb) to authenticated;
create or replace function public.prepare_inquiry() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' then
  new.created_by:=auth.uid();new.assigned_to:=case when public.can_manage_crm() then coalesce(new.assigned_to,auth.uid()) else auth.uid() end;new.inquiry_number:=public.allocate_business_number('INQUIRY');new.updated_by:=auth.uid();
 else
  new.created_by:=old.created_by;new.inquiry_number:=old.inquiry_number;new.created_at:=old.created_at;new.updated_by:=auth.uid();
  if new.assigned_to<>old.assigned_to and not public.can_manage_crm() then raise exception 'Only Admin or Manager can reassign inquiries';end if;
 end if;
 if not exists(select 1 from public.erp_profiles where auth_user_id=new.assigned_to and is_active) then raise exception 'Assignee must have active ERP access';end if;
 if new.contact_id is not null and not exists(select 1 from public.customer_contacts c where c.id=new.contact_id and c.customer_company_id=new.company_id and c.deleted_at is null) then raise exception 'Contact does not belong to selected company';end if;
 if new.status='LOST' and new.lost_reason is null then raise exception 'Lost reason is required';end if;
 if tg_op='UPDATE' and new.status='WON' and old.status<>'WON' then new.won_at:=now();end if;
 if tg_op='UPDATE' and new.status='CLOSED' and old.status<>'CLOSED' then new.closed_at:=now();end if;
 return new;
end
$$;
create or replace function public.log_inquiry_assignment() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' or new.assigned_to<>old.assigned_to then
  insert into public.inquiry_assignments(inquiry_id,previous_assigned_to,assigned_to,assigned_by,remarks)
  values(new.id,case when tg_op='UPDATE' then old.assigned_to end,new.assigned_to,auth.uid(),nullif(current_setting('app.assignment_remarks',true),''));
 end if;return new;
end
$$;
create or replace function public.log_inquiry_status() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_op='INSERT' or new.status<>old.status then insert into public.inquiry_status_history(inquiry_id,previous_status,new_status,changed_by) values(new.id,case when tg_op='UPDATE' then old.status end,new.status,auth.uid());end if;return new;
end
$$;
create or replace function public.prepare_crm_child() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if tg_table_name='inquiry_follow_ups' then
  if tg_op='INSERT' then new.created_by:=auth.uid();else new.created_by:=old.created_by;new.created_at:=old.created_at;end if;new.updated_by:=auth.uid();
 elsif tg_table_name='inquiry_attachments' then new.uploaded_by:=auth.uid();end if;return new;
end
$$;
drop trigger if exists prepare_inquiry on public.inquiries;create trigger prepare_inquiry before insert or update on public.inquiries for each row execute function public.prepare_inquiry();
drop trigger if exists log_inquiry_assignment on public.inquiries;create trigger log_inquiry_assignment after insert or update of assigned_to on public.inquiries for each row execute function public.log_inquiry_assignment();
drop trigger if exists log_inquiry_status on public.inquiries;create trigger log_inquiry_status after insert or update of status on public.inquiries for each row execute function public.log_inquiry_status();
drop trigger if exists set_inquiries_updated_at on public.inquiries;create trigger set_inquiries_updated_at before update on public.inquiries for each row execute function public.set_updated_at();
drop trigger if exists set_follow_ups_updated_at on public.inquiry_follow_ups;create trigger set_follow_ups_updated_at before update on public.inquiry_follow_ups for each row execute function public.set_updated_at();
drop trigger if exists prepare_follow_up on public.inquiry_follow_ups;create trigger prepare_follow_up before insert or update on public.inquiry_follow_ups for each row execute function public.prepare_crm_child();
drop trigger if exists prepare_attachment on public.inquiry_attachments;create trigger prepare_attachment before insert on public.inquiry_attachments for each row execute function public.prepare_crm_child();

alter table public.inquiries enable row level security;alter table public.inquiry_status_history enable row level security;alter table public.inquiry_follow_ups enable row level security;
alter table public.inquiry_assignments enable row level security;alter table public.inquiry_attachments enable row level security;
drop policy if exists "CRM visible inquiries" on public.inquiries;drop policy if exists "CRM create inquiries" on public.inquiries;drop policy if exists "CRM update inquiries" on public.inquiries;
drop policy if exists "CRM visible follow ups" on public.inquiry_follow_ups;drop policy if exists "CRM create follow ups" on public.inquiry_follow_ups;drop policy if exists "CRM update follow ups" on public.inquiry_follow_ups;
drop policy if exists "CRM visible status history" on public.inquiry_status_history;
drop policy if exists "CRM visible assignments" on public.inquiry_assignments;
drop policy if exists "CRM visible attachments" on public.inquiry_attachments;drop policy if exists "CRM create attachments" on public.inquiry_attachments;drop policy if exists "CRM update attachments" on public.inquiry_attachments;
create policy "CRM visible inquiries" on public.inquiries for select to authenticated using(public.can_view_inquiry(id));
create policy "CRM create inquiries" on public.inquiries for insert to authenticated with check(public.has_active_erp_access());
create policy "CRM update inquiries" on public.inquiries for update to authenticated using(public.can_view_inquiry(id)) with check(public.can_view_inquiry(id));
create policy "CRM visible follow ups" on public.inquiry_follow_ups for select to authenticated using(public.can_view_inquiry(inquiry_id));
create policy "CRM create follow ups" on public.inquiry_follow_ups for insert to authenticated with check(public.can_view_inquiry(inquiry_id));
create policy "CRM update follow ups" on public.inquiry_follow_ups for update to authenticated using(created_by=auth.uid() and public.can_view_inquiry(inquiry_id));
create policy "CRM visible status history" on public.inquiry_status_history for select to authenticated using(public.can_view_inquiry(inquiry_id));
create policy "CRM visible assignments" on public.inquiry_assignments for select to authenticated using(public.can_view_inquiry(inquiry_id));
create policy "CRM visible attachments" on public.inquiry_attachments for select to authenticated using(public.can_view_inquiry(inquiry_id));
create policy "CRM create attachments" on public.inquiry_attachments for insert to authenticated with check(public.can_view_inquiry(inquiry_id));
create policy "CRM update attachments" on public.inquiry_attachments for update to authenticated using((uploaded_by=auth.uid() or public.can_manage_crm()) and public.can_view_inquiry(inquiry_id));
grant select,insert,update on public.inquiries,public.inquiry_follow_ups,public.inquiry_attachments to authenticated;
grant select on public.inquiry_assignments,public.inquiry_status_history to authenticated;
revoke all on function public.reassign_inquiry(uuid,uuid,text) from public,anon;
grant execute on function public.current_erp_role(),public.can_manage_crm(),public.can_view_inquiry(uuid),public.reassign_inquiry(uuid,uuid,text) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values(
 'crm-inquiry-attachments','crm-inquiry-attachments',false,10485760,
 array['application/pdf','application/msword','application/vnd.openxmlformats-officedocument.wordprocessingml.document','application/vnd.ms-excel','application/vnd.openxmlformats-officedocument.spreadsheetml.sheet','image/jpeg','image/png','image/webp']
) on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
drop policy if exists "CRM attachment objects read" on storage.objects;drop policy if exists "CRM attachment objects insert" on storage.objects;drop policy if exists "CRM attachment objects delete" on storage.objects;
create policy "CRM attachment objects read" on storage.objects for select to authenticated using(bucket_id='crm-inquiry-attachments' and public.can_view_inquiry((storage.foldername(name))[1]::uuid));
create policy "CRM attachment objects insert" on storage.objects for insert to authenticated with check(bucket_id='crm-inquiry-attachments' and public.can_view_inquiry((storage.foldername(name))[1]::uuid));
create policy "CRM attachment objects delete" on storage.objects for delete to authenticated using(bucket_id='crm-inquiry-attachments' and (owner_id=auth.uid()::text or public.can_manage_crm()) and public.can_view_inquiry((storage.foldername(name))[1]::uuid));
commit;

