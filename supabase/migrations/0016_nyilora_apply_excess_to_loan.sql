-- Nyilora only. Apply an existing client's available credit to their active loan.
-- Atomic operation: internal repayment, schedule, loan and excess ledger move together.
begin;

alter table public.nyilora_excess_allocations
  add column if not exists loan_id uuid references public.loans(id),
  add column if not exists repayment_id uuid references public.loan_repayments(id),
  add column if not exists request_id uuid;
create unique index if not exists nyilora_excess_allocation_request_once
  on public.nyilora_excess_allocations(request_id) where request_id is not null;

create or replace function public.nyilora_apply_excess_to_loan(
  p_excess_id uuid,p_loan_id uuid,p_amount numeric,p_note text,p_request_id uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_excess public.nyilora_excess_ledger; v_loan public.loans;
  v_previous public.nyilora_excess_allocations; v_sched record;
  v_amount numeric(16,2); v_remaining numeric(16,2); v_apply numeric(16,2);
  v_unpaid numeric(16,2); v_new_paid numeric(16,2); v_new_balance numeric(16,2);
  v_interest numeric(16,2); v_arrears numeric(16,2); v_oldest date;
  v_repayment uuid;
begin
  if public.nyilora_staff_id() is null or not public.nyilora_can_adjust_charges()
    then raise exception 'Charges & Excess permission required' using errcode='42501'; end if;
  if p_request_id is null then raise exception 'A unique transfer request is required'; end if;
  if p_amount is null or p_amount<=0 or round(p_amount,2)<>p_amount
    then raise exception 'Enter a positive amount with at most two decimal places'; end if;
  if nullif(trim(p_note),'') is null then raise exception 'Enter an approval reference or reason'; end if;
  perform pg_advisory_xact_lock(hashtext('nyilora_excess_'||p_excess_id::text));
  select * into v_previous from public.nyilora_excess_allocations
    where request_id=p_request_id and business_id='BIZ-NYILORA';
  if v_previous.id is not null then
    if v_previous.excess_id<>p_excess_id or v_previous.loan_id is distinct from p_loan_id
      or v_previous.amount<>p_amount then raise exception 'Request ID was used for a different transfer'; end if;
    return jsonb_build_object('ok',true,'already_recorded',true,'amount_applied',v_previous.amount,
      'repayment_id',v_previous.repayment_id);
  end if;
  select * into v_excess from public.nyilora_excess_ledger
    where id=p_excess_id and business_id='BIZ-NYILORA' for update;
  select * into v_loan from public.loans
    where id=p_loan_id and business_id='BIZ-NYILORA' for update;
  if v_excess.id is null or v_loan.id is null then raise exception 'Excess or loan not found'; end if;
  if v_excess.client_id<>v_loan.client_id or v_excess.branch_id<>v_loan.branch_id
    then raise exception 'Excess and loan must belong to the same client and branch'; end if;
  if v_loan.status<>'active' or v_loan.outstanding_balance<=0
    then raise exception 'Target loan is not active with an outstanding balance'; end if;
  if p_amount>v_excess.amount_available or p_amount>v_loan.outstanding_balance
    then raise exception 'Amount exceeds available credit or outstanding loan balance'; end if;
  select coalesce(sum(greatest(0,s.total_due-s.total_paid)),0) into v_unpaid
    from public.loan_schedules s where s.loan_id=p_loan_id and s.business_id='BIZ-NYILORA';
  if v_unpaid<p_amount then raise exception 'Unpaid installments cannot cover this credit; review the schedule'; end if;
  v_amount:=round(p_amount,2);
  v_interest:=case when v_loan.total_payable>0 and v_loan.total_interest>0
    then round(v_amount*v_loan.total_interest/v_loan.total_payable,2) else 0 end;
  v_interest:=least(v_interest,v_amount);
  insert into public.loan_repayments
    (business_id,branch_id,loan_id,receipt_no,amount,payment_method,payment_reference,
     payment_date,principal_portion,interest_portion,loan_portion,credit_portion,
     collected_by,notes)
  values('BIZ-NYILORA',v_loan.branch_id,v_loan.id,
    'EXC-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,16)),v_amount,
    'client_excess','EXCESS-'||p_request_id::text,now(),v_amount-v_interest,v_interest,v_amount,0,
    public.nyilora_staff_id(),'Applied existing client credit: '||left(trim(p_note),1000))
  returning id into v_repayment;
  v_remaining:=v_amount;
  for v_sched in select s.* from public.loan_schedules s
    where s.loan_id=v_loan.id and s.business_id='BIZ-NYILORA'
      and s.total_due>s.total_paid
    order by s.due_date,s.installment_no for update loop
    exit when v_remaining<=0;
    v_apply:=least(v_remaining,greatest(0,v_sched.total_due-v_sched.total_paid));
    if v_apply<=0 then continue; end if;
    v_new_paid:=round(v_sched.total_paid+v_apply,2);
    update public.loan_schedules set total_paid=v_new_paid,
      status=case when v_new_paid>=total_due-0.01 then 'paid'
        when due_date<current_date then 'overdue' else 'partial' end,
      paid_at=case when v_new_paid>=total_due-0.01 then now() else null end,
      updated_at=now()
    where id=v_sched.id;
    v_remaining:=round(v_remaining-v_apply,2);
  end loop;
  if v_remaining<>0 then raise exception 'Installment allocation incomplete; all changes rolled back'; end if;
  v_new_balance:=round(v_loan.outstanding_balance-v_amount,2);
  select coalesce(sum(greatest(0,s.total_due-s.total_paid)),0),min(s.due_date)
    into v_arrears,v_oldest from public.loan_schedules s
    where s.loan_id=v_loan.id and s.due_date<current_date and s.total_due>s.total_paid;
  update public.loans set total_paid=round(coalesce(total_paid,0)+v_amount,2),
    outstanding_balance=v_new_balance,
    status=case when v_new_balance<=0 then 'completed' else status end,
    arrears_amount=case when v_new_balance<=0 then 0 else least(v_new_balance,v_arrears) end,
    overdue_days=case when v_new_balance<=0 or v_oldest is null then 0 else current_date-v_oldest end,
    updated_at=now()
  where id=v_loan.id;
  update public.nyilora_excess_ledger set amount_available=round(amount_available-v_amount,2),
    status=case when amount_available-v_amount<=0 then 'applied' else 'partially_used' end,
    resolved_at=case when amount_available-v_amount<=0 then now() else null end,
    resolved_by=case when amount_available-v_amount<=0 then public.nyilora_staff_id() else null end,
    resolution_note=left(trim(p_note),1000),updated_at=now()
  where id=v_excess.id;
  insert into public.nyilora_excess_allocations
    (excess_id,loan_id,repayment_id,request_id,action,amount,note,created_by)
  values(v_excess.id,v_loan.id,v_repayment,p_request_id,'loan_payment',v_amount,
    left(trim(p_note),1000),public.nyilora_staff_id());
  insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,entity_id,new_value)
  values(public.nyilora_staff_id(),'excess_applied_to_loan','nyilora_excess_ledger',v_excess.id::text,
    jsonb_build_object('loan_id',v_loan.id,'repayment_id',v_repayment,'amount',v_amount,
      'request_id',p_request_id,'reason',left(trim(p_note),1000)));
  return jsonb_build_object('ok',true,'amount_applied',v_amount,
    'loan_balance',v_new_balance,'repayment_id',v_repayment);
end $$;

revoke all on function public.nyilora_apply_excess_to_loan(uuid,uuid,numeric,text,uuid) from public,anon;
grant execute on function public.nyilora_apply_excess_to_loan(uuid,uuid,numeric,text,uuid) to authenticated;
notify pgrst,'reload schema';
commit;
