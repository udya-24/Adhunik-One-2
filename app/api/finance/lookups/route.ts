import {NextRequest,NextResponse} from 'next/server';
import {createClient} from '@/lib/supabase/server';
export async function GET(request:NextRequest){const db=await createClient();const{data,error}=await db.rpc('search_gp_master' as never,{p_kind:request.nextUrl.searchParams.get('kind'),p_query:request.nextUrl.searchParams.get('q')??''} as never);if(error)return NextResponse.json({error:'Lookup unavailable or access denied.'},{status:403});return NextResponse.json(data,{headers:{'Cache-Control':'no-store'}});}
