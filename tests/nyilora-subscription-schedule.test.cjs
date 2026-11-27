const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const vm=require('node:vm');

const root=path.resolve(__dirname,'..');
const html=fs.readFileSync(path.join(root,'index.html'),'utf8');
const config=fs.readFileSync(path.join(root,'config.js'),'utf8');
const payment=fs.readFileSync(path.join(root,'supabase','functions','start-service-payment','index.ts'),'utf8');
const slice=(start,end)=>html.slice(html.indexOf(start),html.indexOf(end,html.indexOf(start)));
assert.match(config,/billingStartDate: '2026-12-01'/);
assert.match(config,/subscriptionAmountKes: 3000/);
assert.match(html,/const SERVICE_BILLING_REMINDER_DAY = 1;/);
assert.match(html,/const SERVICE_BILLING_LOCK_DAY = 4;/);
assert.match(payment,/timeZone: "Africa\/Nairobi"/);
assert.match(payment,/billingMonth\(\) < "2026-12-01"/);

const context=vm.createContext({Date,Intl,
  SERVICE_BILLING_FIRST_REMINDER_DATE:'2026-12-01',SERVICE_BILLING_LOCK_DAY:4});
vm.runInContext(slice('function kenyaDateISO(','function shiftISODate(')+
  slice('function serviceBillingMonth(','function serviceBillingCacheKey('),context);
assert.equal(context.serviceBillingMonth(new Date('2026-11-30T20:59:59Z')),'2026-11-01');
assert.equal(context.serviceBillingMonth(new Date('2026-11-30T21:00:00Z')),'2026-12-01');
assert.equal(context.kenyaDateISO(new Date('2026-11-30T21:00:00Z')),'2026-12-01');
console.log('PASS: Nyilora December 1 Kenya-time subscription start, reminder day, lock day, and Daraja timestamp');
