import 'server-only';
import{createClient}from'@/lib/supabase/server';
import type{PurchaseOrder}from'@/lib/database.types';
export type PurchaseOrderVersion=PurchaseOrder&{root_po_id:string;parent_po_id:string|null;revision_number:number;revision_reason:string|null;revised_at:string|null;revised_by:string|null};
export async function orderRevisionHistory(rootId:string){const db=await createClient();const{data,error}=await db.from('purchase_orders').select('*').eq('root_po_id',rootId).order('revision_number');if(error)throw new Error(error.message);const versions=(data??[])as unknown as PurchaseOrderVersion[],ids=[...new Set(versions.flatMap(x=>[x.created_by,x.confirmed_by,x.revised_by,x.approved_by].filter(Boolean)as string[]))];const{data:labels}=ids.length?await db.rpc('get_purchase_user_labels',{p_ids:ids}):{data:[]};return{versions,names:Object.fromEntries((labels??[]).map(x=>[x.auth_user_id,x.display_name]))}}
