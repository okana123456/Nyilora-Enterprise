-- Nyilora officer dashboards: scoped read endpoint avoiding repeated legacy
-- RLS checks on every repayment row. No financial data or policies are changed.
-- Identity, business, branch and ownership are checked inside this function.
begin;

create or replace function public.nyilora_officer_portfolio_page(
  p_table text,
  p_after uuid default null,
  p_since timestamptz default null,
  p_limit integer default 500
) returns jsonb
language plpgsql stable security definer
set search_path = pg_catalog
as $$
declare
  actor public.loan_staff%rowtype;
  actor_roles text[];
  result_rows jsonb;
  scope_sql text;
  page_size integer := least(greatest(coalesce(p_limit,500),1),500);
begin
  if auth.uid() is null then
    raise exception 'Sign in to view your portfolio' using errcode='42501';
  end if;
  if p_table is null or p_table not in (
    'loan_clients','loans','loan_applications','loan_schedules','loan_repayments','loan_staff'
  ) then
    raise exception 'Unsupported portfolio table' using errcode='22023';
  end if;

  select s.* into actor from public.loan_staff s
  where s.business_id='BIZ-NYILORA' and coalesce(s.is_active,true)
    and (s.auth_user_id=auth.uid() or (
      public.nyilora_confirmed_auth_email() is not null
      and lower(trim(s.email))=public.nyilora_confirmed_auth_email()
    ))
  order by (s.auth_user_id=auth.uid()) desc nulls last, s.id
  limit 1;

  actor_roles := regexp_split_to_array(lower(trim(coalesce(actor.role,''))), '\s*,\s*');
  if actor.id is null or actor.branch_id is null
    or not ('loan_officer'=any(actor_roles))
    or 'admin'=any(actor_roles) or 'branch_manager'=any(actor_roles) then
    raise exception 'An active Nyilora loan officer with an assigned branch is required' using errcode='42501';
  end if;

  if p_table='loan_staff' then
    -- Only fields needed by the officer screens, never password/login fields.
    result_rows := case when p_after is null then jsonb_build_array(jsonb_build_object(
      'id',actor.id,'name',actor.name,'role',actor.role,'business_id',actor.business_id,
      'branch_id',actor.branch_id,'is_active',actor.is_active
    )) else '[]'::jsonb end;
    return jsonb_build_object('rows',result_rows,'next_after',null,'staff_id',actor.id);
  end if;

  scope_sql := 'r.business_id=$1 and r.branch_id=$2';
  if p_table in ('loans','loan_applications') then
    scope_sql := scope_sql || ' and r.loan_officer_id=$3';
  elsif p_table='loan_clients' then
    scope_sql := scope_sql || ' and (r.loan_officer_id=$3 or exists (
      select 1 from public.loans l where l.client_id=r.id
        and l.business_id=$1 and l.branch_id=$2 and l.loan_officer_id=$3))';
  else
    scope_sql := scope_sql || ' and exists (
      select 1 from public.loans l where l.id=r.loan_id
        and l.business_id=$1 and l.branch_id=$2 and l.loan_officer_id=$3)';
  end if;

  -- p_table is a strict allowlist above and is quoted as an identifier.
  -- All caller-supplied values are bound parameters. Ownership is always
  -- resolved from the authenticated user, never from a caller-supplied ID.
  execute format('select coalesce(jsonb_agg(to_jsonb(page) order by page.id),''[]''::jsonb)
    from (select r.* from public.%I r where %s
      and ($4::uuid is null or r.id>$4)
      and ($5::timestamptz is null or coalesce(
        (to_jsonb(r)->>''updated_at'')::timestamptz,
        (to_jsonb(r)->>''created_at'')::timestamptz,
        ''epoch''::timestamptz)>=$5)
      order by r.id limit $6) page',p_table,scope_sql)
  into result_rows
  using actor.business_id,actor.branch_id,actor.id,p_after,p_since,page_size;

  return jsonb_build_object('rows',result_rows,'staff_id',actor.id,
    'next_after',case when jsonb_array_length(result_rows)=page_size
      then result_rows->(page_size-1)->>'id' else null end);
end $$;

revoke all on function public.nyilora_officer_portfolio_page(text,uuid,timestamptz,integer) from public,anon;
grant execute on function public.nyilora_officer_portfolio_page(text,uuid,timestamptz,integer) to authenticated;

create index if not exists nyilora_reader_officer_loans_idx
on public.loans (branch_id,loan_officer_id,id) where business_id='BIZ-NYILORA';
create index if not exists nyilora_reader_repayments_idx
on public.loan_repayments (loan_id,id) where business_id='BIZ-NYILORA';
create index if not exists nyilora_reader_schedules_idx
on public.loan_schedules (loan_id,id) where business_id='BIZ-NYILORA';

notify pgrst, 'reload schema';
commit;

select
  to_regprocedure('public.nyilora_officer_portfolio_page(text,uuid,timestamp with time zone,integer)') is not null as reader_installed,
  has_function_privilege('authenticated','public.nyilora_officer_portfolio_page(text,uuid,timestamptz,integer)','EXECUTE') as staff_can_call,
  not has_function_privilege('anon','public.nyilora_officer_portfolio_page(text,uuid,timestamptz,integer)','EXECUTE') as anonymous_blocked;
