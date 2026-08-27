-- Adhunik ERP — Phase 10A HR & Payroll Foundation
begin;

insert into public.erp_permission_sections(module_key,section_key,module_name,section_name,sort_order) values
('hr-payroll','hr-payroll.overview','HR & Payroll','Overview',900),
('hr-payroll','hr-payroll.attendance','HR & Payroll','Monthly Attendance',910),
('hr-payroll','hr-payroll.salary_structures','HR & Payroll','Salary Structures',920),
('hr-payroll','hr-payroll.loi','HR & Payroll','Letter of Intent',930),
('hr-payroll','hr-payroll.appointment_letters','HR & Payroll','Appointment Letters',940),
('hr-payroll','hr-payroll.letter_configuration','HR & Payroll','Letter Configuration',950)
on conflict(section_key) do update set module_key=excluded.module_key,module_name=excluded.module_name,section_name=excluded.section_name,sort_order=excluded.sort_order,is_active=true;

create table public.monthly_attendance(
 id uuid primary key default gen_random_uuid(),employee_id uuid not null references public.employees(id) on delete restrict,
 month smallint not null check(month between 1 and 12),year smallint not null check(year between 2000 and 2200),
 working_days numeric(6,2) not null check(working_days>=0),present_days numeric(6,2) not null check(present_days>=0 and present_days<=working_days),weekly_offs numeric(6,2) not null check(weekly_offs>=0),
 absent_days numeric(6,2) generated always as (working_days-present_days) stored,
 total_payable_days numeric(6,2) generated always as (working_days+weekly_offs) stored,
 paid_days numeric(6,2) generated always as (present_days+weekly_offs) stored,
 created_by uuid not null references auth.users(id) default auth.uid(),updated_by uuid references auth.users(id) default auth.uid(),created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 unique(employee_id,month,year)
);
create index monthly_attendance_period on public.monthly_attendance(year desc,month desc);
create index monthly_attendance_employee on public.monthly_attendance(employee_id,year desc,month desc);

create table public.employee_salary_structures(
 id uuid primary key default gen_random_uuid(),employee_id uuid not null references public.employees(id) on delete restrict,effective_from date not null,
 basic numeric(15,2) not null check(basic>=0),hra numeric(15,2) not null default 0 check(hra>=0),allowance numeric(15,2) not null default 0 check(allowance>=0),other_earnings numeric(15,2) not null default 0 check(other_earnings>=0),
 fixed_gross numeric(15,2) generated always as (basic+hra+allowance+other_earnings) stored,
 created_by uuid not null references auth.users(id) default auth.uid(),updated_by uuid references auth.users(id) default auth.uid(),created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
 unique(employee_id,effective_from)
);
create index employee_salary_applicable on public.employee_salary_structures(employee_id,effective_from desc);

create table public.hr_letter_settings(
 id boolean primary key default true check(id),company_logo_path text,company_name text not null default 'ADHUNIK',cin text,address text,phone text,email text,website text,right_header_image_path text,
 footer_main_text text,footer_secondary_text text,created_by uuid references auth.users(id) default auth.uid(),updated_by uuid references auth.users(id) default auth.uid(),created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
insert into public.hr_letter_settings(id) values(true) on conflict do nothing;

create table public.hr_letter_templates(
 id uuid primary key default gen_random_uuid(),letter_type text not null check(letter_type in('LOI','APPOINTMENT')),body_template text not null default '',
 created_by uuid references auth.users(id) default auth.uid(),updated_by uuid references auth.users(id) default auth.uid(),created_at timestamptz not null default now(),updated_at timestamptz not null default now(),unique(letter_type)
);
insert into public.hr_letter_templates(letter_type) values('LOI'),('APPOINTMENT') on conflict do nothing;

create table public.hr_letters(
 id uuid primary key default gen_random_uuid(),employee_id uuid not null references public.employees(id) on delete restrict,letter_type text not null check(letter_type in('LOI','APPOINTMENT')),status text not null default 'DRAFT' check(status in('DRAFT','FINAL','CANCELLED')),letter_date date not null default current_date,subject text not null,
 employee_name text not null,employee_code text not null,address text,phone text,email text,designation text,department text,joining_date date,reporting_to text,company text,branch text,posting_location text,ctc numeric(15,2) check(ctc is null or ctc>=0),probation_period text,notice_period text,date_of_appointment date,
 body_content text not null default '',employee_snapshot jsonb not null default '{}'::jsonb,variable_snapshot jsonb not null default '{}'::jsonb,template_snapshot text,header_snapshot jsonb,footer_snapshot jsonb,
 created_by uuid not null references auth.users(id) default auth.uid(),updated_by uuid references auth.users(id) default auth.uid(),finalized_by uuid references auth.users(id),created_at timestamptz not null default now(),updated_at timestamptz not null default now(),finalized_at timestamptz,
 check(status<>'FINAL' or (finalized_by is not null and finalized_at is not null))
);
create index hr_letters_register on public.hr_letters(letter_type,letter_date desc,created_at desc);
create index hr_letters_employee on public.hr_letters(employee_id,letter_type,created_at desc);

create table public.hr_activity(
 id uuid primary key default gen_random_uuid(),event_type text not null,entity_type text not null,entity_id uuid,description text,created_by uuid not null references auth.users(id) default auth.uid(),created_at timestamptz not null default now()
);

create or replace function public.save_monthly_attendance(p_month smallint,p_year smallint,p_rows jsonb) returns void language plpgsql security definer set search_path='' as $$
declare x jsonb;begin
 if not public.has_erp_permission('hr-payroll.attendance','EDIT') then raise exception 'Monthly Attendance edit permission required';end if;
 if p_month not between 1 and 12 or p_year not between 2000 and 2200 then raise exception 'Invalid attendance period';end if;
 for x in select * from jsonb_array_elements(p_rows) loop
  if not exists(select 1 from public.employees e where e.id=(x->>'employee_id')::uuid and e.deleted_at is null) then raise exception 'Invalid employee';end if;
  insert into public.monthly_attendance(employee_id,month,year,working_days,present_days,weekly_offs)
  values((x->>'employee_id')::uuid,p_month,p_year,(x->>'working_days')::numeric,(x->>'present_days')::numeric,(x->>'weekly_offs')::numeric)
  on conflict(employee_id,month,year) do update set working_days=excluded.working_days,present_days=excluded.present_days,weekly_offs=excluded.weekly_offs,updated_by=auth.uid(),updated_at=now();
 end loop;
 insert into public.hr_activity(event_type,entity_type,description) values('MONTHLY_ATTENDANCE_UPDATED','MONTHLY_ATTENDANCE',p_month||'/'||p_year);
end$$;

create or replace function public.save_salary_structure(p_employee_id uuid,p_effective_from date,p_basic numeric,p_hra numeric,p_allowance numeric,p_other numeric) returns uuid language plpgsql security definer set search_path='' as $$
declare v uuid;begin
 if not public.has_erp_permission('hr-payroll.salary_structures','EDIT') then raise exception 'Salary Structures edit permission required';end if;
 if least(p_basic,p_hra,p_allowance,p_other)<0 then raise exception 'Salary components cannot be negative';end if;
 if not exists(select 1 from public.employees where id=p_employee_id and deleted_at is null) then raise exception 'Invalid employee';end if;
 insert into public.employee_salary_structures(employee_id,effective_from,basic,hra,allowance,other_earnings) values(p_employee_id,p_effective_from,p_basic,p_hra,p_allowance,p_other) returning id into v;
 insert into public.hr_activity(event_type,entity_type,entity_id,description) values('SALARY_STRUCTURE_CREATED','SALARY_STRUCTURE',v,'Effective '||p_effective_from);return v;
end$$;

create or replace function public.finalize_hr_letter(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare l public.hr_letters%rowtype;s public.hr_letter_settings%rowtype;begin
 select * into l from public.hr_letters where id=p_id for update;if not found then raise exception 'Letter not found';end if;
 if not public.has_erp_permission(case when l.letter_type='LOI'then'hr-payroll.loi'else'hr-payroll.appointment_letters'end,'EDIT') then raise exception 'Letter edit permission required';end if;
 if l.status<>'DRAFT' then raise exception 'Only draft letters can be finalized';end if;select * into s from public.hr_letter_settings where id;
 update public.hr_letters set status='FINAL',template_snapshot=body_content,header_snapshot=jsonb_build_object('company_logo_path',s.company_logo_path,'company_name',s.company_name,'cin',s.cin,'address',s.address,'phone',s.phone,'email',s.email,'website',s.website,'right_header_image_path',s.right_header_image_path),footer_snapshot=jsonb_build_object('main',s.footer_main_text,'secondary',s.footer_secondary_text),finalized_by=auth.uid(),finalized_at=now(),updated_by=auth.uid(),updated_at=now() where id=p_id;
 insert into public.hr_activity(event_type,entity_type,entity_id)values(case when l.letter_type='LOI'then'LOI_FINALIZED'else'APPOINTMENT_LETTER_FINALIZED'end,'HR_LETTER',p_id);
end$$;

create or replace function public.prevent_final_hr_letter_changes() returns trigger language plpgsql set search_path='' as $$begin if old.status='FINAL' then raise exception 'Final HR letters are locked';end if;return new;end$$;
create trigger lock_final_hr_letters before update on public.hr_letters for each row when(old.status='FINAL') execute function public.prevent_final_hr_letter_changes();
create trigger set_monthly_attendance_updated_at before update on public.monthly_attendance for each row execute function public.set_updated_at();
create trigger set_employee_salary_structures_updated_at before update on public.employee_salary_structures for each row execute function public.set_updated_at();
create trigger set_hr_letter_settings_updated_at before update on public.hr_letter_settings for each row execute function public.set_updated_at();
create trigger set_hr_letter_templates_updated_at before update on public.hr_letter_templates for each row execute function public.set_updated_at();
create trigger set_hr_letters_updated_at before update on public.hr_letters for each row execute function public.set_updated_at();

alter table public.monthly_attendance enable row level security;alter table public.employee_salary_structures enable row level security;alter table public.hr_letter_settings enable row level security;alter table public.hr_letter_templates enable row level security;alter table public.hr_letters enable row level security;alter table public.hr_activity enable row level security;
create policy attendance_read on public.monthly_attendance for select to authenticated using(public.has_erp_permission('hr-payroll.attendance','VIEW'));
create policy salary_read on public.employee_salary_structures for select to authenticated using(public.has_erp_permission('hr-payroll.salary_structures','VIEW'));
create policy settings_read on public.hr_letter_settings for select to authenticated using(public.has_erp_permission('hr-payroll.letter_configuration','VIEW') or public.has_erp_permission('hr-payroll.loi','VIEW') or public.has_erp_permission('hr-payroll.appointment_letters','VIEW'));
create policy settings_update on public.hr_letter_settings for update to authenticated using(public.has_erp_permission('hr-payroll.letter_configuration','EDIT')) with check(public.has_erp_permission('hr-payroll.letter_configuration','EDIT'));
create policy templates_read on public.hr_letter_templates for select to authenticated using(public.has_erp_permission('hr-payroll.letter_configuration','VIEW') or (letter_type='LOI' and public.has_erp_permission('hr-payroll.loi','VIEW')) or (letter_type='APPOINTMENT' and public.has_erp_permission('hr-payroll.appointment_letters','VIEW')));
create policy templates_update on public.hr_letter_templates for update to authenticated using(public.has_erp_permission('hr-payroll.letter_configuration','EDIT')) with check(public.has_erp_permission('hr-payroll.letter_configuration','EDIT'));
create policy letters_read on public.hr_letters for select to authenticated using(public.has_erp_permission(case when letter_type='LOI'then'hr-payroll.loi'else'hr-payroll.appointment_letters'end,'VIEW'));
create policy letters_insert on public.hr_letters for insert to authenticated with check(public.has_erp_permission(case when letter_type='LOI'then'hr-payroll.loi'else'hr-payroll.appointment_letters'end,'EDIT') and created_by=auth.uid());
create policy letters_update on public.hr_letters for update to authenticated using(status='DRAFT' and public.has_erp_permission(case when letter_type='LOI'then'hr-payroll.loi'else'hr-payroll.appointment_letters'end,'EDIT')) with check(public.has_erp_permission(case when letter_type='LOI'then'hr-payroll.loi'else'hr-payroll.appointment_letters'end,'EDIT'));
create policy hr_activity_read on public.hr_activity for select to authenticated using(public.has_erp_permission('hr-payroll.overview','VIEW'));
grant select on public.monthly_attendance,public.employee_salary_structures,public.hr_letter_settings,public.hr_letter_templates,public.hr_letters,public.hr_activity to authenticated;
grant insert,update on public.hr_letter_settings,public.hr_letter_templates,public.hr_letters to authenticated;
revoke all on function public.save_monthly_attendance(smallint,smallint,jsonb),public.save_salary_structure(uuid,date,numeric,numeric,numeric,numeric),public.finalize_hr_letter(uuid) from public,anon;
grant execute on function public.save_monthly_attendance(smallint,smallint,jsonb),public.save_salary_structure(uuid,date,numeric,numeric,numeric,numeric),public.finalize_hr_letter(uuid) to authenticated;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types) values('hr-letter-assets','hr-letter-assets',false,5242880,array['image/jpeg','image/png','image/webp']) on conflict(id)do update set public=false,file_size_limit=excluded.file_size_limit,allowed_mime_types=excluded.allowed_mime_types;
create policy hr_letter_assets_read on storage.objects for select to authenticated using(bucket_id='hr-letter-assets' and (public.has_erp_permission('hr-payroll.letter_configuration','VIEW') or public.has_erp_permission('hr-payroll.loi','VIEW') or public.has_erp_permission('hr-payroll.appointment_letters','VIEW')));
create policy hr_letter_assets_insert on storage.objects for insert to authenticated with check(bucket_id='hr-letter-assets' and public.has_erp_permission('hr-payroll.letter_configuration','EDIT'));
create policy hr_letter_assets_update on storage.objects for update to authenticated using(bucket_id='hr-letter-assets' and public.has_erp_permission('hr-payroll.letter_configuration','EDIT')) with check(bucket_id='hr-letter-assets' and public.has_erp_permission('hr-payroll.letter_configuration','EDIT'));

insert into public.erp_user_permissions(profile_id,section_id,can_view,can_edit,created_by,updated_by)
select p.id,s.id,true,true,p.auth_user_id,p.auth_user_id from public.erp_profiles p join public.erp_roles r on r.id=p.role_id cross join public.erp_permission_sections s where p.is_active and r.code='MANAGER' and s.module_key='hr-payroll' on conflict(profile_id,section_id)do nothing;
commit;
