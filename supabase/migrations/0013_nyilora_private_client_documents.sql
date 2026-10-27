-- Nyilora only. Private onboarding files for clients and guarantors.
-- Run after 0012. No lending or financial records are changed.
begin;

alter table public.nyilora_client_documents
  add column if not exists file_name text,
  add column if not exists mime_type text,
  add column if not exists file_size bigint,
  add column if not exists uploaded_at timestamptz not null default now();
alter table public.nyilora_client_documents
  add constraint nyilora_document_kind_check
    check(kind in ('client_passport','client_id_front','client_id_back',
      'guarantor_passport','guarantor_id_front','guarantor_id_back')),
  add constraint nyilora_document_type_check
    check(mime_type in ('image/jpeg','image/png','image/webp','application/pdf')),
  add constraint nyilora_document_size_check
    check(file_size>0 and file_size<=8388608);
create unique index if not exists nyilora_document_path_unique
  on public.nyilora_client_documents(object_path);

create or replace function public.nyilora_can_access_client_documents(p_client uuid)
returns boolean language sql stable security definer set search_path=public as $$
  select exists(select 1 from public.loan_clients c
    where c.id=p_client and c.business_id='BIZ-NYILORA'
      and public.nyilora_staff_id() is not null
      and (public.nyilora_has_role('admin') or public.nyilora_has_role('branch_manager')
        or (public.nyilora_has_role('loan_officer') and c.loan_officer_id=public.nyilora_staff_id())))
$$;

create or replace function public.nyilora_can_access_document_path(p_path text)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare parts text[]:=string_to_array(p_path,'/');
begin
  if cardinality(parts)<>4 or parts[1]<>'BIZ-NYILORA'
    or parts[2]!~*'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
    or parts[3] not in ('client_passport','client_id_front','client_id_back',
      'guarantor_passport','guarantor_id_front','guarantor_id_back')
    or parts[4]!~*'^[0-9a-f-]+\.(jpg|png|webp|pdf)$' then return false; end if;
  return public.nyilora_can_access_client_documents(parts[2]::uuid);
end $$;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('nyilora-client-documents','nyilora-client-documents',false,8388608,
  array['image/jpeg','image/png','image/webp','application/pdf'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

create policy nyilora_document_storage_read on storage.objects for select to authenticated
  using(bucket_id='nyilora-client-documents' and public.nyilora_can_access_document_path(name));
create policy nyilora_document_storage_insert on storage.objects for insert to authenticated
  with check(bucket_id='nyilora-client-documents' and public.nyilora_can_access_document_path(name));
create policy nyilora_document_storage_delete on storage.objects for delete to authenticated
  using(bucket_id='nyilora-client-documents' and public.nyilora_can_access_document_path(name));
create policy nyilora_document_storage_boundary on storage.objects as restrictive for all to public
  using(bucket_id<>'nyilora-client-documents' or public.nyilora_can_access_document_path(name))
  with check(bucket_id<>'nyilora-client-documents' or public.nyilora_can_access_document_path(name));

drop policy if exists nyilora_document_read on public.nyilora_client_documents;
create policy nyilora_document_read on public.nyilora_client_documents for select to authenticated
  using(business_id='BIZ-NYILORA' and public.nyilora_can_access_client_documents(client_id));
create policy nyilora_document_insert on public.nyilora_client_documents for insert to authenticated
  with check(business_id='BIZ-NYILORA' and public.nyilora_can_access_client_documents(client_id));
create policy nyilora_document_update on public.nyilora_client_documents for update to authenticated
  using(business_id='BIZ-NYILORA' and public.nyilora_can_access_client_documents(client_id))
  with check(business_id='BIZ-NYILORA' and public.nyilora_can_access_client_documents(client_id));

create or replace function public.nyilora_validate_client_document()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  if not public.nyilora_can_access_client_documents(new.client_id)
    or split_part(new.object_path,'/',1)<>'BIZ-NYILORA'
    or split_part(new.object_path,'/',2)<>new.client_id::text
    or split_part(new.object_path,'/',3)<>new.kind
    or not public.nyilora_can_access_document_path(new.object_path)
    or not exists(select 1 from storage.objects o
      where o.bucket_id='nyilora-client-documents' and o.name=new.object_path)
    then raise exception 'Upload to the authorized client folder first' using errcode='42501'; end if;
  if new.kind in ('client_passport','guarantor_passport') and new.mime_type='application/pdf'
    then raise exception 'Passport photo must be an image'; end if;
  new.uploaded_by:=public.nyilora_staff_id();
  new.uploaded_at:=now();
  return new;
end $$;
create trigger nyilora_validate_document before insert or update on public.nyilora_client_documents
  for each row execute function public.nyilora_validate_client_document();

create or replace function public.nyilora_audit_client_document()
returns trigger language plpgsql security definer set search_path=public as $$
begin
  insert into public.nyilora_domain_audit(actor_staff_id,action,entity_type,entity_id,old_value,new_value)
  values(new.uploaded_by,case when tg_op='INSERT' then 'document_uploaded' else 'document_replaced' end,
    'client_document',new.client_id::text||'/'||new.kind,
    case when tg_op='UPDATE' then to_jsonb(old) else null end,to_jsonb(new));
  return new;
end $$;
create trigger nyilora_audit_document after insert or update on public.nyilora_client_documents
  for each row execute function public.nyilora_audit_client_document();

revoke all on function public.nyilora_can_access_client_documents(uuid),
  public.nyilora_can_access_document_path(text),
  public.nyilora_validate_client_document(),public.nyilora_audit_client_document() from public,anon;
grant execute on function public.nyilora_can_access_client_documents(uuid),
  public.nyilora_can_access_document_path(text) to authenticated;
-- The restrictive storage policy is evaluated for anonymous requests too.
grant execute on function public.nyilora_can_access_document_path(text) to anon;
notify pgrst,'reload schema';
commit;
