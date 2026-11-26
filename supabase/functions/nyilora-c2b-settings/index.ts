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

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, message: "Use POST." }, 405);

  let stage = "setup";
  try {
    const url = Deno.env.get("SUPABASE_URL") || "";
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
    if (!url || new URL(url).host !== projectHost || !serviceKey) {
      return json({ ok: false, message: "Nyilora Supabase configuration is incomplete." }, 503);
    }
    const supabase = createClient(url, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const bearer = /^Bearer (.+)$/i.exec(req.headers.get("authorization") || "")?.[1];
    if (!bearer) return json({ ok: false, message: "Sign in as an administrator." }, 401);
    stage = "authentication";
    const { data: authData, error: authError } = await supabase.auth.getUser(bearer);
    if (authError || !authData.user) return json({ ok: false, message: "Your session has expired." }, 401);
    const { data: staff, error: staffError } = await supabase.from("loan_staff")
      .select("business_id,role,is_active").eq("auth_user_id", authData.user.id).maybeSingle();
    if (staffError) throw staffError;
    if (!staff?.is_active || staff.role !== "admin" || !staff.business_id) {
      return json({ ok: false, message: "Only an active company administrator can configure its Paybill." }, 403);
    }

    stage = "request";
    const body = await req.json().catch(() => ({}));
    if (body.action === "save") {
      const consumerKey = String(body.consumer_key || "").trim();
      const consumerSecret = String(body.consumer_secret || "").trim();
      if (consumerKey.length < 5 || consumerKey.length > 512 ||
          consumerSecret.length < 5 || consumerSecret.length > 512) {
        return json({ ok: false, message: "Enter both Daraja consumer key and secret." }, 400);
      }
      stage = "vault_write";
      const { error } = await supabase.rpc("nyilora_set_c2b_credentials", {
        p_business_id: staff.business_id,
        p_consumer_key: consumerKey,
        p_consumer_secret: consumerSecret,
      });
      if (error) throw error;
    } else if (body.action !== "status") {
      return json({ ok: false, message: "Unknown action." }, 400);
    }

    stage = "vault_status";
    const { data: credentialsSaved, error: credentialsError } = await supabase.rpc(
      "nyilora_c2b_credentials_saved", { p_business_id: staff.business_id },
    );
    if (credentialsError) throw credentialsError;
    return json({ ok: true, credentials_saved: credentialsSaved === true });
  } catch (error) {
    // Never log request bodies or credential values.
    const rawCode = (error as { code?: unknown })?.code;
    const code = typeof rawCode === "string" && /^[A-Z0-9]{5,10}$/.test(rawCode)
      ? rawCode : "INTERNAL";
    console.error("Nyilora C2B settings failed", { stage, code });
    return json({
      ok: false,
      message: stage === "vault_write"
        ? `Could not store the Daraja key pair (${code}). The Paybill settings were saved; the keys were not.`
        : `Could not complete Daraja settings at ${stage} (${code}).`,
      stage, code,
    }, 500);
  }
});
