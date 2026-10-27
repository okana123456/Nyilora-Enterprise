-- Service callbacks must select exactly one business before matching borrowers.
begin;

create or replace function public.nyilora_callback_phone_candidates(
  p_business_id text,p_account_reference text,p_transaction_code text)
returns table(id uuid,business_id text,full_name text,account_credit numeric)
language sql stable security definer set search_path=public as $$
  select c.id,c.business_id,c.full_name,c.account_credit
  from public.loan_clients c
  where c.business_id=p_business_id
    and length(regexp_replace(coalesce(p_account_reference,''),'\D','','g')) between 9 and 12
    and right(regexp_replace(coalesce(c.phone,''),'\D','','g'),9)=
        right(regexp_replace(coalesce(p_account_reference,''),'\D','','g'),9)
    and not exists(select 1 from public.loan_repayments r
      where r.business_id=p_business_id
        and (upper(r.payment_reference)=upper(p_transaction_code)
          or upper(r.receipt_no)=upper(p_transaction_code)))
  order by c.id limit 2
$$;
revoke all on function public.nyilora_callback_phone_candidates(text,text,text)
  from public,anon,authenticated;
grant execute on function public.nyilora_callback_phone_candidates(text,text,text)
  to service_role;

create unique index if not exists nyilora_one_business_per_paybill
  on public.loan_settings(regexp_replace(mpesa_shortcode,'\D','','g'))
  where nullif(regexp_replace(mpesa_shortcode,'\D','','g'),'') is not null;

create table if not exists public.nyilora_unrouted_callbacks (
  trans_id text primary key, shortcode text, account_reference text,
  amount numeric(16,2), raw_payload jsonb not null,
  reason text not null, received_at timestamptz not null default now()
);
alter table public.nyilora_unrouted_callbacks enable row level security;
revoke all on public.nyilora_unrouted_callbacks from anon,authenticated;
grant select,insert on public.nyilora_unrouted_callbacks to service_role;

notify pgrst,'reload schema';
commit;
