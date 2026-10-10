// Local PostgreSQL regression tests using the repository's optional PGlite runtime.
import {PGlite} from '../node_modules/.cache/gp-validation/node_modules/@electric-sql/pglite/dist/index.js';
import fs from 'node:fs';
import assert from 'node:assert/strict';
const db=new PGlite();
const read=name=>fs.readFileSync('supabase/migrations/'+name,'utf8');
const original=read('202608240016_phase_8b_procurement_execution.sql');
const revisions=read('202608260022_purchase_order_revisions.sql');
const fn=(source,name)=>{
 const match=source.match(new RegExp('create (?:or replace )?function public\\.'+name+'\\([^$]*?\\$\\$[\\s\\S]*?\\$\\$;','i'));
 assert.ok(match,name);return match[0].replace(/^create function/i,'create or replace function');
};
const uid='11111111-1111-4111-8111-111111111111';
await db.exec(`create role anon;create role authenticated;create schema auth;create table auth.users(id uuid primary key);insert into auth.users values('${uid}');
create function auth.uid()returns uuid language sql as $$select '${uid}'::uuid$$;
create function public.has_erp_permission(section text,action text)returns boolean language sql as $$select coalesce(current_setting('test.permissions',true),'true')='true'$$;
create function public.is_erp_manager()returns boolean language sql as $$select coalesce(current_setting('test.manager',true),'true')='true'$$;
create function public.recalculate_purchase_order(id uuid)returns void language sql as $$select$$;`);
for(const name of ['procurement_year_counters','suppliers','purchase_orders','purchase_order_items','purchase_order_activities','material_receipts','material_receipt_items','material_receipt_activities']){
 const sql=original.match(new RegExp('create table public\\.'+name+'\\([^;]+;'))[0];
 await db.exec(sql.replace(/references\s+(?:public\.|auth\.)\w+\s*\(\w+\)\s*(?:on delete (?:restrict|cascade|set null))?/gi,''));
}
await db.exec(`alter table public.purchase_orders drop constraint purchase_orders_requisition_id_key;
alter table public.purchase_orders drop constraint purchase_orders_status_check;
alter table public.purchase_orders add column root_po_id uuid,add column parent_po_id uuid,add column revision_number integer default 0,add column revision_reason text,add column revised_at timestamptz,add column revised_by uuid;
alter table public.purchase_order_items add column root_po_item_id uuid,add column indent_item_id uuid;
alter table public.purchase_orders add constraint purchase_orders_status_check check(status in('DRAFT','CONFIRMED','PARTIALLY_RECEIVED','FULLY_RECEIVED','CANCELLED','CLOSED','SUPERSEDED'));
create unique index purchase_orders_one_current_version on public.purchase_orders(root_po_id) where status in('CONFIRMED','PARTIALLY_RECEIVED','FULLY_RECEIVED','CLOSED');`);
for(const [source,name] of [[original,'allocate_procurement_number'],[original,'confirm_purchase_order'],[revisions,'refresh_purchase_order_revision_receipt_status'],[revisions,'refresh_purchase_order_receipt_status']])await db.exec(fn(source,name));
await db.exec(read('202610100001_purchase_receipt_work_queue.sql'));
await db.exec(read('202608260018_phase_7_8_material_receipt_inventory_integration.sql').match(/create table public.material_receipt_inventory_postings\([\s\S]*?;/)[0].replace(/references\s+(?:public\.|auth\.)\w+\s*\(\w+\)\s*(?:on delete (?:restrict|cascade|set null))?/gi,''));
await db.exec(fn(read('202608240017_phase_8_purchase_flow_simplification.sql'),'save_purchase_order'));
const scalar=async(sql,args=[])=>Object.values((await db.query(sql,args)).rows[0])[0];
const call=(name,args=[])=>scalar(`select public.${name}(${args.map((_,i)=>'$'+(i+1)).join(',')})`,args);
const order=async(number,status='CONFIRMED',root=null,revision=0,quantity=1000)=>{
 const id=await scalar(`insert into public.purchase_orders(po_number,requisition_id,indent_id,supplier_id,supplier_code_snapshot,supplier_name_snapshot,billing_address_snapshot,delivery_address_snapshot,created_by,status,root_po_id,revision_number)values($1,$2,$2,$2,'SUP','Supplier','Billing','Delivery',$2,$3,$4,$5)returning id`,[number,uid,status,root,revision]);
 if(!root)await db.query('update public.purchase_orders set root_po_id=id where id=$1',[id]);
 const line=await scalar(`insert into public.purchase_order_items(purchase_order_id,requisition_item_id,line_number,item_name_snapshot,unit_snapshot,pon_quantity,quantity)values($1,$2,1,'Material','PCS',1500,$3)returning id`,[id,uid,quantity]);
 await db.query('update public.purchase_order_items set root_po_item_id=id where id=$1',[line]);
 return {id,line};
};
const receive=(po,line,quantity)=>call('authorized_record_material_receipt',[po,{},[{purchase_order_item_id:line,received_quantity:quantity,accepted_quantity:quantity,rejected_quantity:0}]]);
let checks=0;
const check=async(name,action)=>{await action();checks++;console.log('PASS '+name)};
const originalPO=await order('PO/2026/0001');
await check('confirmed PO initially has no receipt',async()=>assert.equal(await call('purchase_order_has_receipts',[originalPO.id]),false));
const r1=await call('create_purchase_order_revision',[originalPO.id,'First revision']);
await call('authorized_confirm_purchase_order',[r1]);
await check('confirmed revised PO can be cancelled before any receipt',async()=>{
 await call('authorized_cancel_purchase_order',[r1,'No longer needed']);
 assert.equal(await scalar('select status from public.purchase_orders where id=$1',[r1]),'CANCELLED');
});
const po=await order('PO/2026/0002');
const receipt=await receive(po.id,po.line,600);
await check('any receipt prevents PO cancellation',async()=>assert.rejects(call('authorized_cancel_purchase_order',[po.id,'Cancel']),/Material Receipt already exists/));
const draft=await call('create_purchase_order_revision',[po.id,'Increase quantity']);
const revisedLine=await scalar('select id from public.purchase_order_items where purchase_order_id=$1',[draft]);
await db.query('update public.purchase_order_items set quantity=1200 where id=$1',[revisedLine]);
await check('draft revision cannot receive',async()=>assert.rejects(receive(draft,revisedLine,1),/Current confirmed PO required/));
await db.query('update public.purchase_order_items set quantity=500 where id=$1',[revisedLine]);
await check('revision cannot reduce ordered quantity below received quantity',async()=>assert.rejects(call('authorized_confirm_purchase_order',[draft]),/cannot be below quantity already received/));
await db.query('update public.purchase_order_items set quantity=1200 where id=$1',[revisedLine]);
await call('authorized_confirm_purchase_order',[draft]);
await check('confirmed revision inherits 600 previously received',async()=>{
 const workspace=await call('purchase_receipt_workspace');
 assert.equal(workspace.received[po.line],600);
 assert.equal(await scalar('select status from public.purchase_orders where id=$1',[po.id]),'SUPERSEDED');
 assert.equal(await scalar('select status from public.purchase_orders where id=$1',[draft]),'PARTIALLY_RECEIVED');
});
await check('superseded PO cannot receive',async()=>assert.rejects(receive(po.id,po.line,1),/Current confirmed PO required/));
await check('revision overreceipt is blocked',async()=>assert.rejects(receive(draft,revisedLine,601),/exceeds revised ordered quantity/));
const second=await receive(draft,revisedLine,400);
await check('receipt snapshots use family history',async()=>{
 const row=(await db.query('select previously_received_quantity,pending_quantity from public.material_receipt_items where material_receipt_id=$1',[second])).rows[0];
 assert.deepEqual(row,{previously_received_quantity:'600.000',pending_quantity:'200.000'});
});
await receive(draft,revisedLine,200);
await check('multiple receipts complete revised PO',async()=>assert.equal(await scalar('select status from public.purchase_orders where id=$1',[draft]),'FULLY_RECEIVED'));
await call('cancel_material_receipt',[receipt,'Return old receipt']);
await check('cancelling old receipt refreshes latest revision and preserves history',async()=>{
 assert.equal(await scalar('select status from public.purchase_orders where id=$1',[draft]),'PARTIALLY_RECEIVED');
 assert.equal(await scalar('select count(*)::integer from public.material_receipts where purchase_order_id in ($1,$2)',[po.id,draft]),3);
});
const cancelled=await order('PO/2026/0003');const cancelledReceipt=await receive(cancelled.id,cancelled.line,100);
await call('cancel_material_receipt',[cancelledReceipt,'Correction']);
await check('cancelled receipt still blocks PO cancellation',async()=>assert.rejects(call('authorized_cancel_purchase_order',[cancelled.id,'Cancel']),/Material Receipt already exists/));
await db.exec("set test.permissions='false'");
await check('existing section permissions are enforced',async()=>{
 await assert.rejects(call('purchase_receipt_workspace'),/view permission required/);
 await assert.rejects(call('authorized_cancel_purchase_order',[cancelled.id,'Cancel']),/edit permission required/);
});
// Apply management approval after historical receipt fixtures to verify upgrade compatibility.
await db.exec("set test.permissions='true'");
try{await db.exec(read('202610100002_purchase_management_approval.sql'))}catch(error){console.error(error.message,error.detail??'',error.position??'');process.exit(1)}
await check('legacy receipt workflows are retained without fabricated approval metadata',async()=>{
 const legacy=(await db.query('select status,approval_source,approved_by,approved_at from public.purchase_orders where id=$1',[draft])).rows[0];
 assert.deepEqual(legacy,{status:'PARTIALLY_RECEIVED',approval_source:'LEGACY_RECEIPT',approved_by:null,approved_at:null});
 assert.equal(await scalar('select status from public.purchase_orders where id=$1',[cancelled.id]),'APPROVED');
 await assert.rejects(call('create_purchase_order_revision',[draft,'Change']),/already been approved/);
});
const pending=await order('PO/2026/0004','DRAFT');
await call('authorized_confirm_purchase_order',[pending.id]);
await check('confirmation sends PO for management approval and blocks receiving',async()=>{
 assert.equal(await scalar("select count(*)::integer from public.purchase_order_activities where purchase_order_id=$1 and activity_type='SENT_FOR_MANAGEMENT_APPROVAL'",[pending.id]),1);
 await assert.rejects(receive(pending.id,pending.line,1),/approved PO required/);
});
const managementRevision=await call('create_purchase_order_revision',[pending.id,'Management review revision']);
await call('authorized_confirm_purchase_order',[managementRevision]);
const managementLine=await scalar('select id from public.purchase_order_items where purchase_order_id=$1',[managementRevision]);
const openDraft=await call('create_purchase_order_revision',[managementRevision,'Unconfirmed change']);
await check('old revisions and draft revisions cannot be approved',async()=>{
 await assert.rejects(call('authorized_approve_purchase_order',[pending.id]),/latest confirmed/);
 await assert.rejects(call('authorized_approve_purchase_order',[openDraft]),/latest confirmed/);
});
await db.exec("set test.manager='false'");
await check('approval is restricted to management even with PO edit permission',async()=>assert.rejects(call('authorized_approve_purchase_order',[managementRevision]),/Admin or Manager/));
await db.exec("set test.manager='true'");
await call('authorized_approve_purchase_order',[managementRevision]);
await check('approval stores actor, India date, timestamp and one audit event',async()=>{
 const approved=(await db.query("select status,approval_source,approved_by,approved_date=(approved_at at time zone 'Asia/Kolkata')::date as correct_date,approved_at is not null as has_time from public.purchase_orders where id=$1",[managementRevision])).rows[0];
 assert.deepEqual(approved,{status:'APPROVED',approval_source:'MANAGEMENT',approved_by:uid,correct_date:true,has_time:true});
 await call('authorized_approve_purchase_order',[managementRevision]);
 assert.equal(await scalar("select count(*)::integer from public.purchase_order_activities where purchase_order_id=$1 and activity_type='MANAGEMENT_APPROVED' and description='Purchase Order approved by Management'",[managementRevision]),1);
 assert.equal(await scalar('select status from public.purchase_orders where id=$1',[openDraft]),'CANCELLED');
});
await check('approved commercial header fields are read-only',async()=>{
 for(const [field,value] of [['supplier_name_snapshot','Changed supplier'],['billing_address_snapshot','Changed billing'],['delivery_address_snapshot','Changed delivery'],['payment_terms','Changed payment'],['delivery_terms','Changed terms'],['terms_conditions','Changed conditions'],['gst_rate','12'],['freight_amount','100'],['expected_delivery_date','2027-01-01']])
  await assert.rejects(db.query(`update public.purchase_orders set ${field}=$2 where id=$1`,[managementRevision,value]),/Commercial modifications/);
 await assert.rejects(db.query("update public.purchase_orders set status='DRAFT' where id=$1",[managementRevision]),/read-only/);
});
await check('approved item quantity and rates are read-only',async()=>{
 await assert.rejects(db.query('update public.purchase_order_items set quantity=1100 where id=$1',[managementLine]),/Item modifications/);
 await assert.rejects(db.query('update public.purchase_order_items set unit_rate=10 where id=$1',[managementLine]),/Item modifications/);
 await assert.rejects(db.query('delete from public.purchase_order_items where id=$1',[managementLine]),/Item modifications/);
});
await check('commercial RPCs and revision attempts reject approved families',async()=>{
 await assert.rejects(call('authorized_save_purchase_order',[managementRevision,{},[]]),/already been approved/);
 await assert.rejects(call('create_purchase_order_revision',[managementRevision,'Change']),/Approved Purchase Orders cannot be revised/);
 await assert.rejects(call('create_purchase_order_revision',[pending.id,'Change older revision']),/already been approved/);
 await assert.rejects(call('authorized_confirm_purchase_order',[openDraft]),/already been approved/);
});
await check('approved PO appears in the warehouse workspace',async()=>{
 const workspace=await call('purchase_receipt_workspace');
 assert.equal(workspace.orders.find(x=>x.id===managementRevision).approval_source,'MANAGEMENT');
});
const approvedReceipt=await receive(managementRevision,managementLine,400);
await check('approved PO supports partial receipt and becomes non-cancellable',async()=>{
 assert.equal(await scalar('select status from public.purchase_orders where id=$1',[managementRevision]),'PARTIALLY_RECEIVED');
 await assert.rejects(call('authorized_cancel_purchase_order',[managementRevision,'Cancel']),/Material Receipt already exists/);
});
await call('cancel_material_receipt',[approvedReceipt,'Correction']);
await check('cancelling all receipts restores APPROVED instead of CONFIRMED',async()=>assert.equal(await scalar('select status from public.purchase_orders where id=$1',[managementRevision]),'APPROVED'));
const fullReceipt=await receive(managementRevision,managementLine,1000);
await check('completion is audited once',async()=>{
 assert.equal(await scalar('select status from public.purchase_orders where id=$1',[managementRevision]),'FULLY_RECEIVED');
 assert.equal(await scalar("select count(*)::integer from public.purchase_order_activities where purchase_order_id=$1 and activity_type='COMPLETED'",[managementRevision]),1);
});
const receiptLine=await scalar('select id from public.material_receipt_items where material_receipt_id=$1',[fullReceipt]);
await db.query('insert into public.material_receipt_inventory_postings(material_receipt_id,material_receipt_item_id,inventory_transaction_id,purchase_order_id,supplier_id,posting_request_id,quantity,posted_by)values($1,$2,gen_random_uuid(),$3,$4,gen_random_uuid(),100,$4)',[fullReceipt,receiptLine,managementRevision,uid]);
await check('inventory posting is reflected in PO audit and prevents receipt cancellation',async()=>{
 assert.equal(await scalar("select count(*)::integer from public.purchase_order_activities where purchase_order_id=$1 and activity_type='INVENTORY_POSTED'",[managementRevision]),1);
 await assert.rejects(call('cancel_material_receipt',[fullReceipt,'Cancel']),/Inventory has already been posted/);
});
await db.exec(fn(original,'close_purchase_order'));
await check('completed approved PO can close and remains read-only',async()=>{
 await call('close_purchase_order',[managementRevision]);
 assert.equal(await scalar('select status from public.purchase_orders where id=$1',[managementRevision]),'CLOSED');
 await assert.rejects(call('create_purchase_order_revision',[managementRevision,'Change closed order']),/already been approved/);
});
const noReceipt=await order('PO/2026/0005');
await call('authorized_approve_purchase_order',[noReceipt.id]);
await check('approved PO with no receipts can be cancelled',async()=>{
 await call('authorized_cancel_purchase_order',[noReceipt.id,'Replacement needed']);
 assert.equal(await scalar('select status from public.purchase_orders where id=$1',[noReceipt.id]),'CANCELLED');
});
const unlimitedRoot=await order('PO/2026/0006');
await db.query("update public.purchase_orders set status='SUPERSEDED' where id=$1",[unlimitedRoot.id]);
const ninetyNine=await order('PO/2026/0006-Revised-99','CONFIRMED',unlimitedRoot.id,99);
await db.query("update public.purchase_orders set parent_po_id=$2,revision_reason='Historical revisions' where id=$1",[ninetyNine.id,unlimitedRoot.id]);
await check('revision numbering remains unique after revision 99',async()=>{
 const hundred=await call('create_purchase_order_revision',[ninetyNine.id,'Revision 100']);
 assert.equal(await scalar('select po_number from public.purchase_orders where id=$1',[hundred]),'PO/2026/0006-Revised-100');
});
await db.exec("set test.permissions='false'");
await check('approval and receiving preserve permission enforcement',async()=>{
 await assert.rejects(call('authorized_approve_purchase_order',[noReceipt.id]),/edit permission/);
 await assert.rejects(receive(managementRevision,managementLine,1),/edit permission required/);
});
console.log(`${checks} database checks passed`);await db.close();
