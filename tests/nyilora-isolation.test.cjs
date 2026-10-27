const assert=require('node:assert/strict');
const fs=require('node:fs');
const path=require('node:path');
const root=path.resolve(__dirname,'..');
function walk(dir){
  return fs.readdirSync(dir,{withFileTypes:true}).flatMap(e=>e.isDirectory()?walk(path.join(dir,e.name)):[path.join(dir,e.name)]);
}
const files=walk(root).filter(f=>!f.includes(`${path.sep}.git${path.sep}`));
for(const file of files){
  if(!/\.(html|js|ts)$/.test(file)||file.includes(`${path.sep}tests${path.sep}`))continue;
  const source=fs.readFileSync(file,'utf8');
  assert.doesNotMatch(source,/nngscmpsxtqqjzcnsrbi|BIZ-B3F5E5D9|sb_publishable_3Zbo|4044341|PATAFIX|BRIPTA|Bripta|bripta/i,file);
}
const html=fs.readFileSync(path.join(root,'index.html'),'utf8');
assert.match(html,/Nyilora Enterprise/);
assert.match(html,/Project setup is pending/);
assert.match(html,/nyilora-create-staff/);
assert.match(html,/functions\.invoke\('nyilora-bootstrap-admin'/);
assert.match(html,/Create Business Account/);
assert.match(html,/signUpCompanyName/);
assert.doesNotMatch(html,/\.auth\.signUp\(/);
assert.doesNotMatch(html,/\+ Add Branch/);
const config=fs.readFileSync(path.join(root,'config.js'),'utf8');
assert.match(config,/subscriptionAmountKes: 3000/);
assert.match(config,/billingStartDate: '2026-12-01'/);
assert.match(config,/smsPriceKes: 0\.55/);
assert.match(config,/https:\/\/sedzaagjqfsoxglcwyed\.supabase\.co/);
assert.doesNotMatch(config,/service_role\s*:|serviceRole\s*:|consumerSecret\s*:/i);
assert.doesNotMatch(config,/NYILORA_ADMIN_SETUP_KEY|adminSetupKey/i);
const bootstrap=fs.readFileSync(path.join(root,'supabase/functions/nyilora-bootstrap-admin/index.ts'),'utf8');
assert.match(bootstrap,/NYILORA_ADMIN_SETUP_KEY/);
assert.match(bootstrap,/nyilora_register_business_admin/);
assert.match(bootstrap,/company_name/);
console.log('PASS: Nyilora branding, isolated configuration, multi-business signup, agreed prices and start date.');
