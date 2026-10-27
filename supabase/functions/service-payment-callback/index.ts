import { createClient } from "https://esm.sh/@supabase/supabase-js@2";
const NYILORA_BUSINESS_ID = Deno.env.get('NYILORA_BUSINESS_ID')?.trim() || '';

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

function nextPaidUntil(billingMonth: string) {
  const month = String(billingMonth || "").slice(0, 10);
  const d = new Date(`${month}T00:00:00Z`);
  d.setUTCMonth(d.getUTCMonth() + 1);
  d.setUTCDate(4);
  return d.toISOString().slice(0, 10);
}

function billingAmount(month: string, businessId: string) {
  return businessId === NYILORA_BUSINESS_ID && String(month).slice(0, 10) >= "2026-12-01" ? 3000 : 0;
}

function metaValue(items: Array<{ Name?: string; Value?: unknown }>, name: string) {
  return items?.find((item) => item.Name === name)?.Value ?? null;
}

Deno.serve(async (req) => {
  if (req.method !== "POST") return callbackResponse();

  try {
    const supabaseUrl = requireEnv("SUPABASE_URL");
    const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || Deno.env.get("SERVICE_ROLE_KEY");
    if (!serviceKey) throw new Error("Missing secret: SUPABASE_SERVICE_ROLE_KEY");

    const admin = createClient(supabaseUrl, serviceKey, {
      auth: { persistSession: false, autoRefreshToken: false },
    });
    const payload = await req.json().catch(() => ({}));
    const stk = payload?.Body?.stkCallback;
    const checkoutRequestId = String(stk?.CheckoutRequestID || "").trim();
    if (!checkoutRequestId) {
      console.error("Subscription callback ignored: CheckoutRequestID is missing", payload);
      return callbackResponse();
    }

    const resultCode = String(stk?.ResultCode ?? "");
    const resultDescription = String(stk?.ResultDesc || "");
    const items = stk?.CallbackMetadata?.Item || [];
    const receipt = metaValue(items, "MpesaReceiptNumber");
    const phone = metaValue(items, "PhoneNumber");
    const paidAmount = Number(metaValue(items, "Amount") || 0);
    let paid = resultCode === "0";

    // start-service-payment creates this row directly, so it is the primary
    // source of truth. The former callback incorrectly required a separate
    // transaction row and silently ignored successful payments.
    let { data: cycle, error: cycleError } = await admin
      .from("loan_billing_cycles")
      .select("id,business_id,billing_month,amount,phone,status")
      .eq("checkout_request_id", checkoutRequestId)
      .maybeSingle();

    let transaction: { id: string; cycle_id?: string | null } | null = null;
    const transactionResult = await admin
      .from("loan_billing_transactions")
      .select("id,cycle_id")
      .eq("checkout_request_id", checkoutRequestId)
      .maybeSingle();
    if (!transactionResult.error) transaction = transactionResult.data;

    // Compatibility fallback for any older request that used a transaction
    // row but did not save the checkout number on its cycle.
    if (!cycle && transaction?.cycle_id) {
      const fallback = await admin
        .from("loan_billing_cycles")
        .select("id,business_id,billing_month,amount,phone,status")
        .eq("id", transaction.cycle_id)
        .maybeSingle();
      cycle = fallback.data;
      cycleError = fallback.error;
    }

    if (cycleError) throw cycleError;
    if (!cycle) {
      console.error("Subscription callback could not find its billing cycle", {
        checkout_request_id: checkoutRequestId,
        result_code: resultCode,
        receipt,
      });
      return callbackResponse();
    }

    const requiredAmount = billingAmount(cycle.billing_month, cycle.business_id);
    if (!requiredAmount) return callbackResponse();
    if (paid && paidAmount < requiredAmount) {
      paid = false;
      console.error("Subscription callback amount below required billing amount", { paidAmount, requiredAmount, billing_month: cycle.billing_month });
    }

    const cycleUpdate: Record<string, unknown> = {
      status: paid ? "paid" : "failed",
      paid_at: paid ? new Date().toISOString() : null,
      paid_until: paid ? nextPaidUntil(cycle.billing_month) : null,
      receipt_number: receipt ? String(receipt) : null,
      phone: phone ? String(phone) : cycle.phone,
      amount: cycle.amount,
      actual_amount: paid ? paidAmount : null,
      result_description: resultDescription,
    };
    const { error: updateError } = await admin
      .from("loan_billing_cycles")
      .update(cycleUpdate)
      .eq("id", cycle.id);
    if (updateError) throw updateError;

    if (transaction?.id) {
      const transactionUpdate = await admin
        .from("loan_billing_transactions")
        .update({
          result_code: resultCode,
          result_description: resultDescription,
          receipt_number: receipt ? String(receipt) : null,
          raw_payload: payload,
          status: paid ? "paid" : "failed",
        })
        .eq("id", transaction.id);
      if (transactionUpdate.error) {
        console.error("Billing cycle updated, but transaction audit update failed", transactionUpdate.error);
      }
    }

    console.log("Subscription callback processed", {
      business_id: cycle.business_id,
      billing_month: cycle.billing_month,
      checkout_request_id: checkoutRequestId,
      paid,
      receipt,
      amount: paidAmount || cycle.amount,
    });
  } catch (error) {
    console.error("service-payment-callback error", error);
  }

  return callbackResponse();
});
