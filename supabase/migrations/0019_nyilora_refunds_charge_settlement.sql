-- Nyilora only. Record completed refunds and cash settlement/waiver of charges.
-- This records confirmed actions; it does not initiate M-Pesa or bank payouts.
begin;

alter table public.nyilora_excess_allocations
  add column if not exists payment_method text,
  add column if not exists payment_reference text;
create unique index if not exists nyilora_refund_reference_once
  on public.nyilora_excess_allocations(business_id,upper(payment_reference))
  where action='refund' and nullif(trim(payment_reference),'') is not null;

create table if not exists public.nyilora_charge_receipts (
  id uuid primary key default gen_random_uuid(),
  business_id text not null default 'BIZ-NYILORA' check(business_id='BIZ-NYILORA'),
  branch_id uuid not null default '00000000-0000-4000-8000-000000000001'
    references public.nyilora_branches(id)
    check(branch_id='00000000-0000-4000-8000-000000000001'),
  charge_id uuid not null references public.nyilora_charges(id),
  amount numeric(16,2) not null check(amount>0),
  payment_method text not null check(payment_method in ('cash','mpesa','bank')),
  payment_reference text not null,
  recorded_by uuid not null references public.loan_staff(id),
  recorded_at timestamptz not null default now(),
  unique(business_id,payment_reference)
);
alter table public.nyilora_charge_receipts enable row level security;
drop policy if exists nyilora_charge_receipt_read on public.nyilora_charge_receipts;
create policy nyilora_charge_receipt_read on public.nyilora_charge_receipts for select to authenticated
  using(business_id='BIZ-NYILORA' and public.nyilora_can_adjust_charges());
grant select on public.nyilora_charge_receipts to authenticated;

create or replace function public.nyilora_cash_account(p_method text)
returns text language sql immutable as $$
  select case lower(p_method) when 'mpesa' then '1010'
    when 'bank' then '1020' when 'cash' then '1000' else null end
$$;

create or replace function public.nyilora_resolve_excess(
  p_excess_id uuid,p_action text,p_amount numeric,p_note text,p_method text default 'cash'
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_excess public.nyilora_excess_ledger; v_remaining numeric(16,2);
  v_code text; v_name text; v_allocation uuid; v_ref text;
begin
  if public.nyilora_staff_id() is null or not public.nyilora_can_adjust_charges()
    then raise exception 'Charges & Excess permission required' using errcode='42501'; end if;
  if p_action<>'refund' then raise exception 'Use Apply to Loan to carry credit forward'; end if;
  if p_amount is null or p_amount<=0 or round(p_amount,2)<>p_amount
    then raise exception 'Enter a positive refund amount with at most two decimal places'; end if;
  v_ref:=upper(trim(coalesce(p_note,'')));
  if length(v_ref)<4 then raise exception 'Enter the completed refund reference'; end if;
  v_code:=public.nyilora_cash_account(p_method);
  if v_code is null then raise exception 'Choose cash, M-Pesa or bank as the refund method'; end if;
  v_name:=case v_code when '1010' then 'M-Pesa' when '1020' then 'Bank' else 'Cash' end;
  select * into v_excess from public.nyilora_excess_ledger
    where id=p_excess_id and business_id='BIZ-NYILORA' for update;
  if v_excess.id is null or p_amount>v_excess.amount_available
    then raise exception 'Refund exceeds available client credit'; end if;
  v_remaining:=round(v_excess.amount_available-p_amount,2);
  update public.nyilora_excess_ledger set amount_available=v_remaining,
    status=case when v_remaining=0 then 'refunded' else 'partially_used' end,
    resolved_at=case when v_remaining=0 then now() else null end,
    resolved_by=case when v_remaining=0 then public.nyilora_staff_id() else null end,
    resolution_note=v_ref,updated_at=now()
  where id=v_excess.id;
  insert into public.nyilora_excess_allocations
    (excess_id,action,amount,note,payment_method,payment_reference,created_by)
  values(v_excess.id,'refund',p_amount,v_ref,lower(p_method),v_ref,public.nyilora_staff_id())
  returning id into v_allocation;
  insert into public.nyilora_accounting_entries
    (business_id,branch_id,entry_date,account_code,account_name,account_type,debit,credit,
     description,source_table,source_id,entry_key,loan_id,created_by)
  values
    ('BIZ-NYILORA',v_excess.branch_id,(now() at time zone 'Africa/Nairobi')::date,'2100','Client Credit','liability',p_amount,0,
      'Client credit refunded '||v_ref,'nyilora_excess_allocations',v_allocation::text,'refund_liability',
      v_excess.loan_id,public.nyilora_staff_id()),
    ('BIZ-NYILORA',v_excess.branch_id,(now() at time zone 'Africa/Nairobi')::date,v_code,v_name,'asset',0,p_amount,
      'Client credit refunded '||v_ref,'nyilora_excess_allocations',v_allocation::text,'refund_paid',
      v_excess.loan_id,public.nyilora_staff_id());
  insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,entity_id,new_value)
  values(public.nyilora_staff_id(),'client_credit_refunded','nyilora_excess_ledger',v_excess.id::text,
    jsonb_build_object('amount',p_amount,'method',lower(p_method),'reference',v_ref));
  return jsonb_build_object('ok',true,'amount_resolved',p_amount,'remaining',v_remaining,
    'action','refund','allocation_id',v_allocation);
end $$;

create or replace function public.nyilora_settle_charge(
  p_charge_id uuid,p_action text,p_note text,p_method text default 'cash'
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_charge public.nyilora_charges; v_remaining numeric(16,2);
  v_code text; v_name text; v_income_code text; v_income_name text;
  v_receipt uuid; v_ref text; v_source text;
begin
  if public.nyilora_staff_id() is null or not public.nyilora_can_adjust_charges()
    then raise exception 'Charges & Excess permission required' using errcode='42501'; end if;
  if p_action is null or p_action not in ('paid','waived') then raise exception 'Choose paid or waived'; end if;
  v_ref:=upper(trim(coalesce(p_note,'')));
  if length(v_ref)<4 then raise exception 'Enter a payment reference or waiver reason'; end if;
  select * into v_charge from public.nyilora_charges
    where id=p_charge_id and business_id='BIZ-NYILORA' for update;
  if v_charge.id is null or v_charge.status not in ('pending','partially_paid')
    then raise exception 'Open charge not found'; end if;
  v_remaining:=round(v_charge.amount-v_charge.amount_paid,2);
  if v_remaining<=0 then raise exception 'Charge has no unpaid balance'; end if;
  if p_action='paid' then
    v_code:=public.nyilora_cash_account(p_method);
    if v_code is null then raise exception 'Choose cash, M-Pesa or bank'; end if;
    v_name:=case v_code when '1010' then 'M-Pesa' when '1020' then 'Bank' else 'Cash' end;
    insert into public.nyilora_charge_receipts
      (charge_id,amount,payment_method,payment_reference,recorded_by)
    values(v_charge.id,v_remaining,lower(p_method),v_ref,public.nyilora_staff_id())
    returning id into v_receipt;
    update public.nyilora_charges set amount_paid=amount,status='paid',settled_at=now(),
      settled_by=public.nyilora_staff_id(),settlement_note=v_ref,updated_at=now()
    where id=v_charge.id;
    insert into public.nyilora_accounting_entries
      (business_id,branch_id,entry_date,account_code,account_name,account_type,debit,credit,
       description,source_table,source_id,entry_key,loan_id,created_by)
    values
      ('BIZ-NYILORA',v_charge.branch_id,(now() at time zone 'Africa/Nairobi')::date,v_code,v_name,'asset',v_remaining,0,
        'Charge payment '||v_ref,'nyilora_charge_receipts',v_receipt::text,'cash_received',
        v_charge.loan_id,public.nyilora_staff_id()),
      ('BIZ-NYILORA',v_charge.branch_id,(now() at time zone 'Africa/Nairobi')::date,'1150','Client Charges Receivable','asset',0,v_remaining,
        'Charge payment '||v_ref,'nyilora_charge_receipts',v_receipt::text,'charge_receivable',
        v_charge.loan_id,public.nyilora_staff_id());
    v_source:=v_receipt::text;
  else
    v_income_code:=case v_charge.charge_type when 'processing_fee' then '4020'
      when 'registration_fee' then '4030' when 'penalty' then '4010' else '4040' end;
    v_income_name:=case v_charge.charge_type when 'processing_fee' then 'Processing Fee Income'
      when 'registration_fee' then 'Registration Fee Income'
      when 'penalty' then 'Penalty Income' else 'Other Charges Income' end;
    update public.nyilora_charges set status='waived',settled_at=now(),
      settled_by=public.nyilora_staff_id(),settlement_note=v_ref,updated_at=now()
    where id=v_charge.id;
    insert into public.nyilora_accounting_entries
      (business_id,branch_id,entry_date,account_code,account_name,account_type,debit,credit,
       description,source_table,source_id,entry_key,loan_id,created_by)
    values
      ('BIZ-NYILORA',v_charge.branch_id,(now() at time zone 'Africa/Nairobi')::date,v_income_code,v_income_name,'income',v_remaining,0,
        'Charge waived '||v_ref,'nyilora_charges',v_charge.id::text,'waiver_income_reversal',
        v_charge.loan_id,public.nyilora_staff_id()),
      ('BIZ-NYILORA',v_charge.branch_id,(now() at time zone 'Africa/Nairobi')::date,'1150','Client Charges Receivable','asset',0,v_remaining,
        'Charge waived '||v_ref,'nyilora_charges',v_charge.id::text,'waiver_receivable_reversal',
        v_charge.loan_id,public.nyilora_staff_id());
    v_source:=v_charge.id::text;
  end if;
  insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,entity_id,new_value)
  values(public.nyilora_staff_id(),'charge_'||p_action,'nyilora_charges',v_charge.id::text,
    jsonb_build_object('amount',v_remaining,'method',case when p_action='paid' then lower(p_method) else null end,
      'reference_or_reason',v_ref,'source_id',v_source));
  return jsonb_build_object('ok',true,'status',p_action,'amount',v_remaining,'receipt_id',v_receipt);
end $$;

revoke all on function public.nyilora_cash_account(text),
  public.nyilora_resolve_excess(uuid,text,numeric,text,text),
  public.nyilora_settle_charge(uuid,text,text,text) from public,anon;
grant execute on function public.nyilora_cash_account(text),
  public.nyilora_resolve_excess(uuid,text,numeric,text,text),
  public.nyilora_settle_charge(uuid,text,text,text) to authenticated;
notify pgrst,'reload schema';
commit;
