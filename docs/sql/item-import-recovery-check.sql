-- READ ONLY. Run in the target project's SQL Editor before any retry.
-- This does not start or resume an import, create products, or change stock.
select b.id,b.source_name,b.state,b.created_at,b.committed_at,b.result,
       (select count(*)from public.item_import_links l where l.batch_id=b.id)committed_source_links
from public.item_import_batches b
where b.source_name='Item master v5.xlsx'
order by b.created_at desc;

-- PostgreSQL/PostgREST settings can differ by login and role. Inspect; do not change them.
select rolname,array(select setting from unnest(coalesce(rolconfig,array[]::text[]))setting
                     where setting like 'statement_timeout=%'or setting like 'lock_timeout=%')timeout_settings
from pg_catalog.pg_roles
where rolname in('authenticated','anon','authenticator');
select name,setting,unit from pg_catalog.pg_settings
where name in('statement_timeout','lock_timeout');

-- Also run the app's read-only preflight as a signed-in Admin after applying migration 002.
-- It reads existing item-code matches, conflicts and source links before a new job starts.
-- select public.item_import_recovery('<source batch UUID>'::uuid);
