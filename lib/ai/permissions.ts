import "server-only";
import {createClient} from "@/lib/supabase/server";
import {AiError} from "./errors";
export async function aiIdentity(permission:string,adminOnly=false) {
 const db=await createClient(); const {data:{user},error}=await db.auth.getUser();
 if(error||!user) throw new AiError("unauthorized","Sign in to use AI.",401);
 const [{data:company,error:scopeError},{data:admin},{data:allowed}]=await Promise.all([db.rpc("ai_current_company"),db.rpc("is_erp_admin"),db.rpc("has_erp_permission",{p_section_key:permission,p_access_type:"VIEW"})]);
 if(scopeError||!company||!allowed||(adminOnly&&!admin)) {
  if(company&&!scopeError){const {auditAi}=await import("./usage");await auditAi(company,user.id,"access_denied",{permission});}
  throw new AiError("forbidden","AI access is not permitted.",403);
 }
 return {db,user,company,admin:Boolean(admin)};
}
