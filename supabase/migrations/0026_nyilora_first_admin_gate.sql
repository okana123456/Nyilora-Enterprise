-- Nyilora only. One-time, server-only claim for the first administrator.
-- The setup key lives only in the Edge Function secret, never in SQL or Git.
begin;

create or replace function public.nyilora_claim_first_admin(
  p_auth_user_id uuid,p_name text,p_email text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_staff_id uuid; v_email text:=lower(trim(coalesce(p_email,'')));
  v_name text:=trim(coalesce(p_name,''));
begin
  perform pg_advisory_xact_lock(hashtext('BIZ-NYILORA:first-admin'));
  if exists(select 1 from public.loan_staff s where s.business_id='BIZ-NYILORA') then
    raise exception 'Nyilora administrator setup is complete' using errcode='23505'; end if;
  if p_auth_user_id is null or length(v_name)<2 or length(v_name)>160
    or v_email !~* '^[^[:space:]@]+@[^[:space:]@]+\.[^[:space:]@]+$' then
    raise exception 'Valid name, email and login are required'; end if;
  if not exists(select 1 from auth.users u where u.id=p_auth_user_id
    and lower(u.email)=v_email and u.email_confirmed_at is not null) then
    raise exception 'Confirmed Nyilora login does not match the setup request'; end if;
  insert into public.loan_staff(business_id,branch_id,auth_user_id,name,email,role,is_active)
  values('BIZ-NYILORA','00000000-0000-4000-8000-000000000001',
    p_auth_user_id,v_name,v_email,'admin',true)
  returning id into v_staff_id;
  insert into public.nyilora_staff_permissions(staff_id,business_id,branch_id,
    view_accounting,view_expenses,initiate_expenses,approve_expenses,
    manage_assets,manage_branches,transfer_portfolios,adjust_charges_excess,
    updated_by)
  values(v_staff_id,'BIZ-NYILORA','00000000-0000-4000-8000-000000000001',
    true,true,true,true,true,true,true,true,v_staff_id);
  insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,
    entity_id,new_value)
  values(v_staff_id,'first_admin_created','loan_staff',v_staff_id::text,
    jsonb_build_object('email',v_email,'role','admin'));
  return jsonb_build_object('ok',true,'staff_id',v_staff_id);
end $$;

revoke all on function public.nyilora_claim_first_admin(uuid,text,text)
  from public,anon,authenticated;
grant execute on function public.nyilora_claim_first_admin(uuid,text,text)
  to service_role;
notify pgrst,'reload schema';
commit;
