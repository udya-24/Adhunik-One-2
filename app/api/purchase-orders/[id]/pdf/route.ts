import { NextResponse } from 'next/server';
import { createClient } from '@/lib/supabase/server';
import { buildPODocument } from '@/lib/procurement/po-document';
import { renderPurchaseOrderPdf } from '@/lib/procurement/render-po-pdf';

export async function GET(_:Request,{params}:{params:Promise<{id:string}>}){
 const db=await createClient();
 const{data:allowed}=await db.rpc('has_erp_permission' as never,{p_section_key:'purchase.orders',p_access_type:'VIEW'}as never);
 if(!allowed)return NextResponse.json({error:'Access denied'},{status:403});
 try{
  const document=await buildPODocument((await params).id);
  const bytes=renderPurchaseOrderPdf(document);
  const filename=`${document.item!.po_number.replaceAll('/','-').replaceAll('\\','-')}.pdf`;
  return new NextResponse(Buffer.from(bytes),{headers:{
   'Content-Type':'application/pdf',
   'Content-Length':String(bytes.byteLength),
   'Content-Disposition':`attachment; filename=${filename}; filename*=UTF-8''${encodeURIComponent(filename)}`,
   'Cache-Control':'private, no-store'
  }});
 }catch(error){
  console.error('PO PDF generation failed',error);
  return NextResponse.json({error:'Purchase Order PDF could not be generated'},{status:500});
 }
}
