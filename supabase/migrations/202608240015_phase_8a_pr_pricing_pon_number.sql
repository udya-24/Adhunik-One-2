-- Adhunik ERP — Phase 8A enhancement: PR pricing, simple GST, freight and calendar-year PON numbering
begin;

alter table public.purchase_requisition_items add column unit_rate numeric(18,4) not null default 0;
alter table public.purchase_requisition_items add column line_amount numeric(18,2) not null default 0;
alter table public.purchase_requisition_items add constraint purchase_requisition_items_unit_rate_nonnegative check(unit_rate>=0);
alter table public.purchase_requisition_items add constraint purchase_requisition_items_line_amount_nonnegative check(line_amount>=0);
alter table public.purchase_requisitions add column subtotal numeric(18,2) not null default 0;
alter table public.purchase_requisitions add column gst_rate numeric(7,4) not null default 0;
alter table public.purchase_requisitions add column gst_amount numeric(18,2) not null default 0;
alter table public.purchase_requisitions add column freight_amount numeric(18,2) not null default 0;
alter table public.purchase_requisitions add column grand_total numeric(18,2) not null default 0;
alter table public.purchase_requisitions add constraint purchase_requisitions_commercial_nonnegative check(subtotal>=0 and gst_rate>=0 and gst_amount>=0 and freight_amount>=0 and grand_total>=0);

-- Existing PR/financial-year numbers remain immutable. New requisitions use this independent calendar-year counter.
create table public.purchase_pon_counters(calendar_year integer primary key check(calendar_year between 2000 and 9999),current_value bigint not null default 0 check(current_value>=0),updated_at timestamptz not null default now());
insert into public.purchase_pon_counters(calendar_year,current_value)
select substring(requisition_number from '^PON/([0-9]{4})/')::integer,max(substring(requisition_number from '/([0-9]+)$')::bigint)
from public.purchase_requisitions where requisition_number~'^PON/[0-9]{4}/[0-9]+$'
group by substring(requisition_number from '^PON/([0-9]{4})/')::integer
on conflict(calendar_year) do update set current_value=greatest(public.purchase_pon_counters.current_value,excluded.current_value),updated_at=now();alter table public.purchase_pon_counters enable row level security;
revoke all on public.purchase_pon_counters from public,anon,authenticated;
update public.numbering_configurations set prefix='PON',separator='/',padding=4,include_year=true,include_financial_year=false,updated_at=now(),updated_by=auth.uid() where entity_type='PURCHASE_REQUISITION';

create or replace function public.allocate_pon_number() returns text language plpgsql security definer set search_path='' as $$
declare y integer:=extract(year from current_date)::integer;n bigint;
begin
 insert into public.purchase_pon_counters(calendar_year,current_value) values(y,1)
 on conflict(calendar_year) do update set current_value=public.purchase_pon_counters.current_value+1,updated_at=now()
 returning current_value into n;
 return 'PON/'||y::text||'/'||lpad(n::text,4,'0');
end $$;
revoke all on function public.allocate_pon_number() from public,anon,authenticated;

create or replace function public.purchase_normalize_pr_items(p_items jsonb) returns table(line_number integer,source_type text,item_id uuid,item_code text,item_name text,description text,hsn_code text,unit_name text,quantity numeric,required_date date,remarks text,unit_rate numeric,line_amount numeric)
language plpgsql security definer set search_path='' as $$
declare x jsonb;i integer:=0;m record;q numeric;r numeric;a numeric;
begin
 if jsonb_typeof(p_items)<>'array' or jsonb_array_length(p_items)=0 then raise exception 'At least one item is required';end if;
 for x in select value from jsonb_array_elements(p_items) loop
  i:=i+1;q:=nullif(x->>'quantity','')::numeric;r:=coalesce(nullif(x->>'unit_rate','')::numeric,0);
  if q is null or q<=0 then raise exception 'Line % quantity must be greater than zero',i;end if;
  if r<0 then raise exception 'Line % rate must not be negative',i;end if;
  a:=round(q*r,2);
  if x->>'source_type'='ITEM_MASTER' then
   select t.id,t.item_code,t.item_name,t.description,t.hsn_code,u.name unit into m from public.items t join public.units_of_measurement u on u.id=t.unit_id where t.id=(x->>'item_id')::uuid and t.is_active;
   if not found then raise exception 'Line % has an invalid or inactive Item Master item',i;end if;
   return query select i,'ITEM_MASTER'::text,m.id,m.item_code,m.item_name,coalesce(nullif(trim(x->>'description'),''),m.description),m.hsn_code,m.unit,q,nullif(x->>'required_date','')::date,nullif(trim(x->>'remarks'),''),r,a;
  else
   if nullif(trim(x->>'item_name'),'') is null or nullif(trim(x->>'unit'),'') is null then raise exception 'Line % manual Item Name and Unit are required',i;end if;
   return query select i,'MANUAL'::text,null::uuid,nullif(trim(x->>'item_code'),''),trim(x->>'item_name'),nullif(trim(x->>'description'),''),nullif(trim(x->>'hsn_code'),''),trim(x->>'unit'),q,nullif(x->>'required_date','')::date,nullif(trim(x->>'remarks'),''),r,a;
  end if;
 end loop;
end $$;
revoke all on function public.purchase_normalize_pr_items(jsonb) from public,anon,authenticated;

create or replace function public.recalculate_purchase_requisition(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare s numeric(18,2);g numeric(7,4);f numeric(18,2);
begin
 update public.purchase_requisition_items set line_amount=round(quantity*unit_rate,2) where requisition_id=p_id;
 select coalesce(sum(line_amount),0) into s from public.purchase_requisition_items where requisition_id=p_id;
 select gst_rate,freight_amount into g,f from public.purchase_requisitions where id=p_id;
 if not found then raise exception 'Purchase requisition not found';end if;
 if g<0 or f<0 then raise exception 'GST rate and freight must not be negative';end if;
 update public.purchase_requisitions set subtotal=s,gst_amount=round(s*g/100,2),grand_total=round(s+round(s*g/100,2)+f,2),updated_at=now(),updated_by=auth.uid() where id=p_id;
end $$;
revoke all on function public.recalculate_purchase_requisition(uuid) from public,anon,authenticated;

create or replace function public.save_purchase_requisition(p_id uuid,p_header jsonb,p_items jsonb) returns uuid language plpgsql security definer set search_path='' as $$
declare g numeric:=coalesce(nullif(p_header->>'gst_rate','')::numeric,0);f numeric:=coalesce(nullif(p_header->>'freight_amount','')::numeric,0);
begin
 if not public.is_erp_manager() then raise exception 'Only Admin or Manager can edit a requisition';end if;
 if nullif(trim(p_header->>'purpose'),'') is null or nullif(p_header->>'department_id','') is null or nullif(p_header->>'required_date','') is null then raise exception 'Department, required date and purpose are required';end if;
 if g<0 or f<0 then raise exception 'GST rate and freight must not be negative';end if;
 perform 1 from public.purchase_normalize_pr_items(p_items);
 perform 1 from public.purchase_requisitions where id=p_id and status='DRAFT' for update;if not found then raise exception 'Draft requisition not found';end if;
 update public.purchase_requisitions set requisition_date=coalesce(nullif(p_header->>'requisition_date','')::date,requisition_date),department_id=(p_header->>'department_id')::uuid,required_date=(p_header->>'required_date')::date,priority=coalesce(nullif(p_header->>'priority',''),'NORMAL'),purpose=trim(p_header->>'purpose'),remarks=nullif(trim(p_header->>'remarks'),''),gst_rate=g,freight_amount=f,updated_at=now(),updated_by=auth.uid() where id=p_id;
 delete from public.purchase_requisition_items where requisition_id=p_id;
 insert into public.purchase_requisition_items(requisition_id,line_number,source_type,item_id,item_code_snapshot,item_name_snapshot,description_snapshot,hsn_code_snapshot,unit_snapshot,quantity,required_date,remarks,unit_rate,line_amount) select p_id,* from public.purchase_normalize_pr_items(p_items);
 perform public.recalculate_purchase_requisition(p_id);
 insert into public.purchase_requisition_activities values(default,p_id,'UPDATED','Draft requisition and commercial values updated',auth.uid(),default);return p_id;
end $$;

create or replace function public.confirm_purchase_requisition(p_id uuid) returns void language plpgsql security definer set search_path='' as $$
declare bad integer;
begin
 if not public.is_erp_manager() then raise exception 'Only Admin or Manager can confirm a requisition';end if;
 perform 1 from public.purchase_requisitions where id=p_id and status='DRAFT' for update;if not found then raise exception 'Draft requisition not found';end if;
 select count(*) into bad from public.purchase_requisition_items where requisition_id=p_id and(quantity<=0 or unit_rate<0);
 if not exists(select 1 from public.purchase_requisition_items where requisition_id=p_id) or bad>0 then raise exception 'PR requires valid items, quantities and rates';end if;
 perform public.recalculate_purchase_requisition(p_id);
 update public.purchase_requisitions set status='CONFIRMED',confirmed_at=now(),confirmed_by=auth.uid(),updated_at=now(),updated_by=auth.uid() where id=p_id;
 insert into public.purchase_requisition_activities values(default,p_id,'CONFIRMED','Purchase requisition confirmed with authoritative commercial totals',auth.uid(),default);
end $$;

create or replace function public.convert_indent_to_pr(p_indent_id uuid) returns uuid language plpgsql security definer set search_path='' as $$
declare h public.purchase_indents%rowtype;v uuid;fy uuid;n text;
begin
 if not public.is_erp_manager() then raise exception 'Only Admin or Manager can convert an indent';end if;
 select * into h from public.purchase_indents where id=p_indent_id for update;if not found then raise exception 'Indent not found';end if;
 select id into v from public.purchase_requisitions where indent_id=p_indent_id;if v is not null then return v;end if;
 if h.status<>'SUBMITTED' then raise exception 'Only submitted indents can be converted';end if;
 select id into fy from public.financial_years where is_current and is_active and deleted_at is null limit 1;n:=public.allocate_pon_number();
 insert into public.purchase_requisitions(requisition_number,indent_id,financial_year_id,department_id,requested_by,required_date,priority,purpose,remarks,created_by,updated_by,gst_rate,freight_amount) values(n,h.id,fy,h.department_id,h.requested_by,h.required_date,h.priority,h.purpose,h.remarks,auth.uid(),auth.uid(),0,0) returning id into v;
 insert into public.purchase_requisition_items(requisition_id,line_number,source_type,item_id,item_code_snapshot,item_name_snapshot,description_snapshot,hsn_code_snapshot,unit_snapshot,quantity,required_date,remarks,unit_rate,line_amount) select v,line_number,source_type,item_id,item_code_snapshot,item_name_snapshot,description_snapshot,hsn_code_snapshot,unit_snapshot,quantity,required_date,remarks,0,0 from public.purchase_indent_items where indent_id=h.id;
 update public.purchase_indents set status='CONVERTED_TO_PR',updated_at=now(),updated_by=auth.uid() where id=h.id;
 insert into public.purchase_indent_activities values(default,h.id,'CONVERTED_TO_PR','Converted to '||n,auth.uid(),default);insert into public.purchase_requisition_activities values(default,v,'CREATED','Created from '||h.indent_number||'; pricing initialized at zero',auth.uid(),default);return v;
end $$;

create or replace function public.get_purchase_user_labels(p_ids uuid[]) returns table(auth_user_id uuid,display_name text) language sql stable security definer set search_path='' as $$
 select p.auth_user_id,coalesce(e.full_name,p.login_email) from public.erp_profiles p left join public.employees e on e.id=p.employee_id where p.auth_user_id=any(p_ids) and public.is_erp_manager()
$$;
grant execute on function public.get_purchase_user_labels(uuid[]) to authenticated;
grant execute on function public.save_purchase_requisition(uuid,jsonb,jsonb),public.confirm_purchase_requisition(uuid),public.convert_indent_to_pr(uuid) to authenticated;
commit;