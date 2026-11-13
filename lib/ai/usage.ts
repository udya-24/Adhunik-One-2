import "server-only";
import {createAdminClient} from "@/lib/supabase/admin";
import {AiError} from "./errors";
const messages:Record<string,string>={AI_DISABLED:"This AI feature is disabled.",AI_MODEL_UNTESTED:"Test the selected model before using this feature.",AI_MODEL_UNAVAILABLE:"Select an enabled model.",AI_PRICING_REQUIRED:"Configure versioned pricing for this model first.",AI_REQUEST_BUDGET:"The maximum estimated request cost exceeds its limit.",AI_DAILY_BUDGET:"The daily AI budget is exhausted or not configured.",AI_MONTHLY_BUDGET:"The monthly AI budget is exhausted or not configured.",AI_USER_BUDGET:"Your monthly AI budget is exhausted or not configured.",AI_USER_RATE:"Your daily AI request limit has been reached.",AI_CONCURRENCY:"AI is busy. Please try again later.",AI_DUPLICATE:"This request ID was already used. Review usage before sending a new request.",AI_FORBIDDEN:"AI access is not permitted.",AI_FEATURE_UNAVAILABLE:"This AI feature is not available."};
export function reservationError(message:string) {const code=Object.keys(messages).find(c=>message.includes(c));return new AiError(code??"accounting_unavailable",code?messages[code]:"AI accounting is unavailable. No request was initiated.",code==="AI_FORBIDDEN"?403:code==="AI_DUPLICATE"?409:429)}
export async function auditAi(company:string,user:string,event:string,details:Record<string,unknown>) {
 const {error}=await createAdminClient().from("ai_audit_events").insert({company_id:company,user_id:user,event_type:event,details});
 if(error)throw new AiError("audit_unavailable","AI audit logging is unavailable.",503);
}
