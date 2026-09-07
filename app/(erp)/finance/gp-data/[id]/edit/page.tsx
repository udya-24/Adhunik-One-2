import {notFound,redirect} from 'next/navigation';
import {requireEdit} from '@/lib/security/access';
import {gpTypes,gpDetail} from '@/lib/finance/data';
import {GpForm} from '@/components/finance/gp-form';
import {PageHeader} from '@/components/ui/page-header';
export default async function Page({params}:{params:Promise<{id:string}>}){await requireEdit('finance.gp_data');const{id}=await params;const[d,types]=await Promise.all([gpDetail(id),gpTypes()]);if(!d)notFound();if(d.invoice.status!=='DRAFT')redirect('/finance/gp-data/'+id);return <><PageHeader title={'Edit GP · '+d.invoice.invoice_no} description="Saved costs remain unchanged unless you change the item or explicitly refresh COGS."/><GpForm key={d.invoice.version} invoice={d.invoice} types={types}/></>;}
