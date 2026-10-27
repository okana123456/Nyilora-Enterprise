-- Callbacks have no user session, so validate against their own business rows.
begin;

alter table public.nyilora_sms_bundle_requests
  add column if not exists branch_id uuid;
update public.nyilora_sms_bundle_requests r set branch_id=b.id
  from public.nyilora_branches b
  where r.branch_id is null and b.business_id=r.business_id and b.is_head_office;
alter table public.nyilora_sms_bundle_requests
  alter column branch_id set not null;
do $$ begin
  if not exists (select 1 from pg_constraint
    where conname='nyilora_sms_bundle_branch_business_fk'
      and conrelid='public.nyilora_sms_bundle_requests'::regclass) then
    alter table public.nyilora_sms_bundle_requests
      add constraint nyilora_sms_bundle_branch_business_fk
        foreign key (business_id,branch_id)
        references public.nyilora_branches(business_id,id);
  end if;
end $$;
drop trigger if exists aa_nyilora_tenant_guard on public.nyilora_sms_bundle_requests;
create trigger aa_nyilora_tenant_guard before insert or update
  on public.nyilora_sms_bundle_requests for each row
  execute function public.nyilora_guard_tenant_row();

create or replace function public.nyilora_check_subscription_cycle()
returns trigger language plpgsql set search_path=public as $$
begin
  if not exists(select 1 from public.nyilora_branches
      where business_id=new.business_id and is_head_office)
    or new.billing_month<date '2026-12-01'
    or date_trunc('month',new.billing_month)::date<>new.billing_month
    or new.amount<>3000 then
    raise exception 'Subscription is KES 3,000 per month from December 2026'; end if;
  if new.status='paid' and (new.actual_amount is null or new.actual_amount<3000
    or new.paid_at is null or new.paid_until is null) then
    raise exception 'A paid period requires a verified KES 3,000 payment'; end if;
  if tg_op='UPDATE' and old.status='paid' and
    (new.status<>'paid' or new.paid_until<old.paid_until) then
    raise exception 'Already-paid billing periods cannot be reopened or shortened'; end if;
  return new;
end $$;

create or replace function public.nyilora_check_sms_bundle_price()
returns trigger language plpgsql set search_path=public as $$
begin
  if not exists(select 1 from public.nyilora_branches
      where business_id=new.business_id and id=new.branch_id)
    or new.credits<=0 or new.amount<>round(new.credits*0.55,2) then
    raise exception 'SMS bundle price must be KES 0.55 per credit'; end if;
  if tg_op='UPDATE' and (new.credits<>old.credits or new.amount<>old.amount
    or new.business_id<>old.business_id) then
    raise exception 'SMS bundle quantity and price cannot change after request'; end if;
  return new;
end $$;

create or replace function public.nyilora_record_callback_charge_payment(
  p_business_id text,p_client_id uuid,p_loan_id uuid,p_charge_id uuid,
  p_amount numeric,p_payment_reference text,p_payment_date timestamptz,
  p_payer_name text default null,p_payer_phone text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_charge public.nyilora_charges; v_loan public.loans;
  v_existing uuid; v_paid numeric(16,2); v_excess numeric(16,2);
begin
  if p_business_id is null or p_amount is null or p_amount<=0
    or round(p_amount,2)<>p_amount or length(trim(coalesce(p_payment_reference,'')))<4
    then raise exception 'Invalid processing-fee callback'; end if;
  if auth.uid() is not null then raise exception 'Service authorization required'; end if;
  select r.id into v_existing from public.loan_repayments r
    where r.business_id=p_business_id and
      (upper(r.payment_reference)=upper(trim(p_payment_reference))
        or upper(r.receipt_no)=upper(trim(p_payment_reference))) limit 1;
  if v_existing is not null then
    return jsonb_build_object('ok',true,'duplicate',true,'repayment_id',v_existing); end if;
  select * into v_loan from public.loans
    where id=p_loan_id and business_id=p_business_id for update;
  select * into v_charge from public.nyilora_charges
    where id=p_charge_id and business_id=p_business_id for update;
  if v_loan.id is null or v_charge.id is null or v_loan.client_id<>p_client_id
    or v_charge.client_id<>p_client_id or v_charge.loan_id<>v_loan.id
    or v_charge.branch_id<>v_loan.branch_id or v_charge.charge_type<>'processing_fee'
    or v_charge.status not in ('pending','partially_paid') then
    raise exception 'Open processing fee does not match the loan'; end if;
  v_paid:=least(round(p_amount,2),round(v_charge.amount-v_charge.amount_paid,2));
  if v_paid<=0 then raise exception 'Processing fee is already paid'; end if;
  v_excess:=round(p_amount-v_paid,2);
  insert into public.loan_repayments(business_id,branch_id,loan_id,receipt_no,amount,
    payment_method,payment_reference,payment_date,sender_name,sender_phone,
    processing_fee_portion,credit_portion,mpesa_confirmed,notes)
  values(p_business_id,v_loan.branch_id,v_loan.id,upper(trim(p_payment_reference)),p_amount,
    'M-Pesa',upper(trim(p_payment_reference)),coalesce(p_payment_date,now()),
    nullif(trim(p_payer_name),''),nullif(trim(p_payer_phone),''),
    v_paid,v_excess,true,'Processing fee received from callback')
  returning id into v_existing;
  update public.nyilora_charges set amount_paid=amount_paid+v_paid,
    status=case when amount_paid+v_paid>=amount then 'paid' else 'partially_paid' end,
    settled_at=case when amount_paid+v_paid>=amount then coalesce(p_payment_date,now()) else null end,
    settlement_note='M-Pesa '||upper(trim(p_payment_reference)),updated_at=now()
  where id=v_charge.id;
  update public.loans set processing_fee_paid=least(processing_fee,
    coalesce(processing_fee_paid,0)+v_paid),updated_at=now() where id=v_loan.id;
  insert into public.nyilora_domain_audit(business_id,branch_id,action,
    entity_type,entity_id,new_value)
  values(p_business_id,v_loan.branch_id,'callback_processing_fee_paid',
    'loan_repayments',v_existing::text,
    jsonb_build_object('charge_id',v_charge.id,'paid',v_paid,
      'excess',v_excess,'reference',upper(trim(p_payment_reference))));
  return jsonb_build_object('ok',true,'repayment_id',v_existing,
    'processing_fee_paid',v_paid,'excess_recorded',v_excess,
    'loan_balance_unchanged',v_loan.outstanding_balance);
end $$;

revoke all on function public.nyilora_record_callback_charge_payment(
  text,uuid,uuid,uuid,numeric,text,timestamptz,text,text)
  from public,anon,authenticated;
grant execute on function public.nyilora_record_callback_charge_payment(
  text,uuid,uuid,uuid,numeric,text,timestamptz,text,text) to service_role;
notify pgrst,'reload schema';
commit;
