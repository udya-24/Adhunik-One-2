import {aiIdentity} from "@/lib/ai/permissions";
import {reportFilters} from "@/lib/ai/report";
import {safeError} from "@/lib/ai/errors";
export const runtime="nodejs";
export const maxDuration=60;
const columns=["request_id","created_at","completed_at","user_id","employee_id","department_id","module","feature","model","status","input_tokens","output_tokens","cached_input_tokens","total_tokens","estimated_cost_usd","calculated_cost_usd","pricing_version","duration_ms","error_category"] as const;
function csv(value:unknown){let text=String(value??"");if(/^[\s]*[=+@-]/.test(text))text="'"+text;return '"'+text.replace(/"/g,'""')+'"'}
export async function GET(request:Request){
 try{
 const {db,company}=await aiIdentity("configuration.ai_usage");const f=reportFilters(Object.fromEntries(new URL(request.url).searchParams));
 const start=f.from+"T00:00:00+05:30";const next=new Date(Date.parse(f.to+"T00:00:00+05:30")+86400000).toISOString();
 const query=()=>{let q=db.from("ai_usage_logs").select(columns.join(",")).eq("company_id",company).gte("created_at",start).lt("created_at",next).order("created_at").order("request_id");if(f.user)q=q.eq("user_id",f.user);if(f.department)q=q.eq("department_id",f.department);if(f.module)q=q.eq("module",f.module);if(f.feature)q=q.eq("feature",f.feature);if(f.model)q=q.eq("model",f.model);return q};
 // Read first page before returning headers so initial database errors are visible.
 const first=await query().range(0,499);if(first.error)throw first.error;
 let offset=0;let rows:typeof first.data|null=first.data;let finished=false;let cancelled=false;const encoder=new TextEncoder();
 const stream=new ReadableStream<Uint8Array>({
  start(controller){controller.enqueue(encoder.encode("\ufeff"+columns.join(",")+"\r\n"))},
  async pull(controller){
   if(finished){controller.close();return}
   try {
    if(rows===null){offset+=500;const page=await query().range(offset,offset+499);if(page.error)throw page.error;rows=page.data}
    if(cancelled)return;
    const pageRows=rows??[];
    if(pageRows.length){const lines=pageRows.map(row=>{const data=row as unknown as Record<string,unknown>;return columns.map(c=>csv(data[c])).join(",")+"\r\n"}).join("");controller.enqueue(encoder.encode(lines))}
    finished=pageRows.length<500;rows=null;
    if(!pageRows.length)controller.close();
   }catch{if(!cancelled)controller.error(new Error("AI export interrupted; retry the export."))}
  },
  cancel(){cancelled=true},
 });
 return new Response(stream,{headers:{"Content-Type":"text/csv; charset=utf-8","Content-Disposition":'attachment; filename="ai-usage.csv"',"Cache-Control":"no-store","X-Content-Type-Options":"nosniff"}});
 }catch(error){const safe=safeError(error);return Response.json({error:safe.message},{status:safe.status})}
}
