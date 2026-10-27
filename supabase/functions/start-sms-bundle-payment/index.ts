import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
const NYILORA_BUSINESS_ID = Deno.env.get('NYILORA_BUSINESS_ID')?.trim() || '';

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, prefer",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function normalizePhone(phone: unknown) {
  let clean = String(phone || "").replace(/\D/g, "");
  if (clean.startsWith("0")) clean = `254${clean.slice(1)}`;
  if (clean.startsWith("7") || clean.startsWith("1")) clean = `254${clean}`;
  return clean;
}

function timestamp() {
  const d = new Date();
  const pad = (value: number) => String(value).padStart(2, "0");
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

function env(name: string) {
  return String(Deno.env.get(name) || Deno.env.get(name.replace("SERVICE_", "DARAJA_")) || "").trim();
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, message: "Use POST" }, 405);

  try {
    const body = await req.json().catch(() => ({}));
    const cleanPhone = normalizePhone(body.phone);
    if (!/^254(7|1)\d{8}$/.test(cleanPhone)) {
      return json({ ok: false, message: "Enter a valid Safaricom phone number." }, 400);
    }

    const allowedCredits = new Set([100, 200, 500, 1000, 2500, 5000, 10000]);
    const credits = Number(body.credits || 0);
    if (!allowedCredits.has(credits)) {
      return json({ ok: false, message: "Choose a valid SMS bundle." }, 400);
    }

    // M-Pesa STK amounts are whole shillings. These bundles price exactly at KES 0.55/SMS.
    const amount = credits * 55 / 100;

    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    if (!NYILORA_BUSINESS_ID || !supabaseUrl || !serviceKey) return json({ ok: false, message: "Nyilora SMS payment setup is incomplete." }, 503);
    const supabase = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const token = /^Bearer (.+)$/i.exec(req.headers.get("authorization") || "")?.[1];
    if (!token) return json({ ok: false, message: "Sign in to buy SMS credits." }, 401);
    const { data: authData, error: authError } = await supabase.auth.getUser(token);
    if (authError || !authData.user) return json({ ok: false, message: "Your session has expired." }, 401);
    const { data: staff, error: staffError } = await supabase
      .from("loan_staff")
      .select("id, business_id, role, is_active")
      .eq("auth_user_id", authData.user.id)
      .eq("business_id", NYILORA_BUSINESS_ID)
      .maybeSingle();
    if (staffError) throw staffError;

    if (!staff?.is_active || !["admin", "branch_manager"].includes(staff.role)) {
      return json({ ok: false, message: "Only admins and branch managers can buy SMS bundles." }, 403);
    }

    const shortcode = env("SERVICE_SHORTCODE");
    const consumerKey = env("SERVICE_CONSUMER_KEY");
    const consumerSecret = env("SERVICE_CONSUMER_SECRET");
    const passkey = env("SERVICE_PASSKEY");
    const transactionType = Deno.env.get("SERVICE_TRANSACTION_TYPE") || Deno.env.get("DARAJA_TRANSACTION_TYPE") || "CustomerPayBillOnline";
    const mode = (Deno.env.get("SERVICE_DARAJA_ENVIRONMENT") || "production").toLowerCase();

    if (!consumerKey || !consumerSecret || !passkey || !shortcode) {
      return json({
        ok: false,
        message: "Daraja credentials are missing. Use the same SERVICE_* secrets used by subscription payments.",
      }, 400);
    }

    const baseUrl = mode === "sandbox" ? "https://sandbox.safaricom.co.ke" : "https://api.safaricom.co.ke";
    const oauthRes = await fetch(`${baseUrl}/oauth/v1/generate?grant_type=client_credentials`, {
      headers: { Authorization: `Basic ${btoa(`${consumerKey}:${consumerSecret}`)}` },
    });
    const oauth = await oauthRes.json();
    if (!oauthRes.ok || !oauth.access_token) {
      return json({ ok: false, message: oauth.errorMessage || oauth.error_description || "Daraja OAuth failed.", response: oauth }, 400);
    }

    const { data: requestRow, error: requestError } = await supabase
      .from("nyilora_sms_bundle_requests")
      .insert({
        business_id: staff.business_id,
        credits,
        amount,
        customer_amount: amount,
        phone: cleanPhone,
        requested_by: staff.id,
        status: "pending",
        note: `SMS bundle purchase: ${credits} credits`,
      })
      .select("id")
      .single();
    if (requestError) return json({ ok: false, message: requestError.message }, 500);

    const ts = timestamp();
    const callbackUrl = `${supabaseUrl}/functions/v1/sms-bundle-payment-callback`;
    const accountReference = `SMS${String(staff.business_id).replace(/[^a-z0-9]/gi, "").slice(-7).toUpperCase()}`.slice(0, 12);
    const payload = {
      BusinessShortCode: Number(shortcode),
      Password: btoa(`${shortcode}${passkey}${ts}`),
      Timestamp: ts,
      TransactionType: transactionType,
      Amount: amount,
      PartyA: Number(cleanPhone),
      PartyB: Number(shortcode),
      PhoneNumber: Number(cleanPhone),
      CallBackURL: callbackUrl,
      AccountReference: accountReference,
      TransactionDesc: `Nyilora SMS bundle ${credits}`,
    };

    const stkRes = await fetch(`${baseUrl}/mpesa/stkpush/v1/processrequest`, {
      method: "POST",
      headers: { Authorization: `Bearer ${oauth.access_token}`, "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const stk = await stkRes.json();
    if (!stkRes.ok || stk.ResponseCode !== "0") {
      await supabase
        .from("nyilora_sms_bundle_requests")
        .update({ status: "cancelled", result_description: stk.errorMessage || stk.ResponseDescription || "M-Pesa prompt failed", provider_response: stk })
        .eq("id", requestRow.id);
      return json({
        ok: false,
        message: stk.errorMessage || stk.ResponseDescription || "M-Pesa prompt failed.",
        response: stk,
      }, 400);
    }

    const { error: saveError } = await supabase
      .from("nyilora_sms_bundle_requests")
      .update({
        merchant_request_id: stk.MerchantRequestID,
        checkout_request_id: stk.CheckoutRequestID,
        result_description: stk.ResponseDescription,
        provider_response: stk,
      })
      .eq("id", requestRow.id);
    if (saveError) {
      return json({
        ok: false,
        message: `M-Pesa prompt was sent, but Nyilora could not save the SMS request: ${saveError.message}`,
        checkout_request_id: stk.CheckoutRequestID,
      }, 500);
    }

    return json({
      ok: true,
      message: "SMS bundle payment prompt sent.",
      credits,
      amount,
      checkout_request_id: stk.CheckoutRequestID,
      customer_message: stk.CustomerMessage,
    });
  } catch (error) {
    return json({ ok: false, message: error instanceof Error ? error.message : String(error) }, 500);
  }
});
