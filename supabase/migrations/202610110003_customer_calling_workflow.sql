alter table public.call_logs add column if not exists customer_response_te text;
alter table public.call_logs add column if not exists customer_summary_te text;

insert into public.orders(owner_id,customer_id,garment_type,status,ready_at,call_enabled,call_status)
select c.owner_id,c.id,'Clothes','ready',now(),false,'idle'
from public.customers c
where not exists(select 1 from public.orders o where o.customer_id=c.id and o.status<>'collected');

create or replace function public.upsert_customer(p_name text,p_phone_e164 text) returns uuid language plpgsql security definer set search_path=public as $$
declare v_owner uuid:=public.current_profile_id();v_id uuid;
begin
  if v_owner is null then raise exception 'unauthorized';end if;
  if length(trim(p_name)) not between 1 and 100 then raise exception 'invalid_name';end if;
  if p_phone_e164 !~ '^\+91[6-9][0-9]{9}$' then raise exception 'invalid_phone';end if;
  insert into customers(owner_id,name,phone_e164) values(v_owner,trim(p_name),p_phone_e164)
  on conflict(owner_id,phone_e164) do update set name=excluded.name returning id into v_id;
  insert into orders(owner_id,customer_id,garment_type,status,ready_at,call_enabled,call_status)
  select v_owner,v_id,'Clothes','ready',now(),false,'idle'
  where not exists(select 1 from orders where customer_id=v_id and status<>'collected');
  return v_id;
end$$;

create or replace function public.grant_customer_call_consent(p_customer_id uuid) returns uuid language plpgsql security definer set search_path=public as $$
declare v_owner uuid:=public.current_profile_id();v_order uuid;
begin
  if v_owner is null then raise exception 'unauthorized';end if;
  update customers set consent_recorded_at=case when consent_status='granted' then consent_recorded_at else now() end,consent_status='granted'
  where id=p_customer_id and owner_id=v_owner and not do_not_call;
  if not found then raise exception 'customer_not_eligible';end if;
  select id into v_order from orders where customer_id=p_customer_id and owner_id=v_owner and status<>'collected' order by created_at desc limit 1;
  if v_order is null then
    insert into orders(owner_id,customer_id,garment_type,status,ready_at,call_enabled,call_status)
    values(v_owner,p_customer_id,'Clothes','ready',now(),true,'idle') returning id into v_order;
  else
    update orders set call_enabled=true,call_status=case when call_status='disabled' then 'idle' else call_status end where id=v_order;
  end if;
  return v_order;
end$$;

create or replace function public.dashboard_counts() returns jsonb language sql stable security definer set search_path=public as $$
select jsonb_build_object(
  'total_customers',(select count(*) from customers where owner_id=public.current_profile_id()),
  'pending_calls',(select count(*) from orders where owner_id=public.current_profile_id() and status<>'collected' and call_enabled and call_status in('idle','queued','calling','connected')),
  'calls_completed',(select count(*) from call_logs where owner_id=public.current_profile_id() and status='completed' and provider='sarvam'),
  'pickup_confirmed',(select count(*) from orders where owner_id=public.current_profile_id() and status='pickup_confirmed')
)$$;

create or replace function public.mark_order_collected(p_order_id uuid) returns void language plpgsql security definer set search_path=public as $$
begin
  update orders set status='collected',collected_at=now(),call_enabled=false,call_status='disabled',next_call_at=null
  where id=p_order_id and owner_id=public.current_profile_id() and status<>'collected';
  if not found then raise exception 'order_not_found';end if;
  update call_jobs set status='cancelled',completed_at=now()
  where order_id=p_order_id and owner_id=public.current_profile_id() and status in('claimed','submitted');
end$$;

create or replace function public.claim_call_job(p_order_id uuid) returns table(job_id uuid,owner_id uuid,customer_id uuid,customer_name text,phone_e164 text,shop_name text,garment_type text) language plpgsql security definer set search_path=public as $$
declare v_owner uuid:=public.current_profile_id();
begin
  if v_owner is null then raise exception 'unauthorized';end if;
  return query with candidate as(
    select o.id,o.owner_id,o.customer_id,c.name,c.phone_e164,p.shop_name,o.garment_type
    from orders o join customers c on c.id=o.customer_id join profiles p on p.id=o.owner_id
    where o.id=p_order_id and o.owner_id=v_owner and o.status in('ready','pickup_confirmed')
      and o.collected_at is null and o.call_enabled and p.calls_enabled and p.manual_calling
      and c.consent_status='granted' and not c.do_not_call
      and (now() at time zone 'Asia/Kolkata')::time between p.business_hours_start and p.business_hours_end
    for update of o
  ), ins as(
    insert into call_jobs(owner_id,order_id) select candidate.owner_id,candidate.id from candidate
    returning id,call_jobs.owner_id,call_jobs.order_id
  )
  update orders o set call_status='queued',call_requested_at=now() from ins where o.id=ins.order_id
  returning ins.id,o.owner_id,o.customer_id,(select name from customers where id=o.customer_id),(select phone_e164 from customers where id=o.customer_id),(select profiles.shop_name from profiles where profiles.id=o.owner_id),o.garment_type;
end$$;

revoke all on function public.grant_customer_call_consent(uuid) from public;
grant execute on function public.grant_customer_call_consent(uuid) to authenticated;
grant execute on function public.upsert_customer(text,text),public.dashboard_counts(),public.mark_order_collected(uuid),public.claim_call_job(uuid) to authenticated;

do $$begin
  alter publication supabase_realtime add table public.customers;
exception when duplicate_object then null;
end$$;
