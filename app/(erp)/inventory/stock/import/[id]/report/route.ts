import{requireAdmin}from"@/lib/identity/data";
import{readAll}from"@/lib/supabase/read-all";
import{decimal}from"@/lib/inventory/import/workbook";
import{reconcileOpeningStock}from"@/lib/inventory/opening-stock/reconciliation";
export async function GET(_:Request,{params}:{params:Promise<{id:string}>}){
 const{id}=await params,{supabase}=await requireAdmin();
 const{data:job,error}=await supabase.from("opening_stock_imports").select("*").eq("id",id).maybeSingle();if(error)return Response.json({error:"Could not read import"},{status:500});if(!job)return Response.json({error:"Import not found"},{status:404});
 const[{data:source},{data:rows},{data:chunks},{data:progress,error:progressError},{data:audit}]=await Promise.all([
  supabase.from("item_import_batches").select("source_name,source_sha256,sheet").eq("id",job.source_batch_id).single(),
  readAll(supabase.from("opening_stock_import_rows").select("*").eq("import_id",id).order("source_row")),
  readAll(supabase.from("opening_stock_posting_chunks").select("*").eq("import_id",id).order("revision").order("sequence")),
  supabase.rpc("opening_stock_progress",{p_id:id}),
  readAll(supabase.from("item_master_admin_activities").select("*").eq("batch_id",job.source_batch_id).order("created_at").order("id")),
 ]);
 if(progressError)return Response.json({error:"Could not read reconciliation"},{status:500});
 const by_unit=reconcileOpeningStock(rows,decimal);
 return new Response(JSON.stringify({job,source,progress,by_unit,rows,chunks,audit},null,2),{headers:{"Content-Type":"application/json","Content-Disposition":'attachment; filename="opening-stock-reconciliation.json"',"Cache-Control":"private, no-store"}});
}
