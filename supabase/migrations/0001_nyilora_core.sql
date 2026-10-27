-- New Nyilora Enterprise project only. No data is imported from another system.
-- Core lending records and the single editable branch. Run once in the fresh
-- project before the feature and security migrations that follow.
begin;
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

commit;
