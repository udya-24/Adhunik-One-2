-- Preserve historical imports. Reuse completely committed identical sources;
-- paginate saved previews and resolve repeated classifications once per validation.
begin;
create index items_import_normalized_code on public.items(lower(trim(item_code)));
create index item_categories_import_name on public.item_categories(public.item_import_normalize(name));
create index item_types_import_name on public.item_types(public.item_import_normalize(name));
create index units_import_name on public.units_of_measurement(public.item_import_normalize(name));
create index locations_import_name on public.stock_locations(public.item_import_normalize(name));
create index item_import_completed_digest on public.item_import_batches(source_sha256,sheet,created_at desc,id desc)
 where purpose='ITEM_MASTER' and state='COMMITTED';

create function public.completed_item_import_source(p_sha256 text,p_sheet text)returns uuid language plpgsql stable security definer set search_path=''as $$
declare v_id uuid;
begin
 perform public.item_import_assert_admin();
 select b.id into v_id from public.item_import_batches b
 where b.purpose='ITEM_MASTER' and b.state='COMMITTED' and b.source_sha256=p_sha256 and b.sheet=p_sheet
 and (select count(*)from public.item_import_links l where l.batch_id=b.id)=b.source_row_count
 order by b.created_at desc,b.id desc limit 1;
 return v_id;
end$$;

create function public.item_import_preview_page(p_batch uuid,p_revision integer,p_offset integer default 0,p_limit integer default 100)returns jsonb language plpgsql stable security definer set search_path=''as $$
declare b record;v_total integer;v_page jsonb;v_eligible jsonb;v_rows jsonb;
begin
 perform public.item_import_assert_admin();
 if p_offset is null or p_offset<0 or p_limit is null or p_limit not between 1 and 100 then raise exception 'Import review required: choose a preview page of 1–100 rows';end if;
 select state,revision,preview into b from public.item_import_batches where id=p_batch and purpose='ITEM_MASTER';
 if not found or b.state<>'PREVIEW' or b.revision<>p_revision then raise exception 'Import review required: preview changed; refresh the batch before selecting rows';end if;
 v_rows:=b.preview->'rows';v_total:=jsonb_array_length(v_rows);
 -- JSONB array subscripts fetch only the requested slice. Never regenerate preview.
 select coalesce(jsonb_agg(v_rows->n order by n),'[]')into v_page
 from generate_series(p_offset,least(p_offset+p_limit,v_total)-1)n;
 -- Selection metadata is small and needed once when the review first opens.
 if p_offset=0 then
  select coalesce(jsonb_agg((r->>'row')::integer order by (r->>'row')::integer),'[]')into v_eligible
  from jsonb_array_elements(v_rows)r where jsonb_array_length(r->'errors')=0;
 end if;
 return jsonb_build_object('rows',v_page,'summary',b.preview->'summary','total',v_total,'offset',p_offset,'limit',p_limit,'eligible_rows',v_eligible);
end$$;


create or replace function public.item_import_preview_rows(p_rows jsonb) returns setof jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;d jsonb;errors jsonb;warnings jsonb;maps jsonb;cat jsonb;m jsonb;existing public.items%rowtype;entry jsonb;k text;t text;cost numeric;v numeric;expected numeric;row_num integer;dupes integer;code_counts jsonb;name_counts jsonb;master_cache jsonb:='{}';cache_key text;master_name text;
begin
 perform public.item_import_assert_admin();
 if jsonb_typeof(p_rows)<>'array' or jsonb_array_length(p_rows) not between 1 and 10000 then raise exception 'Expected 1–10000 source rows';end if;
 if exists(select 1 from jsonb_array_elements(p_rows)x group by x->>'row' having count(*)>1)then raise exception 'Duplicate source row numbers';end if;
 select coalesce(jsonb_object_agg(code,n),'{}')into code_counts from(select lower(trim(x->'raw'->>'New code'))code,count(*)n from jsonb_array_elements(p_rows)x group by 1)s;
 select coalesce(jsonb_object_agg(name,n),'{}')into name_counts from(select public.item_import_normalize(x->'raw'->>'Item name')name,count(distinct lower(trim(x->'raw'->>'New code')))n from jsonb_array_elements(p_rows)x group by 1)s;
 for r in select value from jsonb_array_elements(p_rows)loop
  d:=r->'raw';errors:=coalesce(r->'issues','[]');warnings:=coalesce(r->'warnings','[]');maps:='{}';cost:=null;
  row_num:=(r->>'row')::integer;if row_num<2 then raise exception 'Invalid row number';end if;
  foreach k in array array['New code','Item name','Family','Type','Store','Unit','Status']loop
   if nullif(trim(d->>k),'')is null then errors:=errors||jsonb_build_array(k||' is required');end if;
  end loop;
  dupes:=coalesce((code_counts->>lower(trim(d->>'New code')))::integer,0);
  if dupes>1 then errors:=errors||'"Duplicate item code in workbook"'::jsonb;end if;
  if coalesce((name_counts->>public.item_import_normalize(d->>'Item name'))::integer,0)>1 then warnings:=warnings||'"Same name with a different code: retained separately"'::jsonb;end if;
  foreach k in array array['Opening qty','Rejected qty','Rate (Rs)','Value (Rs)','Rejected value (Rs)','Uses in 6 months']loop
   begin
    if coalesce(d->>k,'')!~'^[0-9]+([.][0-9]*)?([eE][+-]?[0-9]+)?$' or length(d->>k)>100 then raise exception 'Invalid number';end if;
    v:=(d->>k)::numeric;
    if v<0 or v>='1000000000000000000'::numeric then raise exception 'Out of range';end if;
    if k='Rate (Rs)' then cost:=round(v,4);if cost>=100000000000 then raise exception 'COGS overflow';end if;
     if cost=0 then warnings:=warnings||'"Zero COGS requires review; zero will be preserved"'::jsonb;end if;
    end if;
    if v<>round(v,case when k='Rate (Rs)'then 4 else 6 end)then warnings:=warnings||jsonb_build_array(k||' rounded for database precision');end if;
   exception when others then errors:=errors||jsonb_build_array(k||': invalid non-negative numeric value or overflow');end;
  end loop;
  begin
   foreach k in array array['Value (Rs)','Rejected value (Rs)']loop
    expected:=(d->>case when k='Value (Rs)' then 'Opening qty' else 'Rejected qty' end)::numeric*(d->>'Rate (Rs)')::numeric;
    if (d->>k)::numeric<>expected then warnings:=warnings||jsonb_build_array(k||' reconciliation difference: '||((d->>k)::numeric-expected)::text);end if;
    if abs((d->>k)::numeric-expected)>0.01 then warnings:=warnings||jsonb_build_array(k||': exceeds Rs 0.01 tolerance; stock proposal cannot be reviewed');end if;
   end loop;
  exception when others then null;end;
  cache_key:=jsonb_build_array('item_categories',d->>'Family')::text;
  if master_cache ? cache_key then cat:=master_cache->cache_key;else
   cat:=public.item_import_master('item_categories',d->>'Family');master_cache:=jsonb_set(master_cache,array[cache_key],cat);
  end if;maps:=maps||jsonb_build_object('category',cat);
  for k,t in select * from(values('subcategory','item_subcategories'),('type','item_types'),('unit','units_of_measurement'),('location','stock_locations'),('classification','stock_classifications'))v(k,t)loop
   master_name:=d->>case k when 'subcategory'then 'Item group'when 'type'then 'Type'when 'unit'then 'Unit'when 'location'then 'Store'else 'Status'end;
   -- Preserve raw spelling/exact-match preference and parent state in the key.
   cache_key:=jsonb_build_array(t,master_name,case when k='subcategory' then cat->>'id' end,case when k='subcategory' then cat->>'state'='NEW' end)::text;
   if master_cache ? cache_key then m:=master_cache->cache_key;else
    m:=public.item_import_master(t,master_name,nullif(cat->>'id','')::uuid,cat->>'state'='NEW');master_cache:=jsonb_set(master_cache,array[cache_key],m);
   end if;
   if k='subcategory'then m:=m||jsonb_build_object('parent_name',public.item_import_normalize(d->>'Family'));end if;
   maps:=maps||jsonb_build_object(k,m);
  end loop;
  for k,m in select key,value from jsonb_each(maps)loop
   if m->>'state' in('INACTIVE','AMBIGUOUS') or (m->>'state'='EMPTY' and k<>'subcategory')then errors:=errors||jsonb_build_array(k||': '||(m->>'state')||'; resolve explicitly in Configuration and preview again');end if;
  end loop;
  if nullif(trim(d->>'Item group'),'')is null then warnings:=warnings||'"Blank subcategory: import as null"'::jsonb;end if;
  select * into existing from public.items where lower(trim(item_code))=lower(trim(d->>'New code'));
  if found then
   if not existing.is_active then errors:=errors||'"Existing item is inactive: explicit resolution required"'::jsonb;end if;
   if existing.item_name<>trim(d->>'Item name') or existing.category_id::text is distinct from maps->'category'->>'id' or existing.subcategory_id::text is distinct from maps->'subcategory'->>'id' or existing.item_type_id::text is distinct from maps->'type'->>'id' or existing.unit_id::text is distinct from maps->'unit'->>'id' or existing.stock_classification_id::text is distinct from maps->'classification'->>'id' or existing.cogs_unit_cost is distinct from cost then
    errors:=errors||'"Existing item-code conflict: no fields or COGS will be overwritten"'::jsonb;
   end if;
   entry:=jsonb_build_object('action','REUSED','item_id',existing.id,'existing',to_jsonb(existing));
  else
   if coalesce((maps->'type'->'record'->>'automatic_code_enabled')::boolean,false)then errors:=errors||'"Automatic-code conflict: workbook code must be preserved; explicit review required"'::jsonb;end if;
   if exists(select 1 from public.items where public.item_import_normalize(item_name)=public.item_import_normalize(d->>'Item name'))then warnings:=warnings||'"Existing product has the same name: a separate item code will be created"'::jsonb;end if;
   entry:=jsonb_build_object('action','CREATE');
  end if;
  return next entry||jsonb_build_object('row',row_num,'raw',d,'errors',errors,'warnings',warnings,'mappings',maps,'cogs',cost);
 end loop;
 return;
end$$;

create or replace function public.stage_item_import(p_name text,p_sha256 text,p_source_base64 text,p_sheet text,p_rows jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;v_preview jsonb;v_existing uuid;
begin
 perform public.item_import_assert_admin();
 if encode(sha256(decode(p_source_base64,'base64')),'hex')<>p_sha256 then raise exception 'Source digest mismatch';end if;
 v_existing:=public.completed_item_import_source(p_sha256,p_sheet);
 if v_existing is not null then return v_existing;end if;
 v_preview:=public.item_import_preview(p_rows);
 insert into public.item_import_batches(source_name,source_sha256,source_base64,sheet,source_rows,preview,created_by)values(p_name,p_sha256,p_source_base64,p_sheet,p_rows,v_preview,auth.uid())returning id into v_id;
 insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(v_id,'PREVIEW_CREATED',v_preview->'summary',auth.uid());return v_id;
end$$;

create or replace function public.start_item_import_job(p_batch uuid,p_revision integer,p_rows integer[],p_request_key uuid,p_batch_size integer,p_acknowledge boolean)returns jsonb language plpgsql security definer set search_path=''as $$
declare b public.item_import_batches%rowtype;j public.item_import_jobs%rowtype;recovery jsonb;v_count integer;v_completed uuid;
begin
 perform public.item_import_assert_admin();select *into b from public.item_import_batches where id=p_batch for update nowait;if not found then raise exception 'Import not found';end if;
 -- Lost start responses and double submits return the same immutable selection/job.
 select *into j from public.item_import_jobs where batch_id=p_batch;
 if found then return public.item_import_job_progress(j.id);end if;
 v_completed:=public.completed_item_import_source(b.source_sha256,b.sheet);
 if v_completed is not null and v_completed<>p_batch then raise exception 'Import review required: this identical workbook is already fully committed. Open the completed batch instead of confirming the old preview';end if;
 if b.state<>'PREVIEW'or b.revision<>p_revision then raise exception 'Refresh the import page: source is committed, cancelled or the preview revision changed';end if;
 if not coalesce(p_acknowledge,false)then raise exception 'Administrator confirmation of selected rows, costs, location codes and per-batch atomicity is required';end if;
 if p_request_key is null or p_batch_size is null or p_batch_size not between 1 and 100 then raise exception 'Choose a batch size between 1 and 100';end if;
 if coalesce(cardinality(p_rows),0)=0 or exists(select 1 from unnest(p_rows)n group by n having count(*)>1)then raise exception 'Select distinct valid source rows';end if;
 -- Expand preview once; no nested re-expansion of the full workbook for every selected row.
 select count(*)into v_count from jsonb_array_elements(b.preview->'rows')r join unnest(p_rows)n on(r->>'row')::integer=n where jsonb_array_length(r->'errors')=0;
 if v_count<>cardinality(p_rows)then raise exception 'Selected rows contain unresolved preview errors';end if;
 recovery:=public.item_import_recovery(p_batch);
 insert into public.item_import_jobs(batch_id,request_key,preview_revision,batch_size,selected_count,recovery_before,approved_by)
 values(p_batch,p_request_key,p_revision,p_batch_size,v_count,recovery,auth.uid())returning *into j;
 insert into public.item_import_job_chunks(job_id,chunk_number,row_count)
 select j.id,((n.ordinality-1)/p_batch_size+1)::integer,count(*)from unnest(p_rows)with ordinality n(source_row,ordinality)group by 2;
 insert into public.item_import_job_rows(job_id,source_row,ordinal,chunk_number,raw,approved)
 select j.id,(r->>'row')::integer,n.ordinality::integer,((n.ordinality-1)/p_batch_size+1)::integer,r->'raw',r
 from jsonb_array_elements(b.preview->'rows')r join unnest(p_rows)with ordinality n(source_row,ordinality)on(r->>'row')::integer=n.source_row;
 update public.item_import_batches set state='IMPORTING'where id=p_batch;
 insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(p_batch,'IMPORT_JOB_STARTED',jsonb_build_object('job_id',j.id,'selected',v_count,'batch_size',p_batch_size,'recovery',recovery,'atomic_scope','CHUNK'),auth.uid());
 return public.item_import_job_progress(j.id);
end$$;

create or replace function public.refresh_item_import(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare b public.item_import_batches%rowtype;v_completed uuid;
begin perform public.item_import_assert_admin();select * into b from public.item_import_batches where id=p_id for update;if not found or b.state<>'PREVIEW'then raise exception 'Import is not in preview';end if;
 v_completed:=public.completed_item_import_source(b.source_sha256,b.sheet);
 if v_completed is not null then raise exception 'Import review required: this identical workbook is already fully committed. Open the completed batch';end if;
 update public.item_import_batches set preview=public.item_import_preview(b.source_rows),revision=revision+1 where id=p_id;
 insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(p_id,'PREVIEW_REFRESHED',jsonb_build_object('revision',b.revision+1),auth.uid());end$$;

revoke all on function public.completed_item_import_source(text,text),public.item_import_preview_page(uuid,integer,integer,integer)from public,anon;
grant execute on function public.completed_item_import_source(text,text),public.item_import_preview_page(uuid,integer,integer,integer)to authenticated;
commit;
