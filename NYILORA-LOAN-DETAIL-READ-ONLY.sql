-- Run in the NYILORA Supabase project. Read only, all companies.
-- Use this to review each existing loan before assigning products or correcting interest.
with repayments as (
  select loan_id,count(*) as payment_count,sum(amount) as paid_cash,
         sum(coalesce(loan_portion,amount)) as paid_to_loan
  from public.loan_repayments group by loan_id
), schedules as (
  select loan_id,count(*) as schedule_count,
         sum(total_due) as scheduled_total,
         sum(total_paid) as scheduled_paid,
         sum(interest_due) as scheduled_interest
  from public.loan_schedules group by loan_id
)
select l.business_id,l.loan_no,l.id as loan_id,l.application_id,
       l.status,l.principal_amount,l.disbursed_amount,l.interest_rate,
       l.interest_type,l.term_weeks,l.total_interest,l.total_payable,
       l.total_paid,l.outstanding_balance,l.processing_fee,
       coalesce(r.payment_count,0) as payment_count,
       coalesce(r.paid_cash,0) as recorded_payment_cash,
       coalesce(r.paid_to_loan,0) as recorded_payment_to_loan,
       coalesce(s.schedule_count,0) as schedule_count,
       coalesce(s.scheduled_total,0) as scheduled_total,
       coalesce(s.scheduled_paid,0) as scheduled_paid,
       coalesce(s.scheduled_interest,0) as scheduled_interest,
       case when coalesce(l.interest_type,'flat')='flat' then
         round(l.principal_amount*l.interest_rate*l.term_weeks/100,2)
       else null end as flat_interest_from_saved_rate,
       case when coalesce(l.interest_type,'flat')='flat' then
         round(l.total_interest-l.principal_amount*l.interest_rate*l.term_weeks/100,2)
       else null end as interest_difference
from public.loans l
left join repayments r on r.loan_id=l.id
left join schedules s on s.loan_id=l.id
order by l.business_id,l.disbursement_date,l.loan_no;
