import type {PriceProgress,PriceResult}from"./types.ts";
export async function runPriceChunks(initial:PriceProgress,step:(p:PriceProgress)=>Promise<PriceResult>,onProgress:(p:PriceProgress)=>void){
 let p=initial;onProgress(p);
 while(p.state==="RUNNING"&&p.next){const result=await step(p);if(result.error||!result.progress)throw new Error(result.error||"Price request interrupted. Read saved progress before resuming.");const next=result.progress;if(next.state==="RUNNING"&&next.posted<=p.posted&&next.next?.id===p.next.id)throw new Error("Price progress did not advance. Refresh before resuming.");p=next;onProgress(p);}
 return p;
}
export function priceError(code?:string,message?:string){
 if(message?.startsWith("Price review required:"))return message.slice(0,500);
 if(code==="57014")return "Price batch timed out and was rolled back. Earlier completed batches remain saved. Refresh pending prices and approve again.";
 if(code==="55P03")return "Another request is updating these prices. Read saved progress before resuming.";
 if(code==="42501"||message?.includes("permission required")||message?.includes("Admin"))return "Active Admin access and Item Master Edit permission are required.";
 return "Price import request failed. Check saved progress and the pricing migration before retrying; stock quantities and selling prices are never changed by this flow.";
}
