-- Nyilora only. Complete asset access and fields used by SMS and payment callbacks.
-- Does not create loans, change repayment totals, or contact providers.
begin;

alter table public.nyilora_sms_outbox
  add column if not exists message_type text,
  add column if not exists client_name text;
alter table public.nyilora_sms_bundle_requests
  add column if not exists paid_at timestamptz,
  add column if not exists credited_at timestamptz,
  add column if not exists payment_reference text,
  add column if not exists result_code text;
create unique index if not exists nyilora_sms_bundle_paid_reference_once
  on public.nyilora_sms_bundle_requests(upper(payment_reference))
  where payment_reference is not null;

-- Only an authenticated Nyilora administrator or staff member with explicit
-- asset permission can write the asset register. Single-branch membership is
-- enforced on both the original and updated row.
drop policy if exists nyilora_asset_read on public.nyilora_assets;
create policy nyilora_asset_read on public.nyilora_assets for select to authenticated
  using (business_id='BIZ-NYILORA' and
    (public.nyilora_can('manage_assets') or public.nyilora_has_role('branch_manager')));
drop policy if exists nyilora_asset_insert on public.nyilora_assets;
create policy nyilora_asset_insert on public.nyilora_assets for insert to authenticated
  with check (business_id='BIZ-NYILORA'
    and branch_id='00000000-0000-4000-8000-000000000001'
    and created_by=public.nyilora_staff_id()
    and (public.nyilora_can('manage_assets') or public.nyilora_has_role('branch_manager'))
    and (custodian_staff_id is null or exists(select 1 from public.loan_staff s
      where s.id=custodian_staff_id and s.business_id='BIZ-NYILORA'
        and s.branch_id=nyilora_assets.branch_id and s.is_active)));
drop policy if exists nyilora_asset_update on public.nyilora_assets;
create policy nyilora_asset_update on public.nyilora_assets for update to authenticated
  using (business_id='BIZ-NYILORA' and
    (public.nyilora_can('manage_assets') or public.nyilora_has_role('branch_manager')))
  with check (business_id='BIZ-NYILORA'
    and branch_id='00000000-0000-4000-8000-000000000001'
    and (public.nyilora_can('manage_assets') or public.nyilora_has_role('branch_manager'))
    and (custodian_staff_id is null or exists(select 1 from public.loan_staff s
      where s.id=custodian_staff_id and s.business_id='BIZ-NYILORA'
        and s.branch_id=nyilora_assets.branch_id and s.is_active)));

create or replace function public.nyilora_asset_guard_audit()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_actor uuid; v_action text;
begin
  v_actor:=public.nyilora_staff_id();
  if v_actor is null or not (public.nyilora_can('manage_assets')
    or public.nyilora_has_role('branch_manager')) then
    raise exception 'Asset management permission required' using errcode='42501'; end if;
  if tg_op='INSERT' then
    if new.business_id<>'BIZ-NYILORA' or new.created_by<>v_actor then
      raise exception 'Asset owner does not match signed-in Nyilora staff'; end if;
    return new;
  end if;
  if old.business_id<>new.business_id or old.id<>new.id or old.created_by<>new.created_by
     or old.initial_price<>new.initial_price or old.purchase_date is distinct from new.purchase_date then
    raise exception 'Asset purchase details are immutable; record a separate adjustment'; end if;
  if old.status='disposed' and new.status<>old.status then
    raise exception 'Disposed assets cannot be reopened'; end if;
  if old.status<>'disposed' and new.status='disposed' and new.disposed_at is null then
    raise exception 'Enter the asset disposal date'; end if;
  return new;
end $$;

create or replace function public.nyilora_asset_after_change()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_actor uuid:=public.nyilora_staff_id(); v_action text;
begin
  v_action:=case when tg_op='INSERT' then 'created'
    when new.status='disposed' and old.status<>'disposed' then 'disposed'
    when new.branch_id<>old.branch_id or new.custodian_staff_id is distinct from old.custodian_staff_id then 'transferred'
    else 'updated' end;
  insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,entity_id,old_value,new_value)
  values(v_actor,'asset_'||v_action,'nyilora_assets',new.id::text,
    case when tg_op='INSERT' then null else to_jsonb(old) end,to_jsonb(new));
  if v_action in ('created','transferred','disposed') then
    insert into public.nyilora_asset_movements
      (asset_id,from_branch_id,to_branch_id,from_custodian_id,to_custodian_id,action,performed_by)
    values(new.id,case when tg_op='INSERT' then null else old.branch_id end,new.branch_id,
      case when tg_op='INSERT' then null else old.custodian_staff_id end,
      new.custodian_staff_id,v_action,v_actor);
  end if;
  return new;
end $$;
drop trigger if exists nyilora_asset_guard_trg on public.nyilora_assets;
create trigger nyilora_asset_guard_trg before insert or update on public.nyilora_assets
  for each row execute function public.nyilora_asset_guard_audit();
drop trigger if exists nyilora_asset_audit_trg on public.nyilora_assets;
create trigger nyilora_asset_audit_trg after insert or update on public.nyilora_assets
  for each row execute function public.nyilora_asset_after_change();
drop policy if exists nyilora_asset_movement_read on public.nyilora_asset_movements;
create policy nyilora_asset_movement_read on public.nyilora_asset_movements
  for select to authenticated using (business_id='BIZ-NYILORA' and
    (public.nyilora_can('manage_assets') or public.nyilora_has_role('branch_manager')));
revoke insert,update,delete on public.nyilora_asset_movements from authenticated;

-- Provider callbacks use the account reference alone. A transaction reference
-- already recorded as a repayment produces no candidate on retry.
create or replace function public.nyilora_callback_phone_candidates(
  p_account_reference text,p_transaction_code text
) returns table(id uuid,business_id text,full_name text,account_credit numeric)
language sql stable security definer set search_path=public as $$
  select c.id,c.business_id,c.full_name,c.account_credit
  from public.loan_clients c
  where c.business_id='BIZ-NYILORA'
    and length(regexp_replace(coalesce(p_account_reference,''),'\D','','g')) between 9 and 12
    and right(regexp_replace(coalesce(c.phone,''),'\D','','g'),9)=
        right(regexp_replace(coalesce(p_account_reference,''),'\D','','g'),9)
    and not exists(select 1 from public.loan_repayments r
      where r.business_id='BIZ-NYILORA'
        and (upper(r.payment_reference)=upper(p_transaction_code)
          or upper(r.receipt_no)=upper(p_transaction_code)))
  order by c.id limit 2
$$;
revoke all on function public.nyilora_callback_phone_candidates(text,text) from public,anon,authenticated;
grant execute on function public.nyilora_callback_phone_candidates(text,text) to service_role;

revoke all on function public.nyilora_asset_guard_audit(),
  public.nyilora_asset_after_change() from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
