import Link from "next/link";
import { requireAdmin } from "@/lib/identity/data";
import { PageHeader } from "@/components/ui/page-header";
import { UploadWorkbook } from "./forms";
import { formatDateTime } from "@/lib/formatting/date";
export default async function ImportItems() {
  const { supabase } = await requireAdmin();
  const { data, error } = await supabase.from("item_import_batches").select("id,source_name,state,created_at").eq("purpose","ITEM_MASTER").order("created_at", { ascending: false }).limit(50);
  return <><PageHeader title="Item Master Excel Import" description="Create missing classifications and new products, with a separate non-posting stock review."/><UploadWorkbook/><section className="card mt-5 p-5"><h2 className="font-semibold">Recent import batches</h2>{error && <p className="mt-3 text-red-700">{error.message}. Apply the local Item Master import migration first.</p>}{data?.map(b => <Link className="block border-b py-3 text-sm text-cyan-700" key={b.id} href={"/inventory/items/import/" + b.id}>{b.source_name} · {b.state} · {formatDateTime(b.created_at)}</Link>)}</section></>;
}
