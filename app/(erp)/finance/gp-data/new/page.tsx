import {requireEdit} from '@/lib/security/access';
import {gpTypes} from '@/lib/finance/data';
import {GpForm} from '@/components/finance/gp-form';
import {PageHeader} from '@/components/ui/page-header';
export default async function Page(){await requireEdit('finance.gp_data');return <><PageHeader title="New GP Invoice" description="Enter the actual sales invoice number. Add items from Item Master."/><GpForm types={await gpTypes()}/></>;}
