-- Nyilora only. Keep the agreed KES 3,000 subscription and KES 0.55 SMS
-- price authoritative in the database as well as the Edge Functions.
begin;

alter table public.loan_billing_cycles
  add column if not exists result_description text,
  add column if not exists actual_amount numeric(16,2);
alter table public.loan_billing_transactions
  add column if not exists result_code text,
  add column if not exists result_description text,
  add column if not exists raw_payload jsonb;

create or replace function public.nyilora_check_subscription_cycle()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.business_id<>'BIZ-NYILORA' or new.billing_month<date '2026-12-01'
    or date_trunc('month',new.billing_month)::date<>new.billing_month
    or new.amount<>3000 then
    raise exception 'Nyilora subscription is KES 3,000 per month from December 2026'; end if;
  if new.status='paid' and (new.actual_amount is null or new.actual_amount<3000
    or new.paid_at is null or new.paid_until is null) then
    raise exception 'A paid period requires a verified KES 3,000 payment'; end if;
  if tg_op='UPDATE' and old.status='paid' and
    (new.status<>'paid' or new.paid_until<old.paid_until) then
    raise exception 'Already-paid billing periods cannot be reopened or shortened'; end if;
  return new;
end $$;
drop trigger if exists nyilora_subscription_cycle_guard_trg on public.loan_billing_cycles;
create trigger nyilora_subscription_cycle_guard_trg before insert or update
  on public.loan_billing_cycles for each row
  execute function public.nyilora_check_subscription_cycle();

create or replace function public.nyilora_check_sms_bundle_price()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.business_id<>'BIZ-NYILORA' or new.credits<=0
    or new.amount<>round(new.credits*0.55,2) then
    raise exception 'Nyilora SMS bundle price must be KES 0.55 per credit'; end if;
  if tg_op='UPDATE' and (new.credits<>old.credits or new.amount<>old.amount
    or new.business_id<>old.business_id) then
    raise exception 'SMS bundle quantity and price cannot change after request'; end if;
  return new;
end $$;
drop trigger if exists nyilora_sms_bundle_price_guard_trg
  on public.nyilora_sms_bundle_requests;
create trigger nyilora_sms_bundle_price_guard_trg before insert or update
  on public.nyilora_sms_bundle_requests for each row
  execute function public.nyilora_check_sms_bundle_price();

revoke all on function public.nyilora_check_subscription_cycle(),
  public.nyilora_check_sms_bundle_price() from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
