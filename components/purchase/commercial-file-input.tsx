'use client';
export function CommercialFileInput({name,required=false}:{name:string;required?:boolean}){return <input className="field mt-1" type="file" name={name} required={required} accept=".pdf,.jpg,.jpeg,.png" onChange={event=>{const input=event.currentTarget,file=input.files?.[0];input.setCustomValidity(file&&file.size>1048576?'Maximum file size is 1 MB.':'');input.reportValidity();}}/>;}
