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
