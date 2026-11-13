"use server";
import {revalidatePath} from "next/cache";
import {z} from "zod";
import {aiAdmin} from "@/lib/ai/admin";
import {settingsInput,pricingInput,featureCodes} from "@/lib/ai/validation";
import {validateModels} from "@/lib/ai/models";
import {keyFingerprint} from "@/lib/ai/config";
import {AiError,safeError} from "@/lib/ai/errors";
import {auditAi} from "@/lib/ai/usage";
async function finish(operation:()=>Promise<void>) {
 try{await operation();revalidatePath("/configuration/ai");return {ok:true,message:"AI configuration saved."}}
 catch(error){return {ok:false,message:error instanceof z.ZodError?"Check model identifiers, numeric limits, pricing and exchange-rate date.":safeError(error).message}}
}
export async function saveAiSettings(raw:unknown) {
 return finish(async()=>{
  const input=settingsInput.parse(raw);const {db,company,user}=await aiAdmin();
  if(input.enabled) {
   const models=[input.default_model,...Object.values(input.model_configuration)].filter((m):m is string=>typeof m==="string"&&m.length>0&&!input.disabled_models.includes(m));
   if(!input.default_model)throw new AiError("model_configuration","Select enabled model identifiers first.");
   await validateModels(models);const fingerprint=await keyFingerprint();
   const {data:existing}=await db.from("ai_settings").select("tested_models").eq("company_id",company).single();
   if(models.some(m=>existing?.tested_models[m]!==fingerprint))throw new AiError("model_untested","Save with AI disabled and successfully test each configured model before enabling AI.");
   const {data:prices}=await db.from("ai_model_pricing").select("model_identifier").eq("company_id",company).lte("effective_date",new Date().toISOString());
   if(models.some(m=>!prices?.some(p=>p.model_identifier===m)))throw new AiError("pricing_required","Add pricing for every configured model before enabling AI.");
  }
  const {error}=await db.from("ai_settings").update({...input,updated_by:user.id,updated_at:new Date().toISOString()}).eq("company_id",company);
  if(error)throw new AiError("save_failed","AI settings could not be saved.",503);
  await auditAi(company,user.id,"settings_saved",{fields:Object.keys(input)});
 });
}
export async function addAiPricing(raw:unknown) {
 return finish(async()=>{
  const input=pricingInput.parse(raw);const {db,company,user}=await aiAdmin();
  const {error}=await db.from("ai_model_pricing").insert({...input,company_id:company});
  if(error)throw new AiError("pricing_failed","Pricing could not be saved. Use a unique pricing version.");
  await auditAi(company,user.id,"pricing_added",{model:input.model_identifier,version:input.pricing_version});
 });
}
export async function setAiFeature(raw:unknown) {
 return finish(async()=>{
  const input=z.object({feature:z.enum(featureCodes),enabled:z.boolean()}).strict().parse(raw);
  const {db,company,user}=await aiAdmin();
  if(!["general","inventory_matching"].includes(input.feature))throw new AiError("feature_unavailable","This feature is reserved for a future integration.");
  const {error}=await db.from("ai_feature_config").update({enabled:input.enabled,updated_at:new Date().toISOString()}).eq("company_id",company).eq("feature_code",input.feature);
  if(error)throw new AiError("save_failed","Feature could not be saved.");
  await auditAi(company,user.id,"feature_changed",input);
 });
}
export async function disableAllAi() {
 return finish(async()=>{const {db,company,user}=await aiAdmin();const {error}=await db.from("ai_settings").update({enabled:false,updated_by:user.id,updated_at:new Date().toISOString()}).eq("company_id",company);if(error)throw new AiError("save_failed","AI could not be disabled.");await auditAi(company,user.id,"emergency_disable",{});});
}
