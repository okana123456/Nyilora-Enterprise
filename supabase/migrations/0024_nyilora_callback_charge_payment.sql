-- Nyilora only. Idempotent processing-fee callback settlement.
begin;

create or replace function public.nyilora_record_callback_charge_payment(
  p_business_id text,p_client_id uuid,p_loan_id uuid,p_charge_id uuid,
  p_amount numeric,p_payment_reference text,p_payment_date timestamptz,
  p_payer_name text default null,p_payer_phone text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_charge public.nyilora_charges; v_loan public.loans;
  v_existing uuid; v_paid numeric(16,2); v_excess numeric(16,2);
begin
  if p_business_id<>'BIZ-NYILORA' or p_amount is null or p_amount<=0
    or round(p_amount,2)<>p_amount or length(trim(coalesce(p_payment_reference,'')))<4
    then raise exception 'Invalid Nyilora processing-fee callback'; end if;
  select r.id into v_existing from public.loan_repayments r
    where r.business_id='BIZ-NYILORA' and
      (upper(r.payment_reference)=upper(trim(p_payment_reference))
        or upper(r.receipt_no)=upper(trim(p_payment_reference))) limit 1;
  if v_existing is not null then
    return jsonb_build_object('ok',true,'duplicate',true,'repayment_id',v_existing); end if;
  select * into v_loan from public.loans
    where id=p_loan_id and business_id='BIZ-NYILORA' for update;
  select * into v_charge from public.nyilora_charges
    where id=p_charge_id and business_id='BIZ-NYILORA' for update;
  if v_loan.id is null or v_charge.id is null or v_loan.client_id<>p_client_id
    or v_charge.client_id<>p_client_id or v_charge.loan_id<>v_loan.id
    or v_charge.branch_id<>v_loan.branch_id or v_charge.charge_type<>'processing_fee'
    or v_charge.status not in ('pending','partially_paid') then
    raise exception 'Open Nyilora processing fee does not match the loan'; end if;
  v_paid:=least(round(p_amount,2),round(v_charge.amount-v_charge.amount_paid,2));
  if v_paid<=0 then raise exception 'Processing fee is already paid'; end if;
  v_excess:=round(p_amount-v_paid,2);
  insert into public.loan_repayments(branch_id,loan_id,receipt_no,amount,
    payment_method,payment_reference,payment_date,sender_name,sender_phone,
    processing_fee_portion,credit_portion,mpesa_confirmed,notes)
  values(v_loan.branch_id,v_loan.id,upper(trim(p_payment_reference)),p_amount,
    'M-Pesa',upper(trim(p_payment_reference)),coalesce(p_payment_date,now()),
    nullif(trim(p_payer_name),''),nullif(trim(p_payer_phone),''),
    v_paid,v_excess,true,'Nyilora processing fee received from callback')
  returning id into v_existing;
  update public.nyilora_charges set amount_paid=amount_paid+v_paid,
    status=case when amount_paid+v_paid>=amount then 'paid' else 'partially_paid' end,
    settled_at=case when amount_paid+v_paid>=amount then coalesce(p_payment_date,now()) else null end,
    settlement_note='M-Pesa '||upper(trim(p_payment_reference)),updated_at=now()
  where id=v_charge.id;
  update public.loans set processing_fee_paid=least(processing_fee,
    coalesce(processing_fee_paid,0)+v_paid),updated_at=now() where id=v_loan.id;
  insert into public.nyilora_domain_audit(action,entity_type,entity_id,new_value)
  values('callback_processing_fee_paid','loan_repayments',v_existing::text,
    jsonb_build_object('charge_id',v_charge.id,'paid',v_paid,
      'excess',v_excess,'reference',upper(trim(p_payment_reference))));
  return jsonb_build_object('ok',true,'repayment_id',v_existing,
    'processing_fee_paid',v_paid,'excess_recorded',v_excess,
    'loan_balance_unchanged',v_loan.outstanding_balance);
end $$;

-- The system charge already posted fee income and a receivable. Offset the
-- cash-basis fee income from the repayment journal and clear the receivable.
create or replace function public.nyilora_reconcile_accrued_processing_fee()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_charge public.nyilora_charges; v_apply numeric(16,2);
begin
  if new.business_id<>'BIZ-NYILORA' or coalesce(new.processing_fee_portion,0)<=0
    then return new; end if;
  select * into v_charge from public.nyilora_charges c
    where c.business_id='BIZ-NYILORA' and c.loan_id=new.loan_id
      and c.charge_type='processing_fee' and c.source='system'
    limit 1;
  if v_charge.id is null then return new; end if;
  v_apply:=least(round(new.processing_fee_portion,2),v_charge.amount);
  insert into public.nyilora_accounting_entries(branch_id,entry_date,account_code,
    account_name,account_type,debit,credit,description,source_table,source_id,
    entry_key,loan_id,created_by)
  values
    (new.branch_id,(new.payment_date at time zone 'Africa/Nairobi')::date,
      '4020','Processing Fee Income','income',v_apply,0,
      'Accrued fee collected '||new.receipt_no,'loan_repayments',new.id::text,
      'accrued_fee_income_reversal',new.loan_id,new.collected_by),
    (new.branch_id,(new.payment_date at time zone 'Africa/Nairobi')::date,
      '1150','Client Charges Receivable','asset',0,v_apply,
      'Accrued fee collected '||new.receipt_no,'loan_repayments',new.id::text,
      'accrued_fee_receivable',new.loan_id,new.collected_by)
  on conflict (business_id,source_table,source_id,entry_key) do nothing;
  return new;
end $$;
drop trigger if exists nyilora_reconcile_accrued_processing_fee_trg on public.loan_repayments;
create trigger nyilora_reconcile_accrued_processing_fee_trg after insert on public.loan_repayments
  for each row execute function public.nyilora_reconcile_accrued_processing_fee();

revoke all on function public.nyilora_record_callback_charge_payment(
  text,uuid,uuid,uuid,numeric,text,timestamptz,text,text),
  public.nyilora_reconcile_accrued_processing_fee() from public,anon,authenticated;
grant execute on function public.nyilora_record_callback_charge_payment(
  text,uuid,uuid,uuid,numeric,text,timestamptz,text,text) to service_role;
notify pgrst,'reload schema';
commit;
