import {PageHeader} from "@/components/ui/page-header";
import {requireAdmin} from "@/lib/identity/data";
import {adminConfiguration} from "@/lib/ai/admin";
import {keyConfigured,keyFingerprint} from "@/lib/ai/config";
import {AiError} from "@/lib/ai/errors";
import {AiConfigurationLoader} from "@/components/ai/loaders";
export default async function AiConfigurationPage(){
 await requireAdmin();
 let data:Awaited<ReturnType<typeof adminConfiguration>>;let configured:boolean;let tested:boolean;
 try {
  data=await adminConfiguration();configured=keyConfigured();const fingerprint=configured?await keyFingerprint():null;
  tested=Boolean(fingerprint&&data.settings.tested_models[data.settings.tested_model??""]===fingerprint);
 }catch(error){return <><PageHeader title="AI Configuration" description="Central OpenAI integration"/><div className="card p-6">{error instanceof AiError?error.message:"AI configuration is temporarily unavailable."}</div></>}
 return <><PageHeader title="AI Configuration" description="Manage OpenAI connection, read-only features and ERP spending controls."/><AiConfigurationLoader {...data} configured={configured} tested={tested}/></>;
}
