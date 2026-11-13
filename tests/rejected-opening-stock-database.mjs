// Disposable in-process PostgreSQL only. No environment credentials or network.
import assert from 'node:assert/strict';
import {readFileSync} from 'node:fs';
import {randomUUID} from 'node:crypto';
import {createStockDatabase,stockRow,seedStockItems,stageStock,stockRows,approveStock,stockStep,finishStock,editStock} from './helpers/opening-stock-fixture.mjs';
import {scalar} from './helpers/item-import-fixture.mjs';
const db=await createStockDatabase(),q=(sql,args=[])=>scalar(db,sql,args);
const legacyRows=[stockRow(2,'LEGACY','7',{'Rejected qty':'3'})];
const legacySource=await seedStockItems(db,legacyRows),legacy=await q('select create_opening_stock_preview($1)',[legacySource]);
const legacyApproval=await approveStock(db,legacy);
let passed=0;
const check=async(name,fn)=>{await fn();passed++;console.log('PASS '+name);};
try {
 await check('incremental migrations preserve committed source, items and audit',async()=>{
  const before=await q('select jsonb_build_object(\'items\',(select jsonb_agg(to_jsonb(i)order by id)from items i),\'batch\',(select to_jsonb(b)from item_import_batches b where id=$1),\'audit\',(select jsonb_agg(to_jsonb(a)order by id)from item_master_admin_activities a))',[legacySource]);
  for(const file of ['202611130001_import_read_performance.sql','202611130002_rejected_opening_stock.sql'])await db.exec(readFileSync(new URL('../supabase/migrations/'+file,import.meta.url),'utf8'));
  const after=await q('select jsonb_build_object(\'items\',(select jsonb_agg(to_jsonb(i)order by id)from items i),\'batch\',(select to_jsonb(b)-\'source_row_count\'from item_import_batches b where id=$1),\'audit\',(select jsonb_agg(to_jsonb(a)order by id)from item_master_admin_activities a))',[legacySource]);
  assert.deepEqual(after,before);assert.equal(await q('select source_row_count from item_import_batches where id=$1',[legacySource]),1);
 });
 await check('existing exclusion approvals retain their accounting policy',async()=>{
  const done=await finishStock(db,legacyApproval);assert.equal(done.posted,1);
  assert.equal(Number(await q("select rejected_quantity from inventory_balances b join items i on i.id=b.item_id where item_code='LEGACY'")),0);
 });
 let job,source;
 await check('usable and rejected quantities post separately and exact precision is retained',async()=>{
  const data=[stockRow(2,'NEW-REJECT','10.123456',{'Rejected qty':'2.000001'}),stockRow(3,'REJECT-ONLY','0',{'Rejected qty':'4'}),stockRow(4,'NO-STOCK','0')];
  source=await seedStockItems(db,data);job=await q('select create_opening_stock_preview($1)',[source]);
  let rows=await stockRows(db,job);assert.equal(rows[1].snapshot.validation,'VALID');assert.equal(rows[2].snapshot.validation,'ZERO');
  const p=await approveStock(db,job,1),done=await finishStock(db,p);assert.equal(done.posted,2,JSON.stringify(done));assert.equal(done.matched,3);assert.equal(done.ready,0);
  const b=await q("select to_jsonb(b)from inventory_balances b join items i on i.id=b.item_id where item_code='NEW-REJECT'");assert.equal(Number(b.on_hand_quantity),10.123456);assert.equal(Number(b.rejected_quantity),2.000001);assert.equal(Number(b.damaged_quantity),0);
  const r=await q("select to_jsonb(b)from inventory_balances b join items i on i.id=b.item_id where item_code='REJECT-ONLY'");assert.equal(Number(r.on_hand_quantity),0);assert.equal(Number(r.rejected_quantity),4);
  assert.equal(Number(await q("select count(*)from inventory_transactions where reference_number=$1",[job])),3);
  assert.equal((await stockStep(db,p)).posted,2);assert.equal(Number(await q("select count(*)from inventory_transactions where reference_number=$1",[job])),3);
  const counts=await q('select inventory_overview_counts()');assert.equal(counts.rejectedItems,2);assert.equal(counts.damagedItems,0);
  const item=rows[0].item_id,location=rows[0].location_id;
  await q("select post_inventory_movement('RESERVE',$1,$2,1,current_date,null,null,null,'Reserve test',null)",[item,location]);
  assert.equal(Number(await q('select on_hand_quantity-reserved_quantity from inventory_balances where item_id=$1',[item])),9.123456);
  await assert.rejects(q("select post_inventory_movement('STOCK_OUT',$1,$2,10,current_date,null,null,null,'Cannot sell rejected',null)",[item,location]),/Available/);
  await assert.rejects(q('update stock_locations set is_active=false where id=$1',[location]),/stock|Location/);
 });
 await check('new uploads cannot duplicate rejected or usable stock and existing inventory is preserved',async()=>{
  const before=await q('select jsonb_agg(to_jsonb(b)order by item_id,location_id)from inventory_balances b');
  const repeat=await q('select create_opening_stock_preview($1)',[source]),p=await q('select opening_stock_progress($1)',[repeat]);assert.equal(p.existing,2);const reviewed=(await stockRows(db,repeat)).find(r=>r.raw['New code']==='NEW-REJECT');assert.equal(Number(reviewed.snapshot.resulting_available),9.123456);
  await assert.rejects(approveStock(db,repeat),/No valid positive/);
  assert.deepEqual(await q('select jsonb_agg(to_jsonb(b)order by item_id,location_id)from inventory_balances b'),before);
 });
 await check('missing rejected quantity blocks posting until explicit manual entry and rejects excess precision',async()=>{
  const data=[stockRow(2,'MANUAL-REJECT','5',{'Rejected qty':''})];await seedStockItems(db,[stockRow(2,'MANUAL-REJECT','5')]);const id=await stageStock(db,data);
  let r=(await stockRows(db,id))[0];assert.equal(r.snapshot.validation,'INVALID');
  await editStock(db,id,[{row:2,quantity:'5',rejected:'1.0000001',selected:true,location:null}]);r=(await stockRows(db,id))[0];assert.equal(r.snapshot.validation,'INVALID');
  await editStock(db,id,[{row:2,quantity:'5',rejected:'1.25',selected:true,location:null}]);assert.equal((await stockRows(db,id))[0].snapshot.validation,'VALID');assert.equal((await finishStock(db,await approveStock(db,id))).posted,1);
  assert.equal(Number(await q("select rejected_quantity from inventory_balances b join items i on i.id=b.item_id where item_code='MANUAL-REJECT'")),1.25);
 });
 await check('failure between usable and rejected posting rolls back the complete chunk; resume is idempotent',async()=>{
  const data=[stockRow(2,'ATOMIC-REJECT','6',{'Rejected qty':'2'}),stockRow(3,'ATOMIC-NEXT','7',{'Rejected qty':'3'})];await seedStockItems(db,data);const id=await stageStock(db,data);let p=await approveStock(db,id,1);p=await stockStep(db,p);assert.equal(p.posted,1);
  await db.exec("create function reject_test_failure()returns trigger language plpgsql as $$begin if new.transaction_type='REJECTED_OPENING' then raise exception 'private sql';end if;return new;end$$;create trigger reject_test_failure before insert on inventory_transactions for each row execute function reject_test_failure()");
  p=await stockStep(db,p);assert.equal(p.state,'PAUSED');assert.equal(p.posted,1);assert.equal(Number(await q("select count(*)from inventory_transactions t join items i on i.id=t.item_id where item_code='ATOMIC-NEXT'")),0);
  await db.exec('drop trigger reject_test_failure on inventory_transactions');await q('select refresh_opening_stock_preview($1)',[id]);p=await finishStock(db,await approveStock(db,id,1));assert.equal(p.posted,2);assert.equal(Number(await q('select count(*)from inventory_transactions where reference_number=$1',[id])),4);
 });
 await check('rejected ledger is immutable and inaccessible to direct application writes',async()=>{
  await assert.rejects(db.exec("update inventory_transactions set rejected_delta=0 where transaction_type='REJECTED_OPENING'"),/immutable/);
  await db.exec("set role authenticated;select set_config('test.role','USER',false)");
  await assert.rejects(q('select post_rejected_opening($1,current_date,$2)',[randomUUID(),'Unauthorized']),/permission denied/);
  await assert.rejects(db.exec('update inventory_balances set rejected_quantity=0'),/permission denied/);
  await db.exec("reset role;select set_config('test.role','ADMIN',false)");
 });
 await check('optimized stock snapshot is identical to legacy result and expands source once',async()=>{
  let sql=readFileSync(new URL('../supabase/migrations/202611120001_item_master_excel_import.sql',import.meta.url),'utf8');sql=sql.slice(sql.indexOf('create function public.item_import_stock_snapshot('),sql.indexOf('create function public.item_import_stock_review_current(')).replace('item_import_stock_snapshot','legacy_stock_snapshot');await db.exec(sql);
  assert.deepEqual(await q('select item_import_stock_snapshot($1)',[source]),await q('select legacy_stock_snapshot($1)',[source]));
 });
 await check('2,000 rows reconcile separate rejected totals in bounded resumable transactions',async()=>{
  const data=Array.from({length:2000},(_,i)=>stockRow(i+2,'REJECT-CAP-'+i,'1.000001',{'Rejected qty':'0.000002'}));
  const source=await seedStockItems(db,data),id=await q('select create_opening_stock_preview($1)',[source]);let p=await approveStock(db,id,100),max=0;
  while(p.state==='RUNNING'&&p.next){const t=performance.now();p=await stockStep(db,p);max=Math.max(max,performance.now()-t);if(p.state==='PAUSED')throw new Error(p.next.error);}
  assert.equal(p.posted,2000);assert.equal(p.posted_batches,20);const totals=Object.values(p.quantities_by_unit)[0];assert.equal(totals.posted,'2000.002000');assert.equal(totals.rejected_posted,'0.004000');assert.equal(Number(await q('select count(*)from inventory_transactions where reference_number=$1',[id])),4000);
  const t=performance.now();assert.equal((await q('select item_import_stock_snapshot($1)',[source])).length,2000);const optimizedMs=performance.now()-t,legacyStart=performance.now();assert.equal((await q('select legacy_stock_snapshot($1)',[source])).length,2000);console.log(JSON.stringify({rows:2000,max_chunk_ms:Math.round(max),optimized_snapshot_ms:Math.round(optimizedMs),legacy_snapshot_ms:Math.round(performance.now()-legacyStart)}));
 });
 if(process.env.ITEM_IMPORT_WORKBOOK)await check('original 1,994-row workbook preserves existing stock and posts rejected-only rows separately',async()=>{
  const {readWorkbook,decimal}=await import('../lib/inventory/import/workbook.ts');
  const full=await createStockDatabase(),f=(sql,args=[])=>scalar(full,sql,args);
  try{
   for(const file of ['202611130001_import_read_performance.sql','202611130002_rejected_opening_stock.sql'])await full.exec(readFileSync(new URL('../supabase/migrations/'+file,import.meta.url),'utf8'));
   const book=await readWorkbook(readFileSync(process.env.ITEM_IMPORT_WORKBOOK),'Sheet1'),source=await seedStockItems(full,book.rows);
   const before=await f('select jsonb_agg(to_jsonb(i)order by id)from items i');
   const existing=book.rows.find(r=>decimal(r.raw['Opening qty'],6).scaled>0n&&decimal(r.raw['Rejected qty'],6).scaled===0n);
   const item=await f('select id from items where item_code=$1',[existing.raw['New code']]),location=await f('select id from stock_locations where name=$1',[existing.raw.Store]);
   await f("select post_inventory_movement('STOCK_IN',$1,$2,11,current_date,null,null,null,'Preserve existing stock',null)",[item,location]);
   const job=await f('select create_opening_stock_preview($1)',[source]);let p=await approveStock(full,job),times=[];
   while(p.state==='RUNNING'&&p.next){const t=performance.now();p=await stockStep(full,p);times.push(performance.now()-t);if(p.state==='PAUSED')throw new Error(p.next.error);}
   assert.equal(p.posted,1769);assert.equal(p.skipped,225);assert.equal(p.rejected_rows,55);assert.equal(p.invalid,0);
   assert.equal(Number(await f('select on_hand_quantity from inventory_balances where item_id=$1',[item])),11);
   assert.equal(Number(await f("select count(*)from inventory_transactions where reference_number=$1 and transaction_type='REJECTED_OPENING'",[job])),55);
   assert.equal(Number(await f('select sum(damaged_quantity)from inventory_balances')),0);
   assert.deepEqual(await f('select jsonb_agg(to_jsonb(i)order by id)from items i'),before);
   const expected=new Map();for(const r of book.rows){if(r.raw['New code']===existing.raw['New code'])continue;const t=expected.get(r.raw.Unit)||{usable:0n,rejected:0n};t.usable+=decimal(r.raw['Opening qty'],6).scaled;t.rejected+=decimal(r.raw['Rejected qty'],6).scaled;expected.set(r.raw.Unit,t);}
   const totals=(await full.query("select u.name,sum(t.on_hand_delta)::text usable,sum(t.rejected_delta)::text rejected from inventory_transactions t join items i on i.id=t.item_id join units_of_measurement u on u.id=i.unit_id where reference_number=$1 group by u.name",[job])).rows;
   for(const t of totals){assert.equal(decimal(t.usable,6).scaled,expected.get(t.name).usable);assert.equal(decimal(t.rejected,6).scaled,expected.get(t.name).rejected);}
   const again=await f('select create_opening_stock_preview($1)',[source]);await assert.rejects(approveStock(full,again),/No valid positive/);
   console.log(JSON.stringify({workbook_rows:book.rows.length,posted:p.posted,skipped:p.skipped,rejected_ledger_rows:55,batches:times.length,max_batch_ms:Math.round(Math.max(...times)),totals_by_unit:totals}));
  }finally{await full.close();}
 });
 console.log(`${passed} rejected opening stock database checks passed`);
} finally {await db.close();}
