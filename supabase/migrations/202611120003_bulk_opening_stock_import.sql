-- Bulk usable opening stock. Approved rule: Opening qty is usable; Rejected qty is NOT posted.
-- Existing item/master/stock history is never overwritten. No historical migration changes.
begin;
alter table public.item_import_batches add column purpose text not null default 'ITEM_MASTER'check(purpose in('ITEM_MASTER','OPENING_STOCK'));
create table public.opening_stock_imports(
 id uuid primary key default gen_random_uuid(),source_batch_id uuid not null references public.item_import_batches(id)on delete restrict,
 state text not null default 'DRAFT'check(state in('DRAFT','RUNNING','PAUSED','COMPLETED','CANCELLED')),revision integer not null default 1,
 quantity_policy text not null default 'USABLE_OPENING_EXCLUDE_REJECTED'check(quantity_policy='USABLE_OPENING_EXCLUDE_REJECTED'),
 existing_policy text not null default 'SKIP'check(existing_policy in('SKIP','REVIEW')),batch_size integer not null default 100 check(batch_size between 1 and 100),
 effective_date date,reason text,approved_by uuid references auth.users(id),approved_at timestamptz,request_key uuid unique,
 created_by uuid not null references auth.users(id),created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table public.opening_stock_posting_chunks(
 id uuid primary key default gen_random_uuid(),import_id uuid not null references public.opening_stock_imports(id)on delete restrict,
 revision integer not null,sequence integer not null,state text not null default 'PENDING'check(state in('PENDING','POSTED','FAILED','SUPERSEDED')),
 request_key uuid not null unique default gen_random_uuid(),row_count integer not null check(row_count between 1 and 100),
 approval jsonb not null,attempts integer not null default 0,last_attempt_key uuid,last_error_code text,last_error text,posted_at timestamptz,
 unique(import_id,revision,sequence)
);
create table public.opening_stock_import_rows(
 id uuid primary key default gen_random_uuid(),import_id uuid not null references public.opening_stock_imports(id)on delete restrict,source_row integer not null,
 raw jsonb not null,parser_issues jsonb not null default '[]',quantity_text text not null,location_override uuid references public.stock_locations(id)on delete restrict,
 is_selected boolean not null default true,item_id uuid references public.items(id)on delete restrict,unit_id uuid references public.units_of_measurement(id)on delete restrict,location_id uuid references public.stock_locations(id)on delete restrict,
 quantity numeric(24,6),snapshot jsonb not null default '{}',state text not null default 'DRAFT'check(state in('DRAFT','PENDING','POSTED','SKIPPED','INVALID')),
 chunk_id uuid references public.opening_stock_posting_chunks(id)on delete restrict,transaction_id uuid unique references public.inventory_transactions(id)on delete restrict,
 approved_snapshot jsonb,posted_at timestamptz,posted_by uuid references auth.users(id),skip_reason text,
 unique(import_id,source_row),check((state='POSTED')=(transaction_id is not null))
);
create index opening_stock_rows_chunk on public.opening_stock_import_rows(chunk_id,state);
create index opening_stock_rows_import on public.opening_stock_import_rows(import_id,source_row);
create unique index inventory_excel_opening_source_once on public.inventory_transactions(reference_id)
 where reference_type='OPENING_STOCK_EXCEL'and transaction_type='OPENING_STOCK'and reversal_of is null;

create function public.opening_stock_quantity(p_text text,p_round boolean default false)returns numeric language plpgsql immutable set search_path=''as $$
declare q numeric;
begin
 if coalesce(p_text,'')!~'^[0-9]+([.][0-9]*)?([eE][+-]?[0-9]+)?$'or length(p_text)>100 then return null;end if;
 q:=p_text::numeric;if q<0 or q>=1000000000000000000 then return null;end if;
 if not p_round and q<>round(q,6)then return null;end if;q:=round(q,6);if q>=1000000000000000000 then return null;end if;return q;
exception when others then return null;end$$;

-- Stable snapshot includes ALL locations/history for an item, including zero balances and ABA movements.
create function public.opening_stock_inventory_snapshot(p_item uuid,p_location uuid)returns jsonb language sql stable set search_path=''as $$
 select jsonb_build_object('item',jsonb_build_object('id',i.id,'code',i.item_code,'name',i.item_name,'unit_id',i.unit_id,'active',i.is_active,'version',i.updated_at,'classification_id',i.stock_classification_id),
 'unit',jsonb_build_object('id',u.id,'name',u.name,'active',u.is_active,'version',u.updated_at),
 'location',jsonb_build_object('id',l.id,'name',l.name,'active',l.is_active,'version',l.updated_at),
 'balances',coalesce((select jsonb_agg(to_jsonb(b)order by b.location_id)from public.inventory_balances b where b.item_id=i.id),'[]'),
 'history_count',(select count(*)from public.inventory_transactions t where t.item_id=i.id),
 'opening_count',(select count(*)from public.inventory_transactions t where t.item_id=i.id and t.transaction_type='OPENING_STOCK'),
 'on_hand',coalesce((select on_hand_quantity from public.inventory_balances b where b.item_id=i.id and b.location_id=l.id),0),
 'reserved',coalesce((select reserved_quantity from public.inventory_balances b where b.item_id=i.id and b.location_id=l.id),0),
 'damaged',coalesce((select damaged_quantity from public.inventory_balances b where b.item_id=i.id and b.location_id=l.id),0))
 from public.items i join public.units_of_measurement u on u.id=i.unit_id left join public.stock_locations l on l.id=p_location where i.id=p_item
$$;

-- Reuse existing exact/normalized master resolution once per unique source Unit/Store, never create values.
create function public.opening_stock_preview_rows(p_import uuid)returns setof jsonb language plpgsql security definer set search_path=''as $$
declare row_data record;errors jsonb;warnings jsonb;q numeric;validation text;inventory jsonb;source_quantity numeric;result jsonb;
begin
 perform public.item_import_assert_admin();
 for row_data in
 with source as materialized(select r.*,j.source_batch_id from public.opening_stock_import_rows r join public.opening_stock_imports j on j.id=r.import_id where r.import_id=p_import and r.state<>'POSTED'),
 unit_names as materialized(select distinct raw->>'Unit'name from source),location_names as materialized(select distinct raw->>'Store'name from source),
 units as materialized(select name,public.item_import_master('units_of_measurement',name)m from unit_names),
 locations as materialized(select name,public.item_import_master('stock_locations',name)m from location_names),
 duplicate_codes as(select lower(trim(raw->>'New code'))code,count(*)n,count(*)filter(where is_selected)selected_count from source group by 1)
 select r.*,i.id matched_item,i.item_name current_name,i.unit_id current_unit,i.is_active item_active,sc.name current_classification,
 coalesce(link.unit_id,nullif(u.m->>'id','')::uuid)source_unit,
 coalesce(r.location_override,link.location_id,nullif(l.m->>'id','')::uuid)target_location,
 dup.n duplicates,dup.selected_count
 from source r left join public.items i on lower(trim(i.item_code))=lower(trim(r.raw->>'New code'))
 left join public.item_import_links link on link.batch_id=r.source_batch_id and link.source_row=r.source_row and link.item_id=i.id
 left join public.stock_classifications sc on sc.id=i.stock_classification_id
 left join units u on u.name=r.raw->>'Unit'left join locations l on l.name=r.raw->>'Store'
 join duplicate_codes dup on dup.code is not distinct from lower(trim(r.raw->>'New code'))
 order by r.source_row
 loop
  select coalesce(jsonb_agg(value)filter(where value like 'Unsupported formula%'),'[]'),coalesce(jsonb_agg('Source: '||value)filter(where value not like 'Unsupported formula%'),'[]')into errors,warnings from jsonb_array_elements_text(coalesce(row_data.parser_issues,'[]'));q:=null;source_quantity:=null;
  if row_data.matched_item is null then errors:=errors||'"Item code not found; no Item Master will be created"'::jsonb;
  elsif not row_data.item_active then errors:=errors||'"Item is inactive"'::jsonb;end if;
  if row_data.current_name is distinct from trim(row_data.raw->>'Item name')then warnings:=warnings||'"Excel item name differs from current Item Master; matching uses the permanent code"'::jsonb;end if;
  if row_data.current_classification is distinct from row_data.raw->>'Status'then warnings:=warnings||'"Source stock classification differs from the current item; no classification will be changed"'::jsonb;end if;
  if row_data.duplicates>1 then warnings:=warnings||'"Duplicate source code: select at most one row and save the preview"'::jsonb;end if;
  if row_data.selected_count>1 then errors:=errors||'"More than one selected row has this item code"'::jsonb;end if;
  if row_data.source_unit is null or row_data.source_unit is distinct from row_data.current_unit then errors:=errors||'"Excel Unit cannot be matched to the item unit; no conversion is assumed"'::jsonb;end if;
  if row_data.target_location is null then errors:=errors||'"Stock Location is missing, ambiguous or unmapped; select an existing location"'::jsonb;end if;
  begin
   if coalesce(row_data.quantity_text,'')!~'^[0-9]+([.][0-9]*)?([eE][+-]?[0-9]+)?$'or length(row_data.quantity_text)>100 then raise exception 'Invalid';end if;
   q:=row_data.quantity_text::numeric;
   if q<0 or q>=1000000000000000000 or q<>round(q,6)then raise exception 'Invalid precision';end if;
  exception when others then q:=null;errors:=errors||'"Quantity must be non-negative, within range and have at most six decimal places"'::jsonb;end;
  begin
   source_quantity:=(row_data.raw->>'Opening qty')::numeric;
   if source_quantity<>round(source_quantity,6)then warnings:=warnings||jsonb_build_array('Excel Opening qty rounds to '||round(source_quantity,6)::text||' at the inventory precision');end if;
  exception when others then warnings:=warnings||'"Excel Opening qty is invalid; review the explicitly edited proposed quantity"'::jsonb;end;
  inventory:=public.opening_stock_inventory_snapshot(row_data.matched_item,row_data.target_location);
  if not coalesce((inventory->'unit'->>'active')::boolean,false)then errors:=errors||'"Select an active item unit"'::jsonb;end if;
  if not coalesce((inventory->'location'->>'active')::boolean,false)then errors:=errors||'"Select an active Stock Location"'::jsonb;end if;
  if jsonb_array_length(errors)>0 then validation:='INVALID';
  elsif jsonb_array_length(inventory->'balances')>0 or(inventory->>'history_count')::bigint>0 then validation:='EXISTING';warnings:=warnings||'"Existing inventory balance or movement history: leave unposted here and review through the authorized adjustment workflow"'::jsonb;
  elsif q=0 then validation:='ZERO';else validation:='VALID';end if;
  result:=jsonb_build_object('row',row_data.source_row,'item_id',row_data.matched_item,'unit_id',row_data.current_unit,'source_unit_id',row_data.source_unit,'location_id',row_data.target_location,'item_code',row_data.raw->>'New code','item_name',row_data.current_name,'source_name',row_data.raw->>'Item name','unit',inventory->'unit'->>'name','location',inventory->'location'->>'name','source_store',row_data.raw->>'Store','source_status',row_data.raw->>'Status','classification',row_data.current_classification,
   'excel_quantity',row_data.raw->>'Opening qty','rejected_quantity',row_data.raw->>'Rejected qty','quantity',case when q is not null then q::numeric(24,6)::text end,
   'existing_quantity',coalesce(inventory->>'on_hand','0'),'delta',case when validation='VALID'then q::numeric(24,6)::text else '0'end,
   'resulting_quantity',case when validation='VALID'then q::numeric(24,6)::text else coalesce(inventory->>'on_hand','0')end,
   'validation',validation,'errors',errors,'warnings',warnings,'inventory',inventory);
  return next result;
 end loop;return;
end$$;

create function public.refresh_opening_stock_preview(p_id uuid)returns void language plpgsql security definer set search_path=''as $$
declare j public.opening_stock_imports%rowtype;
begin
 perform public.item_import_assert_admin();select *into j from public.opening_stock_imports where id=p_id for update nowait;
 if not found or j.state not in('DRAFT','PAUSED')then raise exception 'Stock import must be a draft or paused before reviewing pending rows';end if;
 update public.opening_stock_posting_chunks set state='SUPERSEDED'where import_id=p_id and state in('PENDING','FAILED');
 update public.opening_stock_import_rows set state='DRAFT',chunk_id=null,approved_snapshot=null,skip_reason=null where import_id=p_id and state<>'POSTED';
 with reviewed as materialized(select value from public.opening_stock_preview_rows(p_id)value)
 update public.opening_stock_import_rows r set snapshot=s.value,item_id=nullif(s.value->>'item_id','')::uuid,unit_id=nullif(s.value->>'unit_id','')::uuid,location_id=nullif(s.value->>'location_id','')::uuid,quantity=nullif(s.value->>'quantity','')::numeric,
 is_selected=r.is_selected and s.value->>'validation'='VALID'
 from reviewed s where r.import_id=p_id and r.source_row=(s.value->>'row')::integer;
 update public.opening_stock_imports set state='DRAFT',revision=revision+1,approved_by=null,approved_at=null,request_key=null,updated_at=now()where id=p_id;
 insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(j.source_batch_id,'OPENING_STOCK_PREVIEW_REVIEWED',jsonb_build_object('import_id',p_id,'revision',j.revision+1,'posted_rows_unchanged',true),auth.uid());
end$$;
create function public.create_opening_stock_preview(p_source uuid)returns uuid language plpgsql security definer set search_path=''as $$
declare source public.item_import_batches%rowtype;v_id uuid;
begin
 perform public.item_import_assert_admin();select *into source from public.item_import_batches where id=p_source;
 if not found or(source.purpose='ITEM_MASTER'and source.state<>'COMMITTED')then raise exception 'Choose a completed Item Master source or upload an opening stock workbook';end if;
 insert into public.opening_stock_imports(source_batch_id,created_by)values(p_source,auth.uid())returning id into v_id;
 insert into public.opening_stock_import_rows(import_id,source_row,raw,parser_issues,quantity_text)
 select v_id,(r->>'row')::integer,r->'raw',coalesce(r->'issues','[]'),coalesce(public.opening_stock_quantity(r->'raw'->>'Opening qty',true)::numeric(24,6)::text,r->'raw'->>'Opening qty','') from jsonb_array_elements(source.source_rows)r;
 perform public.refresh_opening_stock_preview(v_id);return v_id;
end$$;
create function public.stage_opening_stock_workbook(p_name text,p_sha256 text,p_source_base64 text,p_sheet text,p_rows jsonb)returns uuid language plpgsql security definer set search_path=''as $$
declare v_source uuid;
begin
 perform public.item_import_assert_admin();if encode(sha256(decode(p_source_base64,'base64')),'hex')<>p_sha256 then raise exception 'Workbook digest mismatch';end if;
 if exists(select 1 from jsonb_array_elements(p_rows)r group by r->>'row'having count(*)>1)then raise exception 'Duplicate source row numbers';end if;
 insert into public.item_import_batches(source_name,source_sha256,source_base64,sheet,source_rows,preview,created_by,purpose)values(p_name,p_sha256,p_source_base64,p_sheet,p_rows,'{"rows":[],"summary":{}}',auth.uid(),'OPENING_STOCK')returning id into v_source;
 return public.create_opening_stock_preview(v_source);
end$$;

create function public.edit_opening_stock_preview(p_id uuid,p_revision integer,p_changes jsonb)returns void language plpgsql security definer set search_path=''as $$
declare j public.opening_stock_imports%rowtype;
begin
 perform public.item_import_assert_admin();select *into j from public.opening_stock_imports where id=p_id for update nowait;
 if not found or j.state<>'DRAFT'or j.revision<>p_revision then raise exception 'Refresh the draft before editing; posted rows cannot be changed';end if;
 if jsonb_typeof(p_changes)<>'array'or jsonb_array_length(p_changes)>10000 then raise exception 'Invalid preview changes';end if;
 if exists(select 1 from jsonb_array_elements(p_changes)c group by c->>'row'having count(*)>1)then raise exception 'Duplicate preview edits';end if;
 if exists(select 1 from jsonb_array_elements(p_changes)c where not exists(select 1 from public.opening_stock_import_rows r where r.import_id=p_id and r.source_row=(c->>'row')::integer and r.state<>'POSTED'))then raise exception 'A source row is missing or already posted';end if;
 update public.opening_stock_import_rows r set quantity_text=left(c->>'quantity',110),is_selected=coalesce((c->>'selected')::boolean,false),location_override=nullif(c->>'location','')::uuid
 from jsonb_array_elements(p_changes)c where r.import_id=p_id and r.source_row=(c->>'row')::integer;
 perform public.refresh_opening_stock_preview(p_id);
end$$;

create function public.opening_stock_progress(p_id uuid)returns jsonb language plpgsql security definer set search_path=''as $$
declare j public.opening_stock_imports%rowtype;v_result jsonb;next_chunk jsonb;
begin
 perform public.item_import_assert_admin();select *into j from public.opening_stock_imports where id=p_id;if not found then raise exception 'Stock import not found';end if;
 select jsonb_build_object('id',c.id,'request_key',c.request_key,'sequence',c.sequence,'error',c.last_error,'code',c.last_error_code)into next_chunk from public.opening_stock_posting_chunks c where c.import_id=p_id and c.revision=j.revision and c.state in('PENDING','FAILED')order by sequence limit 1;
 select jsonb_build_object('id',j.id,'state',j.state,'revision',j.revision,'batch_size',j.batch_size,'quantity_policy',j.quantity_policy,'existing_policy',j.existing_policy,
 'total',count(*),'valid',count(*)filter(where snapshot->>'validation'in('VALID','ZERO')),'invalid',count(*)filter(where snapshot->>'validation'='INVALID'),'existing',count(*)filter(where snapshot->>'validation'='EXISTING'),
 'selected',count(*)filter(where is_selected),'posted',count(*)filter(where r.state='POSTED'),'skipped',count(*)filter(where r.state='SKIPPED'),
 'pending',count(*)filter(where r.state='PENDING'),'quantities_by_unit',coalesce((select jsonb_object_agg(x.unit_id::text,jsonb_build_object('unit',x.name,'selected',x.selected::text,'posted',x.posted::text))from(select u.id unit_id,u.name,coalesce(sum(rr.quantity)filter(where rr.is_selected),0)selected,coalesce(sum(rr.quantity)filter(where rr.state='POSTED'),0)posted from public.opening_stock_import_rows rr join public.units_of_measurement u on u.id=rr.unit_id where rr.import_id=p_id group by u.id,u.name)x),'{}'),'rejected_rows',count(*)filter(where public.opening_stock_quantity(r.raw->>'Rejected qty',true)>0),
 'failed_batches',(select count(*)from public.opening_stock_posting_chunks where import_id=p_id and state='FAILED'),
 'posted_batches',(select count(*)from public.opening_stock_posting_chunks where import_id=p_id and state='POSTED'),
 'next',next_chunk,'percent',case when count(*)filter(where is_selected)=0 then 0 else round(100.0*count(*)filter(where r.state='POSTED')/count(*)filter(where is_selected),2)end)
 into v_result from public.opening_stock_import_rows r where r.import_id=p_id;return v_result;
end$$;

create function public.approve_opening_stock_import(p_id uuid,p_revision integer,p_request_key uuid,p_effective_date date,p_reason text,p_existing_policy text,p_batch_size integer,p_acknowledge boolean)returns jsonb language plpgsql security definer set search_path=''as $$
declare j public.opening_stock_imports%rowtype;v_count integer;
begin
 perform public.item_import_assert_admin();select *into j from public.opening_stock_imports where id=p_id for update nowait;
 if not found then raise exception 'Stock import not found';end if;
 if j.state in('RUNNING','COMPLETED')and j.request_key=p_request_key then return public.opening_stock_progress(p_id);end if;
 if j.state<>'DRAFT'or j.revision<>p_revision then raise exception 'Review the current draft revision before approval';end if;
 if not coalesce(p_acknowledge,false)or p_request_key is null or p_effective_date is null or nullif(trim(p_reason),'')is null then raise exception 'Explicit approval, effective date and reason are required';end if;
 if p_existing_policy is null or p_existing_policy not in('SKIP','REVIEW')or p_batch_size is null or p_batch_size not between 1 and 100 then raise exception 'Select an existing-stock policy and batch size between 1 and 100';end if;
 if exists(select 1 from public.opening_stock_import_rows where import_id=p_id and is_selected and state<>'POSTED'and snapshot->>'validation'<>'VALID')then raise exception 'Selected rows have unresolved validation, zero quantity or existing inventory';end if;
 if exists(select 1 from public.opening_stock_import_rows where import_id=p_id and is_selected group by item_id having count(*)>1)then raise exception 'Select at most one row per item';end if;
 select count(*)into v_count from public.opening_stock_import_rows where import_id=p_id and is_selected and state<>'POSTED';if v_count=0 then raise exception 'No valid positive opening quantities selected; nothing will be posted';end if;
 -- Existing postings cannot change while verifying the precise preview approved by the Admin.
 lock table public.items,public.units_of_measurement,public.stock_locations,public.inventory_balances,public.inventory_transactions in share row exclusive mode nowait;
 if exists(select 1 from public.opening_stock_import_rows r where r.import_id=p_id and r.is_selected and r.state<>'POSTED'and r.snapshot->'inventory'is distinct from public.opening_stock_inventory_snapshot(r.item_id,r.location_id))then raise exception 'Stock state or mappings changed; refresh the pending preview and approve again';end if;
 update public.opening_stock_imports set state='RUNNING',request_key=p_request_key,batch_size=p_batch_size,effective_date=p_effective_date,reason=trim(p_reason),existing_policy=p_existing_policy,approved_by=auth.uid(),approved_at=clock_timestamp(),updated_at=now()where id=p_id;
 update public.opening_stock_import_rows set state=case when snapshot->>'validation'='INVALID'then 'INVALID'else 'SKIPPED'end,skip_reason=case when snapshot->>'validation'='EXISTING'then 'Existing inventory/history; review through ordinary adjustments'when snapshot->>'validation'='ZERO'then 'Zero opening quantity'else 'Not selected'end where import_id=p_id and not is_selected and state<>'POSTED';
 insert into public.opening_stock_posting_chunks(import_id,revision,sequence,row_count,approval)
 select p_id,j.revision,part,count(*),jsonb_build_object('approved_by',auth.uid(),'date',p_effective_date,'reason',trim(p_reason),'quantity_policy','USABLE_OPENING_EXCLUDE_REJECTED','existing_policy',p_existing_policy,'rows',jsonb_agg(jsonb_build_object('row_id',r.row_id,'source_row',r.source_row,'snapshot',r.snapshot)order by r.source_row))
 from(select ((row_number()over(order by source_row)-1)/p_batch_size+1)::integer part,id row_id,source_row,snapshot from public.opening_stock_import_rows where import_id=p_id and is_selected and state<>'POSTED')r group by part;
 with selected as(select id,((row_number()over(order by source_row)-1)/p_batch_size+1)::integer part from public.opening_stock_import_rows where import_id=p_id and is_selected and state<>'POSTED')
 update public.opening_stock_import_rows r set state='PENDING',approved_snapshot=r.snapshot,chunk_id=c.id from selected s join public.opening_stock_posting_chunks c on c.import_id=p_id and c.revision=j.revision and c.sequence=s.part where r.id=s.id;
 insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)
 values(j.source_batch_id,'OPENING_STOCK_APPROVED',jsonb_build_object('import_id',p_id,'revision',j.revision,'count',v_count,'effective_date',p_effective_date,'policy',j.quantity_policy,'existing_policy',p_existing_policy,'selection_digest',(select md5(jsonb_agg(jsonb_build_array(id,quantity,approved_snapshot)order by source_row)::text)from public.opening_stock_import_rows where import_id=p_id and state='PENDING')),auth.uid());
 return public.opening_stock_progress(p_id);
end$$;

create function public.opening_stock_safe_error(p_code text,p_message text default null)returns text language sql immutable set search_path=''as $$select case
 when p_message like 'Opening stock review required:%'then left(p_message,500)
 when p_code='57014'then 'Opening stock batch timed out and was rolled back. Earlier batches remain posted. Refresh and reapprove pending rows before resuming.'
 when p_code='55P03'then 'Inventory is being updated by another request. Wait, then refresh and reapprove pending rows.'
 when p_code='23505'then 'An opening or source transaction already exists. Refresh the preview; do not add the quantities again.'
 when p_code='23503'then 'An item, unit or stock location changed. Review the mapping before resuming.'
 else 'This opening stock batch could not be posted and was rolled back. Earlier batches remain posted. Refresh and review pending rows.'end$$;
create function public.process_opening_stock_chunk(p_id uuid,p_chunk uuid,p_request_key uuid,p_attempt_key uuid)returns jsonb language plpgsql security definer set search_path=''as $$
declare j public.opening_stock_imports%rowtype;c public.opening_stock_posting_chunks%rowtype;r public.opening_stock_import_rows%rowtype;v_tx uuid;v_error text;v_code text;
begin
 perform public.item_import_assert_admin();select *into j from public.opening_stock_imports where id=p_id for update nowait;if not found then raise exception 'Stock import not found';end if;
 select *into c from public.opening_stock_posting_chunks where id=p_chunk and import_id=p_id for update nowait;
 if not found or c.request_key<>p_request_key then raise exception 'Opening stock review required: invalid batch request';end if;
 if c.state='POSTED'then return public.opening_stock_progress(p_id);end if;
 if c.revision<>j.revision or c.state='SUPERSEDED'then raise exception 'Opening stock review required: this approval was superseded; refresh the page';end if;
 if j.state<>'RUNNING'or c.state='FAILED'then return public.opening_stock_progress(p_id);end if;
 if p_attempt_key is null then raise exception 'Opening stock review required: attempt key required';end if;
 if exists(select 1 from public.opening_stock_posting_chunks where import_id=p_id and revision=j.revision and sequence<c.sequence and state<>'POSTED')then raise exception 'Opening stock review required: process the next pending batch first';end if;
 update public.opening_stock_posting_chunks set attempts=attempts+1,last_attempt_key=p_attempt_key where id=p_chunk;
 begin
  -- Locks cover absent balance rows AND stock at other locations; existing posting RPCs use ordinary DML.
  -- This serializes validation/posting against manual stock, dispatch, transfers and receipt posting.
  lock table public.items,public.units_of_measurement,public.stock_locations,public.inventory_balances,public.inventory_transactions in share row exclusive mode nowait;
  if(select count(*)from public.opening_stock_import_rows where chunk_id=p_chunk and state='PENDING')<>c.row_count then raise exception 'Opening stock review required: batch rows changed';end if;
  for r in select *from public.opening_stock_import_rows where chunk_id=p_chunk and state='PENDING'order by item_id,location_id loop
   if not exists(select 1 from jsonb_array_elements(c.approval->'rows')a where a->>'row_id'=r.id::text and a->'snapshot'=r.approved_snapshot)then raise exception 'Opening stock review required: batch approval data changed';end if;
   if r.snapshot is distinct from r.approved_snapshot or r.quantity is null or r.quantity<=0 or r.quantity::numeric(24,6)::text is distinct from r.approved_snapshot->>'quantity'then raise exception 'Opening stock review required: approved quantity or mapping changed';end if;
   if r.approved_snapshot->'inventory'is distinct from public.opening_stock_inventory_snapshot(r.item_id,r.location_id)then raise exception 'Opening stock review required: balances, history, item, unit or location changed; refresh pending preview';end if;
   if exists(select 1 from public.inventory_balances where item_id=r.item_id)or exists(select 1 from public.inventory_transactions where item_id=r.item_id)then raise exception 'Opening stock review required: this item already has inventory history; use an authorized adjustment';end if;
   v_tx:=public.post_inventory_movement('OPENING_STOCK',r.item_id,r.location_id,r.quantity,(c.approval->>'date')::date,'OPENING_STOCK_EXCEL',r.id,p_id::text,c.approval->>'reason','Source batch '||j.source_batch_id||', row '||r.source_row||'; Opening qty is usable; Rejected qty excluded',null,null);
   update public.opening_stock_import_rows set state='POSTED',transaction_id=v_tx,posted_at=clock_timestamp(),posted_by=auth.uid()where id=r.id;
   insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)
   values(j.source_batch_id,'OPENING_STOCK_ROW_POSTED',jsonb_build_object('import_id',p_id,'revision',j.revision,'row_id',r.id,'source_row',r.source_row,'transaction_id',v_tx,'item_id',r.item_id,'location_id',r.location_id,'quantity',r.quantity::text,'before',r.approved_snapshot->'inventory','after_on_hand',r.quantity::text,'approved_by',c.approval->>'approved_by','posted_by',auth.uid(),'rejected_posted',false),auth.uid());
  end loop;
  update public.opening_stock_posting_chunks set state='POSTED',posted_at=clock_timestamp(),last_error=null,last_error_code=null where id=p_chunk;
  insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(j.source_batch_id,'OPENING_STOCK_CHUNK_POSTED',jsonb_build_object('import_id',p_id,'chunk_id',p_chunk,'revision',j.revision,'request_key',p_request_key,'attempt_key',p_attempt_key,'posted',c.row_count,'atomic_scope','CHUNK'),auth.uid());
 exception when others then
  get stacked diagnostics v_code=returned_sqlstate,v_error=message_text;
  update public.opening_stock_posting_chunks set state='FAILED',last_error_code=v_code,last_error=public.opening_stock_safe_error(v_code,v_error)where id=p_chunk;
  update public.opening_stock_imports set state='PAUSED',updated_at=now()where id=p_id;
  insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(j.source_batch_id,'OPENING_STOCK_CHUNK_FAILED',jsonb_build_object('import_id',p_id,'chunk_id',p_chunk,'code',v_code,'message',public.opening_stock_safe_error(v_code,v_error),'rolled_back',true),auth.uid());
  return public.opening_stock_progress(p_id);
 end;
 if not exists(select 1 from public.opening_stock_posting_chunks where import_id=p_id and revision=j.revision and state<>'POSTED')then
  update public.opening_stock_imports set state='COMPLETED',updated_at=now()where id=p_id;
  insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(j.source_batch_id,'OPENING_STOCK_IMPORT_COMPLETED',public.opening_stock_progress(p_id),auth.uid());
 end if;
 return public.opening_stock_progress(p_id);
end$$;
create function public.record_opening_stock_interruption(p_id uuid,p_chunk uuid,p_request_key uuid,p_attempt_key uuid,p_code text)returns jsonb language plpgsql security definer set search_path=''as $$
declare j public.opening_stock_imports%rowtype;c public.opening_stock_posting_chunks%rowtype;
begin
 perform public.item_import_assert_admin();select *into j from public.opening_stock_imports where id=p_id for update nowait;if not found then raise exception 'Stock import not found';end if;
 select *into c from public.opening_stock_posting_chunks where id=p_chunk and import_id=p_id for update nowait;
 if not found or c.request_key<>p_request_key or c.state in('POSTED','SUPERSEDED')or c.revision<>j.revision or(c.state='FAILED'and c.last_attempt_key=p_attempt_key)or p_code='55P03'then return public.opening_stock_progress(p_id);end if;
 update public.opening_stock_posting_chunks set state='FAILED',attempts=attempts+case when last_attempt_key is not distinct from p_attempt_key then 0 else 1 end,last_attempt_key=p_attempt_key,last_error_code=left(p_code,10),last_error=public.opening_stock_safe_error(p_code)where id=p_chunk;
 update public.opening_stock_imports set state='PAUSED',updated_at=now()where id=p_id;
 insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(j.source_batch_id,'OPENING_STOCK_INTERRUPTED',jsonb_build_object('import_id',p_id,'chunk_id',p_chunk,'attempt_key',p_attempt_key,'code',left(p_code,10),'message',public.opening_stock_safe_error(p_code),'prior_postings_preserved',true),auth.uid());
 return public.opening_stock_progress(p_id);
end$$;
create function public.cancel_opening_stock_import(p_id uuid)returns void language plpgsql security definer set search_path=''as $$
declare j public.opening_stock_imports%rowtype;
begin
 perform public.item_import_assert_admin();select *into j from public.opening_stock_imports where id=p_id for update nowait;
 if not found or j.state in('COMPLETED','CANCELLED')then raise exception 'Import cannot be cancelled';end if;
 update public.opening_stock_imports set state='CANCELLED',updated_at=now()where id=p_id;
 update public.opening_stock_posting_chunks set state='SUPERSEDED'where import_id=p_id and state in('PENDING','FAILED');
 update public.opening_stock_import_rows set state='SKIPPED',is_selected=false,skip_reason='Cancelled; posted transactions are preserved'where import_id=p_id and state<>'POSTED';
 insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(j.source_batch_id,'OPENING_STOCK_CANCELLED',jsonb_build_object('import_id',p_id,'posted_rows_preserved',true),auth.uid());
end$$;

-- Quantities come from real balances; catalogue activity only determines which items are counted.
create function public.inventory_overview_counts()returns jsonb language sql stable set search_path=''as $$
 with balances as(select item_id,sum(on_hand_quantity-reserved_quantity)available,sum(damaged_quantity)damaged from public.inventory_balances group by item_id),
 active as(select i.id,i.reorder_level,coalesce(b.available,0)available,coalesce(b.damaged,0)damaged from public.items i left join balances b on b.item_id=i.id where i.is_active)
 select jsonb_build_object('activeItems',count(*),'inStock',count(*)filter(where available>0 and(reorder_level is null or available>reorder_level)),
 'lowStock',count(*)filter(where available>0 and reorder_level is not null and available<=reorder_level),'outOfStock',count(*)filter(where available<=0),'damagedItems',count(*)filter(where damaged>0))from active
$$;
revoke all on function public.inventory_overview_counts()from public,anon;grant execute on function public.inventory_overview_counts()to authenticated;

do $$declare t text;f record;begin
 foreach t in array array['opening_stock_imports','opening_stock_import_rows','opening_stock_posting_chunks']loop
  execute format('alter table public.%I enable row level security',t);
  execute format('create policy admin_read on public.%I for select to authenticated using(public.is_erp_admin()and public.has_active_erp_access())',t);
  execute format('grant select on public.%I to authenticated',t);
 end loop;
 for f in select p.oid::regprocedure signature,p.proname name from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public'and p.proname in('opening_stock_quantity','opening_stock_inventory_snapshot','opening_stock_preview_rows','refresh_opening_stock_preview','create_opening_stock_preview','stage_opening_stock_workbook','edit_opening_stock_preview','opening_stock_progress','approve_opening_stock_import','opening_stock_safe_error','process_opening_stock_chunk','record_opening_stock_interruption','cancel_opening_stock_import')loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  if f.name in('refresh_opening_stock_preview','create_opening_stock_preview','stage_opening_stock_workbook','edit_opening_stock_preview','opening_stock_progress','approve_opening_stock_import','process_opening_stock_chunk','record_opening_stock_interruption','cancel_opening_stock_import')then execute format('grant execute on function %s to authenticated',f.signature);end if;
 end loop;
end$$;
comment on table public.opening_stock_imports is 'Explicit Admin opening stock approval. Opening qty is usable; rejected stock excluded. Each chunk atomic; no whole-workbook rollback after partial completion.';
commit;
