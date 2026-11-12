import {readAll} from "@/lib/supabase/read-all";
import Link from "next/link";
import { requireAdmin } from "@/lib/identity/data";
import { PageHeader } from "@/components/ui/page-header";
import { DeleteMaster, ConsolidateMaster } from "./forms";
import { formatDateTime } from "@/lib/formatting/date";
const tables = ["item_categories", "item_subcategories", "item_types", "units_of_measurement", "stock_locations", "stock_classifications"] as const;
export default async function ItemMasterAdministration({ searchParams }: { searchParams: Promise<Record<string, string>> }) {
  const f = await searchParams, { supabase } = await requireAdmin();
  const master = tables.find(t => t === f.master) || "stock_classifications";
  const [{ data: rows }, { data: audit, error: auditError }] = await Promise.all([
    readAll(supabase.from(master).select("*").order("name").order("id")),
    supabase.from("item_master_admin_activities").select("*").eq("master_table", master).order("created_at", { ascending: false }).limit(50),
  ]);
  if (auditError) throw new Error(auditError.message);
  const section = { item_categories: "item-categories", item_subcategories: "item-subcategories", item_types: "item-types", units_of_measurement: "units", stock_locations: "stock-locations", stock_classifications: "stock-classifications" }[master];
  const filtered = (rows || []).filter(r => (!f.q || (r.name + " " + (r.code || "")).toLowerCase().includes(f.q.toLowerCase())) && (!f.status || r.is_active === (f.status === "active")));
  const pages = Math.max(1, Math.ceil(filtered.length / 25)), page = Math.min(pages, Math.max(1, Number.parseInt(f.page || "1", 10) || 1));
  const shown = filtered.slice((page - 1) * 25, page * 25);
  const pageHref = (n: number) => "/configuration/item-masters?" + new URLSearchParams({master, q:f.q || "", status:f.status || "", page:String(n)});
  const targets = (rows || []).filter(r => r.is_active).map(r => ({ id: r.id, name: r.name + ("category_id" in r ? " · parent " + r.category_id : "") }));
  return <><PageHeader title="Classification administration" description="Review dependencies and explicitly consolidate or delete unused master values."/><Link className="button-primary mb-4" href={"/configuration?section=" + section}>Add, edit, activate or deactivate values</Link><form className="card mb-4 grid gap-3 p-4 md:grid-cols-4"><select className="field" name="master" defaultValue={master}>{tables.map(t => <option key={t}>{t}</option>)}</select><input className="field" name="q" defaultValue={f.q} placeholder="Search name or code"/><select className="field" name="status" defaultValue={f.status}><option value="">All activity states</option><option value="active">Active</option><option value="inactive">Inactive</option></select><button className="button-primary">Filter</button></form><div className="grid gap-4 md:grid-cols-2">{shown.map(r => <section className="card space-y-3 p-4 text-sm" key={r.id}><h2 className="font-semibold">{r.name} · {r.code || "No code"} · {r.is_active ? "Active" : "Inactive"}</h2>{"category_id" in r && <p>Parent: {r.category_id}</p>}<p>Referenced values cannot be deleted. Deactivation retains existing references and history.</p><DeleteMaster master={master} id={r.id}/><ConsolidateMaster master={master} source={r.id} targets={targets}/></section>)}</div><nav className="my-4 flex gap-4 text-sm"><span>{filtered.length} values · Page {page} of {pages}</span>{page>1&&<Link href={pageHref(page-1)}>Previous</Link>}{page<pages&&<Link href={pageHref(page+1)}>Next</Link>}</nav><section className="card mt-5 p-5"><h2 className="font-semibold">Recent administrative history</h2>{audit?.map(a => <details key={a.id} className="border-b py-3 text-sm"><summary>{a.event_type} · {formatDateTime(a.created_at)} · {a.created_by}</summary><pre className="overflow-auto text-xs">{JSON.stringify(a.details, null, 2)}</pre></details>)}</section></>;
}
