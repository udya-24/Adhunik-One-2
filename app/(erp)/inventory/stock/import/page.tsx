import Link from"next/link";
import{requireAdmin}from"@/lib/identity/data";
import{PageHeader}from"@/components/ui/page-header";
import{formatDateTime}from"@/lib/formatting/date";
import{OpeningUpload,ReuseSource}from"./forms";
export default async function OpeningStockHome(){
 const{supabase}=await requireAdmin();
 const[{data:sources,error:sourceError},{data:imports,error:importError}]=await Promise.all([
  supabase.from("item_import_batches").select("id,source_name,sheet").eq("purpose","ITEM_MASTER").eq("state","COMMITTED").order("created_at",{ascending:false}).limit(50),
  supabase.from("opening_stock_imports").select("*").order("created_at",{ascending:false}).limit(50),
 ]);
 return <><PageHeader title="Import Opening Stock from Excel"description="Separate usable opening quantities from Item Master import and rejected-stock review."/><Link className="text-cyan-700"href="/inventory/stock">Back to Stock Register</Link>{(sourceError||importError)&&<p className="my-4 rounded bg-red-50 p-3 text-red-700">Opening stock import is unavailable. Apply migration 202611120003 to the local test database first.</p>}<div className="my-4 grid gap-4 lg:grid-cols-2"><OpeningUpload/><ReuseSource sources={sources||[]}/></div><section className="card p-5"><h2 className="font-semibold">Opening stock history</h2>{imports?.map(j=><Link className="block border-b py-3 text-sm text-cyan-700"key={j.id}href={"/inventory/stock/import/"+j.id}>{j.id.slice(0,8)} · {j.state} · {formatDateTime(j.created_at)}</Link>)}</section></>;
}
