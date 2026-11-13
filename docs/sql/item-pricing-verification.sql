-- READ ONLY. Use a disposable local database first. No products, stock or prices
-- are modified. All valuations use actual inventory_balances, not source rows.
select item_code,cogs_unit_cost::text purchase_cogs,selling_price::text
from public.items order by item_code,id limit 100;

select public.inventory_valuation_summary();
-- Optional location / classification filters:
-- select public.inventory_valuation_summary('<location UUID>'::uuid,'<classification UUID>'::uuid);

-- Source reconciliation is diagnostic: differences do not authorize any update.
with source as materialized(
 select b.source_rows from public.item_import_batches b
 where b.purpose='ITEM_MASTER'and b.state='COMMITTED'
 and b.source_name in('Item master v5.xlsx','Item master v5(1).xlsx')
 order by b.created_at desc,b.id desc limit 1
),rows as(select r->'raw'raw from source cross join lateral jsonb_array_elements(source.source_rows)r)
select count(*) source_rows,
 count(*)filter(where i.id is null)unmatched,
 count(*)filter(where i.cogs_unit_cost is not distinct from public.item_price_parse(raw->>'Rate (Rs)'))matching_cogs,
 count(*)filter(where i.id is not null and i.cogs_unit_cost is distinct from public.item_price_parse(raw->>'Rate (Rs)'))different_cogs
from rows left join public.items i on lower(trim(i.item_code))=lower(trim(raw->>'New code'));
-- item_price_parse is internal: this source-reconciliation query is intended for
-- the authorized SQL Editor/database owner. Application users use the Admin price preview.

select id,source_name,state,revision,approved_at,approved_by,reason
from public.item_price_imports order by created_at desc,id desc limit 25;
select c.item_id,c.old_cogs::text,c.new_cogs::text,c.approved_by,c.changed_by,c.changed_at,c.reason
from public.item_price_changes c order by c.changed_at desc,c.id desc limit 100;

-- Record these counts before/after a price-only fixture approval; they must not
-- increase because of the price operation. Test assertions also compare balances
-- and ledger contents exactly, not merely their counts.
select (select count(*)from public.inventory_transactions)stock_ledger_entries,
       (select count(*)from public.inventory_balances)stock_balance_rows;
