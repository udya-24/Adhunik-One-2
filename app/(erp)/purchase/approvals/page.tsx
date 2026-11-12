import Link from 'next/link';
import { PageHeader } from '@/components/ui/page-header';
import { formatDate, formatDateTime } from '@/lib/formatting/date';
import { currentPurchaseAccess } from '@/lib/security/access';
import { managementApprovalRows } from '@/lib/procurement/data';
import { ApprovalButton } from '@/components/purchase/approval-button';
import { approvePO } from '../procurement-actions';
export default async function Page(){
 const [data,access]=await Promise.all([managementApprovalRows(),currentPurchaseAccess()]);
 const canApprove=access['purchase.orders'].canEdit&&data.manager;
 return <><PageHeader title="Management Approval" description="Latest confirmed purchase orders waiting for Management approval."/>
 <section className="card overflow-hidden"><div className="overflow-x-auto"><table className="w-full min-w-[1400px] text-sm"><thead><tr>{['PO Number','Revision','PO Date','Supplier','Item Count','PO Value','Expected Delivery','Created By','Confirmed By','Confirmed Date','Status','Actions'].map(label=><th className="p-3 text-left" key={label}>{label}</th>)}</tr></thead>
 <tbody>{data.rows.map(order=><tr className="border-t" key={order.id}><td className="p-3">{order.po_number}</td><td>{order.revision_number?String(order.revision_number).padStart(2,'0'):'Original'}</td><td>{formatDate(order.po_date)}</td><td>{order.supplier_name_snapshot}</td><td>{order.purchase_order_items.length}</td><td>{new Intl.NumberFormat('en-IN',{style:'currency',currency:'INR'}).format(Number(order.grand_total))}</td><td>{formatDate(order.expected_delivery_date)}</td><td>{data.names[order.created_by]??'—'}</td><td>{data.names[order.confirmed_by??'']??'—'}</td><td>{formatDateTime(order.confirmed_at)}</td><td>Waiting Management Approval</td><td className="p-3"><div className="flex flex-wrap gap-2"><Link className="rounded border px-3 py-2 text-cyan-700" href={'/purchase/orders/'+order.id}>View PO</Link><Link className="rounded border px-3 py-2 text-cyan-700" href={'/api/purchase-orders/'+order.id+'/pdf'}>Download PDF</Link>{canApprove&&<ApprovalButton action={approvePO.bind(null,order.id)}/>}</div></td></tr>)}</tbody></table></div>{!data.rows.length&&<p className="p-8 text-center text-sm">No Purchase Orders waiting for Management approval.</p>}</section></>;
}
