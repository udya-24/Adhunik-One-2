"use server";
import { runImportQuery, ImportOperationError } from "@/lib/inventory/import/diagnostics";
import type { ImportPreviewPage } from "@/lib/inventory/import/types";
import { randomUUID } from "node:crypto";
import { importErrorMessage } from "@/lib/inventory/import/runner";
import type { ImportStepResult } from "@/lib/inventory/import/runner";
import { redirect } from "next/navigation";
import { revalidatePath } from "next/cache";
import { requireAdmin } from "@/lib/identity/data";
import { readWorkbook } from "@/lib/inventory/import/workbook";
export type ImportActionState = { error?: string; success?: string };
export async function uploadItemWorkbook(_: ImportActionState, form: FormData): Promise<ImportActionState> {
  let id: string;
  try {
    const { supabase } = await requireAdmin();
    const file = form.get("workbook");
    if (!(file instanceof File) || !/\.xlsx$/i.test(file.name)) throw new Error("Select an XLSX workbook.");
    if (file.size > 10 * 1024 * 1024) throw new Error("Workbook must be at most 10 MB.");
    const bytes = Buffer.from(await file.arrayBuffer()), source = await readWorkbook(bytes);
    const { data, error } = await runImportQuery("stage_workbook",()=>supabase.rpc("stage_item_import", { p_name: file.name, p_sha256: source.sha256, p_source_base64: bytes.toString("base64"), p_sheet: source.sheet, p_rows: source.rows }).retry(false));
    if (error || !data) throw new Error(error?.message || "Could not stage workbook."); id = data;
  } catch (e) { return { error: (e as Error).message }; }
  redirect("/inventory/items/import/" + id);
}
export async function startItemWorkbook(id: string, revision: number, requestKey: string, form: FormData): Promise<ImportStepResult> {
  try {
    const {supabase} = await requireAdmin();
    const rows = form.getAll("rows").map(Number), size = Number(form.get("batch_size") || 100);
    if (rows.some(n => !Number.isInteger(n)) || !rows.length) return {error:"Select distinct valid source rows."};
    const {data, error} = await runImportQuery("start_import",()=>supabase.rpc("start_item_import_job",{p_batch:id,p_revision:revision,p_rows:rows,p_request_key:requestKey,p_batch_size:size,p_acknowledge:form.get("acknowledge")==="on"}).retry(false));
    if (error) return {error:importErrorMessage(error.code,error.message)};
    return {progress:data};
  } catch (e) { return {error:(e instanceof ImportOperationError?e.message:importErrorMessage(undefined,(e as Error).message))}; }
}
export async function resumeItemWorkbook(jobId: string, size: number): Promise<ImportStepResult> {
  try {
    const {supabase} = await requireAdmin();
    const {data,error} = await runImportQuery("resume_import",()=>supabase.rpc("resume_item_import_job",{p_job:jobId,p_batch_size:size}).retry(false));
    if(error)return {error:importErrorMessage(error.code,error.message)};
    return {progress:data};
  } catch(e) { return {error:(e instanceof ImportOperationError?e.message:importErrorMessage(undefined,(e as Error).message))}; }
}
export async function processItemWorkbookChunk(jobId: string, chunk: number, requestKey: string): Promise<ImportStepResult> {
  const attemptKey=randomUUID();
  try {
    const {supabase}=await requireAdmin();
    const {data}=await runImportQuery("post_chunk",()=>supabase.rpc("process_item_import_chunk",{p_job:jobId,p_chunk:chunk,p_request_key:requestKey,p_attempt_key:attemptKey}).retry(false));
    if(!data)throw new Error("Could not read saved import progress");
    if(data.state==="COMPLETED")for(const path of ["/configuration","/inventory/items","/inventory/locations"])revalidatePath(path);
    return {progress:data};
  } catch(e){
    // If transport failed after a commit, failure reconciliation is a no-op on that chunk.
    try{if(!(e instanceof ImportOperationError)||!["55P03","42501"].includes(e.code)){const {supabase}=await requireAdmin();await runImportQuery("record_interruption",()=>supabase.rpc("record_item_import_chunk_failure",{p_job:jobId,p_chunk:chunk,p_request_key:requestKey,p_attempt_key:attemptKey,p_code:e instanceof ImportOperationError?e.code:"NETWORK"}).retry(false));}}catch{/* On reconnect the durable job still provides safe resumption. */}
    return {error:(e instanceof ImportOperationError?e.message:importErrorMessage(undefined,(e as Error).message))};
  }
}
export async function refreshItemWorkbook(id: string, _: ImportActionState): Promise<ImportActionState> {
  void _;
  try {
    const { supabase } = await requireAdmin();
    const { error } = await runImportQuery("refresh_preview",()=>supabase.rpc("refresh_item_import",{ p_id: id }).retry(false)); if (error) throw new Error(error.message);
    revalidatePath("/inventory/items/import/" + id); return { success: "Preview refreshed. Review changes before confirmation." };
  } catch (e) { return { error: (e as Error).message }; }
}
export async function reviewStockProposal(id: string, action: string, revision: number | null, _: ImportActionState, form: FormData): Promise<ImportActionState> {
  try {
    const { supabase } = await requireAdmin();
    if (action === "REVIEW" && form.get("acknowledge") !== "on") throw new Error("Confirm that this review cannot authorize inventory posting.");
    const { error } = await runImportQuery("legacy_stock_review",()=>supabase.rpc("review_item_import_stock",{ p_batch: id, p_action: action, p_revision: revision, p_reason: String(form.get("reason") || "" ) }).retry(false));
    if (error) throw new Error(error.message);
    revalidatePath("/inventory/items/import/" + id); return { success: "Stock proposal " + action.toLowerCase() + " saved. Posting remains disabled." };
  } catch (e) { return { error: (e as Error).message }; }
}

export async function loadItemPreviewPage(id: string, revision: number, offset: number): Promise<{preview?:ImportPreviewPage;error?:string}> {
  try {
    const {supabase}=await requireAdmin();
    const {data}=await runImportQuery("load_preview_page",()=>supabase.rpc("item_import_preview_page",{p_batch:id,p_revision:revision,p_offset:offset,p_limit:100}));
    return data?{preview:data}:{error:"Saved preview was not found. Refresh the batch."};
  }catch(e){return {error:e instanceof Error?e.message:"Could not load preview page."};}
}
