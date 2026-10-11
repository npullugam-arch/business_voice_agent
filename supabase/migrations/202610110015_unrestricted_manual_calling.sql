-- Manual calls requested by the shop owner can be placed at any time.
-- Automatic campaigns retain their existing hours and consent rules.
-- Explicit Do Not Call and collected-order protections remain in force.
create or replace function public.grant_customer_call_consent(p_customer_id uuid)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  v_shop uuid:=public.current_shop_id();
  v_owner uuid:=public.current_profile_id();
  v_order uuid;
begin
  if v_shop is null or v_owner is null then raise exception 'unauthorized';end if;

  if not exists(
    select 1 from public.customers
    where id=p_customer_id and shop_id=v_shop and not do_not_call
  ) then
    raise exception 'customer_not_eligible';
  end if;

  select id into v_order
  from public.orders
  where customer_id=p_customer_id and shop_id=v_shop and status<>'collected'
  order by created_at desc limit 1;

  if v_order is null then
    insert into public.orders(shop_id,owner_id,customer_id,garment_type,status,ready_at,call_enabled,call_status)
    values(v_shop,v_owner,p_customer_id,'Clothes','ready',now(),true,'idle')
    returning id into v_order;
  else
    update public.orders
    set call_enabled=true,
        call_status=case when call_status='disabled' then 'idle' else call_status end
    where id=v_order;
  end if;

  return v_order;
end
$$;

create or replace function public.claim_call_job(p_order_id uuid)
returns table(job_id uuid,owner_id uuid,customer_id uuid,customer_name text,phone_e164 text,shop_name text,garment_type text)
language plpgsql
security definer
set search_path=public
as $$
declare
  v_shop uuid:=public.current_shop_id();
begin
  if v_shop is null then raise exception 'unauthorized';end if;
  return query with candidate as(
    select o.id,o.shop_id,o.owner_id,o.customer_id,c.name,c.phone_e164,s.shop_name,o.garment_type
    from public.orders o
    join public.customers c on c.id=o.customer_id and c.shop_id=o.shop_id
    join public.shops s on s.id=o.shop_id
    where o.id=p_order_id and o.shop_id=v_shop
      and o.status in('ready','pickup_confirmed')
      and o.collected_at is null
      and o.call_enabled
      and s.calls_enabled
      and s.manual_calling
      and not c.do_not_call
      and not exists(
        select 1 from public.call_jobs j
        where j.order_id=o.id and j.status in('claimed','submitted')
      )
    for update of o
  ),ins as(
    insert into public.call_jobs(shop_id,owner_id,order_id)
    select candidate.shop_id,candidate.owner_id,candidate.id from candidate
    returning id,call_jobs.owner_id,call_jobs.order_id
  )
  update public.orders o
  set call_status='queued',call_requested_at=now()
  from ins where o.id=ins.order_id
  returning ins.id,o.owner_id,o.customer_id,
    (select c.name from public.customers c where c.id=o.customer_id),
    (select c.phone_e164 from public.customers c where c.id=o.customer_id),
    (select s.shop_name from public.shops s where s.id=o.shop_id),o.garment_type;
end
$$;

grant execute on function public.grant_customer_call_consent(uuid) to authenticated;
grant execute on function public.claim_call_job(uuid) to authenticated;
notify pgrst,'reload schema';

