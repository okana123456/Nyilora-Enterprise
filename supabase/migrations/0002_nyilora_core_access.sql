-- Fresh Nyilora project only. Auth identity controls access to the one branch.
begin;

create or replace function public.nyilora_current_staff()
returns public.loan_staff
language sql stable security definer set search_path=public
as $$
  select s from public.loan_staff s
  where s.business_id='BIZ-NYILORA' and s.auth_user_id=auth.uid()
    and s.is_active
  limit 1
$$;

create or replace function public.nyilora_has_role(p_role text)
returns boolean
language sql stable security definer set search_path=public
as $$
  select p_role=any(regexp_split_to_array(lower(coalesce((public.nyilora_current_staff()).role,'')),'\s*,\s*'))
$$;

create or replace function public.nyilora_staff_id()
returns uuid
language sql stable security definer set search_path=public
as $$select (public.nyilora_current_staff()).id$$;

create or replace function public.nyilora_can_read_portfolio(p_branch uuid,p_officer uuid)
returns boolean
language sql stable security definer set search_path=public
as $$
  select p_branch=(public.nyilora_current_staff()).branch_id and
  (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
   or public.nyilora_has_role('cashier')
   or p_officer=public.nyilora_staff_id())
$$;

revoke all on function public.nyilora_current_staff() from public,anon;
revoke all on function public.nyilora_has_role(text) from public,anon;
revoke all on function public.nyilora_staff_id() from public,anon;
revoke all on function public.nyilora_can_read_portfolio(uuid,uuid) from public,anon;
grant execute on function public.nyilora_current_staff(),public.nyilora_has_role(text),
  public.nyilora_staff_id(),public.nyilora_can_read_portfolio(uuid,uuid) to authenticated;

alter table public.nyilora_branches enable row level security;
alter table public.loan_staff enable row level security;
alter table public.loan_clients enable row level security;
alter table public.loan_products enable row level security;
alter table public.loan_applications enable row level security;
alter table public.loans enable row level security;
alter table public.loan_schedules enable row level security;
alter table public.loan_repayments enable row level security;
alter table public.loan_penalties enable row level security;

create policy nyilora_branch_read on public.nyilora_branches for select to authenticated
  using (business_id='BIZ-NYILORA' and (public.nyilora_current_staff()).id is not null);
create policy nyilora_branch_admin_edit on public.nyilora_branches for update to authenticated
  using (public.nyilora_has_role('admin'))
  with check (business_id='BIZ-NYILORA' and public.nyilora_has_role('admin'));

create policy nyilora_staff_read on public.loan_staff for select to authenticated
  using (business_id='BIZ-NYILORA' and
    (id=public.nyilora_staff_id() or public.nyilora_has_role('admin')
     or public.nyilora_has_role('branch_manager')));
create policy nyilora_staff_admin_update on public.loan_staff for update to authenticated
  using (public.nyilora_has_role('admin'))
  with check (business_id='BIZ-NYILORA' and public.nyilora_has_role('admin'));

create policy nyilora_client_read on public.loan_clients for select to authenticated
  using (business_id='BIZ-NYILORA' and public.nyilora_can_read_portfolio(branch_id,loan_officer_id));
create policy nyilora_client_insert on public.loan_clients for insert to authenticated
  with check (business_id='BIZ-NYILORA' and branch_id=(public.nyilora_current_staff()).branch_id and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
     or (public.nyilora_has_role('loan_officer') and loan_officer_id=public.nyilora_staff_id())));
create policy nyilora_client_update on public.loan_clients for update to authenticated
  using (business_id='BIZ-NYILORA' and branch_id=(public.nyilora_current_staff()).branch_id and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
     or loan_officer_id=public.nyilora_staff_id()))
  with check (business_id='BIZ-NYILORA' and branch_id=(public.nyilora_current_staff()).branch_id);

create policy nyilora_product_read on public.loan_products for select to authenticated
  using (business_id='BIZ-NYILORA' and (public.nyilora_current_staff()).id is not null);
create policy nyilora_product_write on public.loan_products for all to authenticated
  using (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager'))
  with check (business_id='BIZ-NYILORA' and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')));

create policy nyilora_application_read on public.loan_applications for select to authenticated
  using (business_id='BIZ-NYILORA' and public.nyilora_can_read_portfolio(branch_id,loan_officer_id));
create policy nyilora_application_insert on public.loan_applications for insert to authenticated
  with check (business_id='BIZ-NYILORA' and branch_id=(public.nyilora_current_staff()).branch_id and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
     or (public.nyilora_has_role('loan_officer') and loan_officer_id=public.nyilora_staff_id())));
create policy nyilora_application_update on public.loan_applications for update to authenticated
  using (business_id='BIZ-NYILORA' and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
     or loan_officer_id=public.nyilora_staff_id()))
  with check (business_id='BIZ-NYILORA' and branch_id=(public.nyilora_current_staff()).branch_id);

create policy nyilora_loan_read on public.loans for select to authenticated
  using (business_id='BIZ-NYILORA' and public.nyilora_can_read_portfolio(branch_id,loan_officer_id));
create policy nyilora_loan_insert on public.loans for insert to authenticated
  with check (business_id='BIZ-NYILORA' and branch_id=(public.nyilora_current_staff()).branch_id and
    (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
     or (public.nyilora_has_role('loan_officer') and loan_officer_id=public.nyilora_staff_id())));
create policy nyilora_loan_update on public.loans for update to authenticated
  using (business_id='BIZ-NYILORA' and public.nyilora_can_read_portfolio(branch_id,loan_officer_id))
  with check (business_id='BIZ-NYILORA' and branch_id=(public.nyilora_current_staff()).branch_id);

create policy nyilora_schedule_read on public.loan_schedules for select to authenticated
  using (business_id='BIZ-NYILORA' and exists (
    select 1 from public.loans l where l.id=loan_id
      and public.nyilora_can_read_portfolio(l.branch_id,l.loan_officer_id)));
create policy nyilora_schedule_insert on public.loan_schedules for insert to authenticated
  with check (business_id='BIZ-NYILORA' and exists (
    select 1 from public.loans l where l.id=loan_id
      and public.nyilora_can_read_portfolio(l.branch_id,l.loan_officer_id)));
create policy nyilora_schedule_update on public.loan_schedules for update to authenticated
  using (business_id='BIZ-NYILORA' and exists (
    select 1 from public.loans l where l.id=loan_id
      and public.nyilora_can_read_portfolio(l.branch_id,l.loan_officer_id)))
  with check (business_id='BIZ-NYILORA');

create policy nyilora_repayment_read on public.loan_repayments for select to authenticated
  using (business_id='BIZ-NYILORA' and exists (
    select 1 from public.loans l where l.id=loan_id
      and public.nyilora_can_read_portfolio(l.branch_id,l.loan_officer_id)));
create policy nyilora_repayment_insert on public.loan_repayments for insert to authenticated
  with check (business_id='BIZ-NYILORA' and exists (
    select 1 from public.loans l where l.id=loan_id
      and public.nyilora_can_read_portfolio(l.branch_id,l.loan_officer_id)));

create policy nyilora_penalty_read on public.loan_penalties for select to authenticated
  using (business_id='BIZ-NYILORA' and exists (
    select 1 from public.loans l where l.id=loan_id
      and public.nyilora_can_read_portfolio(l.branch_id,l.loan_officer_id)));

grant select,insert,update on public.loan_clients,public.loan_products,
  public.loan_applications,public.loans,public.loan_schedules,public.loan_repayments to authenticated;
grant select on public.loan_penalties to authenticated;
grant select,update on public.nyilora_branches,public.loan_staff to authenticated;

commit;
