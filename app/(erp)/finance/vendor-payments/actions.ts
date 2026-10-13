'use server';
import {assertEdit} from '@/lib/security/access';
import {createClient} from '@/lib/supabase/server';
import {uploadCommercialFile,removeCommercialFiles} from '@/lib/procurement/document-upload';
import {revalidatePath} from 'next/cache';
export async function recordVendorPayment(id:string,_:{error?:string},form:FormData){let path:string|undefined;try{await assertEdit('finance.vendor_payments');const proof=await uploadCommercialFile(form,'proof');path=proof?.path;const data=Object.fromEntries(['payment_date','payment_mode','bank','reference_number','utr_number','amount','remarks'].map(key=>[key,String(form.get(key)??'').trim()]));const db=await createClient();const{error}=await db.rpc('record_vendor_payment' as never,{p_id:id,p_data:{...data,proof_name:proof?.name,proof_path:proof?.path}} as never);if(error)throw new Error(error.message);}catch(e){if(path)await removeCommercialFiles([path]);return{error:(e as Error).message};}revalidatePath('/finance','layout');return{};}
