-- Nyilora only. Queue and reserve SMS credits atomically. Provider calls remain
-- in Nyilora Edge Functions and require Nyilora-specific secrets.
begin;

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
commit;
