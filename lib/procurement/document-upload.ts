import 'server-only';
import {createClient} from '@/lib/supabase/server';
import {createAdminClient} from '@/lib/supabase/admin';
import {commercialBucket,validateCommercialFile} from './documents';
export async function uploadCommercialFile(form:FormData,key:string){const file=form.get(key);if(!(file instanceof File)||!file.size)return null;if(file.size>1048576)throw new Error('Maximum file size is 1 MB.');const bytes=new Uint8Array(await file.arrayBuffer()),mime=validateCommercialFile(file.name,file.type,bytes),name=file.name.replace(/[^a-zA-Z0-9._-]/g,'_').slice(-160),path=`${crypto.randomUUID()}/${name}`;const {error}=await (await createClient()).storage.from(commercialBucket).upload(path,bytes,{contentType:mime});if(error)throw new Error(error.message);return{name,path};}
export async function removeCommercialFiles(paths:string[]){if(paths.length){const{error}=await createAdminClient().storage.from(commercialBucket).remove(paths);if(error)console.error('Unlinked commercial upload cleanup failed',error.message);}}
