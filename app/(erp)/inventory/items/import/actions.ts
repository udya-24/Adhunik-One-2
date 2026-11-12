"use server";
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
    const { data, error } = await supabase.rpc("stage_item_import", { p_name: file.name, p_sha256: source.sha256, p_source_base64: bytes.toString("base64"), p_sheet: source.sheet, p_rows: source.rows });
    if (error || !data) throw new Error(error?.message || "Could not stage workbook."); id = data;
  } catch (e) { return { error: (e as Error).message }; }
  redirect("/inventory/items/import/" + id);
}
export async function commitItemWorkbook(id: string, revision: number, _: ImportActionState, form: FormData): Promise<ImportActionState> {
  try {
    const { supabase } = await requireAdmin();
    const rows = form.getAll("rows").map(Number);
    if (rows.some(n => !Number.isInteger(n))) throw new Error("Invalid selected rows.");
    const { error } = await supabase.rpc("commit_item_import", { p_id: id, p_revision: revision, p_rows: rows, p_acknowledge: form.get("acknowledge") === "on" });
    if (error) throw new Error(error.message);
    for (const path of ["/configuration", "/inventory/items", "/inventory/locations", "/inventory/items/import/" + id]) revalidatePath(path);
    return { success: "Product master import committed. Stock balances were not changed." };
  } catch (e) {
    const message = (e as Error).message;
    try { const { supabase } = await requireAdmin(); await supabase.rpc("record_item_import_failure", { p_id: id, p_message: message }); } catch { /* Authorization failures must not create audit events. */ }
    return { error: message };
  }
}
export async function refreshItemWorkbook(id: string, _: ImportActionState): Promise<ImportActionState> {
  void _;
  try {
    const { supabase } = await requireAdmin();
    const { error } = await supabase.rpc("refresh_item_import", { p_id: id }); if (error) throw new Error(error.message);
    revalidatePath("/inventory/items/import/" + id); return { success: "Preview refreshed. Review changes before confirmation." };
  } catch (e) { return { error: (e as Error).message }; }
}
export async function reviewStockProposal(id: string, action: string, revision: number | null, _: ImportActionState, form: FormData): Promise<ImportActionState> {
  try {
    const { supabase } = await requireAdmin();
    if (action === "REVIEW" && form.get("acknowledge") !== "on") throw new Error("Confirm that this review cannot authorize inventory posting.");
    const { error } = await supabase.rpc("review_item_import_stock", { p_batch: id, p_action: action, p_revision: revision, p_reason: String(form.get("reason") || "" ) });
    if (error) throw new Error(error.message);
    revalidatePath("/inventory/items/import/" + id); return { success: "Stock proposal " + action.toLowerCase() + " saved. Posting remains disabled." };
  } catch (e) { return { error: (e as Error).message }; }
}
