-- Nyilora only. Adds controlled single-branch officer handovers.
-- No branch, schedule, repayment, accounting or financial amounts are changed.
begin;

create or replace function public.nyilora_can_transfer_portfolios()
returns boolean language sql stable security definer set search_path=public as $$
  select public.nyilora_has_role('admin') or coalesce((
    select p.transfer_portfolios from public.nyilora_staff_permissions p
    where p.staff_id=public.nyilora_staff_id() and p.business_id='BIZ-NYILORA'
  ),false)
$$;

create or replace function public.nyilora_transfer_portfolio(
  p_from uuid,p_to uuid,p_client_ids uuid[] default null,p_move_all boolean default false
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_source public.loan_staff; v_target public.loan_staff; v_ids uuid[];
  v_expected integer; v_clients integer; v_loans integer; v_apps integer;
  v_branch constant uuid:='00000000-0000-4000-8000-000000000001';
begin
  if public.nyilora_staff_id() is null or not public.nyilora_can_transfer_portfolios()
    then raise exception 'Portfolio transfer permission required' using errcode='42501'; end if;
  if p_from is null or p_to is null or p_from=p_to then raise exception 'Choose two different officers'; end if;
  select * into v_source from public.loan_staff where id=p_from and business_id='BIZ-NYILORA' and branch_id=v_branch;
  select * into v_target from public.loan_staff where id=p_to and business_id='BIZ-NYILORA'
    and branch_id=v_branch and is_active;
  if v_source.id is null or v_target.id is null then raise exception 'Source or active target officer not found'; end if;
  if not ('loan_officer'=any(regexp_split_to_array(lower(v_target.role),'\s*,\s*')))
    or 'admin'=any(regexp_split_to_array(lower(v_target.role),'\s*,\s*'))
    then raise exception 'Target must be an active loan officer'; end if;
  if not p_move_all and coalesce(cardinality(p_client_ids),0)=0 then raise exception 'Select clients to transfer'; end if;
  perform pg_advisory_xact_lock(hashtext('nyilora_portfolio_'||p_from::text));
  select coalesce(array_agg(distinct c.id),'{}') into v_ids
  from public.loan_clients c where c.business_id='BIZ-NYILORA' and c.branch_id=v_branch
    and c.loan_officer_id=p_from and (p_move_all or c.id=any(p_client_ids));
  v_expected:=case when p_move_all then cardinality(v_ids)
    else (select count(distinct x) from unnest(p_client_ids) x where x is not null) end;
  if cardinality(v_ids)<>v_expected or v_expected=0
    then raise exception 'Selected clients are missing or no longer assigned to the source officer'; end if;
  if exists(select 1 from public.loans l where l.client_id=any(v_ids) and l.business_id='BIZ-NYILORA'
    and l.status='active' and (l.branch_id<>v_branch or l.loan_officer_id is distinct from p_from))
    then raise exception 'An active loan has a different owner; review before transfer'; end if;
  update public.loan_clients set loan_officer_id=p_to,updated_at=now() where id=any(v_ids);
  get diagnostics v_clients=row_count;
  update public.loans set loan_officer_id=p_to,updated_at=now()
    where business_id='BIZ-NYILORA' and branch_id=v_branch and client_id=any(v_ids)
      and status='active' and loan_officer_id=p_from;
  get diagnostics v_loans=row_count;
  update public.loan_applications set loan_officer_id=p_to,updated_at=now()
    where business_id='BIZ-NYILORA' and branch_id=v_branch and client_id=any(v_ids)
      and status in ('draft','submitted','under_review','approved')
      and (loan_officer_id=p_from or loan_officer_id is null);
  get diagnostics v_apps=row_count;
  if v_clients<>v_expected then raise exception 'Portfolio changed during transfer'; end if;
  insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,new_value)
  values(public.nyilora_staff_id(),'portfolio_transferred','loan_clients',
    jsonb_build_object('from',p_from,'to',p_to,'client_ids',to_jsonb(v_ids),
      'clients',v_clients,'active_loans',v_loans,'open_applications',v_apps));
  return jsonb_build_object('ok',true,'clients_moved',v_clients,
    'active_loans_moved',v_loans,'pending_applications_moved',v_apps);
end $$;

create or replace function public.nyilora_assign_client_portfolio(
  p_client_id uuid,p_officer_id uuid,p_reason text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_old uuid; v_target public.loan_staff; v_result jsonb;
  v_branch constant uuid:='00000000-0000-4000-8000-000000000001';
begin
  if public.nyilora_staff_id() is null or not public.nyilora_can_transfer_portfolios()
    then raise exception 'Portfolio transfer permission required' using errcode='42501'; end if;
  select loan_officer_id into v_old from public.loan_clients
    where id=p_client_id and business_id='BIZ-NYILORA' and branch_id=v_branch for update;
  if not found then raise exception 'Client not found'; end if;
  select * into v_target from public.loan_staff where id=p_officer_id and business_id='BIZ-NYILORA'
    and branch_id=v_branch and is_active;
  if v_target.id is null or not ('loan_officer'=any(regexp_split_to_array(lower(v_target.role),'\s*,\s*')))
    then raise exception 'Select an active Nyilora loan officer'; end if;
  if v_old=p_officer_id then return jsonb_build_object('ok',true,'clients_moved',0); end if;
  if v_old is null then
    if exists(select 1 from public.loans where client_id=p_client_id and status='active')
      then raise exception 'Unassigned client has an active loan; review its officer first'; end if;
    update public.loan_clients set loan_officer_id=p_officer_id,updated_at=now() where id=p_client_id;
    update public.loan_applications set loan_officer_id=p_officer_id,updated_at=now()
      where client_id=p_client_id and business_id='BIZ-NYILORA'
        and status in ('draft','submitted','under_review','approved');
    v_result:=jsonb_build_object('ok',true,'clients_moved',1,'active_loans_moved',0);
  else
    v_result:=public.nyilora_transfer_portfolio(v_old,p_officer_id,array[p_client_id],false);
  end if;
  insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,entity_id,new_value)
  values(public.nyilora_staff_id(),'client_portfolio_assigned','loan_clients',p_client_id::text,
    jsonb_build_object('from',v_old,'to',p_officer_id,'reason',left(coalesce(p_reason,''),1000)));
  return v_result;
end $$;

create or replace function public.nyilora_handover_branch_portfolio(p_from uuid,p_to uuid,p_branch uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  if p_branch is distinct from '00000000-0000-4000-8000-000000000001'::uuid
    then raise exception 'Invalid Nyilora branch'; end if;
  return public.nyilora_transfer_portfolio(p_from,p_to,null,true);
end $$;

revoke all on function public.nyilora_can_transfer_portfolios(),
  public.nyilora_transfer_portfolio(uuid,uuid,uuid[],boolean),
  public.nyilora_assign_client_portfolio(uuid,uuid,text),
  public.nyilora_handover_branch_portfolio(uuid,uuid,uuid) from public,anon;
grant execute on function public.nyilora_can_transfer_portfolios(),
  public.nyilora_transfer_portfolio(uuid,uuid,uuid[],boolean),
  public.nyilora_assign_client_portfolio(uuid,uuid,text),
  public.nyilora_handover_branch_portfolio(uuid,uuid,uuid) to authenticated;
notify pgrst,'reload schema';
commit;
