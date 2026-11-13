// Local disposable PostgreSQL only. No production configuration is read.
import assert from'node:assert/strict';
import{readFileSync}from'node:fs';
import{randomUUID,createHash}from'node:crypto';
import{createStockDatabase,stockRow,seedStockItems,approveStock,finishStock}from'./helpers/opening-stock-fixture.mjs';
import{scalar}from'./helpers/item-import-fixture.mjs';
const db=await createStockDatabase(),q=(s,a=[])=>scalar(db,s,a);let passed=0;
const check=async(n,f)=>{await f();passed++;console.log('PASS '+n);};
const approve=(id,rows,revision)=>q('select approve_item_price_import($1,$2,$3,$4,$5)',[id,revision,rows,randomUUID(),'Reviewed current purchase costs']);
const step=p=>q('select process_item_price_chunk($1,$2,$3)',[p.id,p.next.id,p.next.key]);
const finish=async p=>{while(p.state==='RUNNING'&&p.next){p=await step(p);if(p.state==='PAUSED')throw new Error(p.next.error);}return p;};
const stage=async data=>{const bytes=Buffer.from('prices-'+randomUUID());return q('select stage_item_price_import($1,$2,$3,$4,$5::jsonb)',['prices.xlsx',createHash('sha256').update(bytes).digest('hex'),'Sheet1',bytes.toString('base64'),JSON.stringify(data)]);};
try{
 for(const file of['202611130001_import_read_performance.sql','202611130002_rejected_opening_stock.sql','202611130003_item_import_preview_and_recovery.sql'])await db.exec(readFileSync(new URL('../supabase/migrations/'+file,import.meta.url),'utf8'));
 await db.exec("create function public.has_erp_permission(s text,a text)returns boolean language sql stable as $$select public.has_active_erp_access() and current_setting('test.edit',true)is distinct from 'false'$$;grant execute on function public.has_erp_permission(text,text)to authenticated");
 const finance=readFileSync(new URL('../supabase/migrations/202609070031_phase_11a_gp_cogs.sql',import.meta.url),'utf8');await db.exec(finance.slice(finance.indexOf('create function public.guard_item_cogs()'),finance.indexOf('-- Configuration uses')));
 const data=[stockRow(2,'VALUE','10.000001',{'Rate (Rs)':'2.1234','Value (Rs)':'21.2340021234','Rejected qty':'3.000002','Rejected value (Rs)':'6.3702042468'}),stockRow(3,'ZERO-COST','5',{'Rate (Rs)':'0','Value (Rs)':'0'}),stockRow(4,'MISSING-COST','2')];
 const source=await seedStockItems(db,data),before=await q('select jsonb_agg(to_jsonb(i)order by id)from items i');
 await check('incremental pricing migration preserves all existing items, stock and history',async()=>{
  await db.exec(readFileSync(new URL('../supabase/migrations/202611130004_item_pricing_and_valuation.sql',import.meta.url),'utf8'));
  assert.deepEqual(await q("select jsonb_agg(to_jsonb(i)-'selling_price'order by id)from items i"),before);assert.equal(Number(await q('select count(*)from inventory_transactions')),0);
 });
 const item=await q("select id from items where item_code='VALUE'"),zero=await q("select id from items where item_code='ZERO-COST'"),missing=await q("select id from items where item_code='MISSING-COST'");
 await db.query('update items set selling_price=99.9999 where id=$1',[item]);
 await check('current-cost valuation uses exact posted usable/rejected/damaged quantities and excludes reservations from quantity deductions',async()=>{
  assert.equal((await q('select inventory_valuation_summary()')).physical,'0');
  const job=await q('select create_opening_stock_preview($1)',[source]);await finishStock(db,await approveStock(db,job));
  const loc=await q('select location_id from inventory_balances where item_id=$1',[item]);
  await q("select post_inventory_movement('DAMAGE',$1,$2,2,current_date,null,null,null,'Damage test',null)",[item,loc]);await q("select post_inventory_movement('RESERVE',$1,$2,1,current_date,null,null,null,'Reserve test',null)",[item,loc]);
  const row=await q('select to_jsonb(v)from inventory_valuation_rows(null,null,array[$1]::uuid[])v',[item]);assert.equal(row.usable,'16.9872021234');assert.equal(row.rejected,'6.3702042468');assert.equal(Number(row.damaged),4.2468);assert.equal(row.physical,'27.6042063702');assert.equal(row.selling,'99.9999');
  const z=await q('select to_jsonb(v)from inventory_valuation_rows(null,null,array[$1]::uuid[])v',[zero]);assert.equal(Number(z.usable),0);assert.equal(z.missing_cogs,false);
 });
 await check('missing COGS remains unknown and classification/location totals are explicitly incomplete',async()=>{
  await db.query('update items set cogs_unit_cost=null where id=$1',[missing]);const s=await q('select inventory_valuation_summary()');assert.equal(s.missing_cogs,1);assert.ok(s.groups.length>0);
  const id=await q("insert into stock_locations(code,name)values('EMPTY','Empty')returning id");assert.equal((await q('select inventory_valuation_summary($1)',[id])).usable,'0');
  const v=await q('select to_jsonb(v)from item_pricing_valuation(array[$1]::uuid[],null)v',[missing]);assert.equal(v.usable,null);assert.equal(v.missing_cogs,true);
 });
 await check('valuation filters separate stock classifications and locations without mixing buckets',async()=>{
  const classification=await q("insert into stock_classifications(name)values('Other valuation class')returning id"),location=await q("insert into stock_locations(code,name)values('VALUATION-OTHER','Valuation other')returning id");
  await db.query('update items set stock_classification_id=$1 where id=$2',[classification,zero]);await q("select post_inventory_movement('STOCK_IN',$1,$2,4,current_date,null,null,null,'Location filter test',null)",[zero,location]);
  const byClass=await q('select inventory_valuation_summary(null,$1)',[classification]);assert.equal(Number(byClass.usable),0);assert.equal(byClass.groups.length,1);assert.equal(byClass.groups[0].classification_id,classification);
  const byLocation=await q('select inventory_valuation_summary($1)',[location]);assert.equal(Number(byLocation.physical),0);assert.equal(byLocation.missing_cogs,0);assert.equal(byLocation.groups.length,1);assert.equal((await q('select inventory_valuation_summary()')).missing_cogs,1);
 });
 let priceId,p,inventoryBefore,productFieldsBefore;
 await check('price preview shows old/new COGS, preserves selling and never posts source quantities',async()=>{
  productFieldsBefore=await q("select jsonb_agg(to_jsonb(i)-'cogs_unit_cost'-'updated_at'-'updated_by'order by id)from items i");
  inventoryBefore=await q('select jsonb_build_object(\'balances\',(select jsonb_agg(to_jsonb(b)order by item_id,location_id)from inventory_balances b),\'ledger\',(select jsonb_agg(to_jsonb(t)order by id)from inventory_transactions t))');
  priceId=await stage([stockRow(2,'VALUE','999999',{'Rate (Rs)':'3.0001'}),stockRow(3,'ZERO-COST','9999',{'Rate (Rs)':'0'}),stockRow(4,'MISSING-COST','0',{'Rate (Rs)':'0'})]);
  const page=await q('select item_price_page($1)',[priceId]);assert.equal(page.rows[0].old_cogs,'2.1234');assert.equal(page.rows[0].new_cogs,'3.0001');assert.equal(page.rows[0].selling,'99.9999');assert.equal(page.rows[1].state,'UNCHANGED');assert.equal(page.rows[2].new_cogs,'0.0000');assert.equal(Number(await q('select cogs_unit_cost from items where id=$1',[item])),2.1234);
  const progress=await q('select item_price_progress($1)',[priceId]);p=await approve(priceId,[2,4],progress.revision);assert.equal(Number(await q('select cogs_unit_cost from items where id=$1',[item])),2.1234);
 });
 await check('approved price-only batch changes only COGS and attribution, preserves exact zero and all inventory',async()=>{
  const done=await finish(p);assert.equal(done.posted,2);assert.deepEqual(await q("select jsonb_agg(to_jsonb(i)-'cogs_unit_cost'-'updated_at'-'updated_by'order by id)from items i"),productFieldsBefore);assert.equal(Number(await q('select cogs_unit_cost from items where id=$1',[item])),3.0001);assert.equal(Number(await q('select selling_price from items where id=$1',[item])),99.9999);assert.equal(Number(await q('select cogs_unit_cost from items where id=$1',[missing])),0);
  assert.deepEqual(await q('select jsonb_build_object(\'balances\',(select jsonb_agg(to_jsonb(b)order by item_id,location_id)from inventory_balances b),\'ledger\',(select jsonb_agg(to_jsonb(t)order by id)from inventory_transactions t))'),inventoryBefore);
  assert.equal(Number(await q('select count(*)from item_price_changes')),2);assert.equal((await step(p)).posted,2);assert.equal(Number(await q('select count(*)from item_price_changes')),2);
  const v=await q('select to_jsonb(v)from item_pricing_valuation(array[$1]::uuid[],null)v',[item]);assert.equal(v.usable,'24.0008030001');
 });
 await check('manual selling price remains independent and price authorization is enforced',async()=>{
  await db.query('update items set selling_price=0 where id=$1',[item]);assert.equal(Number(await q('select cogs_unit_cost from items where id=$1',[item])),3.0001);
  await db.exec("select set_config('test.edit','false',false)");await assert.rejects(db.query('update items set selling_price=5 where id=$1',[item]),/Edit permission/);await assert.rejects(q('select reuse_item_price_source($1)',[source]),/Edit permission/);await db.exec("select set_config('test.edit','true',false)");
 });
 await check('unmatched, duplicate, inactive, unit mismatch and invalid prices are blocked',async()=>{
  await seedStockItems(db,[stockRow(2,'INACTIVE-PRICE','0')]);await db.exec("update items set is_active=false,deactivated_at=clock_timestamp(),deactivated_by=auth.uid()where item_code='INACTIVE-PRICE'");
  const id=await stage([stockRow(2,'NOT-FOUND','1'),stockRow(3,'VALUE','1',{'Rate (Rs)':'-1'}),stockRow(4,'ZERO-COST','1',{Unit:'KG'}),stockRow(5,'MISSING-COST','1'),stockRow(6,'MISSING-COST','1'),stockRow(7,'INACTIVE-PRICE','0')]);const page=await q('select item_price_page($1)',[id]);assert.ok(page.rows.every(r=>r.state==='INVALID'));await assert.rejects(approve(id,[2],(await q('select item_price_progress($1)',[id])).revision),/valid changed/);
 });
 await check('changed COGS after preview pauses rather than silently overwriting; refresh requires reapproval',async()=>{
  const id=await stage([stockRow(2,'VALUE','1',{'Rate (Rs)':'7'})]),pr=await q('select item_price_progress($1)',[id]);let queued=await approve(id,[2],pr.revision);await db.query('update items set cogs_unit_cost=4 where id=$1',[item]);queued=await step(queued);assert.equal(queued.state,'PAUSED');assert.equal(Number(await q('select cogs_unit_cost from items where id=$1',[item])),4);await q('select refresh_item_price_import($1)',[id]);assert.equal((await q('select item_price_page($1)',[id])).rows[0].old_cogs,'4.0000');
 });
 await check('a failure rolls back all price changes/audits within a chunk and safe refresh resumes',async()=>{
  const id=await stage([stockRow(2,'VALUE','1',{'Rate (Rs)':'8'}),stockRow(3,'ZERO-COST','1',{'Rate (Rs)':'9'})]),pr=await q('select item_price_progress($1)',[id]),queued=await approve(id,[2,3],pr.revision);
  await db.exec("create function price_fail_test()returns trigger language plpgsql as $$begin if new.item_code='ZERO-COST' then raise exception 'private backend';end if;return new;end$$;create trigger price_fail_test before update on items for each row execute function price_fail_test()");const result=await step(queued);assert.equal(result.state,'PAUSED');assert.equal(Number(await q('select cogs_unit_cost from items where id=$1',[item])),4);assert.equal(Number(await q('select count(*)from item_price_changes')),2);
  await db.exec('drop trigger price_fail_test on items');await q('select refresh_item_price_import($1)',[id]);await assert.rejects(step(queued),/superseded/);const fresh=await q('select item_price_progress($1)',[id]);assert.equal((await finish(await approve(id,[2,3],fresh.revision))).posted,2);
 });
 await check('price audit is immutable and nonadmins cannot call approval/private helpers or write raw rows',async()=>{
  await assert.rejects(db.exec('update item_price_changes set new_cogs=1'),/immutable/);
  await db.exec("set role authenticated;select set_config('test.role','USER',false)");await assert.rejects(q('select reuse_item_price_source($1)',[source]),/Admin/);await assert.rejects(db.exec('update item_price_import_rows set new_cogs=1'),/permission denied/);await assert.rejects(q('select prepare_item_price_import($1,$2,$3,$4::jsonb,null)',['x','x','s','[]']),/permission denied/);await db.exec("reset role;select set_config('test.role','ADMIN',false)");
 });
 await check('source lineage preserves renamed units while fresh uploads require an explicit unit match',async()=>{
  const unit=await q('select unit_id from items where id=$1',[item]),name=await q('select name from units_of_measurement where id=$1',[unit]);
  await db.query("update units_of_measurement set name='Renamed price unit'where id=$1",[unit]);
  try{const reuse=await q('select reuse_item_price_source($1)',[source]),page=await q('select item_price_page($1)',[reuse]);assert.notEqual(page.rows[0].state,'INVALID');const fresh=await stage([stockRow(2,'VALUE','0',{'Rate (Rs)':'10'})]);assert.equal((await q('select item_price_page($1)',[fresh])).rows[0].state,'INVALID');}finally{await db.query('update units_of_measurement set name=$1 where id=$2',[name,unit]);}
 });
 await check('late failure after a committed response cannot undo or duplicate successful price changes',async()=>{
  const id=await stage([stockRow(2,'VALUE','0',{'Rate (Rs)':'8.5'})]),pr=await q('select item_price_progress($1)',[id]),queued=await approve(id,[2],pr.revision),done=await finish(queued);
  const count=await q('select count(*)from item_price_changes');assert.equal(done.state,'COMPLETED');assert.equal((await q('select interrupt_item_price_import($1,$2,$3)',[id,queued.next.id,queued.next.key])).state,'COMPLETED');assert.equal(await q('select count(*)from item_price_changes'),count);
 });
 await check('a selling-price edit after approval is preserved by the cost-only update',async()=>{
  const id=await stage([stockRow(2,'VALUE','0',{'Rate (Rs)':'9.1234'})]),pr=await q('select item_price_progress($1)',[id]),queued=await approve(id,[2],pr.revision);
  await db.query('update items set selling_price=17.7777 where id=$1',[item]);assert.equal((await finish(queued)).posted,1);assert.equal(Number(await q('select selling_price from items where id=$1',[item])),17.7777);assert.equal(Number(await q('select cogs_unit_cost from items where id=$1',[item])),9.1234);
 });
 await check('failure of a later chunk preserves earlier prices and refresh resumes only pending rows',async()=>{
  const data=Array.from({length:101},(_,i)=>stockRow(i+2,'PRICE-RESUME-'+i,'0',{'Rate (Rs)':'1'}));await seedStockItems(db,data);const id=await stage(data.map(r=>({...r,raw:{...r.raw,'Rate (Rs)':'2'}}))),pr=await q('select item_price_progress($1)',[id]);let queued=await approve(id,data.map(r=>r.row),pr.revision);queued=await step(queued);assert.equal(queued.posted,100);
  await db.exec("create function price_resume_fail()returns trigger language plpgsql as $$begin if new.item_code='PRICE-RESUME-100'then raise exception 'private failure';end if;return new;end$$;create trigger price_resume_fail before update on items for each row execute function price_resume_fail()");queued=await step(queued);assert.equal(queued.state,'PAUSED');assert.equal(queued.posted,100);assert.equal(Number(await q("select cogs_unit_cost from items where item_code='PRICE-RESUME-100'")),1);
  await db.exec('drop trigger price_resume_fail on items');await q('select refresh_item_price_import($1)',[id]);const fresh=await q('select item_price_progress($1)',[id]);assert.equal(fresh.ready,1);queued=await finish(await approve(id,[102],fresh.revision));assert.equal(queued.posted,101);assert.equal(Number(await q('select count(*)from item_price_changes c join item_price_import_rows r on r.id=c.row_id where r.import_id=$1',[id])),101);
 });
 await check('2,000 prices post in twenty bounded chunks, with paginated preview and no duplicate changes',async()=>{
  const data=Array.from({length:2000},(_,i)=>stockRow(i+2,'PRICE-CAP-'+i,'0',{'Rate (Rs)':'1'}));await seedStockItems(db,data);const id=await stage(data.map(r=>({...r,raw:{...r.raw,'Rate (Rs)':'1.0001'}}))),pr=await q('select item_price_progress($1)',[id]);assert.equal((await q('select item_price_page($1,0)',[id])).rows.length,100);assert.equal((await q('select item_price_page($1,1900)',[id])).rows.at(-1).row,2001);
  const t=performance.now();let p=await approve(id,data.map(r=>r.row),pr.revision),max=0;while(p.state==='RUNNING'&&p.next){const t=performance.now();p=await step(p);max=Math.max(max,performance.now()-t);if(p.state==='PAUSED')throw new Error(p.next.error);}assert.equal(p.posted,2000);assert.equal(Number(await q('select count(*)from item_price_import_chunks where import_id=$1',[id])),20);assert.equal(Number(await q('select count(*)from items where item_code like $1 and cogs_unit_cost=1.0001',['PRICE-CAP-%'])),2000);console.log(JSON.stringify({prices:2000,max_chunk_ms:Math.round(max),total_ms:Math.round(performance.now()-t)}));
 });
 if(process.env.ITEM_IMPORT_WORKBOOK)await check('actual workbook COGS including zeros matches the original preserved source',async()=>{
  const{readWorkbook}=await import('../lib/inventory/import/workbook.ts');const book=await readWorkbook(readFileSync(process.env.ITEM_IMPORT_WORKBOOK));const source=await seedStockItems(db,book.rows),id=await q('select reuse_item_price_source($1)',[source]),p=await q('select item_price_progress($1)',[id]);assert.equal(p.total,1994);assert.equal(p.unchanged,1994);assert.equal(p.ready,0);assert.equal(p.invalid,0);assert.ok(book.rows.some(r=>Number(r.raw['Rate (Rs)'])===0));
 });
 console.log(`${passed} pricing/valuation database checks passed`);
}finally{await db.close();}
