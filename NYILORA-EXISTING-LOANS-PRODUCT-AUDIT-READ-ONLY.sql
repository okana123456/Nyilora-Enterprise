-- Run in the NYILORA Supabase project. Read only, all Nyilora companies.
-- No borrower names, phone numbers or document data are returned.
with loans_by_terms as (
  select l.business_id,l.principal_amount,l.interest_rate,l.interest_type,
         l.term_weeks,l.status,
         count(*) as loan_count,
         count(*) filter (where r.loan_id is not null) as joined_repayment_rows,
         sum(l.total_interest) as recorded_interest_total,
         sum(l.outstanding_balance) as recorded_outstanding_total,
         count(*) filter (where abs(coalesce(l.total_interest,0)-
           round(coalesce(l.principal_amount,0)*coalesce(l.interest_rate,0)*coalesce(l.term_weeks,0)/100,2))>0.02
           and coalesce(l.interest_type,'flat')='flat') as flat_interest_mismatches
  from public.loans l
  left join (select distinct loan_id from public.loan_repayments) r on r.loan_id=l.id
  group by l.business_id,l.principal_amount,l.interest_rate,l.interest_type,l.term_weeks,l.status
), product_summary as (
  select p.business_id,
         jsonb_agg(jsonb_build_object('name',p.name,'min_amount',p.min_amount,
           'max_amount',p.max_amount,'rate',p.interest_rate,
           'interest_type',p.interest_type,'period',p.interest_period,
           'min_weeks',p.min_term_weeks,'max_weeks',p.max_term_weeks,
           'active',p.is_active) order by p.name) as products
  from public.loan_products p group by p.business_id
)
select 'company_products' as source,s.business_id,s.company_name as label,
       coalesce(p.products,'[]'::jsonb) as details
from public.loan_settings s left join product_summary p on p.business_id=s.business_id
union all
select 'loan_terms',l.business_id,
       concat('KES ',l.principal_amount,' | ',l.interest_rate,'% ',l.interest_type,
              ' | ',l.term_weeks,' weeks | ',l.status),
       jsonb_build_object('loans',l.loan_count,'loans_with_repayments',l.joined_repayment_rows,
         'recorded_interest_total',l.recorded_interest_total,
         'recorded_outstanding_total',l.recorded_outstanding_total,
         'flat_interest_mismatches',l.flat_interest_mismatches)
from loans_by_terms l
order by business_id,source,label;
