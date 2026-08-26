import test from"node:test";import assert from"node:assert/strict";import{commercialTotals,lineAmountCents}from"../lib/purchase/money.ts";
test("quantity times rate is decimal-safe",()=>assert.equal(lineAmountCents("100","250.00"),2500000n));
test("required two-item commercial example",()=>assert.deepEqual(commercialTotals([{quantity:100,unit_rate:250},{quantity:50,unit_rate:500}],18,2000),{subtotalCents:5000000n,gstAmountCents:900000n,freightCents:200000n,grandTotalCents:6100000n}));
test("18 percent GST excludes freight",()=>assert.equal(commercialTotals([{quantity:1,unit_rate:100000}],18,5000).grandTotalCents,12300000n));
test("zero GST adds only freight",()=>assert.equal(commercialTotals([{quantity:1,unit_rate:100000}],0,5000).grandTotalCents,10500000n));
test("decimal GST percentage is supported",()=>assert.equal(commercialTotals([{quantity:1,unit_rate:10000}],7.5,0).gstAmountCents,75000n));