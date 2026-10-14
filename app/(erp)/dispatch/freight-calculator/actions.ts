'use server';
import {crmIdentity} from '@/lib/crm/data';
import {assertEdit} from '@/lib/security/access';
import {freightEstimate} from '@/lib/dispatch/freight-data';
import {revalidatePath} from 'next/cache';
export type FreightState={error?:string;message?:string;savedId?:string;estimate?:Awaited<ReturnType<typeof freightEstimate>>};
export async function estimateFreight(_:FreightState,f:FormData):Promise<FreightState>{
 try{
 await assertEdit('dispatch.freight_calculator');const {db,user}=await crmIdentity();
 const estimate=await freightEstimate(String(f.get('packing_list_id')??''),String(f.get('from_pin')??'').trim(),String(f.get('to_pin')??'').trim(),String(f.get('transport_partner')??'').trim());
 if(f.get('intent')==='save'){
 const {data,error}=await db.from('freight_calculations').insert({...estimate,created_by:user.id}).select('id').single();
 if(error)throw new Error(error.message);revalidatePath('/dispatch/freight-calculator');return {estimate,savedId:data!.id};
 }return {estimate};
 }catch(e){return {error:(e as Error).message};}
}
export async function attachFreight(_:FreightState,f:FormData):Promise<FreightState>{
 try{await assertEdit('dispatch.freight_calculator');const {db}=await crmIdentity();const {data:stored,error:fetchError}=await db.from('freight_calculations').select('*').eq('id',String(f.get('estimate_id'))).single();if(fetchError||!stored)throw new Error(fetchError?.message??'Estimate unavailable.');const fresh=await freightEstimate(stored.packing_list_id,stored.from_pin,stored.to_pin,stored.transport_partner);if(fresh.total_freight!==Number(stored.total_freight)||JSON.stringify(fresh.calculation_snapshot)!==JSON.stringify(stored.calculation_snapshot)) {
 // JSONB key ordering differs; compare data after recursively sorting object keys.
 const stable=(value:unknown):string=>JSON.stringify(value,(_,v)=>v&&typeof v==='object'&&!Array.isArray(v)?Object.fromEntries(Object.entries(v).sort(([a],[b])=>a.localeCompare(b))):v);
 if(stable(fresh.calculation_snapshot)!==stable(stored.calculation_snapshot)||fresh.total_freight!==Number(stored.total_freight))throw new Error('Packing List, Item Master, PI values or tariff changed. Save a fresh estimate before attaching.');
 }const {error}=await db.rpc('attach_freight_estimate' as never,{p_estimate:String(f.get('estimate_id')),p_dispatch:String(f.get('dispatch_id'))} as never);if(error)throw new Error(error.message);revalidatePath('/dispatch/dispatches/'+String(f.get('dispatch_id')));revalidatePath('/dispatch/freight-calculator');return {message:'Freight estimate attached.'};}catch(e){return {error:(e as Error).message};}
}
