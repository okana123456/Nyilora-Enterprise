import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";
const NYILORA_BUSINESS_ID = Deno.env.get('NYILORA_BUSINESS_ID')?.trim() || '';
const NYILORA_SMS_SENDER_ID = Deno.env.get('NYILORA_SMS_SENDER_ID')?.trim() || '';

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type, x-test-pin",
};

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

function kenyaPhone(value: unknown) {
  const digits = String(value || "").replace(/\D/g, "");
  const tail = digits.slice(-9);
  if (!/^[17]\d{8}$/.test(tail)) return null;
  return `254${tail}`;
}

async function callerBusinessId(
  req: Request,
  admin: ReturnType<typeof createClient>,
  serviceKey: string,
) {
  const tokens = [
    req.headers.get("Authorization"),
    req.headers.get("apikey"),
    req.headers.get("x-supabase-auth-token"),
  ]
    .map((value) => String(value || "").replace(/^Bearer\s+/i, "").trim())
    .filter(Boolean);

  if (!tokens.length) return null;
  if (tokens.includes(serviceKey)) return "__service_role__";

  const userToken = tokens[0];
  const { data: userData, error: userError } = await admin.auth.getUser(userToken);
  if (userError || !userData.user) return null;

  let query = admin
    .from("loan_staff")
    .select("business_id")
    .eq("auth_user_id", userData.user.id)
    .eq("is_active", true)
    .limit(1)
    .maybeSingle();
  let { data: staff } = await query;
  if (!staff && userData.user.email) {
    const fallback = await admin
      .from("loan_staff")
      .select("business_id")
      .ilike("email", userData.user.email)
      .eq("is_active", true)
      .limit(1)
      .maybeSingle();
    staff = fallback.data;
  }
  return staff?.business_id || null;
}

function providerUid(payload: any) {
  return String(
    payload?.data?.uid || payload?.data?.id || payload?.data?.message_id ||
    payload?.uid || payload?.id || payload?.message_id || "",
  ).trim() || null;
}

function kenyaTodayUtcBounds() {
  const formatter = new Intl.DateTimeFormat("en-CA", {
    timeZone: "Africa/Nairobi",
    year: "numeric",
    month: "2-digit",
    day: "2-digit",
  });
  const today = formatter.format(new Date());
  const start = new Date(`${today}T00:00:00+03:00`);
  const end = new Date(`${today}T23:59:59.999+03:00`);
  return {
    today,
    startIso: start.toISOString(),
    endIso: end.toISOString(),
  };
}

async function sendSmsProviderDirect(smsProviderToken: string, sendUrl: string, phone: unknown) {
  const recipient = kenyaPhone(phone);
  if (!recipient) return { ok: false, code: "invalid_phone", message: "Phone number is invalid" };

  const message = "Nyilora Enterprises SMS test successful. Repayment notifications are now active.";
  let response: Response;
  try {
    response = await fetch(sendUrl, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${smsProviderToken}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify({
        recipient,
        sender_id: NYILORA_SMS_SENDER_ID,
        type: "plain",
        message,
      }),
      signal: AbortSignal.timeout(15000),
    });
  } catch (error) {
    const errorMessage = error instanceof Error ? error.message : String(error);
    return { ok: false, code: "smsProvider_unreachable", recipient, message: errorMessage };
  }

  const responseText = await response.text();
  let providerResponse: any = { raw: responseText };
  try { providerResponse = responseText ? JSON.parse(responseText) : {}; } catch (_) { /* keep raw response */ }
  const accepted = response.ok && String(providerResponse?.status || "success").toLowerCase() !== "error";
  return {
    ok: accepted,
    status: accepted ? "sent" : "failed",
    recipient,
    provider_uid: accepted ? providerUid(providerResponse) : null,
    provider_response: providerResponse,
    provider_error: accepted ? null : String(providerResponse?.message || providerResponse?.error || `HTTP ${response.status}`),
  };
}

async function deliverClaim(
  admin: ReturnType<typeof createClient>,
  smsProviderToken: string,
  sendUrl: string,
  claim: any,
) {
  const recipient = kenyaPhone(claim.recipient);
  if (!recipient) {
    await admin.rpc("nyilora_complete_repayment_sms", {
      p_outbox_id: claim.outbox_id,
      p_status: "failed",
      p_error: "Recipient phone number is invalid",
      p_refund: true,
    });
    return { ok: false, code: "invalid_phone" };
  }

  let response: Response;
  try {
    response = await fetch(sendUrl, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${smsProviderToken}`,
        "Content-Type": "application/json",
        Accept: "application/json",
      },
      body: JSON.stringify({
        recipient,
        sender_id: NYILORA_SMS_SENDER_ID,
        type: "plain",
        message: claim.message,
      }),
      signal: AbortSignal.timeout(15000),
    });
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    await admin.rpc("nyilora_complete_repayment_sms", {
      p_outbox_id: claim.outbox_id,
      p_status: "delivery_unknown",
      p_error: `SMS provider did not return a definite result: ${message}`,
      p_refund: false,
    });
    return { ok: false, code: "delivery_unknown" };
  }

  const responseText = await response.text();
  let providerResponse: any = { raw: responseText };
  try { providerResponse = responseText ? JSON.parse(responseText) : {}; } catch (_) { /* keep raw response */ }
  const providerError = String(providerResponse?.message || providerResponse?.error || `HTTP ${response.status}`);
  const accepted = response.ok && String(providerResponse?.status || "success").toLowerCase() !== "error";

  await admin.rpc("nyilora_complete_repayment_sms", {
    p_outbox_id: claim.outbox_id,
    p_status: accepted ? "sent" : "failed",
    p_provider_uid: accepted ? providerUid(providerResponse) : null,
    p_provider_response: providerResponse,
    p_error: accepted ? null : providerError,
    p_refund: !accepted,
  });
  return {
    ok: accepted,
    status: accepted ? "sent" : "failed",
    provider_uid: accepted ? providerUid(providerResponse) : null,
  };
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, message: "Method not allowed" }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const smsProviderToken = Deno.env.get("NYILORA_SMS_API_TOKEN")?.trim() || "";
  const sendUrl = Deno.env.get("NYILORA_SMS_SEND_URL")?.trim() || "";
  if (!NYILORA_BUSINESS_ID || !NYILORA_SMS_SENDER_ID || !smsProviderToken || !sendUrl)
    return json({ ok: false, code: "sms_not_configured", message: "Nyilora SMS provider setup is incomplete" }, 503);

  const body = await req.json().catch(() => ({}));
  const directTestPhone = String(body?.direct_test_phone || "").trim();
  const processTodaySms = body?.process_today_sms === true;
  if (directTestPhone) {
    const expectedPin = Deno.env.get("NYILORA_SMS_TEST_PIN")?.trim() || "";
    const suppliedPin = String(req.headers.get("x-test-pin") || body?.test_pin || "").trim();
    if (!expectedPin || suppliedPin !== expectedPin) {
      return json({ ok: false, message: "Direct SMS provider test requires the correct NYILORA_SMS_TEST_PIN." }, 401);
    }
    return json(await sendSmsProviderDirect(smsProviderToken, sendUrl, directTestPhone));
  }

  if (!supabaseUrl || !serviceKey) return json({ ok: false, message: "Supabase secrets are missing" }, 500);

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });

  if (processTodaySms) {
    const expectedPin = Deno.env.get("NYILORA_SMS_TEST_PIN")?.trim() || "";
    const suppliedPin = String(req.headers.get("x-test-pin") || body?.test_pin || "").trim();
    if (!expectedPin || suppliedPin !== expectedPin) {
      return json({ ok: false, message: "Processing queued SMS requires the correct NYILORA_SMS_TEST_PIN." }, 401);
    }

    const businessId = NYILORA_BUSINESS_ID;
    const limit = Math.max(1, Math.min(Number(body?.limit || 100), 200));
    const bounds = kenyaTodayUtcBounds();
    const { data: pending, error: pendingError } = await admin
      .from("nyilora_sms_outbox")
      .select("repayment_id")
      .eq("business_id", businessId)
      .in("status", ["queued", "failed", "blocked_no_credit"])
      .not("repayment_id", "is", null)
      .gte("queued_at", bounds.startIso)
      .lte("queued_at", bounds.endIso)
      .order("queued_at", { ascending: true })
      .limit(limit);

    if (pendingError) return json({ ok: false, message: pendingError.message }, 500);

    const results: Record<string, unknown>[] = [];
    const repaymentIds = (pending || []).map((row) => row.repayment_id).filter(Boolean);
    for (const repaymentId of repaymentIds) {
      const { data: claim, error: claimError } = await admin.rpc("nyilora_claim_repayment_sms", {
        p_repayment_id: repaymentId,
      });
      if (claimError) {
        results.push({ repayment_id: repaymentId, ok: false, error: claimError.message });
        continue;
      }
      if (!claim?.ok || claim?.already_sent) {
        results.push({ repayment_id: repaymentId, ...claim });
        continue;
      }
      const result = await deliverClaim(admin, smsProviderToken, sendUrl, claim);
      results.push({ repayment_id: repaymentId, ...result });
    }

    return json({
      ok: true,
      mode: "process_today_sms",
      business_id: businessId,
      kenya_date: bounds.today,
      queued_found: repaymentIds.length,
      processed: results.length,
      results,
    });
  }

  const callerBusiness = await callerBusinessId(req, admin, serviceKey);
  if (!callerBusiness) {
    return json({
      ok: false,
      message: "Unauthorized: use this Nyilora project's service_role key in Authorization or apikey.",
    }, 401);
  }
  const businessId = callerBusiness === "__service_role__" ? NYILORA_BUSINESS_ID : callerBusiness;

  if (String(body?.sms_type || "").trim() === "custom") {
    const message = String(body?.message || "").trim();
    const rawRecipients = Array.isArray(body?.recipients) ? body.recipients.slice(0, 300) : [];
    if (!message) return json({ ok: false, message: "Message is required" }, 400);
    if (!rawRecipients.length) return json({ ok: false, message: "At least one recipient is required" }, 400);

    const results: Record<string, unknown>[] = [];
    let sent = 0;
    let failed = 0;
    for (const item of rawRecipients) {
      const phone = typeof item === "string" ? item : item?.phone;
      const name = typeof item === "string" ? "Manual SMS" : item?.name;
      const { data: claim, error: claimError } = await admin.rpc("nyilora_claim_custom_sms", {
        p_business_id: businessId,
        p_recipient: phone,
        p_message: message,
        p_client_name: name || "Manual SMS",
      });
      if (claimError || !claim?.ok) {
        failed++;
        results.push({
          phone,
          ok: false,
          error: claimError?.message || claim?.message || claim?.code || "Could not reserve SMS credit",
        });
        continue;
      }

      const result = await deliverClaim(admin, smsProviderToken, sendUrl, claim);
      if (result.ok) sent++; else failed++;
      results.push({ phone, ...result });
    }

    return json({ ok: true, mode: "custom", business_id: businessId, sent, failed, processed: results.length, results });
  }

  const testPhone = String(body?.test_phone || "").trim();
  if (testPhone) {
    const { data: claim, error: claimError } = await admin.rpc("nyilora_claim_test_sms", {
      p_business_id: businessId,
      p_phone: testPhone,
    });
    if (claimError) return json({ ok: false, message: claimError.message }, 500);
    if (!claim?.ok || claim?.already_sent) return json(claim || { ok: false }, claim?.ok ? 200 : 400);

    const result = await deliverClaim(admin, smsProviderToken, sendUrl, claim);
    return json({ ...result, test: true, recipient: kenyaPhone(testPhone) });
  }

  const requestedClientId = String(body?.client_id || "").trim();
  if (requestedClientId && String(body?.sms_type || "").trim() === "onboarding") {
    const { data: outbox } = await admin
      .from("nyilora_sms_outbox")
      .select("id,business_id,client_id,status")
      .eq("client_id", requestedClientId)
      .eq("message_type", "onboarding")
      .order("queued_at", { ascending: false })
      .limit(1)
      .maybeSingle();
    if (!outbox) return json({ ok: false, code: "not_queued", message: "Client welcome SMS was not queued" }, 404);
    if (callerBusiness !== "__service_role__" && outbox.business_id !== callerBusiness) {
      return json({ ok: false, message: "Forbidden" }, 403);
    }

    const { data: claim, error: claimError } = await admin.rpc("nyilora_claim_client_onboarding_sms", {
      p_client_id: requestedClientId,
    });
    if (claimError) return json({ ok: false, message: claimError.message }, 500);
    if (!claim?.ok || claim?.already_sent) return json(claim || { ok: false }, claim?.ok ? 200 : 400);

    const result = await deliverClaim(admin, smsProviderToken, sendUrl, claim);
    return json({ ...result, onboarding: true, recipient: kenyaPhone(claim.recipient) });
  }

  const requestedRepaymentId = String(body?.repayment_id || "").trim();
  let repaymentIds: string[] = [];

  if (requestedRepaymentId) {
    const { data: outbox } = await admin
      .from("nyilora_sms_outbox")
      .select("repayment_id,business_id")
      .eq("repayment_id", requestedRepaymentId)
      .maybeSingle();
    if (!outbox) return json({ ok: false, code: "not_queued", message: "SMS outbox row was not found" }, 404);
    if (callerBusiness !== "__service_role__" && outbox.business_id !== callerBusiness) {
      return json({ ok: false, message: "Forbidden" }, 403);
    }
    repaymentIds = [requestedRepaymentId];
  } else {
    if (callerBusiness === "__service_role__") {
      return json({ ok: false, message: "A business-scoped repayment ID is required" }, 400);
    }
    const { data: pending } = await admin
      .from("nyilora_sms_outbox")
      .select("repayment_id")
      .eq("business_id", callerBusiness)
      .in("status", ["queued", "failed", "blocked_no_credit"])
      .not("repayment_id", "is", null)
      .order("queued_at", { ascending: true })
      .limit(50);
    repaymentIds = (pending || []).map((row) => row.repayment_id).filter(Boolean);
  }

  const results: Record<string, unknown>[] = [];
  for (const repaymentId of repaymentIds) {
    const { data: claim, error: claimError } = await admin.rpc("nyilora_claim_repayment_sms", {
      p_repayment_id: repaymentId,
    });
    if (claimError) {
      results.push({ repayment_id: repaymentId, ok: false, error: claimError.message });
      continue;
    }
    if (!claim?.ok || claim?.already_sent) {
      results.push({ repayment_id: repaymentId, ...claim });
      continue;
    }

    const result = await deliverClaim(admin, smsProviderToken, sendUrl, claim);
    results.push({ repayment_id: repaymentId, ...result });
  }

  return json({ ok: true, processed: results.length, results });
});
