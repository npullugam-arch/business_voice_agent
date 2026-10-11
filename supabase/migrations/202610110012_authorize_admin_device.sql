-- Authorize the admin browser shown by the deployed TailorConnect site.
-- Other visitors remain blocked by RLS even if they know the website URL.
do $$
begin
  if not exists(
    select 1 from auth.users
    where id='fda6b491-a984-4d1b-9f64-f5c3d0c44f09'::uuid
  ) then
    raise exception 'The admin browser identity does not exist in this Supabase project';
  end if;

  insert into public.shop_members(shop_id,user_id,role,active)
  values(
    '00000000-0000-4000-8000-000000000001'::uuid,
    'fda6b491-a984-4d1b-9f64-f5c3d0c44f09'::uuid,
    'member',
    true
  )
  on conflict(shop_id,user_id)
  do update set active=true;
end
$$;

