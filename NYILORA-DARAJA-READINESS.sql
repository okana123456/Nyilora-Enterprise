-- Read-only. Run in Nyilora's Supabase project sedzaagjqfsoxglcwyed.
-- Identify the actual company account before saving its Paybill and C2B key pair in Settings.
select s.business_id, s.company_name,
       s.mpesa_shortcode as saved_paybill,
       s.daraja_environment,
       s.mpesa_auto_confirm,
       (select count(*) from public.loan_staff t where t.business_id=s.business_id and t.is_active) as active_staff,
       (select count(*) from public.loan_clients c where c.business_id=s.business_id) as clients,
       (select count(*) from public.loans l where l.business_id=s.business_id) as loans,
       (select count(*) from public.mpesa_callback_queue q where q.business_id=s.business_id) as received_callbacks
from public.loan_settings s
order by s.company_name,s.business_id;

select indexname,
       indexdef like '%regexp_replace(mpesa_shortcode%' as unique_paybill_guard_present
from pg_indexes
where schemaname='public' and tablename='loan_settings'
  and indexname='nyilora_one_business_per_paybill';
