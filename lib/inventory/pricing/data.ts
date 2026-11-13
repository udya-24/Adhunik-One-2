import "server-only";
import {createClient}from"@/lib/supabase/server";
import {readAll}from"@/lib/supabase/read-all";
export async function valuationRows(filters:{location?:string;classification?:string;items?:string[]}={}){
 const db=await createClient();const{data}=await readAll(db.rpc("inventory_valuation_rows",{p_location:filters.location||undefined,p_classification:filters.classification||undefined,p_items:filters.items}).order("item_id").order("location_id",{nullsFirst:true}));return data;
}
export async function valuationSummary(filters:{location?:string;classification?:string;items?:string[]}={}){
 const db=await createClient();const{data,error}=await db.rpc("inventory_valuation_summary",{p_location:filters.location||undefined,p_classification:filters.classification||undefined,p_items:filters.items});if(error||!data)throw new Error("Inventory valuation could not be read. Check the pricing/valuation migration and access permissions.");return data;
}

export async function itemValuations(ids:string[],location?:string){
 if(!ids.length)return [];
 const db=await createClient();const{data,error}=await db.rpc("item_pricing_valuation",{p_items:ids,p_location:location||undefined});if(error)throw new Error("Item pricing and valuation could not be loaded. Check the pricing migration.");return data??[];
}
