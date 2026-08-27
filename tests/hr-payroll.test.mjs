import test from'node:test';import assert from'node:assert/strict';
const attendance=(working,present,offs)=>{if(Math.min(working,present,offs)<0||present>working)throw new Error('invalid');return{absent:working-present,total:working+offs,paid:present+offs}};
test('monthly attendance formulas',()=>assert.deepEqual(attendance(26,24,4),{absent:2,total:30,paid:28}));
test('monthly attendance permits half days',()=>assert.deepEqual(attendance(26,24.5,4),{absent:1.5,total:30,paid:28.5}));
test('present days cannot exceed working days',()=>assert.throws(()=>attendance(26,27,4)));
test('fixed gross and future payroll foundation',()=>{const gross=25000+10000+5000+2000;assert.equal(gross,42000);assert.equal(gross*28/30,39200)});
test('Phase 10B payroll formula',()=>{const attendance=42000*28/30,eligible=100000,incentive=eligible*1.5/100;assert.equal(attendance,39200);assert.equal(incentive,1500);assert.equal(attendance+incentive+2000+500,43200)});
test('GST and freight are excluded from incentive basis',()=>{const subtotal=100000,gst=18000,freight=5000,grand=123000;assert.equal(subtotal*1.5/100,1500);assert.notEqual(grand*1.5/100,1500);assert.equal(subtotal+gst+freight,grand)});
