begin;

alter table public.orders
  add column if not exists shipping_contact_number varchar(50);

alter table public.proforma_invoices
  add column if not exists shipping_contact_number varchar(50),
  add column if not exists other_remarks text;

create or replace function public.normalize_sales_document_extras()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if tg_table_name = 'orders' then
    new.shipping_contact_number := nullif(trim(new.shipping_contact_number), '');
  else
    new.shipping_contact_number := nullif(trim(new.shipping_contact_number), '');
    new.other_remarks := nullif(trim(new.other_remarks), '');

    if tg_op = 'INSERT' and new.revised_from_id is not null then
      select p.shipping_contact_number, p.other_remarks
        into new.shipping_contact_number, new.other_remarks
        from public.proforma_invoices p
       where p.id = new.revised_from_id;
    elsif tg_op = 'INSERT' and new.shipping_contact_number is null then
      select o.shipping_contact_number
        into new.shipping_contact_number
        from public.orders o
       where o.id = new.order_id;
    end if;
  end if;
  return new;
end;
$$;

drop trigger if exists normalize_order_shipping_contact on public.orders;
create trigger normalize_order_shipping_contact
before insert or update of shipping_contact_number on public.orders
for each row execute function public.normalize_sales_document_extras();

drop trigger if exists normalize_pi_extras on public.proforma_invoices;
create trigger normalize_pi_extras
before insert or update of shipping_contact_number, other_remarks on public.proforma_invoices
for each row execute function public.normalize_sales_document_extras();

create or replace function public.save_proforma_invoice_extras(
  p_pi_id uuid,
  p_shipping_contact_number text,
  p_other_remarks text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  update public.proforma_invoices
     set shipping_contact_number = p_shipping_contact_number,
         other_remarks = p_other_remarks,
         updated_by = auth.uid(),
         updated_at = now()
   where id = p_pi_id
     and status = 'DRAFT'
     and public.can_manage_proforma_invoice(id);
  if not found then
    raise exception 'Draft PI not found or not editable';
  end if;
end;
$$;

revoke all on function public.save_proforma_invoice_extras(uuid,text,text) from public, anon;
grant execute on function public.save_proforma_invoice_extras(uuid,text,text) to authenticated;

commit;
