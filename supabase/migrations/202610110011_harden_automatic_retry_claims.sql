create or replace function public.claim_automatic_call_jobs(p_limit integer default 3)
returns table(job_id uuid,campaign_id uuid,attempt_number smallint,owner_id uuid,order_id uuid,customer_id uuid,customer_name text,phone_e164 text,shop_name text,garment_type text)
language plpgsql security definer set search_path=public set row_security=off as $$
declare v_now_local timestamp:=(now() at time zone 'Asia/Kolkata');v_today date:=v_now_local::date;
begin
  update public.shops set automatic_calling_enabled=false,automatic_campaign_date=null,updated_at=now()
  where automatic_calling_enabled and automatic_campaign_date is not null
    and (automatic_campaign_date<v_today or (automatic_campaign_date=v_today and v_now_local::time>='21:00'));
  update public.auto_call_campaigns set status='completed',ended_at=coalesce(ended_at,now())
  where (campaign_date<v_today or (campaign_date=v_today and v_now_local::time>='21:00')) and status in('scheduled','running');
  if v_now_local::time<'11:00' or v_now_local::time>='21:00' then return;end if;

  insert into public.auto_call_campaigns(shop_id,campaign_date,status,started_at)
  select s.id,v_today,'running',now() from public.shops s
  where s.automatic_calling_enabled and (s.automatic_campaign_date is null or s.automatic_campaign_date=v_today)
  on conflict(shop_id,campaign_date) do update set status=case when auto_call_campaigns.status='scheduled' then 'running' else auto_call_campaigns.status end,
    started_at=coalesce(auto_call_campaigns.started_at,excluded.started_at);

  return query
  with eligible as(
    select o.id order_id,o.owner_id,o.customer_id,o.shop_id,c.name,c.phone_e164,s.shop_name,o.garment_type,
      campaign.id campaign_id,(select count(*) from public.call_logs l where l.campaign_id=campaign.id and l.order_id=o.id)::smallint+1 attempt_no
    from public.orders o join public.customers c on c.id=o.customer_id and c.shop_id=o.shop_id
    join public.shops s on s.id=o.shop_id
    join public.auto_call_campaigns campaign on campaign.shop_id=o.shop_id and campaign.campaign_date=v_today and campaign.status='running'
    where s.automatic_calling_enabled and (s.automatic_campaign_date is null or s.automatic_campaign_date=v_today)
      and s.calls_enabled and o.status in('ready','pickup_confirmed') and o.collected_at is null and o.call_enabled
      and c.consent_status='granted' and not c.do_not_call
      and not exists(select 1 from public.call_jobs j where j.order_id=o.id and j.status in('claimed','submitted'))
      and (select count(*) from public.call_logs l where l.campaign_id=campaign.id and l.order_id=o.id)<s.automatic_retry_limit
      and not exists(
        select 1 from public.call_logs answered where answered.order_id=o.id and answered.status='completed'
          and coalesce(answered.call_outcome,'tentative')<>'rejected'
          and (coalesce(answered.completed_at,answered.executed_at,answered.created_at) at time zone 'Asia/Kolkata')::date=v_today
      )
      and (
        not exists(select 1 from public.call_logs first_attempt where first_attempt.campaign_id=campaign.id and first_attempt.order_id=o.id)
        or (
          o.next_call_at is not null and o.next_call_at<=now()
          and exists(
            select 1 from public.call_logs retryable where retryable.id=(
              select latest.id from public.call_logs latest where latest.campaign_id=campaign.id and latest.order_id=o.id order by latest.created_at desc limit 1
            ) and (retryable.status in('no_answer','busy') or retryable.call_outcome='rejected')
          )
        )
      )
    order by o.next_call_at nulls first,o.updated_at desc
    for update of o skip locked limit greatest(1,least(p_limit,10))
  ),inserted as(
    insert into public.call_jobs(shop_id,owner_id,order_id,automatic,campaign_id,attempt_number)
    select e.shop_id,e.owner_id,e.order_id,true,e.campaign_id,e.attempt_no from eligible e
    returning id,call_jobs.campaign_id,call_jobs.attempt_number,call_jobs.owner_id,call_jobs.order_id
  ),updated as(
    update public.orders o set call_status='queued',call_requested_at=now(),next_call_at=null
    from inserted i where o.id=i.order_id returning o.*
  )
  select i.id,i.campaign_id,i.attempt_number,i.owner_id,o.id,o.customer_id,c.name,c.phone_e164,s.shop_name,o.garment_type
  from inserted i join updated o on o.id=i.order_id join public.customers c on c.id=o.customer_id join public.shops s on s.id=o.shop_id;
end$$;
revoke all on function public.claim_automatic_call_jobs(integer) from public,anon,authenticated;
grant execute on function public.claim_automatic_call_jobs(integer) to service_role;
notify pgrst,'reload schema';
