-- Allow shop users to reopen an order that was marked collected by mistake.
-- Historical calls remain untouched; only the active order state is restored.
create or replace function public.unmark_order_collected(p_order_id uuid)
returns void
language plpgsql
security definer
set search_path=public
as $$
declare
  v_shop uuid:=public.current_shop_id();
begin
  if v_shop is null then raise exception 'unauthorized';end if;

  update public.orders
  set status='ready',
      collected_at=null,
      call_enabled=false,
      call_status='idle',
      call_requested_at=null,
      next_call_at=null
  where id=p_order_id and shop_id=v_shop and status='collected';

  if not found then raise exception 'collected_order_not_found';end if;
end
$$;

revoke all on function public.unmark_order_collected(uuid) from public,anon;
grant execute on function public.unmark_order_collected(uuid) to authenticated;
notify pgrst,'reload schema';

