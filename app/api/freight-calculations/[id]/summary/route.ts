import {NextResponse} from 'next/server';
import {createClient} from '@/lib/supabase/server';
import {renderFreightSummary} from '@/lib/dispatch/render-freight';
export const runtime='nodejs';
export async function GET(_:Request,{params}:{params:Promise<{id:string}>}){
 const {id}=await params;const db=await createClient();const {data:{user}}=await db.auth.getUser();if(!user)return new NextResponse('Unauthorized',{status:401});
 const {data,error}=await db.from('freight_calculations').select('*').eq('id',id).maybeSingle();if(error)return new NextResponse('Freight summary unavailable',{status:500});if(!data)return new NextResponse('Freight estimate not found',{status:404});
 const pdf=renderFreightSummary(data);return new NextResponse(Buffer.from(pdf),{headers:{'Content-Type':'application/pdf','Content-Disposition':`attachment; filename="Freight_Summary_${data.id}.pdf"`,'Cache-Control':'private, no-store'}});
}
