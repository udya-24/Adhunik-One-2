import Link from "next/link";
import { requireAdmin } from "@/lib/identity/data";
import { PageHeader } from "@/components/ui/page-header";
import { UploadWorkbook } from "./forms";
import { formatDateTime } from "@/lib/formatting/date";
import { ImportOperationError, runImportQuery } from "@/lib/inventory/import/diagnostics";
export default async function ImportItems({searchParams}:{searchParams:Promise<{page?:string}>}) {
  const { supabase } = await requireAdmin(), query=await searchParams;
  const page=Math.max(0,Math.min(100000,Math.floor(Number(query.page)||0))),size=25;
  let rows:{id:string;source_name:string;state:string;created_at:string}[]=[],failure:string|undefined;
  try{
    const {data}=await runImportQuery("list_batches",()=>supabase.from("item_import_batches").select("id,source_name,state,created_at").eq("purpose","ITEM_MASTER").order("created_at", { ascending: false }).order("id",{ascending:false}).range(page*size,page*size+size));
    rows=data??[];
  }catch(error){if(!(error instanceof ImportOperationError))throw error;failure=error.message;}
  return <><PageHeader title="Item Master Excel Import" description="Import product masters. Opening and rejected stock require a separate administrator approval."/><UploadWorkbook/><section className="card mt-5 p-5"><h2 className="font-semibold">Recent import batches</h2>{failure&&<p role="alert" className="mt-3 text-red-700">{failure} No product or inventory changes were requested by this page.</p>}{rows.slice(0,size).map(b => <Link className="block border-b py-3 text-sm text-cyan-700" key={b.id} href={"/inventory/items/import/" + b.id}>{b.source_name} · {b.state} · {formatDateTime(b.created_at)}</Link>)}<div className="mt-4 flex gap-4 text-sm">{page>0&&<Link className="text-cyan-700" href={"?page="+(page-1)}>Previous</Link>}{rows.length>size&&<Link className="text-cyan-700" href={"?page="+(page+1)}>Next</Link>}</div><Link className="mt-4 inline-block text-sm text-cyan-700" href="/inventory/stock/import">Import opening and rejected stock separately</Link></section></>;
}
