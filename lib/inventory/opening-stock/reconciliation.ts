import type{OpeningRow}from"./types";
/** Exact totals per stable unit; unresolved/incompatible source units never enter a different unit's totals. */
export function reconcileOpeningStock(rows:OpeningRow[],parseDecimal:(value:string,scale:number)=>{scaled:bigint}){
 const totals=new Map<string,{unit_id:string|null;unit:string;unresolved:boolean;excel:bigint;rejected:bigint;selected:bigint;posted:bigint;invalid_source_values:number}>();
 for(const r of rows){
  const mapped=!!r.unit_id&&r.unit_id===r.snapshot.source_unit_id,key=mapped?r.unit_id!:"unresolved:"+(r.raw.Unit||"").trim().replace(/\s+/g," ").toLowerCase();
  const t=totals.get(key)||{unit_id:mapped?r.unit_id:null,unit:mapped?(r.snapshot.unit||r.raw.Unit):r.raw.Unit||"Unresolved",unresolved:!mapped,excel:BigInt(0),rejected:BigInt(0),selected:BigInt(0),posted:BigInt(0),invalid_source_values:0};
  function amount(s:string,source=false){try{const n=parseDecimal(s,6).scaled;if(n>=BigInt(10)**BigInt(24))throw new Error("Overflow");return n;}catch{if(source)t.invalid_source_values++;return BigInt(0);}}
  t.excel+=amount(r.raw["Opening qty"],true);t.rejected+=amount(r.raw["Rejected qty"],true);
  if(r.is_selected)t.selected+=amount(r.snapshot.quantity||"0");if(r.state==="POSTED")t.posted+=amount(r.snapshot.quantity||"0");totals.set(key,t);
 }
 const fixed=(n:bigint)=>{const s=n.toString().padStart(7,"0");return s.slice(0,-6)+"."+s.slice(-6);};
 return [...totals.values()].map(t=>({unit_id:t.unit_id,unit:t.unit,unresolved_source_unit:t.unresolved,excel_opening:fixed(t.excel),rejected_unposted:fixed(t.rejected),selected:fixed(t.selected),posted:fixed(t.posted),invalid_source_values:t.invalid_source_values}));
}
