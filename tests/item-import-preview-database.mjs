// Disposable local PostgreSQL only; never reads .env or contacts Supabase.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {randomUUID,createHash} from 'node:crypto';
import {createStockDatabase,stockRow,editStock,approveStock,stockStep} from './helpers/opening-stock-fixture.mjs';
import {scalar} from './helpers/item-import-fixture.mjs';
const db=await createStockDatabase(),q=(sql,args=[])=>scalar(db,sql,args);
let passed=0;const check=async(name,fn)=>{await fn();passed++;console.log('PASS '+name);};
const data=Array.from({length:2000},(_,n)=>stockRow(n+2,'PAGE-'+n,'1',{Family:'Family '+(n%5),'Item group':'Group '+(n%20)}));
const bytes=Buffer.from('read-only-fixture-source'),sha=createHash('sha256').update(bytes).digest('hex');
const stage=()=>q('select stage_item_import($1,$2,$3,$4,$5::jsonb)',['test.xlsx',sha,bytes.toString('base64'),'Sheet1',JSON.stringify(data)]);
let source,oldPreview;
try{
 for(const file of ['202611130001_import_read_performance.sql','202611130002_rejected_opening_stock.sql'])await db.exec(readFileSync(new URL('../supabase/migrations/'+file,import.meta.url),'utf8'));
 source=await stage();oldPreview=await stage();
 await q("select record_item_import_failure($1,'canceling statement due to statement timeout')",[oldPreview]);
 const before=await q('select jsonb_build_object(\'batches\',(select jsonb_agg(to_jsonb(b)order by id)from item_import_batches b),\'audit\',(select jsonb_agg(to_jsonb(a)order by id)from item_master_admin_activities a))');
 const legacy=await q('select item_import_preview($1::jsonb)',[JSON.stringify(data)]);
 await check('incremental migration preserves staging, historical failures and inventory',async()=>{
  await db.exec(readFileSync(new URL('../supabase/migrations/202611130003_item_import_preview_and_recovery.sql',import.meta.url),'utf8'));
  assert.deepEqual(await q('select jsonb_build_object(\'batches\',(select jsonb_agg(to_jsonb(b)order by id)from item_import_batches b),\'audit\',(select jsonb_agg(to_jsonb(a)order by id)from item_master_admin_activities a))'),before);
  assert.equal(Number(await q('select count(*)from items')),0);assert.equal(Number(await q('select count(*)from inventory_transactions')),0);
 });
 await check('cached validation is identical to the original 2,000-row validation',async()=>{
  const t=performance.now();const optimized=await q('select item_import_preview($1::jsonb)',[JSON.stringify(data)]);assert.deepEqual(optimized,legacy);console.log(JSON.stringify({cached_preview_ms:Math.round(performance.now()-t),rows:data.length}));
 });
 await check('repeated validation resolves each distinct classification once per call',async()=>{
  const sql=readFileSync(new URL('../supabase/migrations/202611120001_item_master_excel_import.sql',import.meta.url),'utf8');
  const start=sql.indexOf('create function public.item_import_master('),end=sql.indexOf('end$$;',start)+7,original=sql.slice(start,end);
  await db.exec(original.replace('public.item_import_master(', 'public.original_lookup_for_test('));
  await db.exec("create table lookup_calls_for_test(id integer);create or replace function public.item_import_master(p_table text,p_name text,p_parent uuid default null,p_parent_new boolean default false)returns jsonb language plpgsql security definer set search_path=''as $$begin insert into public.lookup_calls_for_test values(1);return public.original_lookup_for_test(p_table,p_name,p_parent,p_parent_new);end$$;");
  try{await q('select item_import_preview($1::jsonb)',[JSON.stringify(data)]);const calls=Number(await q('select count(*)from lookup_calls_for_test'));assert.ok(calls<50,`Expected distinct lookups, received ${calls}`);console.log(JSON.stringify({rows:data.length,classification_lookups:calls,original_lookups:data.length*6}));}
  finally{await db.exec(original.replace('create function','create or replace function'));}
 });
 await check('saved preview pages are bounded, ordered, revision-checked and read-only',async()=>{
  const initial=await q('select item_import_preview_page($1,1,0,100)',[source]);assert.equal(initial.rows.length,100);assert.equal(initial.total,2000);assert.equal(initial.eligible_rows.length,2000);assert.equal(initial.rows[0].row,2);
  const next=await q('select item_import_preview_page($1,1,100,100)',[source]);assert.equal(next.rows[0].row,102);assert.equal(next.eligible_rows,null);assert.equal((await q('select item_import_preview_page($1,1,1900,100)',[source])).rows.at(-1).row,2001);
  assert.equal((await q('select item_import_preview_page($1,1,2000,100)',[source])).rows.length,0);
  await assert.rejects(q('select item_import_preview_page($1,2,0,100)',[source]),/preview changed/);await assert.rejects(q('select item_import_preview_page($1,1,0,101)',[source]),/1–100/);
  assert.equal(Number(await q('select count(*)from items')),0);assert.equal(Number(await q('select count(*)from inventory_transactions')),0);
 });
 await check('partial completion does not suppress remaining workbook rows',async()=>{
  let p=await q('select start_item_import_job($1,1,$2,$3,100,true)',[source,[2],randomUUID()]);while(p.state==='RUNNING'&&p.next)p=await q('select process_item_import_chunk($1,$2,$3,$4)',[p.id,p.next.chunk_number,p.next.request_key,randomUUID()]);assert.equal(p.state,'COMPLETED');assert.equal(await q('select completed_item_import_source($1,$2)',[sha,'Sheet1']),null);
 });
 let completeSource;
 await check('2,000-row import safely reuses existing products; inventory remains unchanged',async()=>{
  completeSource=await stage();let p=await q('select start_item_import_job($1,1,$2,$3,100,true)',[completeSource,data.map(r=>r.row),randomUUID()]);while(p.state==='RUNNING'&&p.next)p=await q('select process_item_import_chunk($1,$2,$3,$4)',[p.id,p.next.chunk_number,p.next.request_key,randomUUID()]);assert.equal(p.state,'COMPLETED');assert.equal(p.created,1999);assert.equal(p.existing,1);assert.equal(Number(await q('select count(*)from items')),2000);assert.equal(Number(await q('select count(*)from inventory_transactions')),0);
  assert.equal(await q('select completed_item_import_source($1,$2)',[sha,'Sheet1']),completeSource);
 });
 await check('repeat upload returns the completed source without creating preview, products or audit events',async()=>{
  const before=await q('select jsonb_build_object(\'items\',(select jsonb_agg(to_jsonb(i)order by id)from items i),\'batches\',(select count(*)from item_import_batches),\'audit\',(select count(*)from item_master_admin_activities))');
  assert.equal(await stage(),completeSource);
  assert.deepEqual(await q('select jsonb_build_object(\'items\',(select jsonb_agg(to_jsonb(i)order by id)from items i),\'batches\',(select count(*)from item_import_batches),\'audit\',(select count(*)from item_master_admin_activities))'),before);
 });
 await check('old identical preview cannot confirm or refresh after full success; historical timeout remains',async()=>{
  await assert.rejects(q('select start_item_import_job($1,1,$2,$3,100,true)',[oldPreview,data.map(r=>r.row),randomUUID()]),/already fully committed/);
  await assert.rejects(q('select refresh_item_import($1)',[oldPreview]),/already fully committed/);
  assert.equal(Number(await q("select count(*)from item_master_admin_activities where batch_id=$1 and event_type='IMPORT_ATTEMPT_FAILED'",[oldPreview])),1);
  assert.equal(Number(await q('select count(*)from items')),2000);
 });
 await check('separate stock preview preserves quantities until approval; usable/rejected posting is idempotent',async()=>{
  const before=await q('select jsonb_agg(to_jsonb(i)order by id)from items i');
  const job=await q('select create_opening_stock_preview($1)',[completeSource]);
  await editStock(db,job,data.map(r=>({row:r.row,quantity:'1',rejected:r.row===2?'2':'0',selected:r.row===2,location:null})));
  assert.equal(Number(await q('select count(*)from inventory_balances')),0);assert.equal(Number(await q('select count(*)from inventory_transactions')),0);
  const approval=await approveStock(db,job);assert.equal(Number(await q('select count(*)from inventory_transactions')),0);
  const done=await stockStep(db,approval);assert.equal(done.posted,1);assert.equal((await stockStep(db,approval)).posted,1);
  assert.equal(Number(await q('select count(*)from inventory_transactions')),2);assert.equal(Number(await q('select sum(on_hand_quantity)from inventory_balances')),1);assert.equal(Number(await q('select sum(rejected_quantity)from inventory_balances')),2);assert.equal(Number(await q('select sum(damaged_quantity)from inventory_balances')),0);
  assert.deepEqual(await q('select jsonb_agg(to_jsonb(i)order by id)from items i'),before);
 });
 await check('RLS checks protect lookup and preview RPCs',async()=>{
  await db.exec("set role authenticated;select set_config('test.role','USER',false)");await assert.rejects(q('select completed_item_import_source($1,$2)',[sha,'Sheet1']),/Admin/);await assert.rejects(q('select item_import_preview_page($1,1,0,100)',[oldPreview]),/Admin/);
  await db.exec('reset role;set role anon');await assert.rejects(q('select completed_item_import_source($1,$2)',[sha,'Sheet1']),/permission denied/);await db.exec("reset role;select set_config('test.role','ADMIN',false)");
 });
 await check('normalized item-code index is used for point lookups',async()=>{
  await db.exec('analyze items');const plan=(await db.query("explain (format json)select id from items where lower(trim(item_code))=lower(trim($1))",['PAGE-1999'])).rows[0]['QUERY PLAN'];assert.match(JSON.stringify(plan),/items_import_normalized_code/);
 });
 console.log(`${passed} item import preview/recovery database checks passed`);
}finally{await db.close();}
