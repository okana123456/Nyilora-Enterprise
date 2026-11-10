-- Read only. Run after migration 0037 in the Nyilora Supabase project.
with companies as (
  select distinct business_id from public.nyilora_branches
), allocations as (
  select a.business_id,count(*) as rows_applied,sum(a.amount) as amount_applied
  from public.nyilora_excess_allocations a
  join public.nyilora_charges c on c.id=a.charge_id
  where a.action='charge_payment' and c.charge_type='processing_fee'
    and a.note like 'Same-loan excess applied to outstanding processing fee%'
  group by a.business_id
), fees as (
  select c.business_id,sum(c.amount) as charged,sum(c.amount_paid) as paid,
    count(*) filter(where c.amount_paid>c.amount or c.amount_paid<0) as invalid_charges,
    count(*) filter(where l.id is not null and
      abs(coalesce(l.processing_fee_paid,0)-c.amount_paid)>0.01) as loan_fee_mismatches
  from public.nyilora_charges c left join public.loans l on l.id=c.loan_id
  where c.charge_type='processing_fee' group by c.business_id
), excess as (
  select business_id,sum(amount_available) as available_excess
  from public.nyilora_excess_ledger group by business_id
)
select co.business_id,coalesce(a.rows_applied,0) as same_loan_allocations,
  coalesce(a.amount_applied,0) as processing_fee_settled_from_excess,
  coalesce(f.charged,0) as processing_fees_charged,
  coalesce(f.paid,0) as processing_fees_paid,
  coalesce(e.available_excess,0) as excess_still_available,
  coalesce(f.invalid_charges,0) as invalid_charges,
  coalesce(f.loan_fee_mismatches,0) as loan_fee_mismatches
from companies co left join allocations a using(business_id)
left join fees f using(business_id) left join excess e using(business_id)
order by co.business_id;
