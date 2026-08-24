-- Adhunik ERP - Phase 3A Organization & Master Configuration
-- Run once after 202608240003_phase_2b_identity_access.sql.
begin;
create table if not exists public.employment_types (
 id uuid primary key default gen_random_uuid(), code text not null check(length(trim(code))>0), name text not null check(length(trim(name))>0), description text, sort_order integer not null default 0, is_active boolean not null default true,
 created_at timestamptz not null default now(), created_by uuid references auth.users(id) on delete set null default auth.uid(), updated_at timestamptz not null default now(), updated_by uuid references auth.users(id) on delete set null default auth.uid(), deleted_at timestamptz, deleted_by uuid references auth.users(id) on delete set null);
create table if not exists public.customer_types (like public.employment_types including defaults including constraints);
alter table public.customer_types add primary key (id);
alter table public.customer_types add constraint customer_types_created_by_fkey foreign key(created_by) references auth.users(id) on delete set null;
alter table public.customer_types add constraint customer_types_updated_by_fkey foreign key(updated_by) references auth.users(id) on delete set null;
alter table public.customer_types add constraint customer_types_deleted_by_fkey foreign key(deleted_by) references auth.users(id) on delete set null;
create unique index if not exists employment_types_code_unique on public.employment_types(upper(code)) where deleted_at is null;
create unique index if not exists employment_types_name_unique on public.employment_types(lower(name)) where deleted_at is null;
create unique index if not exists customer_types_code_unique on public.customer_types(upper(code)) where deleted_at is null;
create unique index if not exists customer_types_name_unique on public.customer_types(lower(name)) where deleted_at is null;
create index if not exists employment_types_display on public.employment_types(sort_order,name) where deleted_at is null;
create index if not exists customer_types_display on public.customer_types(sort_order,name) where deleted_at is null;
-- Only actual legacy values are migrated; example values are not seeded.
insert into public.employment_types(code,name,description) select 'LEGACY_'||upper(substr(md5(lower(trim(employment_type))),1,8)),min(trim(employment_type)),'Migrated from existing Employee Master data.' from public.employees where nullif(trim(employment_type),'') is not null group by lower(trim(employment_type)) on conflict do nothing;
insert into public.customer_types(code,name,description) select 'LEGACY_'||upper(substr(md5(lower(trim(company_type))),1,8)),min(trim(company_type)),'Migrated from existing Company Master data.' from public.customer_companies where nullif(trim(company_type),'') is not null group by lower(trim(company_type)) on conflict do nothing;
alter table public.employees add column if not exists employment_type_id uuid;
alter table public.customer_companies add column if not exists customer_type_id uuid;
update public.employees e set employment_type_id=t.id from public.employment_types t where e.employment_type_id is null and lower(trim(e.employment_type))=lower(t.name) and t.deleted_at is null;
update public.customer_companies c set customer_type_id=t.id from public.customer_types t where c.customer_type_id is null and lower(trim(c.company_type))=lower(t.name) and t.deleted_at is null;
alter table public.employees add constraint employees_employment_type_id_fkey foreign key(employment_type_id) references public.employment_types(id) on delete restrict;
alter table public.customer_companies add constraint customer_companies_customer_type_id_fkey foreign key(customer_type_id) references public.customer_types(id) on delete restrict;
create index if not exists employees_employment_type on public.employees(employment_type_id) where deleted_at is null;
create index if not exists customer_companies_customer_type on public.customer_companies(customer_type_id) where deleted_at is null;
create index if not exists departments_display on public.departments(sort_order,name) where deleted_at is null;
create index if not exists designations_display on public.designations(sort_order,name) where deleted_at is null;
create index if not exists teams_display on public.teams(sort_order,name) where deleted_at is null;
drop trigger if exists set_employment_types_updated_at on public.employment_types; create trigger set_employment_types_updated_at before update on public.employment_types for each row execute function public.set_updated_at();
drop trigger if exists set_customer_types_updated_at on public.customer_types; create trigger set_customer_types_updated_at before update on public.customer_types for each row execute function public.set_updated_at();
alter table public.departments enable row level security; alter table public.designations enable row level security; alter table public.teams enable row level security; alter table public.employment_types enable row level security; alter table public.customer_types enable row level security;
do $$ declare t text; begin foreach t in array array['departments','designations','teams','employment_types','customer_types'] loop
 execute format('drop policy if exists "Authenticated users can read %I" on public.%I',t,t); execute format('drop policy if exists "Authenticated users can insert %I" on public.%I',t,t); execute format('drop policy if exists "Authenticated users can update %I" on public.%I',t,t);
 execute format('create policy "ERP users can read %I" on public.%I for select to authenticated using (public.has_active_erp_access())',t,t); execute format('create policy "Admins can insert %I" on public.%I for insert to authenticated with check (public.is_erp_admin())',t,t); execute format('create policy "Admins can update %I" on public.%I for update to authenticated using (public.is_erp_admin()) with check (public.is_erp_admin())',t,t);
end loop; end $$;
grant select,insert,update on public.departments,public.designations,public.teams,public.employment_types,public.customer_types to authenticated;
comment on column public.employees.employment_type is 'Legacy text retained during the Phase 3A staged migration.';
comment on column public.customer_companies.company_type is 'Legacy text retained during the Phase 3A staged migration.';
commit;
