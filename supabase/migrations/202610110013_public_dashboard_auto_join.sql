-- The shop owner explicitly requested URL-only access from every device.
-- Each anonymous Supabase Auth browser session automatically becomes a member.
create or replace function public.ensure_nandu_shop_access()
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_user uuid:=auth.uid();
begin
  if v_user is null then
    raise exception 'authentication_required';
  end if;

  insert into public.shop_members(shop_id,user_id,role,active)
  values(
    '00000000-0000-4000-8000-000000000001'::uuid,
    v_user,
    'member',
    true
  )
  on conflict(shop_id,user_id)
  do update set active=true;

  return true;
end
$$;

revoke all on function public.ensure_nandu_shop_access() from public,anon;
grant execute on function public.ensure_nandu_shop_access() to authenticated;
notify pgrst,'reload schema';

