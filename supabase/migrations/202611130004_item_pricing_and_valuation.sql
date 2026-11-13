-- Current-cost valuation and independently approved price-only imports.
-- No stock, historical COGS, selling prices or accounting entries are backfilled.
begin;
alter table public.items add column selling_price numeric(15,4) check(selling_price>=0 and selling_price<'Infinity'::numeric);
comment on column public.items.selling_price is 'Independent selling price; never inferred from purchase COGS.';
create function public.guard_item_selling_price()returns trigger language plpgsql set search_path=''as $$begin
 if (tg_op='INSERT' and new.selling_price is not null)or(tg_op='UPDATE' and new.selling_price is distinct from old.selling_price)then
  if auth.uid()is not null and not public.has_erp_permission('inventory.items','EDIT')then raise exception 'Item Master Edit permission required to change Selling Price';end if;
 end if;return new;end$$;
create trigger guard_item_selling_price before insert or update on public.items for each row execute function public.guard_item_selling_price();
revoke all on function public.guard_item_selling_price()from public,anon,authenticated;

-- SECURITY INVOKER: existing item/balance RLS remains authoritative. All numeric
-- products/sums are exact in PostgreSQL, returned as text to avoid JS float loss.
create function public.inventory_valuation_rows(p_location uuid default null,p_classification uuid default null,p_items uuid[] default null)
returns table(item_id uuid,location_id uuid,classification_id uuid,classification text,cogs text,selling text,usable text,rejected text,damaged text,physical text,missing_cogs boolean)
language sql stable set search_path=''as $$
 with amounts as(
 select i.id item_id,b.location_id,i.stock_classification_id classification_id,sc.name classification,i.cogs_unit_cost,i.selling_price,
 coalesce(b.on_hand_quantity,0)q,coalesce(b.rejected_quantity,0)r,coalesce(b.damaged_quantity,0)d
 from public.items i left join public.stock_classifications sc on sc.id=i.stock_classification_id
 left join public.inventory_balances b on b.item_id=i.id
 where(p_location is null or b.location_id=p_location)and(p_classification is null or i.stock_classification_id=p_classification)and(p_items is null or i.id=any(p_items))
 ),valued as(select *,case when q=0 then 0 else q*cogs_unit_cost end u,case when r=0 then 0 else r*cogs_unit_cost end rv,case when d=0 then 0 else d*cogs_unit_cost end dv from amounts)
 select item_id,location_id,classification_id,classification,cogs_unit_cost::text,selling_price::text,u::text,rv::text,dv::text,(u+rv+dv)::text,
 cogs_unit_cost is null and(q<>0 or r<>0 or d<>0)from valued
$$;
create function public.inventory_valuation_summary(p_location uuid default null,p_classification uuid default null,p_items uuid[] default null)returns jsonb language sql stable set search_path=''as $$
 with valued as materialized(select *from public.inventory_valuation_rows(p_location,p_classification,p_items)),
 groups as(select classification_id,classification,coalesce(sum(usable::numeric),0)::text usable,coalesce(sum(rejected::numeric),0)::text rejected,coalesce(sum(damaged::numeric),0)::text damaged,
 coalesce(sum(coalesce(usable::numeric,0)+coalesce(rejected::numeric,0)+coalesce(damaged::numeric,0)),0)::text physical,count(distinct item_id)filter(where missing_cogs)missing_cogs
 from valued group by classification_id,classification)
 select jsonb_build_object('usable',coalesce(sum(usable::numeric),0)::text,'rejected',coalesce(sum(rejected::numeric),0)::text,'damaged',coalesce(sum(damaged::numeric),0)::text,
 'physical',coalesce(sum(coalesce(usable::numeric,0)+coalesce(rejected::numeric,0)+coalesce(damaged::numeric,0)),0)::text,'missing_cogs',count(distinct item_id)filter(where missing_cogs),
 'groups',coalesce((select jsonb_agg(to_jsonb(g)order by classification nulls last,classification_id)from groups g),'[]'))from valued
$$;
revoke all on function public.inventory_valuation_rows(uuid,uuid,uuid[]),public.inventory_valuation_summary(uuid,uuid,uuid[])from public,anon;
grant execute on function public.inventory_valuation_rows(uuid,uuid,uuid[]),public.inventory_valuation_summary(uuid,uuid,uuid[])to authenticated;

create function public.item_pricing_valuation(p_items uuid[],p_location uuid default null)
returns table(item_id uuid,cogs text,selling text,usable text,rejected text,damaged text,physical text,missing_cogs boolean)
language sql stable set search_path=''as $$
 with valued as(select v.item_id,
 case when bool_or(v.usable is null)then null else coalesce(sum(v.usable::numeric),0)::text end usable,
 case when bool_or(v.rejected is null)then null else coalesce(sum(v.rejected::numeric),0)::text end rejected,
 case when bool_or(v.damaged is null)then null else coalesce(sum(v.damaged::numeric),0)::text end damaged,
 case when bool_or(v.physical is null)then null else coalesce(sum(v.physical::numeric),0)::text end physical,bool_or(v.missing_cogs)missing
 from public.inventory_valuation_rows(p_location,null,p_items)v group by v.item_id)
 select i.id,i.cogs_unit_cost::text,i.selling_price::text,
 case when v.item_id is null then '0'else v.usable end,case when v.item_id is null then '0'else v.rejected end,case when v.item_id is null then '0'else v.damaged end,case when v.item_id is null then '0'else v.physical end,coalesce(v.missing,false)
 from public.items i left join valued v on v.item_id=i.id where i.id=any(p_items)
$$;
revoke all on function public.item_pricing_valuation(uuid[],uuid)from public,anon;grant execute on function public.item_pricing_valuation(uuid[],uuid)to authenticated;

create table public.item_price_imports(
 id uuid primary key default gen_random_uuid(),source_batch_id uuid references public.item_import_batches(id)on delete restrict,
 source_name text not null,source_sha256 text not null check(source_sha256~'^[0-9a-f]{64}$'),sheet text not null,
 state text not null default 'DRAFT'check(state in('DRAFT','RUNNING','PAUSED','COMPLETED')),revision integer not null default 1,
 request_key uuid unique,reason text,approved_by uuid references auth.users(id),approved_at timestamptz,
 created_by uuid not null references auth.users(id),created_at timestamptz not null default now()
);
create table public.item_price_import_chunks(
 id uuid primary key default gen_random_uuid(),import_id uuid not null references public.item_price_imports(id)on delete restrict,
 sequence integer not null,revision integer not null,request_key uuid not null unique default gen_random_uuid(),
 state text not null default 'PENDING'check(state in('PENDING','POSTED','FAILED','SUPERSEDED')),approval jsonb not null,
 row_count integer not null check(row_count between 1 and 100),error text,posted_at timestamptz,unique(import_id,revision,sequence)
);
create table public.item_price_import_rows(
 id uuid primary key default gen_random_uuid(),import_id uuid not null references public.item_price_imports(id)on delete restrict,source_row integer not null,
 raw jsonb not null,issues jsonb not null default '[]',item_id uuid references public.items(id),unit_id uuid references public.units_of_measurement(id),
 old_cogs numeric(15,4),new_cogs numeric(15,4),state text not null default 'INVALID'check(state in('READY','UNCHANGED','INVALID','PENDING','POSTED','SKIPPED')),
 error text,warning text,chunk_id uuid references public.item_price_import_chunks(id),posted_at timestamptz,unique(import_id,source_row)
);
create index item_price_rows_chunk on public.item_price_import_rows(chunk_id,state);
create index item_price_imports_recent on public.item_price_imports(created_at desc,id desc);
create table public.item_price_changes(
 id uuid primary key default gen_random_uuid(),row_id uuid not null unique references public.item_price_import_rows(id),
 item_id uuid not null references public.items(id),old_cogs numeric(15,4),new_cogs numeric(15,4)not null,
 approved_by uuid not null references auth.users(id),changed_by uuid not null references auth.users(id),changed_at timestamptz not null default clock_timestamp(),reason text not null
);
create trigger item_price_changes_immutable before update or delete on public.item_price_changes for each row execute function public.prevent_inventory_history_change();

create function public.item_price_assert_editor()returns void language plpgsql stable security definer set search_path=''as $$begin
 perform public.item_import_assert_admin();if not public.has_erp_permission('inventory.items','EDIT')then raise exception 'Item Master Edit permission required';end if;
end$$;
create function public.item_price_parse(p_text text)returns numeric language plpgsql immutable set search_path=''as $$declare q numeric;begin
 if coalesce(p_text,'')!~'^[0-9]+([.][0-9]*)?([eE][+-]?[0-9]+)?$'or length(p_text)>100 then return null;end if;
 q:=round(p_text::numeric,4);if q<0 or q>=100000000000 then return null;end if;return q;
exception when others then return null;end$$;
create function public.item_price_source_numeric(p_text text)returns numeric language plpgsql immutable set search_path=''as $$declare q numeric;begin
 if coalesce(p_text,'')!~'^[0-9]+([.][0-9]*)?([eE][+-]?[0-9]+)?$'or length(p_text)>100 then return null;end if;
 q:=p_text::numeric;if q>=1000000000000000000000000 then return null;end if;return q;
exception when others then return null;end$$;
create function public.refresh_item_price_import(p_id uuid)returns void language plpgsql security definer set search_path=''as $$
declare j public.item_price_imports%rowtype;
begin
 perform public.item_price_assert_editor();select *into j from public.item_price_imports where id=p_id for update nowait;
 if not found or j.state not in('DRAFT','PAUSED')then raise exception 'Price review required: refresh only a draft or paused price import';end if;
 update public.item_price_import_chunks set state='SUPERSEDED'where import_id=p_id and state in('PENDING','FAILED');
 with source as materialized(select r.*,sj.source_batch_id,count(*)over(partition by lower(trim(raw->>'New code')))duplicates from public.item_price_import_rows r join public.item_price_imports sj on sj.id=r.import_id where import_id=p_id),
 mapped as(select r.id,i.id item_id,i.unit_id,i.cogs_unit_cost old_cost,public.item_price_parse(r.raw->>'Rate (Rs)')cost,
 case when i.id is null then 'Item code is unmatched; this price-only import cannot create products'
 when not i.is_active then 'Item is inactive' when r.duplicates>1 then 'Duplicate source item code'
 when public.item_price_parse(r.raw->>'Rate (Rs)')is null then 'Rate (Rs) is invalid or outside COGS precision/range'
 when not u.is_active or case when link.unit_id is not null then link.unit_id is distinct from i.unit_id else public.item_import_normalize(u.name)is distinct from public.item_import_normalize(r.raw->>'Unit')end then 'Source Unit does not match the active item unit; no cost conversion is assumed'
 when exists(select 1 from jsonb_array_elements_text(r.issues)x where x like 'Unsupported formula%')then 'Unsupported formula in source workbook' end error,
 concat_ws('; ',case when i.item_name is distinct from trim(r.raw->>'Item name')then 'Item name differs; matching uses permanent code'end,
 case when case when public.item_price_parse(r.raw->>'Rate (Rs)')is not null then public.item_price_parse(r.raw->>'Rate (Rs)')is distinct from (r.raw->>'Rate (Rs)')::numeric else false end then 'Rate rounds to four decimal places; approve the displayed proposed COGS'end)warning
 from source r left join public.items i on lower(trim(i.item_code))=lower(trim(r.raw->>'New code'))left join public.units_of_measurement u on u.id=i.unit_id left join public.item_import_links link on link.batch_id=r.source_batch_id and link.source_row=r.source_row and link.item_id=i.id)
 update public.item_price_import_rows r set item_id=m.item_id,unit_id=m.unit_id,old_cogs=m.old_cost,new_cogs=m.cost,error=m.error,warning=nullif(m.warning,''),chunk_id=null,
 state=case when m.error is not null then 'INVALID'when m.old_cost is not distinct from m.cost then 'UNCHANGED'else 'READY'end
 from mapped m where r.id=m.id and r.state<>'POSTED';
 update public.item_price_imports set state='DRAFT',revision=revision+1,request_key=null,approved_by=null,approved_at=null where id=p_id;
end$$;
create function public.prepare_item_price_import(p_name text,p_sha256 text,p_sheet text,p_rows jsonb,p_source uuid)returns uuid language plpgsql security definer set search_path=''as $$
declare v_id uuid;
begin
 perform public.item_price_assert_editor();
 if jsonb_typeof(p_rows)<>'array'or jsonb_array_length(p_rows)not between 1 and 10000 or length(p_name)not between 1 and 255 then raise exception 'Price review required: expected 1–10000 workbook rows';end if;
 insert into public.item_price_imports(source_batch_id,source_name,source_sha256,sheet,created_by)values(p_source,p_name,p_sha256,p_sheet,auth.uid())returning id into v_id;
 insert into public.item_price_import_rows(import_id,source_row,raw,issues)select v_id,(r->>'row')::integer,r->'raw',coalesce(r->'issues','[]')from jsonb_array_elements(p_rows)r;
 perform public.refresh_item_price_import(v_id);return v_id;
end$$;
create function public.stage_item_price_import(p_name text,p_sha256 text,p_sheet text,p_source_base64 text,p_rows jsonb)returns uuid language plpgsql security definer set search_path=''as $$begin
 perform public.item_price_assert_editor();if encode(sha256(decode(p_source_base64,'base64')),'hex')<>p_sha256 then raise exception 'Workbook digest mismatch';end if;
 return public.prepare_item_price_import(p_name,p_sha256,p_sheet,p_rows,null);
end$$;
create function public.reuse_item_price_source(p_source uuid)returns uuid language plpgsql security definer set search_path=''as $$declare b public.item_import_batches%rowtype;begin
 perform public.item_price_assert_editor();select *into b from public.item_import_batches where id=p_source and purpose='ITEM_MASTER'and state='COMMITTED';if not found then raise exception 'Choose a committed Item Master source';end if;
 return public.prepare_item_price_import(b.source_name,b.source_sha256,b.sheet,b.source_rows,b.id);
end$$;
create function public.item_price_progress(p_id uuid)returns jsonb language plpgsql stable security definer set search_path=''as $$declare j public.item_price_imports%rowtype;v jsonb;begin
 perform public.item_price_assert_editor();select *into j from public.item_price_imports where id=p_id;if not found then raise exception 'Price import not found';end if;
 select jsonb_build_object('id',j.id,'state',j.state,'revision',j.revision,'total',count(*),'ready',count(*)filter(where state='READY'),'unchanged',count(*)filter(where state='UNCHANGED'),'invalid',count(*)filter(where state='INVALID'),'posted',count(*)filter(where state='POSTED'),'pending',count(*)filter(where state='PENDING'),
 'next',(select jsonb_build_object('id',c.id,'key',c.request_key,'sequence',c.sequence,'error',c.error)from public.item_price_import_chunks c where c.import_id=p_id and c.revision=j.revision and c.state in('PENDING','FAILED')order by c.sequence limit 1))into v from public.item_price_import_rows where import_id=p_id;return v;
end$$;
create function public.item_price_page(p_id uuid,p_offset integer default 0)returns jsonb language plpgsql stable security definer set search_path=''as $$declare result jsonb;begin
 perform public.item_price_assert_editor();if p_offset is null or p_offset<0 then raise exception 'Invalid price page';end if;
 select coalesce(jsonb_agg(jsonb_build_object('row',r.source_row,'code',r.raw->>'New code','name',i.item_name,'unit',r.raw->>'Unit','old_cogs',r.old_cogs::text,'new_cogs',r.new_cogs::text,'selling',i.selling_price::text,'state',r.state,'error',r.error,'warning',r.warning,'raw',r.raw,'source_usable_difference',(public.item_price_source_numeric(r.raw->>'Value (Rs)')-public.item_price_source_numeric(r.raw->>'Opening qty')*public.item_price_source_numeric(r.raw->>'Rate (Rs)'))::text,'source_rejected_difference',(public.item_price_source_numeric(r.raw->>'Rejected value (Rs)')-public.item_price_source_numeric(r.raw->>'Rejected qty')*public.item_price_source_numeric(r.raw->>'Rate (Rs)'))::text)order by source_row),'[]')into result
 from(select *from public.item_price_import_rows where import_id=p_id order by source_row limit 100 offset p_offset)r left join public.items i on i.id=r.item_id;
 return jsonb_build_object('rows',result,'eligible',case when p_offset=0 then(select coalesce(jsonb_agg(source_row order by source_row),'[]')from public.item_price_import_rows where import_id=p_id and state='READY')end,'offset',p_offset);
end$$;
create function public.approve_item_price_import(p_id uuid,p_revision integer,p_rows integer[],p_request_key uuid,p_reason text)returns jsonb language plpgsql security definer set search_path=''as $$
declare j public.item_price_imports%rowtype;v_count integer;
begin
 perform public.item_price_assert_editor();select *into j from public.item_price_imports where id=p_id for update nowait;
 if not found then raise exception 'Price import not found';end if;
 if j.state in('RUNNING','COMPLETED')and j.request_key=p_request_key then return public.item_price_progress(p_id);end if;
 if j.state<>'DRAFT'or j.revision<>p_revision then raise exception 'Price review required: review the current draft revision';end if;
 if p_request_key is null or nullif(trim(p_reason),'')is null or coalesce(cardinality(p_rows),0)=0 or cardinality(p_rows)>10000 then raise exception 'Price review required: select changed rows and enter an approval reason';end if;
 if exists(select 1 from unnest(p_rows)n group by n having count(*)>1)then raise exception 'Duplicate selection';end if;
 select count(*)into v_count from public.item_price_import_rows where import_id=p_id and source_row=any(p_rows)and state='READY';if v_count<>cardinality(p_rows)then raise exception 'Price review required: selected rows must be valid changed prices';end if;
 insert into public.item_price_import_chunks(import_id,sequence,revision,row_count,approval)
 select p_id,part,j.revision,count(*),jsonb_agg(jsonb_build_object('id',id,'item_id',item_id,'unit_id',unit_id,'old_cogs',old_cogs::text,'new_cogs',new_cogs::text)order by source_row)
 from(select r.*,((row_number()over(order by source_row)-1)/100+1)::integer part from public.item_price_import_rows r where import_id=p_id and source_row=any(p_rows))s group by part;
 with selected as(select id,((row_number()over(order by source_row)-1)/100+1)::integer part from public.item_price_import_rows where import_id=p_id and source_row=any(p_rows))
 update public.item_price_import_rows r set state='PENDING',chunk_id=c.id from selected s join public.item_price_import_chunks c on c.import_id=p_id and c.revision=j.revision and c.sequence=s.part where r.id=s.id;
 update public.item_price_import_rows set state='SKIPPED'where import_id=p_id and state='READY';
 update public.item_price_imports set state='RUNNING',request_key=p_request_key,reason=trim(p_reason),approved_by=auth.uid(),approved_at=clock_timestamp()where id=p_id;
 return public.item_price_progress(p_id);
end$$;
create function public.process_item_price_chunk(p_id uuid,p_chunk uuid,p_key uuid)returns jsonb language plpgsql security definer set search_path=''as $$
declare j public.item_price_imports%rowtype;c public.item_price_import_chunks%rowtype;v_row record;v_code text;v_message text;
begin
 perform public.item_price_assert_editor();select *into j from public.item_price_imports where id=p_id for update nowait;
 if not found then raise exception 'Price import not found';end if;
 select *into c from public.item_price_import_chunks where id=p_chunk and import_id=p_id for update nowait;
 if not found or c.request_key<>p_key then raise exception 'Price review required: invalid chunk key';end if;
 if c.state='POSTED'then return public.item_price_progress(p_id);end if;
 if c.revision<>j.revision or c.state='SUPERSEDED'then raise exception 'Price review required: approval was superseded';end if;
 if j.state<>'RUNNING'or c.state='FAILED'then return public.item_price_progress(p_id);end if;
 if exists(select 1 from public.item_price_import_chunks where import_id=p_id and revision=j.revision and sequence<c.sequence and state<>'POSTED')then raise exception 'Process the next pending price batch';end if;
 begin
  perform 1 from public.items i join public.item_price_import_rows r on r.item_id=i.id where r.chunk_id=p_chunk order by i.id for update of i nowait;
  perform 1 from public.units_of_measurement u join public.item_price_import_rows r on r.unit_id=u.id where r.chunk_id=p_chunk order by u.id for share of u nowait;
  if(select count(*)from public.item_price_import_rows where chunk_id=p_chunk and state='PENDING')<>c.row_count then raise exception 'Price review required: chunk selection changed';end if;
  for v_row in select r.*,i.cogs_unit_cost current_cogs,i.unit_id current_unit,i.is_active,u.is_active unit_active from public.item_price_import_rows r join public.items i on i.id=r.item_id join public.units_of_measurement u on u.id=i.unit_id where r.chunk_id=p_chunk order by r.source_row loop
   if not v_row.is_active or not v_row.unit_active or v_row.current_cogs is distinct from v_row.old_cogs or v_row.current_unit is distinct from v_row.unit_id then raise exception 'Price review required: current COGS, activity or unit changed on row %; refresh and approve again',v_row.source_row;end if;
   if not exists(select 1 from jsonb_array_elements(c.approval)a where a->>'id'=v_row.id::text and a->>'item_id'=v_row.item_id::text and a->>'unit_id'=v_row.unit_id::text and nullif(a->>'old_cogs','')::numeric is not distinct from v_row.old_cogs and(a->>'new_cogs')::numeric=v_row.new_cogs)then raise exception 'Price review required: approved prices changed';end if;
  end loop;
  -- Set-based update touches only COGS and update attribution. Selling price and
  -- all stock/sales/finance snapshots are intentionally absent from this write.
  update public.items i set cogs_unit_cost=r.new_cogs,updated_by=auth.uid()from public.item_price_import_rows r where r.chunk_id=p_chunk and r.item_id=i.id;
  insert into public.item_price_changes(row_id,item_id,old_cogs,new_cogs,approved_by,changed_by,reason)select id,item_id,old_cogs,new_cogs,j.approved_by,auth.uid(),j.reason from public.item_price_import_rows where chunk_id=p_chunk;
  update public.item_price_import_rows set state='POSTED',posted_at=clock_timestamp()where chunk_id=p_chunk;
  update public.item_price_import_chunks set state='POSTED',posted_at=clock_timestamp(),error=null where id=p_chunk;
 exception when others then
  get stacked diagnostics v_code=returned_sqlstate,v_message=message_text;
  update public.item_price_import_chunks set state='FAILED',error=case when v_message like 'Price review required:%'then left(v_message,500)else 'Price batch rolled back ('||v_code||'). Refresh pending prices before approval and retry.'end where id=p_chunk;
  update public.item_price_imports set state='PAUSED'where id=p_id;return public.item_price_progress(p_id);
 end;
 if not exists(select 1 from public.item_price_import_chunks where import_id=p_id and revision=j.revision and state<>'POSTED')then update public.item_price_imports set state='COMPLETED'where id=p_id;end if;
 return public.item_price_progress(p_id);
end$$;
create function public.interrupt_item_price_import(p_id uuid,p_chunk uuid,p_key uuid)returns jsonb language plpgsql security definer set search_path=''as $$
declare c public.item_price_import_chunks%rowtype;begin
 perform public.item_price_assert_editor();perform 1 from public.item_price_imports where id=p_id for update nowait;
 select *into c from public.item_price_import_chunks where id=p_chunk and import_id=p_id and request_key=p_key for update nowait;
 if found and c.state='PENDING'then update public.item_price_import_chunks set state='FAILED',error='Request interrupted. Refresh pending prices, review and approve again; earlier chunks remain saved.'where id=p_chunk;update public.item_price_imports set state='PAUSED'where id=p_id;end if;
 return public.item_price_progress(p_id);
end$$;

do $$declare t text;f record;begin
 foreach t in array array['item_price_imports','item_price_import_rows','item_price_import_chunks','item_price_changes']loop
  execute format('alter table public.%I enable row level security',t);
  execute format('create policy admin_read on public.%I for select to authenticated using(public.is_erp_admin()and public.has_active_erp_access())',t);
  execute format('grant select on public.%I to authenticated',t);
 end loop;
 for f in select p.oid::regprocedure signature,p.proname name from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid=p.pronamespace where n.nspname='public'and p.proname in('item_price_assert_editor','item_price_parse','item_price_source_numeric','prepare_item_price_import','stage_item_price_import','reuse_item_price_source','refresh_item_price_import','item_price_progress','item_price_page','approve_item_price_import','process_item_price_chunk','interrupt_item_price_import')loop
  execute format('revoke all on function %s from public,anon,authenticated',f.signature);
  if f.name not in('item_price_assert_editor','item_price_parse','item_price_source_numeric','prepare_item_price_import')then execute format('grant execute on function %s to authenticated',f.signature);end if;
 end loop;
end$$;
commit;
