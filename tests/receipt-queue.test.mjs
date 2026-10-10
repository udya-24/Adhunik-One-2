import test from 'node:test';
import assert from 'node:assert/strict';
import {latestConfirmedVersions,latestReceiptVersions,receiptQueueBalance,purchaseStatusLabel} from '../lib/procurement/receipt-queue.ts';
const version=(id,revision_number,status,root_po_id='po')=>({id,revision_number,status,root_po_id,approval_source:['APPROVED','PARTIALLY_RECEIVED','FULLY_RECEIVED','CLOSED'].includes(status)?'MANAGEMENT':null});
test('approved PO is visible; drafts, confirmed and cancelled orders are hidden',()=>{
 assert.deepEqual(latestReceiptVersions([version('draft',0,'DRAFT','draft'),version('cancelled',0,'CANCELLED','cancelled'),version('confirmed',0,'CONFIRMED','confirmed'),version('po',0,'APPROVED')]).map(x=>x.id),['po']);
});
test('draft revision leaves latest confirmed revision in use',()=>{
 assert.deepEqual(latestConfirmedVersions([version('original',0,'SUPERSEDED'),version('r1',1,'CONFIRMED'),version('r2',2,'DRAFT')]).map(x=>x.id),['r1']);
});
test('confirmed revision replaces earlier versions even with unordered input',()=>{
 assert.deepEqual(latestConfirmedVersions([version('r3',3,'CONFIRMED'),version('original',0,'CONFIRMED'),version('r1',1,'CONFIRMED'),version('r2',2,'CONFIRMED')]).map(x=>x.id),['r3']);
});
test('completed orders remain visible for history',()=>{
 assert.equal(latestReceiptVersions([version('full',1,'FULLY_RECEIVED')]).length,1);
 assert.equal(latestReceiptVersions([version('closed',1,'CLOSED')]).length,1);
});
test('partial receipt has correct pending balance',()=>assert.deepEqual(receiptQueueBalance([{quantity:1000,received:400}]),{ordered:1000,received:400,pending:600,status:'Partially Received'}));
test('revision after partial receipt preserves received quantity',()=>assert.deepEqual(receiptQueueBalance([{quantity:1200,received:600}]),{ordered:1200,received:600,pending:600,status:'Partially Received'}));
test('multiple receipts complete the ordered quantity',()=>assert.equal(receiptQueueBalance([{quantity:1000,received:400+600}]).status,'Completed'));
test('unreceived lines cannot be hidden by overreceived lines',()=>assert.equal(receiptQueueBalance([{quantity:100,received:120},{quantity:100,received:80}]).pending,20));
test('no receipt produces pending status',()=>assert.equal(receiptQueueBalance([{quantity:1000,received:0}]).status,'Pending Receipt'));

test('latest pending revision does not fall back to an older approved version',()=>{
 assert.deepEqual(latestReceiptVersions([version('original',0,'APPROVED'),version('r1',1,'CONFIRMED')]),[]);
});
test('pending confirmed revisions appear in management approval only',()=>{
 const versions=[version('original',0,'SUPERSEDED'),version('r1',1,'CONFIRMED'),version('r2',2,'DRAFT')];
 assert.deepEqual(latestConfirmedVersions(versions).filter(x=>x.status==='CONFIRMED').map(x=>x.id),['r1']);
 assert.deepEqual(latestReceiptVersions(versions),[]);
});
test('legacy receipt orders remain visible with explicit exemption',()=>{
 const legacy={...version('legacy',1,'PARTIALLY_RECEIVED'),approval_source:'LEGACY_RECEIPT'};
 assert.deepEqual(latestReceiptVersions([legacy]),[legacy]);
 assert.deepEqual(latestReceiptVersions([{...legacy,approval_source:null}]),[]);
});
test('status labels explain the management stage and completion',()=>{
 assert.equal(purchaseStatusLabel('CONFIRMED'),'Waiting Management Approval');
 assert.equal(purchaseStatusLabel('APPROVED'),'APPROVED');
 assert.equal(purchaseStatusLabel('FULLY_RECEIVED'),'Completed');
});
