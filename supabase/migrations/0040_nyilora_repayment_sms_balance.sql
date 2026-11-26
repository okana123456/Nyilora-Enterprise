-- Nyilora only: show the loan balance after each repayment in SMS.
-- The repayment insert precedes the app's loan update, so use loan_portion
-- for the initial snapshot. A claim refreshes the latest payment from the
-- completed loan row when that update can be identified safely.
begin;

create or replace function public.nyilora_repayment_sms_text(
  p_client_name text,p_amount numeric,p_loan_no text,p_receipt text,
  p_balance numeric,p_company text)
returns text language sql stable set search_path=public as $$
  select format('Dear %s, we received KES %s for loan %s. Balance: KES %s. Receipt %s. Thank you. %s',
    split_part(trim(coalesce(p_client_name,'')),' ',1),
    to_char(p_amount,'FM9999999990.00'),p_loan_no,
    to_char(greatest(0,round(p_balance,2)),'FM9999999990.00'),
    p_receipt,coalesce(p_company,'Your lender'))
$$;

create or replace function public.nyilora_queue_repayment_sms()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_client public.loan_clients; v_loan public.loans; v_company text;
  v_balance numeric;
begin
  select * into v_loan from public.loans
    where id=new.loan_id and business_id=new.business_id;
  select * into v_client from public.loan_clients
    where id=v_loan.client_id and business_id=new.business_id;
  if v_loan.id is null or v_client.id is null
    or nullif(trim(v_client.phone),'') is null then return new; end if;
  select company_name into v_company from public.loan_settings
    where business_id=new.business_id;
  v_balance:=greatest(0,round(v_loan.outstanding_balance-coalesce(new.loan_portion,0),2));
  insert into public.nyilora_sms_outbox(business_id,branch_id,client_id,loan_id,
    repayment_id,recipient,sender_id,message,sms_type,message_type,client_name,status)
  values(new.business_id,new.branch_id,v_client.id,v_loan.id,new.id,v_client.phone,
    (select sender_id from public.nyilora_sms_wallets where business_id=new.business_id),
    public.nyilora_repayment_sms_text(v_client.full_name,new.amount,
      v_loan.loan_no,new.receipt_no,v_balance,v_company),
    'repayment','repayment',v_client.full_name,'queued') on conflict do nothing;
  return new;
end $$;

create or replace function public.nyilora_claim_repayment_sms(p_repayment_id uuid)
returns jsonb language plpgsql security definer set search_path=public as $$
declare v_row public.nyilora_sms_outbox; v_repayment public.loan_repayments;
  v_loan public.loans; v_company text;
begin
  select * into v_row from public.nyilora_sms_outbox
    where repayment_id=p_repayment_id for update;
  if v_row.id is null then return jsonb_build_object('ok',false,'code','not_queued'); end if;
  if v_row.status in ('queued','failed','blocked_no_credit') then
    select * into v_repayment from public.loan_repayments
      where id=p_repayment_id and business_id=v_row.business_id;
    select * into v_loan from public.loans
      where id=v_row.loan_id and business_id=v_row.business_id;
    -- Only the latest repayment can use the current loan balance. The loan
    -- update must have followed that repayment promptly; later edits or
    -- restructures make a historical balance uncertain.
    if v_repayment.id is not null and v_loan.id is not null
      and v_loan.updated_at>=v_repayment.created_at
      and v_loan.updated_at<=v_repayment.created_at+interval '2 minutes'
      and not exists(select 1 from public.loan_repayments later
        where later.loan_id=v_repayment.loan_id
          and later.business_id=v_repayment.business_id
          and (later.created_at,later.id)>(v_repayment.created_at,v_repayment.id)) then
      select company_name into v_company from public.loan_settings
        where business_id=v_row.business_id;
      update public.nyilora_sms_outbox
      set message=public.nyilora_repayment_sms_text(v_row.client_name,
        v_repayment.amount,v_loan.loan_no,v_repayment.receipt_no,
        v_loan.outstanding_balance,v_company)
      where id=v_row.id;
    end if;
  end if;
  return public.nyilora_reserve_sms(v_row.id);
end $$;

-- Existing messages: update only the latest unsent repayment for a loan when
-- the final loan row was updated within two minutes of that repayment.
-- Older repayments or later loan edits are left unchanged for review.
with safe as (
  select o.id,o.client_name,r.amount,r.receipt_no,l.loan_no,
    l.outstanding_balance,s.company_name
  from public.nyilora_sms_outbox o
  join public.loan_repayments r on r.id=o.repayment_id
    and r.business_id=o.business_id and r.loan_id=o.loan_id
  join public.loans l on l.id=o.loan_id and l.business_id=o.business_id
  left join public.loan_settings s on s.business_id=o.business_id
  where o.message_type='repayment'
    and o.status in ('queued','failed','blocked_no_credit')
    and o.message not like '%Balance: KES %'
    and l.updated_at>=r.created_at
    and l.updated_at<=r.created_at+interval '2 minutes'
    and not exists(select 1 from public.loan_repayments later
      where later.loan_id=r.loan_id and later.business_id=r.business_id
        and (later.created_at,later.id)>(r.created_at,r.id))
), updated as (
  update public.nyilora_sms_outbox o
  set message=public.nyilora_repayment_sms_text(safe.client_name,
    safe.amount,safe.loan_no,safe.receipt_no,
    safe.outstanding_balance,safe.company_name)
  from safe where o.id=safe.id returning o.id
)
select count(*) as older_messages_safely_updated from updated;

revoke all on function public.nyilora_repayment_sms_text(text,numeric,text,text,numeric,text)
  from public,anon,authenticated;
revoke all on function public.nyilora_queue_repayment_sms(),
  public.nyilora_claim_repayment_sms(uuid) from public,anon,authenticated;
grant execute on function public.nyilora_claim_repayment_sms(uuid) to service_role;
notify pgrst,'reload schema';
commit;
