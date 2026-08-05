-- =====================================================================
-- Admin account login migration  (Changwon 2026 WSPS WCH — NPC Portal)
-- Run in Supabase SQL Editor (project tkdvyxouknhjhaqjrotb). Idempotent.
--
-- 목적: service_role 키 공유 → 개별 관리자 계정(이메일+비밀번호) 전환 (갈래 1).
--   · admins 테이블 + is_admin() 로 관리자 판별
--   · 12개 테이블 + storage 에 관리자 정책 추가 (기존 NPC 정책은 그대로)
--   · NPC 가 만질 수 없어야 하는 컬럼은 트리거로 보호 (grant 확대 보완)
--   · Auth 관리 API(초대·비밀번호 설정·원클릭 접속·계정 삭제)는 갈래 2 —
--     admin.html 이 실행 시점에만 service key 를 요구하는 방식 유지 (단계적)
--
-- 실행 순서:
--   1) 이 SQL 실행
--   2) 최초 관리자 등록 (아래 [최초 관리자 등록] 참고)
--   3) 새 admin.html 배포  — 이 순서면 서비스 중단 없음
--     (구 admin.html 은 service key 로 계속 동작; 이 SQL 은 기존 동작을 제거하지 않음)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 1) admins 테이블 + is_admin()
-- ---------------------------------------------------------------------
create table if not exists admins (
  user_id      uuid primary key references auth.users(id) on delete cascade,
  email        text not null,
  display_name text default '',
  added_at     timestamptz default now()
);
alter table admins enable row level security;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as
$$ select exists(select 1 from admins where user_id = auth.uid()) $$;
revoke all on function is_admin() from public;
grant execute on function is_admin() to anon, authenticated;

-- 관리자는 관리자 명단을 볼 수 있음 (관리는 service_role/SQL 전용 = 단계적)
drop policy if exists admins_sel on admins;
create policy admins_sel on admins for select to authenticated using (is_admin());
grant select on admins to authenticated;

-- ---------------------------------------------------------------------
-- 2) 관리자 정책 — 기존 NPC 정책(rw_own 등) 옆에 추가 (permissive OR)
--    members, invitations, invoices, firearms, firearm_submissions,
--    invoice_addresses, group_flights, manual_docs, oc_settings,
--    activation_requests, npc_directory  (11개, FOR ALL)
--    + doc_register (SELECT 전용) = 12개
-- ---------------------------------------------------------------------
do $$ declare t text;
begin
  foreach t in array array['members','invitations','invoices','firearms',
    'firearm_submissions','invoice_addresses','group_flights','manual_docs',
    'oc_settings','activation_requests','npc_directory'] loop
    execute format('drop policy if exists adm_rw on %I', t);
    execute format('create policy adm_rw on %I for all to authenticated using (is_admin()) with check (is_admin())', t);
  end loop;
end $$;

-- doc_register: 장부는 관리자도 조회만 (번호 발급은 issue_docno 함수로만)
drop policy if exists adm_sel on doc_register;
create policy adm_sel on doc_register for select to authenticated using (is_admin());
grant select on doc_register to authenticated;

-- ---------------------------------------------------------------------
-- 3) 이전에 회수했던 테이블 권한 복구 (정책이 is_admin() 으로 게이트하므로
--    NPC 에는 여전히 정책이 없어 차단됨 — 아래 4) 트리거가 컬럼 단위 보완)
-- ---------------------------------------------------------------------
grant update on invitations to authenticated;
grant update on invoices to authenticated;
grant update on firearm_submissions to authenticated;
grant update, delete on activation_requests to authenticated;
grant insert, update, delete on npc_directory to authenticated;
grant insert, update on oc_settings to authenticated;
grant select, insert, update, delete on manual_docs to authenticated;

-- ---------------------------------------------------------------------
-- 4) 컬럼 보호 트리거
--    firearm_submissions: NPC 는 자국 fs_upd 정책으로 UPDATE 가능해지므로
--      승인·발급·편집 컬럼(status,no,approved_at,reg_no,issued_at,doc_html)을 보호
--    npc_directory: NPC 는 자기 행 dir_upd 정책으로 UPDATE 가능하므로
--      country,email,created_at 보호 (active,user_id 만 허용 — 기존과 동일)
-- ---------------------------------------------------------------------
create or replace function guard_protected_cols() returns trigger
language plpgsql as $$
begin
  if session_user in ('postgres','supabase_admin')
     or coalesce(auth.jwt()->>'role','') = 'service_role'
     or is_admin() then
    return new;
  end if;
  if tg_table_name = 'firearm_submissions' then
    if (new.status      is distinct from old.status)
       or (new.no          is distinct from old.no)
       or (new.approved_at is distinct from old.approved_at)
       or (new.reg_no      is distinct from old.reg_no)
       or (new.issued_at   is distinct from old.issued_at)
       or (new.doc_html    is distinct from old.doc_html) then
      raise exception 'protected columns can only be changed by an administrator';
    end if;
  elsif tg_table_name = 'npc_directory' then
    if (new.country       is distinct from old.country)
       or (new.email      is distinct from old.email)
       or (new.created_at is distinct from old.created_at) then
      raise exception 'protected columns can only be changed by an administrator';
    end if;
  end if;
  return new;
end $$;

drop trigger if exists guard_cols on firearm_submissions;
create trigger guard_cols before update on firearm_submissions
  for each row execute function guard_protected_cols();
drop trigger if exists guard_cols on npc_directory;
create trigger guard_cols before update on npc_directory
  for each row execute function guard_protected_cols();

-- ---------------------------------------------------------------------
-- 5) issue_docno: 관리자도 실행 가능 (함수 내부에서 권한 검증)
-- ---------------------------------------------------------------------
create or replace function issue_docno(
  p_type text, p_country text, p_reference text, p_source_table text, p_source_key text
) returns bigint
language plpgsql
security definer
set search_path = public
as $$
declare v_no bigint;
begin
  if not ( session_user in ('postgres','supabase_admin')
           or coalesce(auth.jwt()->>'role','') = 'service_role'
           or is_admin() ) then
    raise exception 'issue_docno: administrators only';
  end if;
  insert into doc_register(doc_type, country, reference, source_table, source_key)
    values (p_type, p_country, p_reference, p_source_table, p_source_key)
    on conflict (source_table, source_key) do nothing
    returning docno into v_no;
  if v_no is null then
    select docno into v_no from doc_register
      where source_table = p_source_table and source_key = p_source_key;
  end if;
  return v_no;
end
$$;
revoke all on function issue_docno(text,text,text,text,text) from public;
grant execute on function issue_docno(text,text,text,text,text) to authenticated, service_role;

-- ---------------------------------------------------------------------
-- 6) Storage(firearms): 관리자 읽기(서명 URL)·삭제 정책 추가
-- ---------------------------------------------------------------------
drop policy if exists firearms_rd_admin on storage.objects;
create policy firearms_rd_admin on storage.objects for select to authenticated
  using (bucket_id = 'firearms' and is_admin());
drop policy if exists firearms_del_admin on storage.objects;
create policy firearms_del_admin on storage.objects for delete to authenticated
  using (bucket_id = 'firearms' and is_admin());

-- ---------------------------------------------------------------------
-- [최초 관리자 등록] — 이 두 단계는 대시보드에서 직접:
--   1) Supabase → Authentication → Users → Add user
--      (이메일+비밀번호 입력, "Auto Confirm User" 체크)
--   2) 아래 SQL 로 admins 에 등록 (이메일만 바꿔서):
--
-- insert into admins(user_id, email, display_name)
--   select id, email, '관리자 이름' from auth.users where email = 'admin@example.org'
--   on conflict (user_id) do nothing;
--
-- 관리자 제거(회수):  delete from admins where email = 'admin@example.org';
--   (auth.users 계정 자체 삭제는 Dashboard → Authentication → Users 에서)
-- ---------------------------------------------------------------------

-- ---------------------------------------------------------------------
-- Verify
-- ---------------------------------------------------------------------
select 'admins_table' k, coalesce((select 'ok' from information_schema.tables where table_name='admins'),'MISSING') v
union all select 'is_admin_fn', coalesce((select 'ok' from pg_proc where proname='is_admin'),'MISSING')
union all select 'adm_rw_policies(11)', (select count(*)::text from pg_policies where policyname='adm_rw')
union all select 'doc_register_adm_sel', coalesce((select 'ok' from pg_policies where tablename='doc_register' and policyname='adm_sel'),'MISSING')
union all select 'storage_adm_policies(2)', (select count(*)::text from pg_policies where schemaname='storage' and tablename='objects' and policyname in ('firearms_rd_admin','firearms_del_admin'))
union all select 'guard_triggers(2)', (select count(*)::text from pg_trigger where tgname='guard_cols' and not tgisinternal)
union all select 'issue_docno_gate', case when exists(select 1 from pg_proc where proname='issue_docno' and prosrc like '%is_admin%') then 'ok' else 'MISSING' end
union all select 'admin_count', (select count(*)::text from admins);

-- =====================================================================
-- ROLLBACK (uncomment to revert)
-- do $$ declare t text; begin
--   foreach t in array array['members','invitations','invoices','firearms',
--     'firearm_submissions','invoice_addresses','group_flights','manual_docs',
--     'oc_settings','activation_requests','npc_directory'] loop
--     execute format('drop policy if exists adm_rw on %I', t);
--   end loop; end $$;
-- drop policy if exists adm_sel on doc_register;
-- drop policy if exists admins_sel on admins;
-- drop policy if exists firearms_rd_admin on storage.objects;
-- drop policy if exists firearms_del_admin on storage.objects;
-- drop trigger if exists guard_cols on firearm_submissions;
-- drop trigger if exists guard_cols on npc_directory;
-- drop function if exists guard_protected_cols();
-- revoke update on invitations, invoices, firearm_submissions from authenticated;
-- revoke update, delete on activation_requests from authenticated;
-- revoke insert, update, delete on npc_directory from authenticated;
-- revoke insert, update on oc_settings from authenticated;
-- revoke all on manual_docs from authenticated;
-- revoke select on doc_register from authenticated;
-- grant update (active, user_id) on npc_directory to authenticated;
-- grant update (country, grp, submitted_at) on firearm_submissions to authenticated;
-- (issue_docno 는 doc_register_migration.sql 원본으로 재실행하여 복원)
-- drop function if exists is_admin(); drop table if exists admins;
-- =====================================================================
