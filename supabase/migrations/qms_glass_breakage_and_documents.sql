-- QMS: glass breakage reports (5.02.09) + controlled documents (draft / publish / revise)
-- Reports are never deleted. Every insert/update is written to history.
-- Idempotent: safe to re-run. Applied via Supabase (MCP / dashboard).

-- ── Glass breakage reports ──────────────────────────────────────────────────
create table if not exists public.qms_glass_breakage (
  id uuid primary key default gen_random_uuid(),
  report_no text not null unique,
  form_code text not null default '5.02.09',
  form_revision text not null default '002',
  breakage_date date,
  breakage_time text,
  person_reporting text,
  time_of_stoppage text,
  products_affected text,
  lot_number text,
  shift text,
  quarantined_liquids text,
  quarantined_glass_bottles text,
  quarantined_finished_product text,
  quarantined_packaging text,
  rejected_liquids text,
  rejected_glass_bottles text,
  rejected_finished_product text,
  rejected_packaging text,
  action_1 boolean not null default false,
  action_2 boolean not null default false,
  action_3 boolean not null default false,
  action_4 boolean not null default false,
  action_5 boolean not null default false,
  action_6 boolean not null default false,
  action_7 boolean not null default false,
  action_8 boolean not null default false,
  action_9 boolean not null default false,
  action_10 boolean not null default false,
  action_11 boolean not null default false,
  comments text,
  operator_sign_name text,
  operator_sign_time text,
  operator_sign_date date,
  quality_sign_name text,
  quality_sign_date date,
  locked_at timestamptz,
  created_by_id uuid,
  created_by_name text,
  created_by_email text,
  updated_by_id uuid,
  updated_by_name text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);

create index if not exists qms_glass_breakage_created
  on public.qms_glass_breakage (created_at desc);

create sequence if not exists public.qms_glass_breakage_seq;

create table if not exists public.qms_glass_breakage_history (
  id uuid primary key default gen_random_uuid(),
  report_id uuid not null references public.qms_glass_breakage(id) on delete restrict,
  action text not null,
  actor_id uuid,
  actor_name text,
  actor_email text,
  snapshot jsonb,
  created_at timestamptz not null default now()
);

create index if not exists qms_glass_breakage_history_report
  on public.qms_glass_breakage_history (report_id, created_at desc);

-- ── Controlled documents ────────────────────────────────────────────────────
create table if not exists public.qms_documents (
  id uuid primary key default gen_random_uuid(),
  doc_code text not null unique,
  title text not null,
  category text not null default 'sops',
  created_at timestamptz not null default now()
);

create table if not exists public.qms_document_revisions (
  id uuid primary key default gen_random_uuid(),
  document_id uuid not null references public.qms_documents(id) on delete restrict,
  revision_number integer not null,
  status text not null default 'draft' check (status in ('draft','published','superseded')),
  title text,
  body text,
  author_name text,
  reviewed_by text,
  approved_by text,
  change_description text,
  date_of_issue date,
  created_by_id uuid,
  created_by_name text,
  created_by_email text,
  published_by_id uuid,
  published_by_name text,
  published_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique (document_id, revision_number)
);

create index if not exists qms_document_revisions_doc
  on public.qms_document_revisions (document_id, revision_number desc);

-- ── RLS: staff read/write, no deletes ───────────────────────────────────────
alter table public.qms_glass_breakage enable row level security;
alter table public.qms_glass_breakage_history enable row level security;
alter table public.qms_documents enable row level security;
alter table public.qms_document_revisions enable row level security;

do $$ begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='qms_glass_breakage' and policyname='staff_select_qms_glass_breakage') then
    create policy staff_select_qms_glass_breakage on public.qms_glass_breakage
      for select to authenticated using (public.is_staff());
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='qms_glass_breakage' and policyname='staff_insert_qms_glass_breakage') then
    create policy staff_insert_qms_glass_breakage on public.qms_glass_breakage
      for insert to authenticated with check (public.is_staff());
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='qms_glass_breakage' and policyname='staff_update_qms_glass_breakage') then
    create policy staff_update_qms_glass_breakage on public.qms_glass_breakage
      for update to authenticated using (public.is_staff()) with check (public.is_staff());
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='qms_glass_breakage_history' and policyname='staff_select_qms_glass_hist') then
    create policy staff_select_qms_glass_hist on public.qms_glass_breakage_history
      for select to authenticated using (public.is_staff());
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='qms_glass_breakage_history' and policyname='staff_insert_qms_glass_hist') then
    create policy staff_insert_qms_glass_hist on public.qms_glass_breakage_history
      for insert to authenticated with check (public.is_staff());
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='qms_documents' and policyname='staff_all_qms_documents') then
    create policy staff_all_qms_documents on public.qms_documents
      for all to authenticated using (public.is_staff()) with check (public.is_staff());
  end if;
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='qms_document_revisions' and policyname='staff_all_qms_doc_revisions') then
    create policy staff_all_qms_doc_revisions on public.qms_document_revisions
      for all to authenticated using (public.is_staff()) with check (public.is_staff());
  end if;
end $$;

grant select, insert, update on public.qms_glass_breakage to authenticated;
grant select, insert on public.qms_glass_breakage_history to authenticated;
grant select, insert, update on public.qms_documents to authenticated;
grant select, insert, update on public.qms_document_revisions to authenticated;
grant usage, select on sequence public.qms_glass_breakage_seq to authenticated;

-- ── Permissions ─────────────────────────────────────────────────────────────
update public.roles
set permissions = coalesce(permissions, '{}'::jsonb) || '{"qms_log":1}'::jsonb
where key in (
  'managing_director','operations_director','production_manager','quality_compliance',
  'warehouse_liquid','production_operator','client_coordinator'
);

update public.roles
set permissions = coalesce(permissions, '{}'::jsonb) || '{"qms_docs_edit":1}'::jsonb
where key in ('managing_director','operations_director','quality_compliance');

-- ── Seed Glass Breakage Procedure 5.05.06 v001 (published) ──────────────────
insert into public.qms_documents (doc_code, title, category)
values ('5.05.06', 'Glass Breakage Procedure', 'sops')
on conflict (doc_code) do update set title = excluded.title, category = excluded.category;

insert into public.qms_document_revisions (
  document_id, revision_number, status, title, body,
  author_name, reviewed_by, approved_by, change_description, date_of_issue,
  created_by_name, published_by_name, published_at
)
select
  d.id, 1, 'published', 'Glass Breakage Procedure',
  $qms$<h2>1.0 Purpose</h2>
<p>The purpose of this policy is to ensure the safety and quality of our products by effectively managing the risks associated with glass breakage in our bottling facility. This policy aligns with the principles of HACCP (Hazard Analysis and Critical Control Points), ensuring food safety throughout our production process.</p>
<h2>2.0 Scope</h2>
<p>This policy applies to all employees, contractors, and visitors within the Lighthouse Drinks bottling facility. It covers the prevention, detection, and management of glass breakage incidents, ensuring that all necessary actions are taken to protect our products and maintain a safe working environment.</p>
<h2>3.0 Definitions</h2>
<p><strong>HACCP (Hazard Analysis and Critical Control Points):</strong> A systematic preventive approach to food safety that identifies, evaluates, and controls hazards that could pose a risk to food safety during production processes.</p>
<p><strong>Glass Breakage Incident:</strong> Any occurrence where glass materials (e.g., bottles, containers, tools) break within the production or storage areas, potentially leading to contamination or safety hazards.</p>
<p><strong>Glass Control Measures:</strong> Procedures and practices implemented to prevent glass breakage and manage glass items within the facility to minimise contamination risks.</p>
<p><strong>Personal Protective Equipment (PPE):</strong> Safety gear worn by employees to protect themselves during work, particularly when dealing with hazardous materials or during cleanup activities. Examples include gloves, safety goggles, and protective clothing.</p>
<p><strong>Quarantine:</strong> The process of isolating products or materials that may have been contaminated by glass breakage to prevent them from entering the production or distribution process until they have been thoroughly inspected and cleared or disposed of.</p>
<p><strong>Corrective Action:</strong> Steps taken to eliminate the cause of a detected nonconformity or other undesirable situation to prevent recurrence. This could include changes to processes, additional training, or other measures to improve safety and quality.</p>
<p><strong>Audit:</strong> A systematic, independent, and documented process for obtaining evidence and evaluating it objectively to determine the extent to which criteria are fulfilled. In this context, audits are conducted to ensure compliance with the Glass Breakage Procedure and overall food safety standards.</p>
<h2>4.0 Responsibilities &amp; Authority</h2>
<h3>4.1 Managing Director</h3>
<ul>
<li>Ensure the Glass Breakage Procedure is effectively implemented across the organisation and aligns with overall business objectives.</li>
<li>Provide necessary resources, including funding, personnel, and equipment, to support the implementation and maintenance of the Glass Breakage Procedure.</li>
<li>Ensure that the company complies with all relevant food safety laws, regulations, and standards, including HACCP.</li>
<li>Oversee continuous improvement initiatives related to glass control and overall food safety, ensuring the company stays ahead of industry best practices.</li>
<li>Review significant glass breakage incidents and their impact on company operations, making decisions on major corrective actions when necessary.</li>
</ul>
<h3>4.2 Operations Director</h3>
<ul>
<li>Ensure the Glass Breakage Procedure is fully implemented in day-to-day operations, and that all staff members understand and comply with the procedures.</li>
<li>Oversee the development and execution of training programs related to glass breakage prevention, detection, and response.</li>
<li>Ensure that all glass breakage incidents are reported, investigated, and resolved in accordance with the policy, and that any necessary actions to prevent a recurrence are implemented.</li>
<li>Monitor the effectiveness of the Glass Breakage Procedure, analysing incident reports and audit results to identify trends and areas for improvement.</li>
<li>Lead the investigation of glass breakage incidents, including root cause analysis, and ensure proper documentation and reporting.</li>
<li>Develop and implement corrective and preventive actions based on the findings of glass breakage incidents and audits.</li>
<li>Ensure ongoing compliance with HACCP requirements related to glass control through regular monitoring and verification activities.</li>
</ul>
<h3>4.3 Production Staff</h3>
<ul>
<li>Perform daily visual inspections of their workstations to identify and report any potential glass hazards, including damaged or improperly stored glass items.</li>
<li>Immediately report any glass breakage or suspected contamination to the Operations Director.</li>
<li>Follow all glass control procedures as outlined in the Glass Breakage Procedure, including the proper handling and storage of glass items.</li>
<li>Assist in the containment and cleanup of glass breakage incidents when directed, ensuring adherence to safety protocols and using appropriate PPE.</li>
<li>Attend all required training sessions related to glass safety and adhere to best practices in the workplace.</li>
</ul>
<h3>4.4 Shift Supervisor</h3>
<ul>
<li>Take immediate action to halt production and isolate the affected area in the event of a glass breakage.</li>
<li>Coordinate the cleanup of glass breakage incidents, ensuring that all procedures are followed, and the area is safe before resuming operations.</li>
<li>Ensure that a detailed Glass Breakage Incident Report is completed and submitted to the Operations Director.</li>
<li>Provide guidance to production staff on proper glass handling and incident response, reinforcing the importance of compliance with the Glass Breakage Procedure.</li>
<li>Conduct pre-shift inspections of glass-controlled areas and verify that all glass control measures are in place.</li>
<li>Conduct an inspection of the affected work areas to ensure any glass breakage has been properly cleaned up and that the area is free of glass fragments prior to restarting production.</li>
</ul>
<h2>5.0 Policy</h2>
<h3>5.1 Prevention</h3>
<h4>5.1.1 Glass Control Measures</h4>
<p>Other than glass bottles for filling, and measuring devices, there should be no other glass items in the production area.</p>
<p>Permission to bring other glass containers, tools or equipment must be sought from and granted by the Operations Director.</p>
<p>All glass containers, tools, and equipment must be inspected before they are brought into the production area. Any damaged glass must be reported and removed immediately.</p>
<p>Regular checks will be conducted to ensure compliance with glass control measures.</p>
<h4>5.1.2 Employee Training</h4>
<p>All employees will receive training on glass control procedures, including how to prevent breakages, the correct handling of glass items, and the steps to take in the event of a breakage.</p>
<p>Refresher training sessions will be held annually or after any significant glass breakage incident.</p>
<h4>5.1.3 Designated Glass Areas</h4>
<p>Glass containers or materials are only allowed in designated areas, clearly marked and separated from production lines to minimise the risk of contamination.</p>
<p>Glass inspections will be conducted at the start and end of each shift in these designated areas.</p>
<h3>5.2 Detection and Reporting</h3>
<h4>5.2.1 Glass Breakage Detection</h4>
<p>If glass breakage occurs, production must be halted immediately, and the area should be cordoned off to prevent contamination.</p>
<p>The incident must be reported to the Shift Supervisor or Operations Director immediately.</p>
<h4>5.2.2 Incident Reporting</h4>
<p>A Glass Breakage Report must be completed, detailing the location, cause, and nature of the breakage, as well as the actions taken.</p>
<p>The report will be reviewed by the Operations Director to identify root causes and implement corrective actions.</p>
<h3>5.3 Response and Cleanup</h3>
<h4>5.3.1 Containment</h4>
<p>The affected area should be isolated, and access restricted to authorised personnel only.</p>
<p>Employees involved in the cleanup must wear appropriate personal protective equipment (PPE), including gloves and safety glasses.</p>
<h4>5.3.2 Cleanup Procedure</h4>
<p>All glass fragments, including any potentially affected products or materials, must be carefully collected and disposed of in designated glass waste containers.</p>
<p>The area should be thoroughly cleaned and inspected before production can resume. This inspection must be documented and approved by the Operations Director.</p>
<h4>5.3.3 Product Quarantine and Disposal</h4>
<p>Any product that may have been contaminated must be quarantined and thoroughly inspected.</p>
<p>If contamination is confirmed or suspected, the product must be destroyed following company waste disposal procedures and documented accordingly.</p>
<h3>5.4 Verification and Review</h3>
<h4>5.4.1 Post-Incident Review</h4>
<p>Following a glass breakage incident, a full review will be conducted to assess the effectiveness of the response and identify any necessary improvements to the process.</p>
<p>Findings from the review will be shared with relevant staff, and additional training or changes to procedures will be implemented as needed.</p>
<h4>5.4.2 Regular Audits</h4>
<p>Regular audits of glass control measures, employee adherence to procedures, and the effectiveness of cleanup protocols will be conducted.</p>
<p>The HACCP team will review and update this Glass Breakage Procedure annually or after any significant incidents to ensure continued alignment with HACCP.</p>
<h2>6.0 Ref</h2>
<p>5.02.09 Glass Breakage Report</p>$qms$,
  'Emlyn Ó Troighthigh', 'John O’Donovan', 'John O’Donovan', 'New document', '2024-09-20',
  'System seed', 'System seed', now()
from public.qms_documents d
where d.doc_code = '5.05.06'
  and not exists (
    select 1 from public.qms_document_revisions r
    where r.document_id = d.id and r.revision_number = 1
  );
