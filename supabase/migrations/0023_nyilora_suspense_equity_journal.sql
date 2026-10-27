-- Nyilora only. Treat verified-paybill callback money as suspense until
-- matched to a repayment or explicitly transferred to owner equity.
begin;

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
commit;
