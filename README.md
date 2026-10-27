# Nyilora Enterprise

This repository is the separate Nyilora Enterprise loan system. It was cloned from the empty [Nyilora-Enterprise](https://github.com/okana123456/Nyilora-Enterprise) repository and prepared with the Bripta feature layout, a green theme, and Nyilora names. It contains no Bripta clients, payments, credentials, callback URL, or Git history.

## Agreed setup

- One branch, editable by administrators. The Branches tab remains available for viewing and editing that branch.
- Monthly subscription: KES 3,000 starting **1 December 2026**. The server payment functions reject earlier subscription requests.
- SMS credits: KES 0.55 each. Nyilora will supply its own SMS provider API and approved sender ID.
- Nyilora will supply its own M-Pesa Paybill and Daraja credentials. Callback URLs are built from Nyilora's Supabase project URL.

## Current status

The interface, reporting helpers, document and financial statement helpers, and Edge Function source templates are in place. The frontend is pointed at the Nyilora Supabase project using its public anon key and confirmed business ID `BIZ-NYILORA`. Nothing is connected to Bripta.

The user has run `NYILORA-FOUNDATION-ONE-RUN.sql`, migrations `0005` through `0019`, and `NYILORA-FINAL-ADDITIONS-ONE-RUN.sql` in the Nyilora project. The reported read-only checks show one branch, zero staff, ten required application functions, two asset write policies, and no financial or SMS records. The frontend loads private profile photos through short-lived signed URLs. The settings UI accepts only public Paybill details and directs private Daraja credentials to Edge Function secrets. Payment callbacks and SMS delivery require Nyilora's provider details and end-to-end tests before they can be enabled. This repository is suitable for an interface preview, not for live financial transactions yet.

## First administrator setup

The public Sign Up flow has been replaced with a one-time first-admin setup form. Run `supabase/migrations/0026_nyilora_first_admin_gate.sql` in the **Nyilora** SQL Editor, then check it with `NYILORA-ADMIN-SETUP-CHECK.sql`. Set `NYILORA_ADMIN_SETUP_KEY` in **Nyilora's Supabase Edge Function Secrets**, and deploy `supabase/functions/nyilora-bootstrap-admin/index.ts` as `nyilora-bootstrap-admin`. The key value is supplied privately to the owner and must never be placed in Git or `config.js`. The Edge Function creates a confirmed Auth user, then calls the database gate to create the only initial admin and grant its permissions. The database gate rejects a second first-admin claim even if two requests arrive together. Later staff accounts are created by an authenticated administrator through `nyilora-create-staff`. After the first administrator has signed in, disable public signups in Nyilora's Supabase Authentication settings and remove or rotate the setup key. The function's public status request hides the setup tab once staff exists.

## Details needed to finish

1. Nyilora will choose its initial administrator later. Use the private one-time setup key and first-admin form when ready.
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
