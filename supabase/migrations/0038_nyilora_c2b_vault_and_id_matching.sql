-- Run in the Nyilora project only. Daraja credentials live in Supabase Vault,
-- never in loan_settings or browser-readable database rows.
begin;

create schema if not exists vault;
create extension if not exists supabase_vault with schema vault;

do $$
begin
  if not exists (select 1 from vault.secrets where name = 'nyilora.c2b.callback_token') then
    perform vault.create_secret(
      replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', ''),
      'nyilora.c2b.callback_token',
      'Private verification token for Nyilora Daraja C2B callbacks'
    );
  end if;
end $$;

create or replace function public.nyilora_set_c2b_credentials(
  p_business_id text, p_consumer_key text, p_consumer_secret text
)
returns void language plpgsql security definer set search_path = '' as $$
declare
  v_name text;
  v_value text;
  v_id uuid;
  v_kind text;
begin
  if not exists (select 1 from public.loan_settings where business_id = p_business_id) then
    raise exception 'Company settings were not found';
  end if;
  if length(trim(coalesce(p_consumer_key, ''))) < 5
     or length(p_consumer_key) > 512
     or length(trim(coalesce(p_consumer_secret, ''))) < 5
     or length(p_consumer_secret) > 512 then
    raise exception 'Enter a valid consumer key and secret';
  end if;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext('nyilora.c2b.' || p_business_id));

  foreach v_kind in array array['consumer_key', 'consumer_secret'] loop
    v_name := 'nyilora.c2b.' || p_business_id || '.' || v_kind;
    v_value := case when v_kind = 'consumer_key' then trim(p_consumer_key) else trim(p_consumer_secret) end;
    select id into v_id from vault.secrets where name = v_name;
    if v_id is null then
      perform vault.create_secret(v_value, v_name, 'Nyilora C2B ' || v_kind || ' for ' || p_business_id);
    else
      perform vault.update_secret(v_id, v_value);
    end if;
  end loop;
end $$;

create or replace function public.nyilora_get_c2b_credentials(p_business_id text)
returns jsonb language sql stable security definer set search_path = '' as $$
  select jsonb_build_object(
    'consumer_key', coalesce((select decrypted_secret from vault.decrypted_secrets
      where name = 'nyilora.c2b.' || p_business_id || '.consumer_key'), ''),
    'consumer_secret', coalesce((select decrypted_secret from vault.decrypted_secrets
      where name = 'nyilora.c2b.' || p_business_id || '.consumer_secret'), ''),
    'callback_token', coalesce((select decrypted_secret from vault.decrypted_secrets
      where name = 'nyilora.c2b.callback_token'), '')
  )
$$;

create or replace function public.nyilora_get_c2b_callback_token()
returns text language sql stable security definer set search_path = '' as $$
  select decrypted_secret from vault.decrypted_secrets
  where name = 'nyilora.c2b.callback_token'
$$;

create or replace function public.nyilora_c2b_credentials_saved(p_business_id text)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from vault.secrets where name = 'nyilora.c2b.' || p_business_id || '.consumer_key')
     and exists (select 1 from vault.secrets where name = 'nyilora.c2b.' || p_business_id || '.consumer_secret')
$$;

revoke all on function public.nyilora_set_c2b_credentials(text,text,text),
  public.nyilora_get_c2b_credentials(text), public.nyilora_get_c2b_callback_token(),
  public.nyilora_c2b_credentials_saved(text)
  from public, anon, authenticated;
grant execute on function public.nyilora_set_c2b_credentials(text,text,text),
  public.nyilora_get_c2b_credentials(text), public.nyilora_get_c2b_callback_token(),
  public.nyilora_c2b_credentials_saved(text)
  to service_role;

-- Match the Paybill account field to the client's registered national ID
-- within the company selected by the receiving Paybill. Two matches are
-- intentionally returned so the callback can hold ambiguous payments.
create or replace function public.nyilora_callback_id_candidates(
  p_business_id text, p_account_reference text, p_transaction_code text
)
returns table(id uuid, business_id text, full_name text, account_credit numeric)
language sql stable security definer set search_path = '' as $$
  select c.id, c.business_id, c.full_name, c.account_credit
  from public.loan_clients c
  where c.business_id = p_business_id
    and length(regexp_replace(coalesce(p_account_reference, ''), '[^0-9]', '', 'g')) between 5 and 20
    and regexp_replace(coalesce(c.id_number, ''), '[^0-9]', '', 'g') =
        regexp_replace(coalesce(p_account_reference, ''), '[^0-9]', '', 'g')
    and not exists (select 1 from public.loan_repayments r
      where r.business_id = p_business_id
        and (upper(r.payment_reference) = upper(p_transaction_code)
          or upper(r.receipt_no) = upper(p_transaction_code)))
  order by c.id limit 2
$$;
revoke all on function public.nyilora_callback_id_candidates(text,text,text)
  from public, anon, authenticated;
grant execute on function public.nyilora_callback_id_candidates(text,text,text)
  to service_role;

notify pgrst, 'reload schema';
commit;
