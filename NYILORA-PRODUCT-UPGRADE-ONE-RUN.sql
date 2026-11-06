-- Nyilora product upgrade. Run in the NYILORA Supabase SQL Editor only.
-- Includes migrations 0032, 0033 and 0034 in order.

-- Link applications and loans to products within the same Nyilora company.
-- Existing financial values and existing product rows are unchanged.
begin;

alter table public.loan_applications add column if not exists product_id uuid;
alter table public.loans add column if not exists product_id uuid;

do $$ begin
  if not exists (select 1 from pg_constraint
                 where conrelid='public.loan_applications'::regclass
                   and conname='nyilora_application_product_fk') then
    alter table public.loan_applications
      add constraint nyilora_application_product_fk
      foreign key(product_id) references public.loan_products(id);
  end if;
  if not exists (select 1 from pg_constraint
                 where conrelid='public.loans'::regclass
                   and conname='nyilora_loan_product_fk') then
    alter table public.loans
      add constraint nyilora_loan_product_fk
      foreign key(product_id) references public.loan_products(id);
  end if;
end $$;

create index if not exists nyilora_applications_product_idx
  on public.loan_applications(business_id,product_id);
create index if not exists nyilora_loans_product_idx
  on public.loans(business_id,product_id);

create or replace function public.nyilora_check_product_company()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if new.product_id is not null and not exists (
    select 1 from public.loan_products p
    where p.id=new.product_id and p.business_id=new.business_id
  ) then
    raise exception 'Loan product must belong to the same company';
  end if;
  return new;
end $$;

drop trigger if exists nyilora_application_product_company on public.loan_applications;
create trigger nyilora_application_product_company
before insert or update of product_id,business_id on public.loan_applications
for each row execute function public.nyilora_check_product_company();

drop trigger if exists nyilora_loan_product_company on public.loans;
create trigger nyilora_loan_product_company
before insert or update of product_id,business_id on public.loans
for each row execute function public.nyilora_check_product_company();

notify pgrst,'reload schema';
commit;


-- Copy the four verified Bripta product definitions into each Nyilora company.
-- Existing products, loans, payments and balances are unchanged.
begin;

create or replace function public.nyilora_seed_bripta_products(p_business_id text)
returns void language plpgsql security definer set search_path=public as $$
begin
if p_business_id is null or p_business_id='' then
  raise exception 'Company ID is required for product setup';
end if;
with source_products(name,min_amount,max_amount,interest_rate,interest_type,
    interest_period,min_term_weeks,max_term_weeks,processing_fee_pct,
    late_penalty_pct,grace_period_days,requires_guarantor) as (
  values
    ('Boresha',5000::numeric,20000::numeric,5::numeric,'flat','weekly',1,6,10::numeric,15::numeric,0,true),
    ('Kuza',5000,20000,5,'flat','weekly',1,5,10,15,0,true),
    ('Super  Wima',3000,4000,6.25,'flat','weekly',1,4,12.5,15,0,true),
    ('Wima',5000,20000,5,'flat','weekly',1,4,10,15,0,true)
)
insert into public.loan_products
  (business_id,name,description,min_amount,max_amount,interest_rate,
   interest_type,interest_period,min_term_weeks,max_term_weeks,
   processing_fee_pct,late_penalty_pct,grace_period_days,requires_guarantor,is_active)
select p_business_id,p.name,'',p.min_amount,p.max_amount,p.interest_rate,
       p.interest_type,p.interest_period,p.min_term_weeks,p.max_term_weeks,
       p.processing_fee_pct,p.late_penalty_pct,p.grace_period_days,
       p.requires_guarantor,true
from source_products p
where not exists (
  select 1 from public.loan_products existing
  where existing.business_id=p_business_id
    and lower(regexp_replace(trim(existing.name),'\s+',' ','g'))=
        lower(regexp_replace(trim(p.name),'\s+',' ','g'))
);
end $$;

revoke all on function public.nyilora_seed_bripta_products(text) from public,anon,authenticated;

create or replace function public.nyilora_seed_products_for_new_business()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  perform public.nyilora_seed_bripta_products(new.business_id);
  return new;
end $$;

drop trigger if exists nyilora_seed_products_after_branch on public.nyilora_branches;
create trigger nyilora_seed_products_after_branch
after insert on public.nyilora_branches
for each row execute function public.nyilora_seed_products_for_new_business();

do $$ declare v_business record; begin
  for v_business in select distinct business_id from public.nyilora_branches loop
    perform public.nyilora_seed_bripta_products(v_business.business_id);
  end loop;
end $$;

commit;

select business_id,name,min_amount,max_amount,interest_rate,interest_type,
       interest_period,min_term_weeks,max_term_weeks,processing_fee_pct,
       late_penalty_pct,grace_period_days,requires_guarantor,is_active
from public.loan_products
where lower(regexp_replace(trim(name),'\s+',' ','g')) in
  ('boresha','kuza','super wima','wima')
order by business_id,name;


-- Correct the one audited Nyilora loan from 0% to its unique Bripta-matched
-- Super Wima product. This is a contractual increase of KES 1,000.
-- Run only after 0032 and 0033, and after the borrower terms are confirmed.
begin;

do $$
declare
  v_loan public.loans;
  v_product public.loan_products;
  v_schedule_count integer;
  v_schedule_total numeric;
  v_schedule_paid numeric;
begin
  select * into v_product from public.loan_products
  where business_id='BIZ-A1C8E7FBD382'
    and lower(regexp_replace(trim(name),'\s+',' ','g'))='super wima';
  if v_product.id is null then raise exception 'Super Wima product is missing; run the product seed first'; end if;

  select * into v_loan from public.loans
  where id='c8073868-de4b-4ddf-953a-7830a9810f1e'::uuid
    and business_id='BIZ-A1C8E7FBD382'
    and loan_no='678423'
  for update;
  if v_loan.id is null then raise exception 'Audited loan 678423 was not found in its company'; end if;
  if v_loan.product_id=v_product.id and v_loan.interest_rate=6.25
    and v_loan.total_interest=1000 and v_loan.total_payable=5000
    and v_loan.outstanding_balance=5000 then return; end if;

  perform 1 from public.loan_schedules where loan_id=v_loan.id for update;
  select count(*),coalesce(sum(total_due),0),coalesce(sum(total_paid),0)
    into v_schedule_count,v_schedule_total,v_schedule_paid
  from public.loan_schedules where loan_id=v_loan.id;
  if v_loan.principal_amount<>4000 or v_loan.disbursed_amount<>4000
    or v_loan.interest_rate<>0 or v_loan.total_interest<>0
    or v_loan.total_payable<>4000 or v_loan.outstanding_balance<>4000
    or v_loan.total_paid<>0 or v_loan.term_weeks<>4
    or v_loan.processing_fee<>500 or v_loan.status<>'active'
    or v_loan.product_id is not null
    or v_schedule_count<>4 or v_schedule_total<>4000 or v_schedule_paid<>0
    or exists(select 1 from public.loan_repayments where loan_id=v_loan.id)
    or exists(select 1 from public.loan_penalties where loan_id=v_loan.id)
    or exists(select 1 from public.loan_schedules where loan_id=v_loan.id
       and (coalesce(interest_due,0)<>0 or coalesce(interest_paid,0)<>0
            or coalesce(principal_paid,0)<>0 or coalesce(penalty_charged,0)<>0))
  then raise exception 'Loan 678423 changed since review; no financial correction made'; end if;

  update public.loans set product_id=v_product.id,
    interest_rate=6.25,interest_type='flat',total_interest=1000,
    total_payable=5000,weekly_installment=1250,outstanding_balance=5000
  where id=v_loan.id and business_id=v_loan.business_id;

  update public.loan_schedules set principal_due=1000,interest_due=250,total_due=1250
  where loan_id=v_loan.id and business_id=v_loan.business_id;

  update public.loan_applications set product_id=v_product.id
  where id=v_loan.application_id and business_id=v_loan.business_id;

  insert into public.nyilora_domain_audit
    (business_id,branch_id,action,entity_type,entity_id,old_value,new_value)
  values(v_loan.business_id,v_loan.branch_id,'loan_product_interest_correction',
    'loans',v_loan.id::text,
    jsonb_build_object('loan_no',v_loan.loan_no,'interest_rate',0,
      'total_interest',0,'total_payable',4000,'outstanding_balance',4000),
    jsonb_build_object('loan_no',v_loan.loan_no,'product',v_product.name,
      'interest_rate',6.25,'total_interest',1000,'total_payable',5000,
      'outstanding_balance',5000,'reason','Audited Super Wima correction'));
end $$;

commit;

select l.business_id,l.loan_no,p.name as product,l.interest_rate,
       l.total_interest,l.total_payable,l.outstanding_balance,
       count(s.id) as installments,sum(s.total_due) as scheduled_total,
       sum(s.interest_due) as scheduled_interest
from public.loans l
join public.loan_products p on p.id=l.product_id
left join public.loan_schedules s on s.loan_id=l.id
where l.id='c8073868-de4b-4ddf-953a-7830a9810f1e'::uuid
group by l.business_id,l.loan_no,p.name,l.interest_rate,
         l.total_interest,l.total_payable,l.outstanding_balance;

