// Native PostgreSQL, independent connections, disposable localhost cluster only.
import assert from'node:assert/strict';
import{randomUUID}from'node:crypto';
import{readFileSync}from'node:fs';
import{prepareImportSchema,scalar}from'./helpers/item-import-fixture.mjs';
import{stockRow,seedStockItems,stageStock,stockRows,approveStock,stockStep,finishStock}from'./helpers/opening-stock-fixture.mjs';
const url=new URL(process.env.ITEM_IMPORT_LOCAL_POSTGRES||'postgresql://item_import_test@127.0.0.1:55493/postgres');if(!['127.0.0.1','localhost','[::1]'].includes(url.hostname))throw new Error('Disposable localhost PostgreSQL only');
const{default:pg}=await import('../node_modules/.cache/pg-concurrency/node_modules/pg/lib/index.js'),admin=new pg.Client({connectionString:url.href});await admin.connect();
const name='opening_stock_test_'+randomUUID().replaceAll('-',''),clients=[];let passed=0;const check=async(n,fn)=>{await fn();passed++;console.log('PASS '+n);};
try{
 await admin.query(`create database "${name}"`);url.pathname='/'+name;
 const connect=async()=>{const c=new pg.Client({connectionString:url.href});await c.connect();clients.push(c);return c;},a=await connect(),b=await connect();
 await admin.query(`do $$begin if not exists(select 1 from pg_roles where rolname='anon')then create role anon;end if;if not exists(select 1 from pg_roles where rolname='authenticated')then create role authenticated;end if;end$$`);
 const db={exec:s=>a.query(s.replace('create role anon; create role authenticated;','')),query:(s,p)=>a.query(s,p)},other={exec:s=>b.query(s),query:(s,p)=>b.query(s,p)},q=(sql,args=[])=>scalar(db,sql,args);
 await prepareImportSchema(db,{resumable:true});await db.exec(readFileSync(new URL('../supabase/migrations/202611120003_bulk_opening_stock_import.sql',import.meta.url),'utf8'));
 for(const c of[a,b])await c.query("select set_config('test.uid','00000000-0000-0000-0000-000000000001',false),set_config('test.role','ADMIN',false);set statement_timeout='8s'");
 await check('concurrent requests for the same opening batch post exactly once',async()=>{
  const data=[stockRow(2,'SAME-OPEN','5')];await seedStockItems(db,data);const job=await stageStock(db,data),p=await approveStock(db,job);
  await db.exec(`create function slow_open_same()returns trigger language plpgsql as $$begin if new.reference_type='OPENING_STOCK_EXCEL'then perform pg_sleep(0.15);end if;return new;end$$;create trigger slow_open_same before insert on inventory_transactions for each row execute function slow_open_same()`);
  const running=stockStep(db,p);await new Promise(r=>setTimeout(r,40));await assert.rejects(stockStep(other,p),e=>e.code==='55P03');await running;assert.equal((await stockStep(other,p)).posted,1);assert.equal(Number(await q("select count(*)from inventory_transactions where reference_number=$1",[job])),1);await db.exec('drop trigger slow_open_same on inventory_transactions');
 });
 await check('overlapping workbook approvals cannot double-post the same item',async()=>{
  const data=[stockRow(2,'OVERLAP-OPEN','5')];await seedStockItems(db,data);const j1=await stageStock(db,data),j2=await stageStock(db,data),p1=await approveStock(db,j1),p2=await approveStock(db,j2);
  await db.exec(`create function slow_open_overlap()returns trigger language plpgsql as $$begin if new.reference_type='OPENING_STOCK_EXCEL'then perform pg_sleep(0.15);end if;return new;end$$;create trigger slow_open_overlap before insert on inventory_transactions for each row execute function slow_open_overlap()`);
  const running=stockStep(db,p1);await new Promise(r=>setTimeout(r,40));const paused=await stockStep(other,p2);assert.equal(paused.state,'PAUSED');assert.equal(paused.next.code,'55P03');await running;await q('select refresh_opening_stock_preview($1)',[j2]);assert.equal((await stockRows(db,j2))[0].snapshot.validation,'EXISTING');await assert.rejects(approveStock(db,j2),/No valid positive/);assert.equal(Number(await q("select count(*)from inventory_transactions t join items i on i.id=t.item_id where item_code='OVERLAP-OPEN'")),1);await db.exec('drop trigger slow_open_overlap on inventory_transactions');
 });
 await check('real statement timeout preserves earlier posted batches and allows fresh approval of only pending rows',async()=>{
  const data=Array.from({length:4},(_,n)=>stockRow(n+2,'TIME-OPEN'+n,'3'));await seedStockItems(db,data);const job=await stageStock(db,data);let p=await approveStock(db,job,2);p=await stockStep(db,p);assert.equal(p.posted,2);
  await db.exec(`create function slow_open_timeout()returns trigger language plpgsql as $$begin if new.item_id=(select id from public.items where item_code in('TIME-OPEN2','TIME-OPEN3')order by id desc limit 1)then perform pg_sleep(0.3);end if;return new;end$$;create trigger slow_open_timeout before insert on inventory_transactions for each row execute function slow_open_timeout();set statement_timeout='75ms'`);
  const before=p,attempt=randomUUID();await assert.rejects(stockStep(db,p,attempt),e=>e.code==='57014');assert.equal(Number(await scalar(other,"select count(*)from inventory_transactions where reference_number=$1",[job])),2);
  p=await scalar(other,'select record_opening_stock_interruption($1,$2,$3,$4,$5)',[job,before.next.id,before.next.request_key,attempt,'57014']);assert.equal(p.state,'PAUSED');assert.equal(p.posted,2);await db.exec("set statement_timeout='8s';drop trigger slow_open_timeout on inventory_transactions");
  await q('select refresh_opening_stock_preview($1)',[job]);p=await finishStock(db,await approveStock(db,job,1));assert.equal(p.posted,4);assert.equal(Number(await q("select count(*)from inventory_transactions where reference_number=$1",[job])),4);
 });
 await check('concurrent ordinary stock posting invalidates an approval rather than adding to live stock',async()=>{
  const data=[stockRow(2,'MANUAL-OPEN','5')];await seedStockItems(db,data);const job=await stageStock(db,data),p=await approveStock(db,job),row=(await stockRows(db,job))[0];
  await b.query('begin');await scalar(other,"select post_inventory_movement('STOCK_IN',$1,$2,2,current_date,'MATERIAL_RECEIPT',null,'TEST','Test receipt',null)",[row.item_id,row.location_id]);
  try{const paused=await stockStep(db,p);assert.equal(paused.state,'PAUSED');assert.equal(paused.next.code,'55P03');}finally{await b.query('commit');}
  await q('select refresh_opening_stock_preview($1)',[job]);assert.equal((await stockRows(db,job))[0].snapshot.validation,'EXISTING');assert.equal(Number(await q('select on_hand_quantity from inventory_balances where item_id=$1',[row.item_id])),2);
 });
 await check('approval protects against first-balance creation and ABA inventory changes',async()=>{
  const data=[stockRow(2,'ABA-OPEN','5')];await seedStockItems(db,data);const job=await stageStock(db,data),p=await approveStock(db,job),r=(await stockRows(db,job))[0];
  await scalar(other,"select post_inventory_movement('STOCK_IN',$1,$2,1,current_date,null,null,null,'Test',null)",[r.item_id,r.location_id]);await scalar(other,"select post_inventory_movement('STOCK_OUT',$1,$2,1,current_date,null,null,null,'Test',null)",[r.item_id,r.location_id]);const paused=await stockStep(db,p);assert.equal(paused.state,'PAUSED');assert.match(paused.next.error,/changed/);assert.equal(Number(await q('select on_hand_quantity from inventory_balances where item_id=$1',[r.item_id])),0);
 });
 if(process.env.ITEM_IMPORT_WORKBOOK)await check('actual workbook posts usable quantities in bounded native batches without duplicate openings',async()=>{
  const{readWorkbook}=await import('../lib/inventory/import/workbook.ts');const source=await readWorkbook(readFileSync(process.env.ITEM_IMPORT_WORKBOOK),'Sheet1');const book=await seedStockItems(db,source.rows),job=await q('select create_opening_stock_preview($1)',[book]);let p=await approveStock(db,job),times=[];
  while(p.state==='RUNNING'&&p.next){const t=performance.now();p=await stockStep(db,p);times.push(performance.now()-t);if(p.state==='PAUSED')throw new Error(p.next.error);}
  assert.equal(p.posted,1725);assert.equal(p.skipped,269);assert.equal(p.rejected_rows,55);assert.equal(p.state,'COMPLETED');assert.equal(Number(await q("select count(*)from inventory_transactions where reference_number=$1 and transaction_type<>'OPENING_STOCK'",[job])),0);assert.equal(Number(await q('select sum(damaged_quantity)from inventory_balances')),0);
  console.log(JSON.stringify({native_posted:p.posted,batches:times.length,max_batch_ms:Math.round(Math.max(...times)),mean_batch_ms:Math.round(times.reduce((x,y)=>x+y,0)/times.length)}));
 });
 console.log(`${passed} native opening-stock concurrency checks passed`);
}finally{for(const c of clients)await c.end();await admin.query(`drop database if exists "${name}"`);await admin.end();}
