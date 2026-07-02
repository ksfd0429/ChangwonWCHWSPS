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
  wheelchair text default 'No',    -- Yes | No
  follow_flight text default 'No'  -- Yes = 그룹별 항공일정을 따름
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
  account text default '',         -- 승인 시 조직위가 입력하는 납부 계좌
  items jsonb default '[]'         -- 항목 스냅샷(초안 생성 시 · admin 편집 가능)
);
create index if not exists invoices_country on invoices(country);

-- 7-a. 그룹별 항공일정 (follow_flight='Yes' 인원에게 자동 반영)
create table if not exists group_flights (
  country text not null, grp text not null default '*ALL*',
  arrive text default '', arr_flight text default '', arr_time text default '',
  depart text default '', dep_flight text default '', dep_time text default '',
  primary key (country,grp)
);

-- 7. 인보이스 수취인 주소 (수취인 종류별 필수 등록)
create table if not exists invoice_addresses (
  country text not null,
  grp text not null default '*ALL*',
  addr text default '',
  primary key (country, grp)
);


-- 8. 운영 설정 (납부 계좌 등 · admin에서 관리)
create table if not exists oc_settings (
  key text primary key,
  value text default ''
);
insert into oc_settings(key,value) values('banking','{"holder":"Korea Shooting Federation for Disabled","account":"180-012-197038","bank":"Shinhan Bank","swift":"SHBKKRSE","addr":"134, Sangmujayu-ro, Seo-gu, Gwangju-city 61963, Korea","note":"Please make all the payments in USD Dollar. Any bank fees or charges Must be paid by the payee on top of the balance at the time of payment. Any outstanding fees must be paid prior to collection of start numbers."}') on conflict (key) do nothing;
insert into oc_settings(key,value) values('pricing','{"single":300,"twin":220,"tr1":280,"tr2":450,"firearm":30,"training":5}') on conflict (key) do nothing;


-- 9. 총기 사진 Storage 버킷 (DB와 별도 1GB · public 읽기)
insert into storage.buckets (id, name, public) values ('firearms','firearms', true) on conflict (id) do nothing;
update storage.buckets set file_size_limit=3145728, allowed_mime_types=array['image/jpeg'] where id='firearms'; -- JPEG만 · 파일당 3MB
drop policy if exists firearms_up on storage.objects;
drop policy if exists firearms_rd on storage.objects;
drop policy if exists firearms_del on storage.objects;
create policy firearms_up on storage.objects for insert to anon, authenticated with check (bucket_id='firearms');
create policy firearms_rd on storage.objects for select to anon, authenticated using (bucket_id='firearms');
create policy firearms_del on storage.objects for delete to anon, authenticated using (bucket_id='firearms');

-- RLS 활성화
alter table activation_requests enable row level security;
alter table npc_directory enable row level security;
alter table members enable row level security;
alter table invitations enable row level security;
alter table firearms enable row level security;
alter table firearm_submissions enable row level security;
alter table invoices enable row level security;
alter table invoice_addresses enable row level security;
alter table group_flights enable row level security;
alter table oc_settings enable row level security;

-- ============================================================
-- 실서비스 RLS 전환 (v4) — 데모 전체허용 제거, 국가별 정책 적용
-- 원칙: NPC(로그인)는 자국 데이터만. 승인/발급 컬럼(status·no·approved_at·account)과
--       설정/디렉터리 관리는 service role(마스터 관리자)만 변경 가능.
-- ============================================================

-- 0) 데모 정책 제거
do $$ declare t text;
begin
  foreach t in array array['activation_requests','npc_directory','members','invitations','firearms','firearm_submissions','invoices','invoice_addresses','group_flights','oc_settings'] loop
    execute format('drop policy if exists anon_all on %I', t);
  end loop;
end $$;

-- 1) 로그인 사용자의 국가 판별 (초대 직후 user_id 미기록 대비 email 폴백)
create or replace function my_country() returns text
language sql stable security definer set search_path = public as
$$ select country from npc_directory
   where user_id = auth.uid()
      or (email <> '' and email = coalesce(auth.jwt()->>'email',''))
   limit 1 $$;
grant execute on function my_country() to anon, authenticated;

-- 2) activation_requests: 신청(pending 강제)+조회는 공개, 수정/삭제는 관리자만
drop policy if exists ar_sel on activation_requests;
drop policy if exists ar_ins on activation_requests;
create policy ar_sel on activation_requests for select to anon, authenticated using (true);
create policy ar_ins on activation_requests for insert to anon, authenticated
  with check (coalesce(status,'pending')='pending');
revoke update, delete on activation_requests from anon, authenticated;

-- 3) npc_directory: 조회 공개(국가 라우팅용), 본인 행의 active/user_id만 갱신
drop policy if exists dir_sel on npc_directory;
drop policy if exists dir_upd on npc_directory;
create policy dir_sel on npc_directory for select to anon, authenticated using (true);
create policy dir_upd on npc_directory for update to authenticated
  using (user_id = auth.uid() or email = coalesce(auth.jwt()->>'email',''))
  with check (user_id = auth.uid() or email = coalesce(auth.jwt()->>'email',''));
revoke insert, update, delete on npc_directory from anon, authenticated;
grant update (active, user_id) on npc_directory to authenticated;

-- 4) 자국 전체 권한 테이블 (승인 개념 없음)
do $$ declare t text;
begin
  foreach t in array array['members','firearms','group_flights','invoice_addresses'] loop
    execute format('drop policy if exists rw_own on %I', t);
    execute format('create policy rw_own on %I for all to authenticated using (country = my_country()) with check (country = my_country())', t);
    execute format('revoke all on %I from anon', t);
  end loop;
end $$;

-- 5) invitations: 자국 조회 + pending 신청 + 미승인 철회만. UPDATE 전면 불가(승인=관리자)
drop policy if exists i_sel on invitations;
drop policy if exists i_ins on invitations;
drop policy if exists i_del on invitations;
create policy i_sel on invitations for select to authenticated using (country = my_country());
create policy i_ins on invitations for insert to authenticated
  with check (country = my_country() and coalesce(status,'pending')='pending'
              and coalesce(no,'')='' and coalesce(approved_at,'')='');
create policy i_del on invitations for delete to authenticated
  using (country = my_country() and status <> 'approved');
revoke update on invitations from anon, authenticated;
revoke all on invitations from anon;

-- 6) invoices: invitations와 동일 + 계좌 스냅샷(account)도 신청 시 빈 값 강제
drop policy if exists v_sel on invoices;
drop policy if exists v_ins on invoices;
drop policy if exists v_del on invoices;
create policy v_sel on invoices for select to authenticated using (country = my_country());
create policy v_ins on invoices for insert to authenticated
  with check (country = my_country() and coalesce(status,'pending')='pending'
              and coalesce(no,'')='' and coalesce(approved_at,'')='' and coalesce(account,'')='');
create policy v_del on invoices for delete to authenticated
  using (country = my_country() and status <> 'approved');
revoke update on invoices from anon, authenticated;
revoke all on invoices from anon;

-- 7) firearm_submissions: 자국 제출/재제출 — 갱신은 submitted_at(+키)만
drop policy if exists fs_sel on firearm_submissions;
drop policy if exists fs_ins on firearm_submissions;
drop policy if exists fs_upd on firearm_submissions;
create policy fs_sel on firearm_submissions for select to authenticated using (country = my_country());
create policy fs_ins on firearm_submissions for insert to authenticated
  with check (country = my_country() and coalesce(status,'pending')='pending'
              and coalesce(no,'')='' and coalesce(approved_at,'')='');
create policy fs_upd on firearm_submissions for update to authenticated
  using (country = my_country()) with check (country = my_country());
revoke update on firearm_submissions from anon, authenticated;
grant update (country, grp, submitted_at) on firearm_submissions to authenticated;
revoke all on firearm_submissions from anon;

-- 8) oc_settings: 읽기 공개(요금표·계좌 표시), 쓰기는 관리자만
drop policy if exists s_sel on oc_settings;
create policy s_sel on oc_settings for select to anon, authenticated using (true);
revoke insert, update, delete on oc_settings from anon, authenticated;

-- 9) Storage(firearms): 읽기 공개, 업로드/삭제는 로그인 + 자국 폴더만
drop policy if exists firearms_up on storage.objects;
drop policy if exists firearms_rd on storage.objects;
drop policy if exists firearms_del on storage.objects;
create policy firearms_rd on storage.objects for select to anon, authenticated
  using (bucket_id = 'firearms');
create policy firearms_up on storage.objects for insert to authenticated
  with check (bucket_id = 'firearms' and (storage.foldername(name))[1] = my_country());
create policy firearms_del on storage.objects for delete to authenticated
  using (bucket_id = 'firearms' and (storage.foldername(name))[1] = my_country());

-- (v4 적용 완료: 2026-07-03 — 데모 전체허용 정책은 폐기됨)
