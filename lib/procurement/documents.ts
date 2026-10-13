import {validateGpFile} from '@/lib/finance/documents';
export const commercialBucket='purchase-commercial-documents';
export function validateCommercialFile(name:string,mime:string,bytes:Uint8Array){if(bytes.length>1048576)throw new Error('Maximum file size is 1 MB.');return validateGpFile(name,mime,bytes);}
