-- Third one-time test-data cleanup requested before production use.
do $$
declare
  v_shop constant uuid:='00000000-0000-4000-8000-000000000001'::uuid;
begin
  update public.shops
  set automatic_calling_enabled=false,
      automatic_campaign_date=null,
      updated_at=now()
  where id=v_shop;

  delete from public.call_jobs where shop_id=v_shop;
  delete from public.call_logs where shop_id=v_shop;
  delete from public.orders where shop_id=v_shop;
  delete from public.customers where shop_id=v_shop;
  delete from public.auto_call_campaigns where shop_id=v_shop;
end
$$;

