# Adhunik ERP

Enterprise Management System for Adhunik Switchgears.

**Current Module: Module 2 â€” Employee & Identity Management (Part B in development)**

## Technology

Next.js App Router, TypeScript, Tailwind CSS, Supabase Auth/PostgreSQL, and Lucide React. The project is ready for GitHub and Vercel workflows.

## Local setup

1. Install Node.js 20.9 or newer.
2. Create a Supabase project.
3. Copy `.env.example` to `.env.local`.
4. Add the project URL and publishable/legacy anon key to `.env.local`.
5. Install dependencies and start development:

```bash
npm install
npm run dev
```

Open `http://localhost:3000`.

## Required environment variables

```text
NEXT_PUBLIC_SUPABASE_URL
NEXT_PUBLIC_SUPABASE_ANON_KEY
SUPABASE_SERVICE_ROLE_KEY
NEXT_PUBLIC_SITE_URL
```

Only the browser-safe Supabase anon/publishable key belongs in this application. Never expose a service-role key.

`SUPABASE_SERVICE_ROLE_KEY` is server-only and required for Phase 2B invitation and existing-user linking operations. Add it to local and Vercel server environments without the `NEXT_PUBLIC_` prefix. `NEXT_PUBLIC_SITE_URL` is used to build the approved invitation callback URL.

## Supabase setup

1. In the Supabase dashboard, open **Authentication â†’ Providers â†’ Email** and enable Email/Password authentication.
2. For an internal ERP, disable public sign-up if employees should only be created by an administrator.
3. Open **Authentication â†’ Users â†’ Add user â†’ Create new user** and enter the initial administrator email and a strong password. Auto-confirm the user when prompted.
4. Open **SQL Editor**, paste the complete contents of `supabase/migrations/202608240001_phase_1b_enterprise_foundation.sql`, and run it once.
5. Confirm that `customer_companies`, `customer_contacts`, `customer_addresses`, `departments`, `designations`, and `teams` appear in Table Editor.
6. In Table Editor, verify that RLS is enabled for all six tables. The temporary policies allow authenticated users to select, insert, and update records; anonymous users receive no access.
7. Enter the project URL and anon/publishable key in `.env.local`, restart the development server, and sign in at `/login`.

### Phase 2A migration

After the Module 1 migration, run the complete `supabase/migrations/202608240002_phase_2a_employee_master.sql` file once in Supabase SQL Editor. It creates the employee tables, safe employee-code sequence, RLS policies, and the private `employee-photos` Storage bucket. No manual bucket creation or public access setting is required.

### Phase 2B migration

Run `supabase/migrations/202608240003_phase_2b_identity_access.sql` once after Phase 2A. It creates the three basic roles, ERP profiles, invitation records, access-check functions, RLS policies, and a bootstrap Admin profile for the earliest existing Auth user. Add `/auth/callback` for each deployment origin to Supabase **Authentication â†’ URL Configuration â†’ Redirect URLs**.


### Phase 3A migration

Run `supabase/migrations/202608240004_phase_3a_configuration_masters.sql` once after Phase 2B. It reuses Departments, Designations, Teams, and employee-team links; creates Employment Types and Customer Types; preserves and maps existing employee/company type text; adds UUID foreign keys; and replaces organization-master write policies with Admin-only RLS. The legacy text columns remain during this staged migration for compatibility and verification.

### Phase 3B migration

Run `supabase/migrations/202608240005_phase_3b_business_configuration.sql` once after Phase 3A. It preserves existing Employee and Company codes, centralizes future numbering behind protected atomic database triggers, adds Financial Years, General/System Settings, and Payment Terms, and migrates existing company payment-term text into UUID master relationships. Live counters are not writable through the application or authenticated database role.
For production, add both environment variables to the Vercel project for the required environments, then redeploy. Add the production deployment URL under Supabase **Authentication â†’ URL Configuration** as the Site URL. No machine-specific configuration is required.

## Commands

```bash
npm run dev
npm run lint
npm run build
npm start
```

## Module 1 scope

Part A supplies authentication, protected routes, the responsive application shell, dashboard, system status, settings foundation, and future-module placeholders.

Part B supplies the external customer Company Master, contacts, addresses, pagination, search and filters, lifecycle management, audit metadata, RLS, soft-delete foundations, and schema-only foundations for departments, designations, and teams. Company codes are entered manually until Module 3 introduces configurable numbering. No organizational seed data is installed.

The current authenticated-user RLS policy is deliberately temporary. Module 2 will introduce employee identity, and Module 15 will tighten authorization. No service-role credential is used by the application.

## Phase 2A scope

Employee Master stores employee records independently from ERP login accounts. It includes database-generated permanent employee codes, organization mapping, multiple team assignments, reporting managers, contacts, emergency information, private employee photos, addresses, search/filtering, pagination, and active/inactive lifecycle management. It does not create Supabase Auth users, store passwords, or implement roles, access control, attendance, payroll, or other HR workflows.

See [ROADMAP.md](./ROADMAP.md) for phase tracking.
