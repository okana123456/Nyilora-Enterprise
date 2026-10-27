-- Nyilora only. One rollover per loan, preserving prior schedule rows.
begin;

create unique index if not exists nyilora_one_rollover_penalty_per_loan
  on public.loan_penalties(loan_id)
  where lower(coalesce(reason,'')) like '%rollover%';

create or replace function public.nyilora_apply_my_rollover_penalties()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_actor public.loan_staff; v_loan public.loans; v_today date;
  v_pct numeric; v_penalty numeric(16,2); v_new_balance numeric(16,2);
  v_first numeric(16,2); v_last numeric(16,2); v_base integer;
  v_new integer:=0; v_arrears integer:=0;
begin
  v_actor:=public.nyilora_current_staff();
  if v_actor.id is null or not (public.nyilora_has_role('admin')
    or public.nyilora_has_role('branch_manager') or public.nyilora_has_role('loan_officer')) then
    raise exception 'Active Nyilora staff account required' using errcode='42501'; end if;
  v_today:=(now() at time zone 'Africa/Nairobi')::date;
  select coalesce(nullif(default_late_penalty_pct,0),15) into v_pct
    from public.loan_settings where business_id='BIZ-NYILORA';
  v_pct:=coalesce(v_pct,15);
  if v_pct<=0 or v_pct>100 then raise exception 'Invalid rollover penalty percentage'; end if;
  for v_loan in select l.* from public.loans l
    where l.business_id='BIZ-NYILORA' and l.status='active'
      and l.maturity_date is not null and v_today>l.maturity_date+2
      and l.outstanding_balance>0
      and (public.nyilora_has_role('admin')
        or public.nyilora_has_role('branch_manager')
        or l.loan_officer_id=v_actor.id)
    order by l.id for update of l
  loop
    if v_loan.rollover_applied or exists(select 1 from public.loan_penalties p
      where p.loan_id=v_loan.id and lower(coalesce(p.reason,'')) like '%rollover%') then
      update public.loans set rollover_applied=true,
        arrears_amount=least(outstanding_balance,round(v_loan.outstanding_balance,2)),
        overdue_days=greatest(0,v_today-v_loan.maturity_date),updated_at=now()
      where id=v_loan.id;
      v_arrears:=v_arrears+1;
      continue;
    end if;
    v_penalty:=round(v_loan.outstanding_balance*v_pct/100,2);
    if v_penalty<=0 then continue; end if;
    v_new_balance:=round(v_loan.outstanding_balance+v_penalty,2);
    v_first:=round(v_new_balance/3,2);
    v_last:=round(v_new_balance-2*v_first,2);
    select coalesce(max(installment_no),0) into v_base from public.loan_schedules
      where loan_id=v_loan.id;
    insert into public.loan_penalties(branch_id,loan_id,penalty_amount,date_charged,reason)
    values(v_loan.branch_id,v_loan.id,v_penalty,v_today,
      'Rollover Penalty ('||v_pct||'%) - '||v_today);
    insert into public.nyilora_charges(branch_id,client_id,loan_id,charge_type,
      description,amount,source,charge_date,created_by)
    values(v_loan.branch_id,v_loan.client_id,v_loan.id,'penalty',
      'One-time rollover penalty for loan '||v_loan.loan_no,
      v_penalty,'system',v_today,v_actor.id);
    -- Historical paid and partial schedule rows are retained. Unpaid rows are
    -- marked superseded so they no longer count as future dues.
    update public.loan_schedules set status='superseded',updated_at=now()
      where loan_id=v_loan.id and status in ('pending','partial','overdue');
    insert into public.loan_schedules(branch_id,loan_id,installment_no,due_date,
      principal_due,interest_due,total_due,status)
    values
      (v_loan.branch_id,v_loan.id,v_base+1,v_today+7,v_first,0,v_first,'pending'),
      (v_loan.branch_id,v_loan.id,v_base+2,v_today+14,v_first,0,v_first,'pending'),
      (v_loan.branch_id,v_loan.id,v_base+3,v_today+21,v_last,0,v_last,'pending');
    update public.loans set outstanding_balance=v_new_balance,
      total_payable=round(total_payable+v_penalty,2),
      weekly_installment=v_first,maturity_date=v_today+21,
      arrears_amount=0,overdue_days=0,rollover_applied=true,
      penalty_applied=true,updated_at=now() where id=v_loan.id;
    insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,entity_id,new_value)
    values(v_actor.id,'one_time_rollover','loans',v_loan.id::text,
      jsonb_build_object('penalty',v_penalty,'date',v_today,'new_balance',v_new_balance));
    v_new:=v_new+1;
  end loop;
  return jsonb_build_object('ok',true,'new_rollovers',v_new,
    'existing_rollovers_moved_to_arrears',v_arrears);
end $$;

-- Charge accrual already recognized penalty income and a receivable. When a
-- repayment later allocates to that charge, reverse its cash-basis income
-- posting and clear the receivable. This prevents recording income twice.
create or replace function public.nyilora_reconcile_paid_rollover_penalty()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_charge public.nyilora_charges; v_apply numeric(16,2);
begin
  if new.business_id<>'BIZ-NYILORA' or coalesce(new.penalty_portion,0)<=0 then return new; end if;
  select * into v_charge from public.nyilora_charges c
    where c.business_id='BIZ-NYILORA' and c.loan_id=new.loan_id
      and c.charge_type='penalty' and c.source='system'
      and c.status in ('pending','partially_paid')
    order by c.charge_date,c.id limit 1 for update;
  if v_charge.id is null then return new; end if;
  v_apply:=least(round(new.penalty_portion,2),round(v_charge.amount-v_charge.amount_paid,2));
  if v_apply<=0 then return new; end if;
  update public.nyilora_charges set amount_paid=amount_paid+v_apply,
    status=case when amount_paid+v_apply>=amount then 'paid' else 'partially_paid' end,
    settled_at=case when amount_paid+v_apply>=amount then now() else null end,
    updated_at=now() where id=v_charge.id;
  insert into public.nyilora_accounting_entries(branch_id,entry_date,account_code,
    account_name,account_type,debit,credit,description,source_table,source_id,
    entry_key,loan_id,created_by)
  values
    (new.branch_id,(new.payment_date at time zone 'Africa/Nairobi')::date,
      '4010','Penalty Income','income',v_apply,0,
      'Accrued penalty collected '||new.receipt_no,'loan_repayments',new.id::text,
      'accrued_penalty_income_reversal',new.loan_id,new.collected_by),
    (new.branch_id,(new.payment_date at time zone 'Africa/Nairobi')::date,
      '1150','Client Charges Receivable','asset',0,v_apply,
      'Accrued penalty collected '||new.receipt_no,'loan_repayments',new.id::text,
      'accrued_penalty_receivable',new.loan_id,new.collected_by)
  on conflict (business_id,source_table,source_id,entry_key) do nothing;
  return new;
end $$;
drop trigger if exists nyilora_reconcile_paid_rollover_penalty_trg on public.loan_repayments;
create trigger nyilora_reconcile_paid_rollover_penalty_trg after insert on public.loan_repayments
  for each row execute function public.nyilora_reconcile_paid_rollover_penalty();

revoke all on function public.nyilora_reconcile_paid_rollover_penalty(),
  public.nyilora_apply_my_rollover_penalties() from public,anon;
grant execute on function public.nyilora_apply_my_rollover_penalties() to authenticated;
notify pgrst,'reload schema';
commit;
