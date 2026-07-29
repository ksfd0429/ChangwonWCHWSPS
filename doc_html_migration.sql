-- 문서 직접 편집(원본 문서 본문 저장) — Supabase SQL Editor에서 실행. 멱등.
-- 관리자가 각국이 제출한 문서를 직접 수정하면, 수정된 본문(HTML)이 원본 레코드에 저장된다.
-- 값이 있으면 문서 렌더 시 자동 생성 본문 대신 이 내용을 사용한다. (머리말/꼬리말/서명/문서번호는 항상 자동)

alter table invitations          add column if not exists doc_html text;
alter table invoices             add column if not exists doc_html text;
alter table firearm_submissions  add column if not exists doc_html text;

-- 검증
select 'invitations.doc_html'         k, coalesce((select 'ok' from information_schema.columns where table_name='invitations'         and column_name='doc_html'),'MISSING') v
union all select 'invoices.doc_html',            coalesce((select 'ok' from information_schema.columns where table_name='invoices'            and column_name='doc_html'),'MISSING')
union all select 'firearm_submissions.doc_html', coalesce((select 'ok' from information_schema.columns where table_name='firearm_submissions' and column_name='doc_html'),'MISSING');
