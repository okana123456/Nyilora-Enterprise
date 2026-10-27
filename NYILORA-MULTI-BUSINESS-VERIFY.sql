-- Read only. Run in the Nyilora Supabase SQL Editor after the update.
-- A company appears after its administrator completes Sign Up with the setup key.
select 'branches' as source,business_id,count(*)::numeric as rows,null::numeric as amount
from public.nyilora_branches group by business_id
union all
select 'staff',business_id,count(*),null from public.loan_staff group by business_id
union all
select 'clients',business_id,count(*),null from public.loan_clients group by business_id
union all
select 'loans',business_id,count(*),coalesce(sum(outstanding_balance),0)
from public.loans group by business_id
union all
select 'repayments',business_id,count(*),coalesce(sum(amount),0)
from public.loan_repayments group by business_id
union all
select 'accounting',business_id,count(*),coalesce(sum(debit-credit),0)
from public.nyilora_accounting_entries group by business_id
union all
select 'sms_wallet',business_id,count(*),coalesce(sum(credits_remaining),0)
from public.nyilora_sms_wallets group by business_id
order by business_id,source;

select 'staff_without_own_branch' as check_name,count(*) as failures
from public.loan_staff s left join public.nyilora_branches b
  on b.id=s.branch_id and b.business_id=s.business_id where b.id is null
union all
select 'clients_without_own_branch',count(*)
from public.loan_clients c left join public.nyilora_branches b
  on b.id=c.branch_id and b.business_id=c.business_id where b.id is null
union all
select 'loans_with_other_business_client',count(*)
from public.loans l join public.loan_clients c on c.id=l.client_id
  where c.business_id<>l.business_id
union all
select 'repayments_with_other_business_loan',count(*)
from public.loan_repayments r join public.loans l on l.id=r.loan_id
  where l.business_id<>r.business_id
union all
select 'duplicate_paybill_businesses',count(*)
from (select regexp_replace(mpesa_shortcode,'\D','','g') as paybill
  from public.loan_settings where nullif(regexp_replace(mpesa_shortcode,'\D','','g'),'') is not null
  group by 1 having count(*)>1) duplicates;
