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
- 로그인: **service_role(legacy) key 입력이 곧 인증** (ID/비밀번호 없음).
  대시보드 → Settings → API Keys → service_role(legacy). 브라우저 세션 메모리에만 보관.
- RLS v4 적용됨: NPC는 자국 데이터만, 승인/발급(status·no·approved_at·account)은 service key로만 가능.
- 신규 활성화 요청 알림: ksfd0427@gmail.com (포털 상단 ADMIN_EMAIL 상수로 변경 가능,
  FormSubmit 최초 1회 확인 메일 승인 필요)

## 운영 메모 (2026-07-03)
- RLS 국가별 정책(v4) 라이브 적용·검증 완료 (schema 파일 참조)
- Custom SMTP: 설정 완료, **Gmail 앱 비밀번호만 입력 필요** (Auth → Emails → SMTP Settings → Password → Save)
- keep-alive: `.github/workflows/keepalive.yml` — 주 2회 REST 핑으로 무료플랜 일시정지 방지 (Actions 탭에서 활성 확인)
- i18n: 47개 언어 병기 + RTL + AI 번역 고지 (문서는 영어 단독)

## 남은 작업
- 산탄총 탄약 카탈로그 모듈 (카탈로그 확정 대기)
- admin 엑셀 내보내기, 하위 관리자 계정, admin 감사 로그
