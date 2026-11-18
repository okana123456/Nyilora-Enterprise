const assert = require('node:assert/strict');
const fs = require('node:fs');
const vm = require('node:vm');

const html = fs.readFileSync('index.html', 'utf8');
const start = html.indexOf('function arrearsLoansForOfficer(');
const end = html.indexOf('function applyArrearsFilters(', start);
assert.ok(start > 0 && end > start);
const context = vm.createContext({ canonicalLoanOfficerId: id => id });
vm.runInContext(html.slice(start, end), context);
const loans = [
  { id: 'a', loan_officer_id: 'officer-a', branch_id: 'head' },
  { id: 'b', loan_officer_id: 'officer-b', branch_id: 'head' },
];
assert.deepEqual(Array.from(context.arrearsLoansForOfficer(loans, 'officer-a'), l => l.id), ['a']);
assert.deepEqual(Array.from(context.arrearsLoansForOfficer(loans, ''), l => l.id), ['a', 'b']);
assert.match(html, /officerExportTag\(snap\).*fileLabel/);
console.log('PASS: staff arrears and dues are filtered before display and named exports');
