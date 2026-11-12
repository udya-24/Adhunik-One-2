"use client";
import { useActionState } from "react";
import { deleteConfiguration, previewConsolidation, confirmConsolidation, type MasterActionState } from "./actions";
function Notice({ state }: { state: MasterActionState }) { return <>{state.error && <p role="alert" className="text-red-700">{state.error}</p>}{state.success && <p role="status" className="text-emerald-700">{state.success}</p>}</>; }
export function DeleteMaster({ master, id }: { master: string; id: string }) {
  const [state, action, pending] = useActionState(deleteConfiguration.bind(null, master, id), {});
  return <form action={action} className="space-y-2"><label className="flex gap-2"><input type="checkbox" required/>Confirm deletion if unused</label><button className="text-red-700 underline" disabled={pending}>Delete unused value</button><Notice state={state}/></form>;
}
export function ConsolidateMaster({ master, source, targets }: { master: string; source: string; targets: { id: string; name: string }[] }) {
  const [state, action, pending] = useActionState(previewConsolidation.bind(null, master, source), {});
  return <details className="mt-3"><summary className="cursor-pointer text-cyan-700">Explicit consolidation</summary><form action={action} className="my-3 space-y-2"><select className="field" name="target" required><option value="">Choose active target</option>{targets.filter(x => x.id !== source).map(x => <option key={x.id} value={x.id}>{x.name}</option>)}</select><button className="button-primary" disabled={pending}>Preview affected references</button><Notice state={state}/></form>{state.preview && state.target && <Confirm key={JSON.stringify(state.preview)} master={master} source={source} target={state.target} preview={state.preview}/>}</details>;
}
function Confirm({ master, source, target, preview }: { master: string; source: string; target: string; preview: Record<string, unknown> }) {
  const [state, action, pending] = useActionState(confirmConsolidation.bind(null, master, source, target, preview), {});
  return <form action={action} className="space-y-2 rounded border p-3"><pre className="max-h-64 overflow-auto text-xs">{JSON.stringify(preview, null, 2)}</pre><p className="text-xs">Current eligible product references move to the target. For units, confirm the same physical unit; no quantity conversion is performed. Source is deactivated; immutable history stays intact. Incompatible parent links, units or historical locations block consolidation.</p><label className="flex gap-2"><input name="confirm" type="checkbox" required/>I confirm this source, target and reference preview.</label><Notice state={state}/><button className="button-primary" disabled={pending}>Confirm consolidation</button></form>;
}
