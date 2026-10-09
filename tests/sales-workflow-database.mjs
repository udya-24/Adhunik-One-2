// Local PostgreSQL integration tests. Uses the existing optional PGlite validation runtime.
import {PGlite} from '../node_modules/.cache/gp-validation/node_modules/@electric-sql/pglite/dist/index.js';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const db=new PGlite();let passed=0;
const migration=name=>fs.readFileSync(`supabase/migrations/${name}`,'utf8').replace(/^\uFEFF/,'');
const phases={
 crm:'202608240006_phase_4a_crm_inquiries.sql',orders:'202608240007_phase_4b_orders.sql',
 pi:'202608240008_phase_5a_proforma_invoices.sql',documents:'202608240009_phase_5b_pi_documents.sql',
 packing:'202608240010_phase_6a_packing_lists.sql',dispatch:'202608240011_phase_6b_dispatch_execution.sql',
 inventory:'202608240013_phase_7b_inventory_foundation.sql',
};
const functionSql=(file,name)=>{
 const match=migration(file).match(new RegExp(`create (?:or replace )?function public\\.${name}\\([^$]*?\\$\\$[\\s\\S]*?\\$\\$;`,'i'));
 assert.ok(match,`Function ${name}`);return match[0].replace(/^create function/i,'create or replace function');
};
const check=async(name,action)=>{await action();passed++;console.log('PASS '+name)};
const scalar=async(sql,args=[])=>Object.values((await db.query(sql,args)).rows[0]??{})[0];
const row=async(sql,args=[]) => (await db.query(sql,args)).rows[0];
const noReferences=sql=>sql.replace(/references\s+(?:public\.|auth\.)\w+\s*\(\w+\)\s*(?:on delete (?:restrict|cascade|set null))?/gi,'');
await db.exec(`
create role anon;create role authenticated;create schema auth;
create function auth.uid()returns uuid language sql stable as $$select nullif(current_setting('test.uid',true),'')::uuid$$;
create function public.has_active_erp_access()returns boolean language sql stable as $$select true$$;
create function public.can_manage_crm()returns boolean language sql stable as $$select current_setting('test.manager',true)='true'$$;
create function public.has_erp_permission(section text,action text)returns boolean language sql stable as $$select current_setting('test.permissions',true)='true'$$;
create function public.can_view_inquiry(id uuid)returns boolean language sql stable as $$select true$$;
create function public.can_view_order(id uuid)returns boolean language sql stable as $$select true$$;
create function public.can_view_proforma_invoice(id uuid)returns boolean language sql stable as $$select true$$;
create function public.can_view_dispatch(id uuid)returns boolean language sql stable as $$select true$$;
create function public.can_manage_dispatch(id uuid)returns boolean language sql stable as $$select true$$;
create function public.refresh_packing_list_dispatch_status(id uuid)returns void language plpgsql as $$begin return;end$$;
create sequence public.test_numbers;
create function public.allocate_business_number(entity text)returns text language sql as $$select entity||'-'||nextval('public.test_numbers')$$;
create table public.customer_companies(id uuid primary key default gen_random_uuid(),legal_name text,gstin text,primary_phone text,primary_email text,deleted_at timestamptz);
create table public.customer_contacts(id uuid primary key default gen_random_uuid(),customer_company_id uuid,phone text,email text,is_active boolean default true,deleted_at timestamptz);
create table public.customer_addresses(id uuid primary key default gen_random_uuid(),customer_company_id uuid,address_type text,address_line_1 text,address_line_2 text,city text,district text,state text,postal_code text,country text,is_active boolean default true,deleted_at timestamptz);
create table public.payment_terms(id uuid primary key default gen_random_uuid(),code text,name text,credit_days int,is_active boolean default true,deleted_at timestamptz);
create table public.erp_profiles(auth_user_id uuid, is_active boolean default true);
create table public.employees(id uuid,full_name text,designation_id uuid,official_email text,phone text);
create table public.designations(id uuid,name text);
create table public.items(id uuid,unit_weight_kg numeric,length_mm numeric,breadth_mm numeric,height_mm numeric);
create table public.system_settings(category text,key text,value text);
create table public.test_inventory_posts(id uuid default gen_random_uuid());
create function public.post_inventory_movement(text,uuid,uuid,numeric,date,text,uuid,text,text,text,uuid,uuid)returns uuid language plpgsql as $$declare v uuid;begin insert into public.test_inventory_posts default values returning id into v;return v;end$$;
`);
// Production table definitions/checks are retained; unrelated FK target setup is omitted.
for(const key of ['crm','orders','pi','documents','packing','dispatch','inventory']){
 const sql=migration(phases[key]);for(const match of sql.matchAll(/create table(?: if not exists)? public\.\w+\([\s\S]*?\);/gi))await db.exec(noReferences(match[0]));
}
for(const match of migration(phases.documents).matchAll(/alter table public\.(?:proforma_invoices|proforma_invoice_activities)[\s\S]*?;/gi))await db.exec(noReferences(match[0]));
for(const match of migration(phases.documents).matchAll(/create (?:unique )?index if not exists proforma_invoices_[\s\S]*?;/gi))await db.exec(match[0]);
await db.exec(`
alter table public.orders add shipping_contact_number text;
alter table public.proforma_invoices add shipping_contact_number text,add other_remarks text;
alter table public.packing_list_items add item_id uuid,add unit_weight_kg numeric;
alter table public.dispatches add stock_location_id uuid;
`);
for(const match of migration(phases.dispatch).matchAll(/alter table public\.packing_lists[\s\S]*?;/gi))await db.exec(match[0]);
for(const [file,name] of [[phases.pi,'can_manage_proforma_invoice'],[phases.documents,'assign_pi_root'],[phases.documents,'issue_proforma_invoice'],[phases.documents,'cancel_proforma_invoice']])await db.exec(functionSql(file,name));
await db.exec(`create trigger assign_pi_root before insert on public.proforma_invoices for each row execute function public.assign_pi_root();`);
await db.exec(functionSql('202608260021_pi_dispatch_packing_handoff.sql','can_view_packing_list'));
await db.exec(migration('202610090032_require_customer_acceptance.sql'));
await db.exec(migration('202610090033_order_snapshots_and_draft_pi.sql'));
await db.exec(`create trigger prepare_order_update before update on public.orders for each row execute function public.prepare_order_update();create trigger prepare_pi_update before update on public.proforma_invoices for each row execute function public.prepare_pi_update();`);
const user='11111111-1111-4111-8111-111111111111',other='22222222-2222-4222-8222-222222222222';
await db.exec(`select set_config('test.uid','${user}',false);select set_config('test.manager','false',false);select set_config('test.permissions','true',false);insert into public.erp_profiles values('${user}',true);insert into public.pi_document_settings(id)values(true);`);
const company=await scalar("insert into customer_companies(legal_name,primary_phone)values('Customer','12345')returning id");
const master=await scalar("insert into customer_addresses(customer_company_id,address_type,address_line_1,city,country)values($1,'BOTH','A-25 Industrial Area Delhi','Delhi','India')returning id",[company]);
async function inquiry(){return scalar("insert into inquiries(inquiry_number,company_id,inquiry_date,subject,requirement_description,status,assigned_to,created_by)values(public.allocate_business_number('INQUIRY'),$1,'2026-10-09','Machines','Machine','WON',$2,$2)returning id",[company,user]);}
const orderData={billing_address_id:master,shipping_address_id:master,billing_address_snapshot:{address_line_1:'Warehouse 2, Plot 15',city:'Lucknow',country:'India'},shipping_address_snapshot:{address_line_1:'Warehouse 3',city:'Lucknow',country:'India'},shipping_contact_number:'99999',customer_notes:'Customer instructions',internal_notes:'Private order note'};
let orderId,piId;
await check('conversion saves edited snapshots, contact and notes without master mutation',async()=>{
 orderId=await scalar('select convert_inquiry_to_order($1,$2)',[await inquiry(),orderData]);
 const order=await row('select * from orders where id=$1',[orderId]);
 assert.equal(order.billing_address_snapshot.address_line_1,orderData.billing_address_snapshot.address_line_1);
 assert.equal(order.shipping_address_snapshot.address_line_1,'Warehouse 3');assert.equal(order.shipping_contact_number,'99999');
 assert.equal(order.customer_notes,'Customer instructions');assert.equal(order.internal_notes,'Private order note');
 assert.equal(await scalar('select address_line_1 from customer_addresses where id=$1',[master]),'A-25 Industrial Area Delhi');
});
await check('future orders and legacy callers reload the original master defaults',async()=>{
 const id=await scalar('select convert_inquiry_to_order($1,$2)',[await inquiry(),{billing_address_id:master,shipping_address_id:master}]);
 const order=await row('select * from orders where id=$1',[id]);assert.equal(order.billing_address_snapshot.address_line_1,'A-25 Industrial Area Delhi');assert.equal(order.shipping_contact_number,'12345');
});
await check('editing snapshots retains overrides and rejects empty addresses',async()=>{
 await db.query('update orders set billing_address_snapshot=$2 where id=$1',[orderId,{address_line_1:'Edited Warehouse',city:'Lucknow'}]);
 await db.query("update orders set customer_notes='Updated notes'where id=$1",[orderId]);
 assert.equal((await scalar('select billing_address_snapshot from orders where id=$1',[orderId])).address_line_1,'Edited Warehouse');
 await assert.rejects(db.query('update orders set billing_address_snapshot=$2 where id=$1',[orderId,{address_line_1:'  '}]),/Address line 1 is required/);
});
const line={item_description:'Machine',unit:'Nos.',quantity:'10',unit_price:'100',discount_percentage:'0'};
const piData={pi_date:'2026-10-09',gst_percentage:'18',freight_amount:'50',currency:'INR',billing_address_id:master,shipping_address_id:master};
await check('PI uses order snapshots after master changes and preserves commercial calculations',async()=>{
 await db.query("update customer_addresses set address_line_1='Changed Master'where id=$1",[master]);
 piId=await scalar('select save_proforma_invoice(null,$1,$2,$3)',[orderId,piData,[line]]);
 const pi=await row('select * from proforma_invoices where id=$1',[piId]);assert.equal(pi.billing_address_snapshot.address_line_1,'Edited Warehouse');assert.equal(pi.shipping_address_snapshot.address_line_1,'Warehouse 3');assert.equal(Number(pi.grand_total),1230);assert.equal(pi.shipping_contact_number,'99999');assert.equal(pi.other_remarks,'Updated notes');
 await assert.rejects(db.query('select create_packing_list($1)',[piId]),/Accepted/);
});
let latest=piId;
await check('Draft can be revised; Rev 1–3 are ISSUED with no packing queue or inventory posting',async()=>{
 for(let revision=1;revision<=3;revision++){
  const prior=latest;latest=await scalar('select create_proforma_invoice_revision($1,$2)',[latest,'Customer requested changes']);
  const pi=await row('select * from proforma_invoices where id=$1',[latest]);assert.equal(pi.status,'ISSUED');assert.equal(pi.revision_number,revision);assert.equal(pi.accepted_at,null);
  assert.equal(await scalar('select status from proforma_invoices where id=$1',[prior]),'REVISED');
  assert.equal(pi.pi_number,await scalar('select pi_number from proforma_invoices where id=$1',[piId]));
  assert.equal(pi.shipping_address_snapshot.address_line_1,'Warehouse 3');
  assert.equal((await db.query('select * from get_awaiting_packing()')).rows.length,0);
  await assert.rejects(db.query('select create_packing_list($1)',[latest]),/Accepted/);
 }
 assert.equal(await scalar('select count(*) from test_inventory_posts'),0);
});
let packingId;
await check('unaccepted revision is editable; acceptance locks commercial terms and enables packing',async()=>{
 await db.query('select save_proforma_invoice($1,$2,$3,$4)',[latest,orderId,{...piData,freight_amount:'75'},[line]]);
 await db.query('select save_proforma_invoice_extras($1,$2,$3)',[latest,'99999','Customer instructions']);
 await db.query('select accept_proforma_invoice($1)',[latest]);
 assert.equal(await scalar('select status from proforma_invoices where id=$1',[latest]),'ACCEPTED');
 const queue=(await db.query('select * from get_awaiting_packing()')).rows;assert.equal(queue.length,1);assert.equal(queue[0].id,latest);
 assert.equal(await scalar('select can_manage_proforma_invoice($1)',[latest]),false);
 await assert.rejects(db.query('select save_proforma_invoice($1,$2,$3,$4)',[latest,orderId,piData,[line]]),/not editable/);
 await db.query('update proforma_invoices set freight_amount=999,other_remarks=\'Changed\' where id=$1',[latest]);
 assert.equal(Number(await scalar('select freight_amount from proforma_invoices where id=$1',[latest])),75);
 assert.equal(await scalar('select other_remarks from proforma_invoices where id=$1',[latest]),'Customer instructions');
 const activity=await row("select * from proforma_invoice_activities where proforma_invoice_id=$1 and activity_type='ACCEPTED'",[latest]);assert.equal(activity.created_by,user);assert.ok(activity.created_at);
 packingId=await scalar('select create_packing_list($1)',[latest]);assert.equal((await scalar('select shipping_address_snapshot from packing_lists where id=$1',[packingId])).address_line_1,'Warehouse 3');
});
let dispatchId;
await check('packing and dispatch become available only after acceptance',async()=>{
 const item=await scalar('select id from packing_list_items where packing_list_id=$1',[packingId]);
 await db.query('update packing_list_items set current_packing_quantity=10 where id=$1',[item]);
 const pkg=await scalar("insert into packing_list_packages(packing_list_id,package_number,package_type_snapshot,length_mm,breadth_mm,height_mm)values($1,1,'Carton',500,400,300)returning id",[packingId]);
 await db.query('insert into packing_list_package_contents(package_id,packing_list_item_id,quantity)values($1,$2,10)',[pkg,item]);
 await db.query('select finalize_packing_list($1)',[packingId]);
 dispatchId=await scalar('select create_dispatch($1)',[packingId]);
 await db.query('select save_dispatch($1,$2,$3)',[dispatchId,{transport_mode:'ROAD',shipping_address:orderData.shipping_address_snapshot},[pkg]]);
 assert.equal((await scalar('select shipping_address_snapshot from dispatches where id=$1',[dispatchId])).address_line_1,'Warehouse 3');
});
await check('new revision removes packing eligibility and blocks stale dispatch creation/confirmation',async()=>{
 const accepted=latest;latest=await scalar('select create_proforma_invoice_revision($1,$2)',[accepted,'New terms']);
 assert.equal(await scalar('select status from proforma_invoices where id=$1',[latest]),'ISSUED');
 assert.equal((await db.query('select * from get_awaiting_packing()')).rows.length,0);
 await assert.rejects(db.query('select create_dispatch($1)',[packingId]),/latest PI revision must be Accepted/);
 await assert.rejects(db.query('select save_dispatch($1,$2,$3)',[dispatchId,{},[]]),/latest PI revision must be Accepted/);
 await db.exec("select set_config('test.manager','true',false)");
 await assert.rejects(db.query('select confirm_dispatch($1)',[dispatchId]),/latest PI revision must be Accepted/);
 assert.equal(await scalar('select count(*) from test_inventory_posts'),0);
 await db.query('select accept_proforma_invoice($1)',[latest]);
 assert.equal((await db.query('select * from get_awaiting_packing()')).rows[0].id,latest);
});
await check('accepted PI dispatch confirms with the existing physical dispatch flow',async()=>{
 const packed=await scalar('select create_packing_list($1)',[latest]);
 const item=await scalar('select id from packing_list_items where packing_list_id=$1',[packed]);
 await db.query('update packing_list_items set current_packing_quantity=10 where id=$1',[item]);
 const pkg=await scalar("insert into packing_list_packages(packing_list_id,package_number,package_type_snapshot,length_mm,breadth_mm,height_mm)values($1,1,'Carton',500,400,300)returning id",[packed]);
 await db.query('insert into packing_list_package_contents(package_id,packing_list_item_id,quantity)values($1,$2,10)',[pkg,item]);
 await db.query('select finalize_packing_list($1)',[packed]);
 const dispatch=await scalar('select create_dispatch($1)',[packed]);
 await db.query('select save_dispatch($1,$2,$3)',[dispatch,{transport_mode:'ROAD',shipping_address:orderData.shipping_address_snapshot},[pkg]]);
 await db.query('select confirm_dispatch($1)',[dispatch]);
 assert.equal(await scalar('select status from dispatches where id=$1',[dispatch]),'DISPATCHED');
 assert.equal(await scalar('select is_committed from dispatch_packages where dispatch_id=$1',[dispatch]),true);
});
await check('cancelled PI has no queue, packing or further revisions',async()=>{
 await db.query('select cancel_proforma_invoice($1,$2)',[latest,'Customer cancelled']);
 await assert.rejects(db.query('select create_proforma_invoice_revision($1,$2)',[latest,'New changes']),/not found/);
 await assert.rejects(db.query('select create_packing_list($1)',[latest]),/Accepted/);
 assert.equal((await db.query('select * from get_awaiting_packing()')).rows.length,0);
});
await check('Draft deletion is audited, preserves numbers, and cannot delete issued PIs',async()=>{
 const draft=await scalar('select save_proforma_invoice(null,$1,$2,$3)',[orderId,piData,[line]]);
 await db.query('select delete_draft_proforma_invoice($1)',[draft]);
 const pi=await row('select * from proforma_invoices where id=$1',[draft]);assert.ok(pi.deleted_at);assert.equal(pi.deleted_by,user);assert.ok(pi.pi_number);
 await assert.rejects(db.query('select delete_draft_proforma_invoice($1)',[latest]),/not deletable/);
});
await check('issuing a Draft preserves review stage and non-owners cannot accept or revise',async()=>{
 await db.exec(`select set_config('test.uid','${user}',false);select set_config('test.manager','false',false);`);
 const draft=await scalar('select save_proforma_invoice(null,$1,$2,$3)',[orderId,piData,[line]]);
 await db.query('select issue_proforma_invoice($1)',[draft]);
 assert.equal(await scalar('select status from proforma_invoices where id=$1',[draft]),'ISSUED');
 assert.equal((await db.query('select * from get_awaiting_packing()')).rows.length,0);
 await assert.rejects(db.query('select create_packing_list($1)',[draft]),/Accepted/);
 await db.exec(`select set_config('test.uid','${other}',false);`);
 await assert.rejects(db.query('select accept_proforma_invoice($1)',[draft]),/not acceptable/);
 await assert.rejects(db.query('select create_proforma_invoice_revision($1,$2)',[draft,'Other user']),/cannot revise/);
});
console.log(`${passed} PostgreSQL integration checks passed`);await db.close();
