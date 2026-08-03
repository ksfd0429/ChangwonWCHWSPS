/* ============================================================================
   admin.html — Accommodation panel
   Changwon 2026 WSPS World Championships

   HOW TO INSTALL (3 edits inside admin.html)

   1. Register the sidebar button next to the existing navb(...) calls, e.g.
        navb('inv','초청장',pInv)
      add:
        navb('acc','숙박',pAcc)

   2. Paste everything below into the same <script> block as the other p*()
      section functions.

   3. Nothing else. It uses the existing globals: sbAdmin, stage(), esc(),
      flagTd(), cname(), and the .tbl / .board / .btn classes.

   The accommodation table has RLS ON with NO policies, so anon/authenticated
   have zero direct access — they go through acc_submit / acc_load only. The
   service_role key bypasses RLS, so this panel reads and writes the table
   directly and needs no extra grants.

   Submissions do NOT require a login. `verified` is true only when the form
   was filled from an active portal session, so treat unverified rows as
   self-declared and reconcile the NPC code against the roster.
   ========================================================================== */

var ACC_HOTELS = {
  GMA:'Grand Mercure Ambassador Changwon',
  GCC:'Grand City Hotel Changwon',
  ISQ:'I-Square Hotel Gimhae'
};
var _accRows = [];

/* ------------------------------------------------------------------ fetch -- */
async function accLoad(){
  var r = await sbAdmin.from('accommodation').select('*').order('country',{ascending:true});
  if(r.error){ _accRows = []; return r.error.message; }
  _accRows = r.data || [];
  return null;
}
function accPax(a){ return (a.n_athletes||0) + (a.n_officials||0); }
function accRooms(a){ return (a.rooms_single||0) + (a.rooms_twin||0); }
function accNights(a){
  if(!a.check_in || !a.check_out) return 0;
  return Math.round((new Date(a.check_out) - new Date(a.check_in)) / 864e5);
}
function accHotel(c){ return ACC_HOTELS[c] || c || '—'; }

/* --------------------------------------------------------------- summary --- */
function accDemand(){
  // first-choice demand and worst-case demand (everyone gets 1st choice)
  var d = {};
  Object.keys(ACC_HOTELS).forEach(function(k){
    d[k] = {teams:0, pax:0, single:0, twin:0, rooms:0, roomNights:0};
  });
  _accRows.forEach(function(a){
    var k = a.choice_1; if(!d[k]) return;
    d[k].teams  += 1;
    d[k].pax    += accPax(a);
    d[k].single += (a.rooms_single||0);
    d[k].twin   += (a.rooms_twin||0);
    d[k].rooms      += accRooms(a);
    d[k].roomNights += accNights(a) * accRooms(a);
  });
  return d;
}

/* ------------------------------------------------- cross-check flags ------- */
/* The LOC verifies every submission by contact name + email by hand. These
   flags surface the cases worth looking at first — they are hints, not
   verdicts, and nothing is blocked on them. */
function accFlags(){
  var byEmail={}, byName={}, byTeam={};
  var norm=function(v){ return String(v||'').trim().toLowerCase(); };
  _accRows.forEach(function(a){
    var e=norm(a.contact_email), n=norm(a.contact_name), t=norm(a.country)+'|'+norm(a.team_name);
    if(e){ (byEmail[e]=byEmail[e]||[]).push(a); }
    if(n){ (byName[n]=byName[n]||[]).push(a); }
    if(norm(a.team_name)){ (byTeam[t]=byTeam[t]||[]).push(a); }
  });
  var f={};
  _accRows.forEach(function(a){
    var w=[];
    var e=norm(a.contact_email), n=norm(a.contact_name), t=norm(a.country)+'|'+norm(a.team_name);
    if(e && byEmail[e].length>1){
      var others=byEmail[e].filter(function(x){return x.id!==a.id;});
      var xc=others.some(function(x){ return x.country!==a.country; });
      w.push(xc ? '같은 이메일이 다른 국가에도 사용됨' : '같은 이메일로 복수 신청');
    }
    if(n && byName[n].length>1 && byName[n].some(function(x){return x.country!==a.country;}))
      w.push('같은 담당자명이 다른 국가에도 있음');
    if(byTeam[t] && byTeam[t].length>1) w.push('같은 국가에 동일 팀명 중복');
    if(!a.verified) w.push('로그인 없이 제출 — 국가 자가 신고');
    if(w.length) f[a.id]=w;
  });
  return f;
}

/* ----------------------------------------------------------------- render -- */
async function pAcc(){
  stage('<div class="wrap"><p>불러오는 중…</p></div>');
  var err = await accLoad();
  if(err){ stage('<div class="wrap"><p style="color:#C94A3D">숙박 데이터를 불러오지 못했습니다: '+esc(err)+'</p></div>'); return; }

  var totalTeams = _accRows.length;
  var totalPax   = _accRows.reduce(function(s,a){ return s + accPax(a); }, 0);
  var totalRooms = _accRows.reduce(function(s,a){ return s + accRooms(a); }, 0);
  var pending    = _accRows.filter(function(a){ return (a.status||'pending')==='pending'; }).length;
  var unverified = _accRows.filter(function(a){ return !a.verified; }).length;

  var flags = accFlags();
  var flagged = Object.keys(flags).length;
  var d = accDemand();
  var demandRows = Object.keys(ACC_HOTELS).map(function(k){
    return '<tr>'+
      '<td><b>'+esc(ACC_HOTELS[k])+'</b></td>'+
      '<td class="rvt">'+d[k].teams+'</td>'+
      '<td class="rvt">'+d[k].pax+'</td>'+
      '<td class="rvt">'+d[k].single+'</td>'+
      '<td class="rvt">'+d[k].twin+'</td>'+
      '<td class="rvt"><b>'+d[k].rooms+'</b></td>'+
      '<td class="rvt">'+d[k].roomNights+'</td>'+
    '</tr>';
  }).join('');

  var rows = _accRows.map(function(a){
    var pax=accPax(a);
    var fl = flags[a.id] || [];
    var st = a.status||'pending';
    var stColor = st==='approved' ? '#2E8B57' : st==='allocated' ? '#1B6FA8' : '#E87722';
    return '<tr>'+
      '<td>'+flagTd(a.country)+'</td>'+
      '<td><b>'+esc(a.team_name||'—')+'</b>'+
        (a.verified
          ? ' <span title="submitted from a portal session" style="color:#2E8B57;font-weight:700">✓</span>'
          : ' <span title="self-declared — not signed in" style="color:#E87722;font-weight:700">?</span>')+
        '<br><span style="color:#5B7690;font-size:12px">'+
        esc(a.contact_name||'')+' · '+esc(a.contact_email||'')+'</span>'+
        '<br><a href="accommodation.html?c='+esc(a.edit_code)+'" target="_blank" '+
        'style="font-size:11.5px;font-family:ui-monospace,monospace">'+esc(a.edit_code)+' ↗</a>'+
        (fl.length ? '<br><span style="color:#C94A3D;font-size:11.5px;font-weight:600">⚑ '+
          esc(fl.join(' · '))+'</span>' : '')+'</td>'+
      '<td class="rvt">'+(a.n_athletes||0)+'</td>'+
      '<td class="rvt">'+(a.n_officials||0)+'</td>'+
      '<td class="rvt"><b>'+pax+'</b></td>'+
      '<td class="rvt">'+(a.n_male||0)+' / '+(a.n_female||0)+'</td>'+
      '<td>'+esc(a.check_in||'')+'<br><span style="color:#5B7690;font-size:12px">→ '+
        esc(a.check_out||'')+' ('+accNights(a)+'n)</span></td>'+
      '<td class="rvt">'+(a.rooms_single||0)+' / '+(a.rooms_twin||0)+'</td>'+
      '<td class="rvt"><b>'+accRooms(a)+'</b></td>'+
      '<td style="font-size:12.5px">1. '+esc(accHotel(a.choice_1))+'<br>'+
        '<span style="color:#5B7690">2. '+esc(accHotel(a.choice_2))+'<br>'+
        '3. '+esc(accHotel(a.choice_3))+'</span></td>'+
      '<td>'+(a.allocated_hotel
              ? '<b>'+esc(accHotel(a.allocated_hotel))+'</b>'
              : '<select class="accAlloc" data-id="'+a.id+'" style="min-width:130px">'+
                '<option value="">— 미배정 —</option>'+
                Object.keys(ACC_HOTELS).map(function(k){
                  return '<option value="'+k+'">'+esc(ACC_HOTELS[k])+'</option>'; }).join('')+
                '</select>')+'</td>'+
      '<td><span style="color:'+stColor+';font-weight:700">'+esc(st)+'</span></td>'+
      '<td>'+(st==='approved'
              ? '<button class="btn sec" data-unapprove="'+a.id+'">해제</button>'
              : '<button class="btn g" data-approve="'+a.id+'">승인</button>')+'</td>'+
    '</tr>';
  }).join('');

  var h =
   '<h2>숙박 신청</h2>'+
   '<div class="board" style="margin-bottom:18px">'+
     '<b>'+totalTeams+'</b>팀 · 총 <b>'+totalPax+'</b>명 · 요청 객실 <b>'+totalRooms+'</b> · '+
     '미승인 <b style="color:#E87722">'+pending+'</b> · '+
     '미인증 <b style="color:#E87722">'+unverified+'</b> · '+
     '확인필요 <b style="color:#C94A3D">'+flagged+'</b>'+
     '<button class="btn sec" style="float:right" id="accCsv">CSV 내보내기</button>'+
     '<button class="btn sec" style="float:right;margin-right:8px" id="accReload">새로고침</button>'+
   '</div>'+

   '<h3>1지망 기준 수요</h3>'+
   '<div class="tbl"><table><thead><tr>'+
     '<th>호텔</th><th class="rvt">팀</th><th class="rvt">인원</th>'+
     '<th class="rvt">싱글</th><th class="rvt">트윈</th><th class="rvt">총 객실</th>'+
     '<th class="rvt">room-nights</th>'+
   '</tr></thead><tbody>'+demandRows+'</tbody></table></div>'+
   '<p style="color:#5B7690;font-size:12.5px">1지망만 집계한 최악 수요입니다. '+
     '호텔 수용량을 넘으면 2지망으로 재배정하세요.</p>'+

   '<h3>신청 목록</h3>'+
   '<div class="tbl"><table><thead><tr>'+
     '<th>국가</th><th>팀 / 담당자 / 수정링크</th><th class="rvt">선수</th><th class="rvt">임원</th>'+
     '<th class="rvt">총원</th><th class="rvt">남/여</th><th>체크인 → 아웃</th>'+
     '<th class="rvt">싱글/트윈</th><th class="rvt">객실</th><th>지망</th>'+
     '<th>배정</th><th>상태</th><th></th>'+
   '</tr></thead><tbody>'+(rows || '<tr><td colspan="13">신청 없음</td></tr>')+
   '</tbody></table></div>';

  stage('<div class="wrap">'+h+'</div>');
  accBind();
}

/* ------------------------------------------------------------------ bind --- */
function accBind(){
  var el;
  if((el=document.getElementById('accReload'))) el.onclick = pAcc;
  if((el=document.getElementById('accCsv')))    el.onclick = accCsv;

  document.querySelectorAll('[data-approve]').forEach(function(b){
    b.onclick = async function(){
      var id = b.getAttribute('data-approve');
      var sel = document.querySelector('.accAlloc[data-id="'+id+'"]');
      var hotel = sel ? sel.value : '';
      if(!hotel){ alert('배정 호텔을 먼저 선택하세요.'); return; }
      b.disabled = true;
      var r = await sbAdmin.from('accommodation').update({
        status:'approved',
        allocated_hotel:hotel,
        approved_at:new Date().toISOString().slice(0,19).replace('T',' ')
      }).eq('id', id);
      if(r.error){ alert('승인 실패: '+r.error.message); b.disabled=false; return; }
      pAcc();
    };
  });

  document.querySelectorAll('[data-unapprove]').forEach(function(b){
    b.onclick = async function(){
      if(!confirm('승인을 해제하면 해당 팀이 다시 수정할 수 있습니다. 진행할까요?')) return;
      b.disabled = true;
      var r = await sbAdmin.from('accommodation').update({
        status:'pending', allocated_hotel:'', approved_at:''
      }).eq('id', b.getAttribute('data-unapprove'));
      if(r.error){ alert('해제 실패: '+r.error.message); b.disabled=false; return; }
      pAcc();
    };
  });
}

/* ------------------------------------------------------------------- CSV --- */
function accCsv(){
  var head = ['country','country_name','verified','edit_code',
    'team_name','contact_name','contact_email','n_athletes',
    'n_officials','total_pax','n_male','n_female','check_in','check_out','nights',
    'rooms_single','rooms_twin','rooms_total','choice_1','choice_2','choice_3',
    'allocated_hotel','status','dietary','notes','submitted_at','review_flags'];
  var q = function(v){ return '"'+String(v==null?'':v).replace(/"/g,'""')+'"'; };
  var lines = [head.join(',')];
  _accRows.forEach(function(a){
    lines.push([a.country,a.country_name,a.verified?'yes':'no',a.edit_code,
      a.team_name,a.contact_name,a.contact_email,a.n_athletes,
      a.n_officials,accPax(a),a.n_male,a.n_female,a.check_in,a.check_out,accNights(a),
      a.rooms_single,a.rooms_twin,accRooms(a),a.choice_1,a.choice_2,a.choice_3,
      a.allocated_hotel,a.status,a.dietary,a.notes,a.submitted_at,
      (accFlags()[a.id]||[]).join(' / ')].map(q).join(','));
  });
  // BOM so Excel opens Korean text correctly
  var blob = new Blob(['﻿'+lines.join('\r\n')], {type:'text/csv;charset=utf-8;'});
  var url = URL.createObjectURL(blob);
  var a = document.createElement('a');
  a.href = url; a.download = 'changwon2026_accommodation.csv';
  document.body.appendChild(a); a.click(); document.body.removeChild(a);
  URL.revokeObjectURL(url);
}
