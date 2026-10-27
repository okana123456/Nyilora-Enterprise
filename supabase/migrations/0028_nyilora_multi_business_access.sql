-- Replace the original Nyilora-only SQL rules with authenticated company scope.
-- Run only after 0027. No lending or financial rows are modified.
begin;

create or replace function public.nyilora_business_branch_id()
returns uuid language sql stable security definer set search_path=public as $$
  select id from public.nyilora_branches
  where business_id=public.nyilora_business_context() limit 1
$$;
revoke all on function public.nyilora_business_branch_id() from public,anon;
grant execute on function public.nyilora_business_branch_id() to authenticated,service_role;

-- Recompile existing Nyilora functions with the caller/row business context.
-- The legacy first-admin function remains restricted to the original business.
do $$ declare r record; v_definition text; begin
  for r in select p.oid,p.proname,pg_get_functiondef(p.oid) as definition
    from pg_proc p join pg_namespace n on n.oid=p.pronamespace
    where n.nspname='public' and p.prokind='f'
      and p.proname not in ('nyilora_claim_first_admin','nyilora_register_business_admin',
        'nyilora_can_access_profile_photo_path','nyilora_can_access_document_path')
      and (pg_get_functiondef(p.oid) like '%''BIZ-NYILORA''%'
        or pg_get_functiondef(p.oid) like '%''00000000-0000-4000-8000-000000000001''%')
  loop
    v_definition:=replace(r.definition,'''BIZ-NYILORA''','public.nyilora_business_context()');
    v_definition:=replace(v_definition,'''00000000-0000-4000-8000-000000000001''',
      'public.nyilora_business_branch_id()');
    execute v_definition;
  end loop;
end $$;

-- A policy may have multiple foreign keys or no explicit company condition.
-- Rebuild its original role logic, then add a universal restrictive boundary.
do $$ declare r record; v_using text; v_check text; v_sql text; begin
  for r in select * from pg_policies
    where schemaname='public' and tablename in
      (select table_name from information_schema.columns
       where table_schema='public' and column_name='business_id')
      and (coalesce(qual,'') like '%BIZ-NYILORA%'
        or coalesce(with_check,'') like '%BIZ-NYILORA%'
        or coalesce(qual,'') like '%00000000-0000-4000-8000-000000000001%'
        or coalesce(with_check,'') like '%00000000-0000-4000-8000-000000000001%')
  loop
    v_using:=replace(replace(r.qual,'''BIZ-NYILORA''',
      'public.nyilora_current_business_id()'),
      '''00000000-0000-4000-8000-000000000001''',
      'public.nyilora_current_branch_id()');
    v_check:=replace(replace(r.with_check,'''BIZ-NYILORA''',
      'public.nyilora_current_business_id()'),
      '''00000000-0000-4000-8000-000000000001''',
      'public.nyilora_current_branch_id()');
    execute format('drop policy %I on public.%I',r.policyname,r.tablename);
    v_sql:=format('create policy %I on public.%I as %s for %s to %s',
      r.policyname,r.tablename,lower(r.permissive),lower(r.cmd),
      array_to_string(r.roles,','));
    if v_using is not null then v_sql:=v_sql||' using ('||v_using||')'; end if;
    if v_check is not null then v_sql:=v_sql||' with check ('||v_check||')'; end if;
    execute v_sql;
  end loop;
end $$;

do $$ declare t record; begin
  for t in select table_name from information_schema.columns
    where table_schema='public' and column_name='business_id'
      and table_name in (select tablename from pg_tables where schemaname='public')
  loop
    execute format('alter table public.%I enable row level security',t.table_name);
    execute format('drop policy if exists nyilora_tenant_boundary on public.%I',t.table_name);
    execute format('create policy nyilora_tenant_boundary on public.%I as restrictive for all to authenticated using (business_id=public.nyilora_current_business_id()) with check (business_id=public.nyilora_current_business_id())',t.table_name);
  end loop;
end $$;

-- Profile photos and onboarding documents use the company ID as the first
-- storage path segment. Keep their exact path shape and permission checks.
create or replace function public.nyilora_can_access_profile_photo_path(p_path text)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare v_business text; v_client uuid;
begin
  v_business:=public.nyilora_current_business_id();
  if v_business is null or split_part(p_path,'/',1)<>v_business
    or p_path !~* '^BIZ-[A-Z0-9]+/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-[0-9]{13}\.jpg$'
    then return false; end if;
  v_client:=left(split_part(p_path,'/',2),36)::uuid;
  return public.nyilora_can_access_client_documents(v_client);
end $$;

create or replace function public.nyilora_can_access_document_path(p_path text)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare parts text[]; v_client uuid;
begin
  parts:=string_to_array(p_path,'/');
  if cardinality(parts)<>4 or parts[1]<>public.nyilora_current_business_id()
    or parts[2] !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or parts[3] not in ('client_passport','client_id_front','client_id_back',
      'guarantor_passport','guarantor_id_front','guarantor_id_back')
    or parts[4] !~* '^[0-9a-f-]+\.(jpg|png|webp|pdf)$'
    then return false; end if;
  v_client:=parts[2]::uuid;
  return public.nyilora_can_access_client_documents(v_client);
end $$;

notify pgrst,'reload schema';
commit;
