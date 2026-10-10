"use client";
import {useActionState} from 'react';
import type {ProcState} from '@/app/(erp)/purchase/procurement-actions';
export function ApprovalButton({action}:{action:(state:ProcState)=>Promise<ProcState>}){
 const [state,formAction,pending]=useActionState(action,{});
 return <form action={formAction}><button className="button-primary" disabled={pending}>{pending?'Approving...':'Approve PO'}</button>{state.error&&<p className="mt-2 text-sm text-red-700">{state.error}</p>}</form>;
}
