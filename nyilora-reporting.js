// Read-only reporting calculations. Never changes a loan, schedule or repayment.
(function(root){
  const n=v=>Math.max(0,Number(v)||0);
  const cents=v=>Math.round(n(v)*100);
  const unique=rows=>[...new Map(rows.map(r=>[r.id,r])).values()];
  const clientKey=l=>l.client_id||`loan:${l.id}`;
  function allocatedSchedules(loans,schedules,repayments,asOf,dateOf){
    const byLoan=new Map(),byRep=new Map(),reviewLoanIds=[];
    for(const s of unique(schedules)){if(!/^\d{4}-\d{2}-\d{2}$/.test(s.due_date||''))continue;
      if(!byLoan.has(s.loan_id))byLoan.set(s.loan_id,[]);byLoan.get(s.loan_id).push(s);}
    for(const r of unique(repayments)){if(!byRep.has(r.loan_id))byRep.set(r.loan_id,[]);byRep.get(r.loan_id).push(r);}
    const output=[];
    for(const l of loans){
      const ss=(byLoan.get(l.id)||[]).sort((a,b)=>a.due_date.localeCompare(b.due_date)||n(a.installment_no)-n(b.installment_no)||String(a.id).localeCompare(String(b.id)));
      const reps=byRep.get(l.id)||[];
      const portion=r=>cents(r.loan_portion==null?Math.max(0,n(r.amount)-n(r.penalty_portion)-n(r.registration_fee_portion)-n(r.processing_fee_portion)-n(r.credit_portion)):r.loan_portion);
      const ledger=reps.reduce((a,r)=>a+portion(r),0);
      const future=reps.filter(r=>dateOf(r)>asOf).reduce((a,r)=>a+portion(r),0);
      const scheduled=ss.reduce((a,s)=>a+cents(s.total_due),0);
      const healthy=Math.abs(scheduled-cents(l.total_payable))<=1;
      if(!healthy)reviewLoanIds.push(l.id);
      // Missing cascade updates are reconciled for intact schedules using the
      // same oldest-instalment-first allocation as payment processing.
      let remaining=Math.max(0,Math.max(cents(l.total_paid),ledger)-future);
      if(healthy){for(const s of ss){const paid=Math.min(cents(s.total_due),remaining);remaining-=paid;output.push({...s,total_paid:paid/100});}}
      else {
        // Preserve observed allocations for malformed/restructured history.
        // Reverse subsequent collections for an earlier cutoff, latest first.
        let reverse=future;const adjusted=[];
        for(const s of [...ss].reverse()){let paid=Math.min(cents(s.total_due),cents(s.total_paid));const take=Math.min(paid,reverse);paid-=take;reverse-=take;adjusted.push({...s,total_paid:paid/100});}
        output.push(...adjusted.reverse());
      }
    }
    return {schedules:output,reviewLoanIds};
  }
  function periodCollection(schedules,include,asOf){
    const arrived=schedules.filter(s=>s.due_date<=asOf&&include(s));
    const due=arrived.reduce((a,s)=>a+cents(s.total_due),0);
    const paid=arrived.reduce((a,s)=>a+Math.min(cents(s.total_due),cents(s.total_paid)),0);
    return {due:due/100,paid:paid/100,unpaid:(due-paid)/100,rate:due?paid/due*100:0,arrived};
  }
  function portfolioQuality(loans,schedules,asOf){
    const byLoan=new Map();for(const s of unique(schedules)){if(!byLoan.has(s.loan_id))byLoan.set(s.loan_id,[]);byLoan.get(s.loan_id).push(s);}
    const active=unique(loans).filter(l=>l.status==='active'&&n(l.outstanding_balance)>.01).map(l=>{
      const ss=byLoan.get(l.id)||[],valid=ss.filter(s=>/^\d{4}-\d{2}-\d{2}$/.test(s.due_date||''));
      const due=valid.filter(s=>s.due_date<asOf&&n(s.total_due)-n(s.total_paid)>.01);
      const irregular=ss.length!==valid.length||!ss.length||Math.abs(ss.reduce((a,s)=>a+n(s.total_due),0)-n(l.total_payable))>.01
        ||Math.abs(ss.reduce((a,s)=>a+n(s.total_paid),0)-n(l.total_paid))>.01;
      const amount=Math.min(n(l.outstanding_balance),irregular?n(l.arrears_amount):due.reduce((a,s)=>a+Math.max(0,n(s.total_due)-n(s.total_paid)),0));
      const oldest=due.map(s=>s.due_date).sort()[0];
      const days=amount<=.01?0:irregular?n(l.overdue_days):oldest?Math.max(1,Math.round((Date.parse(asOf+'T00:00:00Z')-Date.parse(oldest+'T00:00:00Z'))/86400000)):0;
      return {...l,_current_arrears:Math.round(amount*100)/100,_current_overdue_days:days};
    });
    return qualityTotals(active);
  }
  function qualityTotals(active){
    active=unique(active);const overdue=active.filter(l=>n(l._current_arrears)>.01);
    const clients=new Set(active.map(clientKey)).size,arrearsClients=new Set(overdue.map(clientKey)).size;
    const outstanding=active.reduce((a,l)=>a+n(l.outstanding_balance),0),arrears=overdue.reduce((a,l)=>a+n(l._current_arrears),0);
    return {active,overdue,clients,arrearsClients,outstanding,arrears,bq:clients?(clients-arrearsClients)/clients*100:100,par:outstanding?arrears/outstanding*100:0};
  }
  function dueClients(schedules,loans){
    const lm=new Map(loans.map(l=>[l.id,l])),groups=new Map();
    for(const s of unique(schedules)){const l=lm.get(s.loan_id);if(!l||l.status!=='active'||n(l.outstanding_balance)<=.01)continue;
      const due=n(s.total_due),paid=Math.min(due,n(s.total_paid)),remaining=Math.max(0,due-paid);
      const key=clientKey(l);if(!groups.has(key))groups.set(key,{name:l.loan_clients?.full_name||'-',phone:l.loan_clients?.phone||'-',total_due:0,paid:0,remaining:0,arrears:0,loan_balance:0,loans:new Map(),installments:[]});
      const row=groups.get(key);row.total_due+=due;row.paid+=paid;row.remaining+=remaining;row.installments.push(s.installment_no);
      if(!row.loans.has(l.id)){row.loans.set(l.id,l);row.arrears+=Math.min(n(l.outstanding_balance),n(l.arrears_amount));row.loan_balance+=n(l.outstanding_balance);}
    }
    return [...groups.values()].map(r=>({...r,loans:[...r.loans.values()]})).sort((a,b)=>b.remaining-a.remaining);
  }
  function actorName(log,staff){if(!log.user_id)return 'System';const found=staff.filter(s=>s.id===log.user_id||s.auth_user_id===log.user_id);
    const names=[...new Set(found.map(s=>String(s.name||'').trim()).filter(Boolean))];return names.length===1?names[0]:log.user_id?'Former or unknown staff':'System';}
  const api={allocatedSchedules,periodCollection,portfolioQuality,qualityTotals,dueClients,actorName};
  if(typeof module!=='undefined')module.exports=api;root.NyiloraReporting=api;
})(typeof globalThis!=='undefined'?globalThis:this);
