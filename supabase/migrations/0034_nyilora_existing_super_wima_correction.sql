-- Correct the one audited Nyilora loan from 0% to its unique Bripta-matched
-- Super Wima product. This is a contractual increase of KES 1,000.
-- Run only after 0032 and 0033, and after the borrower terms are confirmed.
begin;

do $$
declare
  v_loan public.loans;
  v_product public.loan_products;
  v_schedule_count integer;
  v_schedule_total numeric;
  v_schedule_paid numeric;
begin
  select * into v_product from public.loan_products
  where business_id='BIZ-A1C8E7FBD382'
    and lower(regexp_replace(trim(name),'\s+',' ','g'))='super wima';
  if v_product.id is null then raise exception 'Super Wima product is missing; run the product seed first'; end if;

  select * into v_loan from public.loans
  where id='c8073868-de4b-4ddf-953a-7830a9810f1e'::uuid
    and business_id='BIZ-A1C8E7FBD382'
    and loan_no='678423'
  for update;
  if v_loan.id is null then raise exception 'Audited loan 678423 was not found in its company'; end if;
  if v_loan.product_id=v_product.id and v_loan.interest_rate=6.25
    and v_loan.total_interest=1000 and v_loan.total_payable=5000
    and v_loan.outstanding_balance=5000 then return; end if;

  perform 1 from public.loan_schedules where loan_id=v_loan.id for update;
  select count(*),coalesce(sum(total_due),0),coalesce(sum(total_paid),0)
    into v_schedule_count,v_schedule_total,v_schedule_paid
  from public.loan_schedules where loan_id=v_loan.id;
  if v_loan.principal_amount<>4000 or v_loan.disbursed_amount<>4000
    or v_loan.interest_rate<>0 or v_loan.total_interest<>0
    or v_loan.total_payable<>4000 or v_loan.outstanding_balance<>4000
    or v_loan.total_paid<>0 or v_loan.term_weeks<>4
    or v_loan.processing_fee<>500 or v_loan.status<>'active'
    or v_loan.product_id is not null
    or v_schedule_count<>4 or v_schedule_total<>4000 or v_schedule_paid<>0
    or exists(select 1 from public.loan_repayments where loan_id=v_loan.id)
    or exists(select 1 from public.loan_penalties where loan_id=v_loan.id)
    or exists(select 1 from public.loan_schedules where loan_id=v_loan.id
       and (coalesce(interest_due,0)<>0 or coalesce(interest_paid,0)<>0
            or coalesce(principal_paid,0)<>0 or coalesce(penalty_charged,0)<>0))
  then raise exception 'Loan 678423 changed since review; no financial correction made'; end if;

  update public.loans set product_id=v_product.id,
    interest_rate=6.25,interest_type='flat',total_interest=1000,
    total_payable=5000,weekly_installment=1250,outstanding_balance=5000
  where id=v_loan.id and business_id=v_loan.business_id;

  update public.loan_schedules set principal_due=1000,interest_due=250,total_due=1250
  where loan_id=v_loan.id and business_id=v_loan.business_id;

  update public.loan_applications set product_id=v_product.id
  where id=v_loan.application_id and business_id=v_loan.business_id;

  insert into public.nyilora_domain_audit
    (business_id,branch_id,action,entity_type,entity_id,old_value,new_value)
  values(v_loan.business_id,v_loan.branch_id,'loan_product_interest_correction',
    'loans',v_loan.id::text,
    jsonb_build_object('loan_no',v_loan.loan_no,'interest_rate',0,
      'total_interest',0,'total_payable',4000,'outstanding_balance',4000),
    jsonb_build_object('loan_no',v_loan.loan_no,'product',v_product.name,
      'interest_rate',6.25,'total_interest',1000,'total_payable',5000,
      'outstanding_balance',5000,'reason','Audited Super Wima correction'));
end $$;

commit;

select l.business_id,l.loan_no,p.name as product,l.interest_rate,
       l.total_interest,l.total_payable,l.outstanding_balance,
       count(s.id) as installments,sum(s.total_due) as scheduled_total,
       sum(s.interest_due) as scheduled_interest
from public.loans l
join public.loan_products p on p.id=l.product_id
left join public.loan_schedules s on s.loan_id=l.id
where l.id='c8073868-de4b-4ddf-953a-7830a9810f1e'::uuid
group by l.business_id,l.loan_no,p.name,l.interest_rate,
         l.total_interest,l.total_payable,l.outstanding_balance;
