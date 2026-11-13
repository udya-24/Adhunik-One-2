import test from'node:test';
import assert from'node:assert/strict';
import{priceInput,inr}from'../lib/inventory/pricing/money.ts';
import{runPriceChunks,priceError}from'../lib/inventory/pricing/runner.ts';
test('prices retain legitimate zeros and exact four-decimal strings without inferring selling prices',()=>{
 assert.equal(priceInput('0'),'0.0000');assert.equal(priceInput(''),null);assert.equal(priceInput('99999999999.9999'),'99999999999.9999');assert.equal(priceInput('12.3456'),'12.3456');
 for(const s of['-1','Infinity','NaN','1.00001','100000000000'])assert.throws(()=>priceInput(s));
});
test('INR display rounds only the final decimal string, including amounts beyond JS safe integers',()=>{
 assert.equal(inr('16.9872021234'),'₹16.99');assert.equal(inr('99999999999.9999'),'₹1,00,00,00,00,000.00');assert.equal(inr('9007199254740993.005'),'₹9,00,71,99,25,47,40,993.01');assert.equal(inr('0'),'₹0.00');assert.equal(inr(null),'Unknown');
});
test('price runner posts sequentially, never retries uncertain writes and rejects stalled progress',async()=>{
 const p={id:'job',state:'RUNNING',posted:0,next:{id:'c',key:'k'}};let calls=0;
 await assert.rejects(runPriceChunks(p,async()=>{calls++;return{error:'timeout'};},()=>{}),/timeout/);assert.equal(calls,1);
 await assert.rejects(runPriceChunks(p,async()=>({progress:p}),()=>{}),/did not advance/);
 const done=await runPriceChunks(p,async()=>({progress:{...p,state:'COMPLETED',posted:1,next:null}}),()=>{});assert.equal(done.posted,1);assert.match(priceError('57014'),/rolled back/);assert.ok(!priceError('XX000','secret SQL').includes('secret'));
});
