-- Nyilora only. Capture the credit portion of new repayments in the excess ledger.
-- No loan balance, schedule or repayment amount is changed by this script.
begin;

create or replace function public.nyilora_capture_repayment_excess()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_loan public.loans; v_source text; v_credit numeric(16,2);
begin
  v_credit:=round(coalesce(new.credit_portion,0),2);
  if v_credit<=0 then return new; end if;
  if v_credit>new.amount then raise exception 'Credit portion exceeds payment amount'; end if;
  select * into v_loan from public.loans where id=new.loan_id and business_id='BIZ-NYILORA';
  if v_loan.id is null or new.business_id<>'BIZ-NYILORA' or new.branch_id is distinct from v_loan.branch_id
    then raise exception 'Repayment and loan do not match Nyilora'; end if;
  v_source:=case
    when coalesce(new.notes,'') ilike '%matched from suspense%' then 'suspense_match'
    when lower(coalesce(new.payment_method,'')) in ('mpesa','m-pesa') and new.mpesa_confirmed then 'mpesa_callback'
    else 'manual_payment' end;
  insert into public.nyilora_excess_ledger
    (business_id,branch_id,client_id,loan_id,repayment_id,amount_original,amount_available,
     source,payment_reference,created_by,notes)
  values('BIZ-NYILORA',v_loan.branch_id,v_loan.client_id,v_loan.id,new.id,
    v_credit,v_credit,v_source,new.payment_reference,new.collected_by,
    'Excess from recorded repayment '||new.receipt_no)
  on conflict (repayment_id) do nothing;
  insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,entity_id,new_value)
  values(new.collected_by,'excess_captured','loan_repayments',new.id::text,
    jsonb_build_object('client_id',v_loan.client_id,'credit_amount',v_credit));
  return new;
end $$;

drop trigger if exists nyilora_capture_repayment_excess_trg on public.loan_repayments;
create trigger nyilora_capture_repayment_excess_trg
  after insert on public.loan_repayments for each row
  execute function public.nyilora_capture_repayment_excess();

create or replace function public.nyilora_refresh_client_credit()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_client_id uuid;
begin
  v_client_id:=case when tg_op='DELETE' then old.client_id else new.client_id end;
  update public.loan_clients c set account_credit=coalesce((
    select sum(e.amount_available) from public.nyilora_excess_ledger e
    where e.client_id=c.id and e.business_id='BIZ-NYILORA'
  ),0),updated_at=now()
  where c.id=v_client_id and c.business_id='BIZ-NYILORA';
  return null;
end $$;

drop trigger if exists nyilora_refresh_client_credit_trg on public.nyilora_excess_ledger;
create trigger nyilora_refresh_client_credit_trg
  after insert or update of amount_available or delete on public.nyilora_excess_ledger
  for each row execute function public.nyilora_refresh_client_credit();

revoke all on function public.nyilora_capture_repayment_excess(),
  public.nyilora_refresh_client_credit() from public,anon,authenticated;
commit;
