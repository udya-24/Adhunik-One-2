-- Adhunik ERP - Phase 3B Numbering, Business & System Configuration
-- Safe to rerun after 202608240004_phase_3a_configuration_masters.sql.
begin;

create table if not exists public.numbering_configurations (
 id uuid primary key default gen_random_uuid(), entity_type text not null unique check(entity_type in('EMPLOYEE','CUSTOMER')),
 prefix text not null default '', suffix text not null default '', padding integer not null default 4 check(padding between 1 and 12),
 separator text not null default '-', include_year boolean not null default false, include_financial_year boolean not null default false, is_active boolean not null default true,
 created_at timestamptz not null default now(), created_by uuid references auth.users(id) on delete set null default auth.uid(),
 updated_at timestamptz not null default now(), updated_by uuid references auth.users(id) on delete set null default auth.uid()
);
create table if not exists public.numbering_counters (
 entity_type text primary key references public.numbering_configurations(entity_type) on delete restrict,
 current_value bigint not null default 0 check(current_value>=0), updated_at timestamptz not null default now()
);
insert into public.numbering_configurations(entity_type,prefix,padding,separator)
values('EMPLOYEE','ADH-EMP',4,'-'),('CUSTOMER','CUS',4,'-')
on conflict(entity_type) do nothing;

-- Never lower a live counter. Raise it only above already-consumed legacy numbers.
with required_values as (
 select 'EMPLOYEE'::text entity_type,greatest(
  coalesce((select max((substring(employee_code from '([0-9]+)$'))::bigint) from public.employees where employee_code~'[0-9]+$'),0),
  coalesce((select last_value from public.employee_code_seq),0)) current_value
 union all
 select 'CUSTOMER',coalesce((select max((substring(company_code from '([0-9]+)$'))::bigint) from public.customer_companies where company_code~'[0-9]+$'),0)
)
insert into public.numbering_counters(entity_type,current_value)
select entity_type,current_value from required_values
on conflict(entity_type) do update set
 current_value=greatest(public.numbering_counters.current_value,excluded.current_value),
 updated_at=case when excluded.current_value>public.numbering_counters.current_value then now() else public.numbering_counters.updated_at end;

create table if not exists public.financial_years (
 id uuid primary key default gen_random_uuid(), code text not null, name text not null, start_date date not null, end_date date not null,
 is_current boolean not null default false, is_active boolean not null default true,
 created_at timestamptz not null default now(), created_by uuid references auth.users(id) on delete set null default auth.uid(),
 updated_at timestamptz not null default now(), updated_by uuid references auth.users(id) on delete set null default auth.uid(),
 deleted_at timestamptz, deleted_by uuid references auth.users(id) on delete set null,
 constraint financial_year_valid_range check(start_date<end_date)
);
create unique index if not exists financial_years_code_unique on public.financial_years(upper(code)) where deleted_at is null;
create unique index if not exists financial_years_one_current on public.financial_years(is_current) where is_current and deleted_at is null;
create index if not exists financial_years_dates on public.financial_years(start_date,end_date) where deleted_at is null;

create table if not exists public.system_settings (
 id uuid primary key default gen_random_uuid(), category text not null check(category in('GENERAL','LOCALIZATION')), key text not null,
 value text not null, data_type text not null default 'STRING' check(data_type in('STRING','BOOLEAN','INTEGER')),
 description text, is_system boolean not null default true,
 created_at timestamptz not null default now(), created_by uuid references auth.users(id) on delete set null default auth.uid(),
 updated_at timestamptz not null default now(), updated_by uuid references auth.users(id) on delete set null default auth.uid(), unique(category,key)
);
insert into public.system_settings(category,key,value,description) values
('GENERAL','BUSINESS_DISPLAY_NAME','Adhunik Switchgears','Business name displayed by ERP'),
('LOCALIZATION','DEFAULT_COUNTRY','India','Default country'),
('LOCALIZATION','DEFAULT_CURRENCY','INR','ISO currency code'),
('LOCALIZATION','TIMEZONE','Asia/Kolkata','Business timezone'),
('LOCALIZATION','DATE_FORMAT','DD/MM/YYYY','Supported display date format')
on conflict(category,key) do nothing;

create table if not exists public.payment_terms (
 id uuid primary key default gen_random_uuid(), code text not null, name text not null, description text,
 credit_days integer check(credit_days is null or credit_days>=0), sort_order integer not null default 0, is_active boolean not null default true,
 created_at timestamptz not null default now(), created_by uuid references auth.users(id) on delete set null default auth.uid(),
 updated_at timestamptz not null default now(), updated_by uuid references auth.users(id) on delete set null default auth.uid(),
 deleted_at timestamptz, deleted_by uuid references auth.users(id) on delete set null
);
create unique index if not exists payment_terms_code_unique on public.payment_terms(upper(code)) where deleted_at is null;
create unique index if not exists payment_terms_name_unique on public.payment_terms(lower(name)) where deleted_at is null;
create index if not exists payment_terms_display on public.payment_terms(sort_order,name) where deleted_at is null;
insert into public.payment_terms(code,name,description)
select 'LEGACY_'||upper(substr(md5(lower(trim(payment_terms))),1,8)),min(trim(payment_terms)),'Migrated from existing Company Master data.'
from public.customer_companies where nullif(trim(payment_terms),'') is not null group by lower(trim(payment_terms))
on conflict do nothing;

alter table public.customer_companies add column if not exists payment_term_id uuid;
do $$
begin
 if not exists(select 1 from pg_constraint where conrelid='public.customer_companies'::regclass and conname='customer_companies_payment_term_id_fkey') then
  alter table public.customer_companies add constraint customer_companies_payment_term_id_fkey
   foreign key(payment_term_id) references public.payment_terms(id) on delete restrict;
 end if;
end
$$;
update public.customer_companies c set payment_term_id=p.id from public.payment_terms p
where c.payment_term_id is null and lower(trim(c.payment_terms))=lower(p.name) and p.deleted_at is null;
create index if not exists customer_companies_payment_term on public.customer_companies(payment_term_id) where deleted_at is null;

create or replace function public.allocate_business_number(p_entity_type text) returns text
language plpgsql security definer set search_path='' as $$
declare cfg public.numbering_configurations%rowtype; next_value bigint; fy_code text; number_parts text[];
begin
 select * into cfg from public.numbering_configurations where entity_type=upper(p_entity_type) and is_active;
 if not found then raise exception 'Numbering is not active for %',p_entity_type; end if;
 update public.numbering_counters set current_value=current_value+1,updated_at=now()
 where entity_type=cfg.entity_type returning current_value into next_value;
 if next_value is null then raise exception 'Numbering counter is missing for %',p_entity_type; end if;
 if cfg.include_financial_year then
  select code into fy_code from public.financial_years where is_current and is_active and deleted_at is null;
  if fy_code is null then raise exception 'A current Financial Year is required'; end if;
 end if;
 number_parts:=array_remove(array[nullif(cfg.prefix,''),
  case when cfg.include_year then extract(year from current_date)::integer::text end,
  case when cfg.include_financial_year then fy_code end,lpad(next_value::text,cfg.padding,'0'),nullif(cfg.suffix,'')],null);
 return array_to_string(number_parts,cfg.separator);
end
$$;
revoke all on function public.allocate_business_number(text) from public,anon,authenticated;

create or replace function public.assign_employee_number() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if nullif(trim(new.employee_code),'') is null then new.employee_code:=public.allocate_business_number('EMPLOYEE'); end if;
 return new;
end
$$;
create or replace function public.assign_customer_number() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if nullif(trim(new.company_code),'') is null and exists(
  select 1 from public.numbering_configurations where entity_type='CUSTOMER' and is_active
 ) then new.company_code:=public.allocate_business_number('CUSTOMER'); end if;
 return new;
end
$$;
alter table public.employees alter column employee_code drop default;
drop trigger if exists assign_employee_number on public.employees;
create trigger assign_employee_number before insert on public.employees for each row execute function public.assign_employee_number();
drop trigger if exists assign_customer_number on public.customer_companies;
create trigger assign_customer_number before insert on public.customer_companies for each row execute function public.assign_customer_number();

create or replace function public.get_numbering_overview()
returns table(entity_type text,format_pattern text,current_value bigint,last_generated text,next_preview text,is_active boolean)
language sql stable security definer set search_path='' as $$
 with d as(
  select c.*,n.current_value,(select code from public.financial_years where is_current and is_active and deleted_at is null) fy
  from public.numbering_configurations c join public.numbering_counters n using(entity_type)
 )
 select d.entity_type,
  array_to_string(array_remove(array[nullif(prefix,''),case when include_year then extract(year from current_date)::integer::text end,
   case when include_financial_year then fy end,repeat('#',padding),nullif(suffix,'')],null),separator),
  current_value,
  case when current_value=0 then null else array_to_string(array_remove(array[nullif(prefix,''),
   case when include_year then extract(year from current_date)::integer::text end,case when include_financial_year then fy end,
   lpad(current_value::text,padding,'0'),nullif(suffix,'')],null),separator) end,
  array_to_string(array_remove(array[nullif(prefix,''),case when include_year then extract(year from current_date)::integer::text end,
   case when include_financial_year then fy end,lpad((current_value+1)::text,padding,'0'),nullif(suffix,'')],null),separator),
  is_active
 from d where public.has_active_erp_access() order by d.entity_type
$$;
grant execute on function public.get_numbering_overview() to authenticated;

create or replace function public.get_current_financial_year() returns public.financial_years
language sql stable security definer set search_path='' as $$
 select f.* from public.financial_years f
 where f.is_current and f.is_active and f.deleted_at is null and public.has_active_erp_access() limit 1
$$;
grant execute on function public.get_current_financial_year() to authenticated;

-- The invalid generated marker was intended to install these common triggers.
do $$
declare target_table text; trigger_name text;
begin
 foreach target_table in array array['numbering_configurations','financial_years','system_settings','payment_terms']
 loop
  trigger_name:='set_'||target_table||'_updated_at';
  execute format('drop trigger if exists %I on public.%I',trigger_name,target_table);
  execute format('create trigger %I before update on public.%I for each row execute function public.set_updated_at()',trigger_name,target_table);
 end loop;
end
$$;

alter table public.numbering_configurations enable row level security;
alter table public.numbering_counters enable row level security;
alter table public.financial_years enable row level security;
alter table public.system_settings enable row level security;
alter table public.payment_terms enable row level security;

do $$
declare target_table text; read_policy text; insert_policy text; update_policy text;
begin
 foreach target_table in array array['numbering_configurations','financial_years','system_settings','payment_terms']
 loop
  read_policy:='ERP users read '||target_table; insert_policy:='Admins insert '||target_table; update_policy:='Admins update '||target_table;
  execute format('drop policy if exists %I on public.%I',read_policy,target_table);
  execute format('drop policy if exists %I on public.%I',insert_policy,target_table);
  execute format('drop policy if exists %I on public.%I',update_policy,target_table);
  execute format('create policy %I on public.%I for select to authenticated using(public.has_active_erp_access())',read_policy,target_table);
  execute format('create policy %I on public.%I for insert to authenticated with check(public.is_erp_admin())',insert_policy,target_table);
  execute format('create policy %I on public.%I for update to authenticated using(public.is_erp_admin()) with check(public.is_erp_admin())',update_policy,target_table);
 end loop;
end
$$;

grant select on table public.numbering_configurations,public.financial_years,public.system_settings,public.payment_terms to authenticated;
grant insert,update on table public.numbering_configurations,public.financial_years,public.system_settings,public.payment_terms to authenticated;
-- No counter policy and no direct application-role privilege: the database owns advancement.
revoke all on table public.numbering_counters from public,anon,authenticated;

commit;
