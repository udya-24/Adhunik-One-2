-- Adhunik ERP — Module 1 Part B: Customer Company & Organization Foundation
-- Safe for a fresh project. Uses IF NOT EXISTS where PostgreSQL supports it, but
-- this is a versioned migration and should normally be run exactly once.

create extension if not exists pg_trgm with schema extensions;

create or replace function public.set_updated_at()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  new.updated_at = now();
  new.updated_by = auth.uid();
  return new;
end;
$$;

create table if not exists public.customer_companies (
  id uuid primary key default gen_random_uuid(),
  company_code text,
  legal_name text not null check (length(trim(legal_name)) > 0),
  trade_name text,
  company_type text,
  gstin text check (gstin is null or gstin ~ '^[0-9]{2}[A-Z]{5}[0-9]{4}[A-Z][1-9A-Z]Z[0-9A-Z]$'),
  pan text check (pan is null or pan ~ '^[A-Z]{5}[0-9]{4}[A-Z]$'),
  primary_email text,
  primary_phone text,
  website text,
  payment_terms text,
  credit_days integer check (credit_days is null or credit_days >= 0),
  credit_limit numeric(15,2) check (credit_limit is null or credit_limit >= 0),
  notes text,
  is_active boolean not null default true,
  created_at timestamptz not null default now(),
  created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_at timestamptz not null default now(),
  updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  deleted_at timestamptz,
  deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists public.customer_contacts (
  id uuid primary key default gen_random_uuid(),
  customer_company_id uuid not null references public.customer_companies(id) on delete restrict,
  contact_name text not null check (length(trim(contact_name)) > 0),
  designation text, department text, phone text, alternate_phone text, email text,
  is_primary boolean not null default false, notes text, is_active boolean not null default true,
  created_at timestamptz not null default now(), created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_at timestamptz not null default now(), updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  deleted_at timestamptz, deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists public.customer_addresses (
  id uuid primary key default gen_random_uuid(),
  customer_company_id uuid not null references public.customer_companies(id) on delete restrict,
  address_type text not null default 'Office', address_line_1 text not null check (length(trim(address_line_1)) > 0),
  address_line_2 text, city text, district text, state text, postal_code text, country text not null default 'India',
  is_primary boolean not null default false, is_active boolean not null default true,
  created_at timestamptz not null default now(), created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_at timestamptz not null default now(), updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  deleted_at timestamptz, deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists public.departments (
  id uuid primary key default gen_random_uuid(), name text not null, code text, description text,
  is_active boolean not null default true, sort_order integer not null default 0,
  created_at timestamptz not null default now(), created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_at timestamptz not null default now(), updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  deleted_at timestamptz, deleted_by uuid references auth.users(id) on delete set null
);

create table if not exists public.designations (like public.departments including defaults including constraints);
alter table public.designations add primary key (id);
alter table public.designations add constraint designations_created_by_fkey foreign key (created_by) references auth.users(id) on delete set null;
alter table public.designations add constraint designations_updated_by_fkey foreign key (updated_by) references auth.users(id) on delete set null;
alter table public.designations add constraint designations_deleted_by_fkey foreign key (deleted_by) references auth.users(id) on delete set null;

create table if not exists public.teams (
  id uuid primary key default gen_random_uuid(), department_id uuid references public.departments(id) on delete restrict,
  name text not null, code text, description text, is_active boolean not null default true, sort_order integer not null default 0,
  created_at timestamptz not null default now(), created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_at timestamptz not null default now(), updated_by uuid references auth.users(id) on delete set null default auth.uid(),
  deleted_at timestamptz, deleted_by uuid references auth.users(id) on delete set null
);

create unique index if not exists customer_companies_code_unique on public.customer_companies (upper(company_code)) where company_code is not null and deleted_at is null;
create unique index if not exists customer_companies_gstin_unique on public.customer_companies (upper(gstin)) where gstin is not null and deleted_at is null;
create index if not exists customer_companies_name_search on public.customer_companies using gin (legal_name extensions.gin_trgm_ops);
create index if not exists customer_companies_lifecycle on public.customer_companies (is_active) where deleted_at is null;
create index if not exists customer_contacts_company on public.customer_contacts (customer_company_id) where deleted_at is null;
create index if not exists customer_addresses_company on public.customer_addresses (customer_company_id) where deleted_at is null;
create index if not exists teams_department on public.teams (department_id) where deleted_at is null;
create unique index if not exists departments_code_unique on public.departments (upper(code)) where code is not null and deleted_at is null;
create unique index if not exists designations_code_unique on public.designations (upper(code)) where code is not null and deleted_at is null;
create unique index if not exists teams_code_unique on public.teams (upper(code)) where code is not null and deleted_at is null;
create unique index if not exists customer_contacts_one_primary on public.customer_contacts (customer_company_id) where is_primary and is_active and deleted_at is null;
create unique index if not exists customer_addresses_one_primary on public.customer_addresses (customer_company_id) where is_primary and is_active and deleted_at is null;

do $$ declare t text; begin
  foreach t in array array['customer_companies','customer_contacts','customer_addresses','departments','designations','teams'] loop
    execute format('drop trigger if exists set_%I_updated_at on public.%I', t, t);
    execute format('create trigger set_%I_updated_at before update on public.%I for each row execute function public.set_updated_at()', t, t);
    execute format('alter table public.%I enable row level security', t);
    execute format('drop policy if exists "Authenticated users can read %I" on public.%I', t, t);
    execute format('drop policy if exists "Authenticated users can insert %I" on public.%I', t, t);
    execute format('drop policy if exists "Authenticated users can update %I" on public.%I', t, t);
    execute format('create policy "Authenticated users can read %I" on public.%I for select to authenticated using (true)', t, t);
    execute format('create policy "Authenticated users can insert %I" on public.%I for insert to authenticated with check (auth.uid() is not null)', t, t);
    execute format('create policy "Authenticated users can update %I" on public.%I for update to authenticated using (auth.uid() is not null) with check (auth.uid() is not null)', t, t);
  end loop;
end $$;

grant select, insert, update on public.customer_companies, public.customer_contacts, public.customer_addresses,
  public.departments, public.designations, public.teams to authenticated;

comment on table public.customer_companies is 'External customer organizations; never Adhunik Switchgears own legal entity.';
comment on column public.customer_companies.company_code is 'Temporary manual code until Module 3 numbering configuration.';
