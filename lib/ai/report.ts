import "server-only";
import {z} from "zod";
import {aiIdentity} from "./permissions";
import {featureCodes} from "./validation";
import {AiError} from "./errors";
import type {Usage} from "./types";
export type Report={totals:{requests:number;success:number;failed:number;unknown:number;input_tokens:number|null;output_tokens:number|null;cached_tokens:number|null;average_ms:number|null;cost:number};daily:{label:string;cost:number;tokens:number}[];monthly:{label:string;cost:number}[];modules:{label:string;requests:number}[];models:{label:string;requests:number}[];employees:{label:string;requests:number}[];features:{label:string;requests:number}[];recent:Usage[];budget:{enabled:boolean;monthly_limit:number;daily_limit:number;usd_to_inr:number|null;exchange_rate_date:string|null;last_test_at:string|null;last_test_error:string|null;last_success_at:string|null};month_spend:number;day_spend:number};
export function reportFilters(raw:Record<string,string|undefined>) {
 const today=new Intl.DateTimeFormat("en-CA",{timeZone:"Asia/Kolkata",year:"numeric",month:"2-digit",day:"2-digit"}).format(new Date());
 const schema=z.object({from:z.iso.date(),to:z.iso.date(),user:z.string().uuid().or(z.literal("")),department:z.string().uuid().or(z.literal("")),module:z.string().max(60),feature:z.enum(featureCodes).or(z.literal("")),model:z.string().max(120)}).refine(v=>v.to>=v.from&&(Date.parse(v.to)-Date.parse(v.from))/86400000<=366,{message:"Choose a date range of up to 366 days"});
 const parsed=schema.safeParse({from:raw.from||today.slice(0,7)+"-01",to:raw.to||today,user:raw.user||"",department:raw.department||"",module:raw.module||"",feature:raw.feature||"",model:raw.model||""});
 if(!parsed.success)throw new AiError("invalid_filter","Choose valid filters and a date range of up to 366 days.");
 return parsed.data;
}
export async function usageReport(filters:ReturnType<typeof reportFilters>) {
 const {db}=await aiIdentity("configuration.ai_usage");const {data,error}=await db.rpc("ai_usage_report",{p_filters:filters});
 if(error||!data)throw new AiError("report_unavailable","AI usage reporting is unavailable. Check the migration and permissions.",503);
 return data as unknown as Report;
}
