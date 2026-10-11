# TailorConnect AI

An English, mobile-first tailoring shop dashboard built with Vanilla HTML/CSS/JavaScript, Supabase, and Sarvam AI Voice Agents.

## Authentication behavior

There is no login page and users never enter an email or password. The browser silently creates a Supabase anonymous session. Access is then restricted by the `shop_members` table and Row Level Security.

In Supabase, open **Authentication → Providers → Anonymous Sign-Ins** and enable anonymous sign-ins. Do not disable RLS or make customer tables public.

Migration `202610110008_shared_nandu_shop.sql` adds every existing profile to the private Nandu Tailor shop. A new browser receives no customer data until its displayed device user ID is inserted into `shop_members` by a trusted administrator. This keeps the shared dashboard private even when somebody knows the website URL.

To authorize a new device, copy its user ID from the Access required screen and run this in the Supabase SQL Editor:

```sql
insert into public.shop_members(shop_id,user_id,role)
values('00000000-0000-4000-8000-000000000001','DEVICE_USER_ID','member')
on conflict(shop_id,user_id) do update set active=true;
```

## Supabase setup

1. Create a Supabase project.
2. Enable anonymous sign-ins.
3. Apply all SQL files in `supabase/migrations` in filename order, or use:

```bash
supabase link --project-ref YOUR_PROJECT_REF
supabase db push
```

4. Copy the structure from `js/config.example.js` into `js/config.js` and add the project URL and publishable/anon key. These are browser-safe values only.

If the app reports that `public.shops` is missing from the schema cache, the frontend is connected but the migrations have not been fully applied. Run the migrations, wait a few seconds for the API schema cache to refresh, and reload the app.

## Run locally

Serve the files over HTTP because the frontend uses JavaScript modules:

```bash
npm run serve
```

Open the displayed localhost URL. Authorized devices open the shared Nandu Tailor dashboard directly; unrecognized devices show an access-required screen and cannot read customer data.

Run checks with:

```bash
npm test
```

## Edge Functions and mock mode

### Automatic calling

Migration `202610110010_automatic_call_campaigns.sql` installs a private Supabase Cron dispatcher. It checks every minute, but the database permits dispatch only from 11:00 AM through 8:59 PM in `Asia/Kolkata`. Calls are claimed atomically in small batches, so overlapping Cron runs cannot call the same order twice. The default daily limit is three attempts; only no-answer, busy, or rejected automatic calls receive a next-hour retry.

Automatic calling is disabled by default. An authorized shop member can enable recurring daily calling or select one campaign date from Settings. A selected one-day campaign disables itself at 9:00 PM IST. Collected, opted-out, unconsented, not-ready, already-answered, and actively calling orders are excluded. Manual Call Now remains independent and available.

Deploy the scheduler function with:

```bash
supabase functions deploy run-auto-calls
```

The Cron request is authenticated with a random database-generated secret. Sarvam credentials remain Edge Function secrets and are never sent to the browser.

```bash
supabase secrets set CALL_MODE=mock
supabase functions deploy start-tailor-call
supabase functions deploy sarvam-call-webhook --no-verify-jwt
supabase functions deploy get-call-recording
```

Mock mode is clearly labelled in call history and never places a real phone call.

For live mode:

```bash
supabase secrets set CALL_MODE=live SARVAM_API_KEY=... SARVAM_ORG_ID=... SARVAM_WORKSPACE_ID=... SARVAM_APP_ID=... SARVAM_APP_VERSION=... SARVAM_CONNECTION_ID=... SARVAM_AGENT_PHONE_NUMBER=... SARVAM_WEBHOOK_URL=https://YOUR_PROJECT.supabase.co/functions/v1/sarvam-call-webhook SARVAM_WEBHOOK_SECRET=A_LONG_RANDOM_SECRET
supabase functions deploy start-tailor-call
supabase functions deploy sarvam-call-webhook --no-verify-jwt
```

Supabase supplies `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and `SUPABASE_SERVICE_ROLE_KEY` to deployed functions. Never place Sarvam credentials or the service-role key in browser code.

## Sarvam configuration

The adapter uses Sarvam's documented Instant Outbound endpoint and `X-API-Key` authentication. Configure the Telugu agent, preferably with a Telugu-capable female voice, using `supabase/agent-instructions-te.md`.

- [Create instant outbound call](https://docs.sarvam.ai/conversations/api/instant-outbound/create)
- [Instant outbound webhook payload](https://docs.sarvam.ai/conversations/api/instant-outbound/webhook-payload)
- [Voice Agents API authentication](https://docs.sarvam.ai/conversations/api/introduction)

Use a connected phone number and an active agent version. Review consent, DND, calling-hour, and data-retention requirements before production use. Real calling is not verified until an authorized test call succeeds with valid credentials.

The Sarvam agent must define these output variables: `call_outcome`, `pickup_date`, `pickup_time`, `pickup_time_period`, `customer_response`, `customer_summary_te`, `follow_up_required`, `callback_requested`, `callback_date`, and `do_not_call`. Sarvam's documented webhook transcript is English translated text, so the UI labels it accordingly. Only Telugu-script output variables are displayed as the customer's Telugu reply or summary.

## Deploy and test calling

1. Apply `202610110003_customer_calling_workflow.sql`. It preserves customers and historical calls, backfills one active calling record for customers who do not have one, and enables Realtime for customers.
   If Supabase reports that `grant_customer_call_consent` is missing from the schema cache, also run `202610110004_grant_call_consent_schema_cache_fix.sql`; it recreates the RPC permissions and explicitly reloads the PostgREST schema cache.
2. Configure the Sarvam agent using `supabase/agent-instructions-te.md`, publish an active version, and connect an outbound phone number.
3. Start safely with `CALL_MODE=mock`, set the other secrets, and deploy both functions using the commands above. A mock result is visibly marked and does not count as a real completed call.
4. Add a customer, tap **Call Now**, and confirm that the customer gave permission. Verify that the test-mode badge appears in Call History.
5. Change `CALL_MODE=live`, redeploy `start-tailor-call`, and make one authorized test call during the business hours configured in Settings (defaults to 09:00–19:00 Asia/Kolkata).
6. Confirm the initial result says the request was submitted, then wait for Sarvam's completion webhook. Verify the final status, Telugu response variable, translated transcript, duration, and pickup date in Call History.
7. Tap **Mark Collected** and verify Call Now becomes unavailable. Delayed webhooks cannot return a collected record to the calling list.

The webhook URL includes a high-entropy secret query token because the documented instant-outbound webhook payload does not define a signature header. Treat `SARVAM_WEBHOOK_SECRET` as a credential and rotate it if the callback URL is exposed.

Apply migration `202610110006_call_results_and_recordings.sql` before deploying the updated webhook. Call results are applied in one database transaction and duplicate terminal webhook deliveries are safe. The provider transcript is preserved exactly as received. When Sarvam supplies only its documented English translation, the webhook attempts an English-to-Telugu translation and labels it as translated rather than verbatim. Set `SARVAM_TRANSLATION_API_KEY` separately if the Voice Agents API key cannot access the Translate API.

Recording playback uses Sarvam's documented Analytics recording endpoint through the authenticated `get-call-recording` Edge Function. Audio is streamed to the authorized owner and is not exposed through a public URL. Recording availability depends on the Sarvam workspace, telephony configuration, retention settings, and applicable recording consent requirements.

If **Call Now** fails, inspect the `start-tailor-call` Edge Function logs in Supabase. The UI distinguishes invalid keys (401), insufficient credits (402), workspace access (403), incorrect IDs (404), invalid call configuration (422), and rate limits (429). The function log and `call_jobs.error_message` contain Sarvam's sanitized response detail. After changing any secret, redeploy `start-tailor-call` before testing again.
