alter table public.call_logs add column if not exists provider_transcript jsonb;
alter table public.call_logs add column if not exists telugu_transcript jsonb;
alter table public.call_logs add column if not exists transcript_kind text
  check (transcript_kind in ('original_telugu','provider_english_translated','provider_english','unavailable'));
alter table public.call_logs add column if not exists executed_at timestamptz;
alter table public.call_logs add column if not exists last_webhook_at timestamptz;
alter table public.call_logs add column if not exists recording_available boolean not null default false;
alter table public.call_logs add column if not exists recording_provider_ref text;
alter table public.call_logs add column if not exists recording_content_type text;

create or replace function public.apply_sarvam_call_result(p_attempt_id text,p_result jsonb)
returns boolean
language plpgsql
security definer
set search_path=public
as $$
declare
  v_log public.call_logs%rowtype;
  v_status public.call_state;
  v_outcome text;
  v_pickup_date date;
  v_pickup_time time;
  v_period text;
  v_vars jsonb:=coalesce(p_result->'agent_variables','{}'::jsonb);
begin
  if p_attempt_id is null or p_attempt_id='' then raise exception 'attempt_required'; end if;
  v_status:=(p_result->>'status')::public.call_state;
  if v_status not in ('completed','no_answer','busy','failed') then raise exception 'invalid_terminal_status'; end if;
  select * into v_log from public.call_logs where provider='sarvam' and provider_attempt_id=p_attempt_id for update;
  if not found then return false; end if;

  v_outcome=nullif(p_result->>'call_outcome','');
  v_pickup_date=nullif(p_result->>'pickup_date','')::date;
  v_pickup_time=nullif(p_result->>'pickup_time','')::time;
  v_period=nullif(p_result->>'pickup_period','');

  update public.call_logs set
    status=v_status,
    provider_interaction_id=coalesce(nullif(p_result->>'interaction_id',''),provider_interaction_id),
    call_outcome=coalesce(v_outcome,call_outcome),
    started_at=coalesce(nullif(p_result->>'started_at','')::timestamptz,started_at),
    completed_at=coalesce(nullif(p_result->>'completed_at','')::timestamptz,now()),
    executed_at=coalesce(nullif(p_result->>'executed_at','')::timestamptz,executed_at),
    duration_seconds=coalesce((p_result->>'duration_seconds')::integer,duration_seconds),
    transcript=coalesce(p_result->'provider_transcript',transcript),
    provider_transcript=coalesce(p_result->'provider_transcript',provider_transcript),
    telugu_transcript=coalesce(p_result->'telugu_transcript',telugu_transcript),
    transcript_kind=coalesce(nullif(p_result->>'transcript_kind',''),transcript_kind,'unavailable'),
    customer_response=coalesce(nullif(p_result->>'customer_response',''),customer_response),
    customer_response_te=coalesce(nullif(p_result->>'customer_response_te',''),customer_response_te),
    customer_summary_te=coalesce(nullif(p_result->>'customer_summary_te',''),customer_summary_te),
    extracted_pickup_date=coalesce(v_pickup_date,extracted_pickup_date),
    extracted_pickup_time=coalesce(v_pickup_time,extracted_pickup_time),
    extracted_pickup_period=coalesce(v_period,extracted_pickup_period),
    follow_up_required=coalesce((p_result->>'follow_up_required')::boolean,follow_up_required),
    callback_requested=coalesce((p_result->>'callback_requested')::boolean,callback_requested),
    callback_date=coalesce(nullif(p_result->>'callback_date','')::date,callback_date),
    failure_reason=coalesce(nullif(p_result->>'failure_reason',''),failure_reason),
    recording_available=recording_available or coalesce((p_result->>'recording_available')::boolean,false),
    recording_provider_ref=coalesce(nullif(p_result->>'recording_provider_ref',''),recording_provider_ref),
    recording_content_type=coalesce(nullif(p_result->>'recording_content_type',''),recording_content_type),
    raw_payload=coalesce(p_result->'raw_payload',raw_payload),
    last_webhook_at=now()
  where id=v_log.id;

  update public.call_jobs set
    status=case when v_status='failed' then 'failed'::public.job_state else 'completed'::public.job_state end,
    completed_at=now(),error_message=case when v_status='failed' then nullif(p_result->>'failure_reason','') else null end
  where provider_request_id=p_attempt_id and status<>'cancelled';

  if coalesce((p_result->>'do_not_call')::boolean,false) or v_outcome='do_not_call' then
    update public.customers set do_not_call=true,consent_status='revoked' where id=v_log.customer_id;
  end if;

  update public.orders set
    call_status=v_status,
    call_enabled=case when v_outcome='do_not_call' then false else call_enabled end,
    expected_pickup_date=coalesce(v_pickup_date,expected_pickup_date),
    expected_pickup_time=coalesce(v_pickup_time,expected_pickup_time),
    expected_pickup_period=coalesce(v_period,expected_pickup_period),
    status=case when v_outcome='confirmed' then 'pickup_confirmed'::public.order_status else status end,
    pickup_confirmation_status=case when v_outcome='confirmed' then 'confirmed' when v_outcome='tentative' then 'tentative' else pickup_confirmation_status end
  where id=v_log.order_id and status<>'collected';
  return true;
end;
$$;

revoke all on function public.apply_sarvam_call_result(text,jsonb) from public,anon,authenticated;
alter publication supabase_realtime add table public.call_jobs;
notify pgrst, 'reload schema';
