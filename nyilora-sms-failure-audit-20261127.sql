-- Nyilora Supabase SQL Editor. Read only. No recipients or message bodies.
select
  o.business_id,
  o.message_type,
  o.status,
  o.attempts,
  o.queued_at,
  nullif(o.sender_id, '') as sender_id,
  left(
    regexp_replace(
      regexp_replace(coalesce(o.provider_error, ''),
        '(\+?254|0)[0-9]{9}', '[phone]', 'g'),
      '[A-Za-z0-9_\-]{32,}', '[redacted]', 'g'),
    250) as provider_error_redacted,
  o.provider_response->>'status' as provider_status,
  o.provider_response->>'code' as provider_code,
  w.credits_remaining
from public.nyilora_sms_outbox o
left join public.nyilora_sms_wallets w on w.business_id=o.business_id
where o.status in ('failed', 'delivery_unknown')
order by o.queued_at desc
limit 15;
