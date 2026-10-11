create extension if not exists pgcrypto;

create type public.consent_status as enum ('unknown','granted','revoked');
create type public.order_status as enum ('not_ready','ready','pickup_confirmed','collected');
create type public.call_state as enum ('idle','queued','calling','connected','completed','no_answer','busy','failed','disabled');
create type public.job_state as enum ('claimed','submitted','completed','failed','cancelled');

create table public.profiles (
  id uuid primary key default gen_random_uuid(), user_id uuid not null unique references auth.users(id) on delete cascade,
  owner_name text not null check(length(owner_name) between 1 and 100), shop_name text not null check(length(shop_name) between 1 and 100),
  shop_phone text not null check(shop_phone ~ '^\+91[6-9][0-9]{9}$'), shop_address text check(length(shop_address)<=300),
  calls_enabled boolean not null default true, manual_calling boolean not null default true, limited_retry boolean not null default false,
  max_attempts smallint not null default 1 check(max_attempts between 1 and 3), business_hours_start time not null default '09:00', business_hours_end time not null default '19:00',
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create table public.customers (
  id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.profiles(id) on delete cascade,
  name text not null check(length(name) between 1 and 100), phone_e164 text not null check(phone_e164 ~ '^\+91[6-9][0-9]{9}$'),
  consent_status public.consent_status not null default 'unknown', consent_recorded_at timestamptz, do_not_call boolean not null default false,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(), unique(owner_id,phone_e164)
);
create table public.orders (
  id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.profiles(id) on delete cascade,
  customer_id uuid not null references public.customers(id) on delete restrict, garment_type text not null check(length(garment_type) between 1 and 60), description text check(length(description)<=500),
  status public.order_status not null default 'not_ready', ready_at timestamptz, expected_pickup_date date, expected_pickup_time time,
  expected_pickup_period text check(expected_pickup_period in ('morning','afternoon','evening','night') or expected_pickup_period is null),
  pickup_confirmation_status text check(pickup_confirmation_status in ('unconfirmed','tentative','confirmed','unresolved') or pickup_confirmation_status is null),
  call_enabled boolean not null default false, call_status public.call_state not null default 'idle', call_requested_at timestamptz, next_call_at timestamptz,
  collected_at timestamptz, created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  check((status='collected' and collected_at is not null and call_enabled=false) or status<>'collected'), check(status='not_ready' or ready_at is not null)
);
create table public.call_logs (
  id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.profiles(id) on delete cascade,
  order_id uuid not null references public.orders(id) on delete cascade, customer_id uuid not null references public.customers(id) on delete restrict,
  provider text not null default 'sarvam', provider_attempt_id text, provider_interaction_id text, status public.call_state not null,
  call_outcome text check(call_outcome in ('confirmed','tentative','no_answer','busy','rejected','wrong_number','callback_requested','already_collected_reported','do_not_call','failed') or call_outcome is null),
  started_at timestamptz, completed_at timestamptz, duration_seconds integer check(duration_seconds>=0), transcript jsonb,
  customer_response text, extracted_pickup_date date, extracted_pickup_time time, extracted_pickup_period text,
  follow_up_required boolean not null default false, callback_requested boolean not null default false, callback_date date, failure_reason text,
  raw_payload jsonb, created_at timestamptz not null default now(), unique(provider,provider_attempt_id)
);
create table public.call_jobs (
  id uuid primary key default gen_random_uuid(), owner_id uuid not null references public.profiles(id) on delete cascade,
  order_id uuid not null references public.orders(id) on delete cascade, status public.job_state not null default 'claimed', requested_at timestamptz not null default now(),
  claimed_at timestamptz not null default now(), provider_request_id text, attempts smallint not null default 1, error_message text, completed_at timestamptz
);
create unique index one_active_call_job_per_order on public.call_jobs(order_id) where status in ('claimed','submitted');
create index orders_owner_status_idx on public.orders(owner_id,status); create index orders_pickup_idx on public.orders(owner_id,expected_pickup_date);
create index customers_owner_name_idx on public.customers(owner_id,name); create index call_logs_owner_created_idx on public.call_logs(owner_id,created_at desc);

create function public.touch_updated_at() returns trigger language plpgsql set search_path=public as $$begin new.updated_at=now();return new;end$$;
create trigger profiles_touch before update on public.profiles for each row execute function public.touch_updated_at();
create trigger customers_touch before update on public.customers for each row execute function public.touch_updated_at();
create trigger orders_touch before update on public.orders for each row execute function public.touch_updated_at();

create function public.current_profile_id() returns uuid language sql stable security definer set search_path=public as $$select id from public.profiles where user_id=auth.uid()$$;
create function public.set_owner_id() returns trigger language plpgsql security definer set search_path=public as $$begin new.owner_id=public.current_profile_id();if new.owner_id is null then raise exception 'profile_required';end if;return new;end$$;
create trigger customers_owner before insert on public.customers for each row execute function public.set_owner_id();
create trigger orders_owner before insert on public.orders for each row execute function public.set_owner_id();

alter table public.profiles enable row level security; alter table public.customers enable row level security; alter table public.orders enable row level security; alter table public.call_logs enable row level security; alter table public.call_jobs enable row level security;
create policy profiles_owner on public.profiles for all using(user_id=auth.uid()) with check(user_id=auth.uid());
create policy customers_owner on public.customers for all using(owner_id=public.current_profile_id()) with check(owner_id=public.current_profile_id());
create policy orders_owner on public.orders for all using(owner_id=public.current_profile_id()) with check(owner_id=public.current_profile_id());
create policy call_logs_read on public.call_logs for select using(owner_id=public.current_profile_id());
create policy call_jobs_read on public.call_jobs for select using(owner_id=public.current_profile_id());

create function public.upsert_customer_for_order(p_name text,p_phone_e164 text,p_consent_status public.consent_status) returns uuid language plpgsql security definer set search_path=public as $$
declare v_owner uuid:=public.current_profile_id();v_id uuid;
begin if v_owner is null then raise exception 'unauthorized';end if;if p_phone_e164 !~ '^\+91[6-9][0-9]{9}$' then raise exception 'invalid_phone';end if;
insert into customers(owner_id,name,phone_e164,consent_status,consent_recorded_at) values(v_owner,trim(p_name),p_phone_e164,p_consent_status,case when p_consent_status='granted' then now() end)
on conflict(owner_id,phone_e164) do update set name=excluded.name,consent_status=case when customers.consent_status='revoked' then 'revoked' else excluded.consent_status end,
consent_recorded_at=case when customers.consent_status<>'revoked' and excluded.consent_status='granted' then now() else customers.consent_recorded_at end returning id into v_id;return v_id;end$$;

create function public.upsert_customer(p_name text,p_phone_e164 text) returns uuid language plpgsql security definer set search_path=public as $$
declare v_owner uuid:=public.current_profile_id();v_id uuid;
begin if v_owner is null then raise exception 'unauthorized';end if;if length(trim(p_name)) not between 1 and 100 then raise exception 'invalid_name';end if;if p_phone_e164 !~ '^\+91[6-9][0-9]{9}$' then raise exception 'invalid_phone';end if;
insert into customers(owner_id,name,phone_e164) values(v_owner,trim(p_name),p_phone_e164)
on conflict(owner_id,phone_e164) do update set name=excluded.name returning id into v_id;return v_id;end$$;
revoke all on function public.upsert_customer(text,text) from public;

create function public.dashboard_counts() returns jsonb language sql stable security definer set search_path=public as $$
select jsonb_build_object('total_orders',count(*),'pending_calls',count(*) filter(where status='ready' and call_enabled),'pickup_confirmed',count(*) filter(where status='pickup_confirmed'),'collected',count(*) filter(where status='collected')) from orders where owner_id=public.current_profile_id()$$;

create function public.mark_order_collected(p_order_id uuid) returns void language plpgsql security definer set search_path=public as $$
begin update orders set status='collected',collected_at=now(),call_enabled=false,call_status='disabled',next_call_at=null where id=p_order_id and owner_id=public.current_profile_id() and status<>'collected';if not found then raise exception 'order_not_found';end if;update call_jobs set status='cancelled',completed_at=now() where order_id=p_order_id and owner_id=public.current_profile_id() and status='claimed';end$$;

create function public.claim_call_job(p_order_id uuid) returns table(job_id uuid,owner_id uuid,customer_id uuid,customer_name text,phone_e164 text,shop_name text,garment_type text) language plpgsql security definer set search_path=public as $$
declare v_owner uuid:=public.current_profile_id();
begin if v_owner is null then raise exception 'unauthorized';end if;
return query with candidate as(select o.id,o.owner_id,o.customer_id,c.name,c.phone_e164,p.shop_name,o.garment_type from orders o join customers c on c.id=o.customer_id join profiles p on p.id=o.owner_id where o.id=p_order_id and o.owner_id=v_owner and o.status in('ready','pickup_confirmed') and o.collected_at is null and o.call_enabled and p.calls_enabled and p.manual_calling and c.consent_status='granted' and not c.do_not_call for update of o), ins as(insert into call_jobs(owner_id,order_id) select candidate.owner_id,candidate.id from candidate returning id,call_jobs.owner_id,call_jobs.order_id) update orders o set call_status='queued',call_requested_at=now() from ins where o.id=ins.order_id returning ins.id,o.owner_id,o.customer_id,(select name from customers where id=o.customer_id),(select phone_e164 from customers where id=o.customer_id),(select profiles.shop_name from profiles where profiles.id=o.owner_id),o.garment_type;
end$$;
revoke all on function public.claim_call_job(uuid) from public;grant execute on function public.claim_call_job(uuid) to authenticated;
grant execute on function public.current_profile_id(),public.upsert_customer(text,text),public.upsert_customer_for_order(text,text,public.consent_status),public.dashboard_counts(),public.mark_order_collected(uuid) to authenticated;
alter publication supabase_realtime add table public.orders,public.call_logs;
