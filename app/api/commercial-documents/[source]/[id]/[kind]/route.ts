import {NextRequest,NextResponse} from 'next/server';
import {createClient} from '@/lib/supabase/server';
import {createAdminClient} from '@/lib/supabase/admin';
import {commercialBucket} from '@/lib/procurement/documents';
export async function GET(request:NextRequest,{params}:{params:Promise<{source:string;id:string;kind:string}>}){const{source,id,kind}=await params,db=await createClient();let path:string|null=null,name:string|null=null;
if(source==='proof'&&kind==='proof'){const{data}=await db.from('vendor_payment_records' as never).select('proof_path,proof_name').eq('id',id).maybeSingle();if(data){const d=data as {proof_path:string;proof_name:string};path=d.proof_path;name=d.proof_name;}}
else if(['receipt','vendor'].includes(source)&&['grn','invoice'].includes(kind)){let receiptId=id;if(source==='vendor'){const{data}=await db.from('vendor_payments' as never).select('material_receipt_id').eq('id',id).maybeSingle();if(!data)return new NextResponse('Not found',{status:404});receiptId=(data as {material_receipt_id:string}).material_receipt_id;}
// Finance access is authorized through its payable; purchase access through receipt RLS.
const client=source==='vendor'?createAdminClient():db;const{data}=await client.from('material_receipts').select('grn_file_url,grn_file_name,invoice_file_url,invoice_file_name').eq('id',receiptId).maybeSingle();if(data){path=kind==='grn'?data.grn_file_url:data.invoice_file_url;name=kind==='grn'?data.grn_file_name:data.invoice_file_name;}}
if(!path)return new NextResponse('Document not uploaded',{status:404});const{data,error}=await createAdminClient().storage.from(commercialBucket).createSignedUrl(path,60,request.nextUrl.searchParams.get('download')==='1'?{download:name??'document'}:undefined);if(error||!data)return new NextResponse('Document unavailable',{status:404});return NextResponse.redirect(data.signedUrl,{headers:{'Cache-Control':'private, no-store'}});}
