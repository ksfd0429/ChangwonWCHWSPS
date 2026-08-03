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
const bucket = a => codeOf(a.allocated_hotel) || codeOf(a.choice_1);
const hotelOf = c => HOTELS.find(h => h.code === c);
const hname   = c => { const h = hotelOf(c); return h ? h.ko : (c || '—'); };
const esc = s => String(s ?? '').replace(/[&<>"]/g,
  c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c]));
const cvar = v => getComputedStyle(document.documentElement).getPropertyValue(v).trim();
const fmt = n => (n || 0).toLocaleString('ko-KR');

/* The grid used to be hardcoded to 3–21 September while the form accepted
   1–25 September. Anything outside the grid was silently dropped: a team
   staying 1–3 Sep contributed rooms and room-nights to the KPIs but ZERO to
   every day column, zero arrivals and zero departures — invisible on the one
   chart the hotels block rooms from. The range now always covers the data. */
function dateRange(rows){
  const iso = d => d.toISOString().slice(0,10);
  let lo = WINDOW_OPEN, hi = WINDOW_CLOSE;
  (rows||[]).forEach(a => {
    if (/^\d{4}-\d{2}-\d{2}$/.test(a.check_in||'')  && a.check_in  < lo) lo = a.check_in;
    if (/^\d{4}-\d{2}-\d{2}$/.test(a.check_out||'') && a.check_out > hi) hi = a.check_out;
  });
  const out = [], d = new Date(lo), end = new Date(hi);
  // guard against a wild date turning this into a million-cell loop
  let guard = 0;
  while (d <= end && guard++ < 400) { out.push(iso(d)); d.setDate(d.getDate()+1); }
  return out;
}

/* Hotel code as stored, normalised. allocated_hotel is set by hand and
   choice_* used to be unconstrained, so 'gma', ' GMA' and typos existed.
   An unrecognised code used to make the row vanish from occupancy and the
   PEAK while still counting in "rooms requested" — the hotels' blocking
   figure came out LOW with nothing on screen to say so. */
const codeOf = v => String(v ?? '').trim().toUpperCase();

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
    if (String(a.country||'').trim()) g.countries.add(a.country);
  });
  return [...map.values()]
    .map(g => ({ ...g, countries: g.countries.size }))
    .sort((x,y) => y.rooms - x.rooms || String(x.key).localeCompare(String(y.key)));
}

/* ------------------------------------------------------------- occupancy -- */
function occupancy(rows){
  const days = dateRange(rows);
  const series = HOTELS.map(h => ({ ...h, vals: days.map(() => 0) }));
  const orphans = [];   // rows that could not be placed in any hotel column
  rows.forEach(a => {
    const s = series.find(x => x.code === bucket(a));
    if (!s) { if (rooms(a)) orphans.push(a); return; }
    days.forEach((d,i) => { if (a.check_in <= d && d < a.check_out) s.vals[i] += rooms(a); });
  });
  const totals = days.map((_,i) => series.reduce((s,x) => s + x.vals[i], 0));
  const peak = Math.max(0, ...totals);
  return { days, series, totals, peak,
           peakDay: peak > 0 ? (days[totals.indexOf(peak)] || '—') : '—',
           orphans, orphanRooms: orphans.reduce((n,a)=>n+rooms(a),0) };
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
/* localStorage throws, not returns null, when the browser blocks storage
   ("block all cookies", third-party iframe). It used to throw straight out of
   render() and leave the partner staring at a blank page. */
function lastSeen(ns){
  try { return localStorage.getItem(seenKey(ns)) || ''; } catch(e){ return ''; }
}
function markSeen(ns, iso){
  try { localStorage.setItem(seenKey(ns), iso || new Date().toISOString()); } catch(e){}
}
/* newest timestamp in a log, so "seen" can be pinned to what was actually
   rendered rather than to the client clock at the moment the modal closed —
   otherwise a change arriving while the modal is open is marked seen without
   ever having been shown. */
function newestAt(log){
  return (log||[]).reduce((m,e)=> (e && e.at && e.at > m) ? e.at : m, '');
}
function unseen(log, ns){
  const ls = lastSeen(ns);
  // First visit is a BASELINE, not a flood. The trigger writes an 'insert'
  // row for every application ever made, so the old behaviour greeted a
  // first-time partner with a 99+ badge and every row painted "changed".
  if (!ls) { markSeen(ns, newestAt(log) || new Date().toISOString()); return 0; }
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
const SCOPE_CHART_MAX = 14;
function drawScope(host, tableHost, rows, scopeKey){
  const all = aggregate(rows, scopeKey);
  const groups = all.slice(0, SCOPE_CHART_MAX);
  const hidden = all.length - groups.length;   // never truncate silently
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
  // The chart shows at most SCOPE_CHART_MAX bars; with scope=국가 that hides
  // most of the field. Say what was left out instead of letting the chart and
  // the table below it quietly disagree.
  if (hidden > 0) host.insertAdjacentHTML('beforeend',
    `<p class="scopenote" style="margin-top:10px">상위 ${SCOPE_CHART_MAX}개만 그래프에 표시했습니다 · ` +
    `나머지 ${hidden}개 항목은 아래 표에 모두 있습니다.</p>`);
  if (tableHost) tableHost.innerHTML =
    '<thead><tr><th>' + esc(scopeBy(scopeKey).label) + '</th><th class="n">팀</th>' +
    '<th class="n">국가</th><th class="n">인원</th><th class="n">선수</th><th class="n">임원</th>' +
    '<th class="n">남</th><th class="n">여</th><th class="n">싱글</th><th class="n">트윈</th>' +
    '<th class="n">객실</th><th class="n">room-nights</th></tr></thead><tbody>' +
    all.map(g => `<tr><td>${esc(g.key)}</td><td class="n">${g.teams}</td>` +
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
  const days = dateRange(rows);
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
    `<span style="margin-left:auto"><b>최다 도착 ${Math.max(0,...inn)}팀</b>${Math.max(0,...inn) ? ' · ' + (days[inn.indexOf(Math.max(0,...inn))]||'—') : ''}</span>`;
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
  const occ = occupancy(rows);
  const pk = occ.peak;
  const pend = rows.filter(a=>(a.status||'pending')!=='approved').length;
  const unv  = rows.filter(a=>!a.verified).length;
  const flg  = flags ? rows.filter(a=>flags[a.id]).length : 0;
  const ctry = new Set(rows.map(a=>a.country).filter(c=>String(c||'').trim())).size;
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
  // "요청 객실" counts every row; "피크 점유" can only count rows whose hotel
  // code is one of GMA/GCC/ISQ. When they disagree, say so — a peak that is
  // quietly short is how a hotel ends up blocking too few rooms.
  if (occ.orphanRooms){
    const codes = [...new Set(occ.orphans.map(a=>bucket(a)||'(빈값)'))].join(', ');
    host.insertAdjacentHTML('afterend',
      `<div class="newsflash" style="margin-top:0"><span class="dot">!</span>` +
      `<span>호텔 코드가 확인되지 않는 신청 ${occ.orphans.length}건 · ${fmt(occ.orphanRooms)}실이 ` +
      `일자별 점유·피크 계산에서 제외되었습니다 (코드: ${esc(codes)}). 배정 호텔을 확인해 주세요.</span></div>`);
  }
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
    ['※ 아래 수치는 숙박 서베이에 접수된 신청 건만 집계한 것입니다.'],
    ['※ 참가등록명단 시트와는 연결되어 있지 않아 인원 수가 다를 수 있습니다.'],
    ['생성 시각', stamp], ['적용 필터', filterNote || '전체'],
    ['분석 기준(scope)', scopeBy(scopeKey).label], [],
    ['항목','값'],
    ['신청 팀', rows.length],
    ['국가', new Set(rows.map(a=>a.country).filter(c=>String(c||'').trim())).size],
    ['총 인원', rows.reduce((s,a)=>s+pax(a),0)],
    ['선수', rows.reduce((s,a)=>s+(a.n_athletes|0),0)],
    ['임원', rows.reduce((s,a)=>s+(a.n_officials|0),0)],
    ['남', rows.reduce((s,a)=>s+(a.n_male|0),0)],
    ['여', rows.reduce((s,a)=>s+(a.n_female|0),0)],
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
  // A recipient who only ever sees this file needs the conventions spelled
  // out here — on screen they are in the panel text, in the file they were
  // nowhere.
  S('날짜별점유', [
    ['※ 각 날짜의 "그날 밤" 사용 객실 수입니다. 체크아웃 당일은 포함되지 않습니다 (9/7~9/12 숙박 = 9/7~9/11 5박).'],
    ['※ 호텔 블로킹은 총합이 아니라 피크(최대 동시 사용) 기준으로 잡으셔야 합니다. 피크 ' +
      occ.peak + '실 · ' + occ.peakDay],
    (occ.orphanRooms ? ['※ 호텔 코드 미확인 ' + occ.orphans.length + '건 · ' + occ.orphanRooms +
      '실은 아래 표에서 제외되어 있습니다.'] : ['']),
    [],
    ['날짜'].concat(HOTELS.map(h=>h.ko)).concat(['합계'])]
    .concat(occ.days.map((d,i) => [d].concat(occ.series.map(s=>s.vals[i])).concat([occ.totals[i]]))));

  /* 5. 도착/출발 */
  const days = dateRange(rows), inn = days.map(()=>0), outv = days.map(()=>0);
  rows.forEach(a => { const i=days.indexOf(a.check_in); if(i>=0) inn[i]++;
                      const o=days.indexOf(a.check_out); if(o>=0) outv[o]++; });
  S('도착출발', [
    ['※ 팀 단위 집계입니다 (인원수 아님). 셔틀·체크인 데스크 인력 산정용.'],
    [],
    ['날짜','도착팀','출발팀']].concat(days.map((d,i)=>[d,inn[i],outv[i]])));

  /* 6. 선호 순위 */
  const m = HOTELS.map(()=>[0,0,0]);
  rows.forEach(a => [a.choice_1,a.choice_2,a.choice_3].forEach((c,r)=>{
    const i = HOTELS.findIndex(h=>h.code===c); if(i>=0) m[i][r]++; }));
  S('선호순위', [['호텔','1지망','2지망','3지망']].concat(HOTELS.map((h,i)=>[h.ko].concat(m[i]))));

  /* 7. 선수단 명단 */
  if (opts.roster && opts.roster.length){
    S('참가등록명단', [
      ['※ Accreditation 등록 인원. 숙박 신청 여부와 무관하며, 개인별 호텔 배정은 미확정입니다.'],
      [opts.rosterFilter ? ('※ 적용 필터: ' + opts.rosterFilter) : '※ 필터 없음 (전체)'],
      [],
      ['국가','이름','구분','성별','나이','미성년','휠체어']]
      .concat(opts.roster.map(r => [r.country||'', r.full_name||'',
        POS_KO[String(r.position||'').trim().toLowerCase()] || (r.position||''),
        r.gender === 'M' ? '남' : r.gender === 'F' ? '여' : '',
        r.age != null ? r.age : '',
        (typeof r.age === 'number' && r.age < 18) ? 'Y' : '',
        r.wheelchair ? 'Y' : ''])));
  }

  /* 8. 변경 이력 */
  S('변경이력', [['시각','국가','팀','구분','내용','작성자']]
    .concat((log||[]).map(e => [
      new Date(e.at).toLocaleString('ko-KR'), e.country||'', e.team_name||'',
      ACTION_KO[e.action]||e.action, describe(e), e.actor||''])));

  const t = new Date(), z = n => String(n).padStart(2,'0');
  const fname = 'changwon2026_숙박집계_' + t.getFullYear() + z(t.getMonth()+1) + z(t.getDate()) +
                '_' + z(t.getHours()) + z(t.getMinutes()) + z(t.getSeconds()) + '.xlsx';
  XLSX.writeFile(wb, fname);
}

/* ---------------------------------------------------------------- roster -- */
/* Per-person list for partners. The payload already excludes passport and
   date of birth — this only decides how it is shown. */
function rosterStats(roster){
  const n = roster.length;
  const wc = roster.filter(r => r.wheelchair).length;
  const ath = roster.filter(r => (r.position||'').toLowerCase() === 'athlete').length;
  // everything that is not an athlete: officials, coaches, assistants,
  // guides, accompanying family. It was labelled "임원", which the table
  // below then contradicted by showing 지도자 / 지원 / 가이드 / 동반가족.
  const ages = roster.map(r => r.age).filter(a => typeof a === 'number');
  const avg = ages.length ? Math.round(ages.reduce((s,a)=>s+a,0)/ages.length) : null;
  // anything that is not exactly M or F renders as "—" in the table, so it
  // has to count as missing here too, or the two disagree
  const noGender = roster.filter(r => r.gender !== 'M' && r.gender !== 'F').length;
  const minors = roster.filter(r => typeof r.age === 'number' && r.age < 18).length;
  return { n, wc, ath, off:n-ath, avg, minors,
           min: ages.length?Math.min(...ages):null, max: ages.length?Math.max(...ages):null,
           noGender, noAge: n - ages.length,
           countries: new Set(roster.map(r=>r.country).filter(c=>String(c||'').trim())).size };
}
/* Accreditation stores position in English; the roster is a Korean surface. */
const POS_KO = { athlete:'선수', official:'임원', coach:'지도자', assistant:'지원',
                 guide:'가이드', family:'동반가족' };
function posKo(p){
  if (!p) return '<span style="color:var(--muted)">—</span>';
  const k = POS_KO[String(p).trim().toLowerCase()];
  return '<span class="chip">' + esc(k || p) + '</span>';
}
function drawRoster(host, statHost, roster, q, countryFilter){
  // Stats are computed on the FILTERED list. They used to be computed on the
  // whole roster while the table below showed the filter — so a hotel that
  // filtered to the one delegation it hosts read "휠체어 72명" directly above
  // a 22-row table whose real answer was 5. Accessible-room blocking is the
  // number on this tab that gets acted on most literally.
  const term0 = (q||'').trim().toLowerCase();
  const shown = roster.filter(r => {
    if (countryFilter && r.country !== countryFilter) return false;
    if (!term0) return true;
    return ((r.full_name||'') + ' ' + (r.country||'')).toLowerCase().includes(term0);
  });
  const st = rosterStats(shown);
  if (statHost) statHost.innerHTML =
    `<span><b>${st.n}</b>명 · ${st.countries}개국</span>` +
    `<span>선수 <b>${st.ath}</b> · 그 외 <b>${st.off}</b></span>` +
    `<span>휠체어 <b style="color:var(--acc)">${st.wc}</b>명</span>` +
    (st.avg != null ? `<span>평균 ${st.avg}세 (${st.min}–${st.max})</span>` : '') +
    (st.minors ? `<span style="color:var(--y)">미성년 <b>${st.minors}</b>명 · 단독 배정 불가</span>` : '') +
    (st.noGender ? `<span style="color:var(--y)">성별 미기재 ${st.noGender}</span>` : '') +
    (st.noAge ? `<span style="color:var(--y)">생년 미기재 ${st.noAge}</span>` : '');

  const list = shown;
  host.innerHTML =
    '<thead><tr><th>이름</th><th>국가</th><th>구분</th><th>성별</th>' +
    '<th class="n">나이</th><th>휠체어</th></tr></thead><tbody>' +
    (list.length ? list.map(r =>
      `<tr><td><b>${esc(r.full_name)}</b></td>` +
      `<td>${esc(r.country||'')}</td>` +
      `<td>${posKo(r.position)}</td>` +
      `<td>${r.gender === 'M' ? '남' : r.gender === 'F' ? '여'
             : '<span style="color:var(--muted)">—</span>'}</td>` +
      `<td class="n">${r.age != null
             ? (r.age < 18 ? '<b style="color:var(--y)">'+r.age+'</b>' : r.age)
             : '<span style="color:var(--muted)">—</span>'}</td>` +
      `<td>${r.wheelchair ? '<span class="chip u">휠체어</span>'
             : '<span style="color:var(--muted)">—</span>'}</td></tr>`).join('')
      : '<tr><td colspan="6" class="empty">조건에 맞는 인원이 없습니다.</td></tr>') +
    '</tbody>';
  return list;
}

/* ------------------------------------------------------------- demo data -- */
/* Sample payload for ?demo=1. Deterministic — no Math.random — so the same
   link always shows the same numbers and two people comparing screens agree.
   Both dashboards render this through exactly the same code path as live
   data, so the demo is a faithful preview, not a mock-up of a mock-up. */
function demoData(){
  const NP = [['KOR','Korea'],['GER','Germany'],['USA','United States'],['JPN','Japan'],
    ['FRA','France'],['CHN','China'],['IND','India'],['BRA','Brazil'],['POL','Poland'],
    ['UKR','Ukraine'],['SVK','Slovakia'],['NED','Netherlands'],['ITA','Italy'],
    ['ESP','Spain'],['AUS','Australia'],['CAN','Canada'],['TUR','Turkey'],['THA','Thailand']];
  const H = ['GMA','GCC','ISQ'];
  const rows = []; let id = 1;
  NP.forEach((c,i) => {
    const teams = (i % 5 === 0) ? 2 : 1;
    for (let t = 0; t < teams; t++){
      const ath = 3 + ((i*7 + t*11) % 16);
      const off = 2 + ((i*3 + t) % 7);
      const male = Math.round((ath+off) * (0.45 + ((i%5)*0.06)));
      const inD  = 3 + ((i + t*2) % 5);
      const outD = 18 + ((i + t) % 4);
      const alloc = (i % 3 === 0);
      rows.push({
        id: id++, country: c[0], country_name: c[1],
        team_name: c[0] + (teams > 1 ? ' Team ' + (t+1) : ' National Team'),
        verified: (i % 4 !== 1),
        contact_name: null, contact_email: null,
        n_athletes: ath, n_officials: off, n_male: male, n_female: (ath+off) - male,
        check_in : '2026-09-' + String(inD).padStart(2,'0'),
        check_out: '2026-09-' + String(outD).padStart(2,'0'),
        choice_1: H[(i+t) % 3], choice_2: H[(i+t+1) % 3], choice_3: H[(i+t+2) % 3],
        rooms_single: 1 + (i % 5), rooms_twin: 2 + ((i*2 + t*3) % 9),
        dietary: (i % 6 === 0) ? '할랄 4' : (i % 7 === 0 ? '채식 2, 글루텐프리 1' : ''),
        status: alloc ? 'approved' : 'pending',
        allocated_hotel: alloc ? H[(i+t) % 3] : '',
        submitted_at: '2026-08-' + String(1 + (i % 9)).padStart(2,'0') + ' 10:00:00',
        updated_at: ''
      });
    }
  });
  const now = Date.now(), ago = m => new Date(now - m*60000).toISOString();
  const log = [
    { id:5, accommodation_id:rows[2].id, country:rows[2].country, team_name:rows[2].team_name,
      action:'update', changed:{ rooms_twin:[6,9], n_athletes:[10,13] }, actor:'npc', at:ago(7) },
    { id:4, accommodation_id:rows[5].id, country:rows[5].country, team_name:rows[5].team_name,
      action:'update', changed:{ check_out:['2026-09-18','2026-09-20'] }, actor:'npc', at:ago(52) },
    { id:3, accommodation_id:rows[9].id, country:rows[9].country, team_name:rows[9].team_name,
      action:'insert', changed:{ total_pax:14, rooms:9, choice_1:'GCC' }, actor:'npc', at:ago(215) },
    { id:2, accommodation_id:rows[0].id, country:rows[0].country, team_name:rows[0].team_name,
      action:'update', changed:{ allocated_hotel:['','GMA'], status:['pending','approved'] },
      actor:'loc', at:ago(600) },
    { id:1, accommodation_id:rows[13].id, country:rows[13].country, team_name:rows[13].team_name,
      action:'update', changed:{ choice_1:['ISQ','GMA'], choice_3:['GMA','ISQ'] }, actor:'npc', at:ago(1500) }
  ];
  const d = new Date(now);
  const stamp = d.getFullYear() + '-' + String(d.getMonth()+1).padStart(2,'0') + '-' +
    String(d.getDate()).padStart(2,'0') + ' ' + String(d.getHours()).padStart(2,'0') + ':' +
    String(d.getMinutes()).padStart(2,'0') + ':' + String(d.getSeconds()).padStart(2,'0');
  // demo roster, derived from the demo teams so the totals line up
  const FN = ['Minjun','Lukas','Emily','Haruto','Camille','Wei','Arjun','Lucas','Jakub',
              'Olena','Marek','Daan','Marco','Carmen','Jack','Owen','Emre','Somchai'];
  const LN = ['Kim','Schmidt','Brown','Sato','Dubois','Chen','Patel','Silva','Nowak',
              'Kovalenko','Varga','de Vries','Rossi','Garcia','Wilson','Taylor','Yilmaz','Chai'];
  const roster = [];
  rows.forEach((t, ti) => {
    const total = t.n_athletes + t.n_officials;
    for (let k = 0; k < total; k++){
      const isAth = k < t.n_athletes;
      const idx = (ti*5 + k) % FN.length;
      roster.push({
        country: t.country,
        full_name: FN[idx] + ' ' + LN[(idx + ti) % LN.length],
        gender: (k % 10 === 7) ? '' : (k < t.n_male ? 'M' : 'F'),
        age: (k % 12 === 5) ? null : 19 + ((ti*7 + k*3) % 34),
        wheelchair: isAth && ((ti + k) % 3 === 0),
        position: isAth ? 'Athlete' : 'Official'
      });
    }
  });
  return { label:'데모 데이터', show_contact:false, generated_at:stamp,
           rows, roster, log, hotels:[], demo:true };
}

/* Shows an unmissable banner so demo figures are never mistaken for real ones. */
function demoBanner(){
  if (document.getElementById('demoBar')) return;
  const b = document.createElement('div');
  b.id = 'demoBar';
  b.style.cssText = 'background:#E87722;color:#fff;font-weight:700;font-size:13.5px;' +
    'padding:9px 20px;text-align:center;letter-spacing:.01em';
  b.textContent = '데모 데이터입니다 — 실제 신청 내역이 아닙니다. 화면 구성과 기능 확인용입니다.';
  document.body.insertBefore(b, document.body.firstChild);
  document.title = '[데모] ' + document.title;
}

/* ------------------------------------------------------------------ api --- */
root.ACC = {
  HOTELS, SCOPES, WINDOW_OPEN, WINDOW_CLOSE,
  pax, rooms, nights, bucket, hname, esc, cvar, fmt, dateRange,
  aggregate, scopeBy, occupancy, crossCheck,
  lastSeen, markSeen, unseen, newestAt, describe, ACTION_KO, FIELD_KO,
  drawOccupancy, drawScope, drawMatrix, drawArrivals, drawKpis, drawHistory,
  drawRoster, rosterStats,
  tipShow, tipHide, exportXlsx, sheetRows, demoData, demoBanner
};
})(window);
