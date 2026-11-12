import { readAll } from "@/lib/supabase/read-all";
import { requireAdmin } from "@/lib/identity/data";
export async function GET(_: Request, { params }: { params: Promise<{ id: string }> }) {
  const { supabase } = await requireAdmin(), { id } = await params;
  const { data, error } = await supabase.from("item_import_batches").select("id,source_name,source_sha256,sheet,revision,state,preview,result,created_at,committed_at").eq("id", id).maybeSingle();
  if (error) return Response.json({ error: error.message }, { status: 500 });
  if (!data) return Response.json({ error: "Import not found" }, { status: 404 });
  const {data:job,error:jobError}=await supabase.from("item_import_jobs").select("id").eq("batch_id",id).maybeSingle();
  if(jobError)return Response.json({error:"Could not read job audit"},{status:500});
  const {data:progress,error:progressError}=job?await supabase.rpc("item_import_job_progress",{p_job:job.id}):{data:null,error:null};
  const {data:chunks}=job?await readAll(supabase.from("item_import_job_chunks").select("*").eq("job_id",job.id).order("chunk_number")): {data:[]};
  if(progressError)return Response.json({error:"Could not read batch audit"},{status:500});
  return new Response(JSON.stringify({...data,progress,chunks}, null, 2), { headers: { "Content-Type": "application/json", "Content-Disposition": 'attachment; filename="item-import-report.json"', "Cache-Control": "private, no-store" } });
}
