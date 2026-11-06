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
