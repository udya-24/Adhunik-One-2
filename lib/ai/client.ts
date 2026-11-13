import "server-only";
import OpenAI from "openai";
import {requireApiKey} from "./config";
// Do not honor browser input or an alternate base URL. No SDK-level retries of uncertain requests.
export function aiClient(timeout=15000) { return new OpenAI({apiKey:requireApiKey(),baseURL:"https://api.openai.com/v1",timeout,maxRetries:0}); }
