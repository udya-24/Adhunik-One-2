-- Read-path fix for completed imports. No product, stock or audit data is changed.
begin;
alter table public.item_import_batches add column source_row_count integer generated always as(jsonb_array_length(source_rows)) stored;
create index item_import_batches_recent on public.item_import_batches(purpose,created_at desc,id desc);
create index item_import_batches_completed on public.item_import_batches(purpose,state,created_at desc,id desc);
create index item_import_activities_batch_recent on public.item_master_admin_activities(batch_id,created_at desc,id desc);
create index inventory_transactions_item_location on public.inventory_transactions(item_id,location_id);
create or replace function public.item_import_stock_snapshot(p_batch uuid)returns jsonb language plpgsql security definer set search_path='' as $$
declare result jsonb;
begin
 perform public.item_import_assert_admin();
 with source as materialized(
  select (r->>'row')::integer source_row,r->'raw' raw
  from public.item_import_batches batch cross join lateral jsonb_array_elements(batch.source_rows)r where batch.id=p_batch
 )
 select coalesce(jsonb_agg(jsonb_build_object('row',l.source_row,'item_id',i.id,'item_code',i.item_code,'item_name',i.item_name,'unit_id',i.unit_id,'source_unit_id',l.unit_id,'unit_mapping_matches',i.unit_id=l.unit_id,'unit',u.name,'unit_active',u.is_active,'unit_version',u.updated_at,'item_version',i.updated_at,'location_version',s.updated_at,'item_active',i.is_active,'location_id',s.id,'location',s.name,'location_active',s.is_active,'raw',r.raw,'on_hand',coalesce(b.on_hand_quantity,0),'reserved',coalesce(b.reserved_quantity,0),'damaged',coalesce(b.damaged_quantity,0),'available',coalesce(b.on_hand_quantity-b.reserved_quantity,0),'balance_version',b.updated_at,'ledger_count',(select count(*)from public.inventory_transactions it where it.item_id=i.id and it.location_id=s.id),'operation','UNDETERMINED','proposed_delta',null,'resulting_balance',null)order by l.source_row),'[]')into result
 from public.item_import_links l join source r on r.source_row=l.source_row join public.items i on i.id=l.item_id join public.units_of_measurement u on u.id=i.unit_id join public.stock_locations s on s.id=l.location_id left join public.inventory_balances b on b.item_id=i.id and b.location_id=s.id
 where l.batch_id=p_batch;
 return result;
end$$;
commit;
