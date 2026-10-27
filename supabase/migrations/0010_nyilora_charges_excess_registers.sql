-- Nyilora only. Empty Charges & Excess registers; no historical conversion or payment changes.
begin;

create table if not exists public.nyilora_charges (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001'
    references public.nyilora_branches(id)
    check(branch_id='00000000-0000-4000-8000-000000000001'),
  client_id uuid not null references public.loan_clients(id),
  loan_id uuid references public.loans(id),
  charge_type text not null check(charge_type in ('processing_fee','registration_fee','penalty','other')),
  description text not null,amount numeric(16,2) not null check(amount>0),
  amount_paid numeric(16,2) not null default 0 check(amount_paid>=0),
  status text not null default 'pending' check(status in ('pending','partially_paid','paid','waived')),
  source text not null default 'system' check(source in ('system','manual')),
  charge_date date not null default current_date,
  created_by uuid references public.loan_staff(id),settled_at timestamptz,
  settled_by uuid references public.loan_staff(id),settlement_note text,
  created_at timestamptz not null default now(),updated_at timestamptz not null default now(),
  check(amount_paid<=amount)
);
create unique index if not exists nyilora_system_charge_once
  on public.nyilora_charges(loan_id,charge_type) where loan_id is not null and source='system';
create index if not exists nyilora_charges_client_status
  on public.nyilora_charges(client_id,status,charge_date desc);

create table if not exists public.nyilora_excess_ledger (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001'
    references public.nyilora_branches(id)
    check(branch_id='00000000-0000-4000-8000-000000000001'),
  client_id uuid not null references public.loan_clients(id),
  loan_id uuid references public.loans(id),repayment_id uuid unique references public.loan_repayments(id),
  amount_original numeric(16,2) not null check(amount_original>0),
  amount_available numeric(16,2) not null check(amount_available>=0 and amount_available<=amount_original),
  status text not null default 'available'
    check(status in ('available','partially_used','applied','refunded','carried_forward')),
  source text not null check(source in ('manual_payment','mpesa_callback','suspense_match')),
  payment_reference text,notes text,created_by uuid references public.loan_staff(id),
  resolved_at timestamptz,resolved_by uuid references public.loan_staff(id),resolution_note text,
  created_at timestamptz not null default now(),updated_at timestamptz not null default now()
);
create index if not exists nyilora_excess_client_status
  on public.nyilora_excess_ledger(client_id,status,created_at desc);

create table if not exists public.nyilora_excess_allocations (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001'
    references public.nyilora_branches(id)
    check(branch_id='00000000-0000-4000-8000-000000000001'),
  excess_id uuid not null references public.nyilora_excess_ledger(id),
  charge_id uuid references public.nyilora_charges(id),
  action text not null check(action in ('charge_payment','loan_payment','refund','carry_forward')),
  amount numeric(16,2) not null check(amount>0),note text,
  created_by uuid references public.loan_staff(id),created_at timestamptz not null default now()
);

alter table public.nyilora_charges enable row level security;
alter table public.nyilora_excess_ledger enable row level security;
alter table public.nyilora_excess_allocations enable row level security;

create policy nyilora_charge_read on public.nyilora_charges for select to authenticated
  using (business_id='BIZ-NYILORA' and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
     or public.nyilora_has_role('cashier')));
create policy nyilora_charge_manual_insert on public.nyilora_charges for insert to authenticated
  with check (business_id='BIZ-NYILORA' and
    branch_id='00000000-0000-4000-8000-000000000001' and source='manual'
    and loan_id is null and created_by=public.nyilora_staff_id()
    and (public.nyilora_has_role('admin') or coalesce((
      select p.adjust_charges_excess from public.nyilora_staff_permissions p
      where p.staff_id=public.nyilora_staff_id()),false))
    and exists(select 1 from public.loan_clients c where c.id=client_id
      and c.business_id='BIZ-NYILORA'));
create policy nyilora_excess_read on public.nyilora_excess_ledger for select to authenticated
  using (business_id='BIZ-NYILORA' and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
     or public.nyilora_has_role('cashier')));
create policy nyilora_excess_allocation_read on public.nyilora_excess_allocations for select to authenticated
  using (business_id='BIZ-NYILORA' and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
     or public.nyilora_has_role('cashier')));

grant select,insert on public.nyilora_charges to authenticated;
grant select on public.nyilora_excess_ledger,public.nyilora_excess_allocations to authenticated;
notify pgrst,'reload schema';
commit;
