-- ============================================================
-- 실물 항공권 기반 전체 여정(경유 포함) 저장 — 2026-08-31 적용됨
--
-- 설계 원칙
--  · 기존 대표 구간(arrive/arr_flight/arr_time, depart/dep_flight/dep_time)은 그대로 유지한다.
--    → 총포서류·명단 등 기존 로직이 그대로 동작한다. 대표 구간 = 한국 입/출국 국제선 구간.
--  · 전체 여정(경유 포함)은 arr_legs / dep_legs JSONB 배열에 구간 단위로 쌓는다.
--
-- 구간(leg) 객체 형식  ※ 모르는 항목은 넣지 않거나 빈 문자열
-- {
--   "seq": 1,                    -- 구간 순서(1부터)
--   "flight": "LH718",           -- 편명
--   "from": "MUC",               -- 출발 공항 IATA
--   "from_name": "뮌헨",          -- 출발 공항 표기명(문서용)
--   "from_terminal": "2",
--   "to": "ICN",                 -- 도착 공항 IATA
--   "to_name": "인천",
--   "to_terminal": "1",
--   "dep_date": "2026-09-06",    -- 현지 출발일
--   "dep_time": "09:55",         -- 현지 출발시각
--   "arr_date": "2026-09-07",    -- 현지 도착일(날짜 넘김 대응)
--   "arr_time": "13:20",
--   "cabin": "Y",                -- 좌석 등급
--   "seat": "32A",
--   "baggage": "2PC",            -- 수하물 규정(총기 별도 수하물 확인용)
--   "pnr": "ABC123",             -- 구간별 PNR이 다를 때만
--   "note": ""                   -- 비고(총기 동반 여부 등)
-- }
--
-- 입국(arr_legs)은 출발지→한국 순서, 출국(dep_legs)은 한국→목적지 순서로 정렬해 넣는다.
-- 경유 대기시간은 앞 구간 arr_date/arr_time 과 다음 구간 dep_date/dep_time 으로 계산한다.
-- ============================================================

alter table members add column if not exists arr_legs      jsonb not null default '[]'::jsonb;
alter table members add column if not exists dep_legs      jsonb not null default '[]'::jsonb;
alter table members add column if not exists ticket_pnr    text  default '';
alter table members add column if not exists ticket_no     text  default '';
alter table members add column if not exists itinerary_src text  default '';
alter table members add column if not exists itinerary_at  timestamptz;

comment on column members.arr_legs is '입국 여정 구간 배열(출발지→인천/김해). 요소: {seq,flight,from,from_name,from_terminal,to,to_name,to_terminal,dep_date,dep_time,arr_date,arr_time,cabin,seat,baggage,pnr,note}';
comment on column members.dep_legs is '출국 여정 구간 배열(인천/김해→목적지). 요소 형식은 arr_legs와 동일';
comment on column members.ticket_pnr is '예약번호(PNR)';
comment on column members.ticket_no is '항공권 번호(e-ticket)';
comment on column members.itinerary_src is '여정 출처(파일명·메일 등)';
comment on column members.itinerary_at is '여정 최종 갱신 시각';

do $$ begin alter table members add constraint members_arr_legs_array check (jsonb_typeof(arr_legs)='array'); exception when duplicate_object then null; end $$;
do $$ begin alter table members add constraint members_dep_legs_array check (jsonb_typeof(dep_legs)='array'); exception when duplicate_object then null; end $$;

create index if not exists members_arr_legs_gin on members using gin (arr_legs jsonb_path_ops);
create index if not exists members_dep_legs_gin on members using gin (dep_legs jsonb_path_ops);

-- 여정 요약 뷰: 최초 출발지 / 최종 도착지 / 편명 체인 / 경유 공항
create or replace view v_member_flights as
select m.id, m.country,
 coalesce(nullif(m.name,''), m.first_name||' '||m.last_name) as nm, m.position,
 jsonb_array_length(m.arr_legs) as arr_leg_count,
 jsonb_array_length(m.dep_legs) as dep_leg_count,
 m.arr_legs->0->>'from' as arr_origin,
 m.arr_legs->0->>'dep_date' as arr_origin_date,
 m.arr_legs->0->>'dep_time' as arr_origin_time,
 m.arr_legs->(greatest(jsonb_array_length(m.arr_legs),1)-1)->>'to' as arr_final,
 m.arr_legs->(greatest(jsonb_array_length(m.arr_legs),1)-1)->>'arr_date' as arr_final_date,
 m.arr_legs->(greatest(jsonb_array_length(m.arr_legs),1)-1)->>'arr_time' as arr_final_time,
 (select string_agg(l->>'flight',' / ' order by ord) from jsonb_array_elements(m.arr_legs) with ordinality t(l,ord)) as arr_flight_chain,
 (select string_agg(l->>'to',' > ' order by ord) from jsonb_array_elements(m.arr_legs) with ordinality t(l,ord) where ord < jsonb_array_length(m.arr_legs)) as arr_via,
 m.dep_legs->0->>'from' as dep_origin,
 m.dep_legs->0->>'dep_date' as dep_origin_date,
 m.dep_legs->0->>'dep_time' as dep_origin_time,
 m.dep_legs->(greatest(jsonb_array_length(m.dep_legs),1)-1)->>'to' as dep_final,
 (select string_agg(l->>'flight',' / ' order by ord) from jsonb_array_elements(m.dep_legs) with ordinality t(l,ord)) as dep_flight_chain,
 m.arrive, m.arr_flight, m.arr_time, m.depart, m.dep_flight, m.dep_time,
 m.ticket_pnr, m.ticket_no, m.itinerary_src, m.itinerary_at
from members m;

-- 사용 예 --------------------------------------------------
-- 1) 한 명의 입국 여정 입력(뮌헨 → 프랑크푸르트 경유 → 인천)
-- update members set
--   arr_legs = '[
--     {"seq":1,"flight":"LH1803","from":"MUC","from_name":"뮌헨","to":"FRA","to_name":"프랑크푸르트",
--      "dep_date":"2026-09-05","dep_time":"18:20","arr_date":"2026-09-05","arr_time":"19:30"},
--     {"seq":2,"flight":"LH718","from":"FRA","from_name":"프랑크푸르트","to":"ICN","to_name":"인천",
--      "dep_date":"2026-09-05","dep_time":"21:40","arr_date":"2026-09-06","arr_time":"14:35"}
--   ]'::jsonb,
--   itinerary_src = 'e-ticket_XXX.pdf', itinerary_at = now()
-- where id = 351;
--
-- 2) 여정이 입력된 인원 현황
-- select country, count(*) filter (where arr_leg_count>0) as 입국여정, count(*) as 전체
--   from v_member_flights group by country order by country;
--
-- 3) 경유가 있는 인원만
-- select country, nm, arr_flight_chain, arr_via from v_member_flights where arr_leg_count > 1;
