import {features,type ImplementedFeature} from "./features.ts";
import {AiError,safeError} from "./errors.ts";
import {instructions} from "./prompts.ts";
import {redactSecrets} from "./validation.ts";
import type {AiSettings,Pricing,Candidate} from "./types.ts";
export type ReportedUsage={input_tokens:number;output_tokens:number;cached_tokens:number};
export type Reservation={settings:AiSettings;model:string;pricing:Pricing;max_output_tokens:number;estimated_cost_usd:string};
export type ProviderResult={text:string;usage:ReportedUsage|null;complete:boolean};
export type EngineDependencies={
 reserve:(inputTokens:number)=>Promise<Reservation>;
 finalize:(status:string,usage:ReportedUsage|null,error:string|null,duration:number)=>Promise<void>;
 call:(request:{model:string;instructions:string;input:string;maxOutput:number;timeout:number;feature:ImplementedFeature;signal:AbortSignal})=>Promise<ProviderResult>;
 candidates?:Candidate[];
};
export async function executeAi(feature:ImplementedFeature,raw:unknown,deps:EngineDependencies) {
 const definition=features[feature];
 const parsed=definition.input.safeParse(raw);
 if(!parsed.success)throw new AiError("invalid_input","AI input is invalid or too large.");
 const data=parsed.data;
 const system=instructions(feature,"mode" in data&&typeof data.mode==="string"?data.mode:undefined);
 const content=feature==="connection_test" ? "Connection check" : JSON.stringify({untrusted_text:redactSecrets("text" in data?data.text:""),...(feature==="inventory_matching"?{untrusted_candidates:deps.candidates??[]}: {})});
 // UTF-8 bytes are a conservative ceiling for text tokenization. Allow schema/framing overhead.
 const inputTokens=new TextEncoder().encode(system+content).length+4096;
 if(inputTokens>80000)throw new AiError("invalid_input","AI request is too large.");
 const reservation=await deps.reserve(inputTokens);
 const start=Date.now();let result:ProviderResult|undefined;let output:unknown;let failure:unknown;
 const controller=new AbortController();const timer=setTimeout(()=>controller.abort(),reservation.settings.timeout_ms);
 try {
  for(let attempt=0;;attempt++) {
   try { result=await deps.call({model:reservation.model,instructions:system+` Desired response length: ${reservation.settings.response_length??"medium"}.`,input:content,maxOutput:reservation.max_output_tokens,timeout:reservation.settings.timeout_ms,feature,signal:controller.signal});break; }
   catch(error) {
    // Retry only an explicit HTTP 429 rejection. Never retry ambiguous network/5xx/timeouts.
    const status=typeof error==="object"&&error!==null&&"status" in error?Number(error.status):0;
    if(status!==429||attempt>=reservation.settings.retry_limit||controller.signal.aborted)throw error;
    await new Promise(resolve=>setTimeout(resolve,Math.min(250*(attempt+1),750)));
   }
  }
  if(!result.complete||!result.text)throw new AiError("invalid_output","AI returned an incomplete or refused response.",502);
  if(result.text.length>24000)throw new AiError("invalid_output","AI response exceeded the output limit.",502);
  if(definition.output) {
   let json:unknown;try{json=JSON.parse(result.text)}catch{throw new AiError("invalid_output","AI returned invalid structured output.",502)}
   const valid=definition.output.safeParse(json);if(!valid.success)throw new AiError("invalid_output","AI response did not match the required schema.",502);
   output=valid.data;
   if(feature==="inventory_matching") {
    const ids=new Set((deps.candidates??[]).map(c=>c.id));
    const matches=(output as {matches:{id:string}[]}).matches;
    if(matches.some(m=>!ids.has(m.id))||new Set(matches.map(m=>m.id)).size!==matches.length)throw new AiError("invalid_output","AI suggested an item outside the authorized candidates.",502);
   }
  }else output={answer:result.text};
 }catch(error){failure=error}finally{clearTimeout(timer)}
 const normalized=failure?safeError(failure):null;
 const status=failure?((result?.usage||["provider_auth","rate_limit","model_configuration"].includes(normalized!.code))?"failed":"unknown"):"success";
 // A failed accounting write never returns an unaccounted successful result. Reservation remains held.
 await deps.finalize(status,result?.usage??null,normalized?.code??null,Date.now()-start);
 if(normalized)throw normalized;
 return {output,model:reservation.model,usage:result?.usage??null,estimatedCostUsd:reservation.estimated_cost_usd};
}
