# clock-autoclose

Nightly job that closes forgotten staff clock-ins / breaks. See
[`supabase/migrations/clock_events_guard.sql`](../../migrations/clock_events_guard.sql)
for the matching `clock_events` schema, RLS, dedupe trigger, transition RPC,
and the pg_cron entry that calls this function.

## Deploy

```bash
# --no-verify-jwt because we call the function from pg_cron (no JWT
# context); the function does its own bearer-token check.
supabase functions deploy clock-autoclose --no-verify-jwt
```

## Required secrets

| Secret | How to set |
| --- | --- |
| `CLOCK_AUTOCLOSE_TOKEN` | Generate any long random string, then `supabase secrets set CLOCK_AUTOCLOSE_TOKEN=<value>` |
| `SUPABASE_URL` | auto-injected |
| `SUPABASE_SERVICE_ROLE_KEY` | auto-injected |

## Wire up the cron caller

The migration creates the `clock-autoclose-nightly` pg_cron entry, but it can
only call your function if the URL + the same token are stored in
`supabase_vault`. Run these **once** in the production database
(Supabase SQL editor or `supabase db query --linked`):

```sql
select vault.create_secret(
  'https://<project-ref>.functions.supabase.co/clock-autoclose',
  'clock_autoclose_url',
  'URL for clock-autoclose nightly EF'
);
select vault.create_secret(
  '<same value as CLOCK_AUTOCLOSE_TOKEN function secret>',
  'clock_autoclose_token',
  'Bearer token for clock-autoclose nightly EF'
);
```

The pg_cron entry reads `vault.decrypted_secrets` at run time, so the
bearer token never appears in `cron.job`. To rotate, set a new
`CLOCK_AUTOCLOSE_TOKEN` function secret and update the matching vault
secret in one step:

```sql
update vault.secrets
   set secret = '<new token>'
 where name  = 'clock_autoclose_token';
```

After this, the cron job at 02:00 UTC will POST to the function with the
bearer token and the function will close any open shifts > 12 h old.

## Manual run

```bash
curl -X POST https://<project-ref>.functions.supabase.co/clock-autoclose \
  -H "Authorization: Bearer $CLOCK_AUTOCLOSE_TOKEN"
```

Returns JSON: `{ ok, examined, closed_clock_outs, closed_break_ends, timestamp }`.

Idempotent — safe to invoke multiple times in a row.
