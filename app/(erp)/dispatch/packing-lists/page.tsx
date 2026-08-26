import Link from "next/link";
import {createPackingList} from "@/app/(erp)/dispatch/actions";
import {PageHeader} from "@/components/ui/page-header";
import {awaitingPacking,packingLists} from "@/lib/dispatch/data";
import {requireView} from "@/lib/security/access";

export default async function Register({searchParams}:{searchParams:Promise<Record<string,string|undefined>>}){
  const [s,grant]=await Promise.all([searchParams,requireView("dispatch.packing_lists")]);
  const view=s.view==="lists"?"lists":"awaiting";
  const filters=Object.fromEntries(Object.entries(s).filter((entry):entry is [string,string]=>Boolean(entry[1])&&entry[0]!=="view"));
  const [{rows:awaiting,error:awaitingError},{rows,error}]=await Promise.all([awaitingPacking(),packingLists(filters)]);
  const activeError=view==="awaiting"?awaitingError:error;

  return <>
    <PageHeader title="Packing Lists" description="Dispatch preparation, carton planning and package management"/>
    <div className="flex flex-wrap items-center justify-between gap-3">
      <nav className="flex gap-2 rounded-lg border bg-white p-1 text-sm font-semibold">
        <Link className={`rounded px-4 py-2 ${view==="awaiting"?"bg-cyan-50 text-cyan-800":""}`} href="/dispatch/packing-lists">Awaiting Packing ({awaiting.length})</Link>
        <Link className={`rounded px-4 py-2 ${view==="lists"?"bg-cyan-50 text-cyan-800":""}`} href="/dispatch/packing-lists?view=lists">Packing Lists ({rows.length})</Link>
      </nav>
      <Link className="rounded-lg border px-4 py-3 text-sm font-semibold" href="/dispatch/dispatches">Dispatch Register</Link>
    </div>
    {activeError&&<p className="rounded-lg bg-red-50 p-3 text-red-700">{activeError.message}</p>}
    {view==="awaiting"?<section className="card overflow-hidden">
      <div className="overflow-x-auto"><table className="w-full min-w-[920px] text-left text-sm">
        <thead className="bg-slate-50"><tr>{["PI Number","PI Date","Customer","Order","Total Items","Total Quantity","Packing Status","Action"].map(label=><th className="px-3 py-3" key={label}>{label}</th>)}</tr></thead>
        <tbody className="divide-y">{awaiting.map(pi=><tr key={pi.id}>
          <td className="px-3 py-3 font-semibold">{pi.pi_number}</td><td className="px-3">{new Date(pi.pi_date).toLocaleDateString("en-IN")}</td><td className="px-3">{pi.customer_name}</td><td className="px-3">{pi.order_number}</td><td className="px-3">{pi.total_items}</td><td className="px-3">{pi.remaining_quantity}</td><td className="px-3">Awaiting Packing</td>
          <td className="px-3">{grant.canEdit?<form action={createPackingList.bind(null,pi.id)}><button className="font-semibold text-cyan-700">Create Packing List</button></form>:<span className="text-slate-400">View only</span>}</td>
        </tr>)}</tbody>
      </table></div>
      {!awaiting.length&&!rows.length&&<p className="p-8 text-center text-sm text-slate-500">No packing activity found.</p>}
      {!awaiting.length&&rows.length>0&&<p className="p-8 text-center text-sm text-slate-500">No PIs are awaiting packing.</p>}
    </section>:<>
      <form className="card grid gap-3 p-4 md:grid-cols-5">
        <input type="hidden" name="view" value="lists"/><input className="field md:col-span-2" name="q" defaultValue={s.q} placeholder="PL, PI, Order, customer or PO"/>
        <select className="field" name="status" defaultValue={s.status}><option value="">All statuses</option>{["DRAFT","FINALIZED","PARTIALLY_DISPATCHED","DISPATCHED","CANCELLED"].map(status=><option key={status}>{status}</option>)}</select>
        <input className="field" type="date" name="from" defaultValue={s.from}/><input className="field" type="date" name="to" defaultValue={s.to}/>
        <div className="flex gap-2 md:col-span-5"><button className="button-primary">Apply Filters</button><Link className="rounded-lg border px-4 py-3 text-sm font-semibold" href="/dispatch/packing-lists?view=lists">Clear</Link></div>
      </form>
      <section className="card overflow-hidden"><div className="overflow-x-auto"><table className="w-full min-w-[900px] text-left text-sm">
        <thead className="bg-slate-50"><tr>{["Packing List","Date","PI","Order","Customer","Packages","Gross kg","Status","Action"].map(label=><th className="px-3 py-3" key={label}>{label}</th>)}</tr></thead>
        <tbody className="divide-y">{rows.map(item=><tr key={item.id}><td className="px-3 py-3 font-semibold">{item.packing_list_number}</td><td className="px-3">{new Date(item.packing_date).toLocaleDateString("en-IN")}</td><td className="px-3">{item.pi_number_snapshot}</td><td className="px-3">{item.order_number_snapshot}</td><td className="px-3">{item.customer_name_snapshot}</td><td className="px-3">{item.total_packages}</td><td className="px-3">{Number(item.total_gross_weight).toFixed(3)}</td><td className="px-3">{item.status}</td><td className="px-3"><Link className="font-semibold text-cyan-700" href={`/dispatch/packing-lists/${item.id}`}>View</Link></td></tr>)}</tbody>
      </table></div>{!rows.length&&<p className="p-8 text-center text-sm text-slate-500">No Packing Lists match these filters.</p>}</section>
    </>}
  </>;
}
