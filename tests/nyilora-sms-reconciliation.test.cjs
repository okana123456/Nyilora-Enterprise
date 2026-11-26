const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');

const projectUrl = 'https://sedzaagjqfsoxglcwyed.supabase.co';
const requestId = '882ab2be-3501-41f7-8249-0b732fdc8048';
const checkoutId = 'checkout-for-existing-paid-request';

async function runCase(resultCode, requestBusiness = 'BIZ-A1C8E7FBD382') {
  let handler;
  const calls = { statusQueries: [], topups: [], updates: [] };
  const source = stripTypeScriptTypes(fs.readFileSync(
    'supabase/functions/reconcile-sms-bundle-payment/index.ts', 'utf8'))
    .replace(/^import .*;\r?\n/gm, '');
  const admin = {
    auth: { getUser: async () => ({ data: { user: { id: 'admin-auth' } }, error: null }) },
    from(table) {
      const query = {
        select: () => query, eq: () => query,
        update: value => { calls.updates.push({ table, value }); return query; },
        maybeSingle: async () => ({ data: table === 'loan_staff'
          ? { business_id: 'BIZ-A1C8E7FBD382', role: 'admin', is_active: true }
          : table === 'nyilora_sms_bundle_requests' && requestBusiness === 'BIZ-A1C8E7FBD382'
            ? { id: requestId, business_id: requestBusiness, status: 'pending',
              credits: 100, amount: 55, checkout_request_id: checkoutId }
            : null, error: null }),
        then: (resolve, reject) => Promise.resolve({ error: null }).then(resolve, reject),
      };
      return query;
    },
    rpc: async (name, args) => {
      calls.topups.push({ name, args });
      return { data: { remaining: 100 }, error: null };
    },
  };
  vm.runInNewContext(source, {
    serve: fn => { handler = fn; }, createClient: () => admin,
    Deno: { env: { get: name => ({
      SUPABASE_URL: projectUrl, SUPABASE_SERVICE_ROLE_KEY: 'test-service-key',
      SERVICE_SHORTCODE: '600123', SERVICE_CONSUMER_KEY: 'owner-key',
      SERVICE_CONSUMER_SECRET: 'owner-secret', SERVICE_PASSKEY: 'owner-passkey',
      SERVICE_DARAJA_ENVIRONMENT: 'production',
    })[name] } },
    fetch: async (url, options) => {
      if (url.includes('/oauth/')) return new Response(JSON.stringify({ access_token: 'owner-token' }));
      calls.statusQueries.push({ url, payload: JSON.parse(options.body) });
      return new Response(JSON.stringify({ ResultCode: resultCode, ResultDesc: 'Status checked' }));
    },
    Response, Request, URL, AbortSignal, Date, Intl, console, btoa,
  }, { filename: 'reconcile-sms-bundle-payment/index.ts' });
  const response = await handler(new Request(`${projectUrl}/functions/v1/reconcile-sms-bundle-payment`, {
    method: 'POST', headers: { authorization: 'Bearer admin-token' },
    body: JSON.stringify({ request_id: requestId }),
  }));
  return { response: await response.json(), calls };
}

async function main() {
  const pending = await runCase(1032);
  assert.equal(pending.response.credited, false);
  assert.equal(pending.calls.topups.length, 0);

  const paid = await runCase(0);
  assert.equal(paid.response.credited, true);
  assert.equal(paid.calls.statusQueries.length, 1);
  assert.equal(paid.calls.statusQueries[0].payload.BusinessShortCode, 600123);
  assert.equal(paid.calls.statusQueries[0].payload.CheckoutRequestID, checkoutId);
  assert.equal(paid.calls.topups.length, 1);
  assert.equal(paid.calls.topups[0].args.p_customer_reference, checkoutId);
  assert.equal(paid.calls.updates.at(-1).value.status, 'credited');

  const otherBusiness = await runCase(0, 'BIZ-OTHER');
  assert.equal(otherBusiness.response.ok, false);
  assert.equal(otherBusiness.calls.statusQueries.length, 0);
  assert.equal(otherBusiness.calls.topups.length, 0);
  console.log('PASS: Nyilora SMS status check credits only verified own-company payments');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
