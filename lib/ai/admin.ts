import "server-only";
import {requireAdmin} from "@/lib/identity/data";
import {createAdminClient} from "@/lib/supabase/admin";
import {AiError} from "./errors";
export async function aiAdmin() {
 const {supabase,user}=await requireAdmin();
 const {data:company,error}=await supabase.rpc("ai_current_company");
 if(error||!company)throw new AiError("migration_required","AI database setup is not available. Apply the central AI migration to your development database.",503);
 return {db:createAdminClient(),company,user};
}
export async function adminConfiguration() {
 const {db,company}=await aiAdmin();
 const [{data:settings,error},{data:features},{data:pricing},{data:profiles},{data:events}]=await Promise.all([
  db.from("ai_settings").select("*").eq("company_id",company).single(),
  db.from("ai_feature_config").select("*").eq("company_id",company).order("feature_code"),
  db.from("ai_model_pricing").select("*").eq("company_id",company).order("effective_date",{ascending:false}).limit(100),
  db.from("erp_profiles").select("auth_user_id,login_email").eq("is_active",true),
  db.from("ai_audit_events").select("*").eq("company_id",company).eq("event_type","budget_threshold").order("created_at",{ascending:false}).limit(10),
 ]);
 if(error||!settings)throw new AiError("configuration_unavailable","AI configuration could not be loaded.",503);
 return {settings,features:features??[],pricing:pricing??[],profiles:profiles??[],alerts:events??[]};
}
