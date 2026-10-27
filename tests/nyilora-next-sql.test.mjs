import fs from 'node:fs';
import assert from 'node:assert/strict';
import { PGlite } from '@electric-sql/pglite';

const db = new PGlite();
try {
  await db.exec(`
    create role anon; create role authenticated;
    create schema auth;
    create table auth.users(id uuid primary key,email text,email_confirmed_at timestamptz);
    create function auth.uid() returns uuid language sql stable as $$
      select nullif(current_setting('test.auth_uid',true),'')::uuid
    $$;
  `);
  for (const path of ['NYILORA-FOUNDATION-ONE-RUN.sql', 'supabase/migrations/0005_nyilora_identity_expenses.sql']) {
    const sql = fs.readFileSync(path, 'utf8').replace('create extension if not exists pgcrypto;', '');
    await db.exec(sql);
  }
  const admin = 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa';
  const officer = 'bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb';
  await db.exec(`
    insert into auth.users values ('${admin}','admin@nyilora.example',now()),
      ('${officer}','officer@nyilora.example',now());
    insert into public.loan_staff(auth_user_id,name,email,role) values
      ('${admin}','Admin','admin@nyilora.example','admin'),
      ('${officer}','Officer','officer@nyilora.example','loan_officer');
  `);
  await db.exec(`select set_config('test.auth_uid','${officer}',false);`);
  let failed = false;
  try { await db.query(`select public.nyilora_submit_expense('{"description":"Fuel","category":"fuel","amount":200}'::jsonb)`); }
  catch { failed = true; }
  assert.equal(failed, true, 'officer without permission cannot initiate');
  await db.exec(`update public.nyilora_staff_permissions set initiate_expenses=true where staff_id=(select id from public.loan_staff where auth_user_id='${officer}')`);
  if ((await db.query('select count(*) as n from public.nyilora_staff_permissions')).rows[0].n === 0) {
    await db.exec(`insert into public.nyilora_staff_permissions(staff_id,initiate_expenses)
      select id,true from public.loan_staff where auth_user_id='${officer}'`);
  }
  const created = await db.query(`select (public.nyilora_submit_expense('{"description":"Fuel","category":"fuel","amount":200}'::jsonb)).id as id`);
  const expenseId = created.rows[0].id;
  await db.exec(`select set_config('test.auth_uid','${admin}',false);`);
  await db.query(`select public.nyilora_decide_expense('${expenseId}','approve',null)`);
  const entries = await db.query(`select count(*)::int as n,sum(debit)::numeric as debit,sum(credit)::numeric as credit
    from public.nyilora_accounting_entries where expense_id='${expenseId}'`);
  assert.equal(entries.rows[0].n, 2);
  assert.equal(Number(entries.rows[0].debit), 200);
  assert.equal(Number(entries.rows[0].credit), 200);
  failed = false;
  try { await db.query(`select public.nyilora_decide_expense('${expenseId}','approve',null)`); }
  catch { failed = true; }
  assert.equal(failed, true, 'second approval rejected');
  console.log('PASS: migration, expense permission, approval, balanced entries, duplicate prevention');
} finally { await db.close(); }
