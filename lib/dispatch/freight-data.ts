import 'server-only';
import {createClient} from '@/lib/supabase/server';
import {weightLine,calculateFreight,freightConfig} from './freight';
export async function freightPacking(id:string){
 const db=await createClient();
 const [pl,items,cartons]=await Promise.all([db.from('packing_lists').select('*').eq('id',id).single(),db.from('packing_list_items').select('*').eq('packing_list_id',id).order('sort_order'),db.from('packing_list_packages').select('*').eq('packing_list_id',id).order('package_number')]);
 for(const result of [pl,items,cartons])if(result.error)throw new Error(result.error.message);
 if(pl.data!.status==='CANCELLED')throw new Error('Cancelled Packing Lists cannot be estimated.');
 const ids=[...new Set((items.data??[]).flatMap(i=>i.item_id?[i.item_id]:[]))];
 const [masters,prices]=await Promise.all([ids.length?db.from('items').select('id,item_name,length_mm,breadth_mm,height_mm,unit_weight_kg').in('id',ids):Promise.resolve({data:[],error:null}),db.from('proforma_invoice_items').select('id,quantity,line_total').eq('proforma_invoice_id',pl.data!.pi_id)]);
 for(const result of [masters,prices])if(result.error)throw new Error(result.error.message);
 const errors:string[]=[];
 const lines=(items.data??[]).filter(i=>Number(i.current_packing_quantity)>0).map(i=>{
  const master=masters.data?.find(m=>m.id===i.item_id),price=prices.data?.find(p=>p.id===i.pi_item_id);let weights=null;
  try{if(!master)throw new Error('Linked Item Master is missing.');weights=weightLine(master.length_mm,master.breadth_mm,master.height_mm,master.unit_weight_kg,Number(i.current_packing_quantity));}catch(e){errors.push(`${i.item_description_snapshot}: ${(e as Error).message}`);}
  if(!price||Number(price.quantity)<=0)errors.push(`${i.item_description_snapshot}: PI value is missing.`);
  return {name:i.item_description_snapshot,quantity:Number(i.current_packing_quantity),length:master?.length_mm,breadth:master?.breadth_mm,height:master?.height_mm,unit_weight:master?.unit_weight_kg,shipment_value:price&&Number(price.quantity)>0?Number(price.line_total)/Number(price.quantity)*Number(i.current_packing_quantity):0,weights};
 });
 const packages=(cartons.data??[]).map(c=>{let weights=null;try{weights=weightLine(c.length_mm,c.breadth_mm,c.height_mm,c.gross_weight_kg,1);}catch(e){errors.push(`Carton ${c.package_number}: ${(e as Error).message}`);}return {number:c.package_number,length:c.length_mm,breadth:c.breadth_mm,height:c.height_mm,weights};});
 if(!lines.length)errors.push('Packing List has no packed items.');if(!packages.length)errors.push('Packing List has no cartons.');
 const total=(rows:typeof lines|typeof packages)=>rows.reduce((a,r)=>({actual_weight:a.actual_weight+(r.weights?.actual_weight??0),volumetric_weight:a.volumetric_weight+(r.weights?.volumetric_weight??0),chargeable_weight:a.chargeable_weight+(r.weights?.chargeable_weight??0),volume_m3:a.volume_m3+(r.weights?.volume_m3??0)}),{actual_weight:0,volumetric_weight:0,chargeable_weight:0,volume_m3:0});
 return {packing:pl.data!,items:lines,cartons:packages,itemTotals:total(lines),cartonTotals:total(packages),shipmentValue:lines.reduce((s,i)=>s+i.shipment_value,0),errors};
}
export async function freightEstimate(id:string,from:string,to:string,partner=freightConfig.partner){
 const data=await freightPacking(id);if(data.errors.length)throw new Error(data.errors.join(' '));
 // Carton chargeable weights include packaging; item weights guard against understated gross weights.
 const weight=Math.max(data.cartonTotals.chargeable_weight,data.itemTotals.chargeable_weight);
 return {...calculateFreight(from,to,weight,data.shipmentValue,partner),packing_list_id:id,transport_partner:partner,from_pin:from,to_pin:to,actual_weight:Math.max(data.cartonTotals.actual_weight,data.itemTotals.actual_weight),volumetric_weight:Math.max(data.cartonTotals.volumetric_weight,data.itemTotals.volumetric_weight),calculation_snapshot:{...data,source:freightConfig.source,sha256:freightConfig.sha256}};
}
