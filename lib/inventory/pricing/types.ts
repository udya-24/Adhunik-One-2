export type ValuationRow={item_id:string;location_id:string|null;classification_id:string|null;classification:string|null;cogs:string|null;selling:string|null;usable:string|null;rejected:string|null;damaged:string|null;physical:string|null;missing_cogs:boolean};
export type ValuationGroup={classification_id:string|null;classification:string|null;usable:string;rejected:string;damaged:string;physical:string;missing_cogs:number};
export type ValuationSummary=Omit<ValuationGroup,"classification_id"|"classification">&{groups:ValuationGroup[]};
export type PriceImport={id:string;source_batch_id:string|null;source_name:string;source_sha256:string;sheet:string;state:"DRAFT"|"RUNNING"|"PAUSED"|"COMPLETED";revision:number;reason:string|null;created_at:string};
export type PriceRow={source_usable_difference:string|null;source_rejected_difference:string|null;row:number;code:string;name:string|null;unit:string;old_cogs:string|null;new_cogs:string|null;selling:string|null;state:string;error:string|null;warning:string|null;raw:Record<string,string>};
export type PricePage={rows:PriceRow[];eligible:number[]|null;offset:number};
export type PriceProgress={id:string;state:PriceImport["state"];revision:number;total:number;ready:number;unchanged:number;invalid:number;posted:number;pending:number;next:{id:string;key:string;sequence:number;error:string|null}|null};
export type PriceResult={id?:string;error?:string;progress?:PriceProgress;page?:PricePage};

export type ItemValuation=Omit<ValuationRow,"location_id"|"classification_id"|"classification">;
