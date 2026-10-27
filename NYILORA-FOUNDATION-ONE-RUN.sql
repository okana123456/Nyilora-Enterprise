-- NYILORA ENTERPRISE: FOUNDATION ONLY. Do not deploy the app or payment/SMS Edge Functions yet.
-- Fresh project sedzaagjqfsoxglcwyed only. BIZ-NYILORA only.
-- Run as one paste in the Nyilora Supabase SQL Editor. One transaction rolls back on error.
begin;

-- 0001_nyilora_core.sql
-- New Nyilora Enterprise project only. No data is imported from another system.
-- Core lending records and the single editable branch. Run once in the fresh
-- project before the feature and security migrations that follow.

create extension if not exists pgcrypto;

create table if not exists public.nyilora_branches (
  id uuid primary key default gen_random_uuid(),
  business_id text not null unique check (business_id='BIZ-NYILORA'),
  code text not null, name text not null,
  address text, phone text, email text,
  is_head_office boolean not null default true,
  is_active boolean not null default true,
  created_by uuid, created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
insert into public.nyilora_branches(id,business_id,code,name,is_head_office,is_active)
values ('00000000-0000-4000-8000-000000000001','BIZ-NYILORA','HO','Head Office',true,true)
on conflict (business_id) do nothing;

create table if not exists public.loan_staff (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check (business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  auth_user_id uuid unique, name text not null, email text not null,
  phone text, role text not null, is_active boolean not null default true,
  last_login timestamptz, created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  unique(business_id,email)
);
create index if not exists loan_staff_branch_idx on public.loan_staff(branch_id);

create table if not exists public.loan_clients (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check (business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  loan_officer_id uuid references public.loan_staff(id), created_by uuid references public.loan_staff(id),
  full_name text not null, id_number text, phone text, email text,
  gender text, dob date, address text, occupation text, employer text,
  monthly_income numeric(16,2) not null default 0,
  next_of_kin_name text, next_of_kin_phone text, next_of_kin_relation text,
  guarantor_name text, guarantor_phone text, guarantor_id_number text,
  photo_path text, account_credit numeric(16,2) not null default 0,
  registration_fee numeric(16,2) not null default 0,
  notes text, status text not null default 'active',
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(business_id,id_number)
);
create index if not exists loan_clients_branch_officer_idx on public.loan_clients(branch_id,loan_officer_id);

create table if not exists public.loan_products (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check (business_id='BIZ-NYILORA'),
  name text not null, description text,
  min_amount numeric(16,2) not null default 0, max_amount numeric(16,2) not null default 0,
  interest_rate numeric(8,3) not null default 0, interest_type text default 'flat',
  interest_period text default 'weekly', min_term_weeks integer default 1,
  max_term_weeks integer default 52, processing_fee_pct numeric(8,3) default 0,
  late_penalty_pct numeric(8,3) default 0, grace_period_days integer default 0,
  requires_guarantor boolean not null default false, is_active boolean not null default true,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);

create table if not exists public.loan_applications (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check (business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  client_id uuid not null references public.loan_clients(id),
  loan_officer_id uuid references public.loan_staff(id),
  application_no text not null unique, applied_amount numeric(16,2) not null check(applied_amount>0),
  applied_term_weeks integer not null check(applied_term_weeks>0),
  purpose text, status text not null default 'submitted', loan_type text,
  application_date date default current_date, reviewed_at timestamptz,
  approved_at timestamptz, approved_by uuid references public.loan_staff(id),
  rejection_reason text, notes text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists loan_applications_branch_client_idx on public.loan_applications(branch_id,client_id);

create table if not exists public.loans (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check (business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  client_id uuid not null references public.loan_clients(id),
  application_id uuid references public.loan_applications(id),
  loan_officer_id uuid references public.loan_staff(id),
  loan_no text not null unique, principal_amount numeric(16,2) not null check(principal_amount>=0),
  disbursed_amount numeric(16,2) not null default 0,
  interest_rate numeric(8,3) default 0, interest_type text default 'flat',
  term_weeks integer not null default 1, processing_fee numeric(16,2) not null default 0,
  processing_fee_paid numeric(16,2) not null default 0,
  registration_fee_due numeric(16,2) not null default 0,
  registration_fee_paid numeric(16,2) not null default 0,
  total_interest numeric(16,2) not null default 0,
  total_payable numeric(16,2) not null default 0,
  weekly_installment numeric(16,2) not null default 0,
  total_paid numeric(16,2) not null default 0,
  outstanding_balance numeric(16,2) not null default 0,
  arrears_amount numeric(16,2) not null default 0,
  overdue_days integer not null default 0,
  disbursement_method text, disbursement_reference text,
  disbursement_date date, first_repayment_date date, maturity_date date,
  status text not null default 'active', loan_type text,
  rollover_applied boolean not null default false,
  penalty_applied boolean not null default false,
  notes text, created_at timestamptz not null default now(), updated_at timestamptz not null default now()
);
create index if not exists loans_branch_officer_idx on public.loans(branch_id,loan_officer_id);
create index if not exists loans_client_idx on public.loans(client_id);

create table if not exists public.loan_schedules (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check (business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  loan_id uuid not null references public.loans(id) on delete restrict,
  installment_no integer not null, due_date date not null,
  principal_due numeric(16,2) not null default 0, interest_due numeric(16,2) not null default 0,
  total_due numeric(16,2) not null default 0,
  principal_paid numeric(16,2) not null default 0, interest_paid numeric(16,2) not null default 0,
  total_paid numeric(16,2) not null default 0, penalty_charged numeric(16,2) not null default 0,
  status text not null default 'pending',
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(loan_id,installment_no)
);
create index if not exists loan_schedules_branch_due_idx on public.loan_schedules(branch_id,due_date);

create table if not exists public.loan_repayments (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check (business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  loan_id uuid not null references public.loans(id) on delete restrict,
  receipt_no text not null, amount numeric(16,2) not null check(amount>0),
  payment_method text not null, payment_reference text,
  payment_date timestamptz not null default now(),
  sender_name text, sender_phone text,
  principal_portion numeric(16,2) not null default 0,
  interest_portion numeric(16,2) not null default 0,
  penalty_portion numeric(16,2) not null default 0,
  registration_fee_portion numeric(16,2) not null default 0,
  processing_fee_portion numeric(16,2) not null default 0,
  loan_portion numeric(16,2) not null default 0,
  credit_portion numeric(16,2) not null default 0,
  mpesa_confirmed boolean not null default false,
  collected_by uuid references public.loan_staff(id), notes text,
  created_at timestamptz not null default now(), updated_at timestamptz not null default now(),
  unique(business_id,receipt_no)
);
create unique index if not exists loan_repayments_mpesa_reference_unique
  on public.loan_repayments(business_id,upper(payment_reference))
  where payment_method ilike '%mpesa%' and nullif(trim(payment_reference),'') is not null;
create index if not exists loan_repayments_branch_date_idx on public.loan_repayments(branch_id,payment_date desc);

create table if not exists public.loan_penalties (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check (business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  loan_id uuid not null references public.loans(id),
  penalty_amount numeric(16,2) not null default 0,
  date_charged date not null default current_date, reason text,
  is_waived boolean not null default false, waived_at timestamptz,
  created_at timestamptz not null default now()
);


-- 0002_nyilora_core_access.sql
-- Fresh Nyilora project only. Auth identity controls access to the one branch.

create or replace function public.nyilora_current_staff()
returns public.loan_staff
language sql stable security definer set search_path=public
as $$
  select s from public.loan_staff s
  where s.business_id='BIZ-NYILORA' and s.auth_user_id=auth.uid()
    and s.is_active
  limit 1
$$;

create or replace function public.nyilora_has_role(p_role text)
returns boolean
language sql stable security definer set search_path=public
as $$
  select p_role=any(regexp_split_to_array(lower(coalesce((public.nyilora_current_staff()).role,'')),'\s*,\s*'))
$$;

create or replace function public.nyilora_staff_id()
returns uuid
language sql stable security definer set search_path=public
as $$select (public.nyilora_current_staff()).id$$;

create or replace function public.nyilora_can_read_portfolio(p_branch uuid,p_officer uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select p_branch=(public.nyilora_current_staff()).branch_id and
  (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
   or public.nyilora_has_role('cashier')
   or p_officer=public.nyilora_staff_id())
$$;

revoke all on function public.nyilora_current_staff() from public,anon;
revoke all on function public.nyilora_has_role(text) from public,anon;
revoke all on function public.nyilora_staff_id() from public,anon;
revoke all on function public.nyilora_can_read_portfolio(uuid,uuid) from public,anon;
grant execute on function public.nyilora_current_staff(),public.nyilora_has_role(text),
  public.nyilora_staff_id(),public.nyilora_can_read_portfolio(uuid,uuid) to authenticated;

alter table public.nyilora_branches enable row level security;
alter table public.loan_staff enable row level security;
alter table public.loan_clients enable row level security;
alter table public.loan_products enable row level security;
alter table public.loan_applications enable row level security;
alter table public.loans enable row level security;
alter table public.loan_schedules enable row level security;
alter table public.loan_repayments enable row level security;
alter table public.loan_penalties enable row level security;

create policy nyilora_branch_read on public.nyilora_branches for select to authenticated
  using (business_id='BIZ-NYILORA' and (public.nyilora_current_staff()).id is not null);
create policy nyilora_branch_admin_edit on public.nyilora_branches for update to authenticated
  using (public.nyilora_has_role('admin'))
  with check (business_id='BIZ-NYILORA' and public.nyilora_has_role('admin'));

create policy nyilora_staff_read on public.loan_staff for select to authenticated
  using (business_id='BIZ-NYILORA' and
    (id=public.nyilora_staff_id() or public.nyilora_has_role('admin')
     or public.nyilora_has_role('branch_manager')));
create policy nyilora_staff_admin_update on public.loan_staff for update to authenticated
  using (public.nyilora_has_role('admin'))
  with check (business_id='BIZ-NYILORA' and public.nyilora_has_role('admin'));

create policy nyilora_client_read on public.loan_clients for select to authenticated
  using (business_id='BIZ-NYILORA' and public.nyilora_can_read_portfolio(branch_id,loan_officer_id));
create policy nyilora_client_insert on public.loan_clients for insert to authenticated
  with check (business_id='BIZ-NYILORA' and branch_id=(public.nyilora_current_staff()).branch_id and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
     or (public.nyilora_has_role('loan_officer') and loan_officer_id=public.nyilora_staff_id())));
create policy nyilora_client_update on public.loan_clients for update to authenticated
  using (business_id='BIZ-NYILORA' and branch_id=(public.nyilora_current_staff()).branch_id and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
     or loan_officer_id=public.nyilora_staff_id()))
  with check (business_id='BIZ-NYILORA' and branch_id=(public.nyilora_current_staff()).branch_id);

create policy nyilora_product_read on public.loan_products for select to authenticated
  using (business_id='BIZ-NYILORA' and (public.nyilora_current_staff()).id is not null);
create policy nyilora_product_write on public.loan_products for all to authenticated
  using (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager'))
  with check (business_id='BIZ-NYILORA' and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')));

create policy nyilora_application_read on public.loan_applications for select to authenticated
  using (business_id='BIZ-NYILORA' and public.nyilora_can_read_portfolio(branch_id,loan_officer_id));
create policy nyilora_application_insert on public.loan_applications for insert to authenticated
  with check (business_id='BIZ-NYILORA' and branch_id=(public.nyilora_current_staff()).branch_id and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
     or (public.nyilora_has_role('loan_officer') and loan_officer_id=public.nyilora_staff_id())));
create policy nyilora_application_update on public.loan_applications for update to authenticated
  using (business_id='BIZ-NYILORA' and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
     or loan_officer_id=public.nyilora_staff_id()))
  with check (business_id='BIZ-NYILORA' and branch_id=(public.nyilora_current_staff()).branch_id);

create policy nyilora_loan_read on public.loans for select to authenticated
  using (business_id='BIZ-NYILORA' and public.nyilora_can_read_portfolio(branch_id,loan_officer_id));
create policy nyilora_loan_insert on public.loans for insert to authenticated
  with check (business_id='BIZ-NYILORA' and branch_id=(public.nyilora_current_staff()).branch_id and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
     or (public.nyilora_has_role('loan_officer') and loan_officer_id=public.nyilora_staff_id())));
create policy nyilora_loan_update on public.loans for update to authenticated
  using (business_id='BIZ-NYILORA' and public.nyilora_can_read_portfolio(branch_id,loan_officer_id))
  with check (business_id='BIZ-NYILORA' and branch_id=(public.nyilora_current_staff()).branch_id);

create policy nyilora_schedule_read on public.loan_schedules for select to authenticated
  using (business_id='BIZ-NYILORA' and exists (
    select 1 from public.loans l where l.id=loan_id
      and public.nyilora_can_read_portfolio(l.branch_id,l.loan_officer_id)));
create policy nyilora_schedule_insert on public.loan_schedules for insert to authenticated
  with check (business_id='BIZ-NYILORA' and exists (
    select 1 from public.loans l where l.id=loan_id
      and public.nyilora_can_read_portfolio(l.branch_id,l.loan_officer_id)));
create policy nyilora_schedule_update on public.loan_schedules for update to authenticated
  using (business_id='BIZ-NYILORA' and exists (
    select 1 from public.loans l where l.id=loan_id
      and public.nyilora_can_read_portfolio(l.branch_id,l.loan_officer_id)))
  with check (business_id='BIZ-NYILORA');

create policy nyilora_repayment_read on public.loan_repayments for select to authenticated
  using (business_id='BIZ-NYILORA' and exists (
    select 1 from public.loans l where l.id=loan_id
      and public.nyilora_can_read_portfolio(l.branch_id,l.loan_officer_id)));
create policy nyilora_repayment_insert on public.loan_repayments for insert to authenticated
  with check (business_id='BIZ-NYILORA' and exists (
    select 1 from public.loans l where l.id=loan_id
      and public.nyilora_can_read_portfolio(l.branch_id,l.loan_officer_id)));

create policy nyilora_penalty_read on public.loan_penalties for select to authenticated
  using (business_id='BIZ-NYILORA' and exists (
    select 1 from public.loans l where l.id=loan_id
      and public.nyilora_can_read_portfolio(l.branch_id,l.loan_officer_id)));

grant select,insert,update on public.loan_clients,public.loan_products,
  public.loan_applications,public.loans,public.loan_schedules,public.loan_repayments to authenticated;
grant select on public.loan_penalties to authenticated;
grant select,update on public.nyilora_branches,public.loan_staff to authenticated;


-- 0003_nyilora_operations.sql
-- New Nyilora project only. Supporting records for settings, audit, M-Pesa,
-- suspense, follow-ups and subscription billing. No external payment starts.

create table if not exists public.loan_settings (
  id uuid primary key default gen_random_uuid(),
  business_id text not null unique default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  company_name text not null default 'Nyilora Enterprise',
  company_phone text,company_email text,company_address text,currency text default 'KES',
  default_grace_period integer default 0,default_late_penalty_pct numeric(8,3) default 0,
  default_processing_fee_pct numeric(8,3) default 0,
  standard_weekly_rate numeric(8,3) default 0,micro_weekly_rate numeric(8,3) default 0,
  micro_threshold numeric(16,2) default 0,
  loan_no_prefix text default 'NYL',app_no_prefix text default 'APP',receipt_no_prefix text default 'RCP',
  disbursement_method text default 'cash',
  mpesa_consumer_key text,mpesa_consumer_secret text,mpesa_passkey text,
  mpesa_shortcode text,daraja_environment text default 'production',
  mpesa_auto_confirm boolean not null default false,
  created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
insert into public.loan_settings(business_id,company_name)
values('BIZ-NYILORA','Nyilora Enterprise') on conflict(business_id) do nothing;

create table if not exists public.loan_audit_log (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  user_id uuid references public.loan_staff(id),action text not null,
  table_name text,record_id text,old_value jsonb,new_value jsonb,
  created_at timestamptz not null default now()
);
create index if not exists loan_audit_log_time_idx on public.loan_audit_log(business_id,created_at desc);

create table if not exists public.loan_follow_ups (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  client_id uuid references public.loan_clients(id),loan_id uuid references public.loans(id),
  officer_id uuid references public.loan_staff(id),
  follow_up_type text,notes text,outcome text,
  follow_up_date date default current_date,next_follow_up_date date,
  created_at timestamptz not null default now()
);

create table if not exists public.mpesa_callback_queue (
  id uuid primary key default gen_random_uuid(),
  business_id text default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  transaction_type text,trans_id text not null unique,trans_time text,
  trans_amount numeric(16,2) not null default 0,business_short_code text,
  bill_ref_number text,msisdn text,first_name text,middle_name text,last_name text,
  raw_payload jsonb,confirmed boolean not null default false,
  dismissed boolean not null default false,
  loan_id uuid references public.loans(id),repayment_id uuid references public.loan_repayments(id),
  review_reason text,recorded_error text,
  created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create index if not exists mpesa_callback_queue_pending_idx
  on public.mpesa_callback_queue(business_id,created_at desc) where not confirmed and not dismissed;

create table if not exists public.unmatched_payments (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  mpesa_reference text not null,amount numeric(16,2) not null check(amount>0),
  account_number text,payer_phone text,payer_name text,raw_payload jsonb,
  resolved boolean not null default false,resolved_at timestamptz,
  loan_id uuid references public.loans(id),repayment_id uuid references public.loan_repayments(id),
  notes text,created_at timestamptz not null default now(),
  unique(business_id,mpesa_reference)
);

create table if not exists public.journal_entries (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  date date not null default current_date,ref text,description text,
  debit text,credit text,amount numeric(16,2) not null default 0,
  synced boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.loan_billing_cycles (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  billing_month date not null check(billing_month>=date '2026-12-01'),
  amount numeric(16,2) not null default 3000 check(amount=3000),
  status text not null default 'pending',phone text,
  checkout_request_id text unique,merchant_request_id text,
  paid_at timestamptz,paid_until date,receipt_number text,
  created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
  unique(business_id,billing_month)
);
create table if not exists public.loan_billing_transactions (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  cycle_id uuid references public.loan_billing_cycles(id),
  checkout_request_id text unique,merchant_request_id text,
  amount numeric(16,2) not null default 3000,
  phone text,status text not null default 'pending',receipt_number text,
  provider_response jsonb,created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);

-- Each legacy source table is kept inside the one Nyilora branch.
do $$ declare t text; begin
  foreach t in array array['loan_staff','loan_clients','loan_applications','loans',
    'loan_schedules','loan_repayments','loan_penalties','mpesa_callback_queue',
    'unmatched_payments','journal_entries'] loop
    execute format('alter table public.%I add constraint %I check (branch_id = %L::uuid)',
      t,t||'_nyilora_single_branch','00000000-0000-4000-8000-000000000001');
  end loop;
end $$;

alter table public.loan_settings enable row level security;
alter table public.loan_audit_log enable row level security;
alter table public.loan_follow_ups enable row level security;
alter table public.mpesa_callback_queue enable row level security;
alter table public.unmatched_payments enable row level security;
alter table public.journal_entries enable row level security;
alter table public.loan_billing_cycles enable row level security;
alter table public.loan_billing_transactions enable row level security;

create policy nyilora_settings_admin on public.loan_settings for all to authenticated
  using (public.nyilora_has_role('admin'))
  with check (business_id='BIZ-NYILORA' and public.nyilora_has_role('admin'));
create policy nyilora_audit_read on public.loan_audit_log for select to authenticated
  using (business_id='BIZ-NYILORA' and public.nyilora_has_role('admin'));
create policy nyilora_audit_insert on public.loan_audit_log for insert to authenticated
  with check (business_id='BIZ-NYILORA' and user_id=public.nyilora_staff_id());
create policy nyilora_follow_up_read on public.loan_follow_ups for select to authenticated
  using (business_id='BIZ-NYILORA' and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager') or officer_id=public.nyilora_staff_id()));
create policy nyilora_follow_up_insert on public.loan_follow_ups for insert to authenticated
  with check (business_id='BIZ-NYILORA' and officer_id=public.nyilora_staff_id());
create policy nyilora_queue_read on public.mpesa_callback_queue for select to authenticated
  using (business_id='BIZ-NYILORA' and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager') or public.nyilora_has_role('cashier')));
create policy nyilora_queue_update on public.mpesa_callback_queue for update to authenticated
  using (business_id='BIZ-NYILORA' and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager') or public.nyilora_has_role('cashier')))
  with check (business_id='BIZ-NYILORA');
create policy nyilora_unmatched_read on public.unmatched_payments for select to authenticated
  using (business_id='BIZ-NYILORA' and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager') or public.nyilora_has_role('cashier')));
create policy nyilora_unmatched_write on public.unmatched_payments for all to authenticated
  using (business_id='BIZ-NYILORA' and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager') or public.nyilora_has_role('cashier')))
  with check (business_id='BIZ-NYILORA');
create policy nyilora_journal_admin on public.journal_entries for all to authenticated
  using (business_id='BIZ-NYILORA' and public.nyilora_has_role('admin'))
  with check (business_id='BIZ-NYILORA' and public.nyilora_has_role('admin'));
create policy nyilora_billing_admin on public.loan_billing_cycles for select to authenticated
  using (business_id='BIZ-NYILORA' and public.nyilora_has_role('admin'));

grant select,insert,update on public.loan_settings,public.loan_audit_log,
  public.loan_follow_ups,public.mpesa_callback_queue,public.unmatched_payments,
  public.journal_entries to authenticated;
grant select on public.loan_billing_cycles to authenticated;


-- 0004_nyilora_finance_sms_documents.sql
-- Fresh Nyilora project feature tables. These create empty registers only.

create table if not exists public.nyilora_staff_permissions (
  staff_id uuid primary key references public.loan_staff(id) on delete cascade,
  business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  view_accounting boolean not null default false,view_expenses boolean not null default false,
  initiate_expenses boolean not null default false,approve_expenses boolean not null default false,
  manage_assets boolean not null default false,manage_branches boolean not null default false,
  transfer_portfolios boolean not null default false,adjust_charges_excess boolean not null default false,
  updated_by uuid references public.loan_staff(id),updated_at timestamptz not null default now()
);

create table if not exists public.nyilora_expenses (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  expense_no text not null unique,expense_date date not null default current_date,
  category text not null,custom_category text,description text not null,
  amount numeric(16,2) not null check(amount>0),payment_method text not null default 'cash',
  payment_reference text,vendor text,receipt_url text,
  status text not null default 'pending' check(status in ('draft','pending','approved','rejected','paid','cancelled')),
  initiated_by uuid not null references public.loan_staff(id),
  approved_by uuid references public.loan_staff(id),approved_at timestamptz,
  rejected_by uuid references public.loan_staff(id),rejected_at timestamptz,rejection_reason text,
  created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create index if not exists nyilora_expenses_date_idx on public.nyilora_expenses(branch_id,expense_date desc);

create table if not exists public.nyilora_assets (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  asset_no text not null unique,category text not null,custom_category text,
  description text not null,model_type text,serial_registration_no text,
  purchase_date date,initial_price numeric(16,2) not null default 0 check(initial_price>=0),
  current_value numeric(16,2) not null default 0 check(current_value>=0),
  custodian_staff_id uuid references public.loan_staff(id),condition text not null default 'good',
  status text not null default 'active' check(status in ('active','in_repair','disposed','lost','inactive')),
  notes text,disposed_at timestamptz,disposal_value numeric(16,2),
  created_by uuid not null references public.loan_staff(id),
  created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create table if not exists public.nyilora_asset_movements (
  id uuid primary key default gen_random_uuid(),asset_id uuid not null references public.nyilora_assets(id),
  business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  from_branch_id uuid references public.nyilora_branches(id),to_branch_id uuid references public.nyilora_branches(id),
  from_custodian_id uuid references public.loan_staff(id),to_custodian_id uuid references public.loan_staff(id),
  action text not null,notes text,performed_by uuid not null references public.loan_staff(id),
  created_at timestamptz not null default now()
);

create table if not exists public.nyilora_accounting_entries (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  entry_date date not null,account_code text not null,account_name text not null,
  account_type text not null check(account_type in ('asset','liability','equity','income','expense')),
  debit numeric(16,2) not null default 0 check(debit>=0),
  credit numeric(16,2) not null default 0 check(credit>=0),
  description text not null,source_table text not null,source_id text not null,entry_key text not null,
  loan_id uuid references public.loans(id),expense_id uuid references public.nyilora_expenses(id),
  asset_id uuid references public.nyilora_assets(id),created_by uuid references public.loan_staff(id),
  created_at timestamptz not null default now(),
  unique(business_id,source_table,source_id,entry_key)
);
create index if not exists nyilora_accounting_date_idx on public.nyilora_accounting_entries(branch_id,entry_date desc);

create table if not exists public.nyilora_domain_audit (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  actor_staff_id uuid references public.loan_staff(id),action text not null,
  entity_type text not null,entity_id text,old_value jsonb,new_value jsonb,
  created_at timestamptz not null default now()
);

create table if not exists public.nyilora_client_documents (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  client_id uuid not null references public.loan_clients(id),kind text not null,
  object_path text not null,uploaded_by uuid references public.loan_staff(id),
  created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
  unique(client_id,kind)
);

create table if not exists public.nyilora_sms_wallets (
  id uuid primary key default gen_random_uuid(),business_id text not null unique default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  sender_id text,credits_purchased integer not null default 0,
  credits_used integer not null default 0,credits_remaining integer not null default 0,
  updated_at timestamptz not null default now()
);
insert into public.nyilora_sms_wallets(business_id)
values('BIZ-NYILORA') on conflict(business_id) do nothing;
create table if not exists public.nyilora_sms_outbox (
  id uuid primary key default gen_random_uuid(),business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001' references public.nyilora_branches(id),
  client_id uuid references public.loan_clients(id),loan_id uuid references public.loans(id),
  repayment_id uuid references public.loan_repayments(id),
  recipient text not null,sender_id text,message text not null,sms_type text,
  status text not null default 'queued',provider_uid text,provider_response jsonb,
  provider_error text,attempts integer not null default 0,
  queued_at timestamptz not null default now(),sent_at timestamptz,
  created_at timestamptz not null default now()
);
create unique index if not exists nyilora_sms_repayment_once
  on public.nyilora_sms_outbox(repayment_id) where repayment_id is not null;
create table if not exists public.nyilora_sms_topups (
  id uuid primary key default gen_random_uuid(),business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  credits integer not null check(credits>0),amount numeric(16,2),reference text,
  created_by uuid references public.loan_staff(id),created_at timestamptz not null default now()
);
create table if not exists public.nyilora_sms_bundle_requests (
  id uuid primary key default gen_random_uuid(),business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  credits integer not null check(credits>0),amount numeric(16,2) not null,
  customer_amount numeric(16,2) not null,phone text not null,
  requested_by uuid references public.loan_staff(id),status text not null default 'pending',
  note text,checkout_request_id text unique,merchant_request_id text,
  receipt_number text,result_description text,provider_response jsonb,
  created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);

alter table public.nyilora_staff_permissions enable row level security;
alter table public.nyilora_expenses enable row level security;
alter table public.nyilora_assets enable row level security;
alter table public.nyilora_asset_movements enable row level security;
alter table public.nyilora_accounting_entries enable row level security;
alter table public.nyilora_domain_audit enable row level security;
alter table public.nyilora_client_documents enable row level security;
alter table public.nyilora_sms_wallets enable row level security;
alter table public.nyilora_sms_outbox enable row level security;
alter table public.nyilora_sms_topups enable row level security;
alter table public.nyilora_sms_bundle_requests enable row level security;

create policy nyilora_permission_read on public.nyilora_staff_permissions for select to authenticated
  using (staff_id=public.nyilora_staff_id() or public.nyilora_has_role('admin'));
create policy nyilora_permission_admin on public.nyilora_staff_permissions for all to authenticated
  using (public.nyilora_has_role('admin'))
  with check (business_id='BIZ-NYILORA' and public.nyilora_has_role('admin'));
create policy nyilora_expense_read on public.nyilora_expenses for select to authenticated
  using (business_id='BIZ-NYILORA' and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
     or initiated_by=public.nyilora_staff_id()));
create policy nyilora_asset_read on public.nyilora_assets for select to authenticated
  using (business_id='BIZ-NYILORA' and (public.nyilora_current_staff()).id is not null);
create policy nyilora_accounting_read on public.nyilora_accounting_entries for select to authenticated
  using (business_id='BIZ-NYILORA' and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')));
create policy nyilora_domain_audit_read on public.nyilora_domain_audit for select to authenticated
  using (business_id='BIZ-NYILORA' and public.nyilora_has_role('admin'));
create policy nyilora_document_read on public.nyilora_client_documents for select to authenticated
  using (business_id='BIZ-NYILORA' and exists (
    select 1 from public.loan_clients c where c.id=client_id and
      public.nyilora_can_read_portfolio(c.branch_id,c.loan_officer_id)));
create policy nyilora_sms_wallet_read on public.nyilora_sms_wallets for select to authenticated
  using (business_id='BIZ-NYILORA' and (public.nyilora_current_staff()).id is not null);
create policy nyilora_sms_outbox_read on public.nyilora_sms_outbox for select to authenticated
  using (business_id='BIZ-NYILORA' and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
     or exists(select 1 from public.loan_clients c where c.id=client_id and c.loan_officer_id=public.nyilora_staff_id())));
create policy nyilora_sms_topup_read on public.nyilora_sms_topups for select to authenticated
  using (business_id='BIZ-NYILORA' and public.nyilora_has_role('admin'));
create policy nyilora_sms_bundle_read on public.nyilora_sms_bundle_requests for select to authenticated
  using (business_id='BIZ-NYILORA' and public.nyilora_has_role('admin'));

grant select on public.nyilora_staff_permissions,public.nyilora_expenses,
  public.nyilora_accounting_entries,public.nyilora_domain_audit,
  public.nyilora_sms_wallets,public.nyilora_sms_outbox,
  public.nyilora_sms_topups,public.nyilora_sms_bundle_requests to authenticated;
grant select,insert,update on public.nyilora_assets,public.nyilora_asset_movements,
  public.nyilora_client_documents to authenticated;
grant insert,update on public.nyilora_staff_permissions to authenticated;

commit;