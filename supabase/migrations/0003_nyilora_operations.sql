-- New Nyilora project only. Supporting records for settings, audit, M-Pesa,
-- suspense, follow-ups and subscription billing. No external payment starts.
begin;

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

commit;
