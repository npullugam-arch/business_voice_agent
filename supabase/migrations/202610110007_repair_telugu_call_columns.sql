alter table public.call_logs add column if not exists customer_response_te text;
alter table public.call_logs add column if not exists customer_summary_te text;
notify pgrst, 'reload schema';
