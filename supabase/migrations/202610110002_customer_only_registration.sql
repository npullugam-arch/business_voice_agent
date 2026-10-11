create or replace function public.upsert_customer(p_name text,p_phone_e164 text) returns uuid language plpgsql security definer set search_path=public as $$
declare v_owner uuid:=public.current_profile_id();v_id uuid;
begin if v_owner is null then raise exception 'unauthorized';end if;if length(trim(p_name)) not between 1 and 100 then raise exception 'invalid_name';end if;if p_phone_e164 !~ '^\+91[6-9][0-9]{9}$' then raise exception 'invalid_phone';end if;
insert into customers(owner_id,name,phone_e164) values(v_owner,trim(p_name),p_phone_e164)
on conflict(owner_id,phone_e164) do update set name=excluded.name returning id into v_id;return v_id;end$$;

revoke all on function public.upsert_customer(text,text) from public;
grant execute on function public.upsert_customer(text,text) to authenticated;
