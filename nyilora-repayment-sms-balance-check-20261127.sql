-- Run after 0040 in Nyilora's Supabase SQL Editor. Read only; no customer details.
select
  coalesce(business_id, 'ALL BUSINESSES') as business_id,
  count(*) filter (where message_type = 'repayment') as repayment_messages,
  count(*) filter (where message_type = 'repayment'
    and message like '%Balance: KES %') as repayment_messages_with_balance,
  count(*) filter (where message_type = 'repayment'
    and status in ('queued', 'failed', 'blocked_no_credit')
    and message not like '%Balance: KES %') as older_unsent_without_verified_balance,
  count(*) filter (where message_type = 'repayment' and status = 'sent') as repayment_messages_already_sent
from public.nyilora_sms_outbox
group by rollup (business_id)
order by business_id nulls last;
