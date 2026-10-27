-- Fresh Nyilora project feature tables. These create empty registers only.
begin;

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
