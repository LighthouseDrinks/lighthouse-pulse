-- ============================================================
-- Pulse on Pulse — Meetings Hub: seed data
--
-- KPI master list (by category, with hybrid-RAG metadata) and the
-- two standing agenda templates. Idempotent: re-running refreshes
-- definitions in place (ON CONFLICT ... DO UPDATE).
--
-- kpi_type: numeric (auto-RAG from rag_thresholds) | status | cadence
-- rag_thresholds: {"dir":"higher|lower","green":n,"amber":n}
--   higher: value>=green→green; value>=amber→amber; else red
--   lower:  value<=green→green; value<=amber→amber; else red
-- ============================================================

insert into public.kpis
  (name, category, measures, unit, target, rag_rule, kpi_type, rag_thresholds, cadence, owner_role, position, active)
values
  -- ── Finance ──────────────────────────────────────────────
  ('Management Accounts — P&L','Finance','Monthly P&L prepared, reviewed and distributed on time; variances explained','RAG','>=1/month=Green; 1-2wks late=Amber; >2wks late=Red','>=1/month=Green; 1-2wks late=Amber; >2wks late=Red','status',null,'Monthly','financial_controller',0,true),
  ('Stock Value','Finance','Live stock value maintained, accuracy verified vs physical counts','RAG / £','Updated this week = Green','Updated this week = Green','status',null,'Weekly','financial_controller',1,true),
  ('Cashflow Position & Forecast','Finance','Weekly cashflow forecast updated; forward visibility on inflows/outflows','RAG / £','Forecast current (<=7 days) = Green','Forecast current (<=7 days) = Green','status',null,'Weekly','financial_controller',2,true),
  ('Budgeting & Planning','Finance','Annual budget in place; monthly actuals tracked vs budget','RAG','Budget live & reviewed = Green','Budget live & reviewed = Green','status',null,'Monthly','financial_controller',3,true),
  ('Cashflow Forecast','Finance','Rolling cashflow forecast updated and reviewed','Cadence','Weekly','Weekly','cadence',null,'Weekly','financial_controller',4,true),
  ('Monthly P&L (Finance sheet)','Finance','Full P&L statement prepared, reviewed, distributed monthly','Cadence','Monthly','Monthly','cadence',null,'Monthly','financial_controller',5,true),
  ('Quarterly KPI Report','Finance','Consolidated quarterly KPI review — trends, variances, corrective actions','Cadence','Quarterly','Quarterly','cadence',null,'Quarterly','financial_controller',6,true),
  ('Cashflow Oversight & Planning','Finance','Proactive cash management; liabilities and receivables tracked','Cadence','Weekly','Weekly','cadence',null,'Weekly','financial_controller',7,true),
  ('Debtor Management','Finance','Aged debtor report monitored; overdue accounts actioned within terms','Cadence','Weekly','Weekly','cadence',null,'Weekly','financial_controller',8,true),
  ('Revenue Compliance','Finance','Revenue streams reconciled and compliant; VAT filed on time','Cadence','Monthly','Monthly','cadence',null,'Monthly','financial_controller',9,true),

  -- ── Sales ────────────────────────────────────────────────
  ('Sales Growth','Sales','Week-on-week and month-on-month sales growth vs target','% vs target','On/above target=Green; <=10% below=Amber; >10% below=Red','On/above target=Green; <=10% below=Amber; >10% below=Red','numeric','{"dir":"higher","green":0,"amber":-10}','Weekly','commercial_manager',10,true),
  ('New Leads','Sales','Minimum new qualified leads generated per week','count/week','3 leads / week','3 leads / week','numeric','{"dir":"higher","green":3,"amber":2}','Weekly','commercial_manager',11,true),
  ('Pipeline','Sales','Minimum 1 new lead advancing through pipeline per week','count/week','1 lead / week','1 lead / week','numeric','{"dir":"higher","green":1,"amber":1}','Weekly','commercial_manager',12,true),
  ('Conversions','Sales','Convert pipeline leads to closed deals — monthly new-business revenue','€ / month','€60,000 / month','€60,000 / month','numeric','{"dir":"higher","green":60000,"amber":54000}','Monthly','commercial_manager',13,true),
  ('Customer Relationship Management (Sales)','Sales','Proactive outreach to all active customers at least monthly','Cadence','Monthly contact','Monthly contact','cadence',null,'Monthly','commercial_manager',14,true),
  ('Digital Platform Presence','Sales','Consistent brand presence; minimum one post per week','posts/week','1 post / week','1 post / week','numeric','{"dir":"higher","green":1,"amber":1}','Weekly','commercial_manager',15,true),
  ('Bottled Spirits Gross Margin','Sales','Gross margin on bottled spirits sales per job','% GM','>=30% GM','>=30% GM','numeric','{"dir":"higher","green":30,"amber":27}','Per job','commercial_manager',16,true),
  ('Bulk Spirits Gross Margin','Sales','Gross margin on bulk spirits sales per transaction','% GM','>=20% GM','>=20% GM','numeric','{"dir":"higher","green":20,"amber":18}','Per transaction','commercial_manager',17,true),
  ('Marketing Activity','Sales','Consistent weekly marketing across digital platforms; calendar maintained','posts/wk/platform','>=1 / platform / week','>=1 / platform / week','numeric','{"dir":"higher","green":1,"amber":1}','Weekly','commercial_manager',18,true),

  -- ── Operations ───────────────────────────────────────────
  ('On-Time Project Delivery','Operations','Jobs delivered within agreed timelines; 6-week commitments honoured','RAG','All on time=Green; 1 late <=1wk=Amber; >1wk=Red','All on time=Green; 1 late <=1wk=Amber; >1wk=Red','status',null,'Ongoing','operations_director',19,true),
  ('Downtime %','Operations','Total downtime ÷ total production window','%','<=0.5%=Green; 0.5-2%=Amber; >2%=Red','<=0.5%=Green; 0.5-2%=Amber; >2%=Red','numeric','{"dir":"lower","green":0.5,"amber":2}','Weekly','production_manager',20,true),
  ('Bottles Produced vs Production Plan','Operations','Actual bottles produced ÷ planned bottles (weekly)','%','>=90%','>=90%','numeric','{"dir":"higher","green":90,"amber":81}','Weekly','production_manager',21,true),
  ('Changeover Time Performance','Operations','Actual changeover time vs standard 3.5 hours','hours','<=3.5 hrs','<=3.5 hrs','numeric','{"dir":"lower","green":3.5,"amber":3.85}','Per run','production_manager',22,true),
  ('Production Tracker Compliance %','Operations','Completed production trackers ÷ total runs','%','>=90%','>=90%','numeric','{"dir":"higher","green":90,"amber":81}','Weekly','production_manager',23,true),
  ('Production Scheduling Visibility','Operations','Rolling 2-week forward schedule maintained; aligned with Sales','weeks','2-week lookahead','2-week lookahead','numeric','{"dir":"higher","green":2,"amber":2}','Weekly','production_manager',24,true),
  ('Production Material Readiness','Operations','All dry goods and liquids staged in bay before production commences','%','>=95%','>=95%','numeric','{"dir":"higher","green":95,"amber":85.5}','Per run','warehouse_liquid',25,true),
  ('Goods-In Processing Time','Operations','Goods checked in and processed within 48 hrs of receipt','hours','<=48 hours','<=48 hours','numeric','{"dir":"lower","green":48,"amber":52.8}','Per receipt','warehouse_liquid',26,true),
  ('Flow & Space Management (Stock Accuracy)','Operations','Correct location, label/barcode, system location, value; audits','% accuracy','>=95% accuracy','>=95% accuracy','numeric','{"dir":"higher","green":95,"amber":85.5}','Weekly + monthly','warehouse_liquid',27,true),
  ('Liquid Preparation Job Tracker Compliance','Operations','All job packs and trackers completed before job commences','%','100% compliance','100% compliance','numeric','{"dir":"higher","green":100,"amber":90}','Per job','warehouse_liquid',28,true),
  ('Liquid Management','Operations','All Lighthouse liquid logged and stock value updated daily; FIFO','% accuracy','100% accuracy','100% accuracy','numeric','{"dir":"higher","green":100,"amber":90}','Daily','warehouse_liquid',29,true),

  -- ── Quality ──────────────────────────────────────────────
  ('Customer Complaints Rate','Quality','Customer complaints per period; root cause + corrective action logged','count','0=Green; 1-2=Amber; 3+=Red','0=Green; 1-2=Amber; 3+=Red','numeric','{"dir":"lower","green":0,"amber":2}','Weekly','quality_compliance',30,true),
  ('Quality/Compliance/H&S Audit Readiness','Quality','All quality, compliance, H&S documentation current and audit-ready','RAG','All docs current = Green','All docs current = Green','status',null,'Ongoing','quality_compliance',31,true),
  ('Health & Safety Audit Ready','Quality','H&S statement, training records, incident logs current','RAG','All H&S records current = Green','All H&S records current = Green','status',null,'Ongoing','quality_compliance',32,true),
  ('Production Error Rate','Quality','Production errors ÷ total units produced (per job)','%','1-5%','1-5%','status',null,'Per job','quality_compliance',33,true),
  ('Return & Complaint Rate','Quality','Customer returns or quality complaints ÷ units sold (per job)','%','<1%','<1%','numeric','{"dir":"lower","green":1,"amber":1.1}','Per job','quality_compliance',34,true),
  ('SOP Compliance & Update Timelines','Quality','NCs categorised; re-training actioned; SOPs reviewed on schedule','% compliance','100% compliance','100% compliance','numeric','{"dir":"higher","green":100,"amber":90}','Ongoing','quality_compliance',35,true),
  ('BRC Certification','Quality','BRC Food Safety certification maintained','status','Certified & Current','Certified & Current','status',null,'Annual audit','quality_compliance',36,true),
  ('ISO 9001','Quality','ISO 9001 certification maintained; no lapses','status','Maintained','Maintained','status',null,'Surveillance + renewal','quality_compliance',37,true),
  ('Training Completion Rate (Quality)','Quality','Staff completed required quality training ÷ total required','%','100%','100%','numeric','{"dir":"higher","green":100,"amber":90}','Ongoing','quality_compliance',38,true),
  ('Batch (Job) Completion','Quality','Batches with fully completed documentation ÷ total batches','%','100%','100%','numeric','{"dir":"higher","green":100,"amber":90}','Per batch','quality_compliance',39,true),
  ('Calibration & Maintenance','Quality','Completed maintenance tasks on time ÷ planned tasks','% on time','100% on time','100% on time','numeric','{"dir":"higher","green":100,"amber":90}','Per task','quality_compliance',40,true),
  ('Internal Checks & Audits','Quality','Schedule of internal audits documented and completed on time','schedule','Schedule live','Schedule live','status',null,'Ongoing','quality_compliance',41,true),

  -- ── E-Commerce ───────────────────────────────────────────
  ('Picking Errors','E-Commerce','Picking errors per month; root cause identified per error','count/month','0 errors / month','0 errors / month','numeric','{"dir":"lower","green":0,"amber":0}','Monthly','ecommerce_manager',42,true),
  ('Custom Orders Tracking','E-Commerce','Every custom order tracked from receipt through fulfilment','%','100% tracked','100% tracked','numeric','{"dir":"higher","green":100,"amber":90}','Per order','ecommerce_manager',43,true),
  ('Order Check Frequency','E-Commerce','Daily backorder check at 10AM and new order check at 2PM','Cadence','Daily (10AM & 2PM)','Daily (10AM & 2PM)','cadence',null,'Daily','ecommerce_manager',44,true),
  ('Stocktake (E-Commerce)','E-Commerce','Monthly full stocktake; one bay audited weekly on rolling basis','Cadence','Monthly (1 bay/wk)','Monthly (1 bay/wk)','cadence',null,'Monthly','ecommerce_manager',45,true),
  ('Supplies & Stock Value (E-Commerce)','E-Commerce','Rolling stock value (Mintsoft); supplies replenished before critical','£ / accuracy','Rolling accuracy','Rolling accuracy','status',null,'Rolling','ecommerce_manager',46,true),
  ('IM Sales Tracking','E-Commerce','Ideal Malt sales and traffic tracked weekly; dashboard reviewed','Cadence','Weekly tracking','Weekly tracking','cadence',null,'Weekly','ecommerce_manager',47,true),
  ('Returns & Damage','E-Commerce','All returns and damaged items logged per incident; trend monthly','count/trend','Log all returns','Log all returns','status',null,'Per incident','ecommerce_manager',48,true),
  ('Conversion Rate (E-Commerce)','E-Commerce','Website conversion rate tracked and optimised','%','>2.5%','>2.5%','numeric','{"dir":"higher","green":2.5,"amber":2.25}','Weekly','ecommerce_manager',49,true),
  ('Reamaze Response Time','E-Commerce','All customer communications responded to within 24 hrs (Reamaze)','hours','<24 hours','<24 hours','numeric','{"dir":"lower","green":24,"amber":26.4}','Per ticket','ecommerce_manager',50,true),
  ('Total Social Reach','E-Commerce','Monthly social media reach across all active channels','reach/month','Monthly volume','Monthly volume','cadence',null,'Monthly','ecommerce_manager',51,true),
  ('Email Database Growth','E-Commerce','Net new email subscribers per week; list health maintained','count/week','Weekly growth','Weekly growth','cadence',null,'Weekly','ecommerce_manager',52,true),
  ('IM Website Traffic','E-Commerce','Total monthly traffic to Ideal Malt website; trend reported','visitors/month','Monthly volume','Monthly volume','cadence',null,'Monthly','ecommerce_manager',53,true),

  -- ── People (Employee Engagement on hold) ─────────────────
  ('Employee Engagement Index','People','Engagement measured periodically; action plan in place (on hold)','On hold','N/A — On hold','N/A — On hold','status',null,'Periodic',null,54,false),
  ('Audit-Ready Training Status','People','Required staff training completed and recorded; matrix maintained','% complete','100%=Green; 1-2 gaps=Amber; 3+=Red','100%=Green; 1-2 gaps=Amber; 3+=Red','status',null,'Monthly','quality_compliance',55,true),
  ('Culture & Workforce Stability','People','Staff turnover and absenteeism tracked; stability monitored quarterly','turnover %','Turnover normal, initiatives active = Green','Turnover normal, initiatives active = Green','status',null,'Quarterly','managing_director',56,true),
  ('Performance Reviews & 1:1s (On-time Completion)','People','Scheduled 1:1s and reviews completed on time for all staff','RAG','All completed on time = Green','All completed on time = Green','status',null,'Ongoing','managing_director',57,true)
on conflict (name) do update set
  category       = excluded.category,
  measures       = excluded.measures,
  unit           = excluded.unit,
  target         = excluded.target,
  rag_rule       = excluded.rag_rule,
  kpi_type       = excluded.kpi_type,
  rag_thresholds = excluded.rag_thresholds,
  cadence        = excluded.cadence,
  owner_role     = excluded.owner_role,
  position       = excluded.position,
  active         = excluded.active,
  updated_at     = now();

-- ── Agenda templates ───────────────────────────────────────
-- 1) Standard 1:1 (7-step) — used by all weekly 1:1s.
with t as (
  insert into public.meeting_templates (name, description)
  values ('Standard 1:1 (7-step)', 'Weekly 1:1 standing agenda (Ops / Commercial / Quality / Finance 1:1s)')
  on conflict (name) do update set description = excluded.description
  returning id
)
insert into public.meeting_template_items (template_id, position, topic, owner_role, time_box_min)
select t.id, v.position, v.topic, v.owner_role, v.tb
from t, (values
  (0, 'Wins this week',                       null::text, 5),
  (1, 'Issues / blockers',                     null::text, 10),
  (2, 'What goes into next Management Meeting', null::text, 5),
  (3, 'Direct report''s topics',               null::text, 15),
  (4, 'Manager''s topics',                      null::text, 15),
  (5, 'Anything I can unblock',                 null::text, 5),
  (6, 'Actions and decisions',                  null::text, 5)
) as v(position, topic, owner_role, tb)
on conflict (template_id, position) do update set
  topic = excluded.topic, owner_role = excluded.owner_role, time_box_min = excluded.time_box_min;

-- 2) Management Meeting (Weekly Leadership) — 8-item agenda.
with t as (
  insert into public.meeting_templates (name, description)
  values ('Management Meeting (Weekly Leadership)', 'Monday weekly leadership KPI review — 8 standing items')
  on conflict (name) do update set description = excluded.description
  returning id
)
insert into public.meeting_template_items (template_id, position, topic, owner_role, time_box_min)
select t.id, v.position, v.topic, v.owner_role, v.tb
from t, (values
  (0, 'Safety incidents and near-misses',                 'operations_director',   1),
  (1, 'Quality & compliance — NCs, complaints, open items','quality_compliance',    3),
  (2, 'Production — output vs plan, OEE, key issues',       'operations_director',   10),
  (3, 'Commercial — pipeline, top deals, client health',   'commercial_manager',    10),
  (4, 'Finance — cash, debtors, variances',                'financial_controller',  5),
  (5, 'Supply chain — stock risk, supplier issues',        'operations_director',   5),
  (6, 'People — hiring, absences, issues',                 'managing_director',     3),
  (7, 'Strategic rocks — progress on each',                'managing_director',     15)
) as v(position, topic, owner_role, tb)
on conflict (template_id, position) do update set
  topic = excluded.topic, owner_role = excluded.owner_role, time_box_min = excluded.time_box_min;
