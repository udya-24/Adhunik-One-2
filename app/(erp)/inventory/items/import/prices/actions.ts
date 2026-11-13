"use server";
import {randomUUID}from"node:crypto";
import {redirect}from"next/navigation";
import {revalidatePath}from"next/cache";
import {requireAdmin}from"@/lib/identity/data";
import {readWorkbook}from"@/lib/inventory/import/workbook";
import {priceError}from"@/lib/inventory/pricing/runner";
import type{PriceResult}from"@/lib/inventory/pricing/types";
export async function uploadPrices(_:PriceResult,f:FormData):Promise<PriceResult>{
 let id:string;
 try{const{supabase}=await requireAdmin(),file=f.get("workbook");if(!(file instanceof File)||!file.name.toLowerCase().endsWith(".xlsx")||file.size>10485760)return{error:"Choose the original XLSX workbook, at most 10 MB."};const bytes=Buffer.from(await file.arrayBuffer()),book=await readWorkbook(bytes);const{data,error}=await supabase.rpc("stage_item_price_import",{p_name:file.name,p_sha256:book.sha256,p_sheet:book.sheet,p_source_base64:bytes.toString("base64"),p_rows:book.rows}).retry(false);if(error||!data)return{error:priceError(error?.code,error?.message)};id=data;}catch{return{error:"Price preview could not be created. Check recent price imports before uploading again."};}
 redirect("/inventory/items/import/prices/"+id);
}
export async function reusePrices(_:PriceResult,f:FormData):Promise<PriceResult>{
 const{supabase}=await requireAdmin();const{data,error}=await supabase.rpc("reuse_item_price_source",{p_source:String(f.get("source")||"")}).retry(false);if(error||!data)return{error:priceError(error?.code,error?.message)};redirect("/inventory/items/import/prices/"+data);
}
export async function pricePage(id:string,offset:number):Promise<PriceResult>{try{const{supabase}=await requireAdmin();const{data,error}=await supabase.rpc("item_price_page",{p_id:id,p_offset:offset});return error||!data?{error:priceError(error?.code,error?.message)}:{page:data};}catch{return{error:"Saved price preview could not be loaded."};}}
export async function approvePrices(id:string,revision:number,rows:number[],reason:string):Promise<PriceResult>{try{const{supabase}=await requireAdmin();const{data,error}=await supabase.rpc("approve_item_price_import",{p_id:id,p_revision:revision,p_rows:rows,p_reason:reason,p_request_key:randomUUID()}).retry(false);return error||!data?{error:priceError(error?.code,error?.message)}:{progress:data};}catch{return{error:"Approval request interrupted. Refresh saved progress before approving again."};}}
export async function readPriceProgress(id:string):Promise<PriceResult>{const{supabase}=await requireAdmin();const{data,error}=await supabase.rpc("item_price_progress",{p_id:id});return error||!data?{error:priceError(error?.code,error?.message)}:{progress:data};}
export async function refreshPrices(id:string,_:PriceResult):Promise<PriceResult>{void _;const{supabase}=await requireAdmin();const{error}=await supabase.rpc("refresh_item_price_import",{p_id:id}).retry(false);if(error)return{error:priceError(error.code,error.message)};revalidatePath("/inventory/items/import/prices/"+id);return{};}
export async function processPriceChunk(id:string,chunk:string,key:string):Promise<PriceResult>{
 const{supabase}=await requireAdmin();
 try{const{data,error}=await supabase.rpc("process_item_price_chunk",{p_id:id,p_chunk:chunk,p_key:key}).retry(false);if(error){if(!["55P03","42501"].includes(error.code))await supabase.rpc("interrupt_item_price_import",{p_id:id,p_chunk:chunk,p_key:key}).retry(false);return{error:priceError(error.code,error.message)};}
 for(const path of["/inventory","/inventory/items","/inventory/stock"])revalidatePath(path);revalidatePath("/inventory/items/[id]","page");revalidatePath("/inventory/stock/[id]","page");return{progress:data};}
 catch{try{await supabase.rpc("interrupt_item_price_import",{p_id:id,p_chunk:chunk,p_key:key}).retry(false);}catch{/* A later progress read resolves lost successful responses. */}return{error:"Price request interrupted. Refresh saved progress; successful batches are preserved."};}
}
