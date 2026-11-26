# Nyilora Paybill setup

This applies only to the Nyilora Supabase project `sedzaagjqfsoxglcwyed`. It hosts separate companies; each company admin saves that company's own Paybill and Daraja C2B consumer key and secret. These are the two values supplied by Safaricom for that company's Daraja app. A C2B Paybill callback does not need an STK passkey.

## Install once in the Nyilora project

1. Run `supabase/migrations/0038_nyilora_c2b_vault_and_id_matching.sql` in the Nyilora Supabase SQL Editor. It enables Vault, creates a private callback verification token, and installs service-only credential storage and ID matching. It does not alter existing loans or repayments.
2. Deploy `nyilora-c2b-settings` and `nyilora-register-c2b` with **Verify JWT enabled**.
3. Deploy `payment-callback` with **Verify JWT disabled** so Safaricom can call it. The callback still checks its private verification token. The repository's `supabase/config.toml` declares these settings for CLI deployments.
4. Publish the updated website.

No consumer key, consumer secret, or callback token needs to be added manually under Edge Function Secrets. The two consumer credentials are saved through Nyilora Settings in Supabase Vault. The callback token is generated privately by the SQL installation. Existing `SERVICE_*` secrets for the platform's separate billing and SMS payments remain separate.

## Set up each company's Paybill

1. Sign in as an active admin of the company receiving the Paybill. Use `NYILORA-DARAJA-READINESS.sql` if you need to identify which company account holds its clients and loans.
2. Open **Settings → M-Pesa Daraja C2B Settings**. Enter the company's Paybill, choose **Production**, and paste the Daraja app's **consumer key** and **consumer secret**. The fields hide what you type and are cleared after saving. The saved values cannot be viewed in the browser. Leave automatic confirmation off for the first test.
3. Click **Save Settings**. Check that the status says the C2B key and secret are saved.
4. The Settings page displays Nyilora's callback endpoint: `https://sedzaagjqfsoxglcwyed.supabase.co/functions/v1/payment-callback`. Click **Register saved Paybill callback** to register the complete private URL with Safaricom. Do not manually register the displayed base URL; the registration button adds its private verification token. Registration can replace a callback already registered for the same Paybill.

## Check a real payment

With the company's permission, make one small Paybill payment using an unknown account number. Confirm it appears once in that company's Suspense Account. Then make one small payment with a client's **registered national ID number** as the Paybill account number. With automatic confirmation off, check the pending callback and match it to the correct loan. Check the transaction code and amount against the Safaricom statement before enabling automatic confirmation.

The receiving Paybill identifies the company. Within that company, the account number must match exactly one normalized registered client ID. An unknown or ambiguous ID is held in Suspense. The sender's phone number is not used to guess a client.

If Safaricom's production app requires the C2B v2 registration path, set the optional `NYILORA_C2B_REGISTER_PATH` Edge Function secret to `/mpesa/c2b/v2/registerurl` and register again. The default is `/mpesa/c2b/v1/registerurl`.
