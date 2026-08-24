-- Adhunik ERP — Phase 2A Employee Master & Organization Mapping
-- Versioned migration: run once after 202608240001_phase_1b_enterprise_foundation.sql.

create sequence if not exists public.employee_code_seq start with 1 increment by 1 no cycle;

create or replace function public.generate_employee_code()
returns text language sql security invoker set search_path = '' as $$
  select 'ADH-EMP-' || lpad(nextval('public.employee_code_seq')::text, 4, '0');
$$;

create table if not exists public.employees (
  id uuid primary key default gen_random_uuid(),
  employee_code text not null unique default public.generate_employee_code(),
  full_name text not null check (length(trim(full_name)) > 0),
  first_name text, middle_name text, last_name text, gender text, date_of_birth date, joining_date date,
  department_id uuid references public.departments(id) on delete restrict,
  designation_id uuid references public.designations(id) on delete restrict,
  reporting_manager_id uuid references public.employees(id) on delete restrict,
  official_email text, personal_email text, phone text, alternate_phone text, blood_group text,
  photo_url text, emergency_contact_name text, emergency_contact_relationship text,
  emergency_contact_phone text, employment_type text, is_active boolean not null default true, notes text,
  created_at timestamptz not null default now(), created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_at timestamptz not null default now(), updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  deleted_at timestamptz, deleted_by uuid references auth.users(id) on delete set null,
  constraint employee_cannot_report_to_self check (reporting_manager_id is null or reporting_manager_id <> id)
);

create table if not exists public.employee_teams (
  id uuid primary key default gen_random_uuid(), employee_id uuid not null references public.employees(id) on delete cascade,
  team_id uuid not null references public.teams(id) on delete restrict,
  created_at timestamptz not null default now(), created_by uuid references auth.users(id) on delete set null default auth.uid(),
  unique (employee_id, team_id)
);

create table if not exists public.employee_addresses (
  id uuid primary key default gen_random_uuid(), employee_id uuid not null references public.employees(id) on delete restrict,
  address_type text not null default 'Current', address_line_1 text not null check (length(trim(address_line_1)) > 0),
  address_line_2 text, city text, district text, state text, postal_code text, country text not null default 'India',
  is_primary boolean not null default false, is_active boolean not null default true,
  created_at timestamptz not null default now(), created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_at timestamptz not null default now(), updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  deleted_at timestamptz, deleted_by uuid references auth.users(id) on delete set null
);

create index if not exists employees_name_search on public.employees using gin (full_name extensions.gin_trgm_ops);
create index if not exists employees_department on public.employees (department_id) where deleted_at is null;
create index if not exists employees_designation on public.employees (designation_id) where deleted_at is null;
create index if not exists employees_manager on public.employees (reporting_manager_id) where deleted_at is null;
create index if not exists employees_lifecycle on public.employees (is_active) where deleted_at is null;
create index if not exists employee_teams_employee on public.employee_teams (employee_id);
create index if not exists employee_teams_team on public.employee_teams (team_id);
create index if not exists employee_addresses_employee on public.employee_addresses (employee_id) where deleted_at is null;
create unique index if not exists employee_addresses_one_primary on public.employee_addresses (employee_id) where is_primary and is_active and deleted_at is null;

drop trigger if exists set_employees_updated_at on public.employees;
create trigger set_employees_updated_at before update on public.employees for each row execute function public.set_updated_at();
drop trigger if exists set_employee_addresses_updated_at on public.employee_addresses;
create trigger set_employee_addresses_updated_at before update on public.employee_addresses for each row execute function public.set_updated_at();

alter table public.employees enable row level security;
alter table public.employee_teams enable row level security;
alter table public.employee_addresses enable row level security;

do $$ declare t text; begin
  foreach t in array array['employees','employee_teams','employee_addresses'] loop
    execute format('create policy "Authenticated users can read %I" on public.%I for select to authenticated using (true)', t, t);
    execute format('create policy "Authenticated users can insert %I" on public.%I for insert to authenticated with check (auth.uid() is not null)', t, t);
    execute format('create policy "Authenticated users can update %I" on public.%I for update to authenticated using (auth.uid() is not null) with check (auth.uid() is not null)', t, t);
  end loop;
end $$;
grant select, insert, update on public.employees, public.employee_teams, public.employee_addresses to authenticated;
create policy "Authenticated users can delete employee team links" on public.employee_teams for delete to authenticated using (auth.uid() is not null);
grant delete on public.employee_teams to authenticated;
grant usage, select on sequence public.employee_code_seq to authenticated;

insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('employee-photos', 'employee-photos', false, 5242880, array['image/jpeg','image/png','image/webp'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit, allowed_mime_types = excluded.allowed_mime_types;

create policy "Authenticated users can view employee photos" on storage.objects for select to authenticated using (bucket_id = 'employee-photos');
create policy "Authenticated users can upload employee photos" on storage.objects for insert to authenticated with check (bucket_id = 'employee-photos' and (storage.foldername(name))[1] is not null);
create policy "Authenticated users can update employee photos" on storage.objects for update to authenticated using (bucket_id = 'employee-photos') with check (bucket_id = 'employee-photos');
create policy "Authenticated users can remove employee photos" on storage.objects for delete to authenticated using (bucket_id = 'employee-photos');

comment on column public.employees.employee_code is 'Permanent database-generated business identifier; Phase 3 may replace formatting configuration.';
comment on column public.employees.official_email is 'Employee information only; not an ERP login identity in Phase 2A.';
