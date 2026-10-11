-- Authorize the Nandu Tailor owner's browser session on the deployed Vercel site.
-- This keeps RLS private: only this exact Supabase Auth identity gains access.
do $$
begin
  if exists (
    select 1 from auth.users
    where id = '210d46fa-c09f-41cf-bb14-13d335956346'::uuid
  ) then
    insert into public.shop_members(shop_id,user_id,role,active)
    values(
      '00000000-0000-4000-8000-000000000001'::uuid,
      '210d46fa-c09f-41cf-bb14-13d335956346'::uuid,
      'member',
      true
    )
    on conflict(shop_id,user_id)
    do update set role='member',active=true;
  else
    raise exception 'Vercel device user does not exist in this Supabase project';
  end if;
end
$$;

