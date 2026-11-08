-- Atomic term extension for active, unpaid loans. Existing product choice stays linked.
-- Product term limits govern new issuance; an authorized restructure may exceed them.
create or replace function public.nyilora_restructure_loan_term(
  p_loan_id uuid, p_new_weeks integer, p_reason text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare
  v_actor public.loan_staff;
  v_loan public.loans;
  v_old jsonb;
  v_interest numeric(16,2);
  v_payable numeric(16,2);
  v_principal_piece numeric(16,2);
  v_interest_piece numeric(16,2);
  v_p numeric(16,2);
  v_i numeric(16,2);
  v_first date;
  v_count integer;
  v_due numeric(16,2);
  v_paid numeric(16,2);
  n integer;
begin
  if p_new_weeks is null or p_new_weeks<1 or p_new_weeks>52 then
    raise exception 'Choose a term between 1 and 52 weeks';
  end if;
  if length(trim(coalesce(p_reason,'')))<5 then
    raise exception 'Provide a reason of at least five characters';
  end if;
  v_actor:=public.nyilora_current_staff();
  if v_actor.id is null or not (
    'admin'=any(regexp_split_to_array(lower(coalesce(v_actor.role,'')),'\s*,\s*')) or
    'branch_manager'=any(regexp_split_to_array(lower(coalesce(v_actor.role,'')),'\s*,\s*'))
  ) then raise exception 'Only an administrator or branch manager may restructure a loan'; end if;
  select * into v_loan from public.loans
    where id=p_loan_id and business_id=v_actor.business_id
      and (branch_id=v_actor.branch_id or
        'admin'=any(regexp_split_to_array(lower(coalesce(v_actor.role,'')),'\s*,\s*')))
    for update;
  if v_loan.id is null then raise exception 'Loan not found in your branch'; end if;
  if v_loan.status<>'active' or v_loan.interest_type<>'flat' or v_loan.principal_amount<=0
    or v_loan.interest_rate<0 or v_loan.disbursement_date is null
  then raise exception 'This loan needs a manual review before restructuring'; end if;
  if v_loan.term_weeks=p_new_weeks then raise exception 'The new term matches the current term'; end if;
  perform 1 from public.loan_schedules where loan_id=p_loan_id for update;
  select count(*),coalesce(sum(total_due),0),coalesce(sum(total_paid),0)
    into v_count,v_due,v_paid from public.loan_schedules where loan_id=p_loan_id;
  if v_count<>v_loan.term_weeks or abs(v_due-v_loan.total_payable)>0.01
    or v_paid<>0 or v_loan.total_paid<>0
    or abs(v_loan.outstanding_balance-v_loan.total_payable)>0.01
    or exists(select 1 from public.loan_repayments where loan_id=p_loan_id)
    or exists(select 1 from public.loan_penalties where loan_id=p_loan_id)
    or exists(select 1 from public.loan_schedules where loan_id=p_loan_id
      and (principal_paid<>0 or interest_paid<>0 or penalty_charged<>0))
  then raise exception 'Payments, penalties or schedule changes exist; review this loan before restructuring'; end if;

  v_old:=jsonb_build_object('term_weeks',v_loan.term_weeks,'total_interest',v_loan.total_interest,
    'total_payable',v_loan.total_payable,'outstanding_balance',v_loan.outstanding_balance,
    'maturity_date',v_loan.maturity_date);
  v_interest:=round(v_loan.principal_amount*v_loan.interest_rate*p_new_weeks/100,2);
  v_payable:=v_loan.principal_amount+v_interest;
  v_principal_piece:=round(v_loan.principal_amount/p_new_weeks,2);
  v_interest_piece:=round(v_interest/p_new_weeks,2);
  v_first:=coalesce(v_loan.first_repayment_date,v_loan.disbursement_date+7);

  -- Remove surplus unpaid rows first; the loan lock serializes competing edits.
  delete from public.loan_schedules where loan_id=p_loan_id and installment_no>p_new_weeks;
  for n in 1..p_new_weeks loop
    v_p:=case when n=p_new_weeks then v_loan.principal_amount-v_principal_piece*(p_new_weeks-1)
      else v_principal_piece end;
    v_i:=case when n=p_new_weeks then v_interest-v_interest_piece*(p_new_weeks-1)
      else v_interest_piece end;
    insert into public.loan_schedules
      (business_id,branch_id,loan_id,installment_no,due_date,principal_due,interest_due,total_due,status)
    values(v_loan.business_id,v_loan.branch_id,p_loan_id,n,v_first+(n-1)*7,v_p,v_i,v_p+v_i,
      case when v_first+(n-1)*7<current_date then 'overdue' else 'pending' end)
    on conflict (loan_id,installment_no) do update
      set due_date=excluded.due_date,principal_due=excluded.principal_due,
          interest_due=excluded.interest_due,total_due=excluded.total_due,status=excluded.status;
  end loop;
  update public.loans set term_weeks=p_new_weeks,total_interest=v_interest,
    total_payable=v_payable,outstanding_balance=v_payable,
    weekly_installment=round(v_payable/p_new_weeks,2),
    first_repayment_date=v_first,maturity_date=v_first+(p_new_weeks-1)*7,
    arrears_amount=(select coalesce(sum(total_due),0) from public.loan_schedules
      where loan_id=p_loan_id and due_date<current_date),
    overdue_days=case when v_first<current_date then current_date-v_first else 0 end,
    updated_at=now()
  where id=p_loan_id;
  insert into public.nyilora_domain_audit
    (business_id,branch_id,actor_staff_id,action,entity_type,entity_id,old_value,new_value)
  values(v_loan.business_id,v_loan.branch_id,v_actor.id,'loan_term_restructured','loans',p_loan_id::text,
    v_old,jsonb_build_object('term_weeks',p_new_weeks,'total_interest',v_interest,
      'total_payable',v_payable,'outstanding_balance',v_payable,'reason',trim(p_reason),
      'actor_staff_id',v_actor.id));
  return jsonb_build_object('loan_id',p_loan_id,'term_weeks',p_new_weeks,
    'total_interest',v_interest,'total_payable',v_payable);
end $$;

revoke all on function public.nyilora_restructure_loan_term(uuid,integer,text) from public,anon;
grant execute on function public.nyilora_restructure_loan_term(uuid,integer,text) to authenticated;
