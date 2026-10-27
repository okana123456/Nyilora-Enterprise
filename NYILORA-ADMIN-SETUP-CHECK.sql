-- Read-only check after 0026_nyilora_first_admin_gate.sql.
select
  to_regprocedure('public.nyilora_claim_first_admin(uuid,text,text)') is not null
    as first_admin_gate_installed,
  has_function_privilege('anon',
    'public.nyilora_claim_first_admin(uuid,text,text)','EXECUTE')
    as anonymous_can_claim_admin,
  has_function_privilege('authenticated',
    'public.nyilora_claim_first_admin(uuid,text,text)','EXECUTE')
    as signed_in_user_can_claim_admin,
  has_function_privilege('service_role',
    'public.nyilora_claim_first_admin(uuid,text,text)','EXECUTE')
    as server_can_claim_admin,
  (select count(*) from public.loan_staff where business_id='BIZ-NYILORA')
    as existing_nyilora_staff;
