-- Changwon 2026 WSPS World Championships · NPC Submission System
-- Supabase 스키마. Supabase SQL Editor에 붙여넣어 실행하세요.
-- 실행 후 index.html / submit.html 상단의 SUPABASE_URL, SUPABASE_ANON_KEY를 채우면 실DB로 동작합니다.

-- 1. 계정 활성화 파이프라인 (계정 = Supabase Auth 사용자)
--    국가 선택 → 활성화 요청(이메일) → 관리자 승인 → Auth invite 메일(비밀번호 세팅 링크)
--    → 세팅 완료 시 npc_directory.active=true. 로그인은 국가→이메일 매핑 후 Auth 처리.
--    ※ 승인/초대 발송은 service_role 필요(관리자 콘솔/Edge Function). anon은 신청만 가능.
--    ※ 화이트라벨: 대시보드 Auth > Emails에서 발신자명·템플릿을 대회 브랜드로 교체(자체 SMTP 권장).
create table if not exists activation_requests (
  id bigint generated always as identity primary key,
  country text not null,
  email text not null,
  status text default 'pending',   -- pending | approved | rejected
  requested_at timestamptz default now(),
  decided_at timestamptz
);
create index if not exists actreq_country on activation_requests(country);

create table if not exists npc_directory (
  country text primary key,
  email text not null,
  user_id uuid,                    -- auth.users.id (초대 후 채움)
  active boolean default false,
  created_at timestamptz default now()
);

-- 2. 선수단 명단 (Delegation info 모듈)
create table if not exists members (
  id bigint generated always as identity primary key,
  country text not null,
  first_name text default '',
  last_name text default '',
  name text default '',            -- legacy 표시용(선택)
  position text default 'Athlete', -- Athlete | Official
  dob text default '',
  passport text default '',
  sub_group text default '',       -- 세부소속(Group)
  arrive text default '',          -- 도착일
  arr_flight text default '',
  arr_time text default '',
  depart text default '',          -- 귀국일
  dep_flight text default '',
  dep_time text default '',
  room text default 'Twin',        -- Twin | Single
  wheelchair text default 'No'     -- Yes | No
);
create index if not exists members_country on members(country);

-- 3. 초청장 신청
create table if not exists invitations (
  id bigint generated always as identity primary key,
  country text not null,
  title text default '',
  member_ids jsonb default '[]',
  status text default 'pending',   -- pending | approved (승인은 관리자만)
  no text default '',              -- 승인 시 부여
  approved_at text default ''      -- 승인 시 부여
);
create index if not exists invitations_country on invitations(country);

-- 4. 총기 정보
create table if not exists firearms (
  id bigint generated always as identity primary key,
  country text not null,
  owner text default '',
  manufacturer text default '',
  model text default '',
  serial text default '',
  type text default '',
  caliber text default '',
  photo_full text default '',      -- base64 축소 이미지
  photo_num text default ''
);
create index if not exists firearms_country on firearms(country);

-- 5. 총기 제출/확인서 (스코프 단위: 전체 = '*ALL*' 또는 세부소속명)
create table if not exists firearm_submissions (
  country text not null,
  grp text not null default '*ALL*',
  submitted_at text default '',
  status text default 'pending',
  no text default '',
  approved_at text default '',
  primary key (country, grp)
);

-- 6. 인보이스 신청
create table if not exists invoices (
  id bigint generated always as identity primary key,
  country text not null,
  title text default '',           -- 수취인(전체/세부소속)
  member_ids jsonb default '[]',
  addr text default '',            -- 신청 시점의 수취인 주소 스냅샷
  status text default 'pending',
  no text default '',
  approved_at text default '',
  account text default ''          -- 승인 시 조직위가 입력하는 납부 계좌
);
create index if not exists invoices_country on invoices(country);

-- 7. 인보이스 수취인 주소 (수취인 종류별 필수 등록)
create table if not exists invoice_addresses (
  country text not null,
  grp text not null default '*ALL*',
  addr text default '',
  primary key (country, grp)
);

-- RLS: 데모 단계에서는 anon 전체 허용. 실서비스 전 반드시 국가별/관리자 정책으로 교체하세요.
alter table activation_requests enable row level security;
alter table npc_directory enable row level security;
alter table members enable row level security;
alter table invitations enable row level security;
alter table firearms enable row level security;
alter table firearm_submissions enable row level security;
alter table invoices enable row level security;
alter table invoice_addresses enable row level security;

do $$ declare t text;
begin
  foreach t in array array['activation_requests','npc_directory','members','invitations','firearms','firearm_submissions','invoices','invoice_addresses'] loop
    execute format('drop policy if exists anon_all on %I', t);
    execute format('create policy anon_all on %I for all to anon using (true) with check (true)', t);
  end loop;
end $$;

-- 주의: 승인 관련 컬럼(status, no, approved_at, account)은 원칙적으로 관리자만 변경해야 합니다.
-- 실서비스에서는 위 anon_all 정책을 제거하고,
--  · NPC: 자국(country) 행만 select/insert/update/delete (승인 컬럼 제외)
--  · 관리자(admin.html): service role 키 또는 별도 인증 기반 정책
-- 으로 교체하세요.

-- ===== 실서비스 전환용 (anon_all 제거 후 적용) =====
-- create or replace function my_country() returns text language sql stable as $$
--   select country from npc_directory where user_id = auth.uid() and active limit 1
-- $$;
-- create policy ar_insert on activation_requests for insert to anon with check (true);
-- create policy ar_select on activation_requests for select to anon using (true);
-- create policy dir_select on npc_directory for select to anon using (true);
-- create policy m_rw  on members             for all to authenticated using (country=my_country()) with check (country=my_country());
-- create policy i_rw  on invitations         for all to authenticated using (country=my_country()) with check (country=my_country());
-- create policy f_rw  on firearms            for all to authenticated using (country=my_country()) with check (country=my_country());
-- create policy fs_rw on firearm_submissions for all to authenticated using (country=my_country()) with check (country=my_country());
-- create policy v_rw  on invoices            for all to authenticated using (country=my_country()) with check (country=my_country());
-- create policy va_rw on invoice_addresses   for all to authenticated using (country=my_country()) with check (country=my_country());
