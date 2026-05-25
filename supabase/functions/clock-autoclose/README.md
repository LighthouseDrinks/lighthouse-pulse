# clock-autoclose

Nightly job that closes forgotten staff clock-ins / breaks. See
[`supabase/migrations/clock_events_guard.sql`](../../migrations/clock_events_guard.sql)
for the matching `clock_events` schema, RLS, dedupe trigger, transition RPC,
and the pg_cron entry that calls this function.

## Deploy

```bash
supabase functions deploy clock-autoclose
```

## Required secrets

| Secret | How to set |
| --- | --- |
| `CLOCK_AUTOCLOSE_TOKEN` | Generate any long random string, then `supabase secrets set CLOCK_AUTOCLOSE_TOKEN=<value>` |
| `SUPABASE_URL` | auto-injected |
| `SUPABASE_SERVICE_ROLE_KEY` | auto-injected |

## Wire up the cron caller

The migration creates the `clock-autoclose-nightly` pg_cron entry, but it can
only call your function if the URL + token are stored as database settings.
Run these **once** in the production database (Supabase SQL editor):

```sql
ALTER DATABASE postgres
  SET app.clock_autoclose_url   = 'https://<project-ref>.functions.supabase.co/clock-autoclose';
ALTER DATABASE postgres
  SET app.clock_autoclose_token = '<same value as CLOCK_AUTOCLOSE_TOKEN secret>';
SELECT pg_reload_conf();
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
