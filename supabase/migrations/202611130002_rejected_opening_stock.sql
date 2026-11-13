-- Confirmed 13-Nov-2026: Opening qty is usable; add Rejected qty separately.
-- Existing jobs retain their old exclusion policy and approval snapshots.
begin;
alter table public.inventory_balances add column rejected_quantity numeric(24,6) not null default 0 check(rejected_quantity>=0);
alter table public.inventory_transactions add column rejected_delta numeric(24,6) not null default 0;
alter table public.inventory_transactions drop constraint inventory_transactions_transaction_type_check;
alter table public.inventory_transactions add constraint inventory_transactions_transaction_type_check check(transaction_type in('OPENING_STOCK','STOCK_IN','STOCK_OUT','RESERVE','UNRESERVE','DAMAGE','DAMAGE_RECOVERY','ADJUSTMENT_IN','ADJUSTMENT_OUT','TRANSFER_OUT','TRANSFER_IN','REJECTED_OPENING'));
alter table public.inventory_transactions add constraint inventory_rejected_movement_check check((transaction_type='REJECTED_OPENING' and rejected_delta=quantity and on_hand_delta=0 and reserved_delta=0 and damaged_delta=0) or(transaction_type<>'REJECTED_OPENING' and rejected_delta=0));
create unique index inventory_rejected_opening_once on public.inventory_transactions(item_id,location_id) where transaction_type='REJECTED_OPENING';
create unique index inventory_rejected_source_once on public.inventory_transactions(reference_id) where transaction_type='REJECTED_OPENING' and reference_type='OPENING_STOCK_EXCEL';
alter table public.opening_stock_imports drop constraint opening_stock_imports_quantity_policy_check;
alter table public.opening_stock_imports add constraint opening_stock_imports_quantity_policy_check check(quantity_policy in('USABLE_OPENING_EXCLUDE_REJECTED','USABLE_PLUS_REJECTED'));
alter table public.opening_stock_imports alter column quantity_policy set default 'USABLE_PLUS_REJECTED';
alter table public.opening_stock_import_rows add column rejected_quantity_text text;
alter table public.opening_stock_import_rows add column rejected_quantity numeric(24,6) check(rejected_quantity>=0);
alter table public.opening_stock_import_rows add column rejected_transaction_id uuid unique references public.inventory_transactions(id) on delete restrict;

-- Internal service: called only inside the existing atomic import chunk transaction.
create function public.post_rejected_opening(p_row uuid,p_date date,p_reason text) returns uuid language plpgsql security definer set search_path=''as $$
declare r public.opening_stock_import_rows%rowtype; j public.opening_stock_imports%rowtype; v_id uuid;
begin
 perform public.item_import_assert_admin();
 select * into r from public.opening_stock_import_rows where id=p_row for update;
 select * into j from public.opening_stock_imports where id=r.import_id;
 if r.state<>'PENDING' or j.state<>'RUNNING' or j.quantity_policy<>'USABLE_PLUS_REJECTED' or r.rejected_quantity is null or r.rejected_quantity<=0 then raise exception 'Rejected opening requires approved pending stock';end if;
 if not exists(select 1 from public.items where id=r.item_id and is_active and unit_id=r.unit_id) or not exists(select 1 from public.stock_locations where id=r.location_id and is_active)then raise exception 'Active rejected stock mapping required';end if;
 perform set_config('app.inventory_posting','1',true);
 insert into public.inventory_balances(item_id,location_id)values(r.item_id,r.location_id)on conflict do nothing;
 perform 1 from public.inventory_balances where item_id=r.item_id and location_id=r.location_id for update;
 insert into public.inventory_transactions(transaction_type,item_id,location_id,quantity,rejected_delta,transaction_date,reference_type,reference_id,reference_number,reason,remarks,created_by)
 values('REJECTED_OPENING',r.item_id,r.location_id,r.rejected_quantity,r.rejected_quantity,p_date,'OPENING_STOCK_EXCEL',r.id,r.import_id::text,p_reason,'Source batch '||j.source_batch_id||', row '||r.source_row||'; rejected stock, excluded from usable on hand',auth.uid())returning id into v_id;
 update public.inventory_balances set rejected_quantity=rejected_quantity+r.rejected_quantity,updated_at=clock_timestamp()where item_id=r.item_id and location_id=r.location_id;
 return v_id;
end$$;
revoke all on function public.post_rejected_opening(uuid,date,text)from public,anon,authenticated;

create function public.protect_rejected_location()returns trigger language plpgsql set search_path=''as $$
begin
 if old.is_active and not new.is_active and exists(select 1 from public.inventory_balances where location_id=old.id and rejected_quantity>0)then raise exception 'Resolve rejected stock before deactivating this Location';end if;return new;
end$$;
create trigger stock_location_rejected_guard before update on public.stock_locations for each row execute function public.protect_rejected_location();
revoke all on function public.protect_rejected_location()from public,anon,authenticated;


create or replace function public.opening_stock_preview_rows(p_import uuid)returns setof jsonb language plpgsql security definer set search_path=''as $$
declare row_data record;errors jsonb;warnings jsonb;q numeric;validation text;inventory jsonb;source_quantity numeric;result jsonb; rejected numeric; include_rejected boolean;
begin
 perform public.item_import_assert_admin();
 select quantity_policy='USABLE_PLUS_REJECTED' into include_rejected from public.opening_stock_imports where id=p_import;
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
  rejected:=case when include_rejected then public.opening_stock_quantity(coalesce(row_data.rejected_quantity_text,row_data.raw->>'Rejected qty'),row_data.rejected_quantity_text is null) else 0 end;
  if include_rejected and row_data.rejected_quantity_text is null and rejected is not null and (row_data.raw->>'Rejected qty')::numeric<>rejected then warnings:=warnings||jsonb_build_array('Excel Rejected qty rounds to '||rejected::text||' at the inventory precision');end if;
  if include_rejected and rejected is null then errors:=errors||'"Rejected quantity must be entered explicitly, non-negative and have at most six decimal places"'::jsonb;end if;
  inventory:=public.opening_stock_inventory_snapshot(row_data.matched_item,row_data.target_location);
  if not coalesce((inventory->'unit'->>'active')::boolean,false)then errors:=errors||'"Select an active item unit"'::jsonb;end if;
  if not coalesce((inventory->'location'->>'active')::boolean,false)then errors:=errors||'"Select an active Stock Location"'::jsonb;end if;
  if jsonb_array_length(errors)>0 then validation:='INVALID';
  elsif jsonb_array_length(inventory->'balances')>0 or(inventory->>'history_count')::bigint>0 then validation:='EXISTING';warnings:=warnings||'"Existing inventory balance or movement history: leave unposted here and review through the authorized adjustment workflow"'::jsonb;
  elsif q=0 and coalesce(rejected,0)=0 then validation:='ZERO';else validation:='VALID';end if;
  result:=jsonb_build_object('row',row_data.source_row,'item_id',row_data.matched_item,'unit_id',row_data.current_unit,'source_unit_id',row_data.source_unit,'location_id',row_data.target_location,'item_code',row_data.raw->>'New code','item_name',row_data.current_name,'source_name',row_data.raw->>'Item name','unit',inventory->'unit'->>'name','location',inventory->'location'->>'name','source_store',row_data.raw->>'Store','source_status',row_data.raw->>'Status','classification',row_data.current_classification,
   'excel_quantity',row_data.raw->>'Opening qty','rejected_quantity',case when include_rejected then rejected::numeric(24,6)::text else row_data.raw->>'Rejected qty' end,'rejected_posting_quantity',coalesce(rejected,0)::numeric(24,6)::text,'quantity_policy',case when include_rejected then 'USABLE_PLUS_REJECTED' else 'USABLE_OPENING_EXCLUDE_REJECTED' end,'quantity',case when q is not null then q::numeric(24,6)::text end,
   'existing_rejected',coalesce((select b.rejected_quantity from public.inventory_balances b where b.item_id=row_data.matched_item and b.location_id=row_data.target_location),0)::text,'existing_quantity',coalesce(inventory->>'on_hand','0'),'delta',case when validation='VALID'then q::numeric(24,6)::text else '0'end,
   'resulting_quantity',case when validation='VALID'then q::numeric(24,6)::text else coalesce(inventory->>'on_hand','0')end,
   'resulting_available',case when validation='VALID' then q::numeric(24,6)::text else (coalesce((inventory->>'on_hand')::numeric,0)-coalesce((inventory->>'reserved')::numeric,0))::numeric(24,6)::text end,
   'validation',validation,'errors',errors,'warnings',warnings,'inventory',inventory);
  return next result;
 end loop;return;
end$$;

create or replace function public.refresh_opening_stock_preview(p_id uuid)returns void language plpgsql security definer set search_path=''as $$
declare j public.opening_stock_imports%rowtype;
begin
 perform public.item_import_assert_admin();select *into j from public.opening_stock_imports where id=p_id for update nowait;
 if not found or j.state not in('DRAFT','PAUSED')then raise exception 'Stock import must be a draft or paused before reviewing pending rows';end if;
 update public.opening_stock_posting_chunks set state='SUPERSEDED'where import_id=p_id and state in('PENDING','FAILED');
 update public.opening_stock_import_rows set state='DRAFT',chunk_id=null,approved_snapshot=null,skip_reason=null where import_id=p_id and state<>'POSTED';
 with reviewed as materialized(select value from public.opening_stock_preview_rows(p_id)value)
 update public.opening_stock_import_rows r set snapshot=s.value,item_id=nullif(s.value->>'item_id','')::uuid,unit_id=nullif(s.value->>'unit_id','')::uuid,location_id=nullif(s.value->>'location_id','')::uuid,quantity=nullif(s.value->>'quantity','')::numeric,rejected_quantity=nullif(s.value->>'rejected_posting_quantity','')::numeric,
 is_selected=r.is_selected and s.value->>'validation'='VALID'
 from reviewed s where r.import_id=p_id and r.source_row=(s.value->>'row')::integer;
 update public.opening_stock_imports set state='DRAFT',revision=revision+1,approved_by=null,approved_at=null,request_key=null,updated_at=now()where id=p_id;
 insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(j.source_batch_id,'OPENING_STOCK_PREVIEW_REVIEWED',jsonb_build_object('import_id',p_id,'revision',j.revision+1,'posted_rows_unchanged',true),auth.uid());
end$$;

create or replace function public.edit_opening_stock_preview(p_id uuid,p_revision integer,p_changes jsonb)returns void language plpgsql security definer set search_path=''as $$
declare j public.opening_stock_imports%rowtype;
begin
 perform public.item_import_assert_admin();select *into j from public.opening_stock_imports where id=p_id for update nowait;
 if not found or j.state<>'DRAFT'or j.revision<>p_revision then raise exception 'Refresh the draft before editing; posted rows cannot be changed';end if;
 if jsonb_typeof(p_changes)<>'array'or jsonb_array_length(p_changes)>10000 then raise exception 'Invalid preview changes';end if;
 if exists(select 1 from jsonb_array_elements(p_changes)c group by c->>'row'having count(*)>1)then raise exception 'Duplicate preview edits';end if;
 if exists(select 1 from jsonb_array_elements(p_changes)c where not exists(select 1 from public.opening_stock_import_rows r where r.import_id=p_id and r.source_row=(c->>'row')::integer and r.state<>'POSTED'))then raise exception 'A source row is missing or already posted';end if;
 update public.opening_stock_import_rows r set rejected_quantity_text=case when c ? 'rejected' then left(c->>'rejected',110)else r.rejected_quantity_text end,quantity_text=left(c->>'quantity',110),is_selected=coalesce((c->>'selected')::boolean,false),location_override=nullif(c->>'location','')::uuid
 from jsonb_array_elements(p_changes)c where r.import_id=p_id and r.source_row=(c->>'row')::integer;
 perform public.refresh_opening_stock_preview(p_id);
end$$;

create or replace function public.approve_opening_stock_import(p_id uuid,p_revision integer,p_request_key uuid,p_effective_date date,p_reason text,p_existing_policy text,p_batch_size integer,p_acknowledge boolean)returns jsonb language plpgsql security definer set search_path=''as $$
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
 select p_id,j.revision,part,count(*),jsonb_build_object('approved_by',auth.uid(),'date',p_effective_date,'reason',trim(p_reason),'quantity_policy',j.quantity_policy,'existing_policy',p_existing_policy,'rows',jsonb_agg(jsonb_build_object('row_id',r.row_id,'source_row',r.source_row,'snapshot',r.snapshot)order by r.source_row))
 from(select ((row_number()over(order by source_row)-1)/p_batch_size+1)::integer part,id row_id,source_row,snapshot from public.opening_stock_import_rows where import_id=p_id and is_selected and state<>'POSTED')r group by part;
 with selected as(select id,((row_number()over(order by source_row)-1)/p_batch_size+1)::integer part from public.opening_stock_import_rows where import_id=p_id and is_selected and state<>'POSTED')
 update public.opening_stock_import_rows r set state='PENDING',approved_snapshot=r.snapshot,chunk_id=c.id from selected s join public.opening_stock_posting_chunks c on c.import_id=p_id and c.revision=j.revision and c.sequence=s.part where r.id=s.id;
 insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)
 values(j.source_batch_id,'OPENING_STOCK_APPROVED',jsonb_build_object('import_id',p_id,'revision',j.revision,'count',v_count,'effective_date',p_effective_date,'policy',j.quantity_policy,'existing_policy',p_existing_policy,'selection_digest',(select md5(jsonb_agg(jsonb_build_array(id,quantity,approved_snapshot)order by source_row)::text)from public.opening_stock_import_rows where import_id=p_id and state='PENDING')),auth.uid());
 return public.opening_stock_progress(p_id);
end$$;

create or replace function public.process_opening_stock_chunk(p_id uuid,p_chunk uuid,p_request_key uuid,p_attempt_key uuid)returns jsonb language plpgsql security definer set search_path=''as $$
declare j public.opening_stock_imports%rowtype;c public.opening_stock_posting_chunks%rowtype;r public.opening_stock_import_rows%rowtype;v_tx uuid;v_rejected_tx uuid;v_error text;v_code text;
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
   if r.snapshot is distinct from r.approved_snapshot or r.quantity is null or (r.quantity<=0 and coalesce(r.rejected_quantity,0)<=0) or r.quantity::numeric(24,6)::text is distinct from r.approved_snapshot->>'quantity'then raise exception 'Opening stock review required: approved quantity or mapping changed';end if;
   if coalesce(r.rejected_quantity,0)::numeric(24,6)::text is distinct from coalesce(r.approved_snapshot->>'rejected_posting_quantity','0.000000') or c.approval->>'quantity_policy' is distinct from j.quantity_policy then raise exception 'Opening stock review required: rejected quantity or policy changed';end if;
   if r.approved_snapshot->'inventory'is distinct from public.opening_stock_inventory_snapshot(r.item_id,r.location_id)then raise exception 'Opening stock review required: balances, history, item, unit or location changed; refresh pending preview';end if;
   if exists(select 1 from public.inventory_balances where item_id=r.item_id)or exists(select 1 from public.inventory_transactions where item_id=r.item_id)then raise exception 'Opening stock review required: this item already has inventory history; use an authorized adjustment';end if;
   v_tx:=null;v_rejected_tx:=null;
   if r.quantity>0 then v_tx:=public.post_inventory_movement('OPENING_STOCK',r.item_id,r.location_id,r.quantity,(c.approval->>'date')::date,'OPENING_STOCK_EXCEL',r.id,p_id::text,c.approval->>'reason','Source batch '||j.source_batch_id||', row '||r.source_row||'; Opening qty is usable',null,null);end if;
   if j.quantity_policy='USABLE_PLUS_REJECTED' and r.rejected_quantity>0 then v_rejected_tx:=public.post_rejected_opening(r.id,(c.approval->>'date')::date,c.approval->>'reason');end if;
   update public.opening_stock_import_rows set state='POSTED',transaction_id=coalesce(v_tx,v_rejected_tx),rejected_transaction_id=v_rejected_tx,posted_at=clock_timestamp(),posted_by=auth.uid()where id=r.id;
   insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)
   values(j.source_batch_id,'OPENING_STOCK_ROW_POSTED',jsonb_build_object('import_id',p_id,'revision',j.revision,'row_id',r.id,'source_row',r.source_row,'transaction_id',v_tx,'item_id',r.item_id,'location_id',r.location_id,'quantity',r.quantity::text,'before',r.approved_snapshot->'inventory','after_on_hand',r.quantity::text,'approved_by',c.approval->>'approved_by','posted_by',auth.uid(),'rejected_posted',v_rejected_tx is not null,'rejected_transaction_id',v_rejected_tx,'rejected_quantity',r.rejected_quantity::text),auth.uid());
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

create or replace function public.opening_stock_progress(p_id uuid)returns jsonb language plpgsql security definer set search_path=''as $$
declare j public.opening_stock_imports%rowtype;v_result jsonb;next_chunk jsonb;
begin
 perform public.item_import_assert_admin();select *into j from public.opening_stock_imports where id=p_id;if not found then raise exception 'Stock import not found';end if;
 select jsonb_build_object('id',c.id,'request_key',c.request_key,'sequence',c.sequence,'error',c.last_error,'code',c.last_error_code)into next_chunk from public.opening_stock_posting_chunks c where c.import_id=p_id and c.revision=j.revision and c.state in('PENDING','FAILED')order by sequence limit 1;
 select jsonb_build_object('id',j.id,'state',j.state,'revision',j.revision,'batch_size',j.batch_size,'quantity_policy',j.quantity_policy,'existing_policy',j.existing_policy,
 'total',count(*),'valid',count(*)filter(where snapshot->>'validation'in('VALID','ZERO')),'invalid',count(*)filter(where snapshot->>'validation'='INVALID'),'existing',count(*)filter(where snapshot->>'validation'='EXISTING'),
 'matched',count(*)filter(where item_id is not null),'unmatched',count(*)filter(where item_id is null),'ready',count(*)filter(where is_selected and snapshot->>'validation'='VALID' and r.state<>'POSTED'),'selected',count(*)filter(where is_selected),'posted',count(*)filter(where r.state='POSTED'),'skipped',count(*)filter(where r.state='SKIPPED'),
 'pending',count(*)filter(where r.state='PENDING'),'quantities_by_unit',coalesce((select jsonb_object_agg(x.unit_id::text,jsonb_build_object('unit',x.name,'excel',x.excel::text,'excel_rejected',x.excel_rejected::text,'rejected',x.rejected::text,'available',x.selected::text,'rejected_posted',x.rejected_posted::text,'selected',x.selected::text,'posted',x.posted::text))from(select u.id unit_id,u.name,coalesce(sum(public.opening_stock_quantity(rr.raw->>'Rejected qty',true)),0)excel_rejected,coalesce(sum(public.opening_stock_quantity(rr.raw->>'Opening qty',true)),0)excel,coalesce(sum(rr.rejected_quantity)filter(where rr.is_selected),0)rejected,coalesce(sum(rr.rejected_quantity)filter(where rr.state='POSTED'),0)rejected_posted,coalesce(sum(rr.quantity)filter(where rr.is_selected),0)selected,coalesce(sum(rr.quantity)filter(where rr.state='POSTED'),0)posted from public.opening_stock_import_rows rr join public.units_of_measurement u on u.id=rr.unit_id where rr.import_id=p_id group by u.id,u.name)x),'{}'),'rejected_rows',count(*)filter(where (coalesce(r.rejected_quantity,0)>0 or public.opening_stock_quantity(r.raw->>'Rejected qty',true)>0)),
 'failed_batches',(select count(*)from public.opening_stock_posting_chunks where import_id=p_id and state='FAILED'),
 'posted_batches',(select count(*)from public.opening_stock_posting_chunks where import_id=p_id and state='POSTED'),
 'next',next_chunk,'percent',case when count(*)filter(where is_selected)=0 then 0 else round(100.0*count(*)filter(where r.state='POSTED')/count(*)filter(where is_selected),2)end)
 into v_result from public.opening_stock_import_rows r where r.import_id=p_id;return v_result;
end$$;

create or replace function public.inventory_overview_counts()returns jsonb language sql stable set search_path=''as $$
 with balances as(select item_id,sum(on_hand_quantity-reserved_quantity)available,sum(damaged_quantity)damaged,sum(rejected_quantity)rejected from public.inventory_balances group by item_id),
 active as(select i.id,i.reorder_level,coalesce(b.available,0)available,coalesce(b.damaged,0)damaged,coalesce(b.rejected,0)rejected from public.items i left join balances b on b.item_id=i.id where i.is_active)
 select jsonb_build_object('activeItems',count(*),'inStock',count(*)filter(where available>0 and(reorder_level is null or available>reorder_level)),
 'lowStock',count(*)filter(where available>0 and reorder_level is not null and available<=reorder_level),'outOfStock',count(*)filter(where available<=0),'damagedItems',count(*)filter(where damaged>0),'rejectedItems',count(*)filter(where rejected>0))from active
$$;

comment on column public.inventory_balances.on_hand_quantity is 'Usable stock excluding damaged and rejected stock. Available = usable on hand minus reserved.';
comment on column public.inventory_balances.rejected_quantity is 'Separate non-saleable rejected stock; never included in usable on hand or damage.';
commit;
