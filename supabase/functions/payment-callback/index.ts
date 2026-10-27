import { serve } from "https://deno.land/std@0.168.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.38.4";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, x-client-info, apikey, content-type",
};

function digitsOnly(value: unknown) {
  return String(value || "").replace(/\D/g, "");
}

function mpesaDate(value: unknown) {
  const s = String(value || "").trim();
  if (/^\d{14}$/.test(s)) {
    return `${s.slice(0, 4)}-${s.slice(4, 6)}-${s.slice(6, 8)}T${s.slice(8, 10)}:${s.slice(10, 12)}:${s.slice(12, 14)}`;
  }
  const d = new Date();
  return `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}T${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}:${String(d.getSeconds()).padStart(2, "0")}`;
}

function billingMonthFromPaymentDate(paymentDate: string) {
  return `${String(paymentDate || "").slice(0, 7)}-01`;
}

function nextPaidUntil(billingMonth: string) {
  const month = String(billingMonth || "").slice(0, 10);
  const d = new Date(`${month}T00:00:00Z`);
  d.setUTCMonth(d.getUTCMonth() + 1);
  d.setUTCDate(4);
  return d.toISOString().slice(0, 10);
}

function subscriptionAccountRef(businessId: string) {
  return `NYILORA${String(businessId).replace(/[^a-z0-9]/gi, "").slice(-6).toUpperCase()}`.slice(0, 12);
}

function subscriptionAmount(month: string, businessId: string) {
  return businessId && String(month).slice(0, 10) >= "2026-12-01" ? 3000 : 0;
}

function compactAccount(value: unknown) {
  return String(value || "").replace(/[^a-z0-9]/gi, "").toUpperCase();
}

async function sendRepaymentSms(supabaseUrl: string, serviceKey: string, repaymentId: string | null | undefined) {
  if (!repaymentId) return;
  try {
    const response = await fetch(`${supabaseUrl}/functions/v1/send-repayment-sms`, {
      method: "POST",
      headers: {
        Authorization: `Bearer ${serviceKey}`,
        apikey: serviceKey,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ repayment_id: repaymentId }),
      signal: AbortSignal.timeout(25000),
    });
    if (!response.ok) console.error("Repayment SMS request failed", response.status, await response.text());
  } catch (error) {
    // Payment processing is already complete. Keep the SMS queued for retry.
    console.error("Could not request repayment SMS", repaymentId, error);
  }
}

serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }

  const accepted = new Response(JSON.stringify({ ResultCode: 0, ResultDesc: "Accepted" }), {
    headers: { ...corsHeaders, "Content-Type": "application/json" },
    status: 200,
  });

  try {
    const body = await req.json();
    const transId = body?.TransID;
    if (!transId) return accepted;

    const shortcode = String(body?.BusinessShortCode || "").trim();
    const accountNumber = String(body?.BillRefNumber || "").trim();
    const amount = Number(body?.TransAmount || 0);
    const payerPhone = String(body?.MSISDN || "").trim();
    const payerName = `${body?.FirstName || ""} ${body?.MiddleName || ""} ${body?.LastName || ""}`.replace(/\s+/g, " ").trim();
    let paymentDate = mpesaDate(body?.TransTime);

    if (!shortcode || !amount || amount <= 0) return accepted;

    const supabaseUrl = Deno.env.get("SUPABASE_URL") ?? "";
    const supabaseKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") ?? "";
    const supabase = createClient(supabaseUrl, supabaseKey);

    const { data: allSettingsRows } = await supabase
      .from("loan_settings")
      .select("business_id, mpesa_auto_confirm, mpesa_shortcode");

    const shortcodeDigits = digitsOnly(shortcode);
    const settingsRows = (allSettingsRows || []).filter((row) =>
      digitsOnly(row.mpesa_shortcode) === shortcodeDigits
    );

    const configuredBusinesses = [...new Set((settingsRows || [])
      .map((row) => String(row.business_id || "").trim())
      .filter(Boolean))];
    if (configuredBusinesses.length !== 1) {
      const { error: unroutedError } = await supabase.from("nyilora_unrouted_callbacks").upsert({
        trans_id: transId, shortcode, account_reference: accountNumber, amount,
        raw_payload: body, reason: configuredBusinesses.length ? "ambiguous_paybill" : "unknown_paybill",
      }, { onConflict: "trans_id" });
      if (unroutedError) throw unroutedError;
      return accepted;
    }
    let businessId = configuredBusinesses.length === 1 ? configuredBusinesses[0] : null;
    let autoConfirm = configuredBusinesses.length === 1 && !!settingsRows?.[0]?.mpesa_auto_confirm;
    if (businessId) {
      paymentDate = /^\d{14}$/.test(String(body?.TransTime || ""))
        ? `${paymentDate}+03:00`
        : new Date().toISOString();
    }

    const { data: existingRepayment } = await supabase
      .from("loan_repayments")
      .select("id, loan_id, business_id")
      .or(`payment_reference.eq.${transId},receipt_no.eq.${transId}`)
      .limit(1)
      .maybeSingle();

    if (existingRepayment) {
      return accepted;
    }

    const subscriptionCandidates = configuredBusinesses;
    const subscriptionBusinessId = subscriptionCandidates.find((candidateBusiness) =>
      compactAccount(accountNumber) === compactAccount(subscriptionAccountRef(candidateBusiness))
    );
    const directBillingMonth = billingMonthFromPaymentDate(paymentDate);
    if (subscriptionBusinessId && subscriptionAmount(directBillingMonth, subscriptionBusinessId) > 0
        && amount >= subscriptionAmount(directBillingMonth, subscriptionBusinessId)) {
      const billingMonth = directBillingMonth;
      const paidUntil = nextPaidUntil(billingMonth);
      const { error: billingError } = await supabase
        .from("loan_billing_cycles")
        .upsert({
          business_id: subscriptionBusinessId,
          billing_month: billingMonth,
          amount: 3000,
          actual_amount: amount,
          status: "paid",
          paid_at: paymentDate,
          paid_until: paidUntil,
          receipt_number: transId,
          phone: payerPhone || null,
        }, { onConflict: "business_id,billing_month" });
      if (billingError) throw billingError;

      return accepted;
    }

    let client: { id: string; business_id: string; full_name: string | null; account_credit?: number | null } | null = null;
    // Nyilora uses the borrower's registered PHONE in the Paybill account field.
    // The sender phone is never used to infer the borrower. Short references,
    // shared phone numbers and explicitly held payments remain in suspense.
    let clientLookupError: unknown = null;
    const accountDigits = digitsOnly(accountNumber);
    if (accountDigits.length >= 5 && accountDigits.length <= 12) {
      const accountMatches: Array<{ id: string; business_id: string; full_name: string | null; account_credit?: number | null }> = [];
      for (const candidateBusiness of configuredBusinesses) {
        const { data, error } = await supabase.rpc("nyilora_callback_phone_candidates", {
          p_business_id: candidateBusiness,
          p_account_reference: accountNumber,
          p_transaction_code: transId,
        });
        if (error) clientLookupError = error;
        for (const row of data || []) accountMatches.push(row);
      }
      const uniqueMatches = [...new Map(accountMatches.map((row) => [row.id, row])).values()];
      if (uniqueMatches.length === 1) client = uniqueMatches[0];
    }

    if (client) {
      businessId = client.business_id;
      autoConfirm = !!(settingsRows || []).find((row) => row.business_id === businessId)?.mpesa_auto_confirm;
    }

    const { data: businessBranch, error: branchError } = businessId
      ? await supabase.from("nyilora_branches").select("id")
        .eq("business_id", businessId).eq("is_head_office", true).maybeSingle()
      : { data: null, error: null };
    if (branchError) throw branchError;
    if (businessId && !businessBranch) throw new Error("Payment business has no Head Office branch");

    // Reuse saved callbacks on provider retries, including payments held for review.
    const { data: previousQueue, error: previousQueueError } = businessId
      ? await supabase
        .from("mpesa_callback_queue")
        .select("id,confirmed")
        .eq("business_id", businessId)
        .eq("trans_id", transId)
        .limit(1)
        .maybeSingle()
      : { data: null, error: null };
    if (previousQueueError) throw previousQueueError;
    if (previousQueue?.confirmed) return accepted;
    const { data: queue, error: queueError } = previousQueue
      ? { data: previousQueue, error: null }
      : await supabase
      .from("mpesa_callback_queue")
      .insert({
        transaction_type: body?.TransactionType || "C2B",
        trans_id: transId,
        trans_time: body?.TransTime,
        trans_amount: amount,
        business_id: businessId,
        branch_id: businessBranch?.id,
        business_short_code: shortcode,
        bill_ref_number: accountNumber,
        msisdn: payerPhone,
        first_name: body?.FirstName || "",
        middle_name: body?.MiddleName || "",
        last_name: body?.LastName || "",
        raw_payload: body,
        confirmed: false,
        dismissed: false,
      })
      .select("id")
      .maybeSingle();

    let queueId = queue?.id;
    if (queueError) {
      console.error("Could not store M-Pesa callback in queue", transId, queueError);
      // Daraja may retry an existing callback. Reuse its queue row rather
      // than creating a second suspense record for the same transaction.
      const { data: existingQueue, error: queueLookupError } = await supabase
        .from("mpesa_callback_queue")
        .select("id")
        .eq("trans_id", transId)
        .limit(1)
        .maybeSingle();
      if (queueLookupError) console.error("Could not look up M-Pesa callback", transId, queueLookupError);
      queueId = existingQueue?.id;
    }
    if (clientLookupError) {
      // Persist the callback first so a temporary lookup/deployment failure
      // cannot discard a received payment.
      throw clientLookupError;
    }

    if (!client || !businessId) {
      if (!businessId) {
        console.error("Could not identify the Nyilora business for payment", transId, shortcode, payerPhone);
        return accepted;
      }
      // The queue is the live M-Pesa suspense register. Store a fallback only
      // if queue persistence failed; writing both would double its UI total.
      if (!queueId) {
        const { error: unmatchedError } = await supabase.from("unmatched_payments").insert({
          amount,
          account_number: accountNumber,
          business_id: businessId,
          branch_id: businessBranch?.id,
          mpesa_reference: transId,
          payer_phone: payerPhone,
          payer_name: payerName,
          raw_payload: body,
          resolved: false,
        });
        if (unmatchedError) throw unmatchedError;
      }
      return accepted;
    }

    const { data: loan } = await supabase
      .from("loans")
      .select("id, loan_no, client_id, outstanding_balance, total_paid, total_payable, total_interest, status, business_id, registration_fee_due, registration_fee_paid, processing_fee, processing_fee_paid")
      .eq("business_id", businessId)
      .eq("client_id", client.id)
      .eq("status", "active")
      .gt("outstanding_balance", 0)
      .order("created_at", { ascending: false })
      .limit(1)
      .maybeSingle();

    if (!loan) {
      const { data: pendingCharge } = await supabase
        .from("nyilora_charges")
        .select("id, loan_id, amount, amount_paid, charge_type, status")
        .eq("business_id", businessId)
        .eq("client_id", client.id)
        .eq("charge_type", "processing_fee")
        .in("status", ["pending", "partially_paid"])
        .order("charge_date", { ascending: true })
        .limit(1)
        .maybeSingle();

      if (pendingCharge?.loan_id && autoConfirm) {
        const { data: feeResult, error: feeError } = await supabase.rpc("nyilora_record_callback_charge_payment", {
          p_business_id: businessId,
          p_client_id: client.id,
          p_loan_id: pendingCharge.loan_id,
          p_charge_id: pendingCharge.id,
          p_amount: amount,
          p_payment_reference: transId,
          p_payment_date: paymentDate,
          p_payer_name: payerName,
          p_payer_phone: payerPhone,
        });
        if (feeError) throw feeError;
        if (queueId) {
          await supabase
            .from("mpesa_callback_queue")
            .update({
              confirmed: true,
              loan_id: pendingCharge.loan_id,
              repayment_id: feeResult?.repayment_id || null,
              business_short_code: shortcode,
            })
            .eq("id", queueId);
        }
        await sendRepaymentSms(supabaseUrl, supabaseKey, feeResult?.repayment_id);
        return accepted;
      }

      if (!queueId) {
        const { error: unmatchedError } = await supabase.from("unmatched_payments").insert({
          amount,
          account_number: accountNumber,
          business_id: businessId,
          branch_id: businessBranch?.id,
          mpesa_reference: transId,
          payer_phone: payerPhone,
          payer_name: payerName,
          raw_payload: body,
          resolved: false,
        });
        if (unmatchedError) throw unmatchedError;
      }
      return accepted;
    }
    if (!autoConfirm) {
      if (queueId) {
        await supabase
          .from("mpesa_callback_queue")
          .update({ business_short_code: shortcode, loan_id: loan.id })
          .eq("id", queueId);
      }
      return accepted;
    }

    // Every payment made using the client's registered phone reduces the loan
    // in full. Registration and processing fees are never diverted here.
    const registrationFeePortion = 0;
    const processingFeePortion = 0;
    const currentBalance = Math.max(0, Number(loan.outstanding_balance || 0));
    const loanPortion = Number(Math.min(amount, currentBalance).toFixed(2));
    const creditPortion = Number(Math.max(0, amount - loanPortion).toFixed(2));
    const totalPayable = Number(loan.total_payable || 0);
    const totalInterest = Number(loan.total_interest || 0);
    const interestRatio = totalPayable > 0 && totalInterest > 0 ? totalInterest / totalPayable : 0;
    const interestPortion = Number((loanPortion * interestRatio).toFixed(2));
    const principalPortion = Number((loanPortion - interestPortion).toFixed(2));
    const receiptNo = transId;
    const allocationNote = [
      loanPortion > 0 ? `loan KES ${loanPortion.toFixed(2)}` : "",
      creditPortion > 0 ? `excess KES ${creditPortion.toFixed(2)}` : "",
    ].filter(Boolean).join(", ");

    const { data: repayment, error: repErr } = await supabase
      .from("loan_repayments")
      .insert({
        amount,
        business_id: businessId,
        branch_id: businessBranch?.id,
        loan_id: loan.id,
        payment_method: "M-Pesa",
        payment_reference: transId,
        receipt_no: receiptNo,
        mpesa_confirmed: true,
        payment_date: paymentDate,
        sender_name: payerName,
        sender_phone: payerPhone,
        interest_portion: interestPortion,
        principal_portion: principalPortion,
        penalty_portion: 0,
        registration_fee_portion: registrationFeePortion,
        processing_fee_portion: processingFeePortion,
        loan_portion: loanPortion,
        credit_portion: creditPortion,
        notes: `Auto-confirmed via Daraja C2B. Matched by borrower phone account. Allocation: ${allocationNote || "none"}. Payer: ${payerName}`,
      })
      .select("id")
      .single();

    if (repErr) throw repErr;

    const { data: schedules } = await supabase
      .from("loan_schedules")
      .select("id, due_date, total_due, total_paid, status")
      .eq("loan_id", loan.id)
      .in("status", ["pending", "partial", "overdue"])
      .order("due_date", { ascending: true });

    let remaining = loanPortion;
    const today = new Date().toISOString().slice(0, 10);
    for (const sched of schedules || []) {
      if (remaining <= 0) break;
      const due = Number(sched.total_due || 0);
      const paid = Number(sched.total_paid || 0);
      const owed = Math.max(0, due - paid);
      if (owed <= 0) continue;

      const apply = Math.min(remaining, owed);
      const newPaid = Number((paid + apply).toFixed(2));
      const newStatus = newPaid >= due ? "paid" : (sched.due_date < today ? "overdue" : "partial");

      await supabase
        .from("loan_schedules")
        .update({
          total_paid: newPaid,
          status: newStatus,
          paid_at: newStatus === "paid" ? paymentDate : null,
        })
        .eq("id", sched.id);

      remaining = Number((remaining - apply).toFixed(2));
    }

    const { data: overdueScheds } = await supabase
      .from("loan_schedules")
      .select("total_due, total_paid, due_date, status")
      .eq("loan_id", loan.id)
      .lt("due_date", today)
      .neq("status", "paid");

    let arrears = 0;
    let oldestDueDate: string | null = null;
    for (const s of overdueScheds || []) {
      const unpaid = Math.max(0, Number(s.total_due || 0) - Number(s.total_paid || 0));
      if (unpaid > 0.01) {
        arrears += unpaid;
        if (!oldestDueDate || s.due_date < oldestDueDate) oldestDueDate = s.due_date;
      }
    }

    const overdueDays = oldestDueDate
      ? Math.max(0, Math.floor((Date.now() - new Date(oldestDueDate).getTime()) / 86400000))
      : 0;
    const newTotalPaid = Number((Number(loan.total_paid || 0) + loanPortion).toFixed(2));
    const newBalance = Math.max(0, Number((Number(loan.outstanding_balance || 0) - loanPortion).toFixed(2)));

    await supabase
      .from("loans")
      .update({
        total_paid: newTotalPaid,
        outstanding_balance: newBalance,
        status: newBalance <= 0 ? "completed" : loan.status,
        arrears_amount: newBalance <= 0 ? 0 : Number(Math.min(newBalance, arrears).toFixed(2)),
        overdue_days: newBalance <= 0 ? 0 : overdueDays,
      })
      .eq("id", loan.id);

    if (queueId) {
      await supabase
        .from("mpesa_callback_queue")
        .update({
          confirmed: true,
          loan_id: loan.id,
          repayment_id: repayment.id,
          business_short_code: shortcode,
        })
        .eq("id", queueId);
    }

    await sendRepaymentSms(supabaseUrl, supabaseKey, repayment.id);

    return accepted;
  } catch (error) {
    console.error("Webhook System Error:", error);
    return accepted;
  }
});
