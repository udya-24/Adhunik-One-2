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

-- Distinguish persisted failure messages from a new read/RPC error. These rows
-- are historical audit, not proof that the current page request just timed out.
select b.id,b.state,b.created_at batch_created_at,a.event_type,a.created_at event_time,
       a.details->>'message' saved_message
from public.item_master_admin_activities a
join public.item_import_batches b on b.id=a.batch_id
where b.source_name='Item master v5.xlsx'
  and a.event_type in('IMPORT_ATTEMPT_FAILED','IMPORT_CHUNK_FAILED','IMPORT_CHUNK_INTERRUPTED')
order by a.created_at desc,a.id desc limit 50;

select b.id,b.state,j.id job_id,j.state job_state,
       count(*) chunks,sum(c.row_count) selected_rows,
       count(*)filter(where c.state='COMPLETED') completed_chunks,
       min(c.elapsed_ms) minimum_ms,max(c.elapsed_ms) maximum_ms,
       max(c.attempts) maximum_attempts
from public.item_import_batches b join public.item_import_jobs j on j.batch_id=b.id
join public.item_import_job_chunks c on c.job_id=j.id
where b.source_name='Item master v5.xlsx'
group by b.id,b.state,j.id,j.state;

-- After applying migration 202611130003, verify expression-index use for a
-- representative existing item. Run as the intended role for RLS comparison.
explain (analyze,buffers)
select id from public.items where lower(trim(item_code))=lower(trim('REPLACE_WITH_EXISTING_CODE'));
