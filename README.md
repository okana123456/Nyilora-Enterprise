# Nyilora Enterprise

Nyilora is a green lending system with the same functional areas as Bripta. This repository and Supabase project `sedzaagjqfsoxglcwyed` are separate from Bripta. The website can host multiple businesses. Each business has one editable Head Office branch, its own administrators and invited staff, and its own lending, accounting, payments, SMS and billing records.

## Install the multi-business update

1. In **Nyilora's** Supabase SQL Editor, run [NYILORA-MULTI-BUSINESS-ONE-RUN.sql](NYILORA-MULTI-BUSINESS-ONE-RUN.sql). It contains migrations 0027–0031 in order. It adds tenant isolation and does not recalculate existing financial amounts. The original empty `BIZ-NYILORA` account is reserved for the first signup; later signups receive new IDs.
2. Deploy the changed Edge Functions from `supabase/functions/`: `nyilora-bootstrap-admin`, `nyilora-create-staff`, `payment-callback`, `send-repayment-sms`, `start-service-payment`, `service-payment-callback`, `start-sms-bundle-payment`, `sms-bundle-payment-callback`.
3. Keep `NYILORA_ADMIN_SETUP_KEY` set privately in this Supabase project's Edge Function secrets. It must be at least 32 characters. Do not put it in Git or the frontend. The setup key authorizes creation of each company administrator. Only existing administrators can invite staff into their own company.
4. Commit and publish the website changes, then register a first business on **Sign Up** using its business name and setup key. Sign in with the new credentials. Additional businesses use the same signup form and key, receiving separate business IDs and records.
5. Run [NYILORA-MULTI-BUSINESS-VERIFY.sql](NYILORA-MULTI-BUSINESS-VERIFY.sql). Every failure count should be zero. Test an administrator and staff login for each business and confirm that one cannot see the other's data.

## Payments and messaging

Each business enters its own unique M-Pesa Paybill in Settings. The callback uses that Paybill to identify the business; payments with unknown or ambiguous Paybills go into the service-only `nyilora_unrouted_callbacks` table for review. Do not enable a business's live callback until its Paybill and loan repayment test have been verified. The callback URL belongs to this Nyilora Supabase project only.

Each business needs its own approved sender ID and SMS provider configuration. The original `BIZ-NYILORA` uses `NYILORA_SMS_API_TOKEN`, `NYILORA_SMS_SEND_URL`, and `NYILORA_SMS_SENDER_ID`. For a new ID such as `BIZ-ABC123`, use `NYILORA_SMS_API_TOKEN__ABC123`, `NYILORA_SMS_SEND_URL__ABC123`, and `NYILORA_SMS_SENDER_ID__ABC123` as secrets in the **Nyilora** Supabase project. Other existing payment provider secrets remain private in the same project. SMS credits cost KES 0.55 each. Subscription billing starts in December 2026 at KES 3,000 per business each month.

## Local checks

The new database test loads the foundation and migrations into an isolated PostgreSQL runtime, reruns the update, creates two companies, and checks RLS, lending, expenses, accounting, callback suspense, SMS and billing isolation. The frontend and Edge Function files have also been syntax checked. These local tests do not replace a live payment callback, SMS provider, email invitation and role test in the Nyilora project.
