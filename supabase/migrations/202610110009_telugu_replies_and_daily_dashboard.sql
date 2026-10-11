-- Backfill an existing, verbatim customer utterance. No date or time is generated.
with candidates as (
  select l.id,coalesce(
    nullif(l.customer_summary_te,''),
    nullif(l.customer_response_te,''),
    (select nullif(turn->>'text','')
     from jsonb_array_elements(coalesce(l.telugu_transcript,'[]'::jsonb)) with ordinality item(turn,n)
     where turn->>'role'='user' order by n desc limit 1),
    (select nullif(turn->>'indic_text','')
     from jsonb_array_elements(coalesce(l.provider_transcript,'[]'::jsonb)) with ordinality item(turn,n)
     where turn->>'role'='user' order by n desc limit 1)
  ) as reply
  from public.call_logs l
  where l.status='completed'
)
update public.call_logs l set customer_summary_te=c.reply,customer_response_te=c.reply
from candidates c
where l.id=c.id and c.reply is not null
  and (nullif(l.customer_summary_te,'') is null or nullif(l.customer_response_te,'') is null);

create or replace function public.dashboard_counts() returns jsonb
language sql stable security definer set search_path=public as $$
with context as(
  select public.current_shop_id() shop_id,(now() at time zone 'Asia/Kolkata')::date today
)
select jsonb_build_object(
  'calls_made_today',(select count(*) from call_logs l,context c where l.shop_id=c.shop_id and (coalesce(l.executed_at,l.started_at,l.created_at) at time zone 'Asia/Kolkata')::date=c.today),
  'calls_completed_today',(select count(*) from call_logs l,context c where l.shop_id=c.shop_id and l.status='completed' and (coalesce(l.completed_at,l.executed_at,l.created_at) at time zone 'Asia/Kolkata')::date=c.today),
  'pickup_confirmed',(select count(distinct l.order_id) from call_logs l,context c where l.shop_id=c.shop_id and l.call_outcome='confirmed' and (coalesce(l.completed_at,l.executed_at,l.created_at) at time zone 'Asia/Kolkata')::date=c.today),
  'orders_collected_today',(select count(*) from orders o,context c where o.shop_id=c.shop_id and o.collected_at is not null and (o.collected_at at time zone 'Asia/Kolkata')::date=c.today)
)$$;

grant execute on function public.dashboard_counts() to authenticated;
notify pgrst,'reload schema';
