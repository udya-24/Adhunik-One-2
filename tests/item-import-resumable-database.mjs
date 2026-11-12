// Disposable PostgreSQL only; never uses application credentials or a Supabase URL.
import assert from 'node:assert/strict';
import {randomUUID,createHash}from'node:crypto';
import {readFileSync}from'node:fs';
import {createImportDatabase,scalar}from'./helpers/item-import-fixture.mjs';
const db=await createImportDatabase({resumable:true});
const q=(sql,args=[])=>scalar(db,sql,args);
let passed=0;const check=async(name,fn)=>{await fn();console.log('PASS '+name);passed++;};
const raw=(code,family='MCC',group='Motor')=>({'New code':code,'Item name':code+' product','Item group':group,'Type':'Raw material','Family':family,'Store':'Store A1','Unit':'PCS','Status':'Keep: active','Opening qty':'10','Rejected qty':'2','Rate (Rs)':'12.34567','Value (Rs)':'123.4567','Rejected value (Rs)':'24.69134','Uses in 6 months':'0','Last used':''});
const rows=(n,prefix='B')=>Array.from({length:n},(_,i)=>({row:i+2,raw:raw(prefix+i),issues:[],warnings:[]}));
const source=Buffer.from('local test source'),sha=createHash('sha256').update(source).digest('hex');
const stage=data=>q('select stage_item_import($1,$2,$3,$4,$5::jsonb)',['test.xlsx',sha,source.toString('base64'),'Sheet1',JSON.stringify(data)]);
const start=(batch,selected,size=100,key=randomUUID())=>q('select start_item_import_job($1,1,$2,$3,$4,true)',[batch,selected,key,size]);
const progress=id=>q('select item_import_job_progress($1)',[id]);
const step=(p,attempt=randomUUID())=>q('select process_item_import_chunk($1,$2,$3,$4)',[p.id,p.next.chunk_number,p.next.request_key,attempt]);
const resume=(id,size=100)=>q('select resume_item_import_job($1,$2)',[id,size]);
const finish=async p=>{while(p.next&&p.state==='RUNNING'){p=await step(p);}return p;};
let batch,job,first;
await check('starting a job discovers prior records but writes no products, selections are immutable and idempotent',async()=>{
 const data=rows(205);batch=await stage(data);job=await start(batch,data.map(r=>r.row));assert.equal(job.total,205);assert.equal(job.total_batches,3);assert.equal(job.completed,0);assert.equal(Number(await q('select count(*)from items')),0);
 assert.equal((await start(batch,[2],1)).id,job.id);assert.equal((await progress(job.id)).total,205);assert.equal(job.recovery_before.existing_matching,0);
});
await check('first chunk is atomic and durable; retry returns the same result without additional inserts',async()=>{
 first=job;job=await step(job);assert.equal(job.created,100);assert.equal(job.pending,105);assert.equal(job.completed_batches,1);assert.equal(await q('select state from item_import_batches where id=$1',[batch]),'IMPORTING');const retried=await step(first);assert.equal(retried.created,100);assert.equal(Number(await q('select count(*)from items')),100);
});
await check('injected mid-chunk failure rolls back only that chunk and accurately reports partial completion',async()=>{
 await db.exec(`create function fail_import_test()returns trigger language plpgsql as $$begin if new.item_code='B150'then raise exception 'private SQL/internal failure must not leak';end if;return new;end$$;create trigger fail_import_test before insert on items for each row execute function fail_import_test()`);
 job=await step(job);assert.equal(job.state,'PAUSED');assert.equal(job.created,100);assert.equal(job.failed,100);assert.equal(job.pending,5);assert.equal(Number(await q('select count(*)from items')),100);assert.ok(!job.next.error.includes('private SQL'));assert.equal(await q('select state from item_import_batches where id=$1',[batch]),'PARTIAL');await db.exec('drop trigger fail_import_test on items');
});
await check('explicit resume can reduce batch size; completed chunks are never reprocessed',async()=>{
 job=await resume(job.id,25);job=await finish(job);assert.equal(job.state,'COMPLETED');assert.equal(job.created,205);assert.equal(job.failed,0);assert.equal(job.completed_batches,job.total_batches);assert.equal(Number(await q('select count(*)from items')),205);assert.equal(Number(await q('select attempts from item_import_job_chunks where job_id=$1 and chunk_number=1',[job.id])),1);assert.equal(Number(await q('select count(*)from item_activities')),205);assert.equal(await q('select state from item_import_batches where id=$1',[batch]),'COMMITTED');
});
await check('reimport preserves complete existing product values and reuses stable UUIDs',async()=>{
 const before=await q('select jsonb_agg(to_jsonb(i)order by item_code)from items i');const data=rows(205),b=await stage(data);let p=await start(b,data.map(r=>r.row));assert.equal(p.recovery_before.existing_matching,205);p=await finish(p);assert.equal(p.existing,205);assert.equal(p.created,0);assert.deepEqual(await q('select jsonb_agg(to_jsonb(i)order by item_code)from items i'),before);
});
await check('a lost success response followed by failure reporting cannot mark committed rows failed',async()=>{
 const data=rows(2,'LOST'),b=await stage(data);let p=await start(b,[2,3]);const previous=p,attempt=randomUUID();p=await step(p,attempt);
 p=await q('select record_item_import_chunk_failure($1,$2,$3,$4,$5)',[previous.id,previous.next.chunk_number,previous.next.request_key,attempt,'57014']);assert.equal(p.state,'COMPLETED');assert.equal(p.failed,0);assert.equal(p.created,2);
});
await check('timeout/interruption state is resumable without losing earlier chunks',async()=>{
 const data=rows(6,'TIME'),b=await stage(data);let p=await start(b,data.map(r=>r.row),2);p=await step(p);const old=p,attempt=randomUUID();
 // A timed-out PostgreSQL statement rolls back; a new request records its failure.
 p=await q('select record_item_import_chunk_failure($1,$2,$3,$4,$5)',[p.id,p.next.chunk_number,p.next.request_key,attempt,'57014']);assert.equal(p.created,2);assert.equal(p.failed,2);assert.equal(p.pending,2);assert.match(p.next.error,/time limit/);
 const again=await q('select record_item_import_chunk_failure($1,$2,$3,$4,$5)',[old.id,old.next.chunk_number,old.next.request_key,attempt,'57014']);assert.equal(again.failed,2);assert.equal(Number(await q('select attempts from item_import_job_chunks where job_id=$1 and chunk_number=$2',[old.id,old.next.chunk_number])),1);
 p=await finish(await resume(p.id,1));assert.equal(p.created,6);assert.equal(p.failed,0);
});
await check('a conflicting item appearing after preview blocks its chunk without overwriting it',async()=>{
 const data=rows(3,'CONFLICT'),b=await stage(data);let p=await start(b,[2,3,4],1);p=await step(p);
 const template=await q("select to_jsonb(i)from items i where item_code='CONFLICT0'");const conflictId=await q("insert into items(item_code,item_name,category_id,subcategory_id,item_type_id,unit_id,stock_classification_id,cogs_unit_cost)values('CONFLICT1','Keep existing',$1,$2,$3,$4,$5,999)returning id",[template.category_id,template.subcategory_id,template.item_type_id,template.unit_id,template.stock_classification_id]);
 const before=await q('select to_jsonb(i)from items i where id=$1',[conflictId]);p=await step(p);assert.equal(p.state,'PAUSED');assert.equal(p.failed,1);assert.match(p.next.error,/source row 3/);assert.deepEqual(await q('select to_jsonb(i)from items i where id=$1',[conflictId]),before);
});
await check('cached mappings are revalidated after deactivation, then reused after explicit resolution',async()=>{
 const data=rows(3,'ACTIVE'),b=await stage(data);let p=await start(b,[2,3,4],1);p=await step(p);await db.exec("update stock_classifications set is_active=false where name='Keep: active'");p=await step(p);assert.equal(p.state,'PAUSED');assert.match(p.next.error,/INACTIVE/);await db.exec("update stock_classifications set is_active=true where name='Keep: active'");p=await finish(await resume(p.id,1));assert.equal(p.created,3);
});
await check('stock workflows remain non-posting and are gated until the whole selected job completes',async()=>{
 const data=rows(2,'STOCK'),b=await stage(data);let p=await start(b,[2,3],1);p=await step(p);await assert.rejects(q("select review_item_import_stock($1,'PREVIEW',null,null)",[b]),/Commit product/);p=await finish(p);assert.equal(p.state,'COMPLETED');await q("select review_item_import_stock($1,'PREVIEW',null,null)",[b]);assert.equal(Number(await q('select count(*)from inventory_balances')),0);assert.equal(Number(await q('select count(*)from inventory_transactions')),0);assert.equal(await q('select posting_enabled from item_import_stock_proposals where batch_id=$1',[b]),false);
});
await check('RLS and RPC checks reject unauthorized jobs, resume, cache writes and batch processing',async()=>{
 await db.exec("set role authenticated;select set_config('test.role','USER',false)");assert.equal(Number(await q('select count(*)from item_import_jobs')),0);await assert.rejects(progress(job.id),/Admin/);await assert.rejects(resume(job.id),/Admin/);await assert.rejects(step(first),/Admin/);await assert.rejects(db.exec('update item_import_job_chunks set state=\'COMPLETED\''),/permission denied/);await db.exec("reset role;select set_config('test.role','ADMIN',false)");
});
await check('2,000 products complete in twenty bounded batches with accurate progress',async()=>{
 const data=rows(2000,'CAPACITY'),b=await stage(data);let p=await start(b,data.map(r=>r.row));p=await finish(p);assert.equal(p.state,'COMPLETED');assert.equal(p.created,2000);assert.equal(p.completed_batches,20);assert.equal(p.percent,100);assert.equal(p.failed,0);assert.equal(p.pending,0);
});
if(process.env.ITEM_IMPORT_WORKBOOK)await check('all 1,994 actual products import in bounded chunks, then reimport without duplicates or stock changes',async()=>{
 const {readWorkbook,decimal}=await import('../lib/inventory/import/workbook.ts');
 const bytes=readFileSync(process.env.ITEM_IMPORT_WORKBOOK),source=await readWorkbook(bytes),full=await createImportDatabase({resumable:true});
 const f=(sql,args=[])=>scalar(full,sql,args);
 const b=await f('select stage_item_import($1,$2,$3,$4,$5::jsonb)',['Item master v5.xlsx',source.sha256,bytes.toString('base64'),source.sheet,JSON.stringify(source.rows)]);
 const started=performance.now();let p=await f('select start_item_import_job($1,1,$2,$3,100,true)',[b,source.rows.map(r=>r.row),randomUUID()]);const startMs=performance.now()-started,times=[];
 while(p.state==='RUNNING'&&p.next){const t=performance.now();p=await f('select process_item_import_chunk($1,$2,$3,$4)',[p.id,p.next.chunk_number,p.next.request_key,randomUUID()]);times.push(performance.now()-t);if(p.state==='PAUSED')throw new Error(p.next.error);}
 assert.equal(p.created,1994);assert.equal(p.completed_batches,20);assert.equal(p.completed,1994);assert.equal(p.failed,0);
 assert.equal(Number(await f('select count(distinct lower(trim(item_code)))from items')),1994);assert.equal(Number(await f('select count(*)from item_categories')),14);assert.equal(Number(await f('select count(*)from item_subcategories')),864);assert.equal(Number(await f('select count(*)from item_types')),5);assert.equal(Number(await f('select count(*)from units_of_measurement')),4);assert.equal(Number(await f('select count(*)from stock_locations')),3);assert.equal(Number(await f('select count(*)from stock_classifications')),6);assert.equal(Number(await f('select count(*)from items where subcategory_id is null')),2);
 const costs=new Map((await full.query('select item_code,cogs_unit_cost::text from items')).rows.map(r=>[r.item_code,r.cogs_unit_cost]));for(const r of source.rows)assert.equal(costs.get(r.raw['New code']),decimal(r.raw['Rate (Rs)'],4).fixed);
 const before=await f('select jsonb_agg(to_jsonb(i)order by item_code)from items i');
 const again=await f('select stage_item_import($1,$2,$3,$4,$5::jsonb)',['Item master v5.xlsx',source.sha256,bytes.toString('base64'),source.sheet,JSON.stringify(source.rows)]);
 let repeat=await f('select start_item_import_job($1,1,$2,$3,100,true)',[again,source.rows.map(r=>r.row),randomUUID()]);assert.equal(repeat.recovery_before.existing_matching,1994);
 while(repeat.state==='RUNNING'&&repeat.next){repeat=await f('select process_item_import_chunk($1,$2,$3,$4)',[repeat.id,repeat.next.chunk_number,repeat.next.request_key,randomUUID()]);if(repeat.state==='PAUSED')throw new Error(repeat.next.error);}
 assert.equal(repeat.created,0);assert.equal(repeat.existing,1994);assert.deepEqual(await f('select jsonb_agg(to_jsonb(i)order by item_code)from items i'),before);
 assert.equal(Number(await f('select count(*)from inventory_balances')),0);assert.equal(Number(await f('select count(*)from inventory_transactions')),0);
 assert.equal(Number(await f("select count(*)from item_master_admin_activities where batch_id=$1 and event_type='IMPORT_CHUNK_COMMITTED'",[b])),20);
 console.log(JSON.stringify({start_ms:Math.round(startMs),chunk_count:times.length,max_chunk_ms:Math.round(Math.max(...times)),mean_chunk_ms:Math.round(times.reduce((a,b)=>a+b,0)/times.length),total_commit_ms:Math.round(times.reduce((a,b)=>a+b,0))}));await full.close();
});
console.log(`${passed} resumable import checks passed`);await db.close();
