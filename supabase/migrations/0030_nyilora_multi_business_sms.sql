-- Route service-role SMS claims and credit purchases by the source business.
begin;

create or replace function public.nyilora_queue_repayment_sms()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_client public.loan_clients; v_loan public.loans; v_company text;
begin
  select * into v_loan from public.loans
    where id=new.loan_id and business_id=new.business_id;
  select * into v_client from public.loan_clients
    where id=v_loan.client_id and business_id=new.business_id;
  if v_loan.id is null or v_client.id is null
    or nullif(trim(v_client.phone),'') is null then return new; end if;
  select company_name into v_company from public.loan_settings
    where business_id=new.business_id;
  insert into public.nyilora_sms_outbox(business_id,branch_id,client_id,loan_id,
    repayment_id,recipient,sender_id,message,sms_type,message_type,client_name,status)
  values(new.business_id,new.branch_id,v_client.id,v_loan.id,new.id,v_client.phone,
    (select sender_id from public.nyilora_sms_wallets where business_id=new.business_id),
    format('Dear %s, we received KES %s for loan %s. Receipt %s. Thank you. %s',
      split_part(trim(v_client.full_name),' ',1),to_char(new.amount,'FM9999999990.00'),
      v_loan.loan_no,new.receipt_no,coalesce(v_company,'Your lender')),
    'repayment','repayment',v_client.full_name,'queued') on conflict do nothing;
  return new;
end $$;

create or replace function public.nyilora_queue_onboarding_sms()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_company text;
begin
  if nullif(trim(new.phone),'') is null then return new; end if;
  select company_name into v_company from public.loan_settings
    where business_id=new.business_id;
  insert into public.nyilora_sms_outbox(business_id,branch_id,client_id,
    recipient,sender_id,message,sms_type,message_type,client_name,status)
  values(new.business_id,new.branch_id,new.id,new.phone,
    (select sender_id from public.nyilora_sms_wallets where business_id=new.business_id),
    'Welcome to '||coalesce(v_company,'your lender')||', '||new.full_name||
      '. Your account is now registered.',
    'onboarding','onboarding',new.full_name,'queued');
  return new;
end $$;

create or replace function public.nyilora_reserve_sms(p_outbox_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_row public.nyilora_sms_outbox; v_wallet public.nyilora_sms_wallets;
begin
  select * into v_row from public.nyilora_sms_outbox where id=p_outbox_id for update;
  if v_row.id is null then return jsonb_build_object('ok',false,'code','not_queued'); end if;
  if auth.uid() is not null and v_row.business_id<>public.nyilora_current_business_id() then
    raise exception 'SMS belongs to another business'; end if;
  if v_row.status='sent' then return jsonb_build_object('ok',true,'already_sent',true); end if;
  if v_row.status in ('sending','delivery_unknown') then
    return jsonb_build_object('ok',false,'code','delivery_in_progress_or_unknown'); end if;
  if v_row.status not in ('queued','failed','blocked_no_credit') then
    return jsonb_build_object('ok',false,'code','not_sendable'); end if;
  select * into v_wallet from public.nyilora_sms_wallets
    where business_id=v_row.business_id for update;
  if v_wallet.id is null then raise exception 'SMS wallet is missing'; end if;
  if v_wallet.credits_remaining<=0 then
    update public.nyilora_sms_outbox set status='blocked_no_credit' where id=v_row.id;
    return jsonb_build_object('ok',false,'code','no_sms_credits'); end if;
  update public.nyilora_sms_wallets set credits_remaining=credits_remaining-1,
    credits_used=credits_used+1,updated_at=now() where id=v_wallet.id;
  update public.nyilora_sms_outbox set status='sending',attempts=attempts+1,
    provider_error=null where id=v_row.id;
  return jsonb_build_object('ok',true,'outbox_id',v_row.id,'business_id',v_row.business_id,
    'recipient',v_row.recipient,'message',v_row.message,'sender_id',v_row.sender_id);
end $$;

create or replace function public.nyilora_claim_repayment_sms(p_repayment_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  select id into v_id from public.nyilora_sms_outbox where repayment_id=p_repayment_id;
  return public.nyilora_reserve_sms(v_id);
end $$;

create or replace function public.nyilora_claim_client_onboarding_sms(p_client_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id uuid;
begin
  select id into v_id from public.nyilora_sms_outbox
    where client_id=p_client_id and message_type='onboarding'
    order by queued_at desc limit 1;
  return public.nyilora_reserve_sms(v_id);
end $$;

create or replace function public.nyilora_claim_custom_sms(
  p_business_id text,p_recipient text,p_message text,p_client_name text)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_branch uuid; v_sender text;
begin
  if nullif(trim(p_recipient),'') is null or nullif(trim(p_message),'') is null
    or length(p_message)>1000 then raise exception 'Invalid SMS request'; end if;
  if auth.uid() is not null and p_business_id<>public.nyilora_current_business_id() then
    raise exception 'Cannot send another business''s SMS'; end if;
  select b.id into v_branch from public.nyilora_branches b
    where b.business_id=p_business_id and b.is_head_office and b.is_active;
  if v_branch is null then raise exception 'Business branch is missing'; end if;
  select sender_id into v_sender from public.nyilora_sms_wallets
    where business_id=p_business_id;
  insert into public.nyilora_sms_outbox(business_id,branch_id,recipient,sender_id,
    message,sms_type,message_type,client_name,status)
  values(p_business_id,v_branch,trim(p_recipient),v_sender,trim(p_message),
    'custom','custom',left(coalesce(p_client_name,'Manual SMS'),150),'queued')
  returning id into v_id;
  return public.nyilora_reserve_sms(v_id);
end $$;

create or replace function public.nyilora_complete_repayment_sms(
  p_outbox_id uuid,p_status text,p_error text default null,p_refund boolean default false,
  p_provider_uid text default null,p_provider_response jsonb default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_row public.nyilora_sms_outbox;
begin
  if p_status not in ('sent','failed','delivery_unknown') then raise exception 'Invalid SMS result'; end if;
  select * into v_row from public.nyilora_sms_outbox where id=p_outbox_id for update;
  if v_row.id is null or v_row.status<>'sending' then
    return jsonb_build_object('ok',false,'code','not_sending'); end if;
  if auth.uid() is not null and v_row.business_id<>public.nyilora_current_business_id() then
    raise exception 'SMS belongs to another business'; end if;
  if p_refund and p_status<>'failed' then raise exception 'Only definite failures can refund a credit'; end if;
  update public.nyilora_sms_outbox set status=p_status,provider_error=left(p_error,1000),
    provider_uid=p_provider_uid,provider_response=p_provider_response,
    sent_at=case when p_status='sent' then now() else null end where id=v_row.id;
  if p_refund then
    update public.nyilora_sms_wallets set credits_remaining=credits_remaining+1,
      credits_used=credits_used-1,updated_at=now()
    where business_id=v_row.business_id; end if;
  return jsonb_build_object('ok',true,'business_id',v_row.business_id,
    'status',p_status,'refunded',p_refund);
end $$;

create or replace function public.nyilora_owner_add_sms_credits(
  p_business_id text,p_credits integer,p_customer_amount_paid numeric,
  p_customer_reference text,p_note text default null)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_id uuid; v_balance integer; v_existing public.nyilora_sms_topups;
  v_branch uuid;
begin
  if p_credits is null or p_credits<=0 or p_customer_amount_paid is null
    or p_customer_amount_paid<round(p_credits*0.55,2)
    or length(trim(coalesce(p_customer_reference,'')))<4 then
    raise exception 'Invalid SMS purchase'; end if;
  if auth.uid() is not null then raise exception 'Service authorization required'; end if;
  select id into v_branch from public.nyilora_branches
    where business_id=p_business_id and is_head_office and is_active;
  if v_branch is null then raise exception 'Business branch is missing'; end if;
  select * into v_existing from public.nyilora_sms_topups
    where business_id=p_business_id
      and upper(reference)=upper(trim(p_customer_reference)) for update;
  if v_existing.id is not null then
    if v_existing.credits<>p_credits or v_existing.amount<>p_customer_amount_paid then
      raise exception 'SMS purchase reference was used for a different amount'; end if;
    select credits_remaining into v_balance from public.nyilora_sms_wallets
      where business_id=p_business_id;
    return jsonb_build_object('ok',true,'already_credited',true,'remaining',v_balance);
  end if;
  insert into public.nyilora_sms_topups(business_id,credits,amount,reference)
  values(p_business_id,p_credits,p_customer_amount_paid,
    upper(trim(p_customer_reference))) returning id into v_id;
  update public.nyilora_sms_wallets set credits_purchased=credits_purchased+p_credits,
    credits_remaining=credits_remaining+p_credits,updated_at=now()
    where business_id=p_business_id returning credits_remaining into v_balance;
  insert into public.nyilora_domain_audit(business_id,branch_id,action,
    entity_type,entity_id,new_value)
  values(p_business_id,v_branch,'sms_credits_purchased','nyilora_sms_topups',v_id::text,
    jsonb_build_object('credits',p_credits,'amount',p_customer_amount_paid,
      'reference',upper(trim(p_customer_reference)),'note',p_note));
  return jsonb_build_object('ok',true,'remaining',v_balance,'topup_id',v_id);
end $$;

revoke all on function public.nyilora_reserve_sms(uuid),
  public.nyilora_claim_repayment_sms(uuid),public.nyilora_claim_client_onboarding_sms(uuid),
  public.nyilora_claim_custom_sms(text,text,text,text),
  public.nyilora_complete_repayment_sms(uuid,text,text,boolean,text,jsonb),
  public.nyilora_owner_add_sms_credits(text,integer,numeric,text,text)
  from public,anon,authenticated;
grant execute on function public.nyilora_claim_repayment_sms(uuid),
  public.nyilora_claim_client_onboarding_sms(uuid),
  public.nyilora_claim_custom_sms(text,text,text,text),
  public.nyilora_complete_repayment_sms(uuid,text,text,boolean,text,jsonb),
  public.nyilora_owner_add_sms_credits(text,integer,numeric,text,text)
  to service_role;
notify pgrst,'reload schema';
commit;
