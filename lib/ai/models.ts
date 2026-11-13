import "server-only";
import {aiClient} from "./client";
import {AiError} from "./errors";
export async function validateModels(models:string[]) {
 const client=aiClient(10000);
 for(const model of [...new Set(models.filter(Boolean))]) {
  try { const accessible=await client.models.retrieve(model); if(accessible.id!==model) throw new Error("Unavailable"); }
  catch { throw new AiError("model_unavailable","A configured model is unavailable to this OpenAI project. Check model identifiers and project access."); }
 }
}
