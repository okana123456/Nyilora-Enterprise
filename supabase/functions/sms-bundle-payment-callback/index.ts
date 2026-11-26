import { createClient } from "https://esm.sh/@supabase/supabase-js@2";

function callbackResponse() {
  return new Response(JSON.stringify({ ResultCode: 0, ResultDesc: "Accepted" }), {
    status: 200,
    headers: { "Content-Type": "application/json" },
  });
}

function requireEnv(name: string) {
  const value = Deno.env.get(name)?.trim();
  if (!value) throw new Error(`Missing secret: ${name}`);
  return value;
}

function metaValue(items: Array<{ Name?: string; Value?: unknown }>, name: string) {
  return items?.find((item) => item.Name === name)?.Value ?? null;
}

async function validSignature(secret: string, requestId: string, signature: string) {
  if (!/^[0-9a-f]{64}$/.test(signature)) return false;
  const key = await crypto.subtle.importKey("raw", new TextEncoder().encode(secret),
    { name: "HMAC", hash: "SHA-256" }, false, ["verify"]);
  const bytes = new Uint8Array(signature.match(/.{2}/g)!.map((part) => parseInt(part, 16)));
  return crypto.subtle.verify("HMAC", key, bytes, new TextEncoder().encode(requestId));
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return callbackResponse();

  try {
    const supabaseUrl = requireEnv("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SERVICE_ROLE_KEY");
    if (!serviceKey) throw new Error("Missing secret: SUPABASE_SERVICE_ROLE_KEY");

    const callbackUrl = new URL(req.url);
    const signedRequestId = callbackUrl.searchParams.get("request") || "";
    const signature = callbackUrl.searchParams.get("signature") || "";
    if (!await validSignature(serviceKey, signedRequestId, signature)) {
      return new Response("Invalid SMS payment callback", { status: 403 });
    }

    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });

    const payload = await req.json().catch(() => ({}));
    const stk = payload?.Body?.stkCallback;
    const checkoutRequestId = String(stk?.CheckoutRequestID || "").trim();
    if (!checkoutRequestId) {
      console.error("SMS bundle callback ignored: CheckoutRequestID is missing");
      return callbackResponse();
    }

    const resultCode = String(stk?.ResultCode ?? "");
    const resultDescription = String(stk?.ResultDesc || "");
    const items = stk?.CallbackMetadata?.Item || [];
    const receipt = String(metaValue(items, "MpesaReceiptNumber") || "").trim();
    const phone = metaValue(items, "PhoneNumber");
    const paidAmount = Number(metaValue(items, "Amount") || 0);
    const paid = resultCode === "0";

    const { data: requestRow, error: requestError } = await admin
      .from("nyilora_sms_bundle_requests")
      .select("id,business_id,credits,amount,phone,status")
      .eq("checkout_request_id", checkoutRequestId)
      .maybeSingle();
    if (requestError) throw requestError;
    if (!requestRow || requestRow.id !== signedRequestId) {
      console.error("SMS bundle callback could not match its signed request", { checkout_request_id: checkoutRequestId, resultCode });
      return callbackResponse();
    }
    if (requestRow.status === "credited") return callbackResponse();

    if (!paid) {
      const { error: failError } = await admin
        .from("nyilora_sms_bundle_requests")
        .update({
          status: "cancelled",
          result_code: resultCode,
          result_description: resultDescription,
          provider_response: payload,
        })
        .eq("id", requestRow.id);
      if (failError) throw failError;
      return callbackResponse();
    }

    if (paidAmount < Number(requestRow.amount) || receipt.length < 4) {
      const { error: reviewError } = await admin
        .from("nyilora_sms_bundle_requests")
        .update({ status: "review", result_code: resultCode,
          result_description: "M-Pesa payment requires manual review before SMS credits are issued",
          provider_response: payload })
        .eq("id", requestRow.id);
      if (reviewError) throw reviewError;
      console.error("SMS bundle callback needs payment review", { request_id: requestRow.id });
      return callbackResponse();
    }

    {
      const { error: updateError } = await admin
        .from("nyilora_sms_bundle_requests")
        .update({
          status: "paid",
          paid_at: new Date().toISOString(),
          payment_reference: receipt ? String(receipt) : null,
          phone: phone ? String(phone) : requestRow.phone,
          customer_amount: paidAmount || requestRow.amount,
          result_code: resultCode,
          result_description: resultDescription,
          provider_response: payload,
        })
        .eq("id", requestRow.id);
      if (updateError) throw updateError;

      const { data: topup, error: topupError } = await admin.rpc("nyilora_owner_add_sms_credits", {
        p_business_id: requestRow.business_id,
        p_credits: requestRow.credits,
        p_customer_amount_paid: paidAmount || requestRow.amount,
        // The checkout ID identifies this purchase across callback and manual
        // status checks, so concurrent retries cannot issue a second top-up.
        p_customer_reference: checkoutRequestId,
        p_note: `Auto-credited from SMS bundle request ${requestRow.id}`,
      });
      if (topupError) throw topupError;

      const { error: creditedError } = await admin
        .from("nyilora_sms_bundle_requests")
        .update({
          status: "credited",
          credited_at: new Date().toISOString(),
          note: `Paid and credited. Remaining SMS: ${topup?.remaining ?? "updated"}`,
        })
        .eq("id", requestRow.id);
      if (creditedError) throw creditedError;
    }

    console.log("SMS bundle callback processed", {
      business_id: requestRow.business_id,
      credits: requestRow.credits,
      checkout_request_id: checkoutRequestId,
      amount: paidAmount || requestRow.amount,
    });
  } catch (error) {
    console.error("sms-bundle-payment-callback error", error);
  }

  return callbackResponse();
});
