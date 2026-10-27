-- Nyilora only. Post balanced journal entries for NEW loan disbursements and repayments.
-- No historical backfill and no updates to loan, repayment or schedule amounts.
begin;

create or replace function public.nyilora_post_new_loan_journal()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_code text; v_name text; v_amount numeric(16,2);
begin
  if new.business_id<>'BIZ-NYILORA' or new.disbursement_date is null then return new; end if;
  v_amount:=round(coalesce(new.disbursed_amount,0),2);
  if v_amount<=0 then return new; end if;
  v_code:=case when lower(coalesce(new.disbursement_method,'')) like '%mpesa%' then '1010'
    when lower(coalesce(new.disbursement_method,'')) like '%bank%' then '1020' else '1000' end;
  v_name:=case v_code when '1010' then 'M-Pesa' when '1020' then 'Bank' else 'Cash' end;
  insert into public.nyilora_accounting_entries
    (business_id,branch_id,entry_date,account_code,account_name,account_type,debit,credit,
     description,source_table,source_id,entry_key,loan_id,created_by)
  values
    ('BIZ-NYILORA',new.branch_id,new.disbursement_date,'1100','Principal Receivable','asset',
      v_amount,0,'Loan disbursed '||new.loan_no,'loans',new.id::text,'principal_receivable',new.id,new.loan_officer_id),
    ('BIZ-NYILORA',new.branch_id,new.disbursement_date,v_code,v_name,'asset',
      0,v_amount,'Loan disbursed '||new.loan_no,'loans',new.id::text,'cash_disbursed',new.id,new.loan_officer_id)
  on conflict (business_id,source_table,source_id,entry_key) do nothing;
  return new;
end $$;

create or replace function public.nyilora_post_new_repayment_journal()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_code text; v_name text; v_date date; v_amount numeric(16,2);
  v_principal numeric(16,2); v_interest numeric(16,2); v_penalty numeric(16,2);
  v_processing numeric(16,2); v_registration numeric(16,2); v_credit numeric(16,2);
  v_unallocated numeric(16,2); v_loan public.loans;
begin
  if new.business_id<>'BIZ-NYILORA' then return new; end if;
  select * into v_loan from public.loans where id=new.loan_id and business_id='BIZ-NYILORA';
  if v_loan.id is null or v_loan.branch_id is distinct from new.branch_id
    then raise exception 'Repayment and loan branch do not match Nyilora'; end if;
  v_date:=(new.payment_date at time zone 'Africa/Nairobi')::date;
  v_amount:=round(new.amount,2);
  v_interest:=round(coalesce(new.interest_portion,0),2);
  v_penalty:=round(coalesce(new.penalty_portion,0),2);
  v_processing:=round(coalesce(new.processing_fee_portion,0),2);
  v_registration:=round(coalesce(new.registration_fee_portion,0),2);
  v_credit:=round(coalesce(new.credit_portion,0),2);
  v_principal:=round(greatest(0,coalesce(new.loan_portion,0)-v_interest),2);
  if least(v_interest,v_penalty,v_processing,v_registration,v_credit,v_principal)<0
    then raise exception 'Repayment portions cannot be negative'; end if;
  v_unallocated:=round(v_amount-v_principal-v_interest-v_penalty-v_processing-v_registration-v_credit,2);
  if v_unallocated<0 then raise exception 'Repayment portions exceed received amount'; end if;
  if lower(coalesce(new.payment_method,''))='client_excess' then
    v_code:='2100';v_name:='Client Credit';
  elsif lower(coalesce(new.payment_method,'')) like '%mpesa%' then
    v_code:='1010';v_name:='M-Pesa';
  elsif lower(coalesce(new.payment_method,'')) like '%bank%' then
    v_code:='1020';v_name:='Bank';
  else v_code:='1000';v_name:='Cash'; end if;
  insert into public.nyilora_accounting_entries
    (business_id,branch_id,entry_date,account_code,account_name,account_type,debit,credit,
     description,source_table,source_id,entry_key,loan_id,created_by)
  values('BIZ-NYILORA',new.branch_id,v_date,v_code,v_name,
    case when v_code='2100' then 'liability' else 'asset' end,v_amount,0,
    'Repayment '||new.receipt_no,'loan_repayments',new.id::text,'receipt',new.loan_id,new.collected_by)
  on conflict (business_id,source_table,source_id,entry_key) do nothing;
  if v_principal>0 then
    insert into public.nyilora_accounting_entries
      (business_id,branch_id,entry_date,account_code,account_name,account_type,debit,credit,
       description,source_table,source_id,entry_key,loan_id,created_by)
    values('BIZ-NYILORA',new.branch_id,v_date,'1100','Principal Receivable','asset',0,v_principal,
      'Principal recovered '||new.receipt_no,'loan_repayments',new.id::text,'principal',new.loan_id,new.collected_by)
    on conflict (business_id,source_table,source_id,entry_key) do nothing;
  end if;
  if v_interest>0 then
    insert into public.nyilora_accounting_entries
      (business_id,branch_id,entry_date,account_code,account_name,account_type,debit,credit,
       description,source_table,source_id,entry_key,loan_id,created_by)
    values('BIZ-NYILORA',new.branch_id,v_date,'4000','Interest Income','income',0,v_interest,
      'Interest received '||new.receipt_no,'loan_repayments',new.id::text,'interest',new.loan_id,new.collected_by)
    on conflict (business_id,source_table,source_id,entry_key) do nothing;
  end if;
  if v_penalty>0 then
    insert into public.nyilora_accounting_entries
      (business_id,branch_id,entry_date,account_code,account_name,account_type,debit,credit,
       description,source_table,source_id,entry_key,loan_id,created_by)
    values('BIZ-NYILORA',new.branch_id,v_date,'4010','Penalty Income','income',0,v_penalty,
      'Penalty received '||new.receipt_no,'loan_repayments',new.id::text,'penalty',new.loan_id,new.collected_by)
    on conflict (business_id,source_table,source_id,entry_key) do nothing;
  end if;
  if v_processing>0 then
    insert into public.nyilora_accounting_entries
      (business_id,branch_id,entry_date,account_code,account_name,account_type,debit,credit,
       description,source_table,source_id,entry_key,loan_id,created_by)
    values('BIZ-NYILORA',new.branch_id,v_date,'4020','Processing Fee Income','income',0,v_processing,
      'Processing fee received '||new.receipt_no,'loan_repayments',new.id::text,'processing_fee',new.loan_id,new.collected_by)
    on conflict (business_id,source_table,source_id,entry_key) do nothing;
  end if;
  if v_registration>0 then
    insert into public.nyilora_accounting_entries
      (business_id,branch_id,entry_date,account_code,account_name,account_type,debit,credit,
       description,source_table,source_id,entry_key,loan_id,created_by)
    values('BIZ-NYILORA',new.branch_id,v_date,'4030','Registration Fee Income','income',0,v_registration,
      'Registration fee received '||new.receipt_no,'loan_repayments',new.id::text,'registration_fee',new.loan_id,new.collected_by)
    on conflict (business_id,source_table,source_id,entry_key) do nothing;
  end if;
  if v_credit>0 then
    insert into public.nyilora_accounting_entries
      (business_id,branch_id,entry_date,account_code,account_name,account_type,debit,credit,
       description,source_table,source_id,entry_key,loan_id,created_by)
    values('BIZ-NYILORA',new.branch_id,v_date,'2100','Client Credit','liability',0,v_credit,
      'Client excess '||new.receipt_no,'loan_repayments',new.id::text,'client_credit',new.loan_id,new.collected_by)
    on conflict (business_id,source_table,source_id,entry_key) do nothing;
  end if;
  if v_unallocated>0 then
    insert into public.nyilora_accounting_entries
      (business_id,branch_id,entry_date,account_code,account_name,account_type,debit,credit,
       description,source_table,source_id,entry_key,loan_id,created_by)
    values('BIZ-NYILORA',new.branch_id,v_date,'2190','Unallocated Receipts','liability',0,v_unallocated,
      'Unallocated portion '||new.receipt_no,'loan_repayments',new.id::text,'unallocated',new.loan_id,new.collected_by)
    on conflict (business_id,source_table,source_id,entry_key) do nothing;
  end if;
  return new;
end $$;

drop trigger if exists nyilora_new_loan_journal_trg on public.loans;
create trigger nyilora_new_loan_journal_trg after insert on public.loans
  for each row execute function public.nyilora_post_new_loan_journal();
drop trigger if exists nyilora_new_repayment_journal_trg on public.loan_repayments;
create trigger nyilora_new_repayment_journal_trg after insert on public.loan_repayments
  for each row execute function public.nyilora_post_new_repayment_journal();

revoke all on function public.nyilora_post_new_loan_journal(),
  public.nyilora_post_new_repayment_journal() from public,anon,authenticated;
commit;
