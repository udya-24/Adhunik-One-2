import {PGlite} from '../../node_modules/.cache/gp-validation/node_modules/@electric-sql/pglite/dist/index.js';
import {readFileSync} from 'node:fs';
export const foundation = `
create role anon; create role authenticated;
create schema auth; create schema storage;
create table auth.users(id uuid primary key);
create function auth.uid()returns uuid language sql stable as $$select nullif(current_setting('test.uid',true),'')::uuid$$;
create function public.is_erp_admin()returns boolean language sql stable as $$select current_setting('test.role',true)='ADMIN'$$;
create function public.has_active_erp_access()returns boolean language sql stable as $$select current_setting('test.role',true)in('ADMIN','MANAGER','USER')$$;
create function public.current_erp_role()returns text language sql stable as $$select current_setting('test.role',true)$$;
create function public.can_manage_crm()returns boolean language sql stable as $$select current_setting('test.role',true)in('ADMIN','MANAGER')$$;
create function public.set_updated_at()returns trigger language plpgsql as $$begin new.updated_at=clock_timestamp();return new;end$$;
create table public.proforma_invoice_items(id uuid primary key,inventory_item_id uuid);
create table public.packing_list_items(id uuid primary key,pi_item_id uuid,item_length_mm numeric,item_breadth_mm numeric,item_height_mm numeric);
create table public.packing_lists(id uuid primary key,status text);
create table public.dispatches(id uuid primary key,status text);
create table storage.buckets(id text primary key,name text,public boolean,file_size_limit bigint,allowed_mime_types text[]);
create table storage.objects(id uuid,bucket_id text,name text);
grant usage on schema public,auth,storage to authenticated,anon;
insert into auth.users values('00000000-0000-0000-0000-000000000001');
select set_config('test.uid','00000000-0000-0000-0000-000000000001',false),set_config('test.role','ADMIN',false);
`;
export async function prepareImportSchema(db, {instrumentLegacy=false, resumable=false}={}) {
 await db.exec(foundation);
 for(const file of ['202608240012_phase_7a_enterprise_item_master.sql','202608240013_phase_7b_inventory_foundation.sql'])await db.exec(readFileSync(new URL('../../supabase/migrations/'+file,import.meta.url),'utf8'));
 await db.exec('alter table items add column cogs_unit_cost numeric(15,4)check(cogs_unit_cost>=0)');
 let migration=readFileSync(new URL('../../supabase/migrations/202611120001_item_master_excel_import.sql',import.meta.url),'utf8');
 if(instrumentLegacy){
  await db.exec('create table import_benchmark_phases(phase text,elapsed_ms numeric)');
  migration=migration.replace('declare b public.item_import_batches%rowtype;fresh jsonb;', 'declare phase_start timestamptz;step_start timestamptz;class_ms numeric:=0;item_ms numeric:=0;b public.item_import_batches%rowtype;fresh jsonb;');
  const mark=(name)=>`insert into public.import_benchmark_phases values('${name}',extract(epoch from clock_timestamp()-phase_start)*1000);phase_start:=clock_timestamp();`;
  migration=migration.replace(' lock table public.item_categories,',' phase_start:=clock_timestamp();lock table public.item_categories,');
  migration=migration.replace(' fresh:=public.item_import_preview(b.source_rows);',mark('lock acquisition')+'fresh:=public.item_import_preview(b.source_rows);'+mark('full preview revalidation'));
  const selectionEnd=' select (select count(*)from public.item_categories)';
  migration=migration.replace(selectionEnd,mark('selected row validation')+selectionEnd);
  migration=migration.replace(' for r in select value from jsonb_array_elements(fresh', ' phase_start:=clock_timestamp();for r in select value from jsonb_array_elements(fresh');
  migration=migration.replace("  d:=r->'raw';m:=r->'mappings';", "  step_start:=clock_timestamp();d:=r->'raw';m:=r->'mappings';");
  migration=migration.replace("cls:=public.item_import_create_master(m->'classification');", "cls:=public.item_import_create_master(m->'classification');class_ms:=class_ms+extract(epoch from clock_timestamp()-step_start)*1000;step_start:=clock_timestamp();");
  migration=migration.replace(" end loop;\n select (select count(*)from public.item_categories)", " item_ms:=item_ms+extract(epoch from clock_timestamp()-step_start)*1000;end loop;\n insert into public.import_benchmark_phases values('classification resolution/create',class_ms),('item/link writes including triggers',item_ms);select (select count(*)from public.item_categories)");
  migration=migration.replace(' into masters_after;', ' into masters_after;'+mark('classification/item/link writes'));
 }
 await db.exec(migration);
 if(resumable)await db.exec(readFileSync(new URL('../../supabase/migrations/202611120002_resumable_item_master_import.sql',import.meta.url),'utf8'));
}
export async function createImportDatabase(options){const db=new PGlite();await prepareImportSchema(db,options);return db;}
export const scalar=async(db,sql,args=[])=>Object.values((await db.query(sql,args)).rows[0])[0];
