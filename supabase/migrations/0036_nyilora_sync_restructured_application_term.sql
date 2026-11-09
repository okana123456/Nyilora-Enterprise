-- Keep a disbursed application's displayed term aligned with its loan after
-- an authorized restructure. The previous value remains in the audit trail.
begin;

create or replace function public.nyilora_sync_restructured_application_term()
returns trigger language plpgsql security definer set search_path=public as $$
declare v_app public.loan_applications;
begin
  if new.application_id is null or new.term_weeks is not distinct from old.term_weeks then
    return new;
  end if;
  select * into v_app from public.loan_applications
    where id=new.application_id and business_id=new.business_id
      and branch_id=new.branch_id and client_id=new.client_id
      and status='disbursed' for update;
  if v_app.id is null then
    raise exception 'The linked disbursed application could not be verified';
  end if;
  if v_app.applied_term_weeks is distinct from new.term_weeks then
    update public.loan_applications set applied_term_weeks=new.term_weeks,updated_at=now()
      where id=v_app.id;
    insert into public.nyilora_domain_audit
      (business_id,branch_id,actor_staff_id,action,entity_type,entity_id,old_value,new_value)
    values(new.business_id,new.branch_id,(public.nyilora_current_staff()).id,
      'application_term_synced_to_restructured_loan','loan_applications',v_app.id::text,
      jsonb_build_object('applied_term_weeks',v_app.applied_term_weeks,'loan_id',new.id),
      jsonb_build_object('applied_term_weeks',new.term_weeks,'loan_id',new.id));
  end if;
  return new;
end $$;

drop trigger if exists nyilora_sync_restructured_application_term on public.loans;
create trigger nyilora_sync_restructured_application_term
after update of term_weeks on public.loans for each row
execute function public.nyilora_sync_restructured_application_term();

-- Repair only applications tied to loans with a recorded term restructure.
-- A matching schedule count guards against a partial or unrelated edit.
do $$
declare r record;
begin
  for r in
    select l.id as loan_id,l.business_id,l.branch_id,l.term_weeks,
      a.id as application_id,a.applied_term_weeks
    from public.loans l
    join public.loan_applications a on a.id=l.application_id
      and a.business_id=l.business_id and a.branch_id=l.branch_id
      and a.client_id=l.client_id and a.status='disbursed'
    where a.applied_term_weeks<>l.term_weeks
      and exists(select 1 from public.nyilora_domain_audit d
        where d.business_id=l.business_id and d.action='loan_term_restructured'
          and d.entity_type='loans' and d.entity_id=l.id::text
          and (d.new_value->>'term_weeks')::integer=l.term_weeks)
      and (select count(*) from public.loan_schedules s where s.loan_id=l.id)=l.term_weeks
    for update of l,a
  loop
    update public.loan_applications set applied_term_weeks=r.term_weeks,updated_at=now()
      where id=r.application_id and applied_term_weeks=r.applied_term_weeks;
    insert into public.nyilora_domain_audit
      (business_id,branch_id,action,entity_type,entity_id,old_value,new_value)
    values(r.business_id,r.branch_id,'application_term_backfilled_from_restructured_loan',
      'loan_applications',r.application_id::text,
      jsonb_build_object('applied_term_weeks',r.applied_term_weeks,'loan_id',r.loan_id),
      jsonb_build_object('applied_term_weeks',r.term_weeks,'loan_id',r.loan_id));
  end loop;
end $$;

commit;

select l.business_id,l.loan_no,a.application_no,
  a.applied_term_weeks as application_weeks,l.term_weeks as loan_weeks,
  (select count(*) from public.loan_schedules s where s.loan_id=l.id) as installments
from public.loans l join public.loan_applications a on a.id=l.application_id
where exists(select 1 from public.nyilora_domain_audit d
  where d.business_id=l.business_id and d.action='loan_term_restructured'
    and d.entity_type='loans' and d.entity_id=l.id::text)
order by l.business_id,l.loan_no;
