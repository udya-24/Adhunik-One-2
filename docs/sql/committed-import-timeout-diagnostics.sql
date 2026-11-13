-- READ ONLY. Run as the authorized database administrator against the intended test
-- database first. No import/posting/retry RPC is invoked. Record the cancelled RPC
-- name/request and timestamp from Supabase/PostgREST logs to identify the live failure.
-- pg_stat_statements, when enabled, reports aggregate timing, not which call cancelled.
select id,source_name,state,source_row_count,revision,committed_at
from public.item_import_batches
where source_name='Item master v5.xlsx' and purpose='ITEM_MASTER'
order by created_at desc,id desc limit 50;

select schemaname,tablename,indexname,indexdef from pg_catalog.pg_indexes
where schemaname='public' and tablename in
 ('item_import_batches','item_master_admin_activities','item_import_links','inventory_transactions')
order by tablename,indexname;

select rolname,rolconfig from pg_catalog.pg_roles
where rolname in('authenticated','anon','authenticator');
select name,setting,unit from pg_catalog.pg_settings
where name in('statement_timeout','lock_timeout');

explain (analyze,buffers)
select id,source_name,state,created_at from public.item_import_batches
where purpose='ITEM_MASTER' order by created_at desc,id desc limit 50;

-- Replace the UUID below with the already COMMITTED batch ID before running:
-- explain (analyze,buffers)
-- select id,event_type,details,created_at,created_by
-- from public.item_master_admin_activities
-- where batch_id='<committed batch UUID>'::uuid
-- order by created_at desc,id desc limit 50;
-- Compare through the authenticated Admin application as well: a SQL Editor owner
-- plan does not reproduce PostgREST role settings or RLS overhead.
