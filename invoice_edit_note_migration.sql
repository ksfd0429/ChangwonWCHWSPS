-- 인보이스 수정 사유(조직위 → NPC 공개) — Supabase SQL Editor에서 실행. 멱등.
-- edited_at : 관리자가 항목 편집 또는 문서 직접 편집을 저장한 날짜. 값이 있으면 승인 시 수정 사유 입력을 요구한다.
-- edit_note : 관리자가 직접 작성한 수정 사유. 해당 NPC가 포털의 인보이스 미리보기에서 함께 읽는다.
-- NPC의 select 정책은 country = my_country() 이므로 두 컬럼은 자동으로 자국 인보이스에서만 읽힌다.

alter table invoices add column if not exists edit_note text;
alter table invoices add column if not exists edited_at text;

-- 검증
select 'invoices.edit_note' k, coalesce((select 'ok' from information_schema.columns where table_name='invoices' and column_name='edit_note'),'MISSING') v
union all select 'invoices.edited_at', coalesce((select 'ok' from information_schema.columns where table_name='invoices' and column_name='edited_at'),'MISSING');
