const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { createHmac, webcrypto } = require('node:crypto');
const { stripTypeScriptTypes } = require('node:module');

const serviceKey = 'test-only-service-key';
const projectUrl = 'https://sedzaagjqfsoxglcwyed.supabase.co';
const requestId = 'request-123';
const checkoutId = 'checkout-123';

function loadFunction(path, createClient, fetchImpl = () => { throw new Error('Unexpected network call'); }) {
  const source = stripTypeScriptTypes(fs.readFileSync(path, 'utf8'))
    .replace(/^import .*;\r?\n/gm, '');
  let handler;
  vm.runInNewContext(source, {
    Deno: { serve: fn => { handler = fn; }, env: { get: name => ({
      SUPABASE_URL: projectUrl, SUPABASE_SERVICE_ROLE_KEY: serviceKey,
      NYILORA_SMS_API_TOKEN__A1C8E7FBD382: 'test-only-talksasa-token',
      NYILORA_SMS_SENDER_ID__A1C8E7FBD382: 'NYILORA',
      NYILORA_SMS_SEND_URL__A1C8E7FBD382: 'https://bulksms.talksasa.com/api/v3/',
      NYILORA_SMS_TEST_PIN: 'test-only-pin',
      SERVICE_SHORTCODE: '600123', SERVICE_CONSUMER_KEY: 'owner-key',
      SERVICE_CONSUMER_SECRET: 'owner-secret', SERVICE_PASSKEY: 'owner-passkey',
      SERVICE_DARAJA_ENVIRONMENT: 'production',
    })[name] } },
    serve: fn => { handler = fn; }, createClient, fetch: fetchImpl,
    crypto: webcrypto, TextEncoder, Uint8Array, Response, URL, Request,
    AbortSignal, Date, Intl, console, btoa,
  }, { filename: path });
  return handler;
}

function fakeAdmin(amount, calls) {
  return {
    from(table) {
      const query = {
        select: () => query, eq: () => query, update: value => {
          calls.updates.push({ table, value });
          return query;
        },
        maybeSingle: async () => ({ data: {
          id: requestId, business_id: 'BIZ-A1C8E7FBD382', credits: 100,
          amount, phone: '254700000001', status: 'pending',
        }, error: null }),
        then: (resolve, reject) => Promise.resolve({ error: null }).then(resolve, reject),
      };
      return query;
    },
    rpc: async (name, args) => {
      calls.topups.push({ name, args });
      return { data: { remaining: 100 }, error: null };
    },
  };
}

async function callbackCase({ signed, amount, paidAmount, receipt }) {
  const calls = { updates: [], topups: [] };
  const handler = loadFunction('supabase/functions/sms-bundle-payment-callback/index.ts',
    () => fakeAdmin(amount, calls));
  const url = new URL(`${projectUrl}/functions/v1/sms-bundle-payment-callback`);
  url.searchParams.set('request', requestId);
  url.searchParams.set('signature', signed
    ? createHmac('sha256', serviceKey).update(requestId).digest('hex')
    : '0'.repeat(64));
  const result = await handler(new Request(url, { method: 'POST', body: JSON.stringify({
    Body: { stkCallback: { CheckoutRequestID: checkoutId, ResultCode: 0,
      CallbackMetadata: { Item: [
        { Name: 'Amount', Value: paidAmount },
        { Name: 'MpesaReceiptNumber', Value: receipt },
      ] },
    } },
  }) }));
  return { result, calls };
}

async function main() {
  const invalid = await callbackCase({ signed: false, amount: 55, paidAmount: 55, receipt: 'TEST123' });
  assert.equal(invalid.result.status, 403);
  assert.equal(invalid.calls.topups.length, 0);

  const underpaid = await callbackCase({ signed: true, amount: 55, paidAmount: 1, receipt: 'TEST123' });
  assert.equal(underpaid.result.status, 200);
  assert.equal(underpaid.calls.topups.length, 0);
  assert.equal(underpaid.calls.updates.at(-1).value.status, 'review');

  const paid = await callbackCase({ signed: true, amount: 55, paidAmount: 55, receipt: 'TEST123' });
  assert.equal(paid.result.status, 200);
  assert.equal(paid.calls.topups.length, 1);
  assert.equal(paid.calls.topups[0].args.p_business_id, 'BIZ-A1C8E7FBD382');
  assert.equal(paid.calls.updates.at(-1).value.status, 'credited');

  let stkPayload;
  const starterAdmin = {
    auth: { getUser: async () => ({ data: { user: { id: 'admin-auth' } }, error: null }) },
    from(table) {
      const query = {
        select: () => query, eq: () => query, update: () => query,
        insert: () => query,
        maybeSingle: async () => ({ data: table === 'loan_staff'
          ? { id: 'staff-1', business_id: 'BIZ-A1C8E7FBD382', branch_id: 'branch-1', role: 'admin', is_active: true }
          : { mpesa_shortcode: '1471039' }, error: null }),
        single: async () => ({ data: { id: requestId }, error: null }),
        then: (resolve, reject) => Promise.resolve({ error: null }).then(resolve, reject),
      };
      return query;
    },
  };
  const startPayment = loadFunction('supabase/functions/start-sms-bundle-payment/index.ts',
    () => starterAdmin, async (url, options) => {
      if (url.includes('/oauth/')) return new Response(JSON.stringify({ access_token: 'owner-oauth' }));
      stkPayload = JSON.parse(options.body);
      return new Response(JSON.stringify({ ResponseCode: '0', MerchantRequestID: 'merchant-1',
        CheckoutRequestID: checkoutId, ResponseDescription: 'Accepted' }));
    });
  const startResult = await startPayment(new Request(`${projectUrl}/functions/v1/start-sms-bundle-payment`, {
    method: 'POST', headers: { authorization: 'Bearer admin-token' },
    body: JSON.stringify({ credits: 100, phone: '0700000001' }),
  }));
  assert.equal((await startResult.json()).ok, true);
  assert.equal(stkPayload.BusinessShortCode, 600123);
  assert.equal(stkPayload.PartyB, 600123);
  assert.equal(stkPayload.Amount, 55);
  const callbackUrl = new URL(stkPayload.CallBackURL);
  assert.equal(callbackUrl.searchParams.get('request'), requestId);
  assert.equal(callbackUrl.searchParams.get('signature'),
    createHmac('sha256', serviceKey).update(requestId).digest('hex'));

  const sender = fs.readFileSync('supabase/functions/send-repayment-sms/index.ts', 'utf8');
  assert.match(sender, /https:\/\/bulksms\.talksasa\.com\/api\/v3\/sms\/send/);
  assert.match(sender, /const senderId = config\.sender/);
  let smsCall;
  const send = loadFunction('supabase/functions/send-repayment-sms/index.ts',
    () => { throw new Error('Direct SMS test must not access the database'); },
    async (url, options) => {
      smsCall = { url, options };
      return new Response(JSON.stringify({ status: 'success', data: { uid: 'test-uid' } }), { status: 200 });
    });
  const smsResult = await send(new Request(`${projectUrl}/functions/v1/send-repayment-sms`, {
    method: 'POST', headers: { 'x-test-pin': 'test-only-pin' },
    body: JSON.stringify({ direct_test_phone: '0700000001', business_id: 'BIZ-A1C8E7FBD382' }),
  }));
  assert.equal((await smsResult.json()).ok, true);
  assert.equal(smsCall.url, 'https://bulksms.talksasa.com/api/v3/sms/send');
  assert.equal(JSON.parse(smsCall.options.body).sender_id, 'NYILORA');
  const start = fs.readFileSync('supabase/functions/start-sms-bundle-payment/index.ts', 'utf8');
  assert.match(start, /env\("SERVICE_SHORTCODE"\)/);
  assert.match(start, /callbackSignature\(serviceKey, requestRow\.id\)/);
  console.log('PASS: Nyilora SMS purchase callback authentication and credit amount checks');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
