import { serve } from "https://deno.land/std@0.224.0/http/server.ts";
import { createClient } from "https://esm.sh/@supabase/supabase-js@2.45.4";

const BUSINESS_ID = "BIZ-NYILORA";
const PROJECT_HOST = "sedzaagjqfsoxglcwyed.supabase.co";
const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "authorization, apikey, content-type, x-client-info",
  "Access-Control-Allow-Methods": "GET, POST, OPTIONS",
};

function json(body: Record<string, unknown>, status = 200) {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...corsHeaders, "Content-Type": "application/json", "Cache-Control": "no-store" },
  });
}

async function keyMatches(supplied: string, expected: string) {
  const digest = async (value: string) => new Uint8Array(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(value))
  );
  const [left, right] = await Promise.all([digest(supplied), digest(expected)]);
  let difference = 0;
  for (let i = 0; i < left.length; i++) difference |= left[i] ^ right[i];
  return difference === 0 && supplied.length >= 32;
}

serve(async (req) => {
  if (req.method === "OPTIONS") return new Response("ok", { headers: corsHeaders });
  if (req.method !== "GET" && req.method !== "POST") return json({ ok: false, message: "Use GET or POST." }, 405);

  const supabaseUrl = Deno.env.get("SUPABASE_URL")?.trim() || "";
  const serviceKey = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim() || "";
  const setupKey = Deno.env.get("NYILORA_ADMIN_SETUP_KEY")?.trim() || "";
  if (!supabaseUrl || !serviceKey || !setupKey || new URL(supabaseUrl).hostname !== PROJECT_HOST) {
    return json({ ok: false, message: "Nyilora administrator setup is not configured." }, 503);
  }

  const admin = createClient(supabaseUrl, serviceKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  try {
    const { count, error: countError } = await admin.from("loan_staff")
      .select("id", { count: "exact", head: true }).eq("business_id", BUSINESS_ID);
    if (countError) throw countError;
    if (req.method === "GET") return json({ ok: true, available: count === 0 });
    if (count !== 0) return json({ ok: false, message: "First administrator setup is already complete." }, 409);

    const body = await req.json().catch(() => ({}));
    const suppliedKey = String(body.admin_key || "").trim();
    if (!(await keyMatches(suppliedKey, setupKey))) {
      return json({ ok: false, message: "Invalid administrator setup key." }, 403);
    }
    const name = String(body.name || "").trim();
    const email = String(body.email || "").trim().toLowerCase();
    const password = String(body.password || "");
    if (name.length < 2 || name.length > 160 ||
      !/^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(email) ||
      password.length < 12 || password.length > 128) {
      return json({ ok: false, message: "Enter a name, valid email and password of at least 12 characters." }, 400);
    }

    const { data: created, error: authError } = await admin.auth.admin.createUser({
      email, password, email_confirm: true, user_metadata: { full_name: name },
    });
    if (authError || !created?.user?.id) {
      if (/already|registered|exists/i.test(authError?.message || "")) {
        return json({ ok: false, message: "This email already has a login. No administrator was created." }, 409);
      }
      throw authError || new Error("Could not create the administrator login.");
    }

    const authId = created.user.id;
    const { data: claimed, error: claimError } = await admin.rpc("nyilora_claim_first_admin", {
      p_auth_user_id: authId, p_name: name, p_email: email,
    });
    if (claimError || !claimed?.ok) {
      // A network interruption can occur after the database committed. Check
      // before deleting the login so an administrator is never orphaned.
      const { data: linked } = await admin.from("loan_staff").select("id")
        .eq("business_id", BUSINESS_ID).eq("auth_user_id", authId).maybeSingle();
      if (linked?.id) return json({ ok: true, message: "Administrator created. Sign in with the new password." });
      const removed = await admin.auth.admin.deleteUser(authId);
      if (removed.error) {
        return json({ ok: false, message: "Setup needs administrator review. Do not retry this email yet." }, 500);
      }
      return json({ ok: false, message: claimError?.message || "Administrator setup was not completed." }, 409);
    }
    return json({ ok: true, message: "Administrator created. Sign in with the new password." });
  } catch (error) {
    console.error("Nyilora administrator setup failed", error);
    return json({ ok: false, message: "Administrator setup failed. Check the function logs." }, 500);
  }
});
