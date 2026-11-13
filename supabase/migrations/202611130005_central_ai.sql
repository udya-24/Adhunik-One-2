-- Central AI: single-organization ERP, NOT customer-company tenancy.
-- No keys, prompts or generated content are persisted. No existing roles/grants are changed.
begin;
insert into public.erp_permission_sections(module_key,section_key,module_name,section_name,sort_order) values
 ('configuration','configuration.ai_settings','Configuration','AI Configuration',230),
 ('configuration','configuration.ai_usage','Configuration','AI Usage Dashboard',231),
 ('ai','ai.use','AI','AI Access',1700),('ai','ai.general','AI','General Assistant',1710),
 ('ai','ai.inventory','AI','Inventory Matching',1720),('ai','ai.purchase','AI','Purchase Analysis',1730),
 ('ai','ai.sales','AI','Sales Assistance',1740),('ai','ai.dispatch','AI','Dispatch Assistance',1750),
 ('ai','ai.finance','AI','Finance Analysis',1760),('ai','ai.documents','AI','Document Extraction',1770)
on conflict(section_key) do nothing;

create table public.ai_settings (
 company_id uuid primary key default '00000000-0000-0000-0000-000000000001' check(company_id='00000000-0000-0000-0000-000000000001'),
 enabled boolean not null default false, default_model text not null default '', model_configuration jsonb not null default '{}',
 response_length text not null default 'medium' check(response_length in('short','medium','long')),
 max_output_tokens integer not null default 1024 check(max_output_tokens between 16 and 4096),
 timeout_ms integer not null default 15000 check(timeout_ms between 1000 and 45000), retry_limit integer not null default 0 check(retry_limit between 0 and 2),
 daily_budget_usd numeric(24,9) not null default 0 check(daily_budget_usd>=0), monthly_budget_usd numeric(24,9) not null default 0 check(monthly_budget_usd>=0),
 per_request_limit_usd numeric(24,9) not null default 0 check(per_request_limit_usd>=0), per_user_monthly_usd numeric(24,9) not null default 0 check(per_user_monthly_usd>=0),
 per_user_daily_requests integer not null default 20 check(per_user_daily_requests between 1 and 1000),
 max_concurrent_requests integer not null default 2 check(max_concurrent_requests between 1 and 20),
 alert_thresholds integer[] not null default '{50,80,100}', disabled_models text[] not null default '{}', restricted_users uuid[] not null default '{}',
 usd_to_inr numeric(12,6) check(usd_to_inr>0), exchange_rate_date date,
 tested_models jsonb not null default '{}',last_test_at timestamptz, last_success_at timestamptz,last_test_error text,tested_model text,
 updated_by uuid references auth.users(id),updated_at timestamptz not null default now(),
 check(usd_to_inr is null or exchange_rate_date is not null),check(jsonb_typeof(model_configuration)='object')
);
comment on column public.ai_settings.company_id is 'Fixed organization scope. Existing ERP is single-organization; customer_companies are customers, not tenants.';
insert into public.ai_settings default values;
create table public.ai_feature_config (
 company_id uuid not null references public.ai_settings(company_id), feature_code text not null,
 module_code text not null, enabled boolean not null default false,model text, required_permission text not null references public.erp_permission_sections(section_key),
 feature_configuration jsonb not null default '{}',updated_at timestamptz not null default now(), primary key(company_id,feature_code)
);
insert into public.ai_feature_config(company_id,feature_code,module_code,enabled,required_permission)
 select s.company_id,f.code,f.module,f.enabled,f.permission from public.ai_settings s cross join (values
 ('connection_test','configuration',true,'configuration.ai_settings'),('general','ai',false,'ai.general'),('inventory_matching','inventory',false,'ai.inventory'),
 ('document_extraction','documents',false,'ai.documents'),('finance_analysis','finance',false,'ai.finance'),('sales_assistance','sales',false,'ai.sales'),('purchase_analysis','purchase',false,'ai.purchase'),('dispatch_assistance','dispatch',false,'ai.dispatch'))f(code,module,enabled,permission);
create table public.ai_model_pricing (
 company_id uuid not null references public.ai_settings(company_id),model_identifier text not null,pricing_version text not null,effective_date timestamptz not null,
 input_price_per_million_tokens numeric(24,9) not null check(input_price_per_million_tokens>=0),
 cached_input_price_per_million_tokens numeric(24,9) not null check(cached_input_price_per_million_tokens>=0),
 output_price_per_million_tokens numeric(24,9) not null check(output_price_per_million_tokens>=0),pricing_source text not null,
 created_at timestamptz not null default now(),primary key(company_id,model_identifier,pricing_version)
);
create table public.ai_usage_logs (
 request_id uuid primary key,company_id uuid not null references public.ai_settings(company_id),user_id uuid not null references auth.users(id),
 employee_id uuid references public.employees(id),department_id uuid references public.departments(id),module text not null,feature text not null,model text not null,
 input_tokens bigint check(input_tokens>=0),output_tokens bigint check(output_tokens>=0),cached_input_tokens bigint check(cached_input_tokens>=0),total_tokens bigint check(total_tokens>=0),
 estimated_cost_usd numeric(24,9) not null check(estimated_cost_usd>=0), calculated_cost_usd numeric(24,9) check(calculated_cost_usd>=0),
 pricing_version text not null,pricing_snapshot jsonb not null,status text not null check(status in('pending','success','failed','unknown')),
 error_category text,duration_ms integer,created_at timestamptz not null default now(),completed_at timestamptz,
 check(cached_input_tokens is null or cached_input_tokens<=input_tokens)
);
create table public.ai_budget_reservations (
 request_id uuid primary key references public.ai_usage_logs(request_id),company_id uuid not null references public.ai_settings(company_id),user_id uuid not null references auth.users(id),
 reserved_cost_usd numeric(24,9) not null check(reserved_cost_usd>=0),settled_cost_usd numeric(24,9) check(settled_cost_usd>=0),
 status text not null check(status in('pending','settled','released','unknown')),created_at timestamptz not null default now(),expires_at timestamptz not null,finalized_at timestamptz
);
create table public.ai_audit_events (
 id uuid primary key default gen_random_uuid(),company_id uuid not null references public.ai_settings(company_id),user_id uuid references auth.users(id),
 event_type text not null,details jsonb not null default '{}',created_at timestamptz not null default now()
);
create index ai_usage_company_time on public.ai_usage_logs(company_id,created_at desc);
create index ai_usage_user_time on public.ai_usage_logs(company_id,user_id,created_at desc);
create index ai_reservations_accounting on public.ai_budget_reservations(company_id,created_at,status);
create index ai_pricing_latest on public.ai_model_pricing(company_id,model_identifier,effective_date desc);
create index ai_audit_time on public.ai_audit_events(company_id,created_at desc);

create function public.ai_current_company() returns uuid language sql stable security definer set search_path='' as $$
 select '00000000-0000-0000-0000-000000000001'::uuid where exists(
 select 1 from public.erp_profiles p join public.erp_roles r on r.id=p.role_id where p.auth_user_id=auth.uid() and p.is_active and r.is_active and public.has_active_erp_access())
$$;
revoke all on function public.ai_current_company() from public,anon;
grant execute on function public.ai_current_company() to authenticated,service_role;
alter table public.ai_settings enable row level security;
alter table public.ai_feature_config enable row level security;
alter table public.ai_model_pricing enable row level security;
alter table public.ai_usage_logs enable row level security;
alter table public.ai_budget_reservations enable row level security;
alter table public.ai_audit_events enable row level security;
-- Settings and accounting details are not visible to ordinary AI users.
create policy ai_settings_read on public.ai_settings for select to authenticated using(company_id=public.ai_current_company() and public.is_erp_admin());
create policy ai_features_read on public.ai_feature_config for select to authenticated using(company_id=public.ai_current_company() and public.is_erp_admin());
create policy ai_pricing_read on public.ai_model_pricing for select to authenticated using(company_id=public.ai_current_company() and public.is_erp_admin());
create policy ai_usage_read on public.ai_usage_logs for select to authenticated using(company_id=public.ai_current_company() and public.has_erp_permission('configuration.ai_usage','VIEW'));
create policy ai_audit_read on public.ai_audit_events for select to authenticated using(company_id=public.ai_current_company() and public.is_erp_admin());
revoke all on public.ai_settings,public.ai_feature_config,public.ai_model_pricing,public.ai_usage_logs,public.ai_budget_reservations,public.ai_audit_events from anon,authenticated;
grant select on public.ai_settings,public.ai_feature_config,public.ai_model_pricing,public.ai_usage_logs,public.ai_audit_events to authenticated;
grant all on public.ai_settings,public.ai_feature_config,public.ai_model_pricing,public.ai_usage_logs,public.ai_budget_reservations,public.ai_audit_events to service_role;

-- Atomic reservation; private server-only RPC. Actor always comes from verified Supabase getUser().
-- Set the transaction-local JWT sub so the EXISTING permission functions remain authoritative.
create function public.ai_reserve(p_request uuid,p_actor uuid,p_feature text,p_input_tokens integer,p_task text default 'general',p_fingerprint text default '') returns jsonb
language plpgsql security definer set search_path='' as $$
declare s public.ai_settings%rowtype;f public.ai_feature_config%rowtype;p public.ai_model_pricing%rowtype;
 org uuid;model_id text;amount numeric(24,9);daily numeric;monthly numeric;personal numeric;requests integer;active_count integer;
 emp uuid;dep uuid;out_tokens integer;day_start timestamptz;month_start timestamptz;
begin
 perform set_config('request.jwt.claim.sub',p_actor::text,true);
 org:=public.ai_current_company();if org is null then raise exception 'AI_FORBIDDEN';end if;
 select * into s from public.ai_settings where company_id=org for update;
 -- All requests/configuration changes serialize on this short-lived row lock.
 update public.ai_budget_reservations set status='unknown',settled_cost_usd=reserved_cost_usd,finalized_at=now() where company_id=org and status='pending' and expires_at<now();
 update public.ai_usage_logs u set status='unknown',error_category='abandoned',completed_at=now() where u.company_id=org and u.status='pending' and exists(select 1 from public.ai_budget_reservations r where r.request_id=u.request_id and r.status='unknown');
 if exists(select 1 from public.ai_usage_logs where request_id=p_request)then raise exception 'AI_DUPLICATE';end if;
 select * into f from public.ai_feature_config where company_id=org and feature_code=p_feature;
 if not found or p_feature not in('connection_test','general','inventory_matching')then raise exception 'AI_FEATURE_UNAVAILABLE';end if;
 if not public.has_erp_permission(f.required_permission,'VIEW') or (p_feature='connection_test' and not public.is_erp_admin()) or
 (p_feature<>'connection_test' and not public.has_erp_permission('ai.use','VIEW')) or
 (p_feature='inventory_matching' and not public.has_erp_permission('inventory.items','VIEW')) or p_actor=any(s.restricted_users)then raise exception 'AI_FORBIDDEN';end if;
 if not f.enabled or (not s.enabled and p_feature<>'connection_test') then raise exception 'AI_DISABLED';end if;
 if p_task not in('general','inventory_matching','document_extraction','finance_analysis','sales_assistance','purchase_analysis','dispatch_assistance')then raise exception 'AI_INPUT_INVALID';end if;
 model_id:=case when p_feature='connection_test' then coalesce(nullif(s.model_configuration->>p_task,''),nullif(s.default_model,'')) else coalesce(nullif(f.model,''),nullif(s.model_configuration->>p_feature,''),nullif(s.default_model,'')) end;
 if model_id is null or model_id=any(s.disabled_models) then raise exception 'AI_MODEL_UNAVAILABLE';end if;
 if p_feature<>'connection_test' and (coalesce(s.tested_models->>model_id,'')<>p_fingerprint or p_fingerprint='') then raise exception 'AI_MODEL_UNTESTED';end if;
 select * into p from public.ai_model_pricing where company_id=org and model_identifier=model_id and effective_date<=now() order by effective_date desc,created_at desc limit 1;
 if not found then raise exception 'AI_PRICING_REQUIRED';end if;
 if p_input_tokens not between 1 and 80000 then raise exception 'AI_INPUT_INVALID';end if;
 out_tokens:=least(s.max_output_tokens,case when p_feature='connection_test' then 16 else 2048 end);
 amount:=ceil((p_input_tokens*greatest(p.input_price_per_million_tokens,p.cached_input_price_per_million_tokens)+out_tokens*p.output_price_per_million_tokens)*1000)/1000000000;
 day_start:=date_trunc('day',now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
 month_start:=date_trunc('month',now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
 select coalesce(sum(coalesce(settled_cost_usd,reserved_cost_usd))filter(where created_at>=day_start),0),coalesce(sum(coalesce(settled_cost_usd,reserved_cost_usd)),0),coalesce(sum(coalesce(settled_cost_usd,reserved_cost_usd))filter(where user_id=p_actor),0),count(*)filter(where status='pending') into daily,monthly,personal,active_count from public.ai_budget_reservations where company_id=org and (created_at>=month_start or status='pending');
 select count(*) into requests from public.ai_usage_logs where company_id=org and user_id=p_actor and created_at>=day_start;
 if amount>s.per_request_limit_usd then raise exception 'AI_REQUEST_BUDGET';end if;
 if daily+amount>s.daily_budget_usd or s.daily_budget_usd=0 then raise exception 'AI_DAILY_BUDGET';end if;
 if monthly+amount>s.monthly_budget_usd or s.monthly_budget_usd=0 then raise exception 'AI_MONTHLY_BUDGET';end if;
 if personal+amount>s.per_user_monthly_usd or s.per_user_monthly_usd=0 then raise exception 'AI_USER_BUDGET';end if;
 if requests>=s.per_user_daily_requests then raise exception 'AI_USER_RATE';end if;
 if active_count>=s.max_concurrent_requests then raise exception 'AI_CONCURRENCY';end if;
 select pr.employee_id,e.department_id into emp,dep from public.erp_profiles pr left join public.employees e on e.id=pr.employee_id where pr.auth_user_id=p_actor;
 insert into public.ai_usage_logs(request_id,company_id,user_id,employee_id,department_id,module,feature,model,estimated_cost_usd,pricing_version,pricing_snapshot,status)
 values(p_request,org,p_actor,emp,dep,f.module_code,p_feature,model_id,amount,p.pricing_version,to_jsonb(p),'pending');
 insert into public.ai_budget_reservations(request_id,company_id,user_id,reserved_cost_usd,status,expires_at)values(p_request,org,p_actor,amount,'pending',now()+interval '2 minutes');
 return jsonb_build_object('settings',to_jsonb(s),'model',model_id,'pricing',to_jsonb(p),'max_output_tokens',out_tokens,'estimated_cost_usd',amount);
end$$;
revoke all on function public.ai_reserve(uuid,uuid,text,integer,text,text) from public,anon,authenticated;
grant execute on function public.ai_reserve(uuid,uuid,text,integer,text,text) to service_role;

-- Finalization and usage logging commit together; unknown charges retain the maximum reservation.
create function public.ai_finalize(p_request uuid,p_status text,p_usage jsonb,p_error text,p_duration integer,p_fingerprint text default '') returns void
language plpgsql security definer set search_path='' as $$
declare r public.ai_budget_reservations%rowtype;u public.ai_usage_logs%rowtype;amount numeric(24,9);inp bigint;outp bigint;cached bigint;s public.ai_settings%rowtype;spent numeric;threshold integer;
begin
 select * into r from public.ai_budget_reservations where request_id=p_request;
 if not found then raise exception 'AI_REQUEST_MISSING';end if;
 select * into s from public.ai_settings where company_id=r.company_id for update;
 select * into r from public.ai_budget_reservations where request_id=p_request for update;
 if r.status not in('pending','unknown') then return;end if;
 select * into u from public.ai_usage_logs where request_id=p_request;
 if p_status not in('success','failed','unknown')then raise exception 'AI_STATUS_INVALID';end if;
 if p_usage is not null then
  inp:=(p_usage->>'input_tokens')::bigint;outp:=(p_usage->>'output_tokens')::bigint;cached:=coalesce((p_usage->>'cached_tokens')::bigint,0);
  if inp is null or outp is null or inp<0 or outp<0 or cached<0 or cached>inp then raise exception 'AI_USAGE_INVALID';end if;
  amount:=ceil(((inp-cached)*(u.pricing_snapshot->>'input_price_per_million_tokens')::numeric+cached*(u.pricing_snapshot->>'cached_input_price_per_million_tokens')::numeric+outp*(u.pricing_snapshot->>'output_price_per_million_tokens')::numeric)*1000)/1000000000;
 elsif p_status='failed' then amount:=0;
 else amount:=null;end if;
 update public.ai_usage_logs set status=case when amount is null then 'unknown' else p_status end,input_tokens=inp,output_tokens=outp,cached_input_tokens=cached,total_tokens=inp+outp,calculated_cost_usd=amount,error_category=p_error,duration_ms=greatest(p_duration,0),completed_at=now() where request_id=p_request;
 update public.ai_budget_reservations set status=case when amount is null then 'unknown' when amount=0 and p_status='failed' then 'released' else 'settled' end,settled_cost_usd=coalesce(amount,reserved_cost_usd),finalized_at=now() where request_id=p_request;
 -- Explicit test result only. Missing usage is conservative accounting, not a fake connection failure.
 if u.feature='connection_test' then
  update public.ai_settings set tested_models=case when p_status='success' then tested_models||jsonb_build_object(u.model,p_fingerprint) else tested_models - u.model end,last_test_at=now(),last_test_error=case when p_status='success' then null else coalesce(p_error,'unconfirmed')end,tested_model=case when p_status='success' then u.model else tested_model end,last_success_at=case when p_status='success' then now() else last_success_at end where company_id=r.company_id;
 end if;
 select coalesce(sum(coalesce(settled_cost_usd,reserved_cost_usd)),0) into spent from public.ai_budget_reservations where company_id=r.company_id and created_at>=date_trunc('month',now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata';
 foreach threshold in array s.alert_thresholds loop
  if s.monthly_budget_usd>0 and spent*100>=s.monthly_budget_usd*threshold and not exists(select 1 from public.ai_audit_events where company_id=r.company_id and event_type='budget_threshold' and details->>'threshold'=threshold::text and created_at>=date_trunc('month',now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata')then
   insert into public.ai_audit_events(company_id,user_id,event_type,details)values(r.company_id,r.user_id,'budget_threshold',jsonb_build_object('threshold',threshold,'spend_usd',spent));
  end if;
 end loop;
 if amount>r.reserved_cost_usd then
  update public.ai_settings set enabled=false where company_id=r.company_id;
  insert into public.ai_audit_events(company_id,user_id,event_type,details)values(r.company_id,r.user_id,'estimate_exceeded',jsonb_build_object('request_id',p_request));
 end if;
end$$;
revoke all on function public.ai_finalize(uuid,text,jsonb,text,integer,text) from public,anon,authenticated;
grant execute on function public.ai_finalize(uuid,text,jsonb,text,integer,text) to service_role;

-- Changes to settings/features/pricing are recorded without prompts or credentials.
create function public.ai_config_audit()returns trigger language plpgsql security definer set search_path='' as $$
begin
 insert into public.ai_audit_events(company_id,user_id,event_type,details)values(new.company_id,auth.uid(),TG_TABLE_NAME||'_'||lower(TG_OP),jsonb_build_object('before',case when TG_OP='UPDATE' then to_jsonb(old) else null end,'after',to_jsonb(new)));
 return new;
end$$;
create trigger ai_settings_audit after update on public.ai_settings for each row execute function public.ai_config_audit();
create trigger ai_features_audit after update on public.ai_feature_config for each row execute function public.ai_config_audit();
create trigger ai_pricing_audit after insert on public.ai_model_pricing for each row execute function public.ai_config_audit();
-- Pricing snapshots are immutable, including to the server. Add a new version to correct prices.
create function public.ai_pricing_immutable()returns trigger language plpgsql set search_path='' as $$begin raise exception 'AI_PRICING_IMMUTABLE';end$$;
create trigger ai_pricing_immutable before update or delete on public.ai_model_pricing for each row execute function public.ai_pricing_immutable();
-- Recover capacity after a worker dies, while retaining its full estimated charge.
create function public.ai_reconcile_expired(p_company uuid) returns void language plpgsql security definer set search_path='' as $$
begin
 perform 1 from public.ai_settings where company_id=p_company for update;
 update public.ai_budget_reservations set status='unknown',settled_cost_usd=reserved_cost_usd,finalized_at=now() where company_id=p_company and status='pending' and expires_at<now();
 update public.ai_usage_logs u set status='unknown',error_category='abandoned',completed_at=now() where u.company_id=p_company and u.status='pending' and exists(select 1 from public.ai_budget_reservations r where r.request_id=u.request_id and r.status='unknown');
end$$;
revoke all on function public.ai_reconcile_expired(uuid) from public,anon,authenticated;
grant execute on function public.ai_reconcile_expired(uuid) to service_role;

create function public.ai_usage_report(p_filters jsonb) returns jsonb language plpgsql stable security definer set search_path='' as $$
declare org uuid;result jsonb;start_at timestamptz;end_at timestamptz;
begin
 org:=public.ai_current_company();if org is null or not public.has_erp_permission('configuration.ai_usage','VIEW')then raise exception 'AI_FORBIDDEN';end if;
 start_at:=(p_filters->>'from')::date::timestamp at time zone 'Asia/Kolkata';end_at:=((p_filters->>'to')::date+1)::timestamp at time zone 'Asia/Kolkata';
 if end_at<=start_at or end_at-start_at>interval '367 days' then raise exception 'AI_DATE_RANGE';end if;
 with filtered as(
 select * from public.ai_usage_logs where company_id=org and created_at>=start_at and created_at<end_at
 and (nullif(p_filters->>'user','')is null or user_id=(p_filters->>'user')::uuid)
 and (nullif(p_filters->>'department','')is null or department_id=(p_filters->>'department')::uuid)
 and (nullif(p_filters->>'module','')is null or module=p_filters->>'module')
 and (nullif(p_filters->>'feature','')is null or feature=p_filters->>'feature')
 and (nullif(p_filters->>'model','')is null or model=p_filters->>'model')
 ), daily as(select to_char(created_at at time zone 'Asia/Kolkata','YYYY-MM-DD') as label,sum(coalesce(calculated_cost_usd,estimated_cost_usd)) as cost,sum(coalesce(input_tokens,0)+coalesce(output_tokens,0)) as tokens from filtered group by 1),
 monthly as(select to_char(created_at at time zone 'Asia/Kolkata','YYYY-MM') as label,sum(coalesce(calculated_cost_usd,estimated_cost_usd)) as cost from filtered group by 1),
 modules as(select module as label,count(*)as requests from filtered group by 1),models as(select model as label,count(*)as requests from filtered group by 1),
 employees as(select coalesce(employee_id::text,user_id::text) as label,count(*)as requests from filtered group by 1),features as(select feature as label,count(*)as requests from filtered group by 1)
 select jsonb_build_object(
 'totals',(select jsonb_build_object('requests',count(*),'success',count(*)filter(where status='success'),'failed',count(*)filter(where status='failed'),'unknown',count(*)filter(where status in('pending','unknown')),'input_tokens',sum(input_tokens),'output_tokens',sum(output_tokens),'cached_tokens',sum(cached_input_tokens),'average_ms',round(avg(duration_ms)),'cost',coalesce(sum(coalesce(calculated_cost_usd,estimated_cost_usd)),0))from filtered),
 'daily',coalesce((select jsonb_agg(to_jsonb(daily)order by label)from daily),'[]'),
 'monthly',coalesce((select jsonb_agg(to_jsonb(monthly)order by label)from monthly),'[]'),
 'modules',coalesce((select jsonb_agg(to_jsonb(modules)order by requests desc)from modules),'[]'),
 'models',coalesce((select jsonb_agg(to_jsonb(models)order by requests desc)from models),'[]'),
 'employees',coalesce((select jsonb_agg(to_jsonb(employees)order by requests desc)from employees),'[]'),
 'features',coalesce((select jsonb_agg(to_jsonb(features)order by requests desc)from features),'[]'),
 'recent',coalesce((select jsonb_agg(to_jsonb(recent))from(select * from filtered order by created_at desc,request_id limit 100)recent),'[]'),
 'budget',(select jsonb_build_object('enabled',enabled,'monthly_limit',monthly_budget_usd,'daily_limit',daily_budget_usd,'usd_to_inr',usd_to_inr,'exchange_rate_date',exchange_rate_date,'last_test_at',last_test_at,'last_test_error',last_test_error,'last_success_at',last_success_at)from public.ai_settings where company_id=org),
 'month_spend',(select coalesce(sum(coalesce(settled_cost_usd,reserved_cost_usd)),0)from public.ai_budget_reservations where company_id=org and created_at>=date_trunc('month',now()at time zone'Asia/Kolkata')at time zone'Asia/Kolkata'),
 'day_spend',(select coalesce(sum(coalesce(settled_cost_usd,reserved_cost_usd)),0)from public.ai_budget_reservations where company_id=org and created_at>=date_trunc('day',now()at time zone'Asia/Kolkata')at time zone'Asia/Kolkata')
 ) into result;
 return result;
end$$;
revoke all on function public.ai_usage_report(jsonb)from public,anon;
grant execute on function public.ai_usage_report(jsonb)to authenticated;

commit;
