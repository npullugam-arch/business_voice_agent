create extension if not exists pg_cron;
create extension if not exists pg_net with schema extensions;

alter table public.shops add column if not exists automatic_calling_enabled boolean not null default false;
alter table public.shops add column if not exists automatic_campaign_date date;
alter table public.shops add column if not exists automatic_retry_limit smallint not null default 3 check(automatic_retry_limit between 1 and 3);
alter table public.shops add column if not exists automatic_batch_size smallint not null default 3 check(automatic_batch_size between 1 and 10);

create table if not exists public.auto_call_campaigns(
  id uuid primary key default gen_random_uuid(),
  shop_id uuid not null references public.shops(id) on delete cascade,
  campaign_date date not null,
  status text not null default 'scheduled' check(status in('scheduled','running','completed','cancelled')),
  started_at timestamptz,ended_at timestamptz,created_at timestamptz not null default now(),
  unique(shop_id,campaign_date)
);
alter table public.auto_call_campaigns enable row level security;
create policy auto_campaigns_member_read on public.auto_call_campaigns for select to authenticated
using(shop_id=public.current_shop_id());
grant select on public.auto_call_campaigns to authenticated;

alter table public.call_jobs add column if not exists automatic boolean not null default false;
alter table public.call_jobs add column if not exists campaign_id uuid references public.auto_call_campaigns(id) on delete set null;
alter table public.call_jobs add column if not exists attempt_number smallint;
alter table public.call_logs add column if not exists automatic boolean not null default false;
alter table public.call_logs add column if not exists campaign_id uuid references public.auto_call_campaigns(id) on delete set null;
alter table public.call_logs add column if not exists attempt_number smallint;
create index if not exists call_logs_campaign_order_idx on public.call_logs(campaign_id,order_id,created_at);

create or replace function public.configure_automatic_calling(p_enabled boolean,p_campaign_date date default null,p_retry_limit smallint default 3)
returns public.shops language plpgsql security definer set search_path=public as $$
declare v_shop uuid:=public.current_shop_id();v_result public.shops;
begin
  if v_shop is null then raise exception 'unauthorized';end if;
  if p_retry_limit not between 1 and 3 then raise exception 'invalid_retry_limit';end if;
  if p_enabled and p_campaign_date is not null and p_campaign_date<(now() at time zone 'Asia/Kolkata')::date then raise exception 'campaign_date_in_past';end if;
  update public.shops set automatic_calling_enabled=p_enabled,
    automatic_campaign_date=case when p_enabled then p_campaign_date else null end,
    automatic_retry_limit=p_retry_limit,updated_at=now()
  where id=v_shop returning * into v_result;
  if not p_enabled then
    update public.auto_call_campaigns set status='cancelled',ended_at=now()
    where shop_id=v_shop and status in('scheduled','running');
    update public.call_jobs set status='cancelled',completed_at=now()
    where shop_id=v_shop and automatic and status='claimed';
    update public.orders set next_call_at=null
    where shop_id=v_shop and status<>'collected';
  end if;
  return v_result;
end$$;
revoke all on function public.configure_automatic_calling(boolean,date,smallint) from public;
grant execute on function public.configure_automatic_calling(boolean,date,smallint) to authenticated;

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
      and (o.next_call_at is null or o.next_call_at<=now())
      and not exists(select 1 from public.call_jobs j where j.order_id=o.id and j.status in('claimed','submitted'))
      and (select count(*) from public.call_logs l where l.campaign_id=campaign.id and l.order_id=o.id)<s.automatic_retry_limit
      and not exists(select 1 from public.call_logs l where l.campaign_id=campaign.id and l.order_id=o.id and l.status='completed' and coalesce(l.call_outcome,'tentative') not in('rejected'))
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

create or replace function public.schedule_automatic_retry() returns trigger
language plpgsql security definer set search_path=public as $$
declare v_limit smallint;v_next_local timestamp;v_order_status public.order_status;
begin
  if not new.automatic or new.status not in('completed','no_answer','busy','failed') or old.status=new.status then return new;end if;
  select o.status,s.automatic_retry_limit into v_order_status,v_limit from public.orders o join public.shops s on s.id=o.shop_id where o.id=new.order_id;
  if v_order_status='collected' then return new;end if;
  if new.status in('no_answer','busy') or new.call_outcome='rejected' then
    v_next_local:=date_trunc('hour',now() at time zone 'Asia/Kolkata')+interval '1 hour';
    if coalesce(new.attempt_number,1)<v_limit and v_next_local::time<'21:00' then
      update public.orders set next_call_at=v_next_local at time zone 'Asia/Kolkata' where id=new.order_id and status<>'collected';
    else update public.orders set next_call_at=null where id=new.order_id;end if;
  else update public.orders set next_call_at=null where id=new.order_id;end if;
  return new;
end$$;
drop trigger if exists call_logs_automatic_retry on public.call_logs;
create trigger call_logs_automatic_retry after update of status,call_outcome on public.call_logs
for each row execute function public.schedule_automatic_retry();

create table if not exists public.internal_automation_secrets(
  name text primary key,secret text not null,created_at timestamptz not null default now()
);
alter table public.internal_automation_secrets enable row level security;
revoke all on public.internal_automation_secrets from public,anon,authenticated;
insert into public.internal_automation_secrets(name,secret) values('auto_call_cron',encode(extensions.gen_random_bytes(32),'hex'))
on conflict(name) do nothing;

select cron.unschedule(jobid) from cron.job where jobname='tailor-auto-call-dispatcher';
select cron.schedule('tailor-auto-call-dispatcher','* * * * *',$cron$
  select net.http_post(
    url:='https://rxvnkklwnqsnrkltdvhn.supabase.co/functions/v1/run-auto-calls',
    headers:=jsonb_build_object('Content-Type','application/json','X-Cron-Secret',(select secret from public.internal_automation_secrets where name='auto_call_cron')),
    body:='{}'::jsonb,timeout_milliseconds:=50000
  );
$cron$);

notify pgrst,'reload schema';
