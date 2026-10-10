
import { formatDate, formatDateTime } from "@/lib/formatting/date";
import Link from 'next/link';
import { notFound } from 'next/navigation';
import { PageHeader } from '@/components/ui/page-header';
import { cancelPO, closePO, confirmPO, createPORevision } from '../../procurement-actions';
import { orderDetail, orderHasReceipts } from '@/lib/procurement/data';
import { orderRevisionHistory, type PurchaseOrderVersion } from '@/lib/procurement/revisions';
import { currentPurchaseAccess } from '@/lib/security/access';
import {currentPurchaseStatuses as currentStatuses,approvedOrderMessage,purchaseStatusLabel} from '@/lib/procurement/receipt-queue';

const money=(value:number)=>new Intl.NumberFormat('en-IN',{style:'currency',currency:'INR'}).format(Number(value));

export default async function Page({params}:{params:Promise<{id:string}>}){
 const{id}=await params;
 const[data,access]=await Promise.all([orderDetail(id),currentPurchaseAccess()]);
 if(!data.item)notFound();
 const order=data.item as PurchaseOrderVersion;
 const [history,hasReceipts]=await Promise.all([orderRevisionHistory(order.root_po_id),orderHasReceipts(id)]);
 const canEdit=access['purchase.orders'].canEdit,canReceipt=access['purchase.material_receipts'].canEdit;
 const isRevision=order.revision_number>0,isCurrent=currentStatuses.includes(order.status),isApproved=Boolean(order.approval_source);
 return <>
  <PageHeader title={order.po_number} description={`${purchaseStatusLabel(order.status)} · Supplier: ${order.supplier_name_snapshot}`}/>
  <div className='flex flex-wrap gap-2'>
   {canEdit&&order.status==='DRAFT'&&<><Link className='button-primary'href={`/purchase/orders/${id}/edit`}>Edit Draft</Link><form action={confirmPO.bind(null,id)}><button className='button-primary'>{isRevision?'Confirm Revised PO':'Confirm PO'}</button></form></>}
   <Link className='rounded border px-4 py-2'href={`/api/purchase-orders/${id}/pdf`}>Download PDF</Link>
   {canEdit&&isCurrent&&!isApproved&&<form action={createPORevision.bind(null,id)}className='flex flex-wrap gap-2 rounded border p-2'><input className='field min-w-72'name='revision_reason'placeholder='Revision Reason *'required/><button className='button-primary'>Create Revision</button></form>}
   {canReceipt&&isCurrent&&['APPROVED','PARTIALLY_RECEIVED'].includes(order.status)&&<Link className='button-primary'href={`/purchase/receipts/new?po=${id}`}>Record Material Receipt</Link>}
   {canEdit&&order.status==='FULLY_RECEIVED'&&<form action={closePO.bind(null,id)}><button className='button-primary'>Close PO</button></form>}
   {canEdit&&(order.status==='DRAFT'||isCurrent)&&!hasReceipts&&<form action={cancelPO.bind(null,id)}className='flex gap-2'><input className='field'name='reason'placeholder='Cancellation reason'required/><button className='rounded border border-red-300 px-3 text-red-700'>Cancel PO</button></form>}
  </div>
  {canEdit&&hasReceipts&&(isCurrent||order.status==='DRAFT')&&<p className='rounded bg-amber-50 p-3 text-sm text-amber-800'>Material Receipt already exists. Purchase Order cannot be cancelled.</p>}
  {order.status==='CONFIRMED'&&!isApproved&&<p className='rounded bg-amber-50 p-3 text-sm text-amber-800'>Waiting Management Approval. <Link className='font-semibold text-cyan-700' href='/purchase/approvals'>Management Approval</Link></p>}
  {isApproved&&<section className='card space-y-2 p-5'><p>{order.approval_source==='LEGACY_RECEIPT'?'Existing receipt history retained. This Purchase Order is read-only.':approvedOrderMessage}</p><p className='text-sm'>If changes are required, cancel the Purchase Order before any Material Receipt exists and create a new Purchase Order.</p>{order.approved_at&&<p><b>Approved By:</b> {history.names[order.approved_by??'']??'�'} � <b>Approved Date:</b> {formatDate(order.approved_date)} � <b>Approval Timestamp:</b> {formatDateTime(order.approved_at)}</p>}</section>}
  {isRevision&&<section className='card grid gap-2 p-5 md:grid-cols-2'><p><b>Revision:</b> {String(order.revision_number).padStart(2,'0')}</p><p><b>Revision Reason:</b> {order.revision_reason}</p></section>}
  <section className='card grid gap-4 p-5 md:grid-cols-2 xl:grid-cols-3'><p><b>PO Date:</b> {formatDate(order.po_date)}</p><p><b>Indent:</b> {data.indent}</p><p><b>Expected Delivery:</b> {formatDate(order.expected_delivery_date)}</p><p><b>Payment Terms:</b> {order.payment_terms??'—'}</p><p><b>Delivery Terms:</b> {order.delivery_terms??'—'}</p><p><b>Billing:</b> {order.billing_address_snapshot}</p><p><b>Delivery:</b> {order.delivery_address_snapshot}</p><p><b>Remarks:</b> {order.remarks??'—'}</p></section>
  <section className='card p-5'><h2 className='font-semibold'>Supplier Snapshot</h2><p>{order.supplier_code_snapshot} — {order.supplier_name_snapshot}</p><p className='text-sm'>GSTIN: {order.supplier_gstin_snapshot??'—'} · Contact: {order.supplier_contact_snapshot??'—'} · Phone: {order.supplier_phone_snapshot??'—'}</p><p className='text-sm'>{order.supplier_address_snapshot??'—'}</p></section>
  <section className='card overflow-x-auto'><table className='w-full min-w-[1000px] text-sm'><thead><tr>{['#','Item','Description','Indent Qty','PO Qty','Unit','Rate','Amount','Expected'].map(label=><th className='p-3 text-left'key={label}>{label}</th>)}</tr></thead><tbody>{data.items.map(item=><tr className='border-t'key={item.id}><td className='p-3'>{item.line_number}</td><td>{item.item_code_snapshot} — {item.item_name_snapshot}</td><td>{item.description_snapshot??'—'}</td><td>{item.pon_quantity}</td><td>{item.quantity}</td><td>{item.unit_snapshot}</td><td>{money(item.unit_rate)}</td><td>{money(item.line_amount)}</td><td>{formatDate(item.expected_delivery_date)}</td></tr>)}</tbody></table></section>
  <section className='ml-auto card max-w-md space-y-2 p-5'><Row label='Subtotal'value={money(order.subtotal)}/><Row label={`GST ${order.gst_rate}%`}value={money(order.gst_amount)}/><Row label='Freight'value={money(order.freight_amount)}/><Row label='Grand Total'value={money(order.grand_total)}bold/></section>
  {access['purchase.material_receipts'].canView&&<section className='card p-5'><h2 className='font-semibold'>Material Receipts</h2>{data.receipts.map(receipt=><p key={receipt.id}><Link className='text-cyan-700'href={`/purchase/receipts/${receipt.id}`}>{receipt.receipt_number}</Link> · {formatDate(receipt.receipt_date)} · {receipt.status}</p>)}{!data.receipts.length&&<p className='text-sm text-slate-500'>No receipts recorded against this version.</p>}</section>}
  <section className='card overflow-x-auto p-5'><h2 className='font-semibold'>Revision History</h2><table className='mt-3 w-full min-w-[760px] text-sm'><thead><tr>{['Version','PO Number','Status','Revision Date','Reason','Created / Revised By','Confirmed At'].map(x=><th className='p-2 text-left'key={x}>{x}</th>)}</tr></thead><tbody>{history.versions.map(x=><tr className='border-t'key={x.id}><td className='p-2'>{x.revision_number?`Revision ${String(x.revision_number).padStart(2,'0')}`:'Original'}</td><td><Link className='text-cyan-700'href={`/purchase/orders/${x.id}`}>{x.po_number}</Link></td><td>{x.revision_number>0&&x.status==='DRAFT'?'DRAFT REVISION':purchaseStatusLabel(x.status)}</td><td>{formatDateTime(x.revised_at??x.created_at)}</td><td>{x.revision_reason??'—'}</td><td>{history.names[x.revised_by??x.created_by]??'—'}</td><td>{formatDateTime(x.confirmed_at)}</td></tr>)}</tbody></table></section>
  <section className='card p-5'><h2 className='font-semibold'>Activity</h2>{data.activity.map(item=><p className='mt-2 text-sm'key={item.id}><b>{item.activity_type}</b> — {item.description}</p>)}</section>
 </>
}
function Row({label,value,bold}:{label:string;value:string;bold?:boolean}){return <p className={`flex justify-between ${bold?'border-t pt-2 font-bold':''}`}><span>{label}</span><span>{value}</span></p>}
