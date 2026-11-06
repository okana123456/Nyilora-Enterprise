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
