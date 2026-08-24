-- Adhunik ERP — Phase 2B ERP Identity & Employee Linking
-- Run once after Phase 2A. Existing Auth users and employee records are preserved.

create table if not exists public.erp_roles (
  id uuid primary key default gen_random_uuid(), code text not null unique, name text not null,
  description text, is_system boolean not null default true, is_active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
insert into public.erp_roles (code,name,description) values
  ('ADMIN','Admin','Basic ERP identity administrator'),
  ('MANAGER','Manager','Basic ERP manager classification'),
  ('USER','User','Basic authenticated ERP user')
on conflict (code) do update set name=excluded.name, description=excluded.description, is_system=true;

create table if not exists public.erp_profiles (
  id uuid primary key default gen_random_uuid(),
  auth_user_id uuid not null unique references auth.users(id) on delete restrict,
  employee_id uuid unique references public.employees(id) on delete restrict,
  role_id uuid not null references public.erp_roles(id) on delete restrict,
  login_email text not null,
  is_active boolean not null default true,
  last_login_at timestamptz,
  created_at timestamptz not null default now(), created_by uuid references auth.users(id) on delete set null default auth.uid(),
  updated_at timestamptz not null default now(), updated_by uuid references auth.users(id) on delete set null default auth.uid()
);

create table if not exists public.employee_invitations (
  id uuid primary key default gen_random_uuid(), employee_id uuid not null references public.employees(id) on delete restrict,
  auth_user_id uuid references auth.users(id) on delete set null, email text not null,
  role_id uuid not null references public.erp_roles(id) on delete restrict,
  status text not null default 'PENDING' check (status in ('PENDING','ACCEPTED','EXPIRED','CANCELLED')),
  invited_by uuid not null references auth.users(id) on delete restrict, invited_at timestamptz not null default now(),
  accepted_at timestamptz, expires_at timestamptz, created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(), updated_by uuid references auth.users(id) on delete set null default auth.uid()
);
create unique index if not exists employee_invitations_one_pending_employee on public.employee_invitations(employee_id) where status='PENDING';
create unique index if not exists employee_invitations_one_pending_email on public.employee_invitations(lower(email)) where status='PENDING';
create index if not exists erp_profiles_employee on public.erp_profiles(employee_id);
create index if not exists erp_profiles_role on public.erp_profiles(role_id);
create index if not exists employee_invitations_employee on public.employee_invitations(employee_id);

drop trigger if exists set_erp_profiles_updated_at on public.erp_profiles;
create trigger set_erp_profiles_updated_at before update on public.erp_profiles for each row execute function public.set_updated_at();
drop trigger if exists set_employee_invitations_updated_at on public.employee_invitations;
create trigger set_employee_invitations_updated_at before update on public.employee_invitations for each row execute function public.set_updated_at();

create or replace function public.is_erp_admin()
returns boolean language sql stable security definer set search_path='' as $$
  select exists (
    select 1 from public.erp_profiles p join public.erp_roles r on r.id=p.role_id
    where p.auth_user_id=auth.uid() and p.is_active and r.code='ADMIN' and r.is_active
  );
$$;
create or replace function public.has_active_erp_access()
returns boolean language sql stable security definer set search_path='' as $$
  select exists (
    select 1 from public.erp_profiles p left join public.employees e on e.id=p.employee_id
    where p.auth_user_id=auth.uid() and p.is_active and (p.employee_id is null or (e.is_active and e.deleted_at is null))
  );
$$;
create or replace function public.accept_own_erp_invitation()
returns void language plpgsql security definer set search_path='' as $$
begin
  update public.employee_invitations set status='ACCEPTED', accepted_at=now(), updated_at=now()
  where auth_user_id=auth.uid() and status='PENDING';
end;
$$;
create or replace function public.record_erp_login()
returns void language sql security definer set search_path='' as $$
  update public.erp_profiles set last_login_at=now(), updated_at=now() where auth_user_id=auth.uid() and is_active;
$$;
grant execute on function public.is_erp_admin(), public.has_active_erp_access(), public.accept_own_erp_invitation(), public.record_erp_login() to authenticated;

-- Preserve the pre-Phase-2B administrator without guessing an employee link.
-- The earliest existing Auth account receives a bootstrap ADMIN profile and can be linked explicitly in the UI.
insert into public.erp_profiles(auth_user_id, employee_id, role_id, login_email, is_active, created_by, updated_by)
select u.id, null, r.id, coalesce(u.email,''), true, u.id, u.id
from auth.users u cross join public.erp_roles r where r.code='ADMIN'
and u.id=(select id from auth.users order by created_at asc limit 1)
on conflict (auth_user_id) do nothing;

alter table public.erp_roles enable row level security;
alter table public.erp_profiles enable row level security;
alter table public.employee_invitations enable row level security;
revoke all on public.erp_roles, public.erp_profiles, public.employee_invitations from anon, authenticated;
grant select on public.erp_roles to authenticated;
grant select, insert, update on public.erp_profiles, public.employee_invitations to authenticated;
create policy "Authenticated users read active basic roles" on public.erp_roles for select to authenticated using (is_active);
create policy "Users read own profile and admins read profiles" on public.erp_profiles for select to authenticated using (auth_user_id=(select auth.uid()) or public.is_erp_admin());
create policy "Admins insert profiles" on public.erp_profiles for insert to authenticated with check (public.is_erp_admin());
create policy "Admins update profiles" on public.erp_profiles for update to authenticated using (public.is_erp_admin()) with check (public.is_erp_admin());
create policy "Admins read invitations" on public.employee_invitations for select to authenticated using (public.is_erp_admin());
create policy "Admins insert invitations" on public.employee_invitations for insert to authenticated with check (public.is_erp_admin() and invited_by=(select auth.uid()));
create policy "Admins update invitations" on public.employee_invitations for update to authenticated using (public.is_erp_admin()) with check (public.is_erp_admin());

comment on table public.erp_profiles is 'ERP access identity linking Auth UUID to an optional employee UUID; permissions remain Phase 15 scope.';
comment on column public.erp_profiles.employee_id is 'Nullable only for bootstrap administration; link explicitly through ERP Access.';
