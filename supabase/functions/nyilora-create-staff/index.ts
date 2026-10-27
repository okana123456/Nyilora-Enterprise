import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const roles = new Set(["admin", "branch_manager", "loan_officer", "cashier"]);
const permissionNames = [
  "view_accounting", "view_expenses", "initiate_expenses", "approve_expenses",
  "manage_assets", "manage_branches", "transfer_portfolios", "adjust_charges_excess",
];

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status, headers: { ...corsHeaders, "Content-Type": "application/json" },
  });
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "POST") return json({ ok: false, message: "Use POST." }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL") || "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY") || "";
  const token = /^Bearer (.+)$/i.exec(req.headers.get("authorization") || "")?.[1];
  if (!supabaseUrl || !serviceKey) return json({ ok: false, message: "Supabase secrets are missing." }, 500);
  if (!token) return json({ ok: false, message: "Sign in again before creating staff." }, 401);

  const admin = createClient(supabaseUrl, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  let createdAuthId: string | null = null;
  let createdStaffId: string | null = null;
  let businessId: string | null = null;

  try {
    const { data: { user }, error: userError } = await admin.auth.getUser(token);
    if (userError || !user) return json({ ok: false, message: "Your login session has expired. Sign in again." }, 401);

    const { data: actor, error: actorError } = await admin.from("loan_staff")
      .select("id, business_id, role, is_active")
      .eq("auth_user_id", user.id).maybeSingle();
    if (actorError) throw actorError;
    if (!actor?.is_active || !String(actor.role || "").split(",").map((r: string) => r.trim()).includes("admin")) {
      return json({ ok: false, message: "Only an active Nyilora administrator can create staff." }, 403);
    }
    businessId = actor.business_id;

    const body = await req.json();
    const name = String(body.name || "").trim();
    const email = String(body.email || "").trim().toLowerCase();
    const phone = String(body.phone || "").trim() || null;
    const branchId = String(body.branch_id || "").trim();
    const selectedRoles = String(body.role || "").split(",").map((r: string) => r.trim()).filter(Boolean);
    if (!name || name.length > 160 || !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) || !branchId ||
        !selectedRoles.length ||
        selectedRoles.some((r: string) => !roles.has(r)) || new Set(selectedRoles).size !== selectedRoles.length) {
      return json({ ok: false, message: "Enter a name, valid email, assigned branch and valid roles." }, 400);
    }

    const { data: branch, error: branchError } = await admin.from("nyilora_branches")
      .select("id").eq("id", branchId).eq("business_id", businessId).eq("is_active", true).maybeSingle();
    if (branchError) throw branchError;
    if (!branch) return json({ ok: false, message: "Choose an active Nyilora branch." }, 400);

    const { data: existingStaff, error: existingError } = await admin.from("loan_staff")
      .select("id").eq("business_id", businessId).ilike("email", email).limit(1);
    if (existingError) throw existingError;
    if (existingStaff?.length) return json({ ok: false, message: "This email already has a Nyilora staff record. Edit that record or send a password reset link." }, 409);

    // Supabase Auth sends this invitation and confirms the address when opened.
    // The invited staff member then sets their own password in the app.
    const { data: authData, error: createError } = await admin.auth.admin.inviteUserByEmail(email, {
      data: { full_name: name },
      redirectTo: "https://nyilora-enterprise-v1.vercel.app/?nyilora_invite=1",
    });
    if (createError || !authData?.user?.id) {
      if (/already|registered|exists/i.test(createError?.message || "")) {
        return json({ ok: false, message: "This email already has a login. No staff record or password was changed. Check the existing account before retrying." }, 409);
      }
      throw createError || new Error("Could not create the login.");
    }
    createdAuthId = authData.user.id;

    const { data: staff, error: staffError } = await admin.from("loan_staff").insert({
      business_id: businessId, auth_user_id: createdAuthId, name, email, phone,
      role: selectedRoles.join(","), is_active: body.is_active !== false, branch_id: branch.id,
    }).select("id").single();
    if (staffError) throw staffError;
    createdStaffId = staff.id;

    const permissions: Record<string, unknown> = {
      staff_id: staff.id, business_id: businessId, branch_id: branch.id,
      updated_by: actor.id, updated_at: new Date().toISOString(),
    };
    for (const key of permissionNames) permissions[key] = body.permissions?.[key] === true;
    const { error: permissionError } = await admin.from("nyilora_staff_permissions").upsert(permissions, { onConflict: "staff_id" });
    if (permissionError) throw permissionError;

    return json({ ok: true, staff_id: staff.id, message: "Staff invitation sent. The recipient must confirm the email and set a password." });
  } catch (error) {
    // A failed staff insert must not leave a new login that cannot sign in.
    let cleanupError: string | null = null;
    if (createdStaffId) {
      const removed = await admin.from("loan_staff").delete().eq("id", createdStaffId).eq("business_id", businessId);
      if (removed.error) cleanupError = `Staff rollback failed: ${removed.error.message}`;
    }
    if (createdAuthId && !cleanupError) {
      const removed = await admin.auth.admin.deleteUser(createdAuthId);
      if (removed.error) cleanupError = `Login rollback failed: ${removed.error.message}`;
    }
    console.error("nyilora-create-staff failed", error);
    if (cleanupError) console.error("nyilora-create-staff cleanup failed", cleanupError);
    return json({ ok: false, message: cleanupError
      ? `Staff creation needs administrator review. ${cleanupError}. Do not retry this email yet.`
      : error instanceof Error ? error.message : "Could not create staff." }, 500);
  }
});
