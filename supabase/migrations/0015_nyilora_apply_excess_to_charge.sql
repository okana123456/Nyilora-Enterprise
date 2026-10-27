-- Nyilora only. Move available client excess to that same client's open charge.
-- This is an internal allocation: it creates no cash receipt or new repayment.
begin;

create or replace function public.nyilora_can_adjust_charges()
returns boolean language sql stable security definer set search_path=public as $$
  select public.nyilora_has_role('admin') or coalesce((
    select p.adjust_charges_excess from public.nyilora_staff_permissions p
    where p.staff_id=public.nyilora_staff_id() and p.business_id='BIZ-NYILORA'
  ),false)
$$;

create or replace function public.nyilora_apply_excess_to_charge(
  p_excess_id uuid,p_charge_id uuid,p_amount numeric,p_note text default null
) returns jsonb language plpgsql security definer set search_path=public as $$
declare v_excess public.nyilora_excess_ledger; v_charge public.nyilora_charges;
  v_amount numeric(16,2); v_remaining numeric(16,2); v_paid numeric(16,2);
begin
  if public.nyilora_staff_id() is null or not public.nyilora_can_adjust_charges()
    then raise exception 'Charges & Excess permission required' using errcode='42501'; end if;
  if p_amount is null or p_amount<=0 or round(p_amount,2)<>p_amount
    then raise exception 'Enter a positive amount with at most two decimal places'; end if;
  if nullif(trim(p_note),'') is null then raise exception 'Enter an allocation reference or reason'; end if;
  select * into v_excess from public.nyilora_excess_ledger
    where id=p_excess_id and business_id='BIZ-NYILORA' for update;
  select * into v_charge from public.nyilora_charges
    where id=p_charge_id and business_id='BIZ-NYILORA' for update;
  if v_excess.id is null or v_charge.id is null then raise exception 'Excess or charge not found'; end if;
  if v_excess.client_id<>v_charge.client_id or v_excess.branch_id<>v_charge.branch_id
    then raise exception 'Excess and charge must belong to the same client and branch'; end if;
  if v_charge.status not in ('pending','partially_paid') or v_excess.amount_available<=0
    then raise exception 'Excess or charge is no longer open'; end if;
  if p_amount>v_excess.amount_available or p_amount>v_charge.amount-v_charge.amount_paid
    then raise exception 'Amount exceeds available credit or charge balance'; end if;
  v_amount:=round(p_amount,2);
  v_remaining:=round(v_excess.amount_available-v_amount,2);
  v_paid:=round(v_charge.amount_paid+v_amount,2);
  update public.nyilora_excess_ledger set amount_available=v_remaining,
    status=case when v_remaining=0 then 'applied' else 'partially_used' end,
    resolved_at=case when v_remaining=0 then now() else null end,
    resolved_by=case when v_remaining=0 then public.nyilora_staff_id() else null end,
    resolution_note=left(trim(p_note),1000),updated_at=now()
  where id=p_excess_id;
  update public.nyilora_charges set amount_paid=v_paid,
    status=case when v_paid=amount then 'paid' else 'partially_paid' end,
    settled_at=case when v_paid=amount then now() else null end,
    settled_by=case when v_paid=amount then public.nyilora_staff_id() else null end,
    settlement_note=left(trim(p_note),1000),updated_at=now()
  where id=p_charge_id;
  insert into public.nyilora_excess_allocations
    (excess_id,charge_id,action,amount,note,created_by)
  values(p_excess_id,p_charge_id,'charge_payment',v_amount,left(trim(p_note),1000),public.nyilora_staff_id());
  insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,entity_id,new_value)
  values(public.nyilora_staff_id(),'excess_applied_to_charge','nyilora_excess_ledger',p_excess_id::text,
    jsonb_build_object('charge_id',p_charge_id,'amount',v_amount,'reason',left(trim(p_note),1000)));
  return jsonb_build_object('ok',true,'amount_applied',v_amount,
    'excess_remaining',v_remaining,'charge_paid',v_paid);
end $$;

revoke all on function public.nyilora_can_adjust_charges(),
  public.nyilora_apply_excess_to_charge(uuid,uuid,numeric,text) from public,anon;
grant execute on function public.nyilora_can_adjust_charges(),
  public.nyilora_apply_excess_to_charge(uuid,uuid,numeric,text) to authenticated;
notify pgrst,'reload schema';
commit;
