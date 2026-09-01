"use client";

import {useEffect,useId,useMemo,useRef,useState} from "react";

export type ItemMasterOption={id:string;item_code:string;item_name:string;description:string|null;model_part_number:string|null;hsn_code:string|null;item_brands:{name:string}|null;units_of_measurement:{name:string;code:string|null}|null};

export function ItemMasterCombobox({items,value,onChange}:{items:ItemMasterOption[];value:string;onChange:(item:ItemMasterOption|null)=>void}){
  const root=useRef<HTMLDivElement>(null),resultsId=useId(),selected=items.find(item=>item.id===value),[open,setOpen]=useState(false),[query,setQuery]=useState("");
  useEffect(()=>{const close=(event:MouseEvent)=>{if(!root.current?.contains(event.target as Node))setOpen(false)};document.addEventListener("mousedown",close);return()=>document.removeEventListener("mousedown",close)},[]);
  const matches=useMemo(()=>{const q=query.trim().toLocaleLowerCase();return(q?items.filter(item=>[item.item_code,item.item_name,item.description,item.item_brands?.name,item.model_part_number].some(text=>text?.toLocaleLowerCase().includes(q))):items).slice(0,50)},[items,query]);
  return <div className="relative mt-1" ref={root}>
    <input className="field" role="combobox" aria-expanded={open} aria-controls={resultsId} autoComplete="off" placeholder="Search item code, name, brand or model…" value={open?query:selected?`${selected.item_code} · ${selected.item_name}`:""} onFocus={()=>{setQuery("");setOpen(true)}} onChange={event=>{setQuery(event.target.value);setOpen(true)}} onKeyDown={event=>{if(event.key==="Escape")setOpen(false)}}/>
    {open&&<div id={resultsId} role="listbox" className="absolute z-30 mt-1 max-h-72 w-full overflow-y-auto rounded-lg border bg-white p-1 shadow-lg">
      <button type="button" role="option" aria-selected={!value} className="block w-full rounded-md px-3 py-2 text-left text-sm hover:bg-slate-100" onClick={()=>{onChange(null);setOpen(false);setQuery("")}}>Manual / custom item</button>
      {matches.map(item=><button type="button" role="option" aria-selected={item.id===value} className="block w-full rounded-md px-3 py-2 text-left hover:bg-slate-100" key={item.id} onClick={()=>{onChange(item);setOpen(false);setQuery("")}}><span className="block text-sm font-semibold">{item.item_code} · {item.item_name}</span>{[item.item_brands?.name,item.model_part_number,item.description].filter(Boolean).length>0&&<span className="block truncate text-xs text-slate-500">{[item.item_brands?.name,item.model_part_number,item.description].filter(Boolean).join(" · ")}</span>}</button>)}
      {!matches.length&&<p className="px-3 py-3 text-sm text-slate-500">No matching Item Master records.</p>}
      {matches.length===50&&<p className="px-3 py-2 text-xs text-slate-400">Showing the first 50 matches. Refine your search for more.</p>}
    </div>}
  </div>
}
