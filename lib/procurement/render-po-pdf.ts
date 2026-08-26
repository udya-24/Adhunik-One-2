import 'server-only';
import { jsPDF } from 'jspdf';
import autoTable from 'jspdf-autotable';
import type { AwaitedReturn } from './types';
import type { PurchaseOrderVersion } from './revisions';
const plain=(x:number)=>new Intl.NumberFormat('en-IN',{minimumFractionDigits:2}).format(Number(x));
export function renderPurchaseOrderPdf(d:AwaitedReturn){
 const p=d.item! as PurchaseOrderVersion,doc=new jsPDF({unit:'mm',format:'a4'});let y=14;
 if(d.header){try{const q=doc.getImageProperties(d.header),w=180,h=Math.min(34,w*q.height/q.width);doc.addImage(d.header,q.fileType,15,y,w,h);y+=h+4}catch{}}
 doc.setFont('helvetica','bold');doc.setFontSize(16);doc.text('PURCHASE ORDER',105,y,{align:'center'});y+=8;doc.setFontSize(9);
 const identity=[['PO Number',p.po_number,'PO Date',p.po_date],['Source Indent',d.indent,'',''],['Supplier',p.supplier_name_snapshot,'GSTIN',p.supplier_gstin_snapshot??'-'],['Contact',p.supplier_contact_snapshot??'-','Phone',p.supplier_phone_snapshot??'-'],['Supplier Address',p.supplier_address_snapshot??'-','','']];
 if(p.revision_number>0)identity.splice(1,0,['Revision',String(p.revision_number).padStart(2,'0'),'Revision Reason',p.revision_reason??'-']);
 autoTable(doc,{startY:y,body:identity,theme:'grid',styles:{fontSize:8}});y=(doc as unknown as{lastAutoTable:{finalY:number}}).lastAutoTable.finalY+4;
 autoTable(doc,{startY:y,head:[['BILLING ADDRESS','DELIVERY ADDRESS']],body:[[p.billing_address_snapshot,p.delivery_address_snapshot]],theme:'grid',styles:{fontSize:8}});y=(doc as unknown as{lastAutoTable:{finalY:number}}).lastAutoTable.finalY+5;
 autoTable(doc,{startY:y,head:[['#','Item','Description','HSN','Qty','Unit','Rate','Amount']],body:d.items.map(x=>[x.line_number,`${x.item_code_snapshot??''} ${x.item_name_snapshot}`,x.description_snapshot??'-',x.hsn_code_snapshot??'-',x.quantity,x.unit_snapshot,plain(x.unit_rate),plain(x.line_amount)]),theme:'grid',showHead:'everyPage',styles:{fontSize:7},headStyles:{fillColor:[8,105,125]}});y=(doc as unknown as{lastAutoTable:{finalY:number}}).lastAutoTable.finalY+5;
 autoTable(doc,{startY:y,body:[['Subtotal',plain(p.subtotal)],[`GST ${p.gst_rate}%`,plain(p.gst_amount)],['Freight',plain(p.freight_amount)],['GRAND TOTAL',plain(p.grand_total)]],theme:'plain',tableWidth:90,margin:{left:105},columnStyles:{0:{fontStyle:'bold',halign:'right'},1:{halign:'right'}}});y=(doc as unknown as{lastAutoTable:{finalY:number}}).lastAutoTable.finalY+5;
 autoTable(doc,{startY:y,body:[['Payment Terms',p.payment_terms??'-'],['Delivery Terms',p.delivery_terms??'-'],['Expected Delivery',p.expected_delivery_date??'-'],['Remarks',p.remarks??'-'],['Terms & Conditions',p.terms_conditions??'-']],theme:'grid',styles:{fontSize:8},columnStyles:{0:{fontStyle:'bold',cellWidth:38}}});
 doc.setFontSize(7);doc.text([d.settings?.company_display_name,d.settings?.registered_office_address,d.settings?.gstin&&`GSTIN: ${d.settings.gstin}`,d.settings?.phone,d.settings?.email].filter(Boolean).join(' · '),105,288,{align:'center',maxWidth:180});return new Uint8Array(doc.output('arraybuffer'));
}
