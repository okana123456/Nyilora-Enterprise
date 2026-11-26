import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const projectHost = "sedzaagjqfsoxglcwyed.supabase.co";
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status, headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function timestamp() {
  const parts = new Intl.DateTimeFormat("en-GB", {
    timeZone: "Africa/Nairobi", year: "numeric", month: "2-digit", day: "2-digit",
    hour: "2-digit", minute: "2-digit", second: "2-digit", hourCycle: "h23",
  }).formatToParts(new Date());
  const value = (type: string) => parts.find((part) => part.type === type)?.value || "";
  return ["year", "month", "day", "hour", "minute", "second"].map(value).join("");
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, message: "Use POST." }, 405);

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    if (!serviceKey || new URL(supabaseUrl).host !== projectHost) {
      return json({ ok: false, message: "Nyilora payment configuration is incomplete." }, 503);
    }
    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const token = /^Bearer (.+)$/i.exec(req.headers.get("authorization") || "")?.[1];
    if (!token) return json({ ok: false, message: "Sign in to check this purchase." }, 401);
    const { data: authData, error: authError } = await admin.auth.getUser(token);
    if (authError || !authData.user) return json({ ok: false, message: "Your session has expired." }, 401);
    const { data: staff, error: staffError } = await admin.from("loan_staff")
      .select("business_id,role,is_active")
      .eq("auth_user_id", authData.user.id).maybeSingle();
    if (staffError) throw staffError;
    if (!staff?.is_active || !["admin", "branch_manager"].includes(staff.role)) {
      return json({ ok: false, message: "Only company administrators can check SMS purchases." }, 403);
    }

    const body = await req.json().catch(() => ({}));
    const requestId = String(body.request_id || "").trim();
    if (!/^[0-9a-f-]{36}$/i.test(requestId)) {
      return json({ ok: false, message: "Choose a valid SMS purchase." }, 400);
    }
    const { data: purchase, error: purchaseError } = await admin.from("nyilora_sms_bundle_requests")
      .select("id,business_id,status,credits,amount,checkout_request_id")
      .eq("id", requestId).eq("business_id", staff.business_id).maybeSingle();
    if (purchaseError) throw purchaseError;
    if (!purchase) return json({ ok: false, message: "SMS purchase was not found in this company." }, 404);
    if (purchase.status === "credited") {
      return json({ ok: true, credited: true, message: "SMS credits were already issued for this purchase." });
    }
    if (!purchase.checkout_request_id) {
      return json({ ok: false, message: "This SMS purchase has no saved M-Pesa request to check." }, 400);
    }

    const shortcode = String(Deno.env.get("SERVICE_SHORTCODE") || "").trim();
    const consumerKey = String(Deno.env.get("SERVICE_CONSUMER_KEY") || "").trim();
    const consumerSecret = String(Deno.env.get("SERVICE_CONSUMER_SECRET") || "").trim();
    const passkey = String(Deno.env.get("SERVICE_PASSKEY") || "").trim();
    const mode = String(Deno.env.get("SERVICE_DARAJA_ENVIRONMENT") || "production").toLowerCase();
    if (!shortcode || !consumerKey || !consumerSecret || !passkey) {
      return json({ ok: false, message: "Owner Paybill credentials are incomplete." }, 503);
    }
    const baseUrl = mode === "sandbox" ? "https://sandbox.safaricom.co.ke" : "https://api.safaricom.co.ke";
    const oauthResponse = await fetch(`${baseUrl}/oauth/v1/generate?grant_type=client_credentials`, {
      headers: { Authorization: `Basic ${btoa(`${consumerKey}:${consumerSecret}`)}` },
      signal: AbortSignal.timeout(15000),
    });
    const oauth = await oauthResponse.json().catch(() => ({}));
    if (!oauthResponse.ok || !oauth.access_token) {
      return json({ ok: false, message: "Owner Paybill authentication failed." }, 502);
    }
    const ts = timestamp();
    const statusResponse = await fetch(`${baseUrl}/mpesa/stkpushquery/v1/query`, {
      method: "POST",
      headers: { Authorization: `Bearer ${oauth.access_token}`, "Content-Type": "application/json" },
      body: JSON.stringify({
        BusinessShortCode: Number(shortcode),
        Password: btoa(`${shortcode}${passkey}${ts}`),
        Timestamp: ts,
        CheckoutRequestID: purchase.checkout_request_id,
      }),
      signal: AbortSignal.timeout(20000),
    });
    const result = await statusResponse.json().catch(() => ({}));
    if (!statusResponse.ok || result.errorCode) {
      return json({ ok: false, message: "Safaricom could not confirm this purchase yet. Try again later." }, 502);
    }
    if (String(result.ResultCode ?? "") !== "0") {
      return json({ ok: true, credited: false,
        message: result.ResultCode == null
          ? "Safaricom has not confirmed this payment yet. No credits were issued."
          : "Safaricom did not confirm this SMS payment as successful. No credits were issued." });
    }

    // The checkout ID is the one stable purchase reference shared with the
    // callback; the database RPC makes repeats idempotent.
    const { data: topup, error: topupError } = await admin.rpc("nyilora_owner_add_sms_credits", {
      p_business_id: purchase.business_id,
      p_credits: purchase.credits,
      p_customer_amount_paid: purchase.amount,
      p_customer_reference: purchase.checkout_request_id,
      p_note: `Safaricom STK status verified for SMS bundle request ${purchase.id}`,
    });
    if (topupError) throw topupError;
    const { error: updateError } = await admin.from("nyilora_sms_bundle_requests")
      .update({ status: "credited", paid_at: new Date().toISOString(),
        credited_at: new Date().toISOString(), result_code: "0",
        result_description: "Verified with Safaricom STK status query",
        note: `Paid and credited. Remaining SMS: ${topup?.remaining ?? "updated"}` })
      .eq("id", purchase.id).eq("business_id", purchase.business_id);
    if (updateError) throw updateError;
    return json({ ok: true, credited: true, remaining: topup?.remaining ?? null,
      message: "Safaricom confirmed the payment. SMS credits are available." });
  } catch (error) {
    console.error("SMS purchase status check failed", error instanceof Error ? error.message : String(error));
    return json({ ok: false, message: "Could not complete the SMS payment check. Try again or review function logs." }, 500);
  }
});
