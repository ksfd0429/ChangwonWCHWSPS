-- ============================================================================
--  Changwon 2026 WSPS World Championships — Accommodation module
--  Migration: accommodation_migration.sql   (v2 — no-login survey model)
--
--  DESIGN
--  This is a SURVEY, not a portal section. Requiring a portal login would put
--  a wall in front of the people who actually fill it in (team managers, who
--  are often not the account holder). So:
--
--    * anon has NO table access at all — not select, not insert, nothing
--    * everything goes through three SECURITY DEFINER functions
--    * submitting needs no account; it returns a random edit_code
--    * the submitter bookmarks  accommodation.html?c=<edit_code>  to come back
--    * a logged-in NPC gets country auto-filled and verified=true
--    * the LOC reads the table directly with the service_role key
--
--  This keeps the surface tiny: anon can only call three functions with
--  validated arguments, and can only ever see the single row whose secret
--  code it already holds.
-- ============================================================================

-- ---------------------------------------------------------------- table -----
create table if not exists accommodation (
  id             bigint generated always as identity primary key,
  edit_code      text not null unique
                 default substr(replace(gen_random_uuid()::text,'-',''),1,10),

  country        text not null,          -- NPC / country code, e.g. 'KOR'
  country_name   text default '',
  verified       boolean default false,  -- true = submitted from a portal session

  team_name      text default '',
  contact_name   text default '',
  contact_email  text default '',

  n_athletes     int  default 0,
  n_officials    int  default 0,         -- includes coaches & personal assistants
  n_male         int  default 0,
  n_female       int  default 0,

  check_in       text default '',        -- 'YYYY-MM-DD', as members.arrive
  check_out      text default '',

  choice_1       text default '',        -- 'GMA' | 'GCC' | 'ISQ'
  choice_2       text default '',
  choice_3       text default '',

  rooms_single   int  default 0,
  rooms_twin     int  default 0,

  dietary        text default '',
  notes          text default '',

  status          text default 'pending',   -- pending | approved
  submitted_at    text default '',
  updated_at      text default '',
  no              text default '',
  approved_at     text default '',
  allocated_hotel text default ''
);

create index if not exists accommodation_country on accommodation(country);
create index if not exists accommodation_status  on accommodation(status);
create unique index if not exists accommodation_team
  on accommodation(country, lower(contact_email));

-- ------------------------------------------------------------ constraints ---
-- The same rules the form enforces, so a bad payload can never land even if
-- someone calls the function directly.
alter table accommodation drop constraint if exists acc_choices_distinct;
alter table accommodation add  constraint acc_choices_distinct
  check (choice_1 <> choice_2 and choice_2 <> choice_3 and choice_1 <> choice_3);

alter table accommodation drop constraint if exists acc_choices_present;
alter table accommodation add  constraint acc_choices_present
  check (choice_1 <> '' and choice_2 <> '' and choice_3 <> '');

alter table accommodation drop constraint if exists acc_stay_order;
alter table accommodation add  constraint acc_stay_order
  check (check_in <> '' and check_out <> '' and check_out > check_in);

alter table accommodation drop constraint if exists acc_pax_positive;
alter table accommodation add  constraint acc_pax_positive
  check (n_athletes + n_officials > 0);

alter table accommodation drop constraint if exists acc_gender_sum;
alter table accommodation add  constraint acc_gender_sum
  check (n_male + n_female = n_athletes + n_officials);

-- Room occupancy is deliberately NOT validated against headcount: delegations
-- include couples sharing, accompanying family, staff doubling up. Rooms are
-- counted as rooms.
alter table accommodation drop constraint if exists acc_beds_cover;
alter table accommodation drop constraint if exists acc_rooms_positive;
alter table accommodation add  constraint acc_rooms_positive
  check (rooms_single + rooms_twin > 0);

alter table accommodation drop constraint if exists acc_country_shape;
alter table accommodation add  constraint acc_country_shape
  check (country ~ '^[A-Z]{3}$');       -- keeps aggregation clean

-- ------------------------------------------------------------------- RLS ----
alter table accommodation enable row level security;
-- deliberately NO policies: with RLS on and no policy, direct access is denied
-- for anon and authenticated alike. service_role bypasses RLS, so admin.html
-- keeps working. All public access is through the functions below.
revoke all on accommodation from anon, authenticated;

-- ========================================================== 1. submit =======
-- Insert a new application, or update an existing one when p_code is supplied.
-- Returns the edit_code the submitter needs to come back.
create or replace function acc_submit(
  p_code     text,
  p_country  text, p_country_name text,
  p_team     text, p_contact text, p_email text,
  p_ath int, p_off int, p_male int, p_female int,
  p_in text, p_out text,
  p_c1 text, p_c2 text, p_c3 text,
  p_single int, p_twin int,
  p_diet text, p_notes text
) returns text
language plpgsql security definer set search_path = public as $$
declare
  v_code text;
  v_now  text := to_char(now() at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI:SS');
  v_ctry text := upper(trim(coalesce(p_country,'')));
  v_ver  boolean := (my_country() is not null and my_country() = v_ctry);
begin
  if v_ctry !~ '^[A-Z]{3}$' then
    raise exception 'Country must be a 3-letter NPC code';
  end if;
  if coalesce(trim(p_email),'') = '' then
    raise exception 'Contact email is required';
  end if;

  if coalesce(p_code,'') <> '' then
    update accommodation set
      country=v_ctry, country_name=coalesce(p_country_name,''),
      team_name=coalesce(p_team,''), contact_name=coalesce(p_contact,''),
      contact_email=trim(p_email),
      n_athletes=p_ath, n_officials=p_off, n_male=p_male, n_female=p_female,
      check_in=p_in, check_out=p_out,
      choice_1=p_c1, choice_2=p_c2, choice_3=p_c3,
      rooms_single=p_single, rooms_twin=p_twin,
      dietary=coalesce(p_diet,''), notes=coalesce(p_notes,''),
      verified = verified or v_ver,
      updated_at=v_now
    where edit_code = p_code and status <> 'approved'
    returning edit_code into v_code;

    if v_code is null then
      raise exception 'That edit link is invalid, or the application has already been approved';
    end if;
    return v_code;
  end if;

  insert into accommodation(
    country, country_name, verified, team_name, contact_name, contact_email,
    n_athletes, n_officials, n_male, n_female, check_in, check_out,
    choice_1, choice_2, choice_3, rooms_single, rooms_twin,
    dietary, notes, status, submitted_at, updated_at)
  values (
    v_ctry, coalesce(p_country_name,''), v_ver, coalesce(p_team,''),
    coalesce(p_contact,''), trim(p_email),
    p_ath, p_off, p_male, p_female, p_in, p_out,
    p_c1, p_c2, p_c3, p_single, p_twin,
    coalesce(p_diet,''), coalesce(p_notes,''), 'pending', v_now, v_now)
  returning edit_code into v_code;

  return v_code;
exception
  when unique_violation then
    raise exception 'An application already exists for % / %. Use the edit link that was shown when it was submitted.', v_ctry, trim(p_email);
end $$;

-- ============================================================ 2. load =======
-- Read back exactly one row — the one whose secret code the caller holds.
create or replace function acc_load(p_code text)
returns json language sql security definer set search_path = public as $$
  select to_json(t) from (
    select edit_code, country, country_name, team_name, contact_name, contact_email,
           n_athletes, n_officials, n_male, n_female, check_in, check_out,
           choice_1, choice_2, choice_3, rooms_single, rooms_twin,
           dietary, notes, status, allocated_hotel, submitted_at, updated_at
    from accommodation
    where edit_code = p_code
    limit 1
  ) t
$$;

-- ======================================================= 3. my rows =========
-- Convenience for a logged-in NPC: list this country's applications so the
-- portal can link straight to them without anyone hunting for a code.
create or replace function acc_mine()
returns json language sql security definer set search_path = public as $$
  select coalesce(json_agg(t),'[]'::json) from (
    select edit_code, team_name, contact_name, contact_email, status,
           n_athletes + n_officials as total_pax, submitted_at
    from accommodation
    where my_country() is not null and country = my_country()
    order by id
  ) t
$$;

grant execute on function acc_submit(text,text,text,text,text,text,int,int,int,int,
                                     text,text,text,text,text,int,int,text,text)
  to anon, authenticated;
grant execute on function acc_load(text) to anon, authenticated;
grant execute on function acc_mine()     to authenticated;

-- ------------------------------------------------------------ hotel data ----
-- oc_settings is already public-select, so the form can read this with no auth.
insert into oc_settings(key, value) values
('hotels', '[
  {"code":"GMA","name":"Grand Mercure Ambassador Changwon","name_ko":"그랜드머큐어 앰배서더 창원",
   "addr":"경상남도 창원시 성산구 원이대로 332","lat":35.2238,"lon":128.6793,
   "site":"https://www.ambatel.com/grandmercure/changwon/En/main.do","site_lang":"EN",
   "check_in":"15:00","check_out":"12:00","capacity_beds":0,"geo_verified":false},
  {"code":"GCC","name":"Grand City Hotel Changwon","name_ko":"그랜드시티호텔 창원",
   "addr":"경상남도 창원시 성산구 중앙대로 78","lat":35.2265,"lon":128.6809,
   "site":"http://www.grandcityhotel.co.kr/","site_lang":"KO",
   "check_in":"15:00","check_out":"11:00","capacity_beds":0,"geo_verified":false},
  {"code":"ISQ","name":"I-Square Hotel Gimhae","name_ko":"아이스퀘어호텔 김해",
   "addr":"경상남도 김해시 김해대로 2360","lat":35.2320,"lon":128.8846,
   "site":"http://www.isquare-hotel.com/","site_lang":"KO",
   "check_in":"15:00","check_out":"11:00","capacity_beds":0,"geo_verified":false}
]')
on conflict (key) do update set value = excluded.value;

insert into oc_settings(key, value) values
('accommodation_window', '{"open":"2026-09-03","close":"2026-09-21",
  "competition_start":"2026-09-07","competition_end":"2026-09-18"}')
on conflict (key) do update set value = excluded.value;

-- ============================================================================
--  ROLLBACK
--    drop function if exists acc_submit(text,text,text,text,text,text,int,int,
--      int,int,text,text,text,text,text,int,int,text,text);
--    drop function if exists acc_load(text);
--    drop function if exists acc_mine();
--    drop table if exists accommodation;
--    delete from oc_settings where key in ('hotels','accommodation_window');
-- ============================================================================
