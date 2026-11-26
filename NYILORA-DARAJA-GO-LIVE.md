# Nyilora borrower Paybill connection

This is for the Nyilora Supabase project `sedzaagjqfsoxglcwyed`. The C2B confirmation endpoint is
`https://sedzaagjqfsoxglcwyed.supabase.co/functions/v1/payment-callback`.
It is separate from Bripta's project and URL. Safaricom receives a private callback token appended during registration; do not manually register the bare URL shown above.

## Identify the correct business

Run `NYILORA-DARAJA-READINESS.sql` in Nyilora's SQL Editor. The project hosts multiple companies. Select the business ID whose client and loan counts match the company receiving the new Paybill. The original reserved `BIZ-NYILORA` account may not be the account that holds Nyilora Enterprise's active loans.

## Configure privately

In Nyilora's Supabase **Edge Functions → Secrets**, add the production Daraja C2B app's consumer key and consumer secret. For the business `BIZ-NYILORA`, use `NYILORA_C2B_CONSUMER_KEY` and `NYILORA_C2B_CONSUMER_SECRET`. For any other business ID, append two underscores and its ID without the `BIZ-` prefix, for example `NYILORA_C2B_CONSUMER_KEY__A1C8E7FBD382` and `NYILORA_C2B_CONSUMER_SECRET__A1C8E7FBD382`.

Add `NYILORA_C2B_CALLBACK_TOKEN` as a random secret of at least 32 characters. It is shared by the callback receiver, not by businesses or browsers. Do not put any of these values in Git, `config.js`, the website's Settings form, or this guide. A C2B registration does not use the STK passkey.

You can generate the callback token locally in PowerShell with `$bytes = New-Object byte[] 32; [System.Security.Cryptography.RandomNumberGenerator]::Create().GetBytes($bytes); [Convert]::ToBase64String($bytes)`. Copy its output directly into Supabase Secrets and keep it private.

`SERVICE_*` secrets belong to the separate platform subscription and SMS bundle STK payments. Do not replace those with Nyilora's borrower Paybill credentials.

## Deploy and register

1. Deploy `payment-callback` with **Verify JWT disabled** so Safaricom can call it. The function itself checks the private callback token. The repository's `supabase/config.toml` also declares the required setting for CLI deployments.
2. Deploy `nyilora-register-c2b` with **Verify JWT enabled**. It checks the signed-in company administrator and registers only that company's saved Paybill.
3. Publish the updated website. Sign in as that company's admin. In **Settings**, enter the new Paybill, choose **Production (Live)**, leave auto-confirmation off, and save.
4. Click **Register saved Paybill callback**. This replaces any callback URLs currently registered for the Paybill, so first confirm that the Paybill is not still routed to another production system. A success message means Safaricom accepted registration; it does not prove a payment was delivered.
5. Make one small authorized live payment using a deliberately unmatched account reference. Verify its transaction code and amount in **Suspense Account** and in the Safaricom statement. Then test a payment with a real borrower's registered phone as the account reference, still with auto-confirmation off. Confirm it appears once in the pending queue and can be matched to the correct loan.
6. Only after reconciliation, consider enabling automatic confirmation. Confirm the callback queue, repayment, loan balance, schedule, and SMS are consistent. Do not turn it on while any callback is missing or mismatched.

If Safaricom's production app requires the C2B v2 registration path, set `NYILORA_C2B_REGISTER_PATH` to `/mpesa/c2b/v2/registerurl` in Edge Function secrets and register again. The default is Safaricom's documented `/mpesa/c2b/v1/registerurl`.

The SMS sender API and Paybill C2B integration are separate. Adding a Paybill does not configure the SMS provider.
