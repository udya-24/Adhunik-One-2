// Local measurements only. ITEM_IMPORT_WORKBOOK is read-only; no Supabase connection.
import {readFileSync}from'node:fs';
import{createImportDatabase,scalar}from'./helpers/item-import-fixture.mjs';
import{readWorkbook}from'../lib/inventory/import/workbook.ts';
const source=await readWorkbook(readFileSync(process.env.ITEM_IMPORT_WORKBOOK));
const db=await createImportDatabase({instrumentLegacy:true});
const start=performance.now();
const id=await scalar(db,'select stage_item_import($1,$2,$3,$4,$5::jsonb)',['benchmark.xlsx',source.sha256,readFileSync(process.env.ITEM_IMPORT_WORKBOOK).toString('base64'),source.sheet,JSON.stringify(source.rows)]);
console.log('Legacy stage ms:',Math.round(performance.now()-start));
const commitStart=performance.now();
await scalar(db,'select commit_item_import($1,1,$2,true)',[id,source.rows.map(r=>r.row)]);
console.log('Legacy confirmation ms:',Math.round(performance.now()-commitStart));
console.log(JSON.stringify((await db.query('select *from import_benchmark_phases')).rows));
await db.close();
