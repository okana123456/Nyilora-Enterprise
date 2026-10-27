import fs from 'node:fs';
import assert from 'node:assert/strict';

const { PGlite } = await import(process.env.NYILORA_PGLITE_IMPORT || '@electric-sql/pglite');
const db = new PGlite();
try {
  await db.exec(`
    create role anon; create role authenticated; create role service_role;
    create schema auth;
    create schema storage;
    create table storage.buckets(id text primary key,name text,public boolean,
      file_size_limit bigint,allowed_mime_types text[]);
    create table storage.objects(id uuid primary key default gen_random_uuid(),
      bucket_id text,name text,owner_id text);
    create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('test.auth_uid',true),'')::uuid
    $$;
  `);
  const migrations = Array.from({length: 27},(_,index) => index + 5).map(number => {
    const prefix = String(number).padStart(4,'0');
    return fs.readdirSync('supabase/migrations').find(file => file.startsWith(prefix + '_'));
  });
  for (const file of ['NYILORA-FOUNDATION-ONE-RUN.sql',
    ...migrations.map(file => `supabase/migrations/${file}`)]) {
    await db.exec(fs.readFileSync(file, 'utf8').replace('create extension if not exists pgcrypto;', ''));
  }
  // An interrupted deployment may lead an operator to run the update again.
  for (const file of migrations.slice(-5)) {
    await db.exec(fs.readFileSync(`supabase/migrations/${file}`, 'utf8'));
  }
  const firstOwner = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  const owner = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  await db.exec(`insert into auth.users values
    ('${firstOwner}','first@example.test',now()),
    ('${owner}','owner@example.test',now())`);
  const first = await db.query(`select public.nyilora_register_business_admin(
    '${firstOwner}','Nyilora Enterprise','First Owner','first@example.test') as created`);
  const originalState = await db.query(`select
    (select count(*) from public.nyilora_branches where business_id='BIZ-NYILORA' and is_head_office) as branches,
    (select count(*) from public.loan_staff where business_id='BIZ-NYILORA') as staff,
    (select count(*) from public.loan_clients where business_id='BIZ-NYILORA') as clients`);
  assert.equal(first.rows[0].created.business_id,'BIZ-NYILORA',JSON.stringify(originalState.rows));
  const result = await db.query(`select public.nyilora_register_business_admin(
    '${owner}','Second Company','Owner','owner@example.test') as created`);
  const newBusiness = result.rows[0].created.business_id;
  assert.notEqual(newBusiness, 'BIZ-NYILORA');
  const rows = await db.query(`select business_id,count(*)::int as n from public.nyilora_branches group by business_id`);
  assert.equal(rows.rows.length, 2);
  await db.exec(`select set_config('test.auth_uid','${owner}',false)`);
  const visible = await db.query(`select business_id from public.nyilora_current_staff()`);
  assert.equal(visible.rows[0].business_id, newBusiness);
  await db.exec('set role authenticated');
  const branchView = await db.query('select business_id from public.nyilora_branches');
  assert.deepEqual(branchView.rows.map(row => row.business_id),[newBusiness]);
  const settingView = await db.query('select business_id from public.loan_settings');
  assert.deepEqual(settingView.rows.map(row => row.business_id),[newBusiness]);
  let blocked = false;
  try {
    await db.query(`insert into public.loan_clients(business_id,branch_id,full_name)
      values('BIZ-NYILORA','00000000-0000-4000-8000-000000000001','Wrong tenant')`);
  } catch { blocked = true; }
  assert.equal(blocked,true,'cannot create a client in another business');
  const expense = await db.query(`select (public.nyilora_submit_expense(
    '{"description":"Office rent","category":"rent","amount":500}'::jsonb)).id as id`);
  await db.query(`select public.nyilora_decide_expense('${expense.rows[0].id}','approve',null)`);
  const journal = await db.query(`select business_id,count(*)::int as entries from public.nyilora_accounting_entries
    where expense_id='${expense.rows[0].id}' group by business_id`);
  assert.equal(journal.rows[0].business_id,newBusiness);
  assert.equal(journal.rows[0].entries,2);
  await db.exec('reset role');
  await db.exec(`select set_config('test.auth_uid','',false)`);
  const branchId = result.rows[0].created.branch_id;
  const staffId = result.rows[0].created.staff_id;
  const client = await db.query(`insert into public.loan_clients(
    business_id,branch_id,loan_officer_id,full_name,phone)
    values('${newBusiness}','${branchId}','${staffId}',
      'Second Company Client','0712345678') returning id`);
  const loan = await db.query(`insert into public.loans(
    business_id,branch_id,client_id,loan_officer_id,loan_no,principal_amount,
    disbursed_amount,total_interest,total_payable,outstanding_balance,
    disbursement_date,status)
    values('${newBusiness}','${branchId}','${client.rows[0].id}','${staffId}',
      'SECOND-001',1000,1000,200,1200,1200,current_date,'active') returning id`);
  const repayment = await db.query(`insert into public.loan_repayments(
    business_id,branch_id,loan_id,receipt_no,amount,payment_method,
    payment_reference,loan_portion,principal_portion,interest_portion)
    values('${newBusiness}','${branchId}','${loan.rows[0].id}',
      'SECOND-PAY-001',100,'M-Pesa','SECOND-PAY-001',100,80,20) returning id`);
  const outbox = await db.query(`select business_id,count(*)::int as n from public.nyilora_sms_outbox
    where repayment_id='${repayment.rows[0].id}' group by business_id`);
  assert.equal(outbox.rows[0].business_id,newBusiness);
  assert.equal(outbox.rows[0].n,1);
  await db.exec(`update public.loan_settings set mpesa_shortcode='4049999'
    where business_id='${newBusiness}'`);
  const callback = await db.query(`insert into public.mpesa_callback_queue(
    business_id,branch_id,trans_id,trans_amount,business_short_code,bill_ref_number)
    values('${newBusiness}','${branchId}','SECOND-C2B-001',50,'4049999','unknown') returning id`);
  const suspense = await db.query(`select business_id,count(*)::int as entries
    from public.nyilora_accounting_entries where source_table='mpesa_callback_queue'
      and source_id='${callback.rows[0].id}' group by business_id`);
  assert.equal(suspense.rows[0].business_id,newBusiness);
  assert.equal(suspense.rows[0].entries,2);
  await db.query(`insert into public.loan_billing_cycles(business_id,billing_month,amount,
    status,actual_amount,paid_at,paid_until)
    values('${newBusiness}','2026-12-01',3000,'paid',3000,now(),'2027-01-04')`);
  await db.query(`insert into public.nyilora_sms_bundle_requests(
    business_id,branch_id,credits,amount,customer_amount,phone)
    values('${newBusiness}','${branchId}',100,55,55,'254712345678')`);
  await db.query(`select public.nyilora_owner_add_sms_credits(
    '${newBusiness}',10,5.50,'TEST-SMS-TOPUP',null)`);
  const claim = await db.query(`select public.nyilora_claim_custom_sms(
    '${newBusiness}','254712345678','Test notice','Test client') as result`);
  assert.equal(claim.rows[0].result.business_id,newBusiness);
  const smsBalances = await db.query(`select business_id,credits_remaining from public.nyilora_sms_wallets order by business_id`);
  assert.equal(smsBalances.rows.find(row => row.business_id===newBusiness).credits_remaining,9);
  assert.equal(smsBalances.rows.find(row => row.business_id==='BIZ-NYILORA').credits_remaining,0);
  const verification = await db.exec(fs.readFileSync('NYILORA-MULTI-BUSINESS-VERIFY.sql','utf8'));
  assert(verification.at(-1).rows.every(row => Number(row.failures)===0),
    'verification query must report no tenant mismatches');
  console.log('PASS: multi-business migration and new administrator isolation');
} finally {
  await db.close();
}
