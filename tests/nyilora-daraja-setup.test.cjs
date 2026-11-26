const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');
const { stripTypeScriptTypes } = require('node:module');

function loadFunction(path, environment, createClient, fetchImpl) {
  const source = stripTypeScriptTypes(fs.readFileSync(path, 'utf8'))
    .replace(/^import .*;\r?\n/gm, '');
  let handler;
  const context = {
    serve: fn => { handler = fn; }, createClient,
    Deno: { env: { get: name => environment[name] } },
    fetch: fetchImpl, Response, URL, AbortSignal, btoa, console,
  };
  vm.runInNewContext(source, context, { filename: path });
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
    NYILORA_C2B_CALLBACK_TOKEN: callbackToken,
    NYILORA_C2B_CONSUMER_KEY__A1C8E7FBD382: 'test-key',
    NYILORA_C2B_CONSUMER_SECRET__A1C8E7FBD382: 'test-secret',
  };
  const requests = [];
  const fetchImpl = async (url, options) => {
    requests.push({ url, options });
    return new Response(JSON.stringify(requests.length === 1
      ? { access_token: 'temporary-test-token' }
      : { ConversationID: 'test-conversation' }), { status: 200 });
  };
  const createClient = () => ({
    auth: { getUser: async () => ({ data: { user: { id: 'auth-user' } }, error: null }) },
    from: table => tableResult(table === 'loan_staff'
      ? { id: 'staff', business_id: 'BIZ-A1C8E7FBD382', role: 'admin', is_active: true }
      : { mpesa_shortcode: '654321', daraja_environment: 'production' }),
  });
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
    environment, () => { throw new Error('Unauthorized request touched database'); },
    () => { throw new Error('Unauthorized request touched network'); });
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
  console.log('PASS: Nyilora callback registration and private-token boundary');
}

main().catch(error => { console.error(error); process.exitCode = 1; });
