import {NextResponse} from "next/server";
import {packingList} from "@/lib/dispatch/data";
import {renderPackingPdf} from "@/lib/dispatch/render-pdf";
import {currentAccess} from "@/lib/security/access";
import {createAdminClient} from "@/lib/supabase/admin";
import {createClient} from "@/lib/supabase/server";

export const runtime="nodejs";

export async function GET(_request:Request,{params}:{params:Promise<{id:string}>}){
  const {id}=await params;
  const db=await createClient();
  const [{data:{user}},access]=await Promise.all([db.auth.getUser(),currentAccess()]);
  if(!user)return new NextResponse("Unauthorized",{status:401});
  if(!access.grants["dispatch.packing_lists"]?.canView)return new NextResponse("Forbidden",{status:403});
  try{
    const detail=await packingList(id);
    if(!detail.item)throw new Error("Packing List not found");
    const bytes=renderPackingPdf(detail.item,detail.items,detail.packages,detail.contents);
    const safe=detail.item.packing_list_number.replace(/[^a-zA-Z0-9-]/g,"-");
    try{await createAdminClient().from("packing_list_activities").insert({packing_list_id:id,activity_type:"PDF_GENERATED",description:"Packing List PDF generated",created_by:user.id})}catch{}
    return new NextResponse(Buffer.from(bytes),{headers:{"Content-Type":"application/pdf","Content-Disposition":`attachment; filename="Packing_List_${safe}.pdf"`,"Cache-Control":"private, no-store"}});
  }catch(error){
    return new NextResponse(error instanceof Error?error.message:"Unavailable",{status:404});
  }
}
