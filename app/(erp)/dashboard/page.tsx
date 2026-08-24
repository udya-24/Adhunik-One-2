import Link from "next/link";
import { ArrowUpRight, CheckCircle2, CircleDot } from "lucide-react";
import { PageHeader } from "@/components/ui/page-header";
import { primaryNavigation, quickAccessHrefs } from "@/lib/modules";
import { createClient } from "@/lib/supabase/server";

function greeting() { const hour = new Date().getHours(); return hour < 12 ? "Good morning" : hour < 17 ? "Good afternoon" : "Good evening"; }
export default async function DashboardPage() {
  const supabase = await createClient(); const { data: { user } } = await supabase.auth.getUser();
  const quickAccess = primaryNavigation.filter((module) => quickAccessHrefs.includes(module.href));
  const status = [{ label: "Application", value: "Online" }, { label: "Database", value: "Connected" }, { label: "Authentication", value: "Active" }, { label: "Environment", value: process.env.VERCEL_ENV === "production" ? "Production" : "Development" }];
  return <><PageHeader title={`${greeting()}, ${user?.email?.split("@")[0] ?? "welcome"}`} description="Welcome to Adhunik ERP. Your enterprise workspace is ready."/>
    <section aria-labelledby="quick-access"><div className="mb-3 flex items-center justify-between"><h3 id="quick-access" className="text-sm font-semibold">Quick access</h3><span className="text-xs text-slate-400">Planned modules</span></div><div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">{quickAccess.map((item) => { const Icon = item.icon; return <Link key={item.href} href={item.href} className="card group flex items-center gap-3 p-4 transition hover:-translate-y-0.5 hover:border-cyan-200 hover:shadow-sm"><span className="grid size-10 place-items-center rounded-lg bg-cyan-50 text-cyan-700"><Icon size={19}/></span><span className="min-w-0"><strong className="block truncate text-sm">{item.label}</strong><span className="text-xs text-slate-400">{item.phase}</span></span><ArrowUpRight size={16} className="ml-auto text-slate-300 group-hover:text-cyan-700"/></Link>; })}</div></section>
    <section className="mt-7" aria-labelledby="system-overview"><h3 id="system-overview" className="mb-3 text-sm font-semibold">System overview</h3><div className="grid gap-3 sm:grid-cols-2 xl:grid-cols-4">{status.map((item) => <div className="card p-4" key={item.label}><div className="flex items-center gap-2 text-xs text-slate-500"><CircleDot size={14} className="text-emerald-600"/>{item.label}</div><div className="mt-2 flex items-center gap-2 text-sm font-semibold"><CheckCircle2 size={16} className="text-emerald-600"/>{item.value}</div></div>)}</div></section></>;
}
