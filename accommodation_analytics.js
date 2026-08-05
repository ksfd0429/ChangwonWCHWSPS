/* ============================================================================
   accommodation_analytics.js
   Changwon 2026 WSPS — shared analysis core

   Loaded by BOTH accommodation_dashboard.html (LOC, service_role) and
   accommodation_mirror.html (partners, share token). Keeping the aggregation
   in one file is the point: the LOC and a hotel must never see different
   numbers for the same question.

   Each page supplies its own data loader and shell; everything below is pure
   computation plus rendering into elements the page provides.
   ========================================================================== */
(function (root) {
'use strict';

/* ------------------------------------------------------------- constants -- */
const HOTELS = [
  { code:'GMA', ko:'그랜드머큐어', name:'Grand Mercure Ambassador Changwon', cv:'--acc' },
  { code:'GCC', ko:'그랜드시티',   name:'Grand City Hotel Changwon',        cv:'--y'   },
  { code:'ISQ', ko:'아이스퀘어',   name:'I-Square Hotel Gimhae',            cv:'--g'   }
];
const WINDOW_OPEN = '2026-09-03', WINDOW_CLOSE = '2026-09-21';

/* --------------------------------------------------------------- helpers -- */
const pax    = a => (a.n_athletes|0) + (a.n_officials|0);
const rooms  = a => (a.rooms_single|0) + (a.rooms_twin|0);
const nights = a => (a.check_in && a.check_out)
  ? Math.max(0, Math.round((new Date(a.check_out) - new Date(a.check_in)) / 864e5)) : 0;
/* once the LOC allocates, that wins over the team's preference */
const bucket = a => a.allocated_hotel || a.choice_1;
const hotelOf = c => HOTELS.find(h => h.code === c);
const hname   = c => { const h = hotelOf(c); return h ? h.ko : (c || '—'); };
const esc = s => String(s ?? '').replace(/[&<>"]/g,
  c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const cvar = v => getComputedStyle(document.documentElement).getPropertyValue(v).trim();
const fmt = n => (n || 0).toLocaleString('ko-KR');

function dateRange(){
  const out = [], d = new Date(WINDOW_OPEN), end = new Date(WINDOW_CLOSE);
  while (d <= end) { out.push(d.toISOString().slice(0,10)); d.setDate(d.getDate()+1); }
  return out;
}

/* ----------------------------------------------------------------- scope -- */
/* "Scope" = how the data is grouped. Every chart and table below honours the
   selected scope, so admin and mirror can slice the same way. */
const SCOPES = [
  { key:'hotel',   label:'호텔 (배정 · 없으면 1지망)', of:a => hname(bucket(a)) },
  { key:'choice1', label:'1지망 호텔',                 of:a => hname(a.choice_1) },
  { key:'country', label:'국가',                       of:a => a.country || '—' },
  { key:'status',  label:'승인 상태',                  of:a => a.status === 'approved' ? '승인' : '미승인' },
  { key:'checkin', label:'체크인 날짜',                of:a => a.check_in || '—' },
  { key:'nights',  label:'숙박 일수',                  of:a => nights(a) + '박' },
  { key:'verified',label:'인증 여부',                  of:a => a.verified ? '포털 인증' : '자가 신고' }
];
const scopeBy = k => SCOPES.find(s => s.key === k) || SCOPES[0];

function aggregate(rows, scopeKey){
  const sc = scopeBy(scopeKey), map = new Map();
  rows.forEach(a => {
    const k = sc.of(a);
    if (!map.has(k)) map.set(k, { key:k, teams:0, pax:0, ath:0, off:0, male:0, female:0,
                                  single:0, twin:0, rooms:0, roomNights:0, countries:new Set() });
    const g = map.get(k);
    g.teams++; g.pax += pax(a); g.ath += a.n_athletes|0; g.off += a.n_officials|0;
    g.male += a.n_male|0; g.female += a.n_female|0;
    g.single += a.rooms_single|0; g.twin += a.rooms_twin|0;
    g.rooms += rooms(a); g.roomNights += nights(a) * rooms(a);
    g.countries.add(a.country);
  });
  return [...map.values()]
    .map(g => ({ ...g, countries: g.countries.size }))
    .sort((x,y) => y.rooms - x.rooms || String(x.key).localeCompare(String(y.key)));
}

/* ------------------------------------------------------------- occupancy -- */
function occupancy(rows){
  const days = dateRange();
  const series = HOTELS.map(h => ({ ...h, vals: days.map(() => 0) }));
  rows.forEach(a => {
    const s = series.find(x => x.code === bucket(a)); if (!s) return;
    days.forEach((d,i) => { if (a.check_in <= d && d < a.check_out) s.vals[i] += rooms(a); });
  });
  const totals = days.map((_,i) => series.reduce((s,x) => s + x.vals[i], 0));
  const peak = Math.max(0, ...totals);
  return { days, series, totals, peak, peakDay: days[totals.indexOf(peak)] || '—' };
}

/* ----------------------------------------------------------- check flags -- */
function crossCheck(rows){
  const n = v => String(v||'').trim().toLowerCase();
  const byMail = {}, byName = {}, byTeam = {};
  rows.forEach(a => {
    if (n(a.contact_email)) (byMail[n(a.contact_email)] ||= []).push(a);
    if (n(a.contact_name))  (byName[n(a.contact_name)]  ||= []).push(a);
    if (n(a.team_name))     (byTeam[n(a.country)+'|'+n(a.team_name)] ||= []).push(a);
  });
  const out = {};
  rows.forEach(a => {
    const w = [];
    const m  = byMail[n(a.contact_email)] || [];
    const nm = byName[n(a.contact_name)]  || [];
    const tm = byTeam[n(a.country)+'|'+n(a.team_name)] || [];
    if (m.length > 1)  w.push(m.some(x => x.country !== a.country) ? '동일 이메일 · 다른 국가' : '동일 이메일 복수 신청');
    if (nm.length > 1 && nm.some(x => x.country !== a.country)) w.push('동일 담당자명 · 다른 국가');
    if (tm.length > 1) w.push('동일 국가 · 동일 팀명');
    if (w.length) out[a.id] = w;
  });
  return out;
}

/* --------------------------------------------------------------- tracker -- */
/* "Unseen" is per-viewer and per-page, kept in localStorage. Opening the
   history marks everything up to now as seen. */
const FIELD_KO = {
  country:'국가', country_name:'국가명', team_name:'팀명', contact_name:'담당자',
  contact_email:'이메일', n_athletes:'선수', n_officials:'임원', n_male:'남성',
  n_female:'여성', check_in:'체크인', check_out:'체크아웃', choice_1:'1지망',
  choice_2:'2지망', choice_3:'3지망', rooms_single:'싱글룸', rooms_twin:'트윈룸',
  dietary:'식이', notes:'요청사항', status:'상태', allocated_hotel:'배정 호텔',
  total_pax:'총원', rooms:'객실'
};
const ACTION_KO = { insert:'신규 신청', update:'수정', delete:'삭제' };

function seenKey(ns){ return 'acc_seen_' + (ns || 'default'); }
function lastSeen(ns){ return localStorage.getItem(seenKey(ns)) || ''; }
function markSeen(ns, iso){ localStorage.setItem(seenKey(ns), iso || new Date().toISOString()); }
function unseen(log, ns){
  const ls = lastSeen(ns);
  if (!ls) return log.length;              // first visit: everything is new
  return log.filter(e => new Date(e.at) > new Date(ls)).length;
}
function describe(entry){
  if (entry.action !== 'update') return ACTION_KO[entry.action] || entry.action;
  const c = entry.changed || {};
  const parts = Object.keys(c).map(k => {
    const v = c[k];
    if (!Array.isArray(v)) return FIELD_KO[k] || k;
    const a = v[0] === null || v[0] === '' ? '(빈값)' : v[0];
    const b = v[1] === null || v[1] === '' ? '(빈값)' : v[1];
    return `${FIELD_KO[k] || k} ${a} → ${b}`;
  });
  return parts.join(', ') || '수정';
}

/* ------------------------------------------------------------- rendering -- */
function svgEl(tag, attrs, txt){
  const e = document.createElementNS('http://www.w3.org/2000/svg', tag);
  for (const k in attrs) e.setAttribute(k, attrs[k]);
  if (txt != null) e.appendChild(document.createTextNode(txt));
  return e;
}
let TIP = null;
function ensureTip(){
  if (TIP) return TIP;
  TIP = document.getElementById('tip');
  if (!TIP) { TIP = document.createElement('div'); TIP.id = 'tip'; document.body.appendChild(TIP); }
  return TIP;
}
function tipShow(ev, title, list){
  const t = ensureTip(); t.innerHTML = '';
  const h = document.createElement('div'); h.className = 'th'; h.textContent = title; t.appendChild(h);
  list.forEach(r => {
    const d = document.createElement('div'); d.className = 'tr';
    const k = document.createElement('span'); k.className = 'tk';
    if (r.color) { const i = document.createElement('i'); i.style.background = r.color; k.appendChild(i); }
    k.appendChild(document.createTextNode(r.label));
    const v = document.createElement('span'); v.className = 'tv'; v.textContent = r.value;
    d.appendChild(k); d.appendChild(v); t.appendChild(d);
  });
  t.style.display = 'block';
  const pad = 14, w = t.offsetWidth, h2 = t.offsetHeight;
  let x = ev.clientX + pad, y = ev.clientY + pad;
  if (x + w > innerWidth - 8)  x = ev.clientX - w - pad;
  if (y + h2 > innerHeight - 8) y = ev.clientY - h2 - pad;
  t.style.left = x + 'px'; t.style.top = y + 'px';
}
function tipHide(){ if (TIP) TIP.style.display = 'none'; }
document.addEventListener('scroll', tipHide, true);

/* stacked occupancy bars */
function drawOccupancy(host, legendHost, tableHost, rows){
  const { days, series, totals, peak, peakDay } = occupancy(rows);
  const max = Math.max(1, peak);
  const W = 880, H = 280, L = 44, R = 10, T = 16, B = 34;
  const iw = W-L-R, ih = H-T-B, cw = iw/days.length, bw = Math.max(6, cw-6);
  const x = i => L + cw*i + (cw-bw)/2, y = v => T + ih - (v/max)*ih;
  const s = svgEl('svg', { viewBox:`0 0 ${W} ${H}`, role:'img' });
  s.appendChild(svgEl('title', {}, '날짜별 객실 점유'));
  for (let g=0; g<=4; g++){
    const v = max*g/4, yy = y(v);
    s.appendChild(svgEl('line', { x1:L, x2:W-R, y1:yy, y2:yy, class:'gl' }));
    s.appendChild(svgEl('text', { x:L-7, y:yy+4, 'text-anchor':'end', class:'ax' }, Math.round(v)));
  }
  days.forEach((d,i) => {
    let acc = 0;
    series.forEach(ser => {
      const v = ser.vals[i]; if (!v) return;
      s.appendChild(svgEl('rect', { x:x(i), y:y(acc+v), width:bw,
        height:Math.max(1,(v/max)*ih-2), rx:2, fill:cvar(ser.cv), class:'seg' }));
      acc += v;
    });
    if (totals[i]) s.appendChild(svgEl('text', { x:x(i)+bw/2, y:y(totals[i])-6,
      'text-anchor':'middle', class:'axb' }, totals[i]));
    s.appendChild(svgEl('text', { x:x(i)+bw/2, y:H-14, 'text-anchor':'middle', class:'ax' }, d.slice(8)));
    const hit = svgEl('rect', { x:L+cw*i, y:T, width:cw, height:ih, class:'hit', tabindex:'0' });
    const show = ev => tipShow(ev, d + ' · 총 ' + totals[i] + '실',
      series.map(ser => ({ label:ser.ko, value:ser.vals[i] + '실', color:cvar(ser.cv) })));
    hit.addEventListener('pointermove', show);
    hit.addEventListener('focus', e => show({ clientX:innerWidth/2, clientY:200 }));
    hit.addEventListener('pointerleave', tipHide);
    hit.addEventListener('blur', tipHide);
    s.appendChild(hit);
  });
  host.innerHTML = ''; host.appendChild(s);
  if (legendHost) legendHost.innerHTML =
    HOTELS.map(h => `<span><i class="sw" style="background:var(${h.cv})"></i>${h.ko}</span>`).join('') +
    `<span style="margin-left:auto"><b>피크 ${peak}실</b> · ${peakDay}</span>`;
  if (tableHost) tableHost.innerHTML =
    '<thead><tr><th>날짜</th>' + HOTELS.map(h => `<th class="n">${h.ko}</th>`).join('') +
    '<th class="n">합계</th></tr></thead><tbody>' +
    days.map((d,i) => `<tr><td>${d}</td>` +
      series.map(ser => `<td class="n">${ser.vals[i] || ''}</td>`).join('') +
      `<td class="n"><b>${totals[i] || ''}</b></td></tr>`).join('') + '</tbody>';
  return { days, series, totals, peak, peakDay };
}

/* horizontal bars for the current scope */
function drawScope(host, tableHost, rows, scopeKey){
  const groups = aggregate(rows, scopeKey).slice(0, 14);
  const max = Math.max(1, ...groups.map(g => g.rooms));
  const rowH = 46, W = 720, L = 170, R = 70;
  const H = Math.max(60, groups.length*rowH + 8);
  const s = svgEl('svg', { viewBox:`0 0 ${W} ${H}`, role:'img' });
  s.appendChild(svgEl('title', {}, scopeBy(scopeKey).label + '별 객실 수'));
  groups.forEach((g,i) => {
    const yy = i*rowH + 10, bw = (g.rooms/max) * (W-L-R);
    const h = HOTELS.find(x => x.ko === g.key);
    const col = h ? cvar(h.cv) : cvar('--acc');
    s.appendChild(svgEl('text', { x:L-10, y:yy+15, 'text-anchor':'end', class:'axb' }, String(g.key)));
    s.appendChild(svgEl('text', { x:L-10, y:yy+30, 'text-anchor':'end', class:'ax' },
      g.teams + '팀 · ' + g.pax + '명'));
    s.appendChild(svgEl('rect', { x:L, y:yy, width:Math.max(1,bw), height:22, rx:4,
      fill:col, class:'seg' }));
    s.appendChild(svgEl('text', { x:L+bw+8, y:yy+16, class:'axb' }, g.rooms + '실'));
    const hit = svgEl('rect', { x:L, y:yy-6, width:W-L, height:34, class:'hit', tabindex:'0' });
    const show = ev => tipShow(ev, String(g.key), [
      { label:'객실', value:g.rooms + '실', color:col },
      { label:'싱글 / 트윈', value:g.single + ' / ' + g.twin },
      { label:'팀', value:g.teams + '팀' },
      { label:'인원', value:g.pax + '명 (선수 ' + g.ath + ')' },
      { label:'남 / 여', value:g.male + ' / ' + g.female },
      { label:'room-nights', value:fmt(g.roomNights) }]);
    hit.addEventListener('pointermove', show);
    hit.addEventListener('focus', () => show({ clientX:innerWidth/2, clientY:200 }));
    hit.addEventListener('pointerleave', tipHide);
    hit.addEventListener('blur', tipHide);
    s.appendChild(hit);
  });
  host.innerHTML = ''; host.appendChild(s);
  if (tableHost) tableHost.innerHTML =
    '<thead><tr><th>' + esc(scopeBy(scopeKey).label) + '</th><th class="n">팀</th>' +
    '<th class="n">국가</th><th class="n">인원</th><th class="n">선수</th><th class="n">임원</th>' +
    '<th class="n">남</th><th class="n">여</th><th class="n">싱글</th><th class="n">트윈</th>' +
    '<th class="n">객실</th><th class="n">room-nights</th></tr></thead><tbody>' +
    aggregate(rows, scopeKey).map(g => `<tr><td>${esc(g.key)}</td><td class="n">${g.teams}</td>` +
      `<td class="n">${g.countries}</td><td class="n">${g.pax}</td><td class="n">${g.ath}</td>` +
      `<td class="n">${g.off}</td><td class="n">${g.male}</td><td class="n">${g.female}</td>` +
      `<td class="n">${g.single}</td><td class="n">${g.twin}</td><td class="n"><b>${g.rooms}</b></td>` +
      `<td class="n">${fmt(g.roomNights)}</td></tr>`).join('') + '</tbody>';
  return groups;
}

/* preference matrix */
function drawMatrix(host, rows){
  const m = HOTELS.map(() => [0,0,0]);
  rows.forEach(a => [a.choice_1,a.choice_2,a.choice_3].forEach((c,r) => {
    const i = HOTELS.findIndex(h => h.code === c); if (i >= 0) m[i][r]++;
  }));
  const max = Math.max(1, ...m.flat());
  const step = v => { if (!v) return 'transparent'; const r = v/max;
    return r>.8?'var(--seq5)':r>.6?'var(--seq4)':r>.4?'var(--seq3)':r>.2?'var(--seq2)':'var(--seq1)'; };
  const ink = v => v/max > .6 ? '#fff' : 'var(--txt)';
  host.innerHTML = '<thead><tr><th>호텔</th><th style="text-align:center">1지망</th>' +
    '<th style="text-align:center">2지망</th><th style="text-align:center">3지망</th></tr></thead><tbody>' +
    HOTELS.map((h,i) => `<tr><td><b>${h.ko}</b></td>` +
      m[i].map(v => `<td class="c" style="background:${step(v)};color:${ink(v)}">${v||'·'}</td>`).join('') +
      '</tr>').join('') + '</tbody>';
  return m;
}

/* arrivals / departures */
function drawArrivals(host, legendHost, tableHost, rows){
  const days = dateRange();
  const inn = days.map(()=>0), out = days.map(()=>0);
  rows.forEach(a => {
    const i = days.indexOf(a.check_in);  if (i>=0) inn[i]++;
    const o = days.indexOf(a.check_out); if (o>=0) out[o]++;
  });
  const max = Math.max(1, ...inn, ...out);
  const W=460,H=240,L=30,R=8,T=12,B=30;
  const iw=W-L-R, ih=H-T-B, cw=iw/days.length, bw=Math.max(3,cw/2-2);
  const y = v => T+ih-(v/max)*ih;
  const s = svgEl('svg', { viewBox:`0 0 ${W} ${H}`, role:'img' });
  s.appendChild(svgEl('title', {}, '도착·출발 분포'));
  for (let g=0; g<=3; g++){ const v=max*g/3, yy=y(v);
    s.appendChild(svgEl('line',{x1:L,x2:W-R,y1:yy,y2:yy,class:'gl'}));
    s.appendChild(svgEl('text',{x:L-6,y:yy+4,'text-anchor':'end',class:'ax'},Math.round(v))); }
  days.forEach((d,i) => {
    const bx = L+cw*i+1;
    if (inn[i]) s.appendChild(svgEl('rect',{x:bx,y:y(inn[i]),width:bw,height:ih-(y(inn[i])-T),rx:2,fill:cvar('--acc'),class:'seg'}));
    if (out[i]) s.appendChild(svgEl('rect',{x:bx+bw+2,y:y(out[i]),width:bw,height:ih-(y(out[i])-T),rx:2,fill:cvar('--muted'),class:'seg'}));
    if (i%2===0) s.appendChild(svgEl('text',{x:bx+bw,y:H-10,'text-anchor':'middle',class:'ax'},d.slice(8)));
    const hit = svgEl('rect',{x:L+cw*i,y:T,width:cw,height:ih,class:'hit',tabindex:'0'});
    const show = ev => tipShow(ev, d, [
      { label:'도착', value:inn[i]+'팀', color:cvar('--acc') },
      { label:'출발', value:out[i]+'팀', color:cvar('--muted') }]);
    hit.addEventListener('pointermove', show);
    hit.addEventListener('focus', () => show({clientX:innerWidth/2,clientY:200}));
    hit.addEventListener('pointerleave', tipHide);
    hit.addEventListener('blur', tipHide);
    s.appendChild(hit);
  });
  host.innerHTML=''; host.appendChild(s);
  if (legendHost) legendHost.innerHTML =
    `<span><i class="sw" style="background:var(--acc)"></i>도착</span>` +
    `<span><i class="sw" style="background:var(--muted)"></i>출발</span>` +
    `<span style="margin-left:auto"><b>최다 도착 ${Math.max(0,...inn)}팀</b> · ${days[inn.indexOf(Math.max(0,...inn))]||'—'}</span>`;
  if (tableHost) tableHost.innerHTML =
    '<thead><tr><th>날짜</th><th class="n">도착</th><th class="n">출발</th></tr></thead><tbody>' +
    days.map((d,i) => (inn[i]||out[i]) ? `<tr><td>${d}</td><td class="n">${inn[i]||''}</td><td class="n">${out[i]||''}</td></tr>` : '').join('') +
    '</tbody>';
  return { days, inn, out };
}

/* KPI tiles */
function drawKpis(host, rows, flags){
  const teams = rows.length;
  const p  = rows.reduce((s,a)=>s+pax(a),0);
  const rm = rows.reduce((s,a)=>s+rooms(a),0);
  const rn = rows.reduce((s,a)=>s+nights(a)*rooms(a),0);
  const pk = occupancy(rows).peak;
  const pend = rows.filter(a=>(a.status||'pending')!=='approved').length;
  const unv  = rows.filter(a=>!a.verified).length;
  const flg  = flags ? rows.filter(a=>flags[a.id]).length : 0;
  const ctry = new Set(rows.map(a=>a.country)).size;
  const tiles = [
    ['신청 팀', teams, '', '팀'], ['국가', ctry, '', '개국'],
    ['총 인원', p, '', '명'], ['요청 객실', rm, '', '실'],
    ['피크 점유', pk, '', '실'], ['room-nights', rn, '', ''],
    ['미승인', pend, pend?'warn':'good', '건']
  ];
  if (flags) tiles.push(['확인필요', flg, flg?'bad':'good', '건']);
  else       tiles.push(['자가 신고', unv, unv?'warn':'good', '건']);
  host.innerHTML = tiles.map(t =>
    `<div class="kpi ${t[2]}"><dt>${t[0]}</dt><dd>${fmt(t[1])}<small>${t[3]}</small></dd></div>`).join('');
}

/* change history list */
function drawHistory(host, log){
  if (!log.length){ host.innerHTML = '<p class="empty">기록된 변동이 없습니다.</p>'; return; }
  host.innerHTML = '<thead><tr><th>시각</th><th>국가 / 팀</th><th>구분</th><th>내용</th></tr></thead><tbody>' +
    log.map(e => {
      const t = new Date(e.at);
      const ts = t.toLocaleString('ko-KR', { month:'2-digit', day:'2-digit',
        hour:'2-digit', minute:'2-digit' });
      const cls = e.action === 'insert' ? 'a' : e.action === 'delete' ? 'u' : '';
      return `<tr><td style="white-space:nowrap">${esc(ts)}</td>` +
        `<td><b>${esc(e.country||'')}</b> ${esc(e.team_name||'')}</td>` +
        `<td><span class="chip ${cls}">${ACTION_KO[e.action]||e.action}</span></td>` +
        `<td style="font-size:12.5px">${esc(describe(e))}</td></tr>`;
    }).join('') + '</tbody>';
}

/* ------------------------------------------------------------- exporting -- */
function sheetRows(rows, showContact){
  const head = ['국가코드','국가','팀명','인증'];
  if (showContact) head.push('담당자','이메일');
  head.push('선수','임원','총원','남','여','체크인','체크아웃','박',
            '싱글룸','트윈룸','총객실','1지망','2지망','3지망','배정','상태','식이','비고','최종수정');
  const body = rows.map(a => {
    const r = [a.country, a.country_name || '', a.team_name || '', a.verified ? '인증' : '자가'];
    if (showContact) r.push(a.contact_name || '', a.contact_email || '');
    return r.concat([a.n_athletes|0, a.n_officials|0, pax(a), a.n_male|0, a.n_female|0,
      a.check_in || '', a.check_out || '', nights(a), a.rooms_single|0, a.rooms_twin|0, rooms(a),
      hname(a.choice_1), hname(a.choice_2), hname(a.choice_3),
      a.allocated_hotel ? hname(a.allocated_hotel) : '',
      a.status === 'approved' ? '승인' : '미승인',
      a.dietary || '', a.notes || '', a.updated_at || a.submitted_at || '']);
  });
  return [head].concat(body);
}

function exportXlsx(opts){
  const { rows, log, scopeKey, showContact, stamp, filterNote } = opts;
  if (typeof XLSX === 'undefined'){ alert('엑셀 라이브러리를 불러오지 못했습니다. 네트워크를 확인하세요.'); return; }
  const wb = XLSX.utils.book_new();
  const occ = occupancy(rows);
  const S = (name, aoa) => XLSX.utils.book_append_sheet(wb, XLSX.utils.aoa_to_sheet(aoa), name);

  /* 1. 요약 — the point-in-time snapshot header */
  S('요약', [
    ['Changwon 2026 WSPS 세계선수권 · 숙박 신청 집계'],
    ['생성 시각', stamp], ['적용 필터', filterNote || '전체'],
    ['분석 기준(scope)', scopeBy(scopeKey).label], [],
    ['항목','값'],
    ['신청 팀', rows.length],
    ['국가', new Set(rows.map(a=>a.country)).size],
    ['총 인원', rows.reduce((s,a)=>s+pax(a),0)],
    ['선수', rows.reduce((s,a)=>s+(a.n_athletes|0),0)],
    ['임원', rows.reduce((s,a)=>s+(a.n_officials|0),0)],
    ['남 / 여', rows.reduce((s,a)=>s+(a.n_male|0),0) + ' / ' + rows.reduce((s,a)=>s+(a.n_female|0),0)],
    ['싱글룸', rows.reduce((s,a)=>s+(a.rooms_single|0),0)],
    ['트윈룸', rows.reduce((s,a)=>s+(a.rooms_twin|0),0)],
    ['총 객실', rows.reduce((s,a)=>s+rooms(a),0)],
    ['room-nights', rows.reduce((s,a)=>s+nights(a)*rooms(a),0)],
    ['피크 점유(실)', occ.peak], ['피크 날짜', occ.peakDay],
    ['미승인', rows.filter(a=>(a.status||'pending')!=='approved').length]
  ]);

  /* 2. scope 집계 */
  const groups = aggregate(rows, scopeKey);
  S('집계_' + scopeBy(scopeKey).key,
    [[scopeBy(scopeKey).label,'팀','국가수','인원','선수','임원','남','여','싱글','트윈','총객실','room-nights']]
    .concat(groups.map(g => [g.key,g.teams,g.countries,g.pax,g.ath,g.off,g.male,g.female,
      g.single,g.twin,g.rooms,g.roomNights])));

  /* 3. 신청 목록 */
  S('신청목록', sheetRows(rows, showContact));

  /* 4. 날짜별 점유 */
  S('날짜별점유', [['날짜'].concat(HOTELS.map(h=>h.ko)).concat(['합계'])]
    .concat(occ.days.map((d,i) => [d].concat(occ.series.map(s=>s.vals[i])).concat([occ.totals[i]]))));

  /* 5. 도착/출발 */
  const days = dateRange(), inn = days.map(()=>0), outv = days.map(()=>0);
  rows.forEach(a => { const i=days.indexOf(a.check_in); if(i>=0) inn[i]++;
                      const o=days.indexOf(a.check_out); if(o>=0) outv[o]++; });
  S('도착출발', [['날짜','도착팀','출발팀']].concat(days.map((d,i)=>[d,inn[i],outv[i]])));

  /* 6. 선호 순위 */
  const m = HOTELS.map(()=>[0,0,0]);
  rows.forEach(a => [a.choice_1,a.choice_2,a.choice_3].forEach((c,r)=>{
    const i = HOTELS.findIndex(h=>h.code===c); if(i>=0) m[i][r]++; }));
  S('선호순위', [['호텔','1지망','2지망','3지망']].concat(HOTELS.map((h,i)=>[h.ko].concat(m[i]))));

  /* 7. 변경 이력 */
  S('변경이력', [['시각','국가','팀','구분','내용','작성자']]
    .concat((log||[]).map(e => [
      new Date(e.at).toLocaleString('ko-KR'), e.country||'', e.team_name||'',
      ACTION_KO[e.action]||e.action, describe(e), e.actor||''])));

  XLSX.writeFile(wb, 'changwon2026_숙박집계_' + stamp.replace(/[^0-9]/g,'').slice(0,12) + '.xlsx');
}

/* ------------------------------------------------------------------ api --- */
root.ACC = {
  HOTELS, SCOPES, WINDOW_OPEN, WINDOW_CLOSE,
  pax, rooms, nights, bucket, hname, esc, cvar, fmt, dateRange,
  aggregate, scopeBy, occupancy, crossCheck,
  lastSeen, markSeen, unseen, describe, ACTION_KO, FIELD_KO,
  drawOccupancy, drawScope, drawMatrix, drawArrivals, drawKpis, drawHistory,
  tipShow, tipHide, exportXlsx, sheetRows
};
})(window);

/* ===== 관리 테이블 좌측 순번(#) 열 자동 삽입 — admin.html과 동일 UX, 재렌더 대응 ===== */
(function(){
  function numberTable(t){
    if (!t.tHead || !t.tBodies.length) return;
    if (t.tHead.querySelector('th.rncol')) return;
    for (var r=0; r<t.tHead.rows.length; r++){
      var hr=t.tHead.rows[r], hc=document.createElement('th');
      hc.className='rncol'; hc.textContent=(r===0?'#':'');
      hc.style.cssText='width:38px;min-width:38px;text-align:center';
      hr.insertBefore(hc, hr.firstChild);
    }
    var tb=t.tBodies[0], n=0;
    for (var i=0; i<tb.rows.length; i++){
      var row=tb.rows[i], f=row.cells[0];
      if (f && f.colSpan>1){ f.colSpan=f.colSpan+1; continue; }
      n++;
      var td=document.createElement('td');
      td.className='rncol'; td.textContent=n;
      td.style.cssText='text-align:center;color:#8a94a0;font-size:11.5px;white-space:nowrap';
      row.insertBefore(td, row.firstChild);
    }
  }
  function sweep(){ var ts=document.querySelectorAll('table'); for (var i=0;i<ts.length;i++) numberTable(ts[i]); }
  var mo = new MutationObserver(function(){
    mo.disconnect();
    try { sweep(); } finally { mo.observe(document.body, {childList:true, subtree:true}); }
  });
  function start(){ sweep(); mo.observe(document.body, {childList:true, subtree:true}); }
  if (document.readyState === 'loading') document.addEventListener('DOMContentLoaded', start);
  else start();
})();

