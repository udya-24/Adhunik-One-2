import test from'node:test';
import assert from'node:assert/strict';
import {runImportChunks,importErrorMessage}from'../lib/inventory/import/runner.ts';
const p=(completed=0,state='RUNNING')=>({id:'job',completed,state,next:state==='COMPLETED'?null:{chunk_number:completed+1,request_key:'key'+completed}});
test('runner advances sequentially once per committed chunk and reports progress',async()=>{
 const called=[],seen=[];const result=await runImportChunks(p(),async current=>{called.push(current.next.chunk_number);return {progress:p(current.completed+1,current.completed===1?'COMPLETED':'RUNNING')};},x=>seen.push(x.completed));assert.deepEqual(called,[1,2]);assert.deepEqual(seen,[0,1,2]);assert.equal(result.state,'COMPLETED');
});
test('runner never automatically retries a failed or uncertain request',async()=>{
 let count=0;await assert.rejects(runImportChunks(p(),async()=>{count++;return {error:'Request timed out'};},()=>{}),/timed out/);assert.equal(count,1);
});
test('runner stops when the database pauses a failed batch',async()=>{
 let count=0;const result=await runImportChunks(p(),async()=>{count++;return {progress:p(0,'PAUSED')};},()=>{});assert.equal(result.state,'PAUSED');assert.equal(count,1);
});
test('completed jobs are never reprocessed and stalled responses cannot create an infinite retry loop',async()=>{
 let count=0;await runImportChunks(p(2,'COMPLETED'),async()=>{count++;},()=>{});assert.equal(count,0);await assert.rejects(runImportChunks(p(),async()=>({progress:p()}),()=>{}),/did not advance/);
});
test('database error presentation is actionable and hides SQL internals',()=>{
 assert.match(importErrorMessage('57014','select private_table SECRET'),/time limit/);assert.match(importErrorMessage('55P03'),/Another request/);assert.match(importErrorMessage('23505'),/duplicate/);assert.match(importErrorMessage('42501'),/administrator/);assert.ok(!importErrorMessage('XX000','secret SQL and credentials').includes('secret'));assert.match(importErrorMessage('P0001','Import review required: source row 5 conflicts'),/source row 5/);
});
