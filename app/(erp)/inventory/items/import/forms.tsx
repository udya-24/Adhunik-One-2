"use client";
import { useActionState, useRef, useState, useTransition } from "react";
import { useRouter } from "next/navigation";
import { runImportChunks } from "@/lib/inventory/import/runner";
import { uploadItemWorkbook, startItemWorkbook, resumeItemWorkbook, processItemWorkbookChunk, refreshItemWorkbook, reviewStockProposal, type ImportActionState } from "./actions";
import type { ImportPreview, ImportJobProgress } from "@/lib/inventory/import/types";
function Message({ state }: { state: ImportActionState }) { return <>{state.error && <p role="alert" className="rounded bg-red-50 p-3 text-red-700">{state.error}</p>}{state.success && <p role="status" className="rounded bg-emerald-50 p-3 text-emerald-700">{state.success}</p>}</>; }
export function UploadWorkbook() {
  const [state, action, pending] = useActionState(uploadItemWorkbook, {});
  return <form action={action} className="card space-y-4 p-5"><label className="block text-sm">Product workbook (.xlsx, maximum 10 MB)<input className="field mt-2" name="workbook" type="file" accept=".xlsx" required /></label><p className="text-sm text-slate-500">The preview preserves source rows and shows missing masters, item conflicts, COGS and stock source values. Uploading does not create products or change stock.</p><Message state={state}/><button className="button-primary" disabled={pending}>{pending ? "Reading workbook…" : "Validate and preview"}</button></form>;
}
export function ImportReview({ id, revision, preview }: { id: string; revision: number; preview: ImportPreview }) {
  const controller = useImportController();
  const {state,pending,progress} = controller;
  const [refreshState, refreshAction, refreshing] = useActionState(refreshItemWorkbook.bind(null, id), {});
  return <><form action={refreshAction} className="my-4 flex items-center gap-3"><button className="button-primary" disabled={refreshing || pending || !!progress}>Refresh preview after resolving conflicts</button><Message state={refreshState}/></form><form onSubmit={event=>{event.preventDefault();const form=new FormData(event.currentTarget);controller.run(()=>startItemWorkbook(id,revision,crypto.randomUUID(),form));}} className="space-y-4"><fieldset disabled={pending || refreshing || !!progress}><div className="card max-h-[65vh] overflow-auto"><table className="w-full text-left text-sm"><thead className="sticky top-0 bg-slate-50"><tr>{["Include", "Row / code", "Product / COGS", "Classification resolution", "Validation"].map(h => <th className="p-3" key={h}>{h}</th>)}</tr></thead><tbody>{preview.rows.map(r => <tr className="border-t align-top" key={r.row}><td className="p-3"><input aria-label={"Include source row " + r.row} name="rows" value={r.row} type="checkbox" defaultChecked={!r.errors.length} disabled={!!r.errors.length}/></td><td className="p-3">{r.row}<br/><b>{r.raw["New code"]}</b><p>{r.errors.length ? "BLOCKED" : r.action}</p></td><td className="p-3">{r.raw["Item name"]}<p>Source rate ₹{r.raw["Rate (Rs)"]}</p><p>COGS ₹{Number(r.cogs ?? 0).toFixed(4)}</p></td><td className="p-3">{Object.entries(r.mappings).map(([k, m]) => <p key={k}>{k}: {m.name || "—"} · {m.state}{m.code && " · code " + m.code}</p>)}</td><td className="p-3"><ul>{r.errors.map((e, i) => <li className="text-red-700" key={"e" + i}>{e}</li>)}{r.warnings.map((w, i) => <li className="text-amber-800" key={"w" + i}>{w}</li>)}</ul><details><summary>Original source values</summary><pre className="max-w-md overflow-auto text-xs">{JSON.stringify(r.raw, null, 2)}</pre></details></td></tr>)}</tbody></table></div><label className="flex gap-2 text-sm"><input type="checkbox" name="acknowledge" required/>I confirm the selected rows, warnings, four-decimal COGS (including zeros), and generated Stock Location codes. Existing products will be preserved. This approves product master data only. Each batch is atomic; earlier successful batches remain saved if a later batch fails.</label><label className="mt-4 block text-sm">Products per batch (1–100)<input className="field mt-1 max-w-40" name="batch_size" type="number" min="1" max="100" defaultValue="100" required/></label><button className="button-primary mt-4" disabled={pending || refreshing || !!progress}>{pending ? "Import running…" : "Confirm and start resumable import"}</button></fieldset><Message state={state}/>{progress&&<ImportProgress progress={progress}/>}</form></>;
}
export function ProposalAction({ id, revision, action, label }: { id: string; revision: number | null; action: string; label: string }) {
  const [state, submit, pending] = useActionState(reviewStockProposal.bind(null, id, action, revision), {});
  return <form action={submit} className="space-y-3">{action === "REVIEW" && <label className="flex gap-2 text-sm"><input type="checkbox" name="acknowledge" required/>I reviewed the source quantities and current balances. Accounting rules remain unapproved; this cannot authorize posting.</label>}{action !== "PREVIEW" && <input className="field" name="reason" placeholder="Review / rejection / cancellation note"/>}<Message state={state}/><button className="button-primary" disabled={pending}>{label}</button></form>;
}

function useImportController(initial?: ImportJobProgress) {
  const router=useRouter(),busy=useRef(false),[pending,startTransition]=useTransition();
  const [progress,setProgress]=useState(initial),[state,setState]=useState<ImportActionState>({});
  function run(start:()=>Promise<{progress?:ImportJobProgress;error?:string}>){
    if(busy.current)return;
    busy.current=true;setState({});
    startTransition(async()=>{
      try{
        const result=await start();if(result.error||!result.progress)throw new Error(result.error||"Could not read job progress. Refresh and resume.");
        const completed=await runImportChunks(result.progress,p=>processItemWorkbookChunk(p.id,p.next!.chunk_number,p.next!.request_key),setProgress);
        if(completed.state==="PAUSED")setState({error:completed.next?.error||"Import paused. Completed batches remain saved. Review this batch and resume."});
        else setState({success:"All selected product masters processed. Inventory balances were not changed."});
      }catch(error){setState({error:error instanceof Error?error.message:"Import interrupted. Refresh progress and resume."});}
      finally{busy.current=false;router.refresh();}
    });
  }
  return {run,progress,state,pending};
}
export function ImportProgress({progress:p}:{progress:ImportJobProgress}){
  return <section className="card my-4 space-y-3 p-5" aria-live="polite"><h2 className="font-semibold">Import progress · {p.state}</h2><div className="grid grid-cols-2 gap-3 text-sm md:grid-cols-3">{[["Selected records",p.total],["New items imported",p.created],["Already existing",p.existing],["Pending records",p.pending],["Failed records",p.failed],["Successfully processed",p.completed]].map(([label,value])=><p key={label}><span className="text-slate-500">{label}: </span><b>{value}</b></p>)}</div><progress className="w-full" value={p.completed} max={p.total} aria-label="Overall import progress"/><p className="text-sm">{p.percent}% · {p.completed_batches} of {p.total_batches} batches completed{p.next&&" · Current batch "+p.next.chunk_number}{p.failed_batches>0&&" · Failed batches: "+p.failed_batches}</p>{p.next?.error&&<p role="alert" className="text-sm text-red-700">{p.next.error}</p>}<p className="text-xs text-slate-500">Each batch is a separate transaction. Completed batches remain saved and will not be reprocessed. Stock quantities are not imported.</p></section>;
}
export function ResumeImport({initial}:{initial:ImportJobProgress}){
  const {run,progress,state,pending}=useImportController(initial);
  return <><ImportProgress progress={progress||initial}/>{initial.state!=="COMPLETED"&&<form className="card space-y-3 p-5" onSubmit={event=>{event.preventDefault();const size=Number(new FormData(event.currentTarget).get("batch_size"));run(()=>resumeItemWorkbook(initial.id,size));}}><p className="text-sm">Import runs only after you select Resume. Reduce the batch size if a request timed out.</p><label className="block text-sm">Products per batch (1–100)<input className="field mt-1 max-w-40" name="batch_size" type="number" min="1" max="100" defaultValue={initial.batch_size} required disabled={pending}/></label><Message state={state}/><button className="button-primary" disabled={pending}>{pending?"Import running…":"Retry / Resume Import"}</button></form>}</>;
}
