import { requireAdmin } from "@/lib/identity/data";
export async function GET(_: Request, { params }: { params: Promise<{ id: string }> }) {
  const { supabase } = await requireAdmin(), { id } = await params;
  const { data, error } = await supabase.from("item_import_batches").select("id,source_name,source_sha256,sheet,revision,state,preview,result,created_at,committed_at").eq("id", id).maybeSingle();
  if (error) return Response.json({ error: error.message }, { status: 500 });
  if (!data) return Response.json({ error: "Import not found" }, { status: 404 });
  return new Response(JSON.stringify(data, null, 2), { headers: { "Content-Type": "application/json", "Content-Disposition": 'attachment; filename="item-import-report.json"', "Cache-Control": "private, no-store" } });
}
