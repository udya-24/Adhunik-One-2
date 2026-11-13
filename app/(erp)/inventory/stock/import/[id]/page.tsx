import Link from"next/link";
import{notFound}from"next/navigation";
import{requireAdmin}from"@/lib/identity/data";
import{readAll}from"@/lib/supabase/read-all";
import{stockLocations}from"@/lib/inventory/stock";
import{PageHeader}from"@/components/ui/page-header";
import{indiaDateInput,formatDateTime}from"@/lib/formatting/date";
import{OpeningReview}from"../forms";
export default async function OpeningImportPage({params}:{params:Promise<{id:string}>}){
 const{id}=await params,{supabase}=await requireAdmin();
 const{data:job,error}=await supabase.from("opening_stock_imports").select("*").eq("id",id).maybeSingle();if(error)throw new Error("Could not read opening stock import");if(!job)notFound();
 const[{data:source},{data:rows},{data:progress,error:progressError},locations,{data:audit}]=await Promise.all([
  supabase.from("item_import_batches").select("source_name,source_sha256,sheet").eq("id",job.source_batch_id).single(),
  readAll(supabase.from("opening_stock_import_rows").select("*").eq("import_id",id).order("source_row")),
  supabase.rpc("opening_stock_progress",{p_id:id}),stockLocations(true),
  supabase.from("item_master_admin_activities").select("*").eq("batch_id",job.source_batch_id).order("created_at",{ascending:false}).limit(100),
 ]);
 if(progressError||!progress||!source)throw new Error("Could not read stock source or progress. Refresh before any retry.");
 return <><PageHeader title={source.source_name+" · Opening Stock"}description={source.sheet+" · "+progress.total+" records · revision "+job.revision}/><div className="my-3 flex gap-4 text-sm"><Link className="text-cyan-700"href="/inventory/stock/import">Opening stock history</Link><Link className="text-cyan-700"href="/inventory/stock">Stock Register</Link><a className="text-cyan-700"href={"/inventory/stock/import/"+id+"/report"}>Download reconciliation and audit report</a></div><p className="my-3 break-all text-xs text-slate-500">Source batch {job.source_batch_id} · SHA-256 {source.source_sha256}</p><OpeningReview key={job.id+":"+job.revision+":"+job.state+":"+progress.posted}job={job}rows={rows}locations={locations.rows}initial={progress}today={indiaDateInput()}/><section className="card mt-5 p-5"><h2 className="font-semibold">Source and import audit (latest 100 source events)</h2>{audit?.map(a=><details className="border-b py-3 text-sm"key={a.id}><summary>{a.event_type} · {formatDateTime(a.created_at)} · {a.created_by}</summary><pre className="overflow-auto text-xs">{JSON.stringify(a.details,null,2)}</pre></details>)}</section></>;
}
