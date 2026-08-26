import test from "node:test";
import assert from "node:assert/strict";
import fs from "node:fs";

const migration=fs.readFileSync("supabase/migrations/202608260021_pi_dispatch_packing_handoff.sql","utf8");
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
  assert.match(migration,/pi\.status in\('ISSUED','ACCEPTED'\)/);
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
