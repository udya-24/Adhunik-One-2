import "server-only";
import {aiIdentity} from "./permissions";
import {matchingInput,redactSecrets} from "./validation";
import {AiError} from "./errors";
import {items} from "@/lib/inventory/data";
import type {Candidate} from "./types";
export async function inventoryCandidates(input:unknown):Promise<Candidate[]> {
 await aiIdentity("ai.use");await aiIdentity("inventory.items");
 const parsed=matchingInput.safeParse(input);if(!parsed.success)throw new AiError("invalid_input","Enter a product description of 3–1,000 characters.");
 // Reuse the ERP's existing user-session/RLS search; no service-role inventory reads.
 const term=parsed.data.text.replace(/[^\p{L}\p{N} ._-]/gu," ").trim().slice(0,100);
 if(term.length<3)throw new AiError("invalid_input","Enter a searchable product name, code or description.");
 const result=await items({q:term,status:"active",page:"1"});
 if(result.error)throw new AiError("candidate_search","Item search is unavailable.",503);
 return result.rows.slice(0,10).map(row=>({id:row.id,item_code:redactSecrets(row.item_code).slice(0,100),item_name:redactSecrets(row.item_name).slice(0,200),description:row.description?redactSecrets(row.description).slice(0,500):null,model_part_number:row.model_part_number?redactSecrets(row.model_part_number).slice(0,100):null}));
}
