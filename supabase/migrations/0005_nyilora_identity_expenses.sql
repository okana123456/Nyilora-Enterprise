-- Nyilora only. Run after NYILORA-FOUNDATION-ONE-RUN.sql.
-- Login linking and expense workflow. No client, loan, repayment or SMS totals are changed.
begin;

create or replace function public.nyilora_confirmed_auth_email()
returns text language sql stable security definer set search_path=public
as $$
  select lower(u.email) from auth.users u
  where u.id=auth.uid() and u.email_confirmed_at is not null
$$;

drop policy if exists nyilora_staff_pending_self_read on public.loan_staff;
create policy nyilora_staff_pending_self_read on public.loan_staff
  for select to authenticated
  using (business_id='BIZ-NYILORA' and is_active and auth_user_id is null
    and lower(email)=public.nyilora_confirmed_auth_email());

create or replace function public.nyilora_link_current_staff()
returns public.loan_staff
language plpgsql security definer set search_path=public
as $$
declare v_email text; v_staff public.loan_staff;
begin
  if auth.uid() is null then raise exception 'Sign in first'; end if;
  select lower(u.email) into v_email from auth.users u
  where u.id=auth.uid() and u.email_confirmed_at is not null;
  if v_email is null then raise exception 'A confirmed email is required'; end if;
  update public.loan_staff s set auth_user_id=auth.uid(),updated_at=now()
  where s.business_id='BIZ-NYILORA' and s.is_active
    and lower(s.email)=v_email and (s.auth_user_id is null or s.auth_user_id=auth.uid())
  returning s.* into v_staff;
  if v_staff.id is null then raise exception 'No active Nyilora staff record matches this login'; end if;
  return v_staff;
end $$;

create or replace function public.nyilora_record_staff_login()
returns timestamptz language plpgsql security definer set search_path=public
as $$
declare v_seen timestamptz;
begin
  update public.loan_staff set last_login=now(),updated_at=now()
  where business_id='BIZ-NYILORA' and auth_user_id=auth.uid() and is_active
  returning last_login into v_seen;
  if v_seen is null then raise exception 'Active Nyilora staff login not found'; end if;
  return v_seen;
end $$;

create or replace function public.nyilora_can(p_permission text)
returns boolean language sql stable security definer set search_path=public
as $$
  select public.nyilora_has_role('admin') or coalesce((
    select case p_permission
      when 'view_expenses' then p.view_expenses
      when 'initiate_expenses' then p.initiate_expenses
      when 'approve_expenses' then p.approve_expenses
      when 'view_accounting' then p.view_accounting
      when 'manage_assets' then p.manage_assets
      else false end
    from public.nyilora_staff_permissions p
    where p.staff_id=public.nyilora_staff_id() and p.business_id='BIZ-NYILORA'
  ),false)
$$;

create or replace function public.nyilora_submit_expense(p jsonb)
returns public.nyilora_expenses
language plpgsql security definer set search_path=public
as $$
declare v_actor public.loan_staff; v_exp public.nyilora_expenses; v_id uuid;
  v_branch constant uuid := '00000000-0000-4000-8000-000000000001';
begin
  v_actor:=public.nyilora_current_staff();
  if v_actor.id is null or not (public.nyilora_can('initiate_expenses') or public.nyilora_has_role('branch_manager'))
    then raise exception 'Expense initiation is not permitted'; end if;
  if p is null or coalesce((p->>'amount')::numeric,0)<=0 then raise exception 'Positive expense amount required'; end if;
  if nullif(trim(p->>'description'),'') is null then raise exception 'Expense description required'; end if;
  if coalesce(nullif(p->>'branch_id','')::uuid,v_branch)<>v_branch then raise exception 'Invalid Nyilora branch'; end if;
  v_id:=nullif(p->>'id','')::uuid;
  if v_id is null then
    insert into public.nyilora_expenses
      (business_id,branch_id,expense_no,expense_date,category,custom_category,description,
       amount,payment_method,payment_reference,vendor,initiated_by)
    values('BIZ-NYILORA',v_branch,'NYE-'||upper(substr(replace(gen_random_uuid()::text,'-',''),1,12)),
      coalesce(nullif(p->>'expense_date','')::date,current_date),p->>'category',p->>'custom_category',
      trim(p->>'description'),(p->>'amount')::numeric,coalesce(nullif(p->>'payment_method',''),'cash'),
      p->>'payment_reference',p->>'vendor',v_actor.id)
    returning * into v_exp;
    insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,entity_id,new_value)
    values(v_actor.id,'create','expense',v_exp.id::text,to_jsonb(v_exp));
  else
    select * into v_exp from public.nyilora_expenses where id=v_id and business_id='BIZ-NYILORA' for update;
    if v_exp.id is null then raise exception 'Expense not found'; end if;
    if v_exp.status not in ('draft','pending','rejected') then raise exception 'Approved expense cannot be edited'; end if;
    if v_exp.initiated_by<>v_actor.id and not (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager'))
      then raise exception 'Cannot edit another user''s expense'; end if;
    insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,entity_id,old_value)
    values(v_actor.id,'edit_previous','expense',v_id::text,to_jsonb(v_exp));
    update public.nyilora_expenses set
      expense_date=coalesce(nullif(p->>'expense_date','')::date,expense_date),
      category=coalesce(nullif(p->>'category',''),category),custom_category=p->>'custom_category',
      description=trim(p->>'description'),amount=(p->>'amount')::numeric,
      payment_method=coalesce(nullif(p->>'payment_method',''),'cash'),
      payment_reference=p->>'payment_reference',vendor=p->>'vendor',
      status='pending',rejection_reason=null,rejected_by=null,rejected_at=null,updated_at=now()
    where id=v_id returning * into v_exp;
    insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,entity_id,old_value,new_value)
    values(v_actor.id,'edit','expense',v_id::text,null,to_jsonb(v_exp));
  end if;
  return v_exp;
end $$;

create or replace function public.nyilora_decide_expense(p_id uuid,p_action text,p_reason text default null)
returns public.nyilora_expenses
language plpgsql security definer set search_path=public
as $$
declare v_actor public.loan_staff; v_exp public.nyilora_expenses;
begin
  v_actor:=public.nyilora_current_staff();
  if v_actor.id is null or not (public.nyilora_can('approve_expenses') or public.nyilora_has_role('branch_manager'))
    then raise exception 'Expense approval is not permitted'; end if;
  if p_action not in ('approve','reject') then raise exception 'Invalid expense action'; end if;
  if p_action='reject' and nullif(trim(p_reason),'') is null then raise exception 'Rejection reason required'; end if;
  select * into v_exp from public.nyilora_expenses where id=p_id and business_id='BIZ-NYILORA' for update;
  if v_exp.id is null or v_exp.status<>'pending' then raise exception 'Pending expense not found'; end if;
  update public.nyilora_expenses set status=case when p_action='approve' then 'approved' else 'rejected' end,
    approved_by=case when p_action='approve' then v_actor.id else null end,
    approved_at=case when p_action='approve' then now() else null end,
    rejected_by=case when p_action='reject' then v_actor.id else null end,
    rejected_at=case when p_action='reject' then now() else null end,
    rejection_reason=case when p_action='reject' then trim(p_reason) else null end,updated_at=now()
  where id=p_id returning * into v_exp;
  if p_action='approve' then
    insert into public.nyilora_accounting_entries
      (business_id,branch_id,entry_date,account_code,account_name,account_type,debit,credit,
       description,source_table,source_id,entry_key,expense_id,created_by)
    values
      ('BIZ-NYILORA',v_exp.branch_id,v_exp.expense_date,'5000','Operating Expenses','expense',v_exp.amount,0,
       v_exp.description,'nyilora_expenses',v_exp.id::text,'expense_debit',v_exp.id,v_actor.id),
      ('BIZ-NYILORA',v_exp.branch_id,v_exp.expense_date,'1000','Cash and Bank','asset',0,v_exp.amount,
       v_exp.description,'nyilora_expenses',v_exp.id::text,'cash_credit',v_exp.id,v_actor.id)
    on conflict (business_id,source_table,source_id,entry_key) do nothing;
  end if;
  insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,entity_id,new_value)
  values(v_actor.id,p_action,'expense',p_id::text,to_jsonb(v_exp));
  return v_exp;
end $$;

create or replace function public.nyilora_delete_expense(p_id uuid)
returns boolean language plpgsql security definer set search_path=public
as $$
declare v_actor public.loan_staff; v_exp public.nyilora_expenses;
begin
  v_actor:=public.nyilora_current_staff();
  select * into v_exp from public.nyilora_expenses where id=p_id and business_id='BIZ-NYILORA' for update;
  if v_exp.id is null then raise exception 'Expense not found'; end if;
  if v_exp.status in ('approved','paid') then raise exception 'Approved expense cannot be deleted'; end if;
  if v_exp.initiated_by<>v_actor.id and not public.nyilora_has_role('admin') then raise exception 'Expense deletion is not permitted'; end if;
  update public.nyilora_expenses set status='cancelled',updated_at=now() where id=p_id;
  insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,entity_id,old_value)
  values(v_actor.id,'cancel','expense',p_id::text,to_jsonb(v_exp));
  return true;
end $$;

revoke all on function public.nyilora_confirmed_auth_email(),public.nyilora_link_current_staff(),public.nyilora_record_staff_login(),
  public.nyilora_can(text),public.nyilora_submit_expense(jsonb),
  public.nyilora_decide_expense(uuid,text,text),public.nyilora_delete_expense(uuid) from public,anon;
grant execute on function public.nyilora_confirmed_auth_email(),public.nyilora_link_current_staff(),public.nyilora_record_staff_login(),
  public.nyilora_can(text),public.nyilora_submit_expense(jsonb),
  public.nyilora_decide_expense(uuid,text,text),public.nyilora_delete_expense(uuid) to authenticated;

commit;
