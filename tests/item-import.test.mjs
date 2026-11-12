import test from 'node:test';
import assert from 'node:assert/strict';
import JSZip from 'jszip';
import { readWorkbook, decimal, normalize, headers } from '../lib/inventory/import/workbook.ts';
const esc = s => String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('"','&quot;');
const col = n => String.fromCharCode(65+n);
async function workbook({ values, formulas={}, extra='', sheetCount=1, headerValues=headers }={}) {
 const zip=new JSZip();
 zip.file('xl/workbook.xml',`<workbook xmlns:r="relationships"><sheets><sheet name="Products" r:id="r1"/>${sheetCount>1?'<sheet name="Other" r:id="r2"/>':''}</sheets></workbook>`);
 zip.file('xl/_rels/workbook.xml.rels','<Relationships><Relationship Id="r1" Target="worksheets/sheet1.xml"/></Relationships>');
 const row=(n,arr)=>`<row r="${n}">${arr.map((s,i)=>`<c r="${col(i)}${n}" t="inlineStr"><is><t>${esc(s)}</t></is>${formulas[col(i)+n]?`<f>${esc(formulas[col(i)+n])}</f>`:''}</c>`).join('')}</row>`;
 zip.file('xl/worksheets/sheet1.xml',`<worksheet><sheetData>${row(1,headerValues)}${row(2,values||['CODE','A & B','Group','Type','Family','Store','PCS','Keep: active','10','2','1.23456','12.3456','2.46912','1',''])}</sheetData>${extra}</worksheet>`);
 return zip.generateAsync({type:'nodebuffer'});
}
test('decimal precision rounds COGS without binary floating-point arithmetic',()=>{
 assert.equal(decimal('1.23455',4).fixed,'1.2346');assert.equal(decimal('0',4).fixed,'0.0000');assert.equal(decimal('1.25000000000001e2',4).fixed,'125.0000');assert.equal(decimal('0.00005',4).fixed,'0.0001');assert.equal(decimal('2e2',4).fixed,'200.0000');assert.throws(()=>decimal('Infinity',4));assert.throws(()=>decimal('-1',4));assert.throws(()=>decimal('1e500',4));
});
test('normalization reconciles only case and whitespace',()=>{assert.equal(normalize('  Raw   Material\t'),'raw material');assert.notEqual(normalize('MCC'),normalize('SWITCHGEARS'));});
test('XLSX parser reads entities, original values and row numbers',async()=>{
 const parsed=await readWorkbook(await workbook());assert.equal(parsed.sheet,'Products');assert.equal(parsed.rows.length,1);assert.equal(parsed.rows[0].row,2);assert.equal(parsed.rows[0].raw['Item name'],'A & B');assert.equal(parsed.rows[0].raw['Rate (Rs)'],'1.23456');assert.equal(parsed.rows[0].issues.length,0);assert.ok(parsed.rows[0].warnings.some(w=>w.includes('rounds to 1.2346')));assert.match(parsed.sha256,/^[a-f0-9]{64}$/);
});
test('duplicate/missing headers and multi-sheet workbooks require explicit correction',async()=>{
 await assert.rejects(readWorkbook(await workbook({headerValues:[headers[0],...headers.slice(0,-1)]})),/duplicate header/);
 await assert.rejects(readWorkbook(await workbook({headerValues:headers.slice(1)})),/Required columns/);
 await assert.rejects(readWorkbook(await workbook({sheetCount:2})),/exactly one/);
});
test('formulas are restricted to same-row reconciliation multiplication',async()=>{
 let p=await readWorkbook(await workbook({formulas:{L2:'I2*K2',M2:'J2*K2'}}));assert.equal(p.rows[0].issues.length,0);
 p=await readWorkbook(await workbook({formulas:{A2:'NOW()',L2:'I3*K2'}}));assert.equal(p.rows[0].issues.length,2);
});
test('malformed/encrypted-style ZIP, DTD and oversized input are rejected',async()=>{
 await assert.rejects(readWorkbook(Buffer.from('not zip')));await assert.rejects(readWorkbook(Buffer.alloc(10*1024*1024+1)),/10 MB/);
 const z=new JSZip();z.file('xl/workbook.xml','<!DOCTYPE workbook><workbook/>');await assert.rejects(readWorkbook(await z.generateAsync({type:'nodebuffer'})),/entities/);
});
test('invalid numeric cells become row errors, blank optional group remains blank',async()=>{
 const p=await readWorkbook(await workbook({values:['CODE','Name','','Type','Family','Store','PCS','Status','-1','0','NaN','0','0','0','']}));assert.equal(p.rows[0].raw['Item group'],'');assert.ok(p.rows[0].issues.some(e=>e.includes('Opening qty')));assert.ok(p.rows[0].issues.some(e=>e.includes('Rate')));
});

test('Excel shared formulas expand only inside a validated same-column range', async()=>{
 const z=await JSZip.loadAsync(await workbook());
 let sheet=await z.file('xl/worksheets/sheet1.xml').async('string');
 sheet=sheet.replace('</sheetData>','<row r="3"><c r="L3"><f t="shared" si="0"/><v>12.3456</v></c><c r="M3"><f t="shared" si="1"/><v>2.46912</v></c></row></sheetData>');
 sheet=sheet.replace('<c r="L2" t="inlineStr">','<c r="L2" t="inlineStr"><f t="shared" si="0" ref="L2:L3">I2*K2</f>').replace('<c r="M2" t="inlineStr">','<c r="M2" t="inlineStr"><f t="shared" si="1" ref="M2:M3">J2*K2</f>');
 z.file('xl/worksheets/sheet1.xml',sheet);
 const p=await readWorkbook(await z.generateAsync({type:'nodebuffer'}));
 assert.equal(p.rows.length,2);assert.ok(!p.rows[1].issues.some(e=>e.includes('formula')));
 z.file('xl/worksheets/sheet1.xml',sheet.replace('L2:L3','L2:L2'));await assert.rejects(readWorkbook(await z.generateAsync({type:'nodebuffer'})),/shared formula reference/);
});

test('catalogue pagination makes all 1,994 products available and rejects partial failures',async()=>{
 const {readAll}=await import('../lib/supabase/read-all.ts');
 const products=Array.from({length:1994},(_,i)=>({id:String(i)}));
 const query={range:async(from,to)=>({data:products.slice(from,to+1),error:null})};
 const result=await readAll(query);assert.equal(result.data.length,1994);assert.equal(result.data[1993].id,'1993');
 const failed={range:async(from,to)=>from?{data:null,error:{message:'Read failed'}}:{data:products.slice(from,to+1),error:null}};
 await assert.rejects(readAll(failed),/Read failed/);
});
