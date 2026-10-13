-- Transactional admin-only customer deletion. The Edge Function is the only
-- caller; browser roles cannot execute this function directly.
create or replace function public.admin_delete_customer(p_customer_id uuid)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_shop constant uuid:='00000000-0000-4000-8000-000000000001'::uuid;
  v_order_ids uuid[];
begin
  if not exists(select 1 from public.customers where id=p_customer_id and shop_id=v_shop) then
    return false;
  end if;

  select coalesce(array_agg(id),'{}'::uuid[]) into v_order_ids
  from public.orders where customer_id=p_customer_id and shop_id=v_shop;

  delete from public.call_jobs where shop_id=v_shop and order_id=any(v_order_ids);
  delete from public.call_logs where shop_id=v_shop and customer_id=p_customer_id;
  delete from public.orders where shop_id=v_shop and customer_id=p_customer_id;
  delete from public.customers where shop_id=v_shop and id=p_customer_id;
  return true;
end
$$;

revoke all on function public.admin_delete_customer(uuid) from public,anon,authenticated;
grant execute on function public.admin_delete_customer(uuid) to service_role;
notify pgrst,'reload schema';

