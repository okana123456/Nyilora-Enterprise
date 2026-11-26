-- Read-only: run in the NYILORA Supabase SQL Editor.
-- No phone numbers, receipt codes, callback URLs, or secrets are returned.
select
  r.id as request_id,
  r.created_at at time zone 'Africa/Nairobi' as requested_at_kenya,
  r.business_id,
  r.status,
  r.credits,
  r.amount as expected_kes,
  r.checkout_request_id is not null as checkout_saved,
  r.result_code,
  r.result_description,
  r.provider_response ? 'Body' as callback_reached_database,
  r.paid_at is not null as payment_marked_paid,
  r.credited_at is not null as credits_marked_issued,
  exists (
    select 1 from public.nyilora_sms_topups t
    where t.business_id = r.business_id
      and (
        (r.checkout_request_id is not null and upper(t.reference) = upper(r.checkout_request_id))
        or (r.payment_reference is not null and upper(t.reference) = upper(r.payment_reference))
      )
  ) as matching_topup_exists,
  w.credits_purchased,
  w.credits_remaining
from public.nyilora_sms_bundle_requests r
left join public.nyilora_sms_wallets w on w.business_id = r.business_id
where r.business_id = 'BIZ-A1C8E7FBD382'
order by r.created_at desc
limit 10;
