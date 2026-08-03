-- ============================================================================
--  Changwon 2026 WSPS — Accommodation: per-person roster for partners
--  Migration: accommodation_roster_migration.sql
--  Run AFTER accommodation_migration.sql and accommodation_tracking_migration.sql
--
--  WHAT THIS ADDS
--  Partners (hotels) need a rooming list, not just totals. acc_mirror() now
--  also returns one row per person: full name, country, gender, age and
--  wheelchair use.
--
--  WHAT IT DELIBERATELY DOES NOT RETURN
--    * passport — no operational use for a hotel, high harm if leaked
--    * date of birth — the request was for AGE, so age is computed here and
--      the birth date never leaves the database
--    * flight numbers, arrival times, contact details
--  The SELECT list below is the only gate. Anything not named there cannot
--  reach the mirror, so review this list whenever the roster changes.
-- ============================================================================

-- ------------------------------------------------------------- gender ------
-- members has no gender column. Added here with an empty default; existing
-- rows stay blank until the value is collected somewhere.
-- NOTE: the roster form (submit.html) does not yet have a gender field, so
-- nothing will populate this on its own. Until that form is updated the
-- roster shows "—" for gender.
alter table members add column if not exists gender text default '';

comment on column members.gender is
  'M / F / blank. Shown to accommodation partners. Populate via the roster form.';

-- ---------------------------------------------------------- mirror v2 ------
create or replace function acc_mirror(p_token text default null,
                                     p_since timestamptz default null)
returns json
language plpgsql security definer set search_path = public as $$
declare
  s        acc_share%rowtype;
  v_label  text := '';
  v_show   boolean := false;
  v_rows   json;
  v_log    json;
  v_hotels json;
  v_roster json;
begin
  if coalesce(p_token,'') <> '' then
    select * into s from acc_share where token = p_token and active;
    if found then
      v_label := s.label;
      v_show  := s.show_contact;
      update acc_share set last_used_at = now() where token = p_token;
    end if;
  end if;

  -- ---- accommodation applications (aggregate level) ----
  select coalesce(json_agg(t order by t.country, t.team_name), '[]'::json) into v_rows
  from (
    select a.id, a.country, a.country_name, a.team_name,
           case when v_show then a.contact_name  else null end as contact_name,
           case when v_show then a.contact_email else null end as contact_email,
           a.n_athletes, a.n_officials, a.n_male, a.n_female,
           a.check_in, a.check_out,
           a.choice_1, a.choice_2, a.choice_3,
           a.rooms_single, a.rooms_twin,
           a.dietary,
           a.status, a.allocated_hotel, a.verified,
           a.submitted_at, a.updated_at
    from accommodation a
  ) t;

  -- ---- per-person roster ----
  -- Age is derived; dob and passport never appear in the output.
  select coalesce(json_agg(m order by m.country, m.full_name), '[]'::json) into v_roster
  from (
    select
      md.country,
      coalesce(
        nullif(btrim(md.name), ''),
        nullif(btrim(concat_ws(' ', nullif(btrim(md.first_name),''),
                                    nullif(btrim(md.last_name),''))), ''),
        '(이름 미입력)'
      )                                                    as full_name,
      upper(nullif(btrim(coalesce(md.gender,'')), ''))     as gender,
      case
        when btrim(coalesce(md.dob,'')) ~ '^\d{4}-\d{1,2}-\d{1,2}$'
          then date_part('year', age(current_date, btrim(md.dob)::date))::int
        else null
      end                                                  as age,
      case
        when lower(btrim(coalesce(md.wheelchair,''))) in ('yes','y','true','1') then true
        else false
      end                                                  as wheelchair,
      nullif(btrim(coalesce(md.position,'')), '')          as position
    from members md
  ) m;

  -- ---- change log ----
  select coalesce(json_agg(l order by l.at desc), '[]'::json) into v_log
  from (
    select id, accommodation_id, country, team_name, action, changed, actor, at
    from accommodation_log
    where p_since is null or at > p_since
    order by at desc
    limit 500
  ) l;

  select value::json into v_hotels from oc_settings where key = 'hotels';

  return json_build_object(
    'label',         v_label,
    'show_contact',  v_show,
    'generated_at',  to_char(now() at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI:SS'),
    'generated_utc', now(),
    'rows',          v_rows,
    'roster',        v_roster,
    'log',           v_log,
    'hotels',        coalesce(v_hotels,'[]'::json)
  );
end $$;

grant execute on function acc_mirror(text, timestamptz) to anon, authenticated;

-- ============================================================================
--  ROLLBACK
--    alter table members drop column if exists gender;
--    -- then re-run accommodation_tracking_migration.sql to restore acc_mirror
-- ============================================================================
