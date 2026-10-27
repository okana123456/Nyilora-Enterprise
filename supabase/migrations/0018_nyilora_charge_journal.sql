-- Nyilora only. Future charge recognition and internal credit-to-charge journal.
-- Existing charge balances, loans and repayments are not changed.
begin;

create or replace function public.nyilora_check_new_charge()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.business_id<>'BIZ-NYILORA' or new.status<>'pending' or new.amount_paid<>0
    then raise exception 'New Nyilora charges must start pending with zero paid'; end if;
  if not exists(select 1 from public.loan_clients c where c.id=new.client_id
    and c.business_id='BIZ-NYILORA' and c.branch_id=new.branch_id)
    then raise exception 'Charge client is outside Nyilora'; end if;
  if new.loan_id is not null and not exists(select 1 from public.loans l
    where l.id=new.loan_id and l.client_id=new.client_id and l.business_id='BIZ-NYILORA'
      and l.branch_id=new.branch_id)
    then raise exception 'Charge loan does not match client'; end if;
  return new;
end $$;

create or replace function public.nyilora_post_new_charge_journal()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_code text; v_name text;
begin
  v_code:=case new.charge_type when 'processing_fee' then '4020'
    when 'registration_fee' then '4030' when 'penalty' then '4010' else '4040' end;
  v_name:=case new.charge_type when 'processing_fee' then 'Processing Fee Income'
    when 'registration_fee' then 'Registration Fee Income'
    when 'penalty' then 'Penalty Income' else 'Other Charges Income' end;
  insert into public.nyilora_accounting_entries
    (business_id,branch_id,entry_date,account_code,account_name,account_type,debit,credit,
     description,source_table,source_id,entry_key,loan_id,created_by)
  values
    ('BIZ-NYILORA',new.branch_id,new.charge_date,'1150','Client Charges Receivable','asset',
      new.amount,0,new.description,'nyilora_charges',new.id::text,'charge_receivable',new.loan_id,new.created_by),
    ('BIZ-NYILORA',new.branch_id,new.charge_date,v_code,v_name,'income',
      0,new.amount,new.description,'nyilora_charges',new.id::text,'charge_income',new.loan_id,new.created_by)
  on conflict (business_id,source_table,source_id,entry_key) do nothing;
  return new;
end $$;

create or replace function public.nyilora_post_charge_credit_allocation()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_excess public.nyilora_excess_ledger; v_charge public.nyilora_charges;
begin
  if new.action<>'charge_payment' then return new; end if;
  select * into v_excess from public.nyilora_excess_ledger where id=new.excess_id;
  select * into v_charge from public.nyilora_charges where id=new.charge_id;
  if v_excess.id is null or v_charge.id is null or v_excess.client_id<>v_charge.client_id
    or v_excess.branch_id<>v_charge.branch_id or new.business_id<>'BIZ-NYILORA'
    or new.branch_id<>v_charge.branch_id
    then raise exception 'Credit allocation does not match its charge'; end if;
  insert into public.nyilora_accounting_entries
    (business_id,branch_id,entry_date,account_code,account_name,account_type,debit,credit,
     description,source_table,source_id,entry_key,loan_id,created_by)
  values
    ('BIZ-NYILORA',new.branch_id,(new.created_at at time zone 'Africa/Nairobi')::date,
      '2100','Client Credit','liability',new.amount,0,
      'Client credit applied to charge','nyilora_excess_allocations',new.id::text,'credit_used',
      v_charge.loan_id,new.created_by),
    ('BIZ-NYILORA',new.branch_id,(new.created_at at time zone 'Africa/Nairobi')::date,
      '1150','Client Charges Receivable','asset',0,new.amount,
      'Client credit applied to charge','nyilora_excess_allocations',new.id::text,'charge_collected',
      v_charge.loan_id,new.created_by)
  on conflict (business_id,source_table,source_id,entry_key) do nothing;
  return new;
end $$;

drop trigger if exists nyilora_check_new_charge_trg on public.nyilora_charges;
create trigger nyilora_check_new_charge_trg before insert on public.nyilora_charges
  for each row execute function public.nyilora_check_new_charge();
drop trigger if exists nyilora_new_charge_journal_trg on public.nyilora_charges;
create trigger nyilora_new_charge_journal_trg after insert on public.nyilora_charges
  for each row execute function public.nyilora_post_new_charge_journal();
drop trigger if exists nyilora_charge_credit_allocation_trg on public.nyilora_excess_allocations;
create trigger nyilora_charge_credit_allocation_trg after insert on public.nyilora_excess_allocations
  for each row execute function public.nyilora_post_charge_credit_allocation();

revoke all on function public.nyilora_check_new_charge(),
  public.nyilora_post_new_charge_journal(),
  public.nyilora_post_charge_credit_allocation() from public,anon,authenticated;
commit;
