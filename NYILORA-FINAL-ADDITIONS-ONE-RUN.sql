-- Nyilora Enterprise additions after migration 0019.
-- One atomic transaction. Run only in the Nyilora Supabase project.

begin;
-- Nyilora only. Complete asset access and fields used by SMS and payment callbacks.
-- Does not create loans, change repayment totals, or contact providers.

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


-- Nyilora only. Queue and reserve SMS credits atomically. Provider calls remain
-- in Nyilora Edge Functions and require Nyilora-specific secrets.

create unique index if not exists nyilora_sms_topup_reference_once
  on public.nyilora_sms_topups(business_id,upper(reference)) where reference is not null;

create or replace function public.nyilora_queue_repayment_sms()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_client public.loan_clients; v_loan public.loans; v_text text;
begin
  select * into v_loan from public.loans where id=new.loan_id and business_id='BIZ-NYILORA';
  select * into v_client from public.loan_clients where id=v_loan.client_id;
  if v_loan.id is null or v_client.id is null or nullif(trim(v_client.phone),'') is null then return new; end if;
  v_text:=format('Dear %s, we received KES %s for loan %s. Receipt %s. Thank you. Nyilora Enterprise',
    split_part(trim(v_client.full_name),' ',1),to_char(new.amount,'FM9999999990.00'),
    v_loan.loan_no,new.receipt_no);
  insert into public.nyilora_sms_outbox(client_id,loan_id,repayment_id,recipient,
    sender_id,message,sms_type,message_type,client_name,status)
  values(v_client.id,v_loan.id,new.id,v_client.phone,
    (select sender_id from public.nyilora_sms_wallets where business_id='BIZ-NYILORA'),
    v_text,'repayment','repayment',v_client.full_name,'queued')
  on conflict do nothing;
  return new;
end $$;
drop trigger if exists nyilora_repayment_sms_queue_trg on public.loan_repayments;
create trigger nyilora_repayment_sms_queue_trg after insert on public.loan_repayments
  for each row execute function public.nyilora_queue_repayment_sms();

create or replace function public.nyilora_queue_onboarding_sms()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.business_id='BIZ-NYILORA' and nullif(trim(new.phone),'') is not null then
    insert into public.nyilora_sms_outbox(client_id,recipient,sender_id,message,
      sms_type,message_type,client_name,status)
    values(new.id,new.phone,
      (select sender_id from public.nyilora_sms_wallets where business_id='BIZ-NYILORA'),
      'Welcome to Nyilora Enterprise, '||new.full_name||'. Your account is now registered.',
      'onboarding','onboarding',new.full_name,'queued');
  end if;
  return new;
end $$;
drop trigger if exists nyilora_onboarding_sms_queue_trg on public.loan_clients;
create trigger nyilora_onboarding_sms_queue_trg after insert on public.loan_clients
  for each row execute function public.nyilora_queue_onboarding_sms();

create or replace function public.nyilora_reserve_sms(p_outbox_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_row public.nyilora_sms_outbox; v_wallet public.nyilora_sms_wallets;
begin
  select * into v_row from public.nyilora_sms_outbox
    where id=p_outbox_id and business_id='BIZ-NYILORA' for update;
  if v_row.id is null then return jsonb_build_object('ok',false,'code','not_queued'); end if;
  if v_row.status='sent' then return jsonb_build_object('ok',true,'already_sent',true); end if;
  if v_row.status in ('sending','delivery_unknown') then
    return jsonb_build_object('ok',false,'code','delivery_in_progress_or_unknown'); end if;
  if v_row.status not in ('queued','failed','blocked_no_credit') then
    return jsonb_build_object('ok',false,'code','not_sendable'); end if;
  select * into v_wallet from public.nyilora_sms_wallets
    where business_id='BIZ-NYILORA' for update;
  if v_wallet.credits_remaining<=0 then
    update public.nyilora_sms_outbox set status='blocked_no_credit' where id=v_row.id;
    return jsonb_build_object('ok',false,'code','no_sms_credits');
  end if;
  update public.nyilora_sms_wallets set credits_remaining=credits_remaining-1,
    credits_used=credits_used+1,updated_at=now() where id=v_wallet.id;
  update public.nyilora_sms_outbox set status='sending',attempts=attempts+1,
    provider_error=null where id=v_row.id;
  return jsonb_build_object('ok',true,'outbox_id',v_row.id,'recipient',v_row.recipient,
    'message',v_row.message);
end $$;

create or replace function public.nyilora_claim_repayment_sms(p_repayment_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  select id into v_id from public.nyilora_sms_outbox
    where business_id='BIZ-NYILORA' and repayment_id=p_repayment_id;
  return public.nyilora_reserve_sms(v_id);
end $$;

create or replace function public.nyilora_claim_client_onboarding_sms(p_client_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  select id into v_id from public.nyilora_sms_outbox
    where business_id='BIZ-NYILORA' and client_id=p_client_id
      and message_type='onboarding' order by queued_at desc limit 1;
  return public.nyilora_reserve_sms(v_id);
end $$;

create or replace function public.nyilora_claim_custom_sms(
  p_business_id text,p_recipient text,p_message text,p_client_name text
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  if p_business_id<>'BIZ-NYILORA' or nullif(trim(p_recipient),'') is null
    or nullif(trim(p_message),'') is null or length(p_message)>1000 then
    raise exception 'Invalid Nyilora SMS request'; end if;
  insert into public.nyilora_sms_outbox(recipient,sender_id,message,sms_type,
    message_type,client_name,status)
  values(trim(p_recipient),
    (select sender_id from public.nyilora_sms_wallets where business_id='BIZ-NYILORA'),
    trim(p_message),'custom','custom',left(coalesce(p_client_name,'Manual SMS'),150),'queued')
  returning id into v_id;
  return public.nyilora_reserve_sms(v_id);
end $$;

create or replace function public.nyilora_claim_test_sms(p_business_id text,p_phone text)
returns jsonb language plpgsql security definer set search_path=public as $$
begin
  return public.nyilora_claim_custom_sms(p_business_id,p_phone,
    'Nyilora Enterprise SMS test. Your messaging service is connected.','System test');
end $$;

create or replace function public.nyilora_complete_repayment_sms(
  p_outbox_id uuid,p_status text,p_error text default null,p_refund boolean default false,
  p_provider_uid text default null,p_provider_response jsonb default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_row public.nyilora_sms_outbox;
begin
  if p_status not in ('sent','failed','delivery_unknown') then
    raise exception 'Invalid SMS result'; end if;
  select * into v_row from public.nyilora_sms_outbox
    where id=p_outbox_id and business_id='BIZ-NYILORA' for update;
  if v_row.id is null or v_row.status<>'sending' then
    return jsonb_build_object('ok',false,'code','not_sending'); end if;
  if p_refund and p_status<>'failed' then raise exception 'Only definite failures can refund a credit'; end if;
  update public.nyilora_sms_outbox set status=p_status,provider_error=left(p_error,1000),
    provider_uid=p_provider_uid,provider_response=p_provider_response,
    sent_at=case when p_status='sent' then now() else null end
  where id=v_row.id;
  if p_refund then
    update public.nyilora_sms_wallets set credits_remaining=credits_remaining+1,
      credits_used=credits_used-1,updated_at=now() where business_id='BIZ-NYILORA'; end if;
  return jsonb_build_object('ok',true,'status',p_status,'refunded',p_refund);
end $$;

create or replace function public.nyilora_owner_add_sms_credits(
  p_business_id text,p_credits integer,p_customer_amount_paid numeric,
  p_customer_reference text,p_note text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_balance integer; v_existing public.nyilora_sms_topups;
begin
  if p_business_id<>'BIZ-NYILORA' or p_credits is null or p_credits<=0
    or p_customer_amount_paid is null or p_customer_amount_paid<round(p_credits*0.55,2)
    or length(trim(coalesce(p_customer_reference,'')))<4 then
    raise exception 'Invalid Nyilora SMS purchase'; end if;
  select * into v_existing from public.nyilora_sms_topups
    where business_id='BIZ-NYILORA' and upper(reference)=upper(trim(p_customer_reference)) for update;
  if v_existing.id is not null then
    if v_existing.credits<>p_credits or v_existing.amount<>p_customer_amount_paid then
      raise exception 'SMS purchase reference was used for a different amount'; end if;
    select credits_remaining into v_balance from public.nyilora_sms_wallets
      where business_id='BIZ-NYILORA';
    return jsonb_build_object('ok',true,'already_credited',true,'remaining',v_balance);
  end if;
  insert into public.nyilora_sms_topups(credits,amount,reference)
  values(p_credits,p_customer_amount_paid,upper(trim(p_customer_reference))) returning id into v_id;
  update public.nyilora_sms_wallets set credits_purchased=credits_purchased+p_credits,
    credits_remaining=credits_remaining+p_credits,updated_at=now()
  where business_id='BIZ-NYILORA' returning credits_remaining into v_balance;
  insert into public.nyilora_domain_audit(action,entity_type,entity_id,new_value)
  values('sms_credits_purchased','nyilora_sms_topups',v_id::text,
    jsonb_build_object('credits',p_credits,'amount',p_customer_amount_paid,
      'reference',upper(trim(p_customer_reference)),'note',p_note));
  return jsonb_build_object('ok',true,'remaining',v_balance,'topup_id',v_id);
end $$;

revoke all on function public.nyilora_queue_repayment_sms(),
  public.nyilora_queue_onboarding_sms(),public.nyilora_reserve_sms(uuid),
  public.nyilora_claim_repayment_sms(uuid),public.nyilora_claim_client_onboarding_sms(uuid),
  public.nyilora_claim_custom_sms(text,text,text,text),
  public.nyilora_claim_test_sms(text,text),
  public.nyilora_complete_repayment_sms(uuid,text,text,boolean,text,jsonb),
  public.nyilora_owner_add_sms_credits(text,integer,numeric,text,text)
  from public,anon,authenticated;
grant execute on function public.nyilora_claim_repayment_sms(uuid),
  public.nyilora_claim_client_onboarding_sms(uuid),
  public.nyilora_claim_custom_sms(text,text,text,text),
  public.nyilora_claim_test_sms(text,text),
  public.nyilora_complete_repayment_sms(uuid,text,text,boolean,text,jsonb),
  public.nyilora_owner_add_sms_credits(text,integer,numeric,text,text)
  to service_role;
notify pgrst,'reload schema';


-- Nyilora only. One rollover per loan, preserving prior schedule rows.

create unique index if not exists nyilora_one_rollover_penalty_per_loan
  on public.loan_penalties(loan_id)
  where lower(coalesce(reason,'')) like '%rollover%';

create or replace function public.nyilora_apply_my_rollover_penalties()
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_actor public.loan_staff; v_loan public.loans; v_today date;
  v_pct numeric; v_penalty numeric(16,2); v_new_balance numeric(16,2);
  v_first numeric(16,2); v_last numeric(16,2); v_base integer;
  v_new integer:=0; v_arrears integer:=0;
begin
  v_actor:=public.nyilora_current_staff();
  if v_actor.id is null or not (public.nyilora_has_role('admin')
    or public.nyilora_has_role('branch_manager') or public.nyilora_has_role('loan_officer')) then
    raise exception 'Active Nyilora staff account required' using errcode='42501'; end if;
  v_today:=(now() at time zone 'Africa/Nairobi')::date;
  select coalesce(nullif(default_late_penalty_pct,0),15) into v_pct
    from public.loan_settings where business_id='BIZ-NYILORA';
  v_pct:=coalesce(v_pct,15);
  if v_pct<=0 or v_pct>100 then raise exception 'Invalid rollover penalty percentage'; end if;
  for v_loan in select l.* from public.loans l
    where l.business_id='BIZ-NYILORA' and l.status='active'
      and l.maturity_date is not null and v_today>l.maturity_date+2
      and l.outstanding_balance>0
      and (public.nyilora_has_role('admin')
        or public.nyilora_has_role('branch_manager')
        or l.loan_officer_id=v_actor.id)
    order by l.id for update of l
  loop
    if v_loan.rollover_applied or exists(select 1 from public.loan_penalties p
      where p.loan_id=v_loan.id and lower(coalesce(p.reason,'')) like '%rollover%') then
      update public.loans set rollover_applied=true,
        arrears_amount=least(outstanding_balance,round(v_loan.outstanding_balance,2)),
        overdue_days=greatest(0,v_today-v_loan.maturity_date),updated_at=now()
      where id=v_loan.id;
      v_arrears:=v_arrears+1;
      continue;
    end if;
    v_penalty:=round(v_loan.outstanding_balance*v_pct/100,2);
    if v_penalty<=0 then continue; end if;
    v_new_balance:=round(v_loan.outstanding_balance+v_penalty,2);
    v_first:=round(v_new_balance/3,2);
    v_last:=round(v_new_balance-2*v_first,2);
    select coalesce(max(installment_no),0) into v_base from public.loan_schedules
      where loan_id=v_loan.id;
    insert into public.loan_penalties(branch_id,loan_id,penalty_amount,date_charged,reason)
    values(v_loan.branch_id,v_loan.id,v_penalty,v_today,
      'Rollover Penalty ('||v_pct||'%) - '||v_today);
    insert into public.nyilora_charges(branch_id,client_id,loan_id,charge_type,
      description,amount,source,charge_date,created_by)
    values(v_loan.branch_id,v_loan.client_id,v_loan.id,'penalty',
      'One-time rollover penalty for loan '||v_loan.loan_no,
      v_penalty,'system',v_today,v_actor.id);
    -- Historical paid and partial schedule rows are retained. Unpaid rows are
    -- marked superseded so they no longer count as future dues.
    update public.loan_schedules set status='superseded',updated_at=now()
      where loan_id=v_loan.id and status in ('pending','partial','overdue');
    insert into public.loan_schedules(branch_id,loan_id,installment_no,due_date,
      principal_due,interest_due,total_due,status)
    values
      (v_loan.branch_id,v_loan.id,v_base+1,v_today+7,v_first,0,v_first,'pending'),
      (v_loan.branch_id,v_loan.id,v_base+2,v_today+14,v_first,0,v_first,'pending'),
      (v_loan.branch_id,v_loan.id,v_base+3,v_today+21,v_last,0,v_last,'pending');
    update public.loans set outstanding_balance=v_new_balance,
      total_payable=round(total_payable+v_penalty,2),
      weekly_installment=v_first,maturity_date=v_today+21,
      arrears_amount=0,overdue_days=0,rollover_applied=true,
      penalty_applied=true,updated_at=now() where id=v_loan.id;
    insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,entity_id,new_value)
    values(v_actor.id,'one_time_rollover','loans',v_loan.id::text,
      jsonb_build_object('penalty',v_penalty,'date',v_today,'new_balance',v_new_balance));
    v_new:=v_new+1;
  end loop;
  return jsonb_build_object('ok',true,'new_rollovers',v_new,
    'existing_rollovers_moved_to_arrears',v_arrears);
end $$;

-- Charge accrual already recognized penalty income and a receivable. When a
-- repayment later allocates to that charge, reverse its cash-basis income
-- posting and clear the receivable. This prevents recording income twice.
create or replace function public.nyilora_reconcile_paid_rollover_penalty()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_charge public.nyilora_charges; v_apply numeric(16,2);
begin
  if new.business_id<>'BIZ-NYILORA' or coalesce(new.penalty_portion,0)<=0 then return new; end if;
  select * into v_charge from public.nyilora_charges c
    where c.business_id='BIZ-NYILORA' and c.loan_id=new.loan_id
      and c.charge_type='penalty' and c.source='system'
      and c.status in ('pending','partially_paid')
    order by c.charge_date,c.id limit 1 for update;
  if v_charge.id is null then return new; end if;
  v_apply:=least(round(new.penalty_portion,2),round(v_charge.amount-v_charge.amount_paid,2));
  if v_apply<=0 then return new; end if;
  update public.nyilora_charges set amount_paid=amount_paid+v_apply,
    status=case when amount_paid+v_apply>=amount then 'paid' else 'partially_paid' end,
    settled_at=case when amount_paid+v_apply>=amount then now() else null end,
    updated_at=now() where id=v_charge.id;
  insert into public.nyilora_accounting_entries(branch_id,entry_date,account_code,
    account_name,account_type,debit,credit,description,source_table,source_id,
    entry_key,loan_id,created_by)
  values
    (new.branch_id,(new.payment_date at time zone 'Africa/Nairobi')::date,
      '4010','Penalty Income','income',v_apply,0,
      'Accrued penalty collected '||new.receipt_no,'loan_repayments',new.id::text,
      'accrued_penalty_income_reversal',new.loan_id,new.collected_by),
    (new.branch_id,(new.payment_date at time zone 'Africa/Nairobi')::date,
      '1150','Client Charges Receivable','asset',0,v_apply,
      'Accrued penalty collected '||new.receipt_no,'loan_repayments',new.id::text,
      'accrued_penalty_receivable',new.loan_id,new.collected_by)
  on conflict (business_id,source_table,source_id,entry_key) do nothing;
  return new;
end $$;
drop trigger if exists nyilora_reconcile_paid_rollover_penalty_trg on public.loan_repayments;
create trigger nyilora_reconcile_paid_rollover_penalty_trg after insert on public.loan_repayments
  for each row execute function public.nyilora_reconcile_paid_rollover_penalty();

revoke all on function public.nyilora_reconcile_paid_rollover_penalty(),
  public.nyilora_apply_my_rollover_penalties() from public,anon;
grant execute on function public.nyilora_apply_my_rollover_penalties() to authenticated;
notify pgrst,'reload schema';


-- Nyilora only. Treat verified-paybill callback money as suspense until
-- matched to a repayment or explicitly transferred to owner equity.

alter table public.mpesa_callback_queue
  add column if not exists resolved_to_equity boolean not null default false;

create or replace function public.nyilora_post_callback_suspense()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_paybill text;
begin
  select regexp_replace(coalesce(mpesa_shortcode,''),'\D','','g') into v_paybill
    from public.loan_settings where business_id='BIZ-NYILORA';
  if new.business_id<>'BIZ-NYILORA' or new.trans_amount<=0
    or nullif(v_paybill,'') is null
    or regexp_replace(coalesce(new.business_short_code,''),'\D','','g')<>v_paybill
    or exists(select 1 from public.loan_repayments r
      where r.business_id='BIZ-NYILORA' and
        (upper(r.payment_reference)=upper(new.trans_id)
          or upper(r.receipt_no)=upper(new.trans_id))) then return new; end if;
  insert into public.nyilora_accounting_entries(branch_id,entry_date,account_code,
    account_name,account_type,debit,credit,description,source_table,source_id,entry_key)
  values
    (new.branch_id,(now() at time zone 'Africa/Nairobi')::date,
      '1010','M-Pesa','asset',new.trans_amount,0,
      'Received pending M-Pesa '||new.trans_id,'mpesa_callback_queue',new.id::text,'cash_received'),
    (new.branch_id,(now() at time zone 'Africa/Nairobi')::date,
      '2200','Suspense','liability',0,new.trans_amount,
      'Received pending M-Pesa '||new.trans_id,'mpesa_callback_queue',new.id::text,'suspense_liability')
  on conflict (business_id,source_table,source_id,entry_key) do nothing;
  return new;
end $$;
drop trigger if exists nyilora_callback_suspense_journal_trg on public.mpesa_callback_queue;
create trigger nyilora_callback_suspense_journal_trg after insert on public.mpesa_callback_queue
  for each row execute function public.nyilora_post_callback_suspense();

create or replace function public.nyilora_clear_suspense_for_repayment()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_queue public.mpesa_callback_queue;
begin
  if new.business_id<>'BIZ-NYILORA' or lower(coalesce(new.payment_method,'')) not in ('mpesa','m-pesa')
    then return new; end if;
  select * into v_queue from public.mpesa_callback_queue q
    where q.business_id='BIZ-NYILORA' and q.branch_id=new.branch_id
      and upper(q.trans_id)=upper(coalesce(new.payment_reference,new.receipt_no))
    for update;
  if v_queue.id is null then return new; end if;
  if v_queue.dismissed or v_queue.resolved_to_equity or abs(v_queue.trans_amount-new.amount)>0.01 then
    raise exception 'Callback and repayment require manual review before recording'; end if;
  if not exists(select 1 from public.nyilora_accounting_entries e
    where e.business_id='BIZ-NYILORA' and e.source_table='mpesa_callback_queue'
      and e.source_id=v_queue.id::text and e.entry_key='suspense_liability') then
    return new; end if;
  insert into public.nyilora_accounting_entries(branch_id,entry_date,account_code,
    account_name,account_type,debit,credit,description,source_table,source_id,
    entry_key,loan_id,created_by)
  values
    (new.branch_id,(new.payment_date at time zone 'Africa/Nairobi')::date,
      '2200','Suspense','liability',new.amount,0,
      'Payment matched from suspense '||new.receipt_no,'loan_repayments',new.id::text,
      'suspense_cleared',new.loan_id,new.collected_by),
    (new.branch_id,(new.payment_date at time zone 'Africa/Nairobi')::date,
      '1010','M-Pesa','asset',0,new.amount,
      'Payment matched from suspense '||new.receipt_no,'loan_repayments',new.id::text,
      'cash_reclassified',new.loan_id,new.collected_by)
  on conflict (business_id,source_table,source_id,entry_key) do nothing;
  return new;
end $$;
drop trigger if exists nyilora_clear_suspense_repayment_trg on public.loan_repayments;
create trigger nyilora_clear_suspense_repayment_trg after insert on public.loan_repayments
  for each row execute function public.nyilora_clear_suspense_for_repayment();

create or replace function public.nyilora_suspense_to_equity(
  p_source_id text,p_amount numeric,p_description text,p_branch uuid
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_actor public.loan_staff; v_queue public.mpesa_callback_queue;
begin
  v_actor:=public.nyilora_current_staff();
  if v_actor.id is null or not public.nyilora_has_role('admin') then
    raise exception 'Administrator permission required' using errcode='42501'; end if;
  if p_branch is distinct from '00000000-0000-4000-8000-000000000001'::uuid
    then raise exception 'Invalid Nyilora branch'; end if;
  if length(trim(coalesce(p_description,'')))<5 then
    raise exception 'Enter the authorization or business reason'; end if;
  select * into v_queue from public.mpesa_callback_queue q
    where q.business_id='BIZ-NYILORA' and upper(q.trans_id)=upper(trim(p_source_id))
      and q.branch_id=p_branch for update;
  if v_queue.id is null or v_queue.confirmed or v_queue.dismissed or v_queue.resolved_to_equity
    or v_queue.repayment_id is not null then
    raise exception 'Open suspense transaction not found'; end if;
  if p_amount is null or round(p_amount,2)<>round(v_queue.trans_amount,2) then
    raise exception 'Transfer the exact open suspense amount'; end if;
  if exists(select 1 from public.loan_repayments r where r.business_id='BIZ-NYILORA'
    and (upper(r.payment_reference)=upper(v_queue.trans_id)
      or upper(r.receipt_no)=upper(v_queue.trans_id))) then
    raise exception 'Payment was already recorded'; end if;
  if not exists(select 1 from public.nyilora_accounting_entries e
    where e.business_id='BIZ-NYILORA' and e.source_table='mpesa_callback_queue'
      and e.source_id=v_queue.id::text and e.entry_key='suspense_liability') then
    raise exception 'No suspense balance was posted for this callback'; end if;
  insert into public.nyilora_accounting_entries(branch_id,entry_date,account_code,
    account_name,account_type,debit,credit,description,source_table,source_id,entry_key,
    created_by)
  values
    (p_branch,(now() at time zone 'Africa/Nairobi')::date,'2200','Suspense','liability',
      p_amount,0,trim(p_description),'suspense_equity',v_queue.id::text,
      'suspense_debit',v_actor.id),
    (p_branch,(now() at time zone 'Africa/Nairobi')::date,'3000','Owner Capital / Equity',
      'equity',0,p_amount,trim(p_description),'suspense_equity',v_queue.id::text,
      'equity_credit',v_actor.id);
  update public.mpesa_callback_queue set resolved_to_equity=true,
    review_reason=left(trim(p_description),1000),updated_at=now()
    where id=v_queue.id;
  insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,entity_id,new_value)
  values(v_actor.id,'suspense_transferred_to_equity','mpesa_callback_queue',v_queue.id::text,
    jsonb_build_object('amount',p_amount,'reference',v_queue.trans_id,
      'reason',trim(p_description)));
  return jsonb_build_object('ok',true,'amount',p_amount,'reference',v_queue.trans_id);
end $$;

-- Keep the existing paged shape while excluding money formally transferred
-- to equity. Neither dismissed nor transferred callbacks can be reallocated.
create or replace function public.nyilora_suspense_page(
  p_source text,p_branch uuid default null,p_after uuid default null,p_limit integer default 500
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_actor public.loan_staff; v_rows jsonb;
  v_size integer:=least(greatest(coalesce(p_limit,500),1),500);
  v_branch constant uuid:='00000000-0000-4000-8000-000000000001';
begin
  v_actor:=public.nyilora_current_staff();
  if v_actor.id is null or not (public.nyilora_has_role('admin')
    or public.nyilora_has_role('branch_manager') or public.nyilora_has_role('cashier')
    or public.nyilora_has_role('loan_officer')) then
    raise exception 'Suspense access is not permitted' using errcode='42501'; end if;
  if p_branch is not null and p_branch<>v_branch then raise exception 'Invalid Nyilora branch'; end if;
  if p_source='queue' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb) into v_rows from (
      select q.* from public.mpesa_callback_queue q
      where q.business_id='BIZ-NYILORA' and q.branch_id=v_branch
        and not q.confirmed and not q.dismissed and not q.resolved_to_equity
        and q.repayment_id is null and (p_after is null or q.id>p_after)
        and not exists(select 1 from public.loan_repayments r
          where r.business_id='BIZ-NYILORA' and
          (upper(r.payment_reference)=upper(q.trans_id) or upper(r.receipt_no)=upper(q.trans_id)))
        and not exists(select 1 from public.unmatched_payments u
          where u.business_id='BIZ-NYILORA' and upper(u.mpesa_reference)=upper(q.trans_id)
            and (u.resolved or u.dismissed))
      order by q.id limit v_size
    ) x;
  elsif p_source='manual' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb) into v_rows from (
      select u.* from public.unmatched_payments u
      where u.business_id='BIZ-NYILORA' and u.branch_id=v_branch
        and not u.resolved and not u.dismissed and u.repayment_id is null
        and (p_after is null or u.id>p_after)
        and not exists(select 1 from public.loan_repayments r
          where r.business_id='BIZ-NYILORA' and
          (upper(r.payment_reference)=upper(u.mpesa_reference)
            or upper(r.receipt_no)=upper(u.mpesa_reference)))
      order by u.id limit v_size
    ) x;
  else raise exception 'Unsupported Suspense source'; end if;
  return jsonb_build_object('rows',v_rows,
    'next_after',case when jsonb_array_length(v_rows)=v_size
      then v_rows->(v_size-1)->>'id' else null end);
end $$;

revoke all on function public.nyilora_post_callback_suspense(),
  public.nyilora_clear_suspense_for_repayment() from public,anon,authenticated;
revoke all on function public.nyilora_suspense_to_equity(text,numeric,text,uuid)
  from public,anon;
grant execute on function public.nyilora_suspense_to_equity(text,numeric,text,uuid)
  to authenticated;
notify pgrst,'reload schema';


-- Nyilora only. Idempotent processing-fee callback settlement.

create or replace function public.nyilora_record_callback_charge_payment(
  p_business_id text,p_client_id uuid,p_loan_id uuid,p_charge_id uuid,
  p_amount numeric,p_payment_reference text,p_payment_date timestamptz,
  p_payer_name text default null,p_payer_phone text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_charge public.nyilora_charges; v_loan public.loans;
  v_existing uuid; v_paid numeric(16,2); v_excess numeric(16,2);
begin
  if p_business_id<>'BIZ-NYILORA' or p_amount is null or p_amount<=0
    or round(p_amount,2)<>p_amount or length(trim(coalesce(p_payment_reference,'')))<4
    then raise exception 'Invalid Nyilora processing-fee callback'; end if;
  select r.id into v_existing from public.loan_repayments r
    where r.business_id='BIZ-NYILORA' and
      (upper(r.payment_reference)=upper(trim(p_payment_reference))
        or upper(r.receipt_no)=upper(trim(p_payment_reference))) limit 1;
  if v_existing is not null then
    return jsonb_build_object('ok',true,'duplicate',true,'repayment_id',v_existing); end if;
  select * into v_loan from public.loans
    where id=p_loan_id and business_id='BIZ-NYILORA' for update;
  select * into v_charge from public.nyilora_charges
    where id=p_charge_id and business_id='BIZ-NYILORA' for update;
  if v_loan.id is null or v_charge.id is null or v_loan.client_id<>p_client_id
    or v_charge.client_id<>p_client_id or v_charge.loan_id<>v_loan.id
    or v_charge.branch_id<>v_loan.branch_id or v_charge.charge_type<>'processing_fee'
    or v_charge.status not in ('pending','partially_paid') then
    raise exception 'Open Nyilora processing fee does not match the loan'; end if;
  v_paid:=least(round(p_amount,2),round(v_charge.amount-v_charge.amount_paid,2));
  if v_paid<=0 then raise exception 'Processing fee is already paid'; end if;
  v_excess:=round(p_amount-v_paid,2);
  insert into public.loan_repayments(branch_id,loan_id,receipt_no,amount,
    payment_method,payment_reference,payment_date,sender_name,sender_phone,
    processing_fee_portion,credit_portion,mpesa_confirmed,notes)
  values(v_loan.branch_id,v_loan.id,upper(trim(p_payment_reference)),p_amount,
    'M-Pesa',upper(trim(p_payment_reference)),coalesce(p_payment_date,now()),
    nullif(trim(p_payer_name),''),nullif(trim(p_payer_phone),''),
    v_paid,v_excess,true,'Nyilora processing fee received from callback')
  returning id into v_existing;
  update public.nyilora_charges set amount_paid=amount_paid+v_paid,
    status=case when amount_paid+v_paid>=amount then 'paid' else 'partially_paid' end,
    settled_at=case when amount_paid+v_paid>=amount then coalesce(p_payment_date,now()) else null end,
    settlement_note='M-Pesa '||upper(trim(p_payment_reference)),updated_at=now()
  where id=v_charge.id;
  update public.loans set processing_fee_paid=least(processing_fee,
    coalesce(processing_fee_paid,0)+v_paid),updated_at=now() where id=v_loan.id;
  insert into public.nyilora_domain_audit(action,entity_type,entity_id,new_value)
  values('callback_processing_fee_paid','loan_repayments',v_existing::text,
    jsonb_build_object('charge_id',v_charge.id,'paid',v_paid,
      'excess',v_excess,'reference',upper(trim(p_payment_reference))));
  return jsonb_build_object('ok',true,'repayment_id',v_existing,
    'processing_fee_paid',v_paid,'excess_recorded',v_excess,
    'loan_balance_unchanged',v_loan.outstanding_balance);
end $$;

-- The system charge already posted fee income and a receivable. Offset the
-- cash-basis fee income from the repayment journal and clear the receivable.
create or replace function public.nyilora_reconcile_accrued_processing_fee()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_charge public.nyilora_charges; v_apply numeric(16,2);
begin
  if new.business_id<>'BIZ-NYILORA' or coalesce(new.processing_fee_portion,0)<=0
    then return new; end if;
  select * into v_charge from public.nyilora_charges c
    where c.business_id='BIZ-NYILORA' and c.loan_id=new.loan_id
      and c.charge_type='processing_fee' and c.source='system'
    limit 1;
  if v_charge.id is null then return new; end if;
  v_apply:=least(round(new.processing_fee_portion,2),v_charge.amount);
  insert into public.nyilora_accounting_entries(branch_id,entry_date,account_code,
    account_name,account_type,debit,credit,description,source_table,source_id,
    entry_key,loan_id,created_by)
  values
    (new.branch_id,(new.payment_date at time zone 'Africa/Nairobi')::date,
      '4020','Processing Fee Income','income',v_apply,0,
      'Accrued fee collected '||new.receipt_no,'loan_repayments',new.id::text,
      'accrued_fee_income_reversal',new.loan_id,new.collected_by),
    (new.branch_id,(new.payment_date at time zone 'Africa/Nairobi')::date,
      '1150','Client Charges Receivable','asset',0,v_apply,
      'Accrued fee collected '||new.receipt_no,'loan_repayments',new.id::text,
      'accrued_fee_receivable',new.loan_id,new.collected_by)
  on conflict (business_id,source_table,source_id,entry_key) do nothing;
  return new;
end $$;
drop trigger if exists nyilora_reconcile_accrued_processing_fee_trg on public.loan_repayments;
create trigger nyilora_reconcile_accrued_processing_fee_trg after insert on public.loan_repayments
  for each row execute function public.nyilora_reconcile_accrued_processing_fee();

revoke all on function public.nyilora_record_callback_charge_payment(
  text,uuid,uuid,uuid,numeric,text,timestamptz,text,text),
  public.nyilora_reconcile_accrued_processing_fee() from public,anon,authenticated;
grant execute on function public.nyilora_record_callback_charge_payment(
  text,uuid,uuid,uuid,numeric,text,timestamptz,text,text) to service_role;
notify pgrst,'reload schema';


-- Nyilora only. Keep the agreed KES 3,000 subscription and KES 0.55 SMS
-- price authoritative in the database as well as the Edge Functions.

alter table public.loan_billing_cycles
  add column if not exists result_description text,
  add column if not exists actual_amount numeric(16,2);
alter table public.loan_billing_transactions
  add column if not exists result_code text,
  add column if not exists result_description text,
  add column if not exists raw_payload jsonb;

create or replace function public.nyilora_check_subscription_cycle()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.business_id<>'BIZ-NYILORA' or new.billing_month<date '2026-12-01'
    or date_trunc('month',new.billing_month)::date<>new.billing_month
    or new.amount<>3000 then
    raise exception 'Nyilora subscription is KES 3,000 per month from December 2026'; end if;
  if new.status='paid' and (new.actual_amount is null or new.actual_amount<3000
    or new.paid_at is null or new.paid_until is null) then
    raise exception 'A paid period requires a verified KES 3,000 payment'; end if;
  if tg_op='UPDATE' and old.status='paid' and
    (new.status<>'paid' or new.paid_until<old.paid_until) then
    raise exception 'Already-paid billing periods cannot be reopened or shortened'; end if;
  return new;
end $$;
drop trigger if exists nyilora_subscription_cycle_guard_trg on public.loan_billing_cycles;
create trigger nyilora_subscription_cycle_guard_trg before insert or update
  on public.loan_billing_cycles for each row
  execute function public.nyilora_check_subscription_cycle();

create or replace function public.nyilora_check_sms_bundle_price()
returns trigger language plpgsql set search_path=public as $$
begin
  if new.business_id<>'BIZ-NYILORA' or new.credits<=0
    or new.amount<>round(new.credits*0.55,2) then
    raise exception 'Nyilora SMS bundle price must be KES 0.55 per credit'; end if;
  if tg_op='UPDATE' and (new.credits<>old.credits or new.amount<>old.amount
    or new.business_id<>old.business_id) then
    raise exception 'SMS bundle quantity and price cannot change after request'; end if;
  return new;
end $$;
drop trigger if exists nyilora_sms_bundle_price_guard_trg
  on public.nyilora_sms_bundle_requests;
create trigger nyilora_sms_bundle_price_guard_trg before insert or update
  on public.nyilora_sms_bundle_requests for each row
  execute function public.nyilora_check_sms_bundle_price();

revoke all on function public.nyilora_check_subscription_cycle(),
  public.nyilora_check_sms_bundle_price() from public,anon,authenticated;
notify pgrst,'reload schema';

commit;

