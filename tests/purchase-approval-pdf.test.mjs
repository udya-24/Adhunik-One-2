import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import ts from 'typescript';
import {jsPDF} from 'jspdf';
import {autoTable} from 'jspdf-autotable';
import {formatDate} from '../lib/formatting/date.ts';
// Run the existing renderer without its server-only marker or Next path aliases.
const source=fs.readFileSync('lib/procurement/render-po-pdf.ts','utf8');
const compiled=ts.transpileModule(source,{compilerOptions:{target:ts.ScriptTarget.ES2020,module:ts.ModuleKind.CommonJS}}).outputText;
const exports={};
new Function('require','exports',compiled)(name=>{
 if(name==='server-only')return {};
 if(name==='@/lib/formatting/date')return {formatDate};
 if(name==='jspdf')return {jsPDF};
 if(name==='jspdf-autotable')return {__esModule:true,default:autoTable};
 throw new Error('Unexpected renderer dependency '+name);
},exports);
for(const status of ['CONFIRMED','APPROVED'])test(`${status} revised PO generates a downloadable PDF`,()=>{
 const bytes=exports.renderPurchaseOrderPdf({item:{po_number:'PO/2026/0042-Revised-02',po_date:'2026-10-10',revision_number:2,revision_reason:'Delivery changes',status,supplier_name_snapshot:'Test Supplier',billing_address_snapshot:'Billing Address',delivery_address_snapshot:'Delivery Address',subtotal:1000,gst_rate:18,gst_amount:180,freight_amount:20,grand_total:1200,expected_delivery_date:'2026-10-20'},indent:'IND/2026/0042',items:[{line_number:1,item_code_snapshot:'MAT-1',item_name_snapshot:'Material',quantity:100,unit_snapshot:'PCS',unit_rate:10,line_amount:1000}],settings:null,header:null});
 assert.ok(bytes instanceof Uint8Array);
 const pdf=Buffer.from(bytes).toString('latin1');
 assert.ok(pdf.startsWith('%PDF-'));
 assert.ok(pdf.includes('PO/2026/0042-Revised-02'));
 assert.ok(pdf.includes('%%EOF'));
});
