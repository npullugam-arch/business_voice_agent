create or replace function public.claim_call_job(p_order_id uuid)
returns table(
  job_id uuid,
  owner_id uuid,
  customer_id uuid,
  customer_name text,
  phone_e164 text,
  shop_name text,
  garment_type text
)
language plpgsql
security definer
set search_path=public
as $$
declare
  v_owner uuid:=public.current_profile_id();
begin
  if v_owner is null then
    raise exception 'unauthorized';
  end if;

  return query
  with candidate as (
    select
      o.id,
      o.owner_id,
      o.customer_id,
      c.name,
      c.phone_e164,
      p.shop_name,
      o.garment_type
    from public.orders o
    join public.customers c on c.id=o.customer_id and c.owner_id=o.owner_id
    join public.profiles p on p.id=o.owner_id and p.id=v_owner
    where o.id=p_order_id
      and o.status in ('ready','pickup_confirmed')
      and o.collected_at is null
      and o.call_enabled
      and p.calls_enabled
      and p.manual_calling
      and c.consent_status='granted'
      and not c.do_not_call
      and (now() at time zone 'Asia/Kolkata')::time between p.business_hours_start and p.business_hours_end
    for update of o
  ), inserted_job as (
    insert into public.call_jobs(owner_id,order_id)
    select candidate.owner_id,candidate.id
    from candidate
    returning id,call_jobs.owner_id,call_jobs.order_id
  )
  update public.orders o
  set call_status='queued',call_requested_at=now()
  from inserted_job
  where o.id=inserted_job.order_id
  returning
    inserted_job.id,
    o.owner_id,
    o.customer_id,
    (select c.name from public.customers c where c.id=o.customer_id),
    (select c.phone_e164 from public.customers c where c.id=o.customer_id),
    (select p.shop_name from public.profiles p where p.id=o.owner_id),
    o.garment_type;
end;
$$;

revoke all on function public.claim_call_job(uuid) from public;
grant execute on function public.claim_call_job(uuid) to authenticated;

notify pgrst, 'reload schema';
