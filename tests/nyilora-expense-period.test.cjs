const {readFileSync}=require('node:fs');
const vm=require('node:vm');
const assert=require('node:assert/strict');
const html=readFileSync(require('node:path').join(__dirname,'..','index.html'),'utf8');
const pick=(start,end)=>html.slice(html.indexOf(start),html.indexOf(end,html.indexOf(start)));
const rows=Array.from({length:26},(_,i)=>({id:`id-${i}`,expense_no:`EXP-${i+1}`,
  expense_date:'2026-11-27',branch_id:'branch',category:'fuel',description:'Fuel',
  amount:10,status:i===0?'pending':'approved',nyilora_branches:{name:'Migori'}}));
const calls=[];const main={innerHTML:''};
const context=vm.createContext({Date,Intl,appFilters:{expenses:{type:'this_month',start:'',end:''}},
  kenyaDateISO:()=> '2026-11-27',shiftISODate:(date,days)=>new Date(Date.parse(date+'T00:00:00Z')+days*86400000).toISOString().slice(0,10),
  $:()=>main,hasPermission:()=>true,hasRole:()=>false,selectedBranchId:null,
  currentUser:{business_id:'BIZ-NYILORA'},escapeHtml:String,branchName:()=> 'Migori',
  fmtDate:String,fmtMoney:n=>`KES ${n}`,statusBadge:String,
  getDateFilterHtml:()=>'<period-filter>',paginationHtml:()=>'<pages>',toast:message=>{throw Error(message)},
  paginate:(items,page,size=25)=>({items:items.slice((page-1)*size,page*size),page,total:Math.ceil(items.length/size),count:items.length}),
  fetchPagedBusinessRows:async(table,configure)=>{
    const filters=[];const query={gte:(...args)=>{filters.push(['gte',...args]);return query},
      lte:(...args)=>{filters.push(['lte',...args]);return query},
      order:(...args)=>{filters.push(['order',...args]);return query}};
    configure(query);calls.push({table,filters});return {data:rows,error:null};
  }});
vm.runInContext(pick('function expenseDateBounds(','function kenyaDateISO(')+
  pick('async function renderExpenses(','function expenseCategories('),context);
assert.deepEqual(Array.from(context.expenseDateBounds({type:'this_week'})),['2026-11-23','2026-11-27']);
assert.deepEqual(Array.from(context.expenseDateBounds({type:'this_month'})),['2026-11-01','2026-11-27']);
(async()=>{
  await context.renderExpenses(2);
  assert.equal(calls[0].table,'nyilora_expenses');
  assert.ok(calls[0].filters.some(x=>x[0]==='gte'&&x[1]==='expense_date'&&x[2]==='2026-11-01'));
  assert.ok(calls[0].filters.some(x=>x[0]==='lte'&&x[1]==='expense_date'&&x[2]==='2026-11-27'));
  assert.ok(main.innerHTML.includes('KES 250'));
  assert.ok(main.innerHTML.includes('EXP-26'));
  assert.ok(!main.innerHTML.includes('EXP-1</td>'));
  context.appFilters.expenses={type:'custom',start:'2026-11-10',end:'2026-11-12'};
  await context.renderExpenses(1);
  assert.ok(calls[1].filters.some(x=>x[0]==='gte'&&x[2]==='2026-11-10'));
  assert.ok(calls[1].filters.some(x=>x[0]==='lte'&&x[2]==='2026-11-12'));
  console.log('PASS Nyilora expense periods, totals, and paging');
})().catch(error=>{console.error(error);process.exitCode=1});

