# Changwon 2026 WCH — NPC Submission Portal

각국(NPC)이 링크 하나로 접속해 명단·초청장·총기·인보이스를 제출하는 시스템.
백엔드는 Supabase(사용자에게 비노출), 프론트는 대회 브랜드 단일 파일.

## 파일
- `index.html` / `submit.html` — NPC 제출 포털 (동일 내용, index가 Pages 진입점)
- `admin.html` — 조직위 마스터 콘솔 (활성화 승인 / 문서 승인 / 취합)
- `assets/` — 로고·국기
- `supabase_schema.sql` — DB 스키마 v3 (이미 실행됨)

## 상태 (2026-07-02)
- Supabase 프로젝트 연결 완료: URL·publishable key 주입됨, 스키마 실행됨, Site URL 설정됨.
- **배포**: 이 폴더를 리포(ChangwonWCHWSPS)에 올리고 Settings → Pages 활성화만 하면 됨.

## 계정 파이프라인
국가 선택 → Account Activation Request(공식 이메일) → [관리자 알림 메일 수신] →
admin.html 승인(→ 초대 메일 자동 발송) → 링크에서 비밀번호 설정 → 국가+비밀번호 로그인.
비밀번호 리셋도 등록 이메일로만.

## 관리자 (admin.html)
- 로그인: loc_7766 / 142857 (프로토타입 계정)
- **초대 메일 발송까지 하려면** 로그인 화면의 Service key 칸에 Supabase secret key
  (대시보드 → Settings → API Keys → Secret keys) 입력 — 메모리에만 보관됨.
  미입력 시 승인 상태 기록만 가능.
- 신규 활성화 요청 알림: ksfd0427@gmail.com (포털 상단 ADMIN_EMAIL 상수로 변경 가능,
  FormSubmit 최초 1회 확인 메일 승인 필요)

## 남은 운영 작업
- Auth > Emails: 초대/리셋 템플릿 문구·발신자명 대회 브랜드로 교체 (자체 SMTP 권장)
- 실서비스 전 RLS를 국가별 정책으로 교체 (schema 하단 주석 참조)
- 산탄총 탄약 카탈로그 모듈
