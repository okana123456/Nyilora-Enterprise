-- Nyilora multi-business update. Run once in Nyilora's Supabase SQL Editor.
-- Includes migrations 0027 through 0031 in order. Safe to rerun.
-- Existing financial amounts and historical records are not updated.

-- BEGIN 0027_nyilora_multi_business_foundation.sql
-- Preparation for multiple isolated companies in this Supabase project.
-- Existing rows keep their business IDs, branch IDs and financial values.
begin;

create or replace function public.nyilora_current_staff()
returns public.loan_staff language sql stable security definer set search_path=public as $$
  select s from public.loan_staff s
  where s.auth_user_id=auth.uid() and s.is_active
  limit 1
$$;

create or replace function public.nyilora_current_business_id()
returns text language sql stable security definer set search_path=public as $$
  select (public.nyilora_current_staff()).business_id
$$;

create or replace function public.nyilora_current_branch_id()
returns uuid language sql stable security definer set search_path=public as $$
  select (public.nyilora_current_staff()).branch_id
$$;

revoke all on function public.nyilora_current_business_id(),public.nyilora_current_branch_id()
  from public,anon;
grant execute on function public.nyilora_current_business_id(),public.nyilora_current_branch_id()
  to authenticated;

-- Remove only the original single-company and single-branch checks.
do $$ declare c record; begin
  for c in select conrelid::regclass as tbl,conname
    from pg_constraint
    where contype='c' and connamespace='public'::regnamespace
      and (pg_get_constraintdef(oid) like '%BIZ-NYILORA%'
        or pg_get_constraintdef(oid) like '%00000000-0000-4000-8000-000000000001%')
  loop execute format('alter table %s drop constraint %I',c.tbl,c.conname); end loop;
end $$;

-- A browser insert takes its company and branch from the authenticated user.
-- Server inserts supply both explicitly or derive the company from the branch.
do $$ declare t record; begin
  for t in select table_name from information_schema.columns
    where table_schema='public' and column_name='business_id'
      and table_name in (select tablename from pg_tables where schemaname='public')
  loop
    execute format('alter table public.%I alter column business_id set default public.nyilora_current_business_id()',t.table_name);
  end loop;
  for t in select table_name from information_schema.columns
    where table_schema='public' and column_name='branch_id'
      and table_name in (select tablename from pg_tables where schemaname='public')
  loop
    execute format('alter table public.%I alter column branch_id set default public.nyilora_current_branch_id()',t.table_name);
  end loop;
end $$;

-- The guard runs before the existing financial and messaging triggers.
create or replace function public.nyilora_guard_tenant_row()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_business text; v_actor_business text;
begin
  select b.business_id into v_business from public.nyilora_branches b where b.id=new.branch_id;
  if v_business is null then raise exception 'Assigned branch does not exist'; end if;
  if new.business_id is null then new.business_id:=v_business; end if;
  if new.business_id<>v_business then raise exception 'Branch belongs to another business'; end if;
  v_actor_business:=public.nyilora_current_business_id();
  if auth.uid() is not null and (v_actor_business is null or v_actor_business<>new.business_id) then
    raise exception 'Cannot write another business''s records'; end if;
  perform set_config('nyilora.row_business_id',new.business_id,true);
  return new;
end $$;

do $$ declare t record; begin
  for t in select a.table_name from information_schema.columns a
    join information_schema.columns b on b.table_schema=a.table_schema
      and b.table_name=a.table_name and b.column_name='branch_id'
    where a.table_schema='public' and a.column_name='business_id'
  loop
    execute format('drop trigger if exists aa_nyilora_tenant_guard on public.%I',t.table_name);
    execute format('create trigger aa_nyilora_tenant_guard before insert or update on public.%I for each row execute function public.nyilora_guard_tenant_row()',t.table_name);
  end loop;
end $$;

-- A business owner can be resolved from the authenticated staff account; server
-- callbacks inherit it from the row guard within the same transaction.
create or replace function public.nyilora_business_context()
returns text language sql stable security definer set search_path=public as $$
  select coalesce(public.nyilora_current_business_id(),
    nullif(current_setting('nyilora.row_business_id',true),''))
$$;
revoke all on function public.nyilora_business_context() from public,anon;
grant execute on function public.nyilora_business_context() to authenticated,service_role;

-- Preserve every existing key and add composite keys so a loan, client, staff
-- member or branch cannot be linked across companies even by a server write.
do $$ declare t record; c record; v_name text; begin
  for t in select a.table_name from information_schema.columns a
    join information_schema.columns b on b.table_schema=a.table_schema
      and b.table_name=a.table_name and b.column_name='id'
    where a.table_schema='public' and a.column_name='business_id'
  loop
    execute format('create unique index if not exists %I on public.%I(business_id,id)',
      left('nyilora_biz_id_'||t.table_name,63),t.table_name);
  end loop;
  for c in select child.relname as child_table,parent.relname as parent_table,
      child_col.attname as child_column
    from pg_constraint fk
    join pg_class child on child.oid=fk.conrelid
    join pg_class parent on parent.oid=fk.confrelid
    join pg_namespace ns on ns.oid=child.relnamespace and ns.nspname='public'
    join pg_attribute child_col on child_col.attrelid=child.oid and child_col.attnum=fk.conkey[1]
    where fk.contype='f' and array_length(fk.conkey,1)=1
      and exists(select 1 from pg_attribute a where a.attrelid=child.oid and a.attname='business_id' and not a.attisdropped)
      and exists(select 1 from pg_attribute a where a.attrelid=parent.oid and a.attname='business_id' and not a.attisdropped)
      and exists(select 1 from pg_attribute a where a.attrelid=parent.oid and a.attname='id' and a.attnum=fk.confkey[1])
  loop
    v_name:=left('ny_biz_fk_'||md5(c.child_table||'_'||c.child_column||'_'||c.parent_table),63);
    if not exists(select 1 from pg_constraint where conname=v_name) then
      execute format('alter table public.%I add constraint %I foreign key (business_id,%I) references public.%I(business_id,id) not valid',
        c.child_table,v_name,c.child_column,c.parent_table);
      execute format('alter table public.%I validate constraint %I',c.child_table,v_name);
    end if;
  end loop;
end $$;

-- The Edge Function checks the private setup key before calling this RPC.
create or replace function public.nyilora_register_business_admin(
  p_auth_user_id uuid,p_company_name text,p_name text,p_email text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_business text; v_branch uuid; v_staff uuid; v_email text;
begin
  v_email:=lower(trim(coalesce(p_email,'')));
  if p_auth_user_id is null or length(trim(coalesce(p_company_name,'')))<2
    or length(trim(p_company_name))>160 or length(trim(coalesce(p_name,'')))<2
    or length(trim(p_name))>160 or v_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Valid company, administrator and email are required'; end if;
  perform pg_advisory_xact_lock(hashtext(p_auth_user_id::text));
  if exists(select 1 from public.loan_staff where auth_user_id=p_auth_user_id) then
    raise exception 'This login already belongs to a business'; end if;
  if not exists(select 1 from auth.users u where u.id=p_auth_user_id
    and lower(u.email)=v_email and u.email_confirmed_at is not null) then
    raise exception 'Confirmed administrator email does not match'; end if;
  -- The original company was seeded before any administrator existed. Claim it
  -- once; every later setup-key registration receives a fresh company ID.
  perform pg_advisory_xact_lock(hashtext('nyilora_initial_business_claim'));
  if exists(select 1 from public.nyilora_branches
      where business_id='BIZ-NYILORA' and is_head_office)
    and not exists(select 1 from public.loan_staff where business_id='BIZ-NYILORA')
    and not exists(select 1 from public.loan_clients where business_id='BIZ-NYILORA') then
    v_business:='BIZ-NYILORA';
    select id into v_branch from public.nyilora_branches
      where business_id=v_business and is_head_office limit 1;
    update public.loan_settings set company_name=trim(p_company_name)
      where business_id=v_business;
  else
    v_business:='BIZ-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12));
    insert into public.nyilora_branches(business_id,code,name,is_head_office,is_active)
      values(v_business,'HO','Head Office',true,true) returning id into v_branch;
    insert into public.loan_settings(business_id,company_name)
      values(v_business,trim(p_company_name));
    insert into public.nyilora_sms_wallets(business_id,branch_id)
      values(v_business,v_branch);
  end if;
  insert into public.loan_staff(business_id,branch_id,auth_user_id,name,email,role,is_active)
    values(v_business,v_branch,p_auth_user_id,trim(p_name),v_email,'admin',true)
    returning id into v_staff;
  insert into public.nyilora_staff_permissions(staff_id,business_id,branch_id,
    view_accounting,view_expenses,initiate_expenses,approve_expenses,
    manage_assets,manage_branches,transfer_portfolios,adjust_charges_excess,updated_by)
    values(v_staff,v_business,v_branch,true,true,true,true,true,true,true,true,v_staff);
  insert into public.nyilora_domain_audit(business_id,branch_id,actor_staff_id,
    action,entity_type,entity_id,new_value)
    values(v_business,v_branch,v_staff,'business_registered','loan_staff',v_staff::text,
      jsonb_build_object('company_name',trim(p_company_name),'email',v_email));
  return jsonb_build_object('ok',true,'business_id',v_business,'branch_id',v_branch,'staff_id',v_staff);
end $$;
revoke all on function public.nyilora_register_business_admin(uuid,text,text,text)
  from public,anon,authenticated;
grant execute on function public.nyilora_register_business_admin(uuid,text,text,text)
  to service_role;

notify pgrst,'reload schema';
commit;

-- END 0027_nyilora_multi_business_foundation.sql

-- BEGIN 0028_nyilora_multi_business_access.sql
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

-- END 0028_nyilora_multi_business_access.sql

-- BEGIN 0029_nyilora_multi_business_integrations.sql
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

-- END 0029_nyilora_multi_business_integrations.sql

-- BEGIN 0030_nyilora_multi_business_sms.sql
-- Route service-role SMS claims and credit purchases by the source business.
begin;

create or replace function public.nyilora_queue_repayment_sms()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_client public.loan_clients; v_loan public.loans; v_company text;
begin
  select * into v_loan from public.loans
    where id=new.loan_id and business_id=new.business_id;
  select * into v_client from public.loan_clients
    where id=v_loan.client_id and business_id=new.business_id;
  if v_loan.id is null or v_client.id is null
    or nullif(trim(v_client.phone),'') is null then return new; end if;
  select company_name into v_company from public.loan_settings
    where business_id=new.business_id;
  insert into public.nyilora_sms_outbox(business_id,branch_id,client_id,loan_id,
    repayment_id,recipient,sender_id,message,sms_type,message_type,client_name,status)
  values(new.business_id,new.branch_id,v_client.id,v_loan.id,new.id,v_client.phone,
    (select sender_id from public.nyilora_sms_wallets where business_id=new.business_id),
    format('Dear %s, we received KES %s for loan %s. Receipt %s. Thank you. %s',
      split_part(trim(v_client.full_name),' ',1),to_char(new.amount,'FM9999999990.00'),
      v_loan.loan_no,new.receipt_no,coalesce(v_company,'Your lender')),
    'repayment','repayment',v_client.full_name,'queued') on conflict do nothing;
  return new;
end $$;

create or replace function public.nyilora_queue_onboarding_sms()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_company text;
begin
  if nullif(trim(new.phone),'') is null then return new; end if;
  select company_name into v_company from public.loan_settings
    where business_id=new.business_id;
  insert into public.nyilora_sms_outbox(business_id,branch_id,client_id,
    recipient,sender_id,message,sms_type,message_type,client_name,status)
  values(new.business_id,new.branch_id,new.id,new.phone,
    (select sender_id from public.nyilora_sms_wallets where business_id=new.business_id),
    'Welcome to '||coalesce(v_company,'your lender')||', '||new.full_name||
      '. Your account is now registered.',
    'onboarding','onboarding',new.full_name,'queued');
  return new;
end $$;

create or replace function public.nyilora_reserve_sms(p_outbox_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_row public.nyilora_sms_outbox; v_wallet public.nyilora_sms_wallets;
begin
  select * into v_row from public.nyilora_sms_outbox where id=p_outbox_id for update;
  if v_row.id is null then return jsonb_build_object('ok',false,'code','not_queued'); end if;
  if auth.uid() is not null and v_row.business_id<>public.nyilora_current_business_id() then
    raise exception 'SMS belongs to another business'; end if;
  if v_row.status='sent' then return jsonb_build_object('ok',true,'already_sent',true); end if;
  if v_row.status in ('sending','delivery_unknown') then
    return jsonb_build_object('ok',false,'code','delivery_in_progress_or_unknown'); end if;
  if v_row.status not in ('queued','failed','blocked_no_credit') then
    return jsonb_build_object('ok',false,'code','not_sendable'); end if;
  select * into v_wallet from public.nyilora_sms_wallets
    where business_id=v_row.business_id for update;
  if v_wallet.id is null then raise exception 'SMS wallet is missing'; end if;
  if v_wallet.credits_remaining<=0 then
    update public.nyilora_sms_outbox set status='blocked_no_credit' where id=v_row.id;
    return jsonb_build_object('ok',false,'code','no_sms_credits'); end if;
  update public.nyilora_sms_wallets set credits_remaining=credits_remaining-1,
    credits_used=credits_used+1,updated_at=now() where id=v_wallet.id;
  update public.nyilora_sms_outbox set status='sending',attempts=attempts+1,
    provider_error=null where id=v_row.id;
  return jsonb_build_object('ok',true,'outbox_id',v_row.id,'business_id',v_row.business_id,
    'recipient',v_row.recipient,'message',v_row.message,'sender_id',v_row.sender_id);
end $$;

create or replace function public.nyilora_claim_repayment_sms(p_repayment_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  select id into v_id from public.nyilora_sms_outbox where repayment_id=p_repayment_id;
  return public.nyilora_reserve_sms(v_id);
end $$;

create or replace function public.nyilora_claim_client_onboarding_sms(p_client_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  select id into v_id from public.nyilora_sms_outbox
    where client_id=p_client_id and message_type='onboarding'
    order by queued_at desc limit 1;
  return public.nyilora_reserve_sms(v_id);
end $$;

create or replace function public.nyilora_claim_custom_sms(
  p_business_id text,p_recipient text,p_message text,p_client_name text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_branch uuid; v_sender text;
begin
  if nullif(trim(p_recipient),'') is null or nullif(trim(p_message),'') is null
    or length(p_message)>1000 then raise exception 'Invalid SMS request'; end if;
  if auth.uid() is not null and p_business_id<>public.nyilora_current_business_id() then
    raise exception 'Cannot send another business''s SMS'; end if;
  select b.id into v_branch from public.nyilora_branches b
    where b.business_id=p_business_id and b.is_head_office and b.is_active;
  if v_branch is null then raise exception 'Business branch is missing'; end if;
  select sender_id into v_sender from public.nyilora_sms_wallets
    where business_id=p_business_id;
  insert into public.nyilora_sms_outbox(business_id,branch_id,recipient,sender_id,
    message,sms_type,message_type,client_name,status)
  values(p_business_id,v_branch,trim(p_recipient),v_sender,trim(p_message),
    'custom','custom',left(coalesce(p_client_name,'Manual SMS'),150),'queued')
  returning id into v_id;
  return public.nyilora_reserve_sms(v_id);
end $$;

create or replace function public.nyilora_complete_repayment_sms(
  p_outbox_id uuid,p_status text,p_error text default null,p_refund boolean default false,
  p_provider_uid text default null,p_provider_response jsonb default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_row public.nyilora_sms_outbox;
begin
  if p_status not in ('sent','failed','delivery_unknown') then raise exception 'Invalid SMS result'; end if;
  select * into v_row from public.nyilora_sms_outbox where id=p_outbox_id for update;
  if v_row.id is null or v_row.status<>'sending' then
    return jsonb_build_object('ok',false,'code','not_sending'); end if;
  if auth.uid() is not null and v_row.business_id<>public.nyilora_current_business_id() then
    raise exception 'SMS belongs to another business'; end if;
  if p_refund and p_status<>'failed' then raise exception 'Only definite failures can refund a credit'; end if;
  update public.nyilora_sms_outbox set status=p_status,provider_error=left(p_error,1000),
    provider_uid=p_provider_uid,provider_response=p_provider_response,
    sent_at=case when p_status='sent' then now() else null end where id=v_row.id;
  if p_refund then
    update public.nyilora_sms_wallets set credits_remaining=credits_remaining+1,
      credits_used=credits_used-1,updated_at=now()
    where business_id=v_row.business_id; end if;
  return jsonb_build_object('ok',true,'business_id',v_row.business_id,
    'status',p_status,'refunded',p_refund);
end $$;

create or replace function public.nyilora_owner_add_sms_credits(
  p_business_id text,p_credits integer,p_customer_amount_paid numeric,
  p_customer_reference text,p_note text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_balance integer; v_existing public.nyilora_sms_topups;
  v_branch uuid;
begin
  if p_credits is null or p_credits<=0 or p_customer_amount_paid is null
    or p_customer_amount_paid<round(p_credits*0.55,2)
    or length(trim(coalesce(p_customer_reference,'')))<4 then
    raise exception 'Invalid SMS purchase'; end if;
  if auth.uid() is not null then raise exception 'Service authorization required'; end if;
  select id into v_branch from public.nyilora_branches
    where business_id=p_business_id and is_head_office and is_active;
  if v_branch is null then raise exception 'Business branch is missing'; end if;
  select * into v_existing from public.nyilora_sms_topups
    where business_id=p_business_id
      and upper(reference)=upper(trim(p_customer_reference)) for update;
  if v_existing.id is not null then
    if v_existing.credits<>p_credits or v_existing.amount<>p_customer_amount_paid then
      raise exception 'SMS purchase reference was used for a different amount'; end if;
    select credits_remaining into v_balance from public.nyilora_sms_wallets
      where business_id=p_business_id;
    return jsonb_build_object('ok',true,'already_credited',true,'remaining',v_balance);
  end if;
  insert into public.nyilora_sms_topups(business_id,credits,amount,reference)
  values(p_business_id,p_credits,p_customer_amount_paid,
    upper(trim(p_customer_reference))) returning id into v_id;
  update public.nyilora_sms_wallets set credits_purchased=credits_purchased+p_credits,
    credits_remaining=credits_remaining+p_credits,updated_at=now()
    where business_id=p_business_id returning credits_remaining into v_balance;
  insert into public.nyilora_domain_audit(business_id,branch_id,action,
    entity_type,entity_id,new_value)
  values(p_business_id,v_branch,'sms_credits_purchased','nyilora_sms_topups',v_id::text,
    jsonb_build_object('credits',p_credits,'amount',p_customer_amount_paid,
      'reference',upper(trim(p_customer_reference)),'note',p_note));
  return jsonb_build_object('ok',true,'remaining',v_balance,'topup_id',v_id);
end $$;

revoke all on function public.nyilora_reserve_sms(uuid),
  public.nyilora_claim_repayment_sms(uuid),public.nyilora_claim_client_onboarding_sms(uuid),
  public.nyilora_claim_custom_sms(text,text,text,text),
  public.nyilora_complete_repayment_sms(uuid,text,text,boolean,text,jsonb),
  public.nyilora_owner_add_sms_credits(text,integer,numeric,text,text)
  from public,anon,authenticated;
grant execute on function public.nyilora_claim_repayment_sms(uuid),
  public.nyilora_claim_client_onboarding_sms(uuid),
  public.nyilora_claim_custom_sms(text,text,text,text),
  public.nyilora_complete_repayment_sms(uuid,text,text,boolean,text,jsonb),
  public.nyilora_owner_add_sms_credits(text,integer,numeric,text,text)
  to service_role;
notify pgrst,'reload schema';
commit;

-- END 0030_nyilora_multi_business_sms.sql

-- BEGIN 0031_nyilora_multi_business_service_guards.sql
-- Callbacks have no user session, so validate against their own business rows.
begin;

alter table public.nyilora_sms_bundle_requests
  add column if not exists branch_id uuid;
update public.nyilora_sms_bundle_requests r set branch_id=b.id
  from public.nyilora_branches b
  where r.branch_id is null and b.business_id=r.business_id and b.is_head_office;
alter table public.nyilora_sms_bundle_requests
  alter column branch_id set not null;
do $$ begin
  if not exists (select 1 from pg_constraint
    where conname='nyilora_sms_bundle_branch_business_fk'
      and conrelid='public.nyilora_sms_bundle_requests'::regclass) then
    alter table public.nyilora_sms_bundle_requests
      add constraint nyilora_sms_bundle_branch_business_fk
        foreign key (business_id,branch_id)
        references public.nyilora_branches(business_id,id);
  end if;
end $$;
drop trigger if exists aa_nyilora_tenant_guard on public.nyilora_sms_bundle_requests;
create trigger aa_nyilora_tenant_guard before insert or update
  on public.nyilora_sms_bundle_requests for each row
  execute function public.nyilora_guard_tenant_row();

create or replace function public.nyilora_check_subscription_cycle()
returns trigger language plpgsql set search_path=public as $$
begin
  if not exists(select 1 from public.nyilora_branches
      where business_id=new.business_id and is_head_office)
    or new.billing_month<date '2026-12-01'
    or date_trunc('month',new.billing_month)::date<>new.billing_month
    or new.amount<>3000 then
    raise exception 'Subscription is KES 3,000 per month from December 2026'; end if;
  if new.status='paid' and (new.actual_amount is null or new.actual_amount<3000
    or new.paid_at is null or new.paid_until is null) then
    raise exception 'A paid period requires a verified KES 3,000 payment'; end if;
  if tg_op='UPDATE' and old.status='paid' and
    (new.status<>'paid' or new.paid_until<old.paid_until) then
    raise exception 'Already-paid billing periods cannot be reopened or shortened'; end if;
  return new;
end $$;

create or replace function public.nyilora_check_sms_bundle_price()
returns trigger language plpgsql set search_path=public as $$
begin
  if not exists(select 1 from public.nyilora_branches
      where business_id=new.business_id and id=new.branch_id)
    or new.credits<=0 or new.amount<>round(new.credits*0.55,2) then
    raise exception 'SMS bundle price must be KES 0.55 per credit'; end if;
  if tg_op='UPDATE' and (new.credits<>old.credits or new.amount<>old.amount
    or new.business_id<>old.business_id) then
    raise exception 'SMS bundle quantity and price cannot change after request'; end if;
  return new;
end $$;

create or replace function public.nyilora_record_callback_charge_payment(
  p_business_id text,p_client_id uuid,p_loan_id uuid,p_charge_id uuid,
  p_amount numeric,p_payment_reference text,p_payment_date timestamptz,
  p_payer_name text default null,p_payer_phone text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_charge public.nyilora_charges; v_loan public.loans;
  v_existing uuid; v_paid numeric(16,2); v_excess numeric(16,2);
begin
  if p_business_id is null or p_amount is null or p_amount<=0
    or round(p_amount,2)<>p_amount or length(trim(coalesce(p_payment_reference,'')))<4
    then raise exception 'Invalid processing-fee callback'; end if;
  if auth.uid() is not null then raise exception 'Service authorization required'; end if;
  select r.id into v_existing from public.loan_repayments r
    where r.business_id=p_business_id and
      (upper(r.payment_reference)=upper(trim(p_payment_reference))
        or upper(r.receipt_no)=upper(trim(p_payment_reference))) limit 1;
  if v_existing is not null then
    return jsonb_build_object('ok',true,'duplicate',true,'repayment_id',v_existing); end if;
  select * into v_loan from public.loans
    where id=p_loan_id and business_id=p_business_id for update;
  select * into v_charge from public.nyilora_charges
    where id=p_charge_id and business_id=p_business_id for update;
  if v_loan.id is null or v_charge.id is null or v_loan.client_id<>p_client_id
    or v_charge.client_id<>p_client_id or v_charge.loan_id<>v_loan.id
    or v_charge.branch_id<>v_loan.branch_id or v_charge.charge_type<>'processing_fee'
    or v_charge.status not in ('pending','partially_paid') then
    raise exception 'Open processing fee does not match the loan'; end if;
  v_paid:=least(round(p_amount,2),round(v_charge.amount-v_charge.amount_paid,2));
  if v_paid<=0 then raise exception 'Processing fee is already paid'; end if;
  v_excess:=round(p_amount-v_paid,2);
  insert into public.loan_repayments(business_id,branch_id,loan_id,receipt_no,amount,
    payment_method,payment_reference,payment_date,sender_name,sender_phone,
    processing_fee_portion,credit_portion,mpesa_confirmed,notes)
  values(p_business_id,v_loan.branch_id,v_loan.id,upper(trim(p_payment_reference)),p_amount,
    'M-Pesa',upper(trim(p_payment_reference)),coalesce(p_payment_date,now()),
    nullif(trim(p_payer_name),''),nullif(trim(p_payer_phone),''),
    v_paid,v_excess,true,'Processing fee received from callback')
  returning id into v_existing;
  update public.nyilora_charges set amount_paid=amount_paid+v_paid,
    status=case when amount_paid+v_paid>=amount then 'paid' else 'partially_paid' end,
    settled_at=case when amount_paid+v_paid>=amount then coalesce(p_payment_date,now()) else null end,
    settlement_note='M-Pesa '||upper(trim(p_payment_reference)),updated_at=now()
  where id=v_charge.id;
  update public.loans set processing_fee_paid=least(processing_fee,
    coalesce(processing_fee_paid,0)+v_paid),updated_at=now() where id=v_loan.id;
  insert into public.nyilora_domain_audit(business_id,branch_id,action,
    entity_type,entity_id,new_value)
  values(p_business_id,v_loan.branch_id,'callback_processing_fee_paid',
    'loan_repayments',v_existing::text,
    jsonb_build_object('charge_id',v_charge.id,'paid',v_paid,
      'excess',v_excess,'reference',upper(trim(p_payment_reference))));
  return jsonb_build_object('ok',true,'repayment_id',v_existing,
    'processing_fee_paid',v_paid,'excess_recorded',v_excess,
    'loan_balance_unchanged',v_loan.outstanding_balance);
end $$;

revoke all on function public.nyilora_record_callback_charge_payment(
  text,uuid,uuid,uuid,numeric,text,timestamptz,text,text)
  from public,anon,authenticated;
grant execute on function public.nyilora_record_callback_charge_payment(
  text,uuid,uuid,uuid,numeric,text,timestamptz,text,text) to service_role;
notify pgrst,'reload schema';
commit;

-- END 0031_nyilora_multi_business_service_guards.sql

