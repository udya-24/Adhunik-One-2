import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import ts from 'typescript';
const workbook=JSON.parse(fs.readFileSync('lib/dispatch/freight-workbook.json','utf8'));
const source=fs.readFileSync('lib/dispatch/freight.ts','utf8');
const js=ts.transpileModule(source,{compilerOptions:{module:ts.ModuleKind.CommonJS,target:ts.ScriptTarget.ES2020,esModuleInterop:true}}).outputText;
const mod={exports:{}};new Function('exports','module','require',js)(mod.exports,mod,()=>workbook);
const {calculateFreight,weightLine,lookupPin}=mod.exports;
test('matches every cached Summary value in supplied workbook reference',()=>{
 const r=calculateFreight('131029','360024',1000,150000,'Delhivery');
 assert.equal(r.zone,'W2');assert.equal(r.rate,12);assert.equal(r.chargeable_weight,1000);
 assert.equal(r.base_freight,12000);assert.equal(r.fuel_charge,1800);assert.equal(r.oda_charge,0);assert.equal(r.insurance,300);assert.equal(r.other_charge,150);assert.equal(r.gst,2565);assert.equal(r.total_freight,16815);
});
test('uses workbook box inches formula after converting Item Master millimetres',()=>{
 const r=weightLine(25*25.4,11*25.4,9*25.4,5.6,1);
 assert.ok(Math.abs(r.volumetric_weight-8.59375)<1e-10);assert.equal(r.actual_weight,5.6);assert.equal(r.chargeable_weight,r.volumetric_weight);
 const items=weightLine(25*25.4,11*25.4,9*25.4,5.6,50);assert.equal(items.actual_weight,280);assert.ok(Math.abs(items.volumetric_weight-429.6875)<1e-9);
});
test('chooses actual weight when heavier',()=>assert.equal(weightLine(100,100,100,10,2).chargeable_weight,20));
test('minimum billing weight, insurance, taxable freight and GST match formulas',()=>{
 const r=calculateFreight('131029','110001',1,1,'Delhivery');assert.equal(r.chargeable_weight,20);assert.equal(r.insurance,100);assert.equal(r.total_freight,708);assert.equal(r.gst,108);
});
test('ODA per kg and minimum are applied',()=>{
 const pin=Object.keys(workbook.pins).find(pin=>workbook.pins[pin].location_type==='ODA'&&workbook.rates.some(r=>r.zone===workbook.city_zones[workbook.pins[pin].city.toLowerCase()]));
 assert.ok(pin);assert.equal(calculateFreight('131029',pin,20,10000,'Delhivery').oda_charge,500);assert.equal(calculateFreight('131029',pin,200,10000,'Delhivery').oda_charge,600);
});
test('billing uses Excel ROUND rather than always rounding up',()=>{
 assert.equal(calculateFreight('131029','360024',20.49,1000,'Delhivery').chargeable_weight,20);assert.equal(calculateFreight('131029','360024',20.5,1000,'Delhivery').chargeable_weight,21);
});
test('imports all original PIN rows and uses the referenced ODA sheet',()=>{
 assert.equal(Object.keys(workbook.pins).length,21761);assert.equal(lookupPin('131029').state,'Haryana');assert.equal(lookupPin('360024').city,'Rajkot');assert.equal(lookupPin('360024').location_type,'NOT ODA');
});
test('rejects missing data and unsupported tariffs instead of guessing',()=>{
 assert.throws(()=>lookupPin('123'),/valid/);assert.throws(()=>lookupPin('999999'),/absent/);assert.throws(()=>calculateFreight('131029','360024',20,1000,'Other'),/tariff/);
 assert.throws(()=>weightLine(null,100,100,1,1),/dimensions/);assert.throws(()=>weightLine(100,100,100,null,1),/weight/);assert.throws(()=>weightLine(100,100,100,1,0),/quantity/);assert.throws(()=>calculateFreight('131029','360024',NaN,1000,'Delhivery'),/Positive/);
});
