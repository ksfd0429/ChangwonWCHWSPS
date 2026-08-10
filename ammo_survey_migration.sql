-- ============================================================
-- 창원 2026 WCH — 산탄총 실탄 수요조사 (Shotgun Ammunition Demand Survey)
-- 작성: 2026-08-09
-- 원칙: NPC(로그인)는 자국 데이터만 읽고 쓴다. 카탈로그와 제출확정(문서번호)은
--       service role(마스터 관리자)만 변경한다. 기존 스키마의 my_country() 를 재사용한다.
-- 통화: EUR (견적 원본 통화 그대로). 운송비는 본 테이블에 포함하지 않는다.
-- 상한: 선수 1인 1일 400발 (구매 한도). 최소 단위 25발.
-- ============================================================

-- ------------------------------------------------------------
-- 1) 카탈로그
-- ------------------------------------------------------------
create table if not exists ammo_products (
  id          bigint generated always as identity primary key,
  name        text not null,                 -- 제품명 (RC-3 Champion 등)
  discipline  text not null default 'TRAP',
  gauge       text not null default '12ga',
  pack        int  not null default 250,     -- 1케이스 발수
  price_eur   numeric(10,2) not null,        -- 케이스당 단가 (EUR)
  active      boolean not null default true,
  sort_order  int  not null default 0
);

-- ------------------------------------------------------------
-- 2) 수요조사 내역 — 선수 × 날짜 × 제품 1행
-- ------------------------------------------------------------
create table if not exists ammo_survey (
  id          bigint generated always as identity primary key,
  country     text not null,
  member_id   bigint not null references members(id) on delete cascade,
  use_date    date not null,
  product_id  bigint not null references ammo_products(id),
  rounds      int  not null check (rounds > 0 and rounds % 25 = 0),
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now(),
  unique (member_id, use_date, product_id)
);
create index if not exists ammo_survey_country on ammo_survey(country);
create index if not exists ammo_survey_member  on ammo_survey(member_id);

-- ------------------------------------------------------------
-- 3) 국가별 제출 상태
-- ------------------------------------------------------------
create table if not exists ammo_survey_meta (
  country      text primary key,
  status       text not null default 'draft',   -- draft | submitted | received
  submitted_at timestamptz,
  doc_no       text default '',                 -- 확인서 문서번호 (관리자 부여)
  remarks      text default '',
  updated_at   timestamptz not null default now()
);

-- ------------------------------------------------------------
-- 4) 1일 400발 상한 강제 (DB 레벨)
--    화면에서도 막지만, 우회 입력을 방지하기 위해 트리거로 이중 확인한다.
-- ------------------------------------------------------------
create or replace function ammo_daily_cap() returns trigger
language plpgsql as $$
declare tot int;
begin
  select coalesce(sum(rounds),0) into tot
    from ammo_survey
   where member_id = new.member_id
     and use_date  = new.use_date
     and id is distinct from new.id;
  if tot + new.rounds > 400 then
    raise exception 'Daily limit exceeded: % rounds on % (max 400 per athlete per day)', tot + new.rounds, new.use_date;
  end if;
  new.updated_at := now();
  return new;
end $$;

drop trigger if exists ammo_survey_cap on ammo_survey;
create trigger ammo_survey_cap before insert or update on ammo_survey
  for each row execute function ammo_daily_cap();

-- 제출 완료(submitted/received) 국가는 NPC가 더 이상 수정하지 못하도록 잠근다.
create or replace function ammo_survey_locked() returns trigger
language plpgsql as $$
declare st text;
begin
  select status into st from ammo_survey_meta
   where country = coalesce(new.country, old.country);
  if st in ('submitted','received') and auth.role() <> 'service_role' then
    raise exception 'Survey already submitted. Please withdraw it first.';
  end if;
  return coalesce(new, old);
end $$;

drop trigger if exists ammo_survey_lock on ammo_survey;
create trigger ammo_survey_lock before insert or update or delete on ammo_survey
  for each row execute function ammo_survey_locked();

-- ------------------------------------------------------------
-- 5) RLS
-- ------------------------------------------------------------
alter table ammo_products    enable row level security;
alter table ammo_survey      enable row level security;
alter table ammo_survey_meta enable row level security;

-- 카탈로그: 로그인 사용자 조회만, 변경은 service role
drop policy if exists ap_sel on ammo_products;
create policy ap_sel on ammo_products for select to authenticated using (true);
revoke all on ammo_products from anon;
revoke insert, update, delete on ammo_products from authenticated;

-- 수요조사 내역: 자국 전체 권한
drop policy if exists as_rw on ammo_survey;
create policy as_rw on ammo_survey for all to authenticated
  using (country = my_country()) with check (country = my_country());
revoke all on ammo_survey from anon;

-- 제출 상태: 자국 행 조회/생성/상태 전환만. doc_no 는 관리자만.
drop policy if exists asm_sel on ammo_survey_meta;
drop policy if exists asm_ins on ammo_survey_meta;
drop policy if exists asm_upd on ammo_survey_meta;
create policy asm_sel on ammo_survey_meta for select to authenticated
  using (country = my_country());
create policy asm_ins on ammo_survey_meta for insert to authenticated
  with check (country = my_country() and coalesce(status,'draft') in ('draft','submitted')
              and coalesce(doc_no,'') = '');
create policy asm_upd on ammo_survey_meta for update to authenticated
  using (country = my_country())
  with check (country = my_country() and status in ('draft','submitted'));
revoke all on ammo_survey_meta from anon;
revoke delete on ammo_survey_meta from authenticated;
grant update (status, submitted_at, remarks, updated_at) on ammo_survey_meta to authenticated;

-- ------------------------------------------------------------
-- 6) 카탈로그 초기 데이터 (중앙코리아 견적 2026-08-03)
-- ------------------------------------------------------------
insert into ammo_products (name, discipline, gauge, pack, price_eur, sort_order) values
 ('RC-3 Champion',        'TRAP','12ga',250,180,1),
 ('RC-4 Champion',        'TRAP','12ga',250,190,2),
 ('RC-2.025',             'TRAP','12ga',250,170,3),
 ('RC-4 Red Shot',        'TRAP','12ga',250,200,4),
 ('NS-4 Fluo',            'TRAP','12ga',250,180,5),
 ('NS-4 Exclusiva',       'TRAP','12ga',250,190,6),
 ('NS-4 C7 Perfacta',     'TRAP','12ga',250,200,7),
 ('NSI Super Veloche',    'TRAP','12ga',250,170,8),
 ('Clever Pro extra evo', 'TRAP','12ga',250,200,9),
 ('Clever 9 Gold',        'TRAP','12ga',250,180,10),
 ('Trust T3',             'TRAP','12ga',250,170,11),
 ('S&B T2 Super',         'TRAP','12ga',250,160,12)
on conflict do nothing;

-- ------------------------------------------------------------
-- 7) 설정값 (마감일 · 공개 여부) — 기존 oc_settings 재사용
-- ------------------------------------------------------------
insert into oc_settings (key, value) values
 ('ammo_survey', '{"open": false, "deadline": "2026-08-17", "currency": "EUR", "daily_cap": 400, "step": 25, "pack": 250}')
on conflict (key) do update set value = excluded.value;

-- ------------------------------------------------------------
-- 8) 검증
-- ------------------------------------------------------------
select 'ammo_products' t, count(*) n from ammo_products
union all select 'ammo_survey', count(*) from ammo_survey
union all select 'ammo_survey_meta', count(*) from ammo_survey_meta
union all select 'oc_settings.ammo_survey', count(*) from oc_settings where key='ammo_survey';
