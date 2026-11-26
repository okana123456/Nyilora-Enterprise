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
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, message: "Use POST." }, 405);

  try {
    const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    if (new URL(supabaseUrl).host !== projectHost || !serviceKey) {
      return json({ ok: false, message: "Nyilora Supabase configuration is incomplete." }, 503);
    }

    const supabase = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const token = /^Bearer (.+)$/i.exec(req.headers.get("authorization") || "")?.[1];
    if (!token) return json({ ok: false, message: "Sign in as an administrator." }, 401);
    const { data: authData, error: authError } = await supabase.auth.getUser(token);
    if (authError || !authData.user) return json({ ok: false, message: "Your session has expired." }, 401);

    const { data: staff, error: staffError } = await supabase.from("loan_staff")
      .select("id,business_id,role,is_active")
      .eq("auth_user_id", authData.user.id).maybeSingle();
    if (staffError) throw staffError;
    if (!staff?.is_active || staff.role !== "admin" || !staff.business_id) {
      return json({ ok: false, message: "Only an active company administrator can register its Paybill." }, 403);
    }

    const { data: settings, error: settingsError } = await supabase.from("loan_settings")
      .select("mpesa_shortcode,daraja_environment")
      .eq("business_id", staff.business_id).maybeSingle();
    if (settingsError) throw settingsError;
    const shortcode = String(settings?.mpesa_shortcode || "").trim();
    if (!/^\d{5,10}$/.test(shortcode)) {
      return json({ ok: false, message: "Save a valid Paybill number in Settings first." }, 400);
    }

    const mode = String(settings?.daraja_environment || "").toLowerCase();
    if (!["sandbox", "production"].includes(mode)) {
      return json({ ok: false, message: "Choose Sandbox or Production in Settings." }, 400);
    }
    const { data: credentials, error: credentialsError } = await supabase.rpc(
      "nyilora_get_c2b_credentials", { p_business_id: staff.business_id },
    );
    if (credentialsError) throw credentialsError;
    const consumerKey = String(credentials?.consumer_key || "");
    const consumerSecret = String(credentials?.consumer_secret || "");
    const callbackToken = String(credentials?.callback_token || "");
    if (!consumerKey || !consumerSecret || callbackToken.length < 32) {
      return json({ ok: false, message: "Save this company's Daraja consumer key and secret in Settings first." }, 400);
    }

    const baseUrl = mode === "sandbox" ? "https://sandbox.safaricom.co.ke" : "https://api.safaricom.co.ke";
    const oauthResponse = await fetch(`${baseUrl}/oauth/v1/generate?grant_type=client_credentials`, {
      headers: { Authorization: `Basic ${btoa(`${consumerKey}:${consumerSecret}`)}` },
      signal: AbortSignal.timeout(15000),
    });
    const oauth = await oauthResponse.json();
    if (!oauthResponse.ok || !oauth.access_token) {
      return json({ ok: false, message: "Daraja authentication failed. Check the C2B consumer key, secret, and environment." }, 502);
    }

    const callback = new URL(`${supabaseUrl}/functions/v1/payment-callback`);
    callback.searchParams.set("token", callbackToken);
    const validation = new URL(callback);
    validation.searchParams.set("validation", "1");
    const path = (Deno.env.get("NYILORA_C2B_REGISTER_PATH") || "/mpesa/c2b/v1/registerurl").trim();
    if (!["/mpesa/c2b/v1/registerurl", "/mpesa/c2b/v2/registerurl"].includes(path)) {
      return json({ ok: false, message: "Invalid C2B registration path configuration." }, 503);
    }

    const registrationResponse = await fetch(`${baseUrl}${path}`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${oauth.access_token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({
        ShortCode: shortcode,
        ResponseType: "Completed",
        ConfirmationURL: callback.toString(),
        ValidationURL: validation.toString(),
      }),
      signal: AbortSignal.timeout(20000),
    });
    const registration = await registrationResponse.json().catch(() => ({}));
    const accepted = registrationResponse.ok && !registration.errorCode &&
      (registration.ConversationID || registration.OriginatorConversationID ||
        String(registration.ResponseCode || "") === "0");
    if (!accepted) {
      return json({
        ok: false,
        message: String(registration.errorMessage || registration.ResponseDescription || "Safaricom did not confirm callback registration."),
      }, 502);
    }
    return json({
      ok: true,
      message: "Safaricom accepted Nyilora's C2B callback registration. Verify it with a small live payment before enabling automatic allocation.",
      shortcode,
      environment: mode,
      confirmation_endpoint: `${supabaseUrl}/functions/v1/payment-callback`,
      conversation_id: registration.ConversationID || null,
    });
  } catch (error) {
    console.error("Nyilora C2B registration failed", error instanceof Error ? error.message : String(error));
    return json({ ok: false, message: "Could not register the callback. Check the function logs and try again." }, 500);
  }
});
