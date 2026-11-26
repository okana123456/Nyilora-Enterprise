-- Run once in Nyilora's Supabase SQL Editor after migration 0038.
-- Vault normally grants SELECT on vault.secrets, not UPDATE. SELECT FOR UPDATE
-- requires UPDATE permission, so use the existing transaction advisory lock.
begin;

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

revoke all on function public.nyilora_set_c2b_credentials(text,text,text)
  from public, anon, authenticated;
grant execute on function public.nyilora_set_c2b_credentials(text,text,text)
  to service_role;

notify pgrst, 'reload schema';
commit;
