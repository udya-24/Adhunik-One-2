// Isolated PostgreSQL; never connects to Supabase or production.
import { PGlite } from '../node_modules/.cache/gp-validation/node_modules/@electric-sql/pglite/dist/index.js';
import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import assert from 'node:assert/strict';
const db = new PGlite();
let passed = 0;
const check = async (name, fn) => { await fn(); passed++; console.log('PASS ' + name); };
const scalar = async (sql, args = []) => Object.values((await db.query(sql, args)).rows[0])[0];
const foundation = `
create role anon; create role authenticated;
create schema auth; create schema storage;
create table auth.users(id uuid primary key);
create function auth.uid()returns uuid language sql stable as $$select nullif(current_setting('test.uid',true),'')::uuid$$;
create function public.is_erp_admin()returns boolean language sql stable as $$select current_setting('test.role',true)='ADMIN'$$;
create function public.has_active_erp_access()returns boolean language sql stable as $$select current_setting('test.role',true)in('ADMIN','MANAGER','USER')$$;
create function public.current_erp_role()returns text language sql stable as $$select current_setting('test.role',true)$$;
create function public.can_manage_crm()returns boolean language sql stable as $$select current_setting('test.role',true)in('ADMIN','MANAGER')$$;
create function public.set_updated_at()returns trigger language plpgsql as $$begin new.updated_at=clock_timestamp();return new;end$$;
create table public.proforma_invoice_items(id uuid primary key,inventory_item_id uuid);
create table public.packing_list_items(id uuid primary key,pi_item_id uuid,item_length_mm numeric,item_breadth_mm numeric,item_height_mm numeric);
create table public.packing_lists(id uuid primary key,status text);
create table public.dispatches(id uuid primary key,status text);
create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
create table storage.objects(id uuid,bucket_id text,name text);
grant usage on schema public,auth,storage to authenticated,anon;
insert into auth.users values('00000000-0000-0000-0000-000000000001');
select set_config('test.uid','00000000-0000-0000-0000-000000000001',false),set_config('test.role','ADMIN',false);
`;
await db.exec(foundation);
for (const file of ['202608240012_phase_7a_enterprise_item_master.sql','202608240013_phase_7b_inventory_foundation.sql']) await db.exec(readFileSync(new URL('../supabase/migrations/'+file, import.meta.url), 'utf8'));
await db.exec('alter table public.items add column cogs_unit_cost numeric(15,4)check(cogs_unit_cost>=0)');
await check('incremental migration executes against actual item/stock migrations', () => db.exec(readFileSync(new URL('../supabase/migrations/202611120001_item_master_excel_import.sql', import.meta.url), 'utf8')));
const raw = (code, family='MCC', group='Motor') => ({'New code':code,'Item name':code+' product','Item group':group,'Type':'Raw material','Family':family,'Store':'Store A1','Unit':'PCS','Status':'Keep: active','Opening qty':'10','Rejected qty':'2','Rate (Rs)':'12.34567','Value (Rs)':'123.4567','Rejected value (Rs)':'24.69134','Uses in 6 months':'0','Last used':''});
const row = (n, r) => ({row:n,raw:r,issues:[],warnings:[]});
const source = Buffer.from('test source'), sha = createHash('sha256').update(source).digest('hex');
const stage = rows => scalar('select stage_item_import($1,$2,$3,$4,$5::jsonb)',['test.xlsx',sha,source.toString('base64'),'Sheet1',JSON.stringify(rows)]);
const batch = id => scalar('select to_jsonb(b)from item_import_batches b where id=$1',[id]);
const commit = (id, nums, revision=1, ack=true) => scalar('select commit_item_import($1,$2,$3,$4)',[id,revision,nums,ack]);
const stock = (id, action, rev=null) => scalar('select review_item_import_stock($1,$2,$3,$4)',[id,action,rev,'test']);
let id, item, location;
await check('preview resolves six masters, warns rounding/zero and leaves business data unchanged', async()=>{
 id=await stage([row(2,raw('A')),row(3,raw('B','SWITCHGEARS')),row(4,{...raw('C','MCC',''),'Rate (Rs)':'0','Value (Rs)':'0','Rejected value (Rs)':'0'})]);
 const b=await batch(id); assert.equal(b.preview.summary.created,3); assert.equal(Object.keys(b.preview.rows[0].mappings).length,6);assert.match(b.preview.rows[0].mappings.location.code,/^XL-/);assert.equal(b.preview.rows[2].mappings.subcategory.state,'EMPTY');assert.ok(b.preview.rows[2].warnings.some(w=>w.includes('Zero COGS')));assert.equal(Number(await scalar('select count(*)from items')),0);assert.equal(Number(await scalar('select count(*)from item_categories')),0);
});
await check('confirmation is mandatory; atomic import preserves codes, parents and four-decimal COGS', async()=>{
 await assert.rejects(commit(id,[2,3,4],1,false),/confirmation/);const r=await commit(id,[2,3,4]);assert.equal(r.created,3);assert.equal(r.classifications.created,8);assert.equal(r.classifications.reused,0);assert.equal(Number(await scalar('select count(*)from item_subcategories')),2);assert.equal(Number(await scalar('select count(*)from item_categories')),2);assert.equal(await scalar("select cogs_unit_cost::text from items where item_code='A'"),'12.3457');assert.equal(await scalar("select cogs_unit_cost::text from items where item_code='C'"),'0.0000');assert.equal(Number(await scalar('select count(*)from inventory_balances')),0);assert.equal(Number(await scalar('select count(*)from inventory_transactions')),0);item=await scalar("select id from items where item_code='A'");location=await scalar('select id from stock_locations');
});
await check('retrying committed request returns result without duplicates',async()=>{assert.equal((await commit(id,[2,3,4])).created,3);assert.equal(Number(await scalar('select count(*)from items')),3);});
await check('repeat import reuses IDs and does not create masters or overwrite products',async()=>{
 const repeated=await stage([row(2,raw('A')),row(3,raw('B','SWITCHGEARS'))]);assert.equal((await batch(repeated)).preview.summary.reused,2);const r=await commit(repeated,[2,3]);assert.equal(r.reused,2);assert.equal(r.created,0);assert.equal(r.classifications.created,0);assert.equal(r.classifications.reused,8);assert.equal(Number(await scalar('select count(*)from items')),3);assert.equal(await scalar("select id from items where item_code='A'"),item);
});
await check('conflicting and inactive products are blocked; COGS never overwritten',async()=>{
 const c=await stage([row(2,{...raw('A'),'Item name':'Changed'})]);assert.ok((await batch(c)).preview.rows[0].errors.some(e=>e.includes('conflict')));await assert.rejects(commit(c,[2]),/unresolved/);assert.equal(await scalar("select item_name from items where item_code='A'"),'A product');
});
await check('case and incidental whitespace reuse normalized masters within correct parents',async()=>{
 const p=await stage([row(2,{...raw('D','  mcc  ',' motor '),'Type':' raw   material ','Unit':' pcs '})]);const b=await batch(p);assert.equal(b.preview.rows[0].mappings.category.state,'REUSED');assert.equal(b.preview.rows[0].mappings.subcategory.state,'REUSED');assert.equal(b.preview.rows[0].mappings.type.state,'REUSED');await commit(p,[2]);assert.equal(Number(await scalar('select count(*)from item_categories')),2);
});
await check('same-name different-code products warn and remain distinct',async()=>{const p=await stage([row(2,{...raw('E'),'Item name':'Shared'}),row(3,{...raw('F'),'Item name':'Shared'})]);assert.ok((await batch(p)).preview.rows[0].warnings.some(w=>w.includes('different code')));await commit(p,[2,3]);assert.equal(Number(await scalar("select count(*)from items where item_name='Shared'")),2);});
await check('duplicate codes block both rows',async()=>{const p=await stage([row(2,raw('DUP')),row(3,raw(' dup '))]);assert.equal((await batch(p)).preview.summary.failed,2);await assert.rejects(commit(p,[2]),/unresolved/);});
await check('inactive classifications require explicit resolution without reactivation',async()=>{
 await db.exec("update stock_classifications set is_active=false");const p=await stage([row(2,raw('G'))]);assert.ok((await batch(p)).preview.rows[0].errors.some(e=>e.includes('INACTIVE')));assert.equal(await scalar('select is_active from stock_classifications'),false);await db.exec('update stock_classifications set is_active=true');
});
await check('normal master writes enforce normalized duplicate prevention and stable parent links',async()=>{
 await assert.rejects(db.exec("insert into item_types(name)values(' RAW   MATERIAL ' )"),/Normalized/);
 const ca=await scalar("insert into item_categories(name)values('Whitespace A')returning id"),cb=await scalar("insert into item_categories(name)values('Whitespace B')returning id");
 const sa=await scalar("insert into item_subcategories(category_id,name)values($1,'Spaced  group')returning id",[ca]);await db.query("insert into item_subcategories(category_id,name)values($1,'Spaced group')",[cb]);await assert.rejects(db.query('update item_subcategories set category_id=$1 where id=$2',[cb,sa]),/Normalized/);
await assert.rejects(db.exec("update item_subcategories set category_id=(select id from item_categories where name='SWITCHGEARS')where category_id=(select id from item_categories where name='MCC')"),/reparented/);
});
await check('referenced deletion blocked, unused deletion audited and deactivation preserves references',async()=>{
 const cat=await scalar("select id from item_categories where name='MCC'");await assert.rejects(scalar('select delete_item_configuration($1,$2)',['item_categories',cat]),/Deactivate/);
 const unused=await scalar("insert into stock_classifications(name)values('Unused')returning id");await scalar('select delete_item_configuration($1,$2)',['stock_classifications',unused]);assert.equal(Number(await scalar("select count(*)from stock_classifications where name='Unused'")),0);assert.ok(Number(await scalar("select count(*)from item_master_admin_activities where event_type='DELETE'"))>0);
 await db.query('update item_categories set is_active=false where id=$1',[cat]);assert.equal(await scalar('select category_id from items where id=$1',[item]),cat);await db.query('update item_categories set is_active=true where id=$1',[cat]);
});
await check('stale preview rejects commit, refreshed preview commits',async()=>{
 const p=await stage([row(2,raw('H'))]);await db.exec("update item_categories set description='edited'where name='MCC'");await assert.rejects(commit(p,[2]),/changed/);await scalar('select refresh_item_import($1)',[p]);await commit(p,[2],2);
});
await check('automatic code conflicts preserve source code and counters',async()=>{
 await db.exec("update item_types set automatic_code_enabled=true,code_prefix='RM'where name='Raw material'");const p=await stage([row(2,raw('I'))]);assert.ok((await batch(p)).preview.rows[0].errors.some(e=>e.includes('Automatic-code conflict')));assert.equal(Number(await scalar('select current_value from item_types')),0);await db.exec("update item_types set automatic_code_enabled=false");
});
await check('mid-commit failure rolls back masters, products and import state',async()=>{
 const p=await stage([row(2,raw('ROLL1','New family')),row(3,raw('ROLL2','New family'))]);await db.exec(`create function fail_second()returns trigger language plpgsql as $$begin if new.item_code='ROLL2' then raise exception 'injected failure';end if;return new;end$$;create trigger fail_second before insert on items for each row execute function fail_second()`);await assert.rejects(commit(p,[2,3]),/injected/);assert.equal(Number(await scalar("select count(*)from items where item_code like 'ROLL%'")),0);assert.equal(Number(await scalar("select count(*)from item_categories where name='New family'")),0);assert.equal((await batch(p)).state,'PREVIEW');await db.exec('drop trigger fail_second on items');
});
await check('non-posting proposal preview/review/cancel cannot change stock',async()=>{
 await stock(id,'PREVIEW');let p=await scalar('select to_jsonb(p)from item_import_stock_proposals p where batch_id=$1',[id]);assert.equal(p.snapshot.length,3);assert.equal(p.snapshot[0].operation,'UNDETERMINED');assert.equal(p.snapshot[0].resulting_balance,null);await stock(id,'REVIEW',p.revision);p=await scalar('select to_jsonb(p)from item_import_stock_proposals p where batch_id=$1',[id]);assert.equal(p.state,'REVIEWED_POSTING_DISABLED');assert.equal(p.posting_enabled,false);await assert.rejects(stock(id,'POST',p.revision),/Posting disabled/);assert.equal(Number(await scalar('select count(*)from inventory_transactions')),0);await stock(id,'PREVIEW');p=await scalar('select to_jsonb(p)from item_import_stock_proposals p where batch_id=$1',[id]);await stock(id,'CANCEL',p.revision);assert.equal(Number(await scalar('select count(*)from inventory_balances')),0);
});
await check('intervening movement invalidates stock review, even after balance returns',async()=>{
 await stock(id,'PREVIEW');let p=await scalar('select to_jsonb(p)from item_import_stock_proposals p where batch_id=$1',[id]);
 await db.query("select post_inventory_movement('STOCK_IN',$1,$2,1,current_date,null,null,null,'test',null)",[item,location]);await db.query("select post_inventory_movement('STOCK_OUT',$1,$2,1,current_date,null,null,null,'test',null)",[item,location]);await assert.rejects(stock(id,'REVIEW',p.revision),/changed/);assert.equal(Number(await scalar('select on_hand_quantity from inventory_balances where item_id=$1',[item])),0);
});
await check('explicit classification consolidation checks preview, retains history and deactivates source',async()=>{
 const source=await scalar('select stock_classification_id from items where id=$1',[item]),target=await scalar("insert into stock_classifications(name)values('Reviewed classification')returning id");const preview=await scalar('select preview_item_consolidation($1,$2,$3)',['stock_classifications',source,target]);await assert.rejects(scalar('select consolidate_item_configuration($1,$2,$3,$4::jsonb,false)',['stock_classifications',source,target,JSON.stringify(preview)]),/confirmation/);await scalar('select consolidate_item_configuration($1,$2,$3,$4::jsonb,true)',['stock_classifications',source,target,JSON.stringify(preview)]);assert.equal(await scalar('select stock_classification_id from items where id=$1',[item]),target);assert.equal(await scalar('select is_active from stock_classifications where id=$1',[source]),false);assert.equal(Number(await scalar('select count(*)from inventory_transactions')),2);
});
await check('legacy ambiguous normalized classifications are surfaced and retained',async()=>{
 await db.exec("alter table item_types disable trigger item_import_normalized_guard;insert into item_types(name)values('Raw  material');alter table item_types enable trigger item_import_normalized_guard");
 const exact=await stage([row(2,raw('EXACT'))]);assert.equal((await batch(exact)).preview.rows[0].mappings.type.state,'REUSED');
 const p=await stage([row(2,{...raw('AMBIG'),'Type':'RAW MATERIAL'})]);assert.equal((await batch(p)).preview.rows[0].mappings.type.state,'AMBIGUOUS');await assert.rejects(commit(p,[2]),/unresolved/);assert.equal(Number(await scalar("select count(*)from item_types where item_import_normalize(name)='raw material'")),2);
});
await check('stock review freshness includes unit eligibility and failure attempts are audited',async()=>{
 await stock(id,'PREVIEW');assert.equal(await scalar('select item_import_stock_review_current($1)',[id]),true);
 await db.exec('update units_of_measurement set is_active=false');assert.equal(await scalar('select item_import_stock_review_current($1)',[id]),false);await db.exec('update units_of_measurement set is_active=true');
 const originalUnit=await scalar('select unit_id from items where id=$1',[item]),otherUnit=await scalar("insert into units_of_measurement(name)values('Different unit')returning id");
 await db.query('update items set unit_id=$1 where id=$2',[otherUnit,item]);await stock(id,'PREVIEW');const changed=await scalar('select revision from item_import_stock_proposals where batch_id=$1',[id]);await assert.rejects(stock(id,'REVIEW',changed),/changed source unit/);await db.query('update items set unit_id=$1 where id=$2',[originalUnit,item]);
 await scalar('select record_item_import_failure($1,$2)',[id,'injected failure audit']);assert.equal(Number(await scalar("select count(*)from item_master_admin_activities where batch_id=$1 and event_type='IMPORT_ATTEMPT_FAILED'",[id])),1);
});
await check('parent category and subcategory explicit consolidation preserves item integrity',async()=>{
 const src=await scalar("select id from item_categories where name='MCC'"),dest=await scalar("insert into item_categories(name)values('Target category')returning id");
 const p=await scalar('select preview_item_consolidation($1,$2,$3)',['item_categories',src,dest]);await scalar('select consolidate_item_configuration($1,$2,$3,$4::jsonb,true)',['item_categories',src,dest,JSON.stringify(p)]);
 assert.equal(await scalar('select category_id from items where id=$1',[item]),dest);assert.equal(Number(await scalar('select count(*)from items i join item_subcategories s on s.id=i.subcategory_id where i.category_id<>s.category_id')),0);
 const sub=await scalar('select subcategory_id from items where id=$1',[item]);const otherCat=await scalar("select id from item_categories where name='SWITCHGEARS'");const targetSub=await scalar('select id from item_subcategories where category_id=$1',[otherCat]);
 const p2=await scalar('select preview_item_consolidation($1,$2,$3)',['item_subcategories',sub,targetSub]);await scalar('select consolidate_item_configuration($1,$2,$3,$4::jsonb,true)',['item_subcategories',sub,targetSub,JSON.stringify(p2)]);assert.equal(await scalar('select category_id from items where id=$1',[item]),otherCat);
 const a=await scalar("insert into item_categories(name)values('Consolidation A')returning id"),b=await scalar("insert into item_categories(name)values('Consolidation B')returning id");
 const ac=await scalar("insert into item_subcategories(category_id,name)values($1,'Same child')returning id",[a]),bc=await scalar("insert into item_subcategories(category_id,name)values($1,'Same child')returning id",[b]);
 const childItem=await scalar("insert into items(item_code,item_name,category_id,subcategory_id,unit_id)values('CHILD-CHECK','Child check',$1,$2,(select id from units_of_measurement limit 1))returning id",[a,ac]);
 const before=await scalar('select preview_item_consolidation($1,$2,$3)',['item_categories',a,b]);await assert.rejects(scalar('select consolidate_item_configuration($1,$2,$3,$4::jsonb,true)',['item_categories',a,b,JSON.stringify(before)]),/Child-name conflict/);
 const childPreview=await scalar('select preview_item_consolidation($1,$2,$3)',['item_subcategories',ac,bc]);await scalar('select consolidate_item_configuration($1,$2,$3,$4::jsonb,true)',['item_subcategories',ac,bc,JSON.stringify(childPreview)]);
 const after=await scalar('select preview_item_consolidation($1,$2,$3)',['item_categories',a,b]);await scalar('select consolidate_item_configuration($1,$2,$3,$4::jsonb,true)',['item_categories',a,b,JSON.stringify(after)]);assert.equal(await scalar('select category_id from items where id=$1',[childItem]),b);assert.equal(await scalar('select category_id from item_subcategories where id=$1',[ac]),a);

});
await check('unauthorized roles cannot stage/commit/review/delete or read staging',async()=>{
 await db.exec("set role authenticated;select set_config('test.role','USER',false)");assert.equal(Number(await scalar('select count(*)from item_import_batches')),0);await assert.rejects(stage([row(2,raw('NO'))]),/Admin/);await assert.rejects(commit(id,[2]),/Admin/);await assert.rejects(stock(id,'PREVIEW'),/Admin/);await assert.rejects(scalar('select item_import_stock_review_current($1)',[id]),/Admin/);await assert.rejects(scalar('select record_item_import_failure($1,$2)',[id,'denied']),/Admin/);await assert.rejects(scalar('select delete_item_configuration($1,$2)',['item_categories',item]),/Admin/);await assert.rejects(db.exec("update item_import_stock_proposals set posting_enabled=true"),/permission denied/);await assert.rejects(db.exec('select item_import_create_master(\'{}\'::jsonb)'),/permission denied/);await db.exec('reset role');
});
if (process.env.ITEM_IMPORT_WORKBOOK) await check('actual 1,994-row workbook imports/reimports locally with 864 parent/group pairs and no stock', async()=>{
 const {readWorkbook}=await import('../lib/inventory/import/workbook.ts');
 const bytes=readFileSync(process.env.ITEM_IMPORT_WORKBOOK),parsed=await readWorkbook(bytes);
 assert.equal(parsed.rows.length,1994);assert.equal(parsed.rows.filter(r=>r.issues.length).length,0);
 const full=new PGlite();await full.exec(foundation);
 for(const file of ['202608240012_phase_7a_enterprise_item_master.sql','202608240013_phase_7b_inventory_foundation.sql'])await full.exec(readFileSync(new URL('../supabase/migrations/'+file,import.meta.url),'utf8'));
 await full.exec('alter table items add column cogs_unit_cost numeric(15,4)');
 await full.exec(readFileSync(new URL('../supabase/migrations/202611120001_item_master_excel_import.sql',import.meta.url),'utf8'));
 const q=async(sql,args=[])=>Object.values((await full.query(sql,args)).rows[0])[0];
 const stageFull=()=>q('select stage_item_import($1,$2,$3,$4,$5::jsonb)',['Item master v5.xlsx',parsed.sha256,bytes.toString('base64'),parsed.sheet,JSON.stringify(parsed.rows)]);
 const batchId=await stageFull();console.log('Actual workbook preview prepared');
 const preview=await q('select preview from item_import_batches where id=$1',[batchId]);assert.equal(preview.summary.created,1994);assert.equal(preview.summary.failed,0);
 const result=await q('select commit_item_import($1,1,$2,true)',[batchId,parsed.rows.map(r=>r.row)]);assert.equal(result.created,1994);assert.equal(result.classifications.created,896);console.log('Actual workbook master import committed locally');
 assert.equal(Number(await q('select count(*)from items')),1994);assert.equal(Number(await q('select count(*)from item_subcategories')),864);assert.equal(Number(await q('select count(*)from item_categories')),14);assert.equal(Number(await q('select count(*)from item_types')),5);assert.equal(Number(await q('select count(*)from units_of_measurement')),4);assert.equal(Number(await q('select count(*)from stock_locations')),3);assert.equal(Number(await q('select count(*)from stock_classifications')),6);assert.equal(Number(await q('select count(*)from items where subcategory_id is null')),2);
 const repeated=await stageFull();assert.equal((await q('select preview from item_import_batches where id=$1',[repeated])).summary.reused,1994);
 assert.equal((await q('select commit_item_import($1,1,$2,true)',[repeated,parsed.rows.map(r=>r.row)])).created,0);
 assert.equal(Number(await q('select count(*)from inventory_balances')),0);assert.equal(Number(await q('select count(*)from inventory_transactions')),0);
 await q("select review_item_import_stock($1,'PREVIEW',null,null)",[batchId]);assert.equal((await q('select snapshot from item_import_stock_proposals where batch_id=$1',[batchId])).length,1994);
 await full.close();
});
console.log(`${passed} local PostgreSQL acceptance checks passed`);await db.close();
