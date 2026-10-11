-- Move every existing TailorConnect record into one private, shared Nandu Tailor shop.
-- Existing authenticated/anonymous browser identities that already have a profile
-- become shop members. New identities receive no data until explicitly added.

create table if not exists public.shops (
  id uuid primary key,
  shop_name text not null,
  owner_name text not null,
  shop_phone text not null,
  shop_address text not null,
  calls_enabled boolean not null default true,
  manual_calling boolean not null default true,
  business_hours_start time not null default '09:00',
  business_hours_end time not null default '19:00',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

insert into public.shops(id,shop_name,owner_name,shop_phone,shop_address,calls_enabled,manual_calling)
values('00000000-0000-4000-8000-000000000001','Nandu Tailor','Pulgam Prasad','+919866104204','Duddeda, Siddipet',true,true)
on conflict(id) do update set shop_name=excluded.shop_name,owner_name=excluded.owner_name,
  shop_phone=excluded.shop_phone,shop_address=excluded.shop_address;

create table if not exists public.shop_members (
  shop_id uuid not null references public.shops(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member' check(role in ('owner','member')),
  active boolean not null default true,
  created_at timestamptz not null default now(),
  primary key(shop_id,user_id)
);

insert into public.shop_members(shop_id,user_id,role)
select '00000000-0000-4000-8000-000000000001',p.user_id,
       case when row_number() over(order by p.created_at,p.id)=1 then 'owner' else 'member' end
from public.profiles p
on conflict(shop_id,user_id) do update set active=true;

update public.profiles set shop_name='Nandu Tailor',owner_name='Pulgam Prasad',
  shop_phone='+919866104204',shop_address='Duddeda, Siddipet';

alter table public.customers add column if not exists shop_id uuid references public.shops(id);
alter table public.orders add column if not exists shop_id uuid references public.shops(id);
alter table public.call_logs add column if not exists shop_id uuid references public.shops(id);
alter table public.call_jobs add column if not exists shop_id uuid references public.shops(id);

update public.customers set shop_id='00000000-0000-4000-8000-000000000001' where shop_id is null;
update public.orders set shop_id='00000000-0000-4000-8000-000000000001' where shop_id is null;
update public.call_logs set shop_id='00000000-0000-4000-8000-000000000001' where shop_id is null;
update public.call_jobs set shop_id='00000000-0000-4000-8000-000000000001' where shop_id is null;

-- Preserve the oldest customer per phone number and repoint all history/orders.
create temporary table customer_merge_map on commit drop as
select id as duplicate_id,
       (array_agg(id) over(partition by shop_id,phone_e164 order by created_at,id))[1] as canonical_id
from public.customers;

update public.call_logs l set customer_id=m.canonical_id
from customer_merge_map m where l.customer_id=m.duplicate_id and m.duplicate_id<>m.canonical_id;
update public.orders o set customer_id=m.canonical_id
from customer_merge_map m where o.customer_id=m.duplicate_id and m.duplicate_id<>m.canonical_id;
delete from public.customers c using customer_merge_map m
where c.id=m.duplicate_id and m.duplicate_id<>m.canonical_id;

alter table public.customers alter column shop_id set not null;
alter table public.orders alter column shop_id set not null;
alter table public.call_logs alter column shop_id set not null;
alter table public.call_jobs alter column shop_id set not null;
create unique index if not exists customers_shop_phone_uidx on public.customers(shop_id,phone_e164);
create index if not exists customers_shop_name_idx on public.customers(shop_id,name);
create index if not exists orders_shop_status_idx on public.orders(shop_id,status);
create index if not exists call_logs_shop_created_idx on public.call_logs(shop_id,created_at desc);
create index if not exists shop_members_user_idx on public.shop_members(user_id,shop_id) where active;

create or replace function public.current_shop_id() returns uuid
language sql stable security definer set search_path=public set row_security=off as $$
  select m.shop_id from public.shop_members m
  where m.user_id=auth.uid() and m.active order by m.created_at limit 1
$$;

create or replace function public.current_profile_id() returns uuid
language sql stable security definer set search_path=public set row_security=off as $$
  select coalesce(
    (select p.id from public.profiles p where p.user_id=auth.uid() limit 1),
    (select p.id from public.profiles p join public.shop_members m on m.user_id=p.user_id
     where m.shop_id=public.current_shop_id() and m.active order by p.created_at limit 1)
  )
$$;

create or replace function public.set_shop_id() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  new.shop_id=public.current_shop_id();
  if new.shop_id is null then raise exception 'unauthorized'; end if;
  return new;
end$$;

create or replace function public.set_related_shop_id() returns trigger
language plpgsql security definer set search_path=public as $$
begin
  select o.shop_id into new.shop_id from public.orders o where o.id=new.order_id;
  if new.shop_id is null then raise exception 'order_not_found'; end if;
  return new;
end$$;

drop trigger if exists customers_shop_scope on public.customers;
create trigger customers_shop_scope before insert on public.customers for each row execute function public.set_shop_id();
drop trigger if exists orders_shop_scope on public.orders;
create trigger orders_shop_scope before insert on public.orders for each row execute function public.set_shop_id();
drop trigger if exists call_logs_shop_scope on public.call_logs;
create trigger call_logs_shop_scope before insert on public.call_logs for each row execute function public.set_related_shop_id();
drop trigger if exists call_jobs_shop_scope on public.call_jobs;
create trigger call_jobs_shop_scope before insert on public.call_jobs for each row execute function public.set_related_shop_id();

alter table public.shops enable row level security;
alter table public.shop_members enable row level security;
drop policy if exists shops_member_read on public.shops;
create policy shops_member_read on public.shops for select to authenticated
using(id=public.current_shop_id());
drop policy if exists shop_members_self_read on public.shop_members;
create policy shop_members_self_read on public.shop_members for select to authenticated
using(user_id=auth.uid() and active);

drop policy if exists customers_owner on public.customers;
drop policy if exists orders_owner on public.orders;
drop policy if exists call_logs_read on public.call_logs;
drop policy if exists call_jobs_read on public.call_jobs;
create policy customers_shop_member on public.customers for all to authenticated
using(shop_id=public.current_shop_id()) with check(shop_id=public.current_shop_id());
create policy orders_shop_member on public.orders for all to authenticated
using(shop_id=public.current_shop_id()) with check(shop_id=public.current_shop_id());
create policy call_logs_shop_member_read on public.call_logs for select to authenticated
using(shop_id=public.current_shop_id());
create policy call_jobs_shop_member_read on public.call_jobs for select to authenticated
using(shop_id=public.current_shop_id());

create or replace function public.upsert_customer(p_name text,p_phone_e164 text) returns uuid
language plpgsql security definer set search_path=public as $$
declare v_shop uuid:=public.current_shop_id();v_owner uuid:=public.current_profile_id();v_id uuid;
begin
  if v_shop is null or v_owner is null then raise exception 'unauthorized';end if;
  if length(trim(p_name)) not between 1 and 100 then raise exception 'invalid_name';end if;
  if p_phone_e164 !~ '^\+91[6-9][0-9]{9}$' then raise exception 'invalid_phone';end if;
  insert into customers(shop_id,owner_id,name,phone_e164) values(v_shop,v_owner,trim(p_name),p_phone_e164)
  on conflict(shop_id,phone_e164) do update set name=excluded.name returning id into v_id;
  insert into orders(shop_id,owner_id,customer_id,garment_type,status,ready_at,call_enabled,call_status)
  select v_shop,v_owner,v_id,'Clothes','ready',now(),false,'idle'
  where not exists(select 1 from orders where customer_id=v_id and shop_id=v_shop and status<>'collected');
  return v_id;
end$$;

create or replace function public.grant_customer_call_consent(p_customer_id uuid) returns uuid
language plpgsql security definer set search_path=public as $$
declare v_shop uuid:=public.current_shop_id();v_owner uuid:=public.current_profile_id();v_order uuid;
begin
  if v_shop is null or v_owner is null then raise exception 'unauthorized';end if;
  update customers set consent_recorded_at=case when consent_status='granted' then consent_recorded_at else now() end,consent_status='granted'
  where id=p_customer_id and shop_id=v_shop and not do_not_call;
  if not found then raise exception 'customer_not_eligible';end if;
  select id into v_order from orders where customer_id=p_customer_id and shop_id=v_shop and status<>'collected' order by created_at desc limit 1;
  if v_order is null then
    insert into orders(shop_id,owner_id,customer_id,garment_type,status,ready_at,call_enabled,call_status)
    values(v_shop,v_owner,p_customer_id,'Clothes','ready',now(),true,'idle') returning id into v_order;
  else
    update orders set call_enabled=true,call_status=case when call_status='disabled' then 'idle' else call_status end where id=v_order;
  end if;
  return v_order;
end$$;

create or replace function public.dashboard_counts() returns jsonb
language sql stable security definer set search_path=public as $$
select jsonb_build_object(
  'total_customers',(select count(*) from customers where shop_id=public.current_shop_id()),
  'pending_calls',(select count(*) from orders where shop_id=public.current_shop_id() and status<>'collected' and call_enabled and call_status in('idle','queued','calling','connected')),
  'calls_completed',(select count(*) from call_logs where shop_id=public.current_shop_id() and status='completed' and provider='sarvam'),
  'pickup_confirmed',(select count(*) from orders where shop_id=public.current_shop_id() and status='pickup_confirmed')
)$$;

create or replace function public.mark_order_collected(p_order_id uuid) returns void
language plpgsql security definer set search_path=public as $$
declare v_shop uuid:=public.current_shop_id();
begin
  if v_shop is null then raise exception 'unauthorized';end if;
  update orders set status='collected',collected_at=now(),call_enabled=false,call_status='disabled',next_call_at=null
  where id=p_order_id and shop_id=v_shop and status<>'collected';
  if not found then raise exception 'order_not_found';end if;
  update call_jobs set status='cancelled',completed_at=now()
  where order_id=p_order_id and shop_id=v_shop and status in('claimed','submitted');
end$$;

create or replace function public.claim_call_job(p_order_id uuid)
returns table(job_id uuid,owner_id uuid,customer_id uuid,customer_name text,phone_e164 text,shop_name text,garment_type text)
language plpgsql security definer set search_path=public as $$
declare v_shop uuid:=public.current_shop_id();
begin
  if v_shop is null then raise exception 'unauthorized';end if;
  return query with candidate as(
    select o.id,o.shop_id,o.owner_id,o.customer_id,c.name,c.phone_e164,s.shop_name,o.garment_type
    from orders o join customers c on c.id=o.customer_id and c.shop_id=o.shop_id
    join shops s on s.id=o.shop_id
    where o.id=p_order_id and o.shop_id=v_shop and o.status in('ready','pickup_confirmed')
      and o.collected_at is null and o.call_enabled and s.calls_enabled and s.manual_calling
      and c.consent_status='granted' and not c.do_not_call
      and (now() at time zone 'Asia/Kolkata')::time between s.business_hours_start and s.business_hours_end
    for update of o
  ),ins as(
    insert into call_jobs(shop_id,owner_id,order_id)
    select candidate.shop_id,candidate.owner_id,candidate.id from candidate
    returning id,call_jobs.owner_id,call_jobs.order_id
  )
  update orders o set call_status='queued',call_requested_at=now() from ins where o.id=ins.order_id
  returning ins.id,o.owner_id,o.customer_id,
    (select c.name from customers c where c.id=o.customer_id),
    (select c.phone_e164 from customers c where c.id=o.customer_id),
    (select s.shop_name from shops s where s.id=o.shop_id),o.garment_type;
end$$;

grant select on public.shops,public.shop_members to authenticated;
grant execute on function public.current_shop_id() to authenticated;
grant execute on function public.upsert_customer(text,text),public.grant_customer_call_consent(uuid),
  public.dashboard_counts(),public.mark_order_collected(uuid),public.claim_call_job(uuid) to authenticated;

notify pgrst,'reload schema';
