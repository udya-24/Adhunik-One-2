import type {OpeningProgress,OpeningResult}from"./types";
/** Explicit approval starts one request per chunk; a failed or uncertain response is never retried automatically. */
export async function runOpeningChunks(initial:OpeningProgress,step:(p:OpeningProgress)=>Promise<OpeningResult>,notify:(p:OpeningProgress)=>void){
  let p=initial;notify(p);
  while(p.state==="RUNNING"&&p.next){
    const result=await step(p);if(result.error||!result.progress)throw new Error(result.error||"Could not read stock posting progress. Refresh before resuming.");
    if(result.progress.state==="RUNNING"&&result.progress.posted<=p.posted&&result.progress.next?.id===p.next.id)throw new Error("Stock posting did not advance. Refresh progress before resuming.");
    p=result.progress;notify(p);
  }
  return p;
}
export function openingError(code?:string,message?:string){
  if(message?.startsWith("Opening stock review required:")||message?.startsWith("No valid positive")||message?.startsWith("Selected rows have")||message?.startsWith("Stock state or mappings changed")||message?.startsWith("Review the current draft")||message?.startsWith("Explicit approval")||message?.startsWith("Select at most one"))return message.slice(0,500);
  if(code==="57014")return "This stock batch timed out. Earlier postings remain saved. Refresh and reapprove the pending preview.";
  if(code==="55P03")return "Another request is updating inventory. Wait, refresh progress, and review pending rows.";
  if(code==="23505")return "An opening or source transaction already exists. Refresh the preview; do not add stock again.";
  if(code==="42501"||message==="FORBIDDEN"||message==="UNAUTHORIZED")return "Active Admin access is required for bulk opening stock.";
  return "The stock request could not be confirmed. Refresh progress and review pending rows before continuing.";
}
