-- Sample Request Flow — Phase 1 schema
-- Adds request, recipient, QC/dispatch, outcome and task-linkage fields to the
-- samples module. Idempotent: safe to re-run. Applied manually via the Supabase
-- dashboard (SQL migrations are tracked in git for review; see .gitignore note).

-- ── samples ─────────────────────────────────────────────────────────────────
alter table public.samples add column if not exists quantity integer;               -- number of bottles
alter table public.samples add column if not exists bottle_size text;                -- 50ml/100ml/.../1000ml/custom
alter table public.samples add column if not exists liquid_type text;                -- free text (Whiskey/Gin/Vodka/liqueur/...)
alter table public.samples add column if not exists mix_type text;                   -- 'straight' | 'blend'
alter table public.samples add column if not exists blend_override boolean not null default false;
alter table public.samples add column if not exists contact_email text;              -- recipient email (drives dispatch email)
alter table public.samples add column if not exists requested_by_id uuid;            -- app_users.id of raising employee

-- Fulfilment / QC / dispatch
alter table public.samples add column if not exists prepared_by text;
alter table public.samples add column if not exists checked_by text;
alter table public.samples add column if not exists dispatch_date date;
alter table public.samples add column if not exists courier_ref text;
alter table public.samples add column if not exists sample_label_id text;
alter table public.samples add column if not exists qc_liquid_confirmed boolean not null default false;
alter table public.samples add column if not exists qc_abv_checked boolean not null default false;
alter table public.samples add column if not exists qc_volume_correct boolean not null default false;
alter table public.samples add column if not exists qc_label_added boolean not null default false;
alter table public.samples add column if not exists client_notified_at timestamptz;
alter table public.samples add column if not exists client_notified_by text;

-- Post-dispatch outcome
alter table public.samples add column if not exists outcome text;                    -- 'approved' | 'rejected' | 'no_response'
alter table public.samples add column if not exists outcome_notes text;
alter table public.samples add column if not exists outcome_at timestamptz;

-- Reject / on-hold off-ramp
alter table public.samples add column if not exists hold_reason text;

-- Off-Pulse recipients (not a Pulse client)
alter table public.samples add column if not exists recipient_company text;
alter table public.samples add column if not exists recipient_name text;
alter table public.samples add column if not exists converted_client_id uuid;        -- set if later converted to a client

-- A sample may have NO client_id (off-Pulse recipient).
alter table public.samples alter column client_id drop not null;

-- ── sample_components ─────────────────────────────────────────────────────────
alter table public.sample_components add column if not exists percentage numeric;    -- blend % per component

-- ── job_tasks: link a task back to its sample + distinguish review vs prepare ──
alter table public.job_tasks add column if not exists sample_id text;
alter table public.job_tasks add column if not exists task_kind text;                -- 'review' | 'prepare'
create index if not exists idx_job_tasks_sample_id on public.job_tasks (sample_id);

-- ── One-off backfill of legacy statuses onto the new flow ─────────────────────
-- Run order matters: map 'awaiting_feedback' before touching 'approved'.
update public.samples set status = 'submitted'  where status = 'pending';
update public.samples set status = 'dispatched' where status = 'awaiting_feedback';
update public.samples set outcome = 'approved'   where status = 'approved' and outcome is null;
update public.samples set status = 'closed'      where status = 'approved';
-- 'rejected' already maps to itself in the new model.
