-- Nyilora only. Add fields used by existing application, schedule and penalty screens.
-- No data or financial amount is modified.
begin;

alter table public.loan_applications
  add column if not exists reviewed_by uuid references public.loan_staff(id);
alter table public.loan_schedules
  add column if not exists paid_at timestamptz;
alter table public.loan_penalties
  add column if not exists waived_reason text;

-- Daraja credentials must live in private Edge Function secrets, never in
-- a browser-readable settings row. Nyilora has not begun taking live payments.
alter table public.loan_settings
  drop column if exists mpesa_consumer_key,
  drop column if exists mpesa_consumer_secret,
  drop column if exists mpesa_passkey;

create policy nyilora_penalty_admin_update on public.loan_penalties for update to authenticated
  using (business_id='BIZ-NYILORA' and public.nyilora_has_role('admin'))
  with check (business_id='BIZ-NYILORA' and public.nyilora_has_role('admin'));
grant update on public.loan_penalties to authenticated;

-- Disbursement creates separate system fee records. Permit only charges tied
-- to a Nyilora loan/client pair handled by the signed-in officer or manager.
create policy nyilora_charge_system_insert on public.nyilora_charges for insert to authenticated
  with check (
    business_id='BIZ-NYILORA' and branch_id='00000000-0000-4000-8000-000000000001'
    and source='system' and loan_id is not null and created_by=public.nyilora_staff_id()
    and charge_type in ('processing_fee','registration_fee')
    and exists(select 1 from public.loans l where l.id=loan_id
      and l.business_id='BIZ-NYILORA' and l.client_id=client_id and l.branch_id=branch_id
      and (l.loan_officer_id=public.nyilora_staff_id() or public.nyilora_has_role('admin')
        or public.nyilora_has_role('branch_manager')))
  );

notify pgrst,'reload schema';
commit;
