import test from'node:test';
import assert from'node:assert/strict';
import JSZip from'jszip';
import{listWorkbookSheets,readWorkbook,decimal}from'../lib/inventory/import/workbook.ts';
import{runOpeningChunks,openingError}from'../lib/inventory/opening-stock/runner.ts';
const progress=(posted=0,state='RUNNING')=>({id:'import',posted,state,next:state==='COMPLETED'?null:{id:'chunk'+posted,request_key:'key'+posted}});
test('opening runner posts one request per batch and stops after completion',async()=>{const calls=[],seen=[];const p=await runOpeningChunks(progress(),async current=>{calls.push(current.next.id);return {progress:progress(current.posted+1,current.posted===1?'COMPLETED':'RUNNING')};},p=>seen.push(p.posted));assert.equal(p.state,'COMPLETED');assert.deepEqual(calls,['chunk0','chunk1']);assert.deepEqual(seen,[0,1,2]);});
test('uncertain opening request is never automatically retried',async()=>{let calls=0;await assert.rejects(runOpeningChunks(progress(),async()=>{calls++;return {error:'timeout'};},()=>{}),/timeout/);assert.equal(calls,1);});
test('paused stock approval stops posting and unchanged progress cannot loop',async()=>{let calls=0;const paused=await runOpeningChunks(progress(),async()=>{calls++;return {progress:progress(0,'PAUSED')};},()=>{});assert.equal(paused.state,'PAUSED');assert.equal(calls,1);await assert.rejects(runOpeningChunks(progress(),async()=>({progress:progress()}),()=>{}),/did not advance/);});
test('posting errors are useful without exposing backend SQL or secrets',()=>{assert.match(openingError('57014'),/timed out/);assert.match(openingError('23505'),/already exists/);assert.match(openingError('55P03'),/Another request/);assert.ok(!openingError('XX000','private internal credentials').includes('private'));assert.match(openingError('P0001','Opening stock review required: balances changed'),/balances changed/);});
test('worksheet list is explicit and master import keeps its original single-sheet contract',async()=>{const z=new JSZip();z.file('xl/workbook.xml','<workbook xmlns:r="relationships"><sheets><sheet name="Stock" r:id="r1"/><sheet name="Notes" r:id="r2"/></sheets></workbook>');z.file('xl/_rels/workbook.xml.rels','<Relationships><Relationship Id="r1" Target="worksheets/sheet1.xml"/></Relationships>');const bytes=await z.generateAsync({type:'nodebuffer'});assert.deepEqual(await listWorkbookSheets(bytes),['Stock','Notes']);await assert.rejects(readWorkbook(bytes),/exactly one/);await assert.rejects(readWorkbook(bytes,'Not a sheet'),/Select a worksheet/);});

test('reconciliation keeps units separate, uses exact decimals and exposes invalid/unmapped source values',async()=>{
 const{reconcileOpeningStock}=await import('../lib/inventory/opening-stock/reconciliation.ts');
 const row=(unit,id,q,state='POSTED',sourceId=id)=>({unit_id:id,raw:{Unit:unit,'Opening qty':q,'Rejected qty':'0'},is_selected:true,state,snapshot:{unit,source_unit_id:sourceId,quantity:q}});
 const totals=reconcileOpeningStock([row('PCS','pcs','0.1'),row('PCS','pcs','0.2'),row('KG','kg','4.123456'),row('MTR','pcs','5','INVALID',null),row('KG','kg','invalid','INVALID')],decimal);
 assert.equal(totals.find(t=>t.unit_id==='pcs').posted,'0.300000');assert.equal(totals.find(t=>t.unit_id==='kg').posted,'4.123456');assert.equal(totals.find(t=>t.unit_id==='kg').invalid_source_values,1);assert.equal(totals.find(t=>t.unresolved_source_unit).unit,'MTR');
});


test('reconciliation distinguishes edited rejected proposals, actual posted rejected stock and legacy exclusions',async()=>{
 const{reconcileOpeningStock}=await import('../lib/inventory/opening-stock/reconciliation.ts');
 const base={unit_id:'pcs',raw:{Unit:'PCS','Opening qty':'5','Rejected qty':'2'},is_selected:true,state:'POSTED',snapshot:{unit:'PCS',source_unit_id:'pcs',quantity:'5',rejected_posting_quantity:'3'},rejected_transaction_id:'rejected-ledger'};
 const [t]=reconcileOpeningStock([base,{...base,rejected_transaction_id:null,snapshot:{...base.snapshot,rejected_posting_quantity:'0',quantity_policy:'USABLE_OPENING_EXCLUDE_REJECTED'}}],decimal);
 assert.equal(t.excel_rejected,'4.000000');assert.equal(t.rejected_posted,'3.000000');assert.equal(t.rejected_selected,'3.000000');assert.equal(t.rejected_unposted,'2.000000');assert.equal(t.posted,'10.000000');
});
