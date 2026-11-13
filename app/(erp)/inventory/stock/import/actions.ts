"use server";
import {randomUUID}from"node:crypto";
import {redirect}from"next/navigation";
import {revalidatePath}from"next/cache";
import {requireAdmin}from"@/lib/identity/data";
import {listWorkbookSheets,readWorkbook}from"@/lib/inventory/import/workbook";
import {openingError}from"@/lib/inventory/opening-stock/runner";
import type {OpeningEdit,OpeningResult}from"@/lib/inventory/opening-stock/types";
const path=(id:string)=>"/inventory/stock/import/"+id;
async function fileBytes(form:FormData){const file=form.get("workbook");if(!(file instanceof File)||!/\.xlsx$/i.test(file.name)||file.size>10*1024*1024)throw new Error("Select an XLSX workbook of at most 10 MB.");return {file,bytes:Buffer.from(await file.arrayBuffer())};}
export async function inspectOpeningWorkbook(form:FormData):Promise<OpeningResult>{
  try{await requireAdmin();const{bytes}=await fileBytes(form);return {sheets:await listWorkbookSheets(bytes)};}catch(e){return {error:(e as Error).message};}
}
export async function uploadOpeningWorkbook(form:FormData):Promise<OpeningResult>{
  let id:string;
  try{
    const{supabase}=await requireAdmin(),{file,bytes}=await fileBytes(form),sheet=String(form.get("sheet")||"");
    if(!sheet)return {error:"Select the worksheet before previewing."};
    const source=await readWorkbook(bytes,sheet);
    const{data,error}=await supabase.rpc("stage_opening_stock_workbook",{p_name:file.name,p_sha256:source.sha256,p_source_base64:bytes.toString("base64"),p_sheet:source.sheet,p_rows:source.rows}).retry(false);
    if(error||!data)return {error:openingError(error?.code,error?.message)};id=data;
  }catch(e){return {error:(e as Error).message};}
  return {import_id:id};
}
export async function reuseOpeningSource(_:OpeningResult,form:FormData):Promise<OpeningResult>{
  let id:string;
  try{const{supabase}=await requireAdmin();const{data,error}=await supabase.rpc("create_opening_stock_preview",{p_source:String(form.get("source")||"")}).retry(false);if(error||!data)return {error:openingError(error?.code,error?.message)};id=data;}catch(e){return {error:openingError(undefined,(e as Error).message)};}
  redirect(path(id));
}
export async function saveOpeningPreview(id:string,revision:number,_:OpeningResult,form:FormData):Promise<OpeningResult>{
  try{
    const{supabase}=await requireAdmin(),selected=new Set(form.getAll("selected").map(String)),changes:OpeningEdit[]=[];
    for(const[key,value]of form.entries())if(key.startsWith("qty:")){const row=key.slice(4);changes.push({row:Number(row),quantity:String(value).trim(),selected:selected.has(row),location:String(form.get("location:"+row)||"")||null});}
    const{error}=await supabase.rpc("edit_opening_stock_preview",{p_id:id,p_revision:revision,p_changes:changes}).retry(false);if(error)return {error:openingError(error.code,error.message)};
    revalidatePath(path(id));return {success:"Preview updated. Review quantities, validation and resulting balances before confirming."};
  }catch(e){return {error:openingError(undefined,(e as Error).message)};}
}
export async function refreshOpeningPreview(id:string,_:OpeningResult):Promise<OpeningResult>{
  void _;
  try{const{supabase}=await requireAdmin();const{error}=await supabase.rpc("refresh_opening_stock_preview",{p_id:id}).retry(false);if(error)return {error:openingError(error.code,error.message)};revalidatePath(path(id));return {success:"Pending rows refreshed. Previous approvals are superseded; review and approve again."};}catch(e){return {error:openingError(undefined,(e as Error).message)};}
}
export async function approveOpeningImport(id:string,revision:number,form:FormData):Promise<OpeningResult>{
  try{
    const{supabase}=await requireAdmin();const{data,error}=await supabase.rpc("approve_opening_stock_import",{p_id:id,p_revision:revision,p_request_key:String(form.get("request_key")||randomUUID()),p_effective_date:String(form.get("date")||""),p_reason:String(form.get("reason")||"").trim(),p_existing_policy:String(form.get("policy")||"SKIP"),p_batch_size:Number(form.get("batch_size")||100),p_acknowledge:form.get("acknowledge")==="on"}).retry(false);
    if(error||!data)return {error:openingError(error?.code,error?.message)};return {progress:data};
  }catch(e){return {error:openingError(undefined,(e as Error).message)};}
}
export async function getOpeningProgress(id:string):Promise<OpeningResult>{
  try{const{supabase}=await requireAdmin();const{data,error}=await supabase.rpc("opening_stock_progress",{p_id:id});if(error||!data)return {error:openingError(error?.code,error?.message)};return {progress:data};}catch(e){return {error:openingError(undefined,(e as Error).message)};}
}
export async function postOpeningChunk(id:string,chunk:string,key:string):Promise<OpeningResult>{
  const attempt=randomUUID();
  try{
    const{supabase}=await requireAdmin();const{data,error}=await supabase.rpc("process_opening_stock_chunk",{p_id:id,p_chunk:chunk,p_request_key:key,p_attempt_key:attempt}).retry(false);
    if(error){if(!["55P03","42501"].includes(error.code))await supabase.rpc("record_opening_stock_interruption",{p_id:id,p_chunk:chunk,p_request_key:key,p_attempt_key:attempt,p_code:error.code||"NETWORK"}).retry(false);return {error:openingError(error.code,error.message)};}
    for(const p of ["/inventory","/inventory/stock","/inventory/ledger"])revalidatePath(p);
    return {progress:data};
  }catch(e){
    try{const{supabase}=await requireAdmin();await supabase.rpc("record_opening_stock_interruption",{p_id:id,p_chunk:chunk,p_request_key:key,p_attempt_key:attempt,p_code:"NETWORK"}).retry(false);}catch{/* A later progress read reconciles an uncertain response. */}
    return {error:openingError(undefined,(e as Error).message)};
  }
}
export async function cancelOpeningImport(id:string,_:OpeningResult):Promise<OpeningResult>{
  void _;
  try{const{supabase}=await requireAdmin();const{error}=await supabase.rpc("cancel_opening_stock_import",{p_id:id}).retry(false);if(error)return {error:openingError(error.code,error.message)};revalidatePath(path(id));return {success:"Remaining rows cancelled. Existing ledger entries were preserved."};}catch(e){return {error:openingError(undefined,(e as Error).message)};}
}
