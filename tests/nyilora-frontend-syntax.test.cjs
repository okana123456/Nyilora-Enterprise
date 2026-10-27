const fs = require('node:fs');
const vm = require('node:vm');
const html = fs.readFileSync('index.html', 'utf8');
const inline = [...html.matchAll(/<script(?:\s[^>]*)?>([\s\S]*?)<\/script>/g)]
  .map(match => match[1]).filter(Boolean);
for (const code of inline) new vm.Script(code);
for (const name of ['nyilora-client-documents.js', 'nyilora-financial-statements.js', 'nyilora-reporting.js']) {
  new vm.Script(fs.readFileSync(name, 'utf8'), { filename: name });
}
console.log(`PASS: ${inline.length} inline scripts and support JavaScript parse`);
