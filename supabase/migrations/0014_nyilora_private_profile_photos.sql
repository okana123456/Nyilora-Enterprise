-- Nyilora only. Private cropped profile photos, separate from ID/guarantor files.
-- The frontend loads short-lived signed URLs after authentication.
begin;

create or replace function public.nyilora_can_access_profile_photo_path(p_path text)
returns boolean language plpgsql stable security definer set search_path=public as $$
declare v_name text; v_client uuid;
begin
  if p_path!~*'^BIZ-NYILORA/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}-[0-9]{13}\.jpg$'
    then return false; end if;
  v_name:=split_part(p_path,'/',2);
  v_client:=left(v_name,36)::uuid;
  return public.nyilora_can_access_client_documents(v_client);
end $$;

insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
values('client-photos','client-photos',false,280000,array['image/jpeg'])
on conflict(id) do update set public=false,file_size_limit=excluded.file_size_limit,
  allowed_mime_types=excluded.allowed_mime_types;

create policy nyilora_profile_photo_read on storage.objects for select to authenticated
  using(bucket_id='client-photos' and public.nyilora_can_access_profile_photo_path(name));
create policy nyilora_profile_photo_insert on storage.objects for insert to authenticated
  with check(bucket_id='client-photos' and public.nyilora_can_access_profile_photo_path(name));
create policy nyilora_profile_photo_delete on storage.objects for delete to authenticated
  using(bucket_id='client-photos' and public.nyilora_can_access_profile_photo_path(name));
create policy nyilora_profile_photo_boundary on storage.objects as restrictive for all to public
  using(bucket_id<>'client-photos' or public.nyilora_can_access_profile_photo_path(name))
  with check(bucket_id<>'client-photos' or public.nyilora_can_access_profile_photo_path(name));

revoke all on function public.nyilora_can_access_profile_photo_path(text) from public,anon;
grant execute on function public.nyilora_can_access_profile_photo_path(text) to authenticated,anon;
commit;
