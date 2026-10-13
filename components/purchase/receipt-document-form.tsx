'use client';
import {CommercialFileInput} from './commercial-file-input';
import {useActionState} from 'react';
import {replaceReceiptDocument} from '@/app/(erp)/purchase/procurement-actions';
export function ReceiptDocumentForm({id,kind}:{id:string;kind:string}){const[state,action,pending]=useActionState(replaceReceiptDocument.bind(null,id,kind),{});return <form action={action} className="mt-3 flex flex-wrap gap-3"><CommercialFileInput name="file" required/><button className="rounded border px-3 py-1" disabled={pending}>Replace {kind.toUpperCase()} (max 1 MB)</button>{state.error&&<p className="text-red-700">{state.error}</p>}</form>}
