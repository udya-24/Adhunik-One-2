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
await db.exec(`create role anon;create role authenticated;create schema auth;
create function auth.uid()returns uuid language sql as $$select '${uid}'::uuid$$;
create function public.has_erp_permission(section text,action text)returns boolean language sql as $$select coalesce(current_setting('test.permissions',true),'true')='true'$$;
create function public.is_erp_manager()returns boolean language sql as $$select true$$;
create function public.recalculate_purchase_order(id uuid)returns void language sql as $$select$$;`);
for(const name of ['procurement_year_counters','purchase_orders','purchase_order_items','purchase_order_activities','material_receipts','material_receipt_items','material_receipt_activities']){
 const sql=original.match(new RegExp('create table public\\.'+name+'\\([^;]+;'))[0];
 await db.exec(sql.replace(/references\s+(?:public\.|auth\.)\w+\s*\(\w+\)\s*(?:on delete (?:restrict|cascade|set null))?/gi,''));
}
await db.exec(`alter table public.purchase_orders drop constraint purchase_orders_requisition_id_key;
alter table public.purchase_orders drop constraint purchase_orders_status_check;
alter table public.purchase_orders add column root_po_id uuid,add column parent_po_id uuid,add column revision_number integer default 0,add column revision_reason text,add column revised_at timestamptz,add column revised_by uuid;
alter table public.purchase_order_items add column root_po_item_id uuid,add column indent_item_id uuid;`);
for(const [source,name] of [[original,'allocate_procurement_number'],[original,'confirm_purchase_order'],[revisions,'refresh_purchase_order_revision_receipt_status'],[revisions,'refresh_purchase_order_receipt_status']])await db.exec(fn(source,name));
await db.exec(read('202610100001_purchase_receipt_work_queue.sql'));
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
console.log(`${checks} database checks passed`);await db.close();
