-- Run once in Nyilora's Supabase SQL Editor after TalkSasa has approved NYILORA.
-- This changes only the SMS sender shown and queued for Nyilora Enterprise.
do $$
begin
  if not exists (
    select 1 from public.nyilora_sms_wallets
    where business_id = 'BIZ-A1C8E7FBD382'
  ) then
    raise exception 'Nyilora Enterprise SMS wallet was not found; no changes made';
  end if;

  update public.nyilora_sms_wallets
  set sender_id = 'NYILORA', updated_at = now()
  where business_id = 'BIZ-A1C8E7FBD382';

  update public.nyilora_sms_outbox
  set sender_id = 'NYILORA'
  where business_id = 'BIZ-A1C8E7FBD382'
    and status in ('queued', 'failed', 'blocked_no_credit');
end $$;

select business_id, sender_id, credits_remaining
from public.nyilora_sms_wallets
where business_id = 'BIZ-A1C8E7FBD382';
