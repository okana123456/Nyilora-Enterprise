-- Run in the BRIPTA Supabase project, not Nyilora. Read only.
-- Copy the complete result back so the exact product definitions can be used.
select 'product' as source, p.business_id, p.name as label,
       jsonb_build_object(
         'id',p.id,'description',p.description,
         'min_amount',p.min_amount,'max_amount',p.max_amount,
         'interest_rate',p.interest_rate,'interest_type',p.interest_type,
         'interest_period',p.interest_period,
         'min_term_weeks',p.min_term_weeks,'max_term_weeks',p.max_term_weeks,
         'processing_fee_pct',p.processing_fee_pct,
         'late_penalty_pct',p.late_penalty_pct,
         'grace_period_days',p.grace_period_days,
         'requires_guarantor',p.requires_guarantor,'is_active',p.is_active
       ) as details
from public.loan_products p
where p.business_id='BIZ-B3F5E5D9'
union all
select 'rate_settings',s.business_id,'current_settings',
       jsonb_build_object(
         'standard_weekly_rate',s.standard_weekly_rate,
         'micro_weekly_rate',s.micro_weekly_rate,
         'micro_threshold',s.micro_threshold,
         'default_late_penalty_pct',s.default_late_penalty_pct,
         'default_grace_period',s.default_grace_period
       )
from public.loan_settings s
where s.business_id='BIZ-B3F5E5D9'
order by source,label;
