# Nyilora Enterprise

This repository is the separate Nyilora Enterprise loan system. It was cloned from the empty [Nyilora-Enterprise](https://github.com/okana123456/Nyilora-Enterprise) repository and prepared with the Bripta feature layout, a green theme, and Nyilora names. It contains no Bripta clients, payments, credentials, callback URL, or Git history.

## Agreed setup

- One branch, editable by administrators. The Branches tab remains available for viewing and editing that branch.
- Monthly subscription: KES 3,000 starting **1 December 2026**. The server payment functions reject earlier subscription requests.
- SMS credits: KES 0.55 each. Nyilora will supply its own SMS provider API and approved sender ID.
- Nyilora will supply its own M-Pesa Paybill and Daraja credentials. Callback URLs are built from Nyilora's Supabase project URL.

## Current status

The interface, reporting helpers, document and financial statement helpers, and Edge Function source templates are in place. The frontend is pointed at the Nyilora Supabase project using its public anon key and confirmed business ID `BIZ-NYILORA`. Nothing is connected to Bripta.

The user has run `NYILORA-FOUNDATION-ONE-RUN.sql` and migrations `0005` through `0019` in the Nyilora project. `NYILORA-FINAL-ADDITIONS-ONE-RUN.sql` combines migrations `0020`–`0025` and is the next file to run once. It passed a local install check after the earlier schema. The frontend loads private profile photos through short-lived signed URLs. The settings UI accepts only public Paybill details and directs private Daraja credentials to Edge Function secrets. Edge Functions have **not** been deployed. The first administrator has not been selected, so login and role tests against the live project remain. Payment callbacks and SMS delivery require Nyilora's provider details and end-to-end tests before they can be enabled. This repository is suitable for an interface preview after the SQL is installed and committed, not for live financial transactions yet.

## Details needed to finish

1. Nyilora will choose its initial administrator later. Create that login privately in Nyilora's Supabase Auth, then add its staff record before first use.
2. Nyilora Paybill/shortcode and Daraja credentials; enter credentials as **Supabase secrets**, never in `config.js` or Git.
3. Nyilora SMS provider endpoint, token, approved sender ID, and payload specification; enter token as a Supabase secret.
4. Test all roles and features against a disposable Nyilora test dataset. The reference app has legacy base tables plus many later changes, so its historical repair SQL must not be run on this fresh Nyilora project.

## Deployment order after setup

1. Install and verify Nyilora's clean database schema, RLS, storage bucket, single branch and staff accounts.
2. Verify the public values in `config.js`. Put service-role, Daraja and SMS credentials in Nyilora's Supabase secrets.
3. Review and deploy the seven functions in `supabase/functions` to **Nyilora's project only** after the payment and SMS provider setup is complete.
4. Verify login, every role and tab, loan issuance, repayment and callback idempotency, suspense, accounting, documents, SMS, subscription boundaries, and branch isolation with test data.
5. Connect hosting and register Nyilora callback URLs only after those checks pass.

Do not copy production records or run Bripta's business-specific recovery SQL in Nyilora.
