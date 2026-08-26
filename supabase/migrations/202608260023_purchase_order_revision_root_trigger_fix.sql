drop trigger if exists purchase_orders_revision_root on public.purchase_orders;
drop trigger if exists purchase_order_items_revision_root on public.purchase_order_items;
drop function if exists public.set_purchase_revision_roots();

create or replace function public.set_purchase_order_revision_root()returns trigger language plpgsql set search_path=''as $$
begin
 if new.root_po_id is null then new.root_po_id:=new.id;end if;
 return new;
end$$;

create or replace function public.set_purchase_order_item_revision_root()returns trigger language plpgsql set search_path=''as $$
begin
 if new.root_po_item_id is null then new.root_po_item_id:=new.id;end if;
 return new;
end$$;

create trigger purchase_orders_revision_root before insert on public.purchase_orders for each row execute function public.set_purchase_order_revision_root();
create trigger purchase_order_items_revision_root before insert on public.purchase_order_items for each row execute function public.set_purchase_order_item_revision_root();
