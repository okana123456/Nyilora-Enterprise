-- Nyilora only. Run after 0006. Reads and dismisses unresolved payment records.
-- Dismissal preserves original callback rows and never creates a repayment.
begin;

alter table public.unmatched_payments add column if not exists dismissed boolean not null default false;
alter table public.unmatched_payments add column if not exists dismissed_at timestamptz;
alter table public.unmatched_payments add column if not exists dismissed_by uuid references public.loan_staff(id);
alter table public.mpesa_callback_queue add column if not exists dismissed_at timestamptz;
alter table public.mpesa_callback_queue add column if not exists dismissed_by uuid references public.loan_staff(id);

create or replace function public.nyilora_suspense_page(
  p_source text,p_branch uuid default null,p_after uuid default null,p_limit integer default 500
) returns jsonb language plpgsql stable security definer set search_path=public as $$
declare v_actor public.loan_staff; v_rows jsonb; v_size integer:=least(greatest(coalesce(p_limit,500),1),500);
  v_branch constant uuid:='00000000-0000-4000-8000-000000000001';
begin
  v_actor:=public.nyilora_current_staff();
  if v_actor.id is null or not (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
    or public.nyilora_has_role('cashier') or public.nyilora_has_role('loan_officer'))
    then raise exception 'Suspense access is not permitted' using errcode='42501'; end if;
  if p_branch is not null and p_branch<>v_branch then raise exception 'Invalid Nyilora branch'; end if;
  if p_source='queue' then
    select coalesce(jsonb_agg(to_jsonb(x) order by x.id),'[]'::jsonb) into v_rows from (
      select q.* from public.mpesa_callback_queue q
      where q.business_id='BIZ-NYILORA' and q.branch_id=v_branch
        and not q.confirmed and not q.dismissed and q.repayment_id is null
        and (p_after is null or q.id>p_after)
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
          (upper(r.payment_reference)=upper(u.mpesa_reference) or upper(r.receipt_no)=upper(u.mpesa_reference)))
        and not exists(select 1 from public.mpesa_callback_queue q
          where q.business_id='BIZ-NYILORA' and upper(q.trans_id)=upper(u.mpesa_reference)
            and (q.confirmed or q.dismissed))
      order by u.id limit v_size
    ) x;
  else raise exception 'Unsupported Suspense source'; end if;
  return jsonb_build_object('rows',v_rows,
    'next_after',case when jsonb_array_length(v_rows)=v_size then v_rows->(v_size-1)->>'id' else null end);
end $$;

create or replace function public.nyilora_dismiss_suspense(
  p_queue_ids uuid[] default '{}',p_manual_ids uuid[] default '{}',p_reason text default 'Dismissed by authorized staff'
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_actor public.loan_staff; v_queue uuid[]; v_manual uuid[]; v_count integer:=0;
  v_row record; v_before jsonb; v_branch constant uuid:='00000000-0000-4000-8000-000000000001';
begin
  v_actor:=public.nyilora_current_staff();
  if v_actor.id is null or not (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
    or public.nyilora_has_role('cashier')) then raise exception 'Suspense dismissal is not permitted' using errcode='42501'; end if;
  select coalesce(array_agg(distinct x),'{}') into v_queue from unnest(coalesce(p_queue_ids,'{}')) x where x is not null;
  select coalesce(array_agg(distinct x),'{}') into v_manual from unnest(coalesce(p_manual_ids,'{}')) x where x is not null;
  if cardinality(v_queue)+cardinality(v_manual) not between 1 and 500
    then raise exception 'Select between 1 and 500 records'; end if;
  if (select count(*) from public.mpesa_callback_queue q where q.id=any(v_queue)
      and q.business_id='BIZ-NYILORA' and q.branch_id=v_branch)<>cardinality(v_queue)
    then raise exception 'Callback missing or outside Nyilora'; end if;
  if (select count(*) from public.unmatched_payments u where u.id=any(v_manual)
      and u.business_id='BIZ-NYILORA' and u.branch_id=v_branch)<>cardinality(v_manual)
    then raise exception 'Manual payment missing or outside Nyilora'; end if;
  for v_row in select q.* from public.mpesa_callback_queue q where q.id=any(v_queue) order by q.id for update loop
    if v_row.dismissed then continue; end if;
    if v_row.confirmed or v_row.repayment_id is not null or exists(
      select 1 from public.loan_repayments r where r.business_id='BIZ-NYILORA' and
      (upper(r.payment_reference)=upper(v_row.trans_id) or upper(r.receipt_no)=upper(v_row.trans_id)))
      then raise exception 'Recorded payment % cannot be dismissed',v_row.trans_id; end if;
    v_before:=to_jsonb(v_row);
    update public.mpesa_callback_queue set dismissed=true,dismissed_at=now(),dismissed_by=v_actor.id,
      review_reason=left(coalesce(nullif(trim(p_reason),''),'Dismissed by authorized staff'),1000),updated_at=now()
      where id=v_row.id;
    insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,entity_id,old_value,new_value)
    values(v_actor.id,'suspense_dismissed','mpesa_callback_queue',v_row.id::text,v_before,
      (select to_jsonb(q) from public.mpesa_callback_queue q where q.id=v_row.id));
    v_count:=v_count+1;
  end loop;
  for v_row in select u.* from public.unmatched_payments u where u.id=any(v_manual) order by u.id for update loop
    if v_row.dismissed then continue; end if;
    if v_row.resolved or v_row.repayment_id is not null or exists(
      select 1 from public.loan_repayments r where r.business_id='BIZ-NYILORA' and
      (upper(r.payment_reference)=upper(v_row.mpesa_reference) or upper(r.receipt_no)=upper(v_row.mpesa_reference)))
      then raise exception 'Recorded payment % cannot be dismissed',v_row.mpesa_reference; end if;
    v_before:=to_jsonb(v_row);
    update public.unmatched_payments set dismissed=true,dismissed_at=now(),dismissed_by=v_actor.id
      where id=v_row.id;
    insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,entity_id,old_value,new_value)
    values(v_actor.id,'suspense_dismissed','unmatched_payments',v_row.id::text,v_before,
      (select to_jsonb(u) from public.unmatched_payments u where u.id=v_row.id));
    v_count:=v_count+1;
  end loop;
  return jsonb_build_object('ok',true,'dismissed_rows',v_count);
end $$;

revoke all on function public.nyilora_suspense_page(text,uuid,uuid,integer),
  public.nyilora_dismiss_suspense(uuid[],uuid[],text) from public,anon;
grant execute on function public.nyilora_suspense_page(text,uuid,uuid,integer),
  public.nyilora_dismiss_suspense(uuid[],uuid[],text) to authenticated;
notify pgrst,'reload schema';
commit;
