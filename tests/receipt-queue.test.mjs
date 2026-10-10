import test from 'node:test';
import assert from 'node:assert/strict';
import {latestReceiptVersions,receiptQueueBalance} from '../lib/procurement/receipt-queue.ts';
const version=(id,revision_number,status,root_po_id='po')=>({id,revision_number,status,root_po_id});
test('confirmed PO is visible; drafts and cancelled orders are hidden',()=>{
 assert.deepEqual(latestReceiptVersions([version('draft',0,'DRAFT','draft'),version('cancelled',0,'CANCELLED','cancelled'),version('po',0,'CONFIRMED')]).map(x=>x.id),['po']);
});
test('draft revision leaves latest confirmed revision in use',()=>{
 assert.deepEqual(latestReceiptVersions([version('original',0,'SUPERSEDED'),version('r1',1,'CONFIRMED'),version('r2',2,'DRAFT')]).map(x=>x.id),['r1']);
});
test('confirmed revision replaces earlier versions even with unordered input',()=>{
 assert.deepEqual(latestReceiptVersions([version('r3',3,'CONFIRMED'),version('original',0,'CONFIRMED'),version('r1',1,'CONFIRMED'),version('r2',2,'CONFIRMED')]).map(x=>x.id),['r3']);
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
