const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');

function loadFunction(path, environment, createClient, fetchImpl) {
  const source = stripTypeScriptTypes(fs.readFileSync(path, 'utf8'))
    .replace(/^import .*;\r?\n/gm, '');
  let handler;
  vm.runInNewContext(source, {
    serve: fn => { handler = fn; }, createClient,
    Deno: { env: { get: name => environment[name] } },
    fetch: fetchImpl, Response, URL, AbortSignal, btoa, console,
  }, { filename: path });
  return handler;
}

function tableResult(row) {
  const query = {
    select: () => query,
    eq: () => query,
    maybeSingle: async () => ({ data: row, error: null }),
  };
  return query;
}

async function main() {
  const projectUrl = 'https://sedzaagjqfsoxglcwyed.supabase.co';
  const callbackToken = 'very-long-random-private-token-for-testing-12345';
  const environment = {
    SUPABASE_URL: projectUrl,
    SUPABASE_SERVICE_ROLE_KEY: 'test-only-service-key',
  };
  const rpcCalls = [];
  const createClient = () => ({
    auth: { getUser: async () => ({ data: { user: { id: 'auth-user' } }, error: null }) },
    from: table => tableResult(table === 'loan_staff'
      ? { id: 'staff', business_id: 'BIZ-A1C8E7FBD382', role: 'admin', is_active: true }
      : { mpesa_shortcode: '654321', daraja_environment: 'production' }),
    rpc: async (name, parameters) => {
      rpcCalls.push({ name, parameters });
      if (name === 'nyilora_get_c2b_credentials') return { data: {
        consumer_key: 'test-key', consumer_secret: 'test-secret', callback_token: callbackToken,
      }, error: null };
      if (name === 'nyilora_get_c2b_callback_token') return { data: callbackToken, error: null };
      if (name === 'nyilora_c2b_credentials_saved') return { data: true, error: null };
      return { data: null, error: null };
    },
  });

  const settings = loadFunction('supabase/functions/nyilora-c2b-settings/index.ts',
    environment, createClient, () => { throw new Error('No outbound call expected'); });
  const status = await settings(new Request(`${projectUrl}/functions/v1/nyilora-c2b-settings`, {
    method: 'POST', headers: { authorization: 'Bearer test-user-token' },
    body: JSON.stringify({ action: 'status' }),
  }));
  assert.deepEqual(await status.json(), { ok: true, credentials_saved: true });
  const save = await settings(new Request(`${projectUrl}/functions/v1/nyilora-c2b-settings`, {
    method: 'POST', headers: { authorization: 'Bearer test-user-token' },
    body: JSON.stringify({ action: 'save', consumer_key: 'test-key', consumer_secret: 'test-secret' }),
  }));
  assert.equal(save.status, 200);
  assert.ok(!JSON.stringify(await save.json()).includes('test-secret'));
  assert.equal(rpcCalls.find(call => call.name === 'nyilora_set_c2b_credentials').parameters.p_business_id,
    'BIZ-A1C8E7FBD382');
  const callsBeforeDenial = rpcCalls.length;
  const officerSettings = loadFunction('supabase/functions/nyilora-c2b-settings/index.ts',
    environment, () => ({
      auth: { getUser: async () => ({ data: { user: { id: 'officer-auth' } }, error: null }) },
      from: () => tableResult({ business_id: 'BIZ-A1C8E7FBD382', role: 'loan_officer', is_active: true }),
      rpc: () => { throw new Error('Officer must not reach credential RPC'); },
    }), () => { throw new Error('No outbound call expected'); });
  const deniedSave = await officerSettings(new Request(`${projectUrl}/functions/v1/nyilora-c2b-settings`, {
    method: 'POST', headers: { authorization: 'Bearer officer-token' },
    body: JSON.stringify({ action: 'save', consumer_key: 'test-key', consumer_secret: 'test-secret' }),
  }));
  assert.equal(deniedSave.status, 403);
  assert.equal(rpcCalls.length, callsBeforeDenial);

  const requests = [];
  const fetchImpl = async (url, options) => {
    requests.push({ url, options });
    return new Response(JSON.stringify(requests.length === 1
      ? { access_token: 'temporary-test-token' }
      : { ConversationID: 'test-conversation' }), { status: 200 });
  };
  const register = loadFunction('supabase/functions/nyilora-register-c2b/index.ts',
    environment, createClient, fetchImpl);
  const result = await register(new Request(`${projectUrl}/functions/v1/nyilora-register-c2b`, {
    method: 'POST', headers: { authorization: 'Bearer test-user-token' },
  }));
  assert.equal(result.status, 200);
  assert.equal((await result.json()).ok, true);
  assert.equal(requests.length, 2);
  const payload = JSON.parse(requests[1].options.body);
  assert.equal(payload.ShortCode, '654321');
  assert.equal(new URL(payload.ConfirmationURL).host, 'sedzaagjqfsoxglcwyed.supabase.co');
  assert.equal(new URL(payload.ConfirmationURL).searchParams.get('token'), callbackToken);
  assert.equal(new URL(payload.ValidationURL).searchParams.get('validation'), '1');
  assert.ok(!JSON.stringify(payload).includes('test-secret'));

  const callback = loadFunction('supabase/functions/payment-callback/index.ts',
    environment, createClient, () => { throw new Error('No outbound call expected'); });
  const denied = await callback(new Request(`${projectUrl}/functions/v1/payment-callback`, {
    method: 'POST', body: '{}',
  }));
  assert.equal(denied.status, 403);
  const validation = await callback(new Request(
    `${projectUrl}/functions/v1/payment-callback?token=${callbackToken}&validation=1`,
    { method: 'POST', body: '{}' },
  ));
  assert.equal(validation.status, 200);
  assert.equal((await validation.json()).ResultCode, 0);

  const seen = [];
  const callbackClient = () => ({
    rpc: async (name, parameters) => {
      seen.push({ name, parameters });
      if (name === 'nyilora_get_c2b_callback_token') return { data: callbackToken, error: null };
      if (name === 'nyilora_callback_id_candidates') return {
        data: [{ id: 'client-1', business_id: 'BIZ-A1C8E7FBD382', full_name: 'Test borrower' }],
        error: null,
      };
      throw new Error(`Unexpected RPC ${name}`);
    },
    from: table => {
      const query = {
        select: () => query, eq: () => query, or: () => query, limit: () => query,
        order: () => query, gt: () => query, update: () => query, insert: () => query,
        maybeSingle: async () => ({
          data: table === 'nyilora_branches' ? { id: 'head-office' }
            : table === 'mpesa_callback_queue' ? { id: 'queue-1' } : null,
          error: null,
        }),
        then: (resolve, reject) => Promise.resolve({
          data: table === 'loan_settings'
            ? [{ business_id: 'BIZ-A1C8E7FBD382', mpesa_shortcode: '654321', mpesa_auto_confirm: false }]
            : table === 'loans'
              ? [{ id: 'loan-1', client_id: 'client-1', business_id: 'BIZ-A1C8E7FBD382', status: 'active' }]
              : null,
          error: null,
        }).then(resolve, reject),
      };
      return query;
    },
  });
  const liveCallback = loadFunction('supabase/functions/payment-callback/index.ts',
    environment, callbackClient, () => { throw new Error('No outbound call expected'); });
  const payment = await liveCallback(new Request(
    `${projectUrl}/functions/v1/payment-callback?token=${callbackToken}`,
    { method: 'POST', body: JSON.stringify({
      TransID: 'TESTTX123', BusinessShortCode: '654321', BillRefNumber: '12345678',
      TransAmount: '100', MSISDN: '254700999888', TransTime: '20261126120000',
    }) },
  ));
  assert.equal(payment.status, 200);
  const idMatch = seen.find(call => call.name === 'nyilora_callback_id_candidates');
  assert.equal(idMatch.parameters.p_account_reference, '12345678');
  assert.equal(idMatch.parameters.p_business_id, 'BIZ-A1C8E7FBD382');
  assert.notEqual(idMatch.parameters.p_account_reference, '254700999888');

  const callbackSource = fs.readFileSync('supabase/functions/payment-callback/index.ts', 'utf8');
  assert.match(callbackSource, /nyilora_callback_id_candidates/);
  assert.doesNotMatch(callbackSource, /nyilora_callback_phone_candidates/);
  const sql = fs.readFileSync('supabase/migrations/0038_nyilora_c2b_vault_and_id_matching.sql', 'utf8');
  assert.match(sql, /c\.business_id = p_business_id/);
  assert.match(sql, /c\.id_number/);
  assert.match(sql, /to service_role/);
  console.log('PASS: Nyilora admin credential storage, callback registration, token check and ID matching boundary');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
