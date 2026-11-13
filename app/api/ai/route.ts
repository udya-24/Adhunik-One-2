import {z} from "zod";
import {requestAi} from "@/lib/ai/service";
import {AiError,safeError} from "@/lib/ai/errors";
export const runtime="nodejs";
export const maxDuration=60;
const envelope=z.object({feature:z.enum(["general","inventory_matching","connection_test"]),input:z.unknown(),requestId:z.string().uuid()}).strict();
export async function POST(request:Request) {
 let requestId=crypto.randomUUID();
 try {
  const origin=request.headers.get("origin");
  if(!origin||origin!==new URL(request.url).origin)throw new AiError("origin","Invalid request origin.",403);
  if(!request.headers.get("content-type")?.startsWith("application/json"))throw new AiError("invalid_input","Expected JSON input.",415);
  // Enforce the cap while reading, rather than trusting Content-Length.
  const reader=request.body?.getReader();if(!reader)throw new AiError("invalid_input","Request body is required.");
  let size=0;const chunks:Uint8Array[]=[];
  for(;;){const {value,done}=await reader.read();if(done)break;size+=value.byteLength;if(size>20000){await reader.cancel();throw new AiError("invalid_input","Request is too large.",413)}chunks.push(value)}
  const bytes=new Uint8Array(size);let offset=0;for(const chunk of chunks){bytes.set(chunk,offset);offset+=chunk.length}
  let json:unknown;try{json=JSON.parse(new TextDecoder().decode(bytes))}catch{throw new AiError("invalid_input","Invalid JSON.")}
  const parsed=envelope.safeParse(json);if(!parsed.success)throw new AiError("invalid_input","Invalid AI request.");
  requestId=parsed.data.requestId;
  const result=await requestAi(parsed.data.feature,parsed.data.input,requestId);
  return Response.json(result,{headers:{"Cache-Control":"no-store"}});
 }catch(error){const safe=safeError(error);return Response.json({requestId,error:safe.message,code:safe.code},{status:safe.status,headers:{"Cache-Control":"no-store"}})}
}
