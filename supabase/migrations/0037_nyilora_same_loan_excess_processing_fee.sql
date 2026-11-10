-- Apply client excess only to an unpaid processing fee on the SAME loan.
-- Works for every Nyilora company. Repayments, loan balances and fee charges
-- remain unchanged. Existing accounting allocation triggers post the transfer.
begin;

create or replace function public.nyilora_apply_same_loan_processing_excess(p_excess_id uuid)
returns numeric language plpgsql security definer set search_path=public as $$
declare
  v_x public.nyilora_excess_ledger%rowtype;
  v_l public.loans%rowtype;
  v_c public.nyilora_charges%rowtype;
  v_r public.loan_repayments%rowtype;
  v_amount numeric(16,2);
  v_note text:='Same-loan excess applied to outstanding processing fee; original repayment preserved';
begin
  select * into v_x from public.nyilora_excess_ledger where id=p_excess_id for update;
  if v_x.id is null or v_x.amount_available<=0 or v_x.loan_id is null
    or v_x.repayment_id is null then return 0; end if;
  select * into v_l from public.loans where id=v_x.loan_id
    and business_id=v_x.business_id and branch_id=v_x.branch_id
    and client_id=v_x.client_id for update;
  if v_l.id is null then return 0; end if;
  select * into v_r from public.loan_repayments where id=v_x.repayment_id
    and loan_id=v_l.id and business_id=v_l.business_id
    and branch_id=v_l.branch_id for update;
  if v_r.id is null or coalesce(v_r.processing_fee_portion,0)>0
    or coalesce(v_r.loan_portion,0)<=0
    or abs(coalesce(v_r.credit_portion,0)-v_x.amount_original)>0.01
    or v_l.disbursement_date is null
    or (v_r.payment_date at time zone 'Africa/Nairobi')::date<v_l.disbursement_date
  then return 0; end if;
  select * into v_c from public.nyilora_charges
    where loan_id=v_l.id and client_id=v_l.client_id
      and business_id=v_l.business_id and branch_id=v_l.branch_id
      and charge_type='processing_fee' and source='system'
      and status in ('pending','partially_paid') and amount_paid<amount
    order by charge_date,id limit 1 for update;
  if v_c.id is null or abs(v_c.amount-v_l.processing_fee)>0.01
    or abs(v_c.amount_paid-coalesce(v_l.processing_fee_paid,0))>0.01
  then return 0; end if;
  v_amount:=least(v_x.amount_available,v_c.amount-v_c.amount_paid);
  if v_amount<=0 then return 0; end if;

  update public.nyilora_excess_ledger set amount_available=amount_available-v_amount,
    status=case when amount_available-v_amount=0 then 'applied' else 'partially_used' end,
    resolved_at=case when amount_available-v_amount=0 then now() else null end,
    resolution_note=v_note,updated_at=now() where id=v_x.id;
  update public.nyilora_charges set amount_paid=amount_paid+v_amount,
    status=case when amount_paid+v_amount=amount then 'paid' else 'partially_paid' end,
    settled_at=case when amount_paid+v_amount=amount then now() else null end,
    settlement_note=v_note,updated_at=now() where id=v_c.id;
  update public.loans set processing_fee_paid=coalesce(processing_fee_paid,0)+v_amount,
    updated_at=now() where id=v_l.id;
  insert into public.nyilora_excess_allocations
    (business_id,branch_id,excess_id,charge_id,action,amount,note,created_by)
  values(v_x.business_id,v_x.branch_id,v_x.id,v_c.id,'charge_payment',v_amount,
    v_note,v_x.created_by);
  insert into public.nyilora_domain_audit
    (business_id,branch_id,actor_staff_id,action,entity_type,entity_id,old_value,new_value)
  values(v_x.business_id,v_x.branch_id,v_x.created_by,
    'same_loan_excess_applied_to_processing_fee','nyilora_excess_ledger',v_x.id::text,
    jsonb_build_object('excess_available',v_x.amount_available,
      'fee_paid',v_c.amount_paid,'loan_fee_paid',v_l.processing_fee_paid),
    jsonb_build_object('charge_id',v_c.id,'loan_id',v_l.id,'amount_applied',v_amount,
      'excess_available',v_x.amount_available-v_amount,'fee_paid',v_c.amount_paid+v_amount));
  return v_amount;
end $$;

revoke all on function public.nyilora_apply_same_loan_processing_excess(uuid)
  from public,anon,authenticated;

-- Existing manual Excess & Charges allocations must also update the loan's
-- fee-paid display; the allocation journal already posts the accounting move.
create or replace function public.nyilora_sync_processing_fee_paid_from_allocation()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_c public.nyilora_charges%rowtype;
begin
  if new.action<>'charge_payment' or new.charge_id is null then return new; end if;
  select * into v_c from public.nyilora_charges where id=new.charge_id;
  if v_c.charge_type='processing_fee' and v_c.loan_id is not null
    and v_c.business_id=new.business_id and v_c.branch_id=new.branch_id then
    update public.loans set processing_fee_paid=least(processing_fee,
      greatest(coalesce(processing_fee_paid,0),v_c.amount_paid)),updated_at=now()
    where id=v_c.loan_id and business_id=v_c.business_id
      and branch_id=v_c.branch_id and client_id=v_c.client_id;
  end if;
  return new;
end $$;
drop trigger if exists nyilora_sync_processing_fee_paid_from_allocation
  on public.nyilora_excess_allocations;
create trigger nyilora_sync_processing_fee_paid_from_allocation
after insert on public.nyilora_excess_allocations for each row
execute function public.nyilora_sync_processing_fee_paid_from_allocation();

create or replace function public.nyilora_auto_apply_same_loan_processing_excess()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  perform public.nyilora_apply_same_loan_processing_excess(new.id);
  return new;
end $$;
drop trigger if exists nyilora_auto_apply_same_loan_processing_excess
  on public.nyilora_excess_ledger;
create trigger nyilora_auto_apply_same_loan_processing_excess
after insert on public.nyilora_excess_ledger for each row
execute function public.nyilora_auto_apply_same_loan_processing_excess();

-- Older excess rows are processed under row locks. Ambiguous records are skipped.
do $$ declare v_id uuid; begin
  for v_id in select id from public.nyilora_excess_ledger
    where amount_available>0 and loan_id is not null and repayment_id is not null
    order by created_at,id
  loop perform public.nyilora_apply_same_loan_processing_excess(v_id); end loop;
end $$;

commit;

select a.business_id,b.name as branch,count(*) as allocations,
  coalesce(sum(a.amount),0) as processing_fee_settled_from_excess,
  count(*) filter(where c.amount_paid>c.amount or l.processing_fee_paid>l.processing_fee)
    as overpaid_fee_errors
from public.nyilora_excess_allocations a
join public.nyilora_excess_ledger x on x.id=a.excess_id
join public.nyilora_charges c on c.id=a.charge_id
join public.loans l on l.id=c.loan_id
join public.nyilora_branches b on b.id=a.branch_id
where a.action='charge_payment' and c.charge_type='processing_fee'
  and a.note like 'Same-loan excess applied to outstanding processing fee%'
group by a.business_id,b.name order by a.business_id,b.name;
