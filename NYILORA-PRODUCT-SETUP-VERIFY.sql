-- Run after migrations 0032, 0033 and 0034 in Nyilora Supabase. Read only.
with product_counts as (
  select b.business_id,count(p.id) as product_count
  from (select distinct business_id from public.nyilora_branches) b
  left join public.loan_products p on p.business_id=b.business_id
    and lower(regexp_replace(trim(p.name),'\s+',' ','g')) in
      ('boresha','kuza','super wima','wima')
  group by b.business_id
), loan_checks as (
  with schedule_totals as (
    select loan_id,sum(total_due) as total_due
    from public.loan_schedules group by loan_id
  )
  select l.business_id,count(*) as loan_count,
         count(*) filter (where l.product_id is null) as loans_without_product,
         count(*) filter (where p.id is not null and p.business_id<>l.business_id)
           as cross_company_product_links,
         count(*) filter (where p.id is not null and
           (l.principal_amount<p.min_amount or l.principal_amount>p.max_amount
             or l.term_weeks<p.min_term_weeks or l.term_weeks>p.max_term_weeks))
           as loans_outside_product_range,
         count(*) filter (where p.id is not null and l.interest_rate<>p.interest_rate)
           as product_rate_mismatches,
         count(*) filter (where coalesce(l.interest_type,'flat')='flat' and
           abs(l.total_interest-round(l.principal_amount*l.interest_rate*l.term_weeks/100,2))>0.02)
           as flat_interest_mismatches,
         count(*) filter (where s.loan_id is not null and
           abs(s.total_due-l.total_payable)>0.02)
           as schedule_total_mismatches
  from public.loans l left join public.loan_products p on p.id=l.product_id
  left join schedule_totals s on s.loan_id=l.id
  group by l.business_id
)
select p.business_id,p.product_count,
       coalesce(l.loan_count,0) as loans,
       coalesce(l.loans_without_product,0) as loans_without_product,
       coalesce(l.cross_company_product_links,0) as cross_company_product_links,
       coalesce(l.loans_outside_product_range,0) as loans_outside_product_range,
       coalesce(l.product_rate_mismatches,0) as product_rate_mismatches,
       coalesce(l.flat_interest_mismatches,0) as flat_interest_mismatches,
       coalesce(l.schedule_total_mismatches,0) as schedule_total_mismatches
from product_counts p left join loan_checks l on l.business_id=p.business_id
order by p.business_id;
