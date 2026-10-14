import {jsPDF} from 'jspdf';
import autoTable from 'jspdf-autotable';
import type {FreightCalculation} from '@/lib/database.types';
import {formatDateTime} from '@/lib/formatting/date';
export function renderFreightSummary(e:FreightCalculation){
 const snapshot=e.calculation_snapshot as {packing?:{packing_list_number?:string;pi_number_snapshot?:string;order_number_snapshot?:string;customer_name_snapshot?:string};items?:{name:string;quantity:number}[]};
 const pdf=new jsPDF({unit:'mm',format:'a4'});
 pdf.setFontSize(16);pdf.text('ADHUNIK SWITCHGEARS - FREIGHT SUMMARY',14,18);pdf.setFontSize(9);
 const header=[`Packing List: ${snapshot.packing?.packing_list_number??e.packing_list_id}`,`Customer: ${snapshot.packing?.customer_name_snapshot??''}`,`PI: ${snapshot.packing?.pi_number_snapshot??''}   Order: ${snapshot.packing?.order_number_snapshot??''}`,`Partner: ${e.transport_partner}   Calculated: ${formatDateTime(e.calculated_at)}`,`From: ${e.from_pin} - ${e.origin_city}, ${e.origin_state}`,`To: ${e.to_pin} - ${e.destination_city}, ${e.destination_state}`,`Zone: ${e.zone}   Location: ${e.location_type}`];
 let y=27;for(const line of header){const lines=pdf.splitTextToSize(line,182);pdf.text(lines,14,y);y+=lines.length*5+2;}
 autoTable(pdf,{startY:y,head:[['Item','Packed Quantity']],body:(snapshot.items??[]).map(i=>[i.name,i.quantity]),styles:{fontSize:8},headStyles:{fillColor:[21,94,117]}});
 y=(pdf as unknown as {lastAutoTable:{finalY:number}}).lastAutoTable.finalY+6;
 const money=(v:number)=>Number(v).toLocaleString('en-IN',{maximumFractionDigits:2});
 autoTable(pdf,{startY:y,head:[['Freight Component','Value']],body:[['Actual weight (kg)',money(e.actual_weight)],['Volumetric weight (kg)',money(e.volumetric_weight)],['Chargeable weight (kg)',money(e.chargeable_weight)],['Rate (INR / kg)',money(e.rate)],['Shipment value (INR)',money(e.shipment_value)],['Base freight (INR)',money(e.base_freight)],['Fuel surcharge (INR)',money(e.fuel_charge)],['ODA (INR)',money(e.oda_charge)],['Insurance (INR)',money(e.insurance)],['Handling (INR)',money(e.handling_charge)],['Other charges (INR)',money(e.other_charge)],['GST (INR)',money(e.gst)],['Grand total (INR)',money(e.total_freight)]],styles:{fontSize:9},headStyles:{fillColor:[21,94,117]}});
 y=(pdf as unknown as {lastAutoTable:{finalY:number}}).lastAutoTable.finalY+8;if(y>270){pdf.addPage();y=20;}
 pdf.setFontSize(8);pdf.text(['Estimate for the full Packing List. Transit days unavailable.','Other charges include e-way bill charges and any minimum taxable freight adjustment.'],14,y);
 return new Uint8Array(pdf.output('arraybuffer'));
}
