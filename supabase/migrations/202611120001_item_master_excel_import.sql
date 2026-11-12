-- Item Master Excel integration. Additive; stock proposal posting is deliberately unavailable.
begin;
create function public.item_import_normalize(v text) returns text language sql immutable parallel safe set search_path='' as $$select lower(regexp_replace(trim(v),'[[:space:]]+',' ','g'))$$;
create table public.stock_classifications(
 id uuid primary key default gen_random_uuid(),code text,name text not null check(length(trim(name))>0),description text,sort_order integer not null default 0,is_active boolean not null default true,
 created_at timestamptz not null default now(),created_by uuid references auth.users(id) default auth.uid(),updated_at timestamptz not null default now(),updated_by uuid references auth.users(id) default auth.uid()
);
create unique index stock_classifications_name_unique on public.stock_classifications(public.item_import_normalize(name));
create unique index stock_classifications_code_unique on public.stock_classifications(upper(trim(code))) where code is not null;
alter table public.items add column stock_classification_id uuid references public.stock_classifications(id) on delete restrict;
create index items_stock_classification on public.items(stock_classification_id);
create index items_import_normalized_name on public.items(public.item_import_normalize(item_name));
create index item_subcategories_import_name on public.item_subcategories(category_id,public.item_import_normalize(name));
create trigger set_stock_classifications_updated_at before update on public.stock_classifications for each row execute function public.set_updated_at();

create table public.item_import_batches(
 id uuid primary key default gen_random_uuid(),source_name text not null check(length(source_name) between 1 and 255),source_sha256 text not null check(source_sha256~'^[0-9a-f]{64}$'),source_base64 text not null check(length(source_base64)<=14000000),sheet text not null,
 parser_version text not null default '1',source_rows jsonb not null check(jsonb_typeof(source_rows)='array' and jsonb_array_length(source_rows) between 1 and 10000),
 preview jsonb not null default '{}',revision integer not null default 1,state text not null default 'PREVIEW' check(state in('PREVIEW','COMMITTED','CANCELLED')),result jsonb,
 created_by uuid not null references auth.users(id),created_at timestamptz not null default now(),committed_by uuid references auth.users(id),committed_at timestamptz
);
create table public.item_import_links(
 batch_id uuid not null references public.item_import_batches(id) on delete restrict,source_row integer not null,item_id uuid not null references public.items(id) on delete restrict,
 location_id uuid not null references public.stock_locations(id) on delete restrict,unit_id uuid not null references public.units_of_measurement(id) on delete restrict,resolved_masters jsonb not null,primary key(batch_id,source_row)
);
create index item_import_links_item on public.item_import_links(item_id);
create index item_import_links_location on public.item_import_links(location_id);
create index item_import_links_unit on public.item_import_links(unit_id);
create table public.item_master_admin_activities(
 id uuid primary key default gen_random_uuid(),batch_id uuid references public.item_import_batches(id) on delete restrict,master_table text,event_type text not null,details jsonb not null,
 created_by uuid not null references auth.users(id),created_at timestamptz not null default now()
);
create table public.item_import_stock_proposals(
 id uuid primary key default gen_random_uuid(),batch_id uuid not null unique references public.item_import_batches(id) on delete restrict,
 revision integer not null default 1,state text not null default 'DRAFT' check(state in('DRAFT','REVIEWED_POSTING_DISABLED','REJECTED','CANCELLED')),
 snapshot jsonb not null,created_by uuid not null references auth.users(id),created_at timestamptz not null default now(),reviewed_by uuid references auth.users(id),reviewed_at timestamptz,
 reason text,posting_enabled boolean not null default false check(not posting_enabled)
);
-- No posting RPC or ledger write is supplied by this migration.
create function public.item_import_assert_admin() returns void language plpgsql stable security definer set search_path='' as $$begin
 if auth.uid() is null or not public.is_erp_admin() or not public.has_active_erp_access() then raise exception 'Active Admin access required';end if;
end$$;

-- Resolve names in the designated master; subcategories are always scoped to their actual parent.
create function public.item_import_master(p_table text,p_name text,p_parent uuid default null,p_parent_new boolean default false) returns jsonb language plpgsql security definer set search_path='' as $$
declare candidates jsonb;exact_candidates jsonb;chosen jsonb;n integer;v_code text;suffix integer:=0;
begin
 perform public.item_import_assert_admin();
 if p_table not in('item_categories','item_subcategories','item_types','units_of_measurement','stock_locations','stock_classifications') then raise exception 'Invalid classification master';end if;
 if nullif(trim(p_name),'') is null then return jsonb_build_object('table',p_table,'name',p_name,'state','EMPTY');end if;
 if p_table='item_subcategories' then
  if p_parent_new then candidates:='[]';else
   select coalesce(jsonb_agg(to_jsonb(t) order by t.id),'[]') into candidates from public.item_subcategories t where t.category_id=p_parent and public.item_import_normalize(t.name)=public.item_import_normalize(p_name);
  end if;
 else
  execute format('select coalesce(jsonb_agg(to_jsonb(t) order by t.id),''[]''::jsonb) from public.%I t where public.item_import_normalize(t.name)=public.item_import_normalize($1)',p_table)into candidates using p_name;
 end if;
 -- Prefer a single exact match; otherwise require an unambiguous normalized equivalent.
 n:=jsonb_array_length(candidates);
 if n>1 then
  select coalesce(jsonb_agg(value),'[]')into exact_candidates from jsonb_array_elements(candidates)where value->>'name'=trim(p_name);
  if jsonb_array_length(exact_candidates)=1 then candidates:=exact_candidates;n:=1;end if;
 end if;
 if n>1 then return jsonb_build_object('table',p_table,'name',p_name,'state','AMBIGUOUS','candidates',candidates);end if;
 if n=1 then chosen:=candidates->0;return jsonb_build_object('table',p_table,'name',p_name,'state',case when (chosen->>'is_active')::boolean then 'REUSED' else 'INACTIVE' end,'id',chosen->>'id','record',chosen);end if;
 if p_table='stock_locations' then
  v_code:='XL-'||upper(substr(md5(public.item_import_normalize(p_name)),1,12));
  while exists(select 1 from public.stock_locations where upper(trim(code))=v_code)loop suffix:=suffix+1;v_code:='XL-'||upper(substr(md5(public.item_import_normalize(p_name)),1,12))||'-'||suffix;end loop;
 end if;
 return jsonb_build_object('table',p_table,'name',trim(p_name),'state','NEW','code',v_code);
end$$;

create function public.item_import_preview_rows(p_rows jsonb) returns setof jsonb language plpgsql security definer set search_path='' as $$
declare r jsonb;d jsonb;errors jsonb;warnings jsonb;maps jsonb;cat jsonb;m jsonb;existing public.items%rowtype;entry jsonb;k text;t text;cost numeric;v numeric;expected numeric;row_num integer;dupes integer;code_counts jsonb;name_counts jsonb;
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
  cat:=public.item_import_master('item_categories',d->>'Family');maps:=maps||jsonb_build_object('category',cat);
  for k,t in select * from(values('subcategory','item_subcategories'),('type','item_types'),('unit','units_of_measurement'),('location','stock_locations'),('classification','stock_classifications'))v(k,t)loop
   m:=public.item_import_master(t,d->>case k when 'subcategory'then 'Item group'when 'type'then 'Type'when 'unit'then 'Unit'when 'location'then 'Store'else 'Status'end,nullif(cat->>'id','')::uuid,cat->>'state'='NEW');
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
create function public.item_import_preview(p_rows jsonb)returns jsonb language plpgsql security definer set search_path='' as $$
declare out_rows jsonb;counts jsonb;
begin
 perform public.item_import_assert_admin();
 select coalesce(jsonb_agg(r.value order by r.ordinal),'[]'),jsonb_build_object('created',count(*)filter(where r.value->>'action'='CREATE' and jsonb_array_length(r.value->'errors')=0),'reused',count(*)filter(where r.value->>'action'='REUSED' and jsonb_array_length(r.value->'errors')=0),'failed',count(*)filter(where jsonb_array_length(r.value->'errors')>0),'updated',0)into out_rows,counts from public.item_import_preview_rows(p_rows)with ordinality r(value,ordinal);
 return jsonb_build_object('rows',out_rows,'summary',counts);
end$$;

create function public.stage_item_import(p_name text,p_sha256 text,p_source_base64 text,p_sheet text,p_rows jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;v_preview jsonb;
begin
 perform public.item_import_assert_admin();
 if encode(sha256(decode(p_source_base64,'base64')),'hex')<>p_sha256 then raise exception 'Source digest mismatch';end if;
 v_preview:=public.item_import_preview(p_rows);
 insert into public.item_import_batches(source_name,source_sha256,source_base64,sheet,source_rows,preview,created_by)values(p_name,p_sha256,p_source_base64,p_sheet,p_rows,v_preview,auth.uid())returning id into v_id;
 insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(v_id,'PREVIEW_CREATED',v_preview->'summary',auth.uid());return v_id;
end$$;
create function public.refresh_item_import(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare b public.item_import_batches%rowtype;
begin perform public.item_import_assert_admin();select * into b from public.item_import_batches where id=p_id for update;if not found or b.state<>'PREVIEW'then raise exception 'Import is not in preview';end if;
 update public.item_import_batches set preview=public.item_import_preview(b.source_rows),revision=revision+1 where id=p_id;
 insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(p_id,'PREVIEW_REFRESHED',jsonb_build_object('revision',b.revision+1),auth.uid());end$$;

create function public.item_import_create_master(m jsonb,p_parent uuid default null)returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid;t text:=m->>'table';
begin
 perform public.item_import_assert_admin();if m->>'state'='EMPTY'then return null;end if;
 if m->>'state'='REUSED'then return(m->>'id')::uuid;end if;
 if m->>'state'<>'NEW' or t not in('item_categories','item_subcategories','item_types','units_of_measurement','stock_locations','stock_classifications')then raise exception 'Unresolved classification';end if;
 -- Previous rows may already have created the same master in this transaction.
 m:=public.item_import_master(t,m->>'name',p_parent,false);
 if m->>'state'='REUSED'then return(m->>'id')::uuid;end if;
 if m->>'state'<>'NEW'then raise exception 'Classification resolution changed';end if;
 if t='item_subcategories'then insert into public.item_subcategories(name,category_id,created_by,updated_by)values(m->>'name',p_parent,auth.uid(),auth.uid())returning id into v_id;
 elsif t='stock_locations'then insert into public.stock_locations(name,code,created_by,updated_by)values(m->>'name',m->>'code',auth.uid(),auth.uid())returning id into v_id;
 else execute format('insert into public.%I(name,created_by,updated_by)values($1,$2,$2)returning id',t)into v_id using m->>'name',auth.uid();end if;
 return v_id;
end$$;

create function public.commit_item_import(p_id uuid,p_revision integer,p_rows integer[],p_acknowledge boolean)returns jsonb language plpgsql security definer set search_path='' as $$
declare b public.item_import_batches%rowtype;fresh jsonb;r jsonb;d jsonb;m jsonb;cat uuid;sub uuid;typ uuid;unt uuid;loc uuid;cls uuid;v_item uuid;created integer:=0;reused integer:=0;v_result jsonb;master_counts jsonb;masters_before bigint;masters_after bigint;master_keys text[]:=array[]::text[];
begin
 perform public.item_import_assert_admin();select * into b from public.item_import_batches where id=p_id for update;
 if not found then raise exception 'Import not found';end if;
 if b.state='COMMITTED'then return b.result;end if;
 if b.state<>'PREVIEW' or b.revision<>p_revision then raise exception 'Stale preview revision';end if;
 if not coalesce(p_acknowledge,false)then raise exception 'Administrator confirmation of warnings, costs and generated location codes is required';end if;
 if coalesce(cardinality(p_rows),0)=0 or exists(select 1 from unnest(p_rows)x group by x having count(*)>1)then raise exception 'Select distinct valid rows';end if;
 -- Coordinate with every ordinary writer, including concurrent Configuration edits.
 lock table public.item_categories,public.item_subcategories,public.item_types,public.units_of_measurement,public.stock_locations,public.stock_classifications,public.items in share row exclusive mode;
 fresh:=public.item_import_preview(b.source_rows);
 if fresh<>b.preview then raise exception 'Masters or items changed: refresh preview and confirm again';end if;
 if exists(select 1 from unnest(p_rows)n where not exists(select 1 from jsonb_array_elements(fresh->'rows')x where(x->>'row')::integer=n and jsonb_array_length(x->'errors')=0))then raise exception 'Selected rows contain unresolved errors';end if;
 select (select count(*)from public.item_categories)+(select count(*)from public.item_subcategories)+(select count(*)from public.item_types)+(select count(*)from public.units_of_measurement)+(select count(*)from public.stock_locations)+(select count(*)from public.stock_classifications) into masters_before;
 for r in select value from jsonb_array_elements(fresh->'rows')where(value->>'row')::integer=any(p_rows)order by(value->>'row')::integer loop
  d:=r->'raw';m:=r->'mappings';cat:=public.item_import_create_master(m->'category');sub:=public.item_import_create_master(m->'subcategory',cat);typ:=public.item_import_create_master(m->'type');unt:=public.item_import_create_master(m->'unit');loc:=public.item_import_create_master(m->'location');cls:=public.item_import_create_master(m->'classification');
  master_keys:=master_keys||array['category:'||cat,case when sub is not null then 'subcategory:'||sub end,'type:'||typ,'unit:'||unt,'location:'||loc,'classification:'||cls];
  if r->>'action'='REUSED'then v_item:=(r->>'item_id')::uuid;reused:=reused+1;
  else
   insert into public.items(item_code,item_name,category_id,subcategory_id,item_type_id,unit_id,stock_classification_id,cogs_unit_cost,created_by,updated_by)values(trim(d->>'New code'),trim(d->>'Item name'),cat,sub,typ,unt,cls,(r->>'cogs')::numeric,auth.uid(),auth.uid())returning id into v_item;created:=created+1;
  end if;
  insert into public.item_import_links(batch_id,source_row,item_id,location_id,unit_id,resolved_masters)values(p_id,(r->>'row')::integer,v_item,loc,unt,jsonb_build_object('category_id',cat,'subcategory_id',sub,'item_type_id',typ,'unit_id',unt,'location_id',loc,'stock_classification_id',cls));
 end loop;
 select (select count(*)from public.item_categories)+(select count(*)from public.item_subcategories)+(select count(*)from public.item_types)+(select count(*)from public.units_of_measurement)+(select count(*)from public.stock_locations)+(select count(*)from public.stock_classifications) into masters_after;
 select jsonb_build_object('created',masters_after-masters_before,'reused',count(distinct x)-(masters_after-masters_before),'unresolved',0)into master_counts from unnest(master_keys)x where x is not null;
 v_result:=jsonb_build_object('created',created,'updated',0,'reused',reused,'skipped',jsonb_array_length(b.source_rows)-cardinality(p_rows),'failed',0,'classifications',master_counts);
 update public.item_import_batches set state='COMMITTED',result=v_result,committed_at=now(),committed_by=auth.uid()where id=p_id;
 insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(p_id,'MASTER_IMPORT_COMMITTED',v_result,auth.uid());return v_result;
end$$;

create function public.item_import_stock_snapshot(p_batch uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform public.item_import_assert_admin();
 select coalesce(jsonb_agg(jsonb_build_object('row',l.source_row,'item_id',i.id,'item_code',i.item_code,'item_name',i.item_name,'unit_id',i.unit_id,'source_unit_id',l.unit_id,'unit_mapping_matches',i.unit_id=l.unit_id,'unit',u.name,'unit_active',u.is_active,'unit_version',u.updated_at,'item_version',i.updated_at,'location_version',s.updated_at,'item_active',i.is_active,'location_id',s.id,'location',s.name,'location_active',s.is_active,'raw',r->'raw','on_hand',coalesce(b.on_hand_quantity,0),'reserved',coalesce(b.reserved_quantity,0),'damaged',coalesce(b.damaged_quantity,0),'available',coalesce(b.on_hand_quantity-b.reserved_quantity,0),'balance_version',b.updated_at,'ledger_count',(select count(*)from public.inventory_transactions it where it.item_id=i.id and it.location_id=s.id),'operation','UNDETERMINED','proposed_delta',null,'resulting_balance',null)order by l.source_row),'[]')into result
 from public.item_import_links l join public.item_import_batches batch on batch.id=l.batch_id cross join lateral jsonb_array_elements(batch.source_rows)r join public.items i on i.id=l.item_id join public.units_of_measurement u on u.id=i.unit_id join public.stock_locations s on s.id=l.location_id left join public.inventory_balances b on b.item_id=i.id and b.location_id=s.id
 where l.batch_id=p_batch and(r->>'row')::integer=l.source_row;
 return result;
end$$;
create function public.item_import_stock_review_current(p_batch uuid)returns boolean language plpgsql security definer set search_path='' as $$
declare saved jsonb;
begin perform public.item_import_assert_admin();select snapshot into saved from public.item_import_stock_proposals where batch_id=p_batch;return saved is not null and saved=public.item_import_stock_snapshot(p_batch);end$$;
create function public.review_item_import_stock(p_batch uuid,p_action text,p_revision integer default null,p_reason text default null)returns uuid language plpgsql security definer set search_path='' as $$
declare p public.item_import_stock_proposals%rowtype;snapshot jsonb;r jsonb;d jsonb;
begin
 perform public.item_import_assert_admin();perform 1 from public.item_import_batches where id=p_batch and state='COMMITTED'for update;if not found then raise exception 'Commit product master records first';end if;
 select * into p from public.item_import_stock_proposals where batch_id=p_batch for update;
 if p_action='PREVIEW'then
  snapshot:=public.item_import_stock_snapshot(p_batch);
  insert into public.item_import_stock_proposals(batch_id,snapshot,created_by)values(p_batch,snapshot,auth.uid())on conflict(batch_id)do update set snapshot=excluded.snapshot,revision=item_import_stock_proposals.revision+1,state='DRAFT',reviewed_by=null,reviewed_at=null,reason=null returning * into p;
 elsif p_action in('REVIEW','REJECT','CANCEL')then
  if p.id is null or p.revision<>p_revision then raise exception 'Stale stock proposal revision';end if;
  if p.state<>'DRAFT'then raise exception 'Refresh stock preview before changing its review';end if;
  if p_action='REVIEW'then
   lock table public.items,public.stock_locations,public.units_of_measurement,public.inventory_balances,public.inventory_transactions in share mode;
   if public.item_import_stock_snapshot(p_batch)<>p.snapshot then raise exception 'Stock state or mappings changed: create a fresh preview';end if;
   if exists(select 1 from jsonb_array_elements(p.snapshot)x where not(x->>'item_active')::boolean or not(x->>'location_active')::boolean or not(x->>'unit_active')::boolean or not(x->>'unit_mapping_matches')::boolean)then raise exception 'Inactive stock mapping or changed source unit; resolve explicitly without assuming conversion';end if;
   if exists(select 1 from jsonb_array_elements(p.snapshot)x group by x->>'item_id',x->>'location_id' having count(*)>1)then raise exception 'Duplicate stock item/location rows';end if;
   for r in select value from jsonb_array_elements(p.snapshot)loop
    d:=r->'raw';if abs((d->>'Value (Rs)')::numeric-(d->>'Opening qty')::numeric*(d->>'Rate (Rs)')::numeric)>0.01 or abs((d->>'Rejected value (Rs)')::numeric-(d->>'Rejected qty')::numeric*(d->>'Rate (Rs)')::numeric)>0.01 then raise exception 'Stock reconciliation exceeds Rs 0.01';end if;
   end loop;
  end if;
  update public.item_import_stock_proposals set state=case p_action when 'REVIEW'then 'REVIEWED_POSTING_DISABLED'when 'REJECT'then 'REJECTED'else 'CANCELLED'end,reviewed_by=auth.uid(),reviewed_at=now(),reason=nullif(trim(p_reason),'')where id=p.id;
 else raise exception 'Posting disabled pending quantity and rejected-stock accounting approval';end if;
 insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(p_batch,'STOCK_'||p_action,jsonb_build_object('proposal',p.id,'revision',p.revision,'posting_enabled',false,'reason',p_reason),auth.uid());return p.id;
end$$;

create function public.record_item_import_failure(p_id uuid,p_message text)returns void language plpgsql security definer set search_path='' as $$begin
 perform public.item_import_assert_admin();perform 1 from public.item_import_batches where id=p_id;if not found then raise exception 'Import not found';end if;
 insert into public.item_master_admin_activities(batch_id,event_type,details,created_by)values(p_id,'IMPORT_ATTEMPT_FAILED',jsonb_build_object('message',left(p_message,2000)),auth.uid());
end$$;

-- Enforce normalized uniqueness and stable parent links for imports AND ordinary master edits.
create function public.guard_item_import_master()returns trigger language plpgsql security definer set search_path='' as $$
declare duplicate boolean;
begin
 perform pg_advisory_xact_lock(hashtextextended('item-master-normalization:'||tg_table_name,0));
 if tg_table_name='item_subcategories'then
  if(tg_op='INSERT' or new.category_id is distinct from old.category_id)then perform 1 from public.item_categories where id=new.category_id and is_active for share;if not found then raise exception 'Select an active parent category';end if;end if;
  if tg_op='UPDATE' and new.category_id<>old.category_id and coalesce(current_setting('app.item_master_consolidation',true),'0')<>'1' and exists(select 1 from public.items where subcategory_id=old.id)then raise exception 'Referenced subcategory cannot be reparented; use explicit consolidation';end if;
  select exists(select 1 from public.item_subcategories where id<>new.id and category_id=new.category_id and public.item_import_normalize(name)=public.item_import_normalize(new.name))into duplicate;
 else execute format('select exists(select 1 from public.%I where id<>$1 and public.item_import_normalize(name)=public.item_import_normalize($2))',tg_table_name)into duplicate using new.id,new.name;end if;
 if duplicate and(tg_op='INSERT' or new.name is distinct from old.name or (to_jsonb(new)->>'category_id') is distinct from (to_jsonb(old)->>'category_id'))then raise exception 'Normalized master name already exists; resolve explicitly';end if;
 return new;
end$$;
create function public.audit_item_import_master()returns trigger language plpgsql security definer set search_path='' as $$begin
 insert into public.item_master_admin_activities(master_table,event_type,details,created_by)values(tg_table_name,tg_op,jsonb_build_object('before',case when tg_op<>'INSERT'then to_jsonb(old)end,'after',case when tg_op<>'DELETE'then to_jsonb(new)end),auth.uid());if tg_op='DELETE'then return old;end if;return new;
end$$;
create function public.guard_item_active_selection()returns trigger language plpgsql security definer set search_path='' as $$
declare col text;t text;v_id uuid;old_id uuid;active boolean;
begin
 for col,t in select * from(values('category_id','item_categories'),('subcategory_id','item_subcategories'),('item_type_id','item_types'),('unit_id','units_of_measurement'),('brand_id','item_brands'),('stock_classification_id','stock_classifications'))v(col,t)loop
  v_id:=nullif(to_jsonb(new)->>col,'')::uuid;old_id:=case when tg_op='UPDATE'then nullif(to_jsonb(old)->>col,'')::uuid end;
  if v_id is not null and(tg_op='INSERT' or v_id is distinct from old_id or(col='category_id' and new.subcategory_id is not null and new.subcategory_id is distinct from old.subcategory_id))then
   execute format('select is_active from public.%I where id=$1 for share',t)into active using v_id;
   if not coalesce(active,false)then raise exception 'Select an active %',t;end if;
  end if;
 end loop;return new;
end$$;
create trigger guard_item_active_selection before insert or update on public.items for each row execute function public.guard_item_active_selection();

create function public.item_master_dependencies(p_table text,p_id uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare c record;n bigint;result jsonb:='[]';
begin
 perform public.item_import_assert_admin();if p_table not in('item_categories','item_subcategories','item_types','units_of_measurement','stock_locations','stock_classifications')then raise exception 'Invalid master';end if;
 for c in select ns.nspname schema_name,cl.relname table_name,a.attname column_name from pg_catalog.pg_constraint fk join pg_catalog.pg_class cl on cl.oid=fk.conrelid join pg_catalog.pg_namespace ns on ns.oid=cl.relnamespace join pg_catalog.pg_attribute a on a.attrelid=cl.oid and a.attnum=any(fk.conkey)where fk.contype='f' and fk.confrelid=to_regclass('public.'||p_table)loop
  execute format('select count(*)from %I.%I where %I=$1',c.schema_name,c.table_name,c.column_name)into n using p_id;
  if n>0 then result:=result||jsonb_build_array(jsonb_build_object('table',c.table_name,'column',c.column_name,'count',n));end if;
 end loop;return result;
end$$;
create function public.delete_item_configuration(p_table text,p_id uuid)returns void language plpgsql security definer set search_path='' as $$
declare refs jsonb;
begin
 perform public.item_import_assert_admin();refs:=public.item_master_dependencies(p_table,p_id);
 if jsonb_array_length(refs)>0 then raise exception 'Deletion blocked by references: %. Deactivate instead.',refs;end if;
 execute format('delete from public.%I where id=$1',p_table)using p_id;
exception when foreign_key_violation then raise exception 'Deletion blocked by a concurrent or existing dependency. Deactivate instead.';
end$$;

create function public.preview_item_consolidation(p_table text,p_source uuid,p_target uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare s jsonb;t jsonb;dependents jsonb;
begin
 perform public.item_import_assert_admin();perform public.item_master_dependencies(p_table,p_source);
 if p_source=p_target then raise exception 'Choose a different explicit target';end if;
 execute format('select to_jsonb(x)from public.%I x where id=$1',p_table)into s using p_source;
 execute format('select to_jsonb(x)from public.%I x where id=$1',p_table)into t using p_target;
 if s is null or t is null or not(t->>'is_active')::boolean then raise exception 'Source and active target required';end if;
 if p_table='item_categories'then select coalesce(jsonb_agg(to_jsonb(x)order by id),'[]')into dependents from public.item_subcategories x where category_id in(p_source,p_target);end if;
 return jsonb_build_object('source',s,'target',t,'references',public.item_master_dependencies(p_table,p_source),'dependent_subcategories',dependents);
end$$;
create function public.consolidate_item_configuration(p_table text,p_source uuid,p_target uuid,p_preview jsonb,p_confirm boolean)returns void language plpgsql security definer set search_path='' as $$
declare fresh jsonb;target_parent uuid;col text;
begin
 perform public.item_import_assert_admin();if not coalesce(p_confirm,false)then raise exception 'Explicit administrator confirmation required';end if;
 -- Same table order as import; all reference moves are atomic. Immutable snapshots stay intact.
 lock table public.item_categories,public.item_subcategories,public.item_types,public.units_of_measurement,public.stock_locations,public.stock_classifications,public.items in share row exclusive mode;
 fresh:=public.preview_item_consolidation(p_table,p_source,p_target);if fresh<>p_preview then raise exception 'Consolidation preview changed; review again';end if;
 if p_table='stock_locations' and jsonb_array_length(fresh->'references')>0 then raise exception 'Location has balances, source mappings or history. Deactivate instead; ledger references cannot be rewritten';end if;
 if p_table='units_of_measurement'and exists(select 1 from public.items i join public.inventory_transactions t on t.item_id=i.id where i.unit_id=p_source)then raise exception 'Unit has inventory history. Deactivate instead; quantities cannot be reinterpreted';end if;
 if p_table='item_types'and coalesce((fresh->'target'->>'automatic_code_enabled')::boolean,false)and exists(select 1 from public.items where item_type_id=p_source)then raise exception 'Cannot move existing items into automatic numbering';end if;
 perform set_config('app.item_master_consolidation','1',true);
 if p_table='item_categories'then
  if exists(select 1 from public.item_subcategories a join public.item_subcategories b on public.item_import_normalize(a.name)=public.item_import_normalize(b.name)where a.category_id=p_source and b.category_id=p_target and(a.is_active or exists(select 1 from public.items i where i.subcategory_id=a.id)))then raise exception 'Child-name conflict: explicitly consolidate the affected subcategories first';end if;
  update public.item_subcategories set category_id=p_target,updated_by=auth.uid()where category_id=p_source and(is_active or exists(select 1 from public.items i where i.subcategory_id=public.item_subcategories.id));
  update public.items set category_id=p_target,updated_by=auth.uid()where category_id=p_source;
 elsif p_table='item_subcategories'then
  target_parent:=(fresh->'target'->>'category_id')::uuid;
  update public.items set subcategory_id=p_target,category_id=target_parent,updated_by=auth.uid()where subcategory_id=p_source;
 elsif p_table<>'stock_locations'then
  col:=case p_table when 'item_types'then 'item_type_id'when 'units_of_measurement'then 'unit_id'else 'stock_classification_id'end;
  execute format('update public.items set %I=$1,updated_by=$2 where %I=$3',col,col)using p_target,auth.uid(),p_source;
 end if;
 execute format('update public.%I set is_active=false,updated_by=$1 where id=$2',p_table)using auth.uid(),p_source;
 insert into public.item_master_admin_activities(master_table,event_type,details,created_by)values(p_table,'CONSOLIDATED',fresh,auth.uid());
 perform set_config('app.item_master_consolidation','0',true);
end$$;

-- Private staging/audit history is visible to active Admins only; writes go through checked RPCs.
do $$declare t text;begin
 foreach t in array array['item_import_batches','item_import_links','item_master_admin_activities','item_import_stock_proposals']loop
  execute format('alter table public.%I enable row level security',t);
  execute format('create policy admin_read on public.%I for select to authenticated using(public.is_erp_admin() and public.has_active_erp_access())',t);
  execute format('grant select on public.%I to authenticated',t);
 end loop;
 foreach t in array array['item_categories','item_subcategories','item_types','units_of_measurement','stock_locations','stock_classifications']loop
  execute format('create trigger item_import_normalized_guard before insert or update on public.%I for each row execute function public.guard_item_import_master()',t);
  execute format('create trigger item_import_master_audit after insert or update or delete on public.%I for each row execute function public.audit_item_import_master()',t);
 end loop;
end$$;
alter table public.stock_classifications enable row level security;
create policy erp_read on public.stock_classifications for select to authenticated using(public.has_active_erp_access());
create policy admin_insert on public.stock_classifications for insert to authenticated with check(public.is_erp_admin() and public.has_active_erp_access());
create policy admin_update on public.stock_classifications for update to authenticated using(public.is_erp_admin() and public.has_active_erp_access())with check(public.is_erp_admin() and public.has_active_erp_access());
grant select,insert,update on public.stock_classifications to authenticated;
-- No DELETE grants: checked security-definer deletion retains FK and audit protections.
do $$declare f record;begin
 for f in select p.oid::regprocedure signature,p.proname name from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public'and p.proname in('item_import_stock_review_current','record_item_import_failure','item_import_assert_admin','item_import_master','item_import_preview_rows','item_import_preview','stage_item_import','refresh_item_import','item_import_create_master','commit_item_import','item_import_stock_snapshot','review_item_import_stock','guard_item_import_master','audit_item_import_master','guard_item_active_selection','item_master_dependencies','delete_item_configuration','preview_item_consolidation','consolidate_item_configuration')loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  if f.name in('item_import_stock_review_current','record_item_import_failure','stage_item_import','refresh_item_import','commit_item_import','review_item_import_stock','item_master_dependencies','delete_item_configuration','preview_item_consolidation','consolidate_item_configuration')then execute format('grant execute on function %s to authenticated',f.signature);end if;
 end loop;
end$$;
comment on table public.item_import_stock_proposals is 'Non-posting source review. Accounting semantics unapproved; posting permanently disabled in this migration.';
commit;
