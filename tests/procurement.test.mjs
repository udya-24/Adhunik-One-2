import test from"node:test";import assert from"node:assert/strict";import{receiptBalance,validateQuality}from"../lib/procurement/receipt.ts";
test("partial receipt tracks received and pending",()=>assert.deepEqual(receiptBalance(100,0,60),{totalReceived:60,pending:40,status:"PARTIALLY_RECEIVED"}));
test("second receipt fully receives PO",()=>assert.deepEqual(receiptBalance(100,60,40),{totalReceived:100,pending:0,status:"FULLY_RECEIVED"}));
test("over receipt is blocked",()=>assert.throws(()=>receiptBalance(100,100,1),/Over-receipt/));
test("accepted and rejected must equal receipt",()=>{assert.equal(validateQuality(100,95,5),true);assert.equal(validateQuality(100,95,4),false)});