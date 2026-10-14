import Link from 'next/link';
import {createClient} from '@/lib/supabase/server';
export async function SavedFreight({packingListId,dispatchId}:{packingListId:string;dispatchId:string}){
 const db=await createClient();const {data,error}=await db.from('freight_calculations').select('*').eq('packing_list_id',packingListId).order('calculated_at',{ascending:false});
 if(error||!data?.length)return null;
 const attached=data.find(e=>e.dispatch_id===dispatchId),e=attached??data[0];
 return <section className="card p-5"><h2 className="font-semibold">{attached?'Attached Freight Estimate':'Latest Packing List Freight Estimate'}</h2><dl className="mt-3 grid gap-3 text-sm sm:grid-cols-3">{[['Freight',`₹${Number(e.total_freight).toLocaleString('en-IN')}`],['Chargeable Weight',`${e.chargeable_weight} kg`],['Transport Partner',e.transport_partner],['From PIN',e.from_pin],['To PIN',e.to_pin]].map(([label,value])=><div key={label}><dt className="text-slate-500">{label}</dt><dd className="font-semibold">{value}</dd></div>)}</dl>{!attached&&<p className="mt-3 text-xs text-slate-500">This quote covers the full Packing List. Attach it to a draft dispatch with all cartons selected to apply the freight.</p>}<Link className="mt-3 inline-block text-sm text-cyan-700 underline" href={`/dispatch/freight-calculator/${e.id}/summary`}>Freight Summary</Link><Link className="ml-4 text-sm text-cyan-700 underline" href={`/dispatch/freight-calculator?packing_list_id=${packingListId}`}>Freight Calculator</Link></section>;
}
