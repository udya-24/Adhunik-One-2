-- Replace whole-workbook confirmation with durable, bounded, independently atomic chunks.
-- No timeout settings, stock functions, stock balances or stock ledgers are changed.
begin;
alter table public.item_import_batches drop constraint item_import_batches_state_check;
alter table public.item_import_batches add constraint item_import_batches_state_check check(state in('PREVIEW','IMPORTING','PARTIAL','COMMITTED','CANCELLED'));
create table public.item_import_jobs(
 id uuid primary key default gen_random_uuid(),batch_id uuid not null unique references public.item_import_batches(id)on delete restrict,
 request_key uuid not null unique,preview_revision integer not null,batch_size integer not null default 100 check(batch_size between 1 and 100),
 state text not null default 'RUNNING'check(state in('RUNNING','PAUSED','COMPLETED')),
 selected_count integer not null check(selected_count>0),recovery_before jsonb not null,
 approved_by uuid not null references auth.users(id),created_at timestamptz not null default now(),updated_at timestamptz not null default now(),completed_at timestamptz
);
create table public.item_import_job_chunks(
 job_id uuid not null references public.item_import_jobs(id)on delete restrict,chunk_number integer not null check(chunk_number>0),request_key uuid not null unique default gen_random_uuid(),
 state text not null default 'PENDING'check(state in('PENDING','COMPLETED','FAILED')),row_count integer not null check(row_count between 1 and 100),
 attempts integer not null default 0,last_attempt_key uuid,created_count integer not null default 0,reused_count integer not null default 0,
 elapsed_ms numeric,last_error_code text,last_error text,started_at timestamptz,finished_at timestamptz,
 primary key(job_id,chunk_number)
);
create table public.item_import_job_rows(
 job_id uuid not null references public.item_import_jobs(id)on delete restrict,source_row integer not null,ordinal integer not null,
 chunk_number integer not null,raw jsonb not null,approved jsonb not null,resolved_masters jsonb,
 state text not null default 'PENDING'check(state in('PENDING','CREATED','REUSED')),item_id uuid references public.items(id)on delete restrict,
 primary key(job_id,source_row),unique(job_id,ordinal),foreign key(job_id,chunk_number)references public.item_import_job_chunks(job_id,chunk_number)on delete restrict
);
create index item_import_job_rows_chunk on public.item_import_job_rows(job_id,chunk_number,state);
create table public.item_import_job_masters(
 job_id uuid not null references public.item_import_jobs(id)on delete restrict,cache_key text not null,
 master_table text not null,source_name text not null,parent_id uuid,master_id uuid not null,
 created_by_import boolean not null,primary key(job_id,cache_key)
);

create function public.item_import_recovery(p_batch uuid)returns jsonb language plpgsql security definer set search_path=''as $$
declare b public.item_import_batches%rowtype;v_result jsonb;
begin
 perform public.item_import_assert_admin();select *into b from public.item_import_batches where id=p_batch;if not found then raise exception 'Import not found';end if;
 with source as(select r->'raw' d,(r->>'cogs')::numeric source_cost from jsonb_array_elements(b.preview->'rows')r),matches as(
 select i.id,case when i.id is null then false else i.is_active and i.item_name=trim(d->>'Item name')
 and public.item_import_normalize(c.name)=public.item_import_normalize(d->>'Family')
 and((i.subcategory_id is null and nullif(trim(d->>'Item group'),'')is null)or(s.category_id=i.category_id and public.item_import_normalize(s.name)=public.item_import_normalize(d->>'Item group')))
 and public.item_import_normalize(t.name)=public.item_import_normalize(d->>'Type')
 and public.item_import_normalize(u.name)=public.item_import_normalize(d->>'Unit')
 and public.item_import_normalize(sc.name)=public.item_import_normalize(d->>'Status')
 and i.cogs_unit_cost is not distinct from source_cost end identical
 from source left join public.items i on lower(trim(i.item_code))=lower(trim(d->>'New code'))
 left join public.item_categories c on c.id=i.category_id left join public.item_subcategories s on s.id=i.subcategory_id
 left join public.item_types t on t.id=i.item_type_id left join public.units_of_measurement u on u.id=i.unit_id
 left join public.stock_classifications sc on sc.id=i.stock_classification_id)
 select jsonb_build_object('source_state',b.state,'source_rows',jsonb_array_length(b.source_rows),'existing_matching',count(*)filter(where identical),'existing_conflicting',count(*)filter(where id is not null and not coalesce(identical,false)),'linked_rows',(select count(*)from public.item_import_links where batch_id=p_batch))into v_result from matches;
 return v_result;
end$$;

create function public.item_import_job_progress(p_job uuid)returns jsonb language plpgsql security definer set search_path=''as $$
declare j public.item_import_jobs%rowtype;v_result jsonb;next_chunk jsonb;
begin
 perform public.item_import_assert_admin();select *into j from public.item_import_jobs where id=p_job;if not found then raise exception 'Import job not found';end if;
 select jsonb_build_object('chunk_number',c.chunk_number,'request_key',c.request_key,'state',c.state,'error_code',c.last_error_code,'error',c.last_error)into next_chunk from public.item_import_job_chunks c where c.job_id=p_job and c.state<>'COMPLETED'order by c.chunk_number limit 1;
 select jsonb_build_object('id',j.id,'batch_id',j.batch_id,'state',j.state,'batch_size',j.batch_size,'total',j.selected_count,
 'created',count(*)filter(where r.state='CREATED'),'existing',count(*)filter(where r.state='REUSED'),
 'completed',count(*)filter(where r.state<>'PENDING'),'failed',count(*)filter(where r.state='PENDING'and c.state='FAILED'),
 'pending',count(*)filter(where r.state='PENDING'and c.state='PENDING'),
 'percent',round(100.0*count(*)filter(where r.state<>'PENDING')/j.selected_count,2),
 'completed_batches',(select count(*)from public.item_import_job_chunks where job_id=p_job and state='COMPLETED'),
 'failed_batches',(select count(*)from public.item_import_job_chunks where job_id=p_job and state='FAILED'),
 'total_batches',(select count(*)from public.item_import_job_chunks where job_id=p_job),'next',next_chunk,'recovery_before',j.recovery_before,'atomic_scope','CHUNK')into v_result
 from public.item_import_job_rows r join public.item_import_job_chunks c using(job_id,chunk_number)where r.job_id=p_job;
 return v_result;
end$$;

create function public.start_item_import_job(p_batch uuid,p_revision integer,p_rows integer[],p_request_key uuid,p_batch_size integer,p_acknowledge boolean)returns jsonb language plpgsql security definer set search_path=''as $$
declare b public.item_import_batches%rowtype;j public.item_import_jobs%rowtype;recovery jsonb;v_count integer;
begin
 perform public.item_import_assert_admin();select *into b from public.item_import_batches where id=p_batch for update nowait;if not found then raise exception 'Import not found';end if;
 -- Lost start responses and double submits return the same immutable selection/job.
 select *into j from public.item_import_jobs where batch_id=p_batch;
 if found then return public.item_import_job_progress(j.id);end if;
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

create function public.item_import_mapping_key(p_table text,p_name text,p_parent uuid default null)returns text language sql immutable set search_path=''as $$select md5(jsonb_build_array(p_table,trim(p_name),p_parent)::text)$$;
create function public.item_import_resolve_cached(p_job uuid,p_table text,p_name text,p_parent uuid,p_approved jsonb)returns uuid language plpgsql security definer set search_path=''as $$
declare k text:=public.item_import_mapping_key(p_table,p_name,p_parent);cached public.item_import_job_masters%rowtype;m jsonb;v_id uuid;v_created boolean;
begin
 perform public.item_import_assert_admin();
 if nullif(trim(p_name),'')is null then if p_table='item_subcategories'then return null;else raise exception 'Import review required: missing classification';end if;end if;
 select *into cached from public.item_import_job_masters where job_id=p_job and cache_key=k;
 if found and(cached.master_table<>p_table or cached.source_name<>trim(p_name)or cached.parent_id is distinct from p_parent)then raise exception 'Import review required: mapping key collision';end if;
 -- Revalidate each DISTINCT mapping once per chunk, never once per product.
 m:=public.item_import_master(p_table,p_name,p_parent,false);
 if m->>'state'not in('NEW','REUSED')then raise exception 'Import review required: % classification %; resolve in Configuration before resuming',p_table,m->>'state';end if;
 if p_approved->>'state'='REUSED'and p_approved->>'id'is distinct from m->>'id'then raise exception 'Import review required: an approved classification identifier changed';end if;
 if cached.master_id is not null and cached.master_id::text is distinct from m->>'id'then raise exception 'Import review required: a previously imported classification was renamed, replaced or reparented';end if;
 if p_table='stock_locations'and p_approved->>'state'='NEW'and coalesce(m->>'code',m->'record'->>'code')is distinct from p_approved->>'code'then raise exception 'Import review required: generated location code changed; review the location explicitly';end if;
 v_created:=m->>'state'='NEW';v_id:=public.item_import_create_master(m,p_parent);
 insert into public.item_import_job_masters(job_id,cache_key,master_table,source_name,parent_id,master_id,created_by_import)
 values(p_job,k,p_table,trim(p_name),p_parent,v_id,v_created)on conflict(job_id,cache_key)do nothing;
 return v_id;
end$$;

-- Resolve each row's cache keys once. Scalar PK lookups avoid multi-way join expansion as the cache grows.
create function public.item_import_map_chunk(p_job uuid,p_chunk integer)returns table(
 source_row integer,item_code text,item_name text,category_id uuid,subcategory_id uuid,item_type_id uuid,unit_id uuid,location_id uuid,stock_classification_id uuid,cogs numeric,approved jsonb
)language sql stable set search_path=''as $$
 with source as materialized(
 select r.*,(select m.master_id from public.item_import_job_masters m where m.job_id=r.job_id and m.cache_key=public.item_import_mapping_key('item_categories',r.raw->>'Family',null))cat_id
 from public.item_import_job_rows r where r.job_id=p_job and r.chunk_number=p_chunk and r.state='PENDING')
 select r.source_row,trim(r.raw->>'New code'),trim(r.raw->>'Item name'),r.cat_id,
 (select m.master_id from public.item_import_job_masters m where m.job_id=r.job_id and m.cache_key=public.item_import_mapping_key('item_subcategories',r.raw->>'Item group',r.cat_id)),
 (select m.master_id from public.item_import_job_masters m where m.job_id=r.job_id and m.cache_key=public.item_import_mapping_key('item_types',r.raw->>'Type',null)),
 (select m.master_id from public.item_import_job_masters m where m.job_id=r.job_id and m.cache_key=public.item_import_mapping_key('units_of_measurement',r.raw->>'Unit',null)),
 (select m.master_id from public.item_import_job_masters m where m.job_id=r.job_id and m.cache_key=public.item_import_mapping_key('stock_locations',r.raw->>'Store',null)),
 (select m.master_id from public.item_import_job_masters m where m.job_id=r.job_id and m.cache_key=public.item_import_mapping_key('stock_classifications',r.raw->>'Status',null)),
 round((r.raw->>'Rate (Rs)')::numeric,4),r.approved from source r
$$;
-- Validation, insertion and linking read this compact row cache, rather than resolving six joins repeatedly.
create function public.item_import_resolved_chunk(p_job uuid,p_chunk integer)returns table(
 source_row integer,item_code text,item_name text,category_id uuid,subcategory_id uuid,item_type_id uuid,unit_id uuid,location_id uuid,stock_classification_id uuid,cogs numeric,approved jsonb
)language sql stable set search_path=''as $$
 select r.source_row,trim(r.raw->>'New code'),trim(r.raw->>'Item name'),(r.resolved_masters->>'category_id')::uuid,(r.resolved_masters->>'subcategory_id')::uuid,(r.resolved_masters->>'item_type_id')::uuid,(r.resolved_masters->>'unit_id')::uuid,(r.resolved_masters->>'location_id')::uuid,(r.resolved_masters->>'stock_classification_id')::uuid,round((r.raw->>'Rate (Rs)')::numeric,4),r.approved
 from public.item_import_job_rows r where r.job_id=p_job and r.chunk_number=p_chunk and r.state='PENDING'and r.resolved_masters is not null
$$;

create function public.item_import_safe_error(p_code text,p_message text default null)returns text language sql immutable set search_path=''as $$select case
 when p_message like 'Import review required:%'then left(p_message,500)
 when p_code='57014'then 'This batch exceeded the database time limit and was rolled back. Reduce the batch size and select Retry / Resume Import.'
 when p_code='55P03'then 'Another request is updating these records. Wait for it to finish, refresh progress, and resume.'
 when p_code='23505'then 'An item code or classification changed concurrently. Review the affected batch and resume.'
 when p_code='23503'then 'A required reference changed or was removed. Review Configuration before resuming.'
 when p_code='42501'then 'Active administrator access is required.'
 else 'This batch could not be committed. No records from this batch were saved. Review the affected source rows before resuming.'end$$;

create function public.process_item_import_chunk(p_job uuid,p_chunk integer,p_request_key uuid,p_attempt_key uuid)returns jsonb language plpgsql security definer set search_path=''as $$
declare j public.item_import_jobs%rowtype;c public.item_import_job_chunks%rowtype;v_batch uuid;mapping record;v_total integer;v_created integer:=0;v_reused integer:=0;v_error text;v_code text;v_start timestamptz:=clock_timestamp();v_result jsonb;v_max integer;v_original_count integer;v_message text;v_inserted uuid[];
begin
 perform public.item_import_assert_admin();select batch_id into v_batch from public.item_import_jobs where id=p_job;if not found then raise exception 'Import job not found';end if;
 perform 1 from public.item_import_batches where id=v_batch for update nowait;
 select *into j from public.item_import_jobs where id=p_job for update nowait;
 select *into c from public.item_import_job_chunks where job_id=p_job and chunk_number=p_chunk for update nowait;
 if not found or c.request_key<>p_request_key then raise exception 'Import review required: stale batch request key';end if;
 if c.state='COMPLETED'then return public.item_import_job_progress(p_job);end if;
 if j.state<>'RUNNING'or c.state='FAILED'then return public.item_import_job_progress(p_job);end if;
 if p_attempt_key is null then raise exception 'Import review required: attempt key required';end if;
 if exists(select 1 from public.item_import_job_chunks where job_id=p_job and chunk_number<p_chunk and state<>'COMPLETED')then raise exception 'Import review required: process the next pending batch first';end if;
 -- Explicit resume may lower the size. Split pending metadata, preserving all completed chunks.
 if c.row_count>j.batch_size then
  select max(chunk_number)into v_max from public.item_import_job_chunks where job_id=p_job;v_original_count:=c.row_count;
  insert into public.item_import_job_chunks(job_id,chunk_number,row_count)
  select p_job,v_max+part,count(*)from(select ((row_number()over(order by ordinal)-1)/j.batch_size)::integer part from public.item_import_job_rows where job_id=p_job and chunk_number=p_chunk and state='PENDING')x where part>0 group by part;
  with ranked as(select source_row,((row_number()over(order by ordinal)-1)/j.batch_size)::integer part from public.item_import_job_rows where job_id=p_job and chunk_number=p_chunk and state='PENDING')
  update public.item_import_job_rows r set chunk_number=v_max+x.part from ranked x where r.job_id=p_job and r.source_row=x.source_row and x.part>0;
  update public.item_import_job_chunks set row_count=j.batch_size where job_id=p_job and chunk_number=p_chunk;c.row_count:=j.batch_size;
  insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(v_batch,'IMPORT_CHUNK_SPLIT',jsonb_build_object('job_id',p_job,'chunk',p_chunk,'previous_size',v_original_count,'new_size',j.batch_size),auth.uid());
 end if;
 update public.item_import_job_chunks set attempts=attempts+1,last_attempt_key=p_attempt_key,started_at=clock_timestamp()where job_id=p_job and chunk_number=p_chunk;
 begin
  -- Bounded lock ownership; NOWAIT turns contention into a resumable error rather than a timeout.
  lock table public.item_categories,public.item_subcategories,public.item_types,public.units_of_measurement,public.stock_locations,public.stock_classifications,public.items in share row exclusive mode nowait;
  for mapping in select distinct raw->>'Family'name,approved->'mappings'->'category'mapping from public.item_import_job_rows where job_id=p_job and chunk_number=p_chunk and state='PENDING'loop
   perform public.item_import_resolve_cached(p_job,'item_categories',mapping.name,null,mapping.mapping);
  end loop;
  for mapping in select distinct v.master_table,v.name,v.mapping,case when v.master_table='item_subcategories'then cat.master_id end parent
   from public.item_import_job_rows src
   join public.item_import_job_masters cat on cat.job_id=src.job_id and cat.cache_key=public.item_import_mapping_key('item_categories',src.raw->>'Family',null)
   cross join lateral(values('item_subcategories',src.raw->>'Item group',src.approved->'mappings'->'subcategory'),('item_types',src.raw->>'Type',src.approved->'mappings'->'type'),('units_of_measurement',src.raw->>'Unit',src.approved->'mappings'->'unit'),('stock_locations',src.raw->>'Store',src.approved->'mappings'->'location'),('stock_classifications',src.raw->>'Status',src.approved->'mappings'->'classification'))v(master_table,name,mapping)
   where src.job_id=p_job and src.chunk_number=p_chunk and src.state='PENDING'loop
   perform public.item_import_resolve_cached(p_job,mapping.master_table,mapping.name,mapping.parent,mapping.mapping);
  end loop;
  update public.item_import_job_rows dest set resolved_masters=jsonb_build_object('category_id',s.category_id,'subcategory_id',s.subcategory_id,'item_type_id',s.item_type_id,'unit_id',s.unit_id,'location_id',s.location_id,'stock_classification_id',s.stock_classification_id)
   from public.item_import_map_chunk(p_job,p_chunk)s where dest.job_id=p_job and dest.source_row=s.source_row and s.category_id is not null and s.item_type_id is not null and s.unit_id is not null and s.location_id is not null and s.stock_classification_id is not null and(s.subcategory_id is not null or nullif(trim(s.approved->'raw'->>'Item group'),'')is null);
  select count(*)into v_total from public.item_import_resolved_chunk(p_job,p_chunk);
  if v_total<>c.row_count then raise exception 'Import review required: incomplete batch mappings';end if;
  -- Set-based existing-code reconciliation happens BEFORE any product insertion.
  if exists(select 1 from public.item_import_resolved_chunk(p_job,p_chunk)s where s.approved->>'item_id'is not null and not exists(select 1 from public.items i where i.id=(s.approved->>'item_id')::uuid and lower(trim(i.item_code))=lower(trim(s.item_code))))then raise exception 'Import review required: an approved existing product was removed or its code changed';end if;
  select 'Import review required: source row '||s.source_row||' ('||s.item_code||') conflicts with an existing product; existing fields and COGS were preserved'into v_message
   from public.item_import_resolved_chunk(p_job,p_chunk)s join public.items i on lower(trim(i.item_code))=lower(trim(s.item_code))
   where not i.is_active or i.item_name<>s.item_name or i.category_id is distinct from s.category_id or i.subcategory_id is distinct from s.subcategory_id or i.item_type_id is distinct from s.item_type_id or i.unit_id is distinct from s.unit_id or i.stock_classification_id is distinct from s.stock_classification_id or i.cogs_unit_cost is distinct from s.cogs or(s.approved->>'item_id'is not null and s.approved->>'item_id'<>i.id::text)limit 1;
  if v_message is not null then raise exception '%',v_message;end if;
  if exists(select 1 from public.item_import_resolved_chunk(p_job,p_chunk)s join public.item_types t on t.id=s.item_type_id where t.automatic_code_enabled and not exists(select 1 from public.items i where lower(trim(i.item_code))=lower(trim(s.item_code))))then raise exception 'Import review required: automatic-code conflict; workbook codes must be preserved';end if;
  -- Reconcile surviving links from an earlier attempt without modifying or duplicating them.
  if exists(select 1 from public.item_import_resolved_chunk(p_job,p_chunk)s join public.item_import_links l on l.batch_id=v_batch and l.source_row=s.source_row join public.items i on i.id=l.item_id where lower(trim(i.item_code))<>lower(trim(s.item_code))or l.unit_id<>s.unit_id or l.location_id<>s.location_id)then raise exception 'Import review required: prior committed source links differ from the reviewed mapping';end if;
  with inserted as(insert into public.items(item_code,item_name,category_id,subcategory_id,item_type_id,unit_id,stock_classification_id,cogs_unit_cost,created_by,updated_by)
   select s.item_code,s.item_name,s.category_id,s.subcategory_id,s.item_type_id,s.unit_id,s.stock_classification_id,s.cogs,auth.uid(),auth.uid()from public.item_import_resolved_chunk(p_job,p_chunk)s
   where not exists(select 1 from public.items i where lower(trim(i.item_code))=lower(trim(s.item_code)))returning id)
  select coalesce(array_agg(id),array[]::uuid[])into v_inserted from inserted;
  v_created:=cardinality(v_inserted);v_reused:=v_total-v_created;
  -- New inserts belong to this transaction; pre-existing records retain all their values/timestamps.
  with resolved as materialized(select *from public.item_import_resolved_chunk(p_job,p_chunk))
  insert into public.item_import_links(batch_id,source_row,item_id,location_id,unit_id,resolved_masters)
   select v_batch,s.source_row,i.id,s.location_id,s.unit_id,jsonb_build_object('category_id',s.category_id,'subcategory_id',s.subcategory_id,'item_type_id',s.item_type_id,'unit_id',s.unit_id,'location_id',s.location_id,'stock_classification_id',s.stock_classification_id)
   from resolved s join public.items i on lower(trim(i.item_code))=lower(trim(s.item_code))on conflict(batch_id,source_row)do nothing;
  -- Use INSERT RETURNING IDs, never timestamps, to distinguish new and pre-existing rows.
  update public.item_import_job_rows src set item_id=i.id,state=case when i.id=any(v_inserted)then 'CREATED'else 'REUSED'end
   from public.item_import_resolved_chunk(p_job,p_chunk)s join public.items i on lower(trim(i.item_code))=lower(trim(s.item_code))where src.job_id=p_job and src.source_row=s.source_row;
  -- Counts are derived from durable row outcomes and verified against the actual insert count.
  if(select count(*)from public.item_import_job_rows where job_id=p_job and chunk_number=p_chunk and state='CREATED')<>v_created then raise exception 'Import review required: inconsistent batch result';end if;
  update public.item_import_job_chunks set state='COMPLETED',created_count=v_created,reused_count=v_reused,elapsed_ms=extract(epoch from clock_timestamp()-v_start)*1000,last_error=null,last_error_code=null,finished_at=clock_timestamp()where job_id=p_job and chunk_number=p_chunk;
  insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(v_batch,'IMPORT_CHUNK_COMMITTED',jsonb_build_object('job_id',p_job,'chunk',p_chunk,'request_key',p_request_key,'attempt_key',p_attempt_key,'created',v_created,'reused',v_reused,'atomic_scope','CHUNK'),auth.uid());
 exception when others then
  get stacked diagnostics v_code=returned_sqlstate,v_error=message_text;
  update public.item_import_job_chunks set state='FAILED',last_error_code=v_code,last_error=public.item_import_safe_error(v_code,v_error),elapsed_ms=extract(epoch from clock_timestamp()-v_start)*1000,finished_at=clock_timestamp()where job_id=p_job and chunk_number=p_chunk;
  update public.item_import_jobs set state='PAUSED',updated_at=now()where id=p_job;
  update public.item_import_batches set state='PARTIAL'where id=v_batch;
  insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(v_batch,'IMPORT_CHUNK_FAILED',jsonb_build_object('job_id',p_job,'chunk',p_chunk,'attempt_key',p_attempt_key,'code',v_code,'message',public.item_import_safe_error(v_code,v_error),'rolled_back',true),auth.uid());
  return public.item_import_job_progress(p_job);
 end;
 if not exists(select 1 from public.item_import_job_chunks where job_id=p_job and state<>'COMPLETED')then
  update public.item_import_jobs set state='COMPLETED',completed_at=clock_timestamp(),updated_at=now()where id=p_job;
  select jsonb_build_object('created',count(*)filter(where state='CREATED'),'reused',count(*)filter(where state='REUSED'),'updated',0,'failed',0,'skipped',(select jsonb_array_length(source_rows)from public.item_import_batches where id=v_batch)-j.selected_count,'atomic_scope','CHUNK','job_id',p_job,
   'classifications',(select jsonb_build_object('created',count(*)filter(where created_by_import),'reused',count(*)filter(where not created_by_import),'unresolved',0)from(select master_table,master_id,bool_or(created_by_import)created_by_import from public.item_import_job_masters where job_id=p_job group by master_table,master_id)m))into v_result from public.item_import_job_rows where job_id=p_job;
  update public.item_import_batches set state='COMMITTED',result=v_result,committed_at=clock_timestamp(),committed_by=auth.uid()where id=v_batch;
  insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(v_batch,'MASTER_IMPORT_COMPLETED',v_result,auth.uid());
 else update public.item_import_jobs set updated_at=now()where id=p_job;end if;
 return public.item_import_job_progress(p_job);
end$$;

-- A cancelled statement rolls back its own state changes. Record that failure in a NEW request.
-- If the first response was lost after commit, the completed chunk is never marked failed.
create function public.record_item_import_chunk_failure(p_job uuid,p_chunk integer,p_request_key uuid,p_attempt_key uuid,p_code text)returns jsonb language plpgsql security definer set search_path=''as $$
declare j public.item_import_jobs%rowtype;c public.item_import_job_chunks%rowtype;
begin
 perform public.item_import_assert_admin();select *into j from public.item_import_jobs where id=p_job;if not found then raise exception 'Import job not found';end if;
 perform 1 from public.item_import_batches where id=j.batch_id for update nowait;
 perform 1 from public.item_import_jobs where id=p_job for update nowait;
 select *into c from public.item_import_job_chunks where job_id=p_job and chunk_number=p_chunk for update nowait;
 if not found or c.request_key<>p_request_key or c.state='COMPLETED'or(c.last_attempt_key=p_attempt_key and c.state='FAILED')then return public.item_import_job_progress(p_job);end if;
 if p_code='55P03'then return public.item_import_job_progress(p_job);end if;
 update public.item_import_job_chunks set state='FAILED',attempts=attempts+case when last_attempt_key is not distinct from p_attempt_key then 0 else 1 end,last_attempt_key=p_attempt_key,last_error_code=left(p_code,10),last_error=public.item_import_safe_error(p_code),finished_at=clock_timestamp()where job_id=p_job and chunk_number=p_chunk;
 update public.item_import_jobs set state='PAUSED',updated_at=now()where id=p_job;
 update public.item_import_batches set state='PARTIAL'where id=j.batch_id;
 insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(j.batch_id,'IMPORT_CHUNK_INTERRUPTED',jsonb_build_object('job_id',p_job,'chunk',p_chunk,'attempt_key',p_attempt_key,'code',left(p_code,10),'message',public.item_import_safe_error(p_code),'completed_chunks_preserved',true),auth.uid());
 return public.item_import_job_progress(p_job);
end$$;
create function public.resume_item_import_job(p_job uuid,p_batch_size integer)returns jsonb language plpgsql security definer set search_path=''as $$
declare j public.item_import_jobs%rowtype;
begin
 perform public.item_import_assert_admin();select *into j from public.item_import_jobs where id=p_job;if not found then raise exception 'Import job not found';end if;
 perform 1 from public.item_import_batches where id=j.batch_id for update nowait;
 select *into j from public.item_import_jobs where id=p_job for update nowait;
 if j.state='COMPLETED'then return public.item_import_job_progress(p_job);end if;
 if p_batch_size is null or p_batch_size not between 1 and 100 then raise exception 'Choose a batch size between 1 and 100';end if;
 update public.item_import_jobs set state='RUNNING',batch_size=p_batch_size,updated_at=now()where id=p_job;
 update public.item_import_job_chunks set state='PENDING'where job_id=p_job and state='FAILED';
 update public.item_import_batches set state='IMPORTING'where id=j.batch_id;
 insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(j.batch_id,'IMPORT_JOB_RESUMED',jsonb_build_object('job_id',p_job,'batch_size',p_batch_size,'completed_chunks_preserved',true),auth.uid());
 return public.item_import_job_progress(p_job);
end$$;
-- Old deployed clients must not accidentally re-enter the expensive all-workbook path.
create or replace function public.commit_item_import(p_id uuid,p_revision integer,p_rows integer[],p_acknowledge boolean)returns jsonb language plpgsql security definer set search_path=''as $$begin
 perform public.item_import_assert_admin();raise exception 'Refresh the application and use the resumable Item Master import. Whole-workbook confirmation is no longer supported.';
end$$;

do $$declare t text;f record;begin
 foreach t in array array['item_import_jobs','item_import_job_chunks','item_import_job_rows','item_import_job_masters']loop
  execute format('alter table public.%I enable row level security',t);
  execute format('create policy admin_read on public.%I for select to authenticated using(public.is_erp_admin()and public.has_active_erp_access())',t);
  execute format('grant select on public.%I to authenticated',t);
 end loop;
 for f in select p.oid::regprocedure signature,p.proname name from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public'and p.proname in('item_import_recovery','item_import_job_progress','start_item_import_job','item_import_mapping_key','item_import_resolve_cached','item_import_map_chunk','item_import_resolved_chunk','item_import_safe_error','process_item_import_chunk','record_item_import_chunk_failure','resume_item_import_job')loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  if f.name in('item_import_recovery','item_import_job_progress','start_item_import_job','process_item_import_chunk','record_item_import_chunk_failure','resume_item_import_job')then execute format('grant execute on function %s to authenticated',f.signature);end if;
 end loop;
end$$;
comment on table public.item_import_jobs is 'Resumable selected Item Master rows. Each chunk is atomic; the entire job is intentionally not atomic. Stock posting remains unavailable.';
commit;
