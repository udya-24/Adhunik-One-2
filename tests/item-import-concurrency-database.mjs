// Optional native PostgreSQL acceptance. Strictly localhost; creates/drops only its generated test DB.
import assert from 'node:assert/strict';
import {randomUUID,createHash}from'node:crypto';
import {readFileSync}from'node:fs';
import {prepareImportSchema}from'./helpers/item-import-fixture.mjs';
const url=new URL(process.env.ITEM_IMPORT_LOCAL_POSTGRES || 'postgresql://item_import_test@127.0.0.1:55493/postgres');
if(!['127.0.0.1','localhost','[::1]'].includes(url.hostname))throw new Error('Only a disposable localhost PostgreSQL server is allowed');
const {default:pg}=await import('../node_modules/.cache/pg-concurrency/node_modules/pg/lib/index.js');
const admin=new pg.Client({connectionString:url.href});await admin.connect();
const name='item_import_test_'+randomUUID().replaceAll('-','');
const clients=[];let passed=0;
const check=async(n,fn)=>{await fn();console.log('PASS '+n);passed++;};
try{
 await admin.query(`create database "${name}"`);url.pathname='/'+name;
 const connect=async()=>{const c=new pg.Client({connectionString:url.href});await c.connect();clients.push(c);return c;};
 const a=await connect(),b=await connect();
 await admin.query(`do $$begin if not exists(select 1 from pg_roles where rolname='anon')then create role anon;end if;if not exists(select 1 from pg_roles where rolname='authenticated')then create role authenticated;end if;end$$`);
 // Roles are cluster-scoped; they already exist on this private test cluster.
 const adapter={exec:sql=>a.query(sql.replace('create role anon; create role authenticated;','')),query:(sql,args)=>a.query(sql,args)};
 await prepareImportSchema(adapter,{resumable:true});
 for(const c of [a,b])await c.query("select set_config('test.uid','00000000-0000-0000-0000-000000000001',false),set_config('test.role','ADMIN',false);set statement_timeout='8s'");
 const q=async(c,sql,args=[])=>Object.values((await c.query(sql,args)).rows[0])[0];
 const raw=code=>({'New code':code,'Item name':code+' product','Item group':'Motor','Type':'Raw material','Family':'MCC','Store':'Store A1','Unit':'PCS','Status':'Keep: active','Opening qty':'10','Rejected qty':'0','Rate (Rs)':'1','Value (Rs)':'10','Rejected value (Rs)':'0','Uses in 6 months':'0','Last used':''});
 const make=async(prefix,count=4,size=2)=>{const rows=Array.from({length:count},(_,i)=>({row:i+2,raw:raw(prefix+i),issues:[],warnings:[]})),src=Buffer.from(prefix),sha=createHash('sha256').update(src).digest('hex');const id=await q(a,'select stage_item_import($1,$2,$3,$4,$5::jsonb)',['test.xlsx',sha,src.toString('base64'),'Sheet1',JSON.stringify(rows)]);return q(a,'select start_item_import_job($1,1,$2,$3,$4,true)',[id,rows.map(r=>r.row),randomUUID(),size]);};
 const step=(c,p,attempt=randomUUID())=>q(c,'select process_item_import_chunk($1,$2,$3,$4)',[p.id,p.next.chunk_number,p.next.request_key,attempt]);
 const resume=p=>q(a,'select resume_item_import_job($1,1)',[p.id]);
 await check('two concurrent confirmations of the same chunk serialize without duplicates',async()=>{
  const p=await make('CONCURRENT',2);
  await a.query(`create function slow_same_chunk()returns trigger language plpgsql as $$begin if new.item_code like 'CONCURRENT%'then perform pg_sleep(0.15);end if;return new;end$$;create trigger slow_same_chunk before insert on items for each row execute function slow_same_chunk()`);
  const running=step(a,p);await new Promise(r=>setTimeout(r,40));await assert.rejects(step(b,p),e=>e.code==='55P03');const done=await running;assert.equal(done.created,2);assert.equal((await step(b,p)).created,2);assert.equal(Number(await q(a,"select count(*)from items where item_code like 'CONCURRENT%'")),2);await a.query('drop trigger slow_same_chunk on items');
 });
 await check('overlapping jobs cannot duplicate items and explicitly resume with existing-code reuse',async()=>{
  const one=await make('OVERLAP',2),two=await make('OVERLAP',2);
  await a.query(`create function slow_overlap()returns trigger language plpgsql as $$begin if new.item_code like 'OVERLAP%'then perform pg_sleep(0.15);end if;return new;end$$;create trigger slow_overlap before insert on items for each row execute function slow_overlap()`);
  const running=step(a,one);await new Promise(r=>setTimeout(r,40));const paused=await step(b,two);assert.equal(paused.state,'PAUSED');assert.equal(paused.next.error_code,'55P03');await running;const done=await step(b,await resume(two));assert.equal(done.created,0);assert.equal(done.existing,1);let p=done;while(p.next)p=await step(b,p);assert.equal(p.existing,2);assert.equal(Number(await q(a,"select count(*)from items where item_code like 'OVERLAP%'")),2);await a.query('drop trigger slow_overlap on items');
 });
 await check('real statement timeout rolls back an interrupted chunk, preserves earlier chunks, and resumes at a smaller size',async()=>{
  let p=await make('TIMEOUT');p=await step(a,p);assert.equal(p.created,2);
  await a.query(`create function slow_timeout()returns trigger language plpgsql as $$begin if new.item_code='TIMEOUT3'then perform pg_sleep(0.3);end if;return new;end$$;create trigger slow_timeout before insert on items for each row execute function slow_timeout();set statement_timeout='75ms'`);
  const previous=p,attempt=randomUUID();await assert.rejects(step(a,p,attempt),e=>e.code==='57014');
  assert.equal(Number(await q(b,"select count(*)from items where item_code like 'TIMEOUT%'")),2);assert.equal(Number(await q(b,'select count(*)from item_import_links where batch_id=$1',[p.batch_id])),2);
  p=await q(b,'select record_item_import_chunk_failure($1,$2,$3,$4,$5)',[p.id,p.next.chunk_number,p.next.request_key,attempt,'57014']);assert.equal(p.failed,2);assert.equal(p.created,2);
  await a.query("set statement_timeout='8s';drop trigger slow_timeout on items");p=await resume(p);while(p.next)p=await step(a,p);assert.equal(p.created,4);assert.equal(p.failed,0);assert.equal(Number(await q(a,'select attempts from item_import_job_chunks where job_id=$1 and chunk_number=1',[previous.id])),1);assert.equal(Number(await q(a,"select count(*)from item_activities ac join items i on i.id=ac.item_id where i.item_code like 'TIMEOUT%'")),4);
 });
 await check('ordinary concurrent table writers cause a bounded retryable lock failure',async()=>{
  const p=await make('LOCKED',2);await b.query('begin;lock table items in access exclusive mode');let failed;
  try{failed=await step(a,p);assert.equal(failed.next.error_code,'55P03');}finally{await b.query('rollback');}
  let result=await resume(failed);while(result.next)result=await step(a,result);assert.equal(result.created,2);
 });
 if(process.env.ITEM_IMPORT_WORKBOOK)await check('native PostgreSQL processes all 1,994 rows under an 8-second per-statement budget',async()=>{
  const {readWorkbook}=await import('../lib/inventory/import/workbook.ts');const bytes=readFileSync(process.env.ITEM_IMPORT_WORKBOOK),source=await readWorkbook(bytes);
  const id=await q(a,'select stage_item_import($1,$2,$3,$4,$5::jsonb)',['Item master v5.xlsx',source.sha256,bytes.toString('base64'),source.sheet,JSON.stringify(source.rows)]);
  const t=performance.now();let p=await q(a,'select start_item_import_job($1,1,$2,$3,100,true)',[id,source.rows.map(r=>r.row),randomUUID()]);const startMs=performance.now()-t,times=[];
  while(p.state==='RUNNING'&&p.next){const ts=performance.now();p=await step(a,p);times.push(performance.now()-ts);if(p.state==='PAUSED')throw new Error(p.next.error);}
  assert.equal(p.created,1994);assert.equal(p.completed_batches,20);assert.equal(p.failed,0);assert.equal(Number(await q(a,'select count(*)from item_import_links where batch_id=$1',[id])),1994);assert.equal(Number(await q(a,'select count(*)from inventory_balances')),0);assert.equal(Number(await q(a,'select count(*)from inventory_transactions')),0);
  console.log(JSON.stringify({native_start_ms:Math.round(startMs),native_max_chunk_ms:Math.round(Math.max(...times)),native_mean_chunk_ms:Math.round(times.reduce((a,b)=>a+b,0)/times.length),native_total_ms:Math.round(times.reduce((a,b)=>a+b,0))}));
 });
 console.log(`${passed} native concurrency/timeout checks passed`);
}finally{
 for(const c of clients)await c.end();
 // Only the random database created above is eligible for cleanup.
 await admin.query(`drop database if exists "${name}"`);await admin.end();
}
