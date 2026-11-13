import {readFileSync}from'node:fs';
import{randomUUID,createHash}from'node:crypto';
import{createImportDatabase,scalar}from'./item-import-fixture.mjs';
export async function createStockDatabase(){const db=await createImportDatabase({resumable:true});await db.exec(readFileSync(new URL('../../supabase/migrations/202611120003_bulk_opening_stock_import.sql',import.meta.url),'utf8'));return db;}
export const stockRow=(row,code,quantity='10',extra={})=>({row,raw:{'New code':code,'Item name':code+' product','Item group':'Motor','Type':'Raw material','Family':'MCC','Store':'Store A1','Unit':'PCS','Status':'Keep: active','Opening qty':quantity,'Rejected qty':'0','Rate (Rs)':'1','Value (Rs)':quantity,'Rejected value (Rs)':'0','Uses in 6 months':'0','Last used':'',...extra},issues:[],warnings:[]});
export async function seedStockItems(db,data){
 const bytes=Buffer.from('master-'+randomUUID()),sha=createHash('sha256').update(bytes).digest('hex');
 const id=await scalar(db,'select stage_item_import($1,$2,$3,$4,$5::jsonb)',['test.xlsx',sha,bytes.toString('base64'),'Sheet1',JSON.stringify(data)]);
 let p=await scalar(db,'select start_item_import_job($1,1,$2,$3,100,true)',[id,data.map(r=>r.row),randomUUID()]);
 while(p.state==='RUNNING'&&p.next)p=await scalar(db,'select process_item_import_chunk($1,$2,$3,$4)',[p.id,p.next.chunk_number,p.next.request_key,randomUUID()]);
 if(p.state!=='COMPLETED')throw new Error(p.next?.error||'Master seed failed');return id;
}
export async function stageStock(db,data){const b=Buffer.from('stock-'+randomUUID());return scalar(db,'select stage_opening_stock_workbook($1,$2,$3,$4,$5::jsonb)',['test.xlsx',createHash('sha256').update(b).digest('hex'),b.toString('base64'),'Sheet1',JSON.stringify(data)]);}
export const stockProgress=(db,id)=>scalar(db,'select opening_stock_progress($1)',[id]);
export const stockRows=(db,id)=>scalar(db,'select jsonb_agg(to_jsonb(r)order by source_row)from opening_stock_import_rows r where import_id=$1',[id]);
export async function approveStock(db,id,size=100,key=randomUUID()){
 const revision=await scalar(db,'select revision from opening_stock_imports where id=$1',[id]);
 return scalar(db,'select approve_opening_stock_import($1,$2,$3,$4,$5,$6,$7,true)',[id,revision,key,'2026-11-12','Local opening stock acceptance','SKIP',size]);
}
export const stockStep=(db,p,attempt=randomUUID())=>scalar(db,'select process_opening_stock_chunk($1,$2,$3,$4)',[p.id,p.next.id,p.next.request_key,attempt]);
export async function finishStock(db,p){while(p.state==='RUNNING'&&p.next)p=await stockStep(db,p);return p;}
export async function editStock(db,id,changes){const revision=await scalar(db,'select revision from opening_stock_imports where id=$1',[id]);await scalar(db,'select edit_opening_stock_preview($1,$2,$3::jsonb)',[id,revision,JSON.stringify(changes)]);}
