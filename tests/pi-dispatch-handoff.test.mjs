import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration=fs.readFileSync("supabase/migrations/202608260021_pi_dispatch_packing_handoff.sql","utf8");
const workflow=fs.readFileSync("supabase/migrations/202610090032_require_customer_acceptance.sql","utf8");
const actions=fs.readFileSync("app/(erp)/dispatch/actions.ts","utf8");
const piDetail=fs.readFileSync("app/(erp)/sales/proforma-invoices/[id]/page.tsx","utf8");
const register=fs.readFileSync("app/(erp)/dispatch/packing-lists/page.tsx","utf8");

test("packing mutations require the Phase 9B edit permission",()=>{
  assert.match(migration,/has_erp_permission\('dispatch\.packing_lists','EDIT'\)/);
  assert.doesNotMatch(migration,/can_manage_crm\(\)or p\.created_by=auth\.uid\(\)/);
  assert.match(actions,/assertEdit\("dispatch\.packing_lists"\)/);
});

test("dispatch view permission exposes packing lists without creator ownership",()=>{
  assert.match(migration,/has_erp_permission\('dispatch\.packing_lists','VIEW'\)/);
  assert.doesNotMatch(migration,/packing_lists p[\s\S]*p\.created_by=auth\.uid\(\)/);
});

test("awaiting queue uses actual PI statuses and remaining finalized quantity",()=>{
  assert.match(workflow,/public\.is_pi_accepted\(pi\.id\)/);
  assert.match(migration,/PARTIALLY_DISPATCHED/);
  assert.match(migration,/get_awaiting_packing/);
  assert.match(register,/Awaiting Packing/);
});

test("PI packing action is permission-aware and retains read-only dispatch status",()=>{
  assert.match(piDetail,/canPack&&<form action=\{createPackingList/);
  assert.match(piDetail,/Dispatch Status/);
  assert.match(piDetail,/Awaiting Packing/);
  assert.match(piDetail,/Packing List Created/);
  assert.match(piDetail,/Dispatched/);
});


test("packing and physical dispatch enforce customer acceptance in the database",()=>{
  for(const name of ["create_packing_list","create_dispatch","finalize_packing_list","confirm_dispatch"]){
    const body=workflow.match(new RegExp("create or replace function public\\."+name+"\\([\\s\\S]*?\\$\\$;"))[0];
    assert.match(body,/perform public\.require_accepted_pi\(/);
  }
  assert.match(workflow,/p\.status='ACCEPTED'/);
  assert.match(workflow,/newer\.revision_number>p\.revision_number/);
  assert.match(workflow,/where id=p_pi_id for update/);
});

test("revision resets approval and preserves editing until acceptance",()=>{
  const body=workflow.match(/create or replace function public\.create_proforma_invoice_revision\([\s\S]*?\$\$;/)[0];
  assert.match(body,/set status='REVISED'/);
  assert.match(body,/currency,'ISSUED',salesperson_id/);
  assert.match(body,/accepted_at=null,accepted_by=null/);
  assert.match(workflow,/p\.status='ISSUED' and p\.revision_number>0 and p\.accepted_at is null/);
  assert.match(workflow,/old\.status='ISSUED' and old\.revision_number>0 and old\.accepted_at is null and new\.status='ISSUED'/);
});

test("PI button requires accepted current revision and lifecycle refreshes dispatch",()=>{
  assert.match(piDetail,/canPack=item\.status==="ACCEPTED"&&latestRevision/);
  const sales=fs.readFileSync("app/(erp)/sales/actions.ts","utf8");
  for(const name of ["revisePi","acceptPi"]){
    const body=sales.split("export async function "+name)[1].split("export async function ")[0];
    assert.match(body,/revalidatePath\("\/dispatch","layout"\)/);
  }
});


test("stale operational drafts disappear from queues and cannot be edited or finalized",()=>{
  const packing=fs.readFileSync("lib/dispatch/data.ts","utf8");
  const dispatch=fs.readFileSync("lib/dispatch/dispatches.ts","utf8");
  for(const source of [packing,dispatch]){
    assert.match(source,/db\.rpc\("is_pi_accepted"/);
    assert.match(source,/rows\.filter\(\(_,index\)=>eligible\[index\]\)/);
  }
  const manage=workflow.match(/create or replace function public\.can_manage_packing_list\([\s\S]*?\$\$;/)[0];
  assert.match(manage,/public\.is_pi_accepted\(p\.pi_id\)/);
  const save=workflow.match(/create or replace function public\.save_dispatch\([\s\S]*?\$\$;/)[0];
  assert.match(save,/perform public\.require_accepted_pi\(d\.pi_id\)/);
});
