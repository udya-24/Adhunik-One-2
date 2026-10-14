import workbook from './freight-workbook.json';
export type FreightPin = {city:string;state:string;zone:string;location_type:string|null;source_row:string};
export const freightConfig = workbook as unknown as {source:string;sha256:string;partner:string;rules:{kg_per_cubic_foot:number;minimum_weight:number;fuel_percent:number;insurance_percent:number;minimum_insurance:number;oda_per_kg:number;minimum_oda:number;eway_charge:number;minimum_taxable:number;gst_percent:number};rates:{name:string;zone:string;type:string;rate:number}[];pins:Record<string,FreightPin>;city_zones:Record<string,string>};
export function lookupPin(pin:string){if(!/^[1-9]\d{5}$/.test(pin))throw new Error('Enter a valid six-digit PIN code.');const found=freightConfig.pins[pin];if(!found)throw new Error(`PIN ${pin} is absent from the workbook PIN master.`);return found;}
export function weightLine(length:number|null,breadth:number|null,height:number|null,unitWeight:number|null,quantity:number){
 if(!Number.isFinite(quantity)||quantity<=0)throw new Error('Packed quantity must be positive.');
 if([length,breadth,height,unitWeight].some(v=>v===null||!Number.isFinite(v)||v<=0))throw new Error('Positive dimensions and weight are required. Update Item Master or Packing List.');
 const volume=Number(length)*Number(breadth)*Number(height)*quantity/1e9;
 const actual=Number(unitWeight)*quantity,volumetric=volume/(0.0254**3*1728)*freightConfig.rules.kg_per_cubic_foot;
 return {actual_weight:actual,volume_m3:volume,volumetric_weight:volumetric,chargeable_weight:Math.max(actual,volumetric)};
}
export function calculateFreight(from:string,to:string,weight:number,value:number,partner:string){
 const origin=lookupPin(from),destination=lookupPin(to);
 if(partner.trim().toLowerCase()!==freightConfig.partner.toLowerCase())throw new Error('No workbook tariff is available for this transport partner.');
 if(!Number.isFinite(weight)||weight<=0||!Number.isFinite(value)||value<=0)throw new Error('Positive shipment weight and value are required.');
 const zone=freightConfig.city_zones[destination.city.toLowerCase()];
 const rate=freightConfig.rates.find(r=>r.zone===zone)?.rate;
 if(rate===undefined)throw new Error('Destination zone has no valid workbook rate.');
 if(!['ODA','NOT ODA'].includes(destination.location_type??''))throw new Error('Destination ODA classification is missing from the workbook lookup sheet.');
 const r=freightConfig.rules,chargeable_weight=Math.max(r.minimum_weight,Math.round(weight)),base_freight=Math.round(chargeable_weight*rate);
 const fuel_charge=Math.round(base_freight*r.fuel_percent/100),oda_charge=destination.location_type==='ODA'?Math.max(r.minimum_oda,chargeable_weight*r.oda_per_kg):0;
 const insurance=Math.max(r.minimum_insurance,Math.round(value*r.insurance_percent/100));
 const subtotal=base_freight+fuel_charge+oda_charge+insurance+r.eway_charge;
 const handling_charge=0,other_charge=r.eway_charge+Math.max(0,r.minimum_taxable-subtotal),taxable=subtotal+Math.max(0,r.minimum_taxable-subtotal),gst=Math.round(taxable*r.gst_percent/100);
 return {origin_city:origin.city,destination_city:destination.city,origin_state:origin.state,destination_state:destination.state,zone,location_type:destination.location_type!,chargeable_weight,rate,shipment_value:value,base_freight,fuel_charge,oda_charge,insurance,handling_charge,other_charge,gst,total_freight:taxable+gst,transit_days:null};
}
