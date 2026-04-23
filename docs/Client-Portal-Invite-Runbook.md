# Client Portal — Invite Runbook

How to give a customer read-only access to their own data on Lighthouse Pulse.

---

## Who gets portal access

Any **client** (not lead, not prospect) who has at least one live or completed job
with us. Typical use cases:

- Brand owners who want to check their BOMs, jobs, and liquid on hand.
- Importers / distributors who want to see their delivery dockets and quotes.
- Peer distilleries whose liquid we store.

**Before you invite**, confirm the client company exists in the Customers page
and has their business type, country, and primary contact set. If the row is
incomplete, the Profile tab in their portal will show blanks.

---

## Issuing the invite

1. Sign in to Pulse as staff.
2. Click the cog icon (top-right of the header) → **Invite User**.
3. In the Invite modal:
   - **Role** — pick **Client (Portal Access)**.
   - **Client** — pick the company from the dropdown.
   - **First / Last name** — fill in the person at the client you're inviting.
   - **Email** — their business email.
4. Click **Generate Invite Link**.
5. Copy the link (it has an `?invite=…` token appended) and paste it into an
   email to the client. Tell them:
   - Click the link.
   - Create a password (8+ characters).
   - They'll land on their portal immediately.
6. The invite token expires automatically after its TTL. If it expires before
   they use it, just generate a new one.

---

## What the client will see

Seven tabs, all read-only:

| Tab | Contents |
|---|---|
| Summary | 4 KPI tiles: Jobs Completed, Bottles Produced YTD, Litres on Hand, Value of Liquid Stored |
| Jobs | All their jobs with product, qty, stage, bottling date, notes |
| BOMs / Specs | Their product spec sheets with GI-verified flag and notes |
| Inventory | Dry goods deliveries + Liquid containers (with `CLIENT VESSEL` tag where applicable) |
| Quotes | Their pricing quotes: name, version, date, total (Ex VAT · Ex Excise · Ex Shipping), last-emailed stamp |
| Documents | Delivery dockets and other attached files |
| Profile | Company details we hold on them |

At the top of every tab is their **Lighthouse Drinks contact** (name, email,
phone) — resolved from `clients.owner_id`. If the client has no owner set, the
contact falls back to `hello@lighthousedrinks.com`. **Set the owner on every
client before issuing the invite.**

---

## What the client cannot do

- Edit anything (everything is read-only on the portal).
- See any other client's data (enforced at the database layer via RLS).
- See CRM/pipeline, deals, staff tasks, or internal notes.
- Send email, create quotes, or approve BOMs.

---

## Common issues

**"The client says their Documents tab is empty."**
They have no files attached yet. Upload delivery dockets on the Dry Goods page
as you receive them — they flow through to the portal automatically.

**"The client says their contact card shows hello@lighthousedrinks.com instead
of me."**
The `clients.owner_id` isn't set. Open the customer in Company 360 and set
yourself (or the right account owner) as the owner. Refresh the portal.

**"The client logs in but sees nothing."**
Usually means their `app_users.client_id` wasn't set at signup (old invite
format). Contact the Business Analyst to update the row and ask the client to
refresh.

**"They used to work, now they say `no data available`."**
RLS policies are probably mis-configured on a table. Do not guess — escalate to
the Business Analyst, who will check the lock-down SQL.

---

## Revoking access

To remove a client's portal access:

1. In Supabase Studio → Authentication → Users, find the user by email and
   disable / delete them.
2. Or, in Supabase → `app_users`, set their `role` to something other than
   `client` — they will be signed out at next session check.

---

## Escalation

- RLS / policy errors → Business Analyst.
- UI / portal bugs → raise a Pulse issue.
- Client UX feedback → capture in Customers → Company 360 → Notes, we'll fold
  it into V2.
