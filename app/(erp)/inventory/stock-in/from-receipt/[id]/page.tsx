import{notFound}from'next/navigation';
import{PageHeader}from'@/components/ui/page-header';
import{ReceiptStockInForm}from'@/components/inventory/receipt-stock-in-form';
import{receiptDetail}from'@/lib/procurement/data';
import{receiptPosting}from'@/lib/inventory/receipts';
import{crmOptions}from'@/lib/crm/data';

export default async function ReceiptStockIn({params}:{params:Promise<{id:string}>}){const{id}=await params;const[receipt,posting,options]=await Promise.all([receiptDetail(id),receiptPosting(id),crmOptions()]);if(!receipt.item)notFound();const x=receipt.item,receivedBy=options.users.find(user=>user.authId===x.received_by)?.name??'ERP User';if(x.status!=='CONFIRMED'||posting.remaining<=0)notFound();return <><PageHeader title={'Post '+x.receipt_number+' to Inventory'}description='Review accepted material and explicitly confirm a normal Stock In transaction.'/><section className='card grid gap-4 p-5 text-sm md:grid-cols-2 xl:grid-cols-3'><Info label='Material Receipt'value={x.receipt_number}/><Info label='Receipt Date'value={x.receipt_date}/><Info label='Purchase Order'value={receipt.po?.po_number??'—'}/><Info label='Supplier'value={x.supplier_name_snapshot}/><Info label='Received At'value={x.received_at??'—'}/><Info label='Received By'value={receivedBy}/><Info label='Posting Status'value={posting.status.replaceAll('_',' ')}/><Info label='Accepted Qty'value={posting.accepted}/><Info label='Remaining Qty'value={posting.remaining}/></section><ReceiptStockInForm receiptId={id}requestId={crypto.randomUUID()}items={posting.items}locations={posting.locations}/></>}
function Info({label,value}:{label:string;value:string|number}){return <div><p className='text-xs font-semibold uppercase text-slate-400'>{label}</p><p className='mt-1 font-medium'>{value}</p></div>}
