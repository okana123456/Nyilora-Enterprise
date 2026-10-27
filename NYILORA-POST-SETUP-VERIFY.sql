-- Read-only Nyilora checks after NYILORA-FINAL-ADDITIONS-ONE-RUN.sql.
select 'business_branch' as check_name,
  coalesce((select business_id||' / '||name from public.nyilora_branches
    where business_id='BIZ-NYILORA' limit 1),'MISSING') as result
union all
select 'active_staff',count(*)::text from public.loan_staff
  where business_id='BIZ-NYILORA' and is_active
union all
select 'loan_clients',count(*)::text from public.loan_clients
  where business_id='BIZ-NYILORA'
union all
select 'loan_repayments',count(*)::text from public.loan_repayments
  where business_id='BIZ-NYILORA'
union all
select 'sms_balance',credits_remaining::text from public.nyilora_sms_wallets
  where business_id='BIZ-NYILORA'
union all
select 'required_functions_present',count(*)::text from pg_proc p
  join pg_namespace n on n.oid=p.pronamespace
  where n.nspname='public' and p.proname in (
    'nyilora_apply_my_rollover_penalties','nyilora_suspense_to_equity',
    'nyilora_callback_phone_candidates','nyilora_record_callback_charge_payment',
    'nyilora_claim_repayment_sms','nyilora_complete_repayment_sms',
    'nyilora_owner_add_sms_credits','nyilora_resolve_excess',
    'nyilora_settle_charge','nyilora_financial_statements')
union all
select 'asset_write_policies',count(*)::text from pg_policies
  where schemaname='public' and tablename='nyilora_assets'
    and cmd in ('INSERT','UPDATE')
union all
select 'subscription_december_price',
  coalesce((select amount::text from public.loan_billing_cycles
    where business_id='BIZ-NYILORA' and billing_month=date '2026-12-01'
    limit 1),'KES 3000 required when the first cycle is created')
order by check_name;
