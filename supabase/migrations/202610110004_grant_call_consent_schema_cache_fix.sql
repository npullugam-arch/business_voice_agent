create or replace function public.grant_customer_call_consent(p_customer_id uuid)
returns uuid
language plpgsql
security definer
set search_path=public
as $$
declare
  v_owner uuid:=public.current_profile_id();
  v_order uuid;
begin
  if v_owner is null then
    raise exception 'unauthorized';
  end if;

  update public.customers
  set consent_recorded_at=case when consent_status='granted' then consent_recorded_at else now() end,
      consent_status='granted'
  where id=p_customer_id
    and owner_id=v_owner
    and not do_not_call;

  if not found then
    raise exception 'customer_not_eligible';
  end if;

  select id into v_order
  from public.orders
  where customer_id=p_customer_id
    and owner_id=v_owner
    and status<>'collected'
  order by created_at desc
  limit 1;

  if v_order is null then
    insert into public.orders(owner_id,customer_id,garment_type,status,ready_at,call_enabled,call_status)
    values(v_owner,p_customer_id,'Clothes','ready',now(),true,'idle')
    returning id into v_order;
  else
    update public.orders
    set call_enabled=true,
        call_status=case when call_status='disabled' then 'idle' else call_status end
    where id=v_order;
  end if;

  return v_order;
end;
$$;

revoke all on function public.grant_customer_call_consent(uuid) from public;
grant execute on function public.grant_customer_call_consent(uuid) to authenticated;

notify pgrst, 'reload schema';
