"use client";
import { useActionState } from "react";
import Link from "next/link";
import { LoaderCircle, Save } from "lucide-react";
import type { CustomerCompany } from "@/lib/database.types";
import { COMPANY_TYPES } from "@/lib/master-data/constants";
import { saveCompany, type FormState } from "@/app/(erp)/configuration/actions";
import { CheckField, Field, FormSection, SelectField } from "./form-controls";
const initialState: FormState = {};
export function CompanyForm({ company }: { company?: CustomerCompany }) { const action = saveCompany.bind(null, company?.id ?? null); const [state, formAction, pending] = useActionState(action, initialState); return <form action={formAction} className="space-y-4">
  <FormSection title="Basic information"><Field label="Legal name" name="legal_name" defaultValue={company?.legal_name} required/><Field label="Trade name" name="trade_name" defaultValue={company?.trade_name}/><Field label="Company code" name="company_code" defaultValue={company?.company_code} placeholder="Manual until Module 3"/><SelectField label="Company type" name="company_type" options={COMPANY_TYPES} defaultValue={company?.company_type}/></FormSection>
  <FormSection title="Tax information"><Field label="GSTIN" name="gstin" defaultValue={company?.gstin} placeholder="Optional, 15 characters"/><Field label="PAN" name="pan" defaultValue={company?.pan} placeholder="Optional, 10 characters"/></FormSection>
  <FormSection title="Contact information"><Field label="Primary email" name="primary_email" type="email" defaultValue={company?.primary_email}/><Field label="Primary phone" name="primary_phone" type="tel" defaultValue={company?.primary_phone}/><Field label="Website" name="website" type="url" defaultValue={company?.website}/></FormSection>
  <FormSection title="Commercial"><Field label="Payment terms" name="payment_terms" defaultValue={company?.payment_terms}/><Field label="Credit days" name="credit_days" type="number" min={0} defaultValue={company?.credit_days}/><Field label="Credit limit" name="credit_limit" type="number" min={0} step="0.01" defaultValue={company?.credit_limit}/></FormSection>
  <fieldset className="card p-5"><legend className="px-1 text-sm font-semibold">Additional</legend><label className="mt-2 block text-sm font-medium text-slate-700">Notes<textarea className="field mt-1.5 min-h-24" name="notes" defaultValue={company?.notes ?? ""}/></label><div className="mt-4"><CheckField label="Active" name="is_active" defaultChecked={company?.is_active ?? true}/></div></fieldset>
  {state.error && <p role="alert" className="rounded-lg bg-red-50 p-3 text-sm text-red-700">{state.error}</p>}<div className="flex justify-end gap-3"><Link className="rounded-lg border border-slate-300 px-4 py-2.5 text-sm font-semibold text-slate-600" href={company ? `/configuration/${company.id}` : "/configuration"}>Cancel</Link><button className="button-primary" disabled={pending}>{pending ? <LoaderCircle className="animate-spin" size={17}/> : <Save size={17}/>} {pending ? "Saving…" : "Save company"}</button></div>
  </form>; }
