// Source-based P&L and cumulative recorded journal balance sheet. Read-only.
async function readAccountingPenalties(start,end){
  const rows=[];let after=null;
  try{
    for(let page=0;page<200;page++){
      const{data,error}=await supabaseClient.rpc('nyilora_accounting_penalties',{p_start:start,p_end:end,p_branch:selectedBranchId||null,p_after:after});
      if(error)throw error;
      if(!Array.isArray(data?.rows))throw new Error('Penalty records could not be verified');
      rows.push(...data.rows);
      if(!data.next_after)return {data:rows,error:null};
      if(data.next_after===after)throw new Error('Could not load the next penalty page');
      after=data.next_after;
    }
    throw new Error('Too many penalty records to load completely');
  }catch(error){return {data:null,error};}
}
let accountingPenaltyRows=[];
const ACCOUNTING_PENALTY_PAGE_SIZE=10;
function accountingPenaltyPageHtml(page=1){
  const count=accountingPenaltyRows.length,total=Math.max(1,Math.ceil(count/ACCOUNTING_PENALTY_PAGE_SIZE));
  page=Math.min(total,Math.max(1,Math.floor(Number(page)||1)));
  const offset=(page-1)*ACCOUNTING_PENALTY_PAGE_SIZE;
  const rows=accountingPenaltyRows.slice(offset,offset+ACCOUNTING_PENALTY_PAGE_SIZE);
  return `<div class="table-wrap" style="max-height:360px;overflow:auto"><table><thead><tr><th>Date charged</th><th>Client</th><th>Loan</th><th>Amount charged</th><th>Status</th><th>Reason</th></tr></thead><tbody>
    ${rows.map(p=>`<tr><td>${escapeHtml(p.charged_on||'Date not recorded')}</td><td>${escapeHtml(p.client_name||'-')}</td><td>${escapeHtml(p.loan_no||'-')}</td><td style="white-space:nowrap">${fmtMoney(p.penalty_amount)}</td><td>${p.is_waived?'Waived':'Applied'}</td><td>${escapeHtml(p.reason||'Rollover Penalty')}</td></tr>`).join('')||'<tr><td colspan="6" style="padding:16px;text-align:center">No penalty charges in this period</td></tr>'}
    </tbody></table></div>
    ${count?`<div style="display:flex;align-items:center;justify-content:space-between;flex-wrap:wrap;gap:8px;margin-top:10px">
      <button type="button" class="btn btn-outline btn-sm" ${page<=1?'disabled':''} onclick="showAccountingPenaltyPage(${page-1})">Previous</button>
      <span style="font-size:12px" aria-live="polite">${offset+1}–${Math.min(offset+ACCOUNTING_PENALTY_PAGE_SIZE,count)} of ${count} records · Page ${page} of ${total}</span>
      <button type="button" class="btn btn-outline btn-sm" ${page>=total?'disabled':''} onclick="showAccountingPenaltyPage(${page+1})">Next</button>
    </div>`:''}`;
}
function showAccountingPenaltyPage(page){
  const panel=document.getElementById('accountingPenaltyPage');
  if(panel)panel.innerHTML=accountingPenaltyPageHtml(page);
}
function accountingPenaltyHtml(result){
  accountingPenaltyRows=[];
  if(result.error)return `<div class="card" style="margin-top:20px"><h3>Rollover Penalties Charged</h3><p>Could not load charged penalties: ${escapeHtml(result.error.message)}</p></div>`;
  accountingPenaltyRows=(result.data||[]).slice().sort((a,b)=>String(b.charged_on||'').localeCompare(String(a.charged_on||''))||String(a.id||'').localeCompare(String(b.id||'')));
  const applied=accountingPenaltyRows.filter(p=>!p.is_waived).reduce((sum,p)=>sum+Number(p.penalty_amount||0),0);
  const waived=accountingPenaltyRows.filter(p=>p.is_waived).reduce((sum,p)=>sum+Number(p.penalty_amount||0),0);
  return `<div class="card" style="margin-top:20px"><h3>Rollover Penalties Charged</h3>
    <p style="font-size:12px;color:var(--text-secondary);margin:8px 0">Applied charges: <strong>${fmtMoney(applied)}</strong> · Waived: <strong>${fmtMoney(waived)}</strong></p>
    <details ${accountingPenaltyRows.length<=ACCOUNTING_PENALTY_PAGE_SIZE?'open':''}>
      <summary style="cursor:pointer;font-weight:600;padding:8px 0">View penalty records (${accountingPenaltyRows.length})</summary>
      <p style="font-size:12px;color:var(--text-secondary);margin-bottom:10px">Charges recorded in the selected period and branch. These amounts are already part of the loan balances; only penalties collected through repayments contribute to collected income.</p>
      <div id="accountingPenaltyPage">${accountingPenaltyPageHtml(1)}</div>
    </details></div>`;
}
function nyiloraBalanceSheet(accounts){
  const groups={asset:[],liability:[],equity:[]};let retained=0;
  for(const row of accounts||[]){
    const signed=Number(row.signed_balance||0);
    if(row.account_type==='income'||row.account_type==='expense')retained-=signed;
    else if(groups[row.account_type])groups[row.account_type].push({...row,balance:row.account_type==='asset'?signed:-signed});
  }
  const sum=rows=>rows.reduce((total,row)=>total+row.balance,0);
  const assets=sum(groups.asset),liabilities=sum(groups.liability),capital=sum(groups.equity);
  return {groups,assets,liabilities,capital,retained,equity:capital+retained,difference:assets-liabilities-capital-retained};
}
function nyiloraStatementHtml(report,income){
  if(report.error)return `<div class="card"><h3>Profit &amp; Loss / Balance Sheet</h3><p>Could not load financial statements: ${escapeHtml(report.error.message)}. Reload after installing the financial statements SQL.</p></div>`;
  const expenses=Number(report.approved_expenses||0),net=income.total-expenses;
  const line=(label,value,bold=false)=>`<div style="display:flex;justify-content:space-between;gap:12px;padding:8px 0;${bold?'font-weight:700;border-top:1px solid var(--border)':''}"><span>${escapeHtml(label)}</span><strong style="white-space:nowrap">${fmtMoney(value)}</strong></div>`;
  const sheet=nyiloraBalanceSheet(report.accounts);
  const section=(title,rows,total)=>`<h4 style="margin:14px 0 5px">${title}</h4>${rows.map(row=>line(row.account_name,row.balance)).join('')||'<p>No recorded balances</p>'}${line('Total '+title,total,true)}`;
  const missing=Object.entries(report.missing_source_postings||{}).filter(([,count])=>Number(count)>0);
  const labels={loans:'loan disbursements',repayments:'repayments',approved_expenses:'approved expenses',asset_purchases:'asset purchases'};
  const notes=[];
  if(!report.opening_balances_identified)notes.push('Opening cash, M-Pesa/bank, capital and debt balances have not been identified in the ledger.');
  if(missing.length)notes.push('Source records without journal postings: '+missing.map(([name,count])=>`${count} ${labels[name]||name}`).join(', ')+'.');
  if(Number(report.unbalanced_sources)>0)notes.push(`${report.unbalanced_sources} journal transaction(s) need balancing.`);
  if(Math.abs(sheet.difference)>0.01)notes.push('Assets and liabilities plus equity differ by '+fmtMoney(sheet.difference)+'.');
  const status=notes.length?'Incomplete — review the items below':'Recorded entries reconcile';
  return `<div class="charts-grid" style="margin-top:20px">
    <div class="card"><h3>Profit &amp; Loss</h3><p style="font-size:12px;color:var(--text-secondary)">${escapeHtml(report.period_start)} to ${escapeHtml(report.as_of)} · Collected income less approved expenses</p>
      ${line('Registration fees',income.registration)}${line('Processing fees',income.processing)}${line('Interest collected',income.interest)}${line('Penalties collected',income.penalties)}
      ${line('Total income',income.total,true)}<h4 style="margin-top:14px">Approved expenses</h4>
      ${(report.expense_categories||[]).map(row=>line(row.category,Number(row.amount))).join('')||'<p>No approved expenses in this period</p>'}
      ${line('Total approved expenses',expenses,true)}${line(net>=0?'Net profit':'Net loss',net,true)}
      <p style="font-size:12px;color:var(--text-secondary)">Expenses use their expense date. Draft, pending, rejected and cancelled expenses are excluded. Loan principal movements and owner capital are excluded from profit.</p>
    </div>
    <div class="card"><h3>Balance Sheet</h3><p style="font-size:12px;color:var(--text-secondary)">Recorded ledger balances as of ${escapeHtml(report.as_of)} · Cumulative through this date</p>
      ${section('Assets',sheet.groups.asset,sheet.assets)}${section('Liabilities',sheet.groups.liability,sheet.liabilities)}
      <h4 style="margin:14px 0 5px">Equity</h4>${sheet.groups.equity.map(row=>line(row.account_name,row.balance)).join('')}
      ${line('Retained profit / loss recorded in ledger',sheet.retained)}${line('Total equity',sheet.equity,true)}
      ${line('Total liabilities + equity',sheet.liabilities+sheet.equity,true)}
      <div style="margin-top:12px;padding:12px;border:1px solid var(--border);border-radius:8px"><strong>${status}</strong>
        ${notes.length?`<ul style="margin:8px 0;padding-left:18px;font-size:12px">${notes.map(note=>`<li>${escapeHtml(note)}</li>`).join('')}</ul>`:''}
        <p style="font-size:12px;color:var(--text-secondary);margin-top:6px">This statement uses posted journal entries. Historical income and expenses in the Profit &amp; Loss report can differ from the ledger until missing postings are reviewed. No missing balances are estimated.</p>
      </div>
    </div></div>`;
}
