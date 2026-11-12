"use server";
import { requireAdmin } from "@/lib/identity/data";
import { revalidatePath } from "next/cache";
export type MasterActionState = { error?: string; success?: string; preview?: Record<string, unknown>; source?: string; target?: string };
export async function deleteConfiguration(master: string, id: string, _: MasterActionState): Promise<MasterActionState> {
  void _;
  try {
    const { supabase } = await requireAdmin();
    const { error } = await supabase.rpc("delete_item_configuration", { p_table: master, p_id: id }); if (error) throw new Error(error.message);
    revalidatePath("/configuration"); revalidatePath("/configuration/item-masters"); revalidatePath("/inventory/locations");
    return { success: "Unused value deleted; audit history retained." };
  } catch (e) { return { error: (e as Error).message }; }
}
export async function previewConsolidation(master: string, source: string, _: MasterActionState, form: FormData): Promise<MasterActionState> {
  try {
    const { supabase } = await requireAdmin(); const target = String(form.get("target") || "");
    const { data, error } = await supabase.rpc("preview_item_consolidation", { p_table: master, p_source: source, p_target: target });
    if (error) throw new Error(error.message); return { preview: data, source, target };
  } catch (e) { return { error: (e as Error).message }; }
}
export async function confirmConsolidation(master: string, source: string, target: string, preview: Record<string, unknown>, _: MasterActionState, form: FormData): Promise<MasterActionState> {
  try {
    const { supabase } = await requireAdmin();
    const { error } = await supabase.rpc("consolidate_item_configuration", { p_table: master, p_source: source, p_target: target, p_preview: preview, p_confirm: form.get("confirm") === "on" }); if (error) throw new Error(error.message);
    for (const p of ["/configuration", "/configuration/item-masters", "/inventory/items", "/inventory/locations"]) revalidatePath(p);
    return { success: "Eligible references moved to the confirmed target. Source deactivated; history retained." };
  } catch (e) { return { error: (e as Error).message }; }
}
