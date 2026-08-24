"use client";
import { useEffect, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { LoaderCircle, Search, X } from "lucide-react";
import { COMPANY_TYPES } from "@/lib/master-data/constants";

type FilterValues = { query: string; status: string; type: string; state: string };
export function CompanyFilters({ values }: { values: FilterValues }) {
  const router = useRouter(); const [pending, startTransition] = useTransition();
  const [query, setQuery] = useState(values.query); const [state, setState] = useState(values.state); const firstQuery = useRef(true); const firstState = useRef(true);
  function navigate(next: Partial<FilterValues>) { const merged = { query, status: values.status, type: values.type, state, ...next }; const params = new URLSearchParams(); if (merged.query.trim()) params.set("q", merged.query.trim()); if (merged.status) params.set("status", merged.status); if (merged.type) params.set("type", merged.type); if (merged.state.trim()) params.set("state", merged.state.trim()); startTransition(() => router.replace(`/configuration${params.size ? `?${params}` : ""}`, { scroll: false })); }
  useEffect(() => { if (firstQuery.current) { firstQuery.current = false; return; } const timer = setTimeout(() => navigate({ query }), 400); return () => clearTimeout(timer); // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [query]);
  useEffect(() => { if (firstState.current) { firstState.current = false; return; } const timer = setTimeout(() => navigate({ state }), 400); return () => clearTimeout(timer); // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [state]);
  const hasFilters = Boolean(values.query || values.status || values.type || values.state);
  return <div className="relative grid gap-2 md:grid-cols-2 xl:grid-cols-[minmax(260px,1fr)_160px_210px_180px_auto]">
    <label className="relative"><span className="sr-only">Search companies</span><Search className="absolute left-3 top-2.5 text-slate-400" size={16}/><input className="field py-2 pl-9" value={query} onChange={(event) => setQuery(event.target.value)} placeholder="Search companies…"/></label>
    <label><span className="sr-only">Status</span><select className="field py-2" value={values.status} onChange={(event) => navigate({ status: event.target.value })}><option value="">All Status</option><option value="active">Active</option><option value="inactive">Inactive</option></select></label>
    <label><span className="sr-only">Company type</span><select className="field py-2" value={values.type} onChange={(event) => navigate({ type: event.target.value })}><option value="">All Types</option>{COMPANY_TYPES.map((item) => <option key={item}>{item}</option>)}</select></label>
    <label><span className="sr-only">State</span><input className="field py-2" value={state} onChange={(event) => setState(event.target.value)} placeholder="All States"/></label>
    {hasFilters ? <button type="button" onClick={() => { setQuery(""); setState(""); startTransition(() => router.replace("/configuration", { scroll: false })); }} className="inline-flex min-h-10 items-center justify-center gap-1.5 rounded-lg border border-slate-300 px-3 text-sm font-semibold text-slate-600 hover:bg-slate-50"><X size={15}/> Clear</button> : <span/>}
    {pending && <span className="absolute -bottom-5 left-0 inline-flex items-center gap-1 text-[11px] text-cyan-700" role="status"><LoaderCircle className="animate-spin" size={12}/> Updating results…</span>}
  </div>;
}
