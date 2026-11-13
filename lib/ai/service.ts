import "server-only";
import {zodTextFormat} from "openai/helpers/zod";
import {aiClient} from "./client";
import {requireApiKey,keyFingerprint} from "./config";
import {aiIdentity} from "./permissions";
import {createAdminClient} from "@/lib/supabase/admin";
import {executeAi,type Reservation} from "./engine";
import {features,type ImplementedFeature} from "./features";
import {AiError} from "./errors";
import {auditAi,reservationError} from "./usage";
import {connectionInput} from "./validation";
import {inventoryCandidates} from "./inventory";
export async function requestAi(feature:ImplementedFeature,input:unknown,requestId:string) {
 const definition=features[feature];
 const identity=await aiIdentity(definition.permission,feature==="connection_test");
 const admin=createAdminClient();let reserved=false;
 try {
  requireApiKey();const fingerprint=await keyFingerprint();
  const task=feature==="connection_test"?connectionInput.parse(input).task:"general";
  const candidates=feature==="inventory_matching"?await inventoryCandidates(input):undefined;
  const result=await executeAi(feature,input,{
   candidates,
   reserve:async(inputTokens)=>{
    const {error:expiryError}=await admin.rpc("ai_reconcile_expired",{p_company:identity.company});
    if(expiryError)throw new AiError("accounting_unavailable","AI accounting is unavailable.",503);
    const {data,error}=await admin.rpc("ai_reserve",{p_request:requestId,p_actor:identity.user.id,p_feature:feature,p_input_tokens:inputTokens,p_task:task,p_fingerprint:fingerprint});
    if(error)throw reservationError(error.message);reserved=true;return data as unknown as Reservation;
   },
   finalize:async(status,usage,error,duration)=>{
    const {error:failure}=await admin.rpc("ai_finalize",{p_request:requestId,p_status:status,p_usage:usage,p_error:error,p_duration:duration,p_fingerprint:fingerprint});
    if(failure)throw new AiError("accounting_unconfirmed","AI accounting could not be finalized. The reservation remains held for review.",503);
   },
   call:async request=>{
    const schema=features[request.feature].output;
    const response=await aiClient(request.timeout).responses.create({model:request.model,instructions:request.instructions,input:request.input,max_output_tokens:request.maxOutput,store:false,...(schema?{text:{format:zodTextFormat(schema,"erp_result")}}:{})},{signal:request.signal});
    return {text:response.output_text,complete:response.status==="completed",usage:response.usage?{input_tokens:response.usage.input_tokens,output_tokens:response.usage.output_tokens,cached_tokens:response.usage.input_tokens_details?.cached_tokens??0}:null};
   },
  });
  return {requestId,...result,...(candidates?{candidates}: {})};
 }catch(error){
  await auditAi(identity.company,identity.user.id,reserved?"request_failed":"request_denied",{request_id:requestId,feature,category:error instanceof AiError?error.code:"internal"});
  throw error;
 }
}
