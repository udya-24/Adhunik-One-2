import test from 'node:test';
import assert from 'node:assert/strict';
import {runImportQuery,ImportOperationError,importAuditLabel} from '../lib/inventory/import/diagnostics.ts';
test('diagnostics identify the failing read without retrying or leaking backend details',async()=>{
 const logs=[];let calls=0;
 await assert.rejects(runImportQuery('load_preview_page',async()=>{calls++;return{data:null,error:{code:'57014',message:'private SQL and credentials'}};},x=>logs.push(x)),error=>error instanceof ImportOperationError&&error.code==='57014'&&error.message.includes('item_import_preview_page')&&!error.message.includes('private SQL'));
 assert.equal(calls,1);assert.equal(logs.length,1);assert.equal(logs[0].operation,'load_preview_page');assert.equal(logs[0].code,'57014');assert.ok(logs[0].reference);assert.ok(!JSON.stringify(logs).includes('credentials'));
});
test('successful reads preserve data; transport errors retain the operation and reference',async()=>{
 const data={id:'committed'},logs=[];assert.deepEqual((await runImportQuery('load_batch',async()=>({data,error:null}),x=>logs.push(x))).data,data);
 await assert.rejects(runImportQuery('list_batches',async()=>{throw new Error('secret transport URL');},x=>logs.push(x)),e=>e.code==='TRANSPORT'&&e.message.includes('Load recent import batches')&&!e.message.includes('secret'));
 assert.equal(logs.length,2);
});
test('schema mismatch is distinguished from timeout; historical errors remain clearly labeled',()=>{
 assert.match(new ImportOperationError('load_preview_page','PGRST202','reference').message,/migrations/);
 assert.match(importAuditLabel('IMPORT_ATTEMPT_FAILED'),/Historical failed attempt/);assert.equal(importAuditLabel('MASTER_IMPORT_COMPLETED'),'MASTER_IMPORT_COMPLETED');
});
