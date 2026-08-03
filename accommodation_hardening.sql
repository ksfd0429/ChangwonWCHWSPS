-- ============================================================================
--  Changwon 2026 WSPS — Accommodation: hardening pass
--  Migration: accommodation_hardening.sql
--  Run AFTER accommodation_migration.sql, accommodation_tracking_migration.sql
--  and accommodation_roster_migration.sql.
--
--  This is a fix migration, not a feature migration. Every block below closes
--  a defect that was found by auditing the three live migrations against a
--  real Postgres. Each one is labelled with what actually broke.
--
--  Safe to re-run. No data is destroyed; the one UPDATE (block 1b) only
--  removes personal data that should never have been in the log payload.
-- ============================================================================

-- =========================================================== 1. LOG LEAK ====
--  DEFECT: acc_mirror() redacted contact_name / contact_email from `rows`,
--  but returned accommodation_log.changed verbatim. The trigger's watch list
--  includes contact_name, contact_email, notes and dietary, so every EDITED
--  application published its contact details and its internal notes to every
--  partner holding the plain mirror link — under a footer that reads
--  "개인 연락처는 표시되지 않습니다".
--
--  Fix in two parts: stop emitting them (1a), and scrub what is already
--  stored (1b). 1a alone is not enough — the old rows are still in the table.

-- 1a. keys that must never leave the database inside a diff
create or replace function acc_log_public(d jsonb)
returns jsonb language sql immutable set search_path = public, pg_temp as $$
  select coalesce(d,'{}'::jsonb)
         - array['contact_name','contact_email','notes','dietary']
$$;

comment on function acc_log_public(jsonb) is
  'Strips personal / internal fields from an accommodation_log diff before it
   is shown to anyone who is not the LOC. Add to this list, never remove.';

-- ---------------------------------------------------------------------------
-- 1b. scrub the diffs already written. The fact that a field CHANGED is kept
--     (the key survives as a null pair) so the audit trail is not falsified —
--     only the values are removed.
update accommodation_log
   set changed = (
         select coalesce(jsonb_object_agg(k, case
                  when k in ('contact_name','contact_email','notes','dietary')
                    then '["(제거됨)","(제거됨)"]'::jsonb
                  else v end), '{}'::jsonb)
         from jsonb_each(changed) as e(k,v))
 where changed ?| array['contact_name','contact_email','notes','dietary'];

-- =================================================== 2. BROKEN REVOKE =======
--  DEFECT: `revoke execute ... from anon, authenticated` is a no-op, because
--  CREATE FUNCTION grants EXECUTE to PUBLIC and both roles inherit it. Anyone
--  with the publishable anon key could call acc_log_recent with an arbitrary
--  p_limit and read the entire, uncapped change history.
revoke execute on function acc_log_recent(timestamptz,int) from public;
revoke execute on function acc_log_recent(timestamptz,int) from anon, authenticated;
grant  execute on function acc_log_recent(timestamptz,int) to service_role;

--  Same class: acc_mine() was granted to authenticated but reachable by anon
--  through PUBLIC. It returns [] for anon today only because my_country() is
--  null — that is luck, not a control.
revoke execute on function acc_mine() from public;
grant  execute on function acc_mine() to authenticated, service_role;

-- ==================================================== 3. FRAGILE DOB ========
--  DEFECT: the roster's age expression guarded dob with a regex that accepts
--  2026-02-30 and 2026-13-01, then cast it. One impossible birthday anywhere
--  in the 241-row shared members table raised 22008 and took down the WHOLE
--  mirror — partner dashboard and LOC dashboard, all panels, one error line.
create or replace function acc_safe_date(t text)
returns date language plpgsql immutable set search_path = public, pg_temp as $$
begin
  return btrim(coalesce(t,''))::date;
exception when others then
  return null;
end $$;

comment on function acc_safe_date(text) is
  'Date cast that returns null instead of raising. Used on members.dob, which
   is free text maintained by another form and cannot be trusted to parse.';

-- ================================================= 4. acc_submit REWRITE ====
--  DEFECTS closed here:
--   (a) every CHECK constraint was bypassable with NULL — a CHECK rejects
--       only FALSE, never NULL, and no parameter was coalesced. One call with
--       nulls inserted a row with no pax, no dates, no choices and no rooms.
--   (b) negative and absurd counts passed: only the SUMS were constrained, so
--       n_athletes = 1000000 with n_officials = -999999 was "valid".
--   (c) check_in / check_out are text and were compared as STRINGS, so
--       'zzz' > 'not-a-date' satisfied the stay-order constraint.
--   (d) choice_1..3 were never checked against the real hotel codes.
--   (e) the UPDATE path let any holder of an edit code rewrite `country`
--       while KEEPING `verified` — an anonymous caller could relabel a
--       verified application as another nation's, and `verified` was not in
--       the trigger's watch list so it left no audit trail.
--   (f) the unique_violation handler assumed the (country, email) index and
--       reported "an application already exists for X / Y" on an edit_code
--       collision too — telling a delegation to use a link they never had.
--   (g) that same message was a contact-email oracle: it confirmed whether a
--       given address is the registered contact for a given NPC.
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
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  v_code  text;
  v_now   text := to_char(now() at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI:SS');
  v_ctry  text := upper(trim(coalesce(p_country,'')));
  v_ver   boolean := (my_country() is not null and my_country() = v_ctry);
  -- numbers: null is not "unknown", it is zero. Coalescing here is what makes
  -- the table's CHECK constraints actually bite.
  v_ath   int := coalesce(p_ath,0);     v_off  int := coalesce(p_off,0);
  v_male  int := coalesce(p_male,0);    v_fem  int := coalesce(p_female,0);
  v_sgl   int := coalesce(p_single,0);  v_twn  int := coalesce(p_twin,0);
  v_in    text := btrim(coalesce(p_in,''));
  v_out   text := btrim(coalesce(p_out,''));
  v_c1    text := upper(btrim(coalesce(p_c1,'')));
  v_c2    text := upper(btrim(coalesce(p_c2,'')));
  v_c3    text := upper(btrim(coalesce(p_c3,'')));
  v_din   date; v_dout date;
  v_owner text;
begin
  ---------------------------------------------------------------- identity --
  if v_ctry !~ '^[A-Z]{3}$' then
    raise exception 'Country must be a 3-letter NPC code';
  end if;
  if coalesce(btrim(p_email),'') !~ '^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$' then
    raise exception 'A valid contact email is required';
  end if;

  ----------------------------------------------------------------- numbers --
  -- Upper bound 2000: the largest delegation ever entered at a WSPS event is
  -- two orders of magnitude below this, so it can only catch a fat finger or
  -- a script, never a real team.
  if v_ath < 0 or v_off < 0 or v_male < 0 or v_fem < 0 or v_sgl < 0 or v_twn < 0 then
    raise exception 'Counts cannot be negative';
  end if;
  if v_ath + v_off < 1 or v_ath + v_off > 2000 then
    raise exception 'Total delegation size must be between 1 and 2000';
  end if;
  if v_male + v_fem <> v_ath + v_off then
    raise exception 'Male + female must equal the total delegation size';
  end if;
  if v_sgl + v_twn < 1 or v_sgl + v_twn > 2000 then
    raise exception 'Total rooms must be between 1 and 2000';
  end if;

  ------------------------------------------------------------------- dates --
  -- Cast to date and compare as dates. The old text comparison let any two
  -- strings through as long as the second sorted higher.
  v_din  := acc_safe_date(v_in);
  v_dout := acc_safe_date(v_out);
  if v_din is null or v_dout is null then
    raise exception 'Check-in and check-out must be real dates (YYYY-MM-DD)';
  end if;
  if v_dout <= v_din then
    raise exception 'Check-out must be after check-in';
  end if;
  if v_din < date '2026-08-01' or v_dout > date '2026-10-31' then
    raise exception 'Stay dates must fall within August–October 2026';
  end if;
  v_in  := to_char(v_din,'YYYY-MM-DD');   -- normalise 2026-9-7 -> 2026-09-07
  v_out := to_char(v_dout,'YYYY-MM-DD');  -- the analytics compare these as text

  ----------------------------------------------------------------- choices --
  -- Checked against the real codes. Previously any string was a valid hotel,
  -- including a 5000-character one, and an unrecognised code silently drops
  -- the delegation out of the daily-occupancy and peak figures downstream.
  if v_c1 not in ('GMA','GCC','ISQ')
     or v_c2 not in ('GMA','GCC','ISQ')
     or v_c3 not in ('GMA','GCC','ISQ') then
    raise exception 'Each hotel preference must be one of GMA, GCC, ISQ';
  end if;
  if v_c1 = v_c2 or v_c2 = v_c3 or v_c1 = v_c3 then
    raise exception 'The three hotel preferences must be different';
  end if;

  ------------------------------------------------------------------ update --
  if coalesce(p_code,'') <> '' then
    select country into v_owner from accommodation where edit_code = p_code;

    update accommodation set
      country=v_ctry, country_name=coalesce(p_country_name,''),
      team_name=coalesce(p_team,''), contact_name=coalesce(p_contact,''),
      contact_email=btrim(p_email),
      n_athletes=v_ath, n_officials=v_off, n_male=v_male, n_female=v_fem,
      check_in=v_in, check_out=v_out,
      choice_1=v_c1, choice_2=v_c2, choice_3=v_c3,
      rooms_single=v_sgl, rooms_twin=v_twn,
      dietary=coalesce(p_diet,''), notes=coalesce(p_notes,''),
      -- Changing the country RESETS verification. A typo can still be fixed;
      -- what is no longer possible is inheriting another delegation's verified
      -- badge by editing its country.
      verified = case when v_owner = v_ctry then (verified or v_ver) else v_ver end,
      updated_at=v_now
    where edit_code = p_code and status <> 'approved'
    returning edit_code into v_code;

    if v_code is null then
      raise exception 'That edit link is invalid, or the application has already been approved';
    end if;
    return v_code;
  end if;

  ------------------------------------------------------------------ insert --
  insert into accommodation(
    country, country_name, verified, team_name, contact_name, contact_email,
    n_athletes, n_officials, n_male, n_female, check_in, check_out,
    choice_1, choice_2, choice_3, rooms_single, rooms_twin,
    dietary, notes, status, submitted_at, updated_at)
  values (
    v_ctry, coalesce(p_country_name,''), v_ver, coalesce(p_team,''),
    coalesce(p_contact,''), btrim(p_email),
    v_ath, v_off, v_male, v_fem, v_in, v_out,
    v_c1, v_c2, v_c3, v_sgl, v_twn,
    coalesce(p_diet,''), coalesce(p_notes,''), 'pending', v_now, v_now)
  returning edit_code into v_code;

  return v_code;
exception
  when unique_violation then
    -- Distinguish the two unique indexes. An edit_code collision is our
    -- problem, not the submitter's, and must not be reported as a duplicate
    -- application. The duplicate message no longer echoes the email back,
    -- so it cannot be used to test whether an address is registered.
    if sqlerrm like '%edit_code%' then
      raise exception 'Could not generate a unique edit link. Please submit again.';
    end if;
    raise exception 'An application already exists for this delegation and contact address. Use the edit link that was shown when it was submitted, or contact the LOC.';
end $$;

grant execute on function acc_submit(text,text,text,text,text,text,int,int,int,int,
                                     text,text,text,text,text,int,int,text,text)
  to anon, authenticated;

-- =================================================== 5. TABLE CONSTRAINTS ===
--  Defence in depth: the same rules as CHECK constraints, so a future path
--  that writes the table directly cannot reintroduce the bad rows.
--  NOT VALID means existing rows are left alone (there are test rows and
--  possibly pre-fix rows); every INSERT and UPDATE from now on is checked.
--  To enforce retroactively after cleaning the data:
--    alter table accommodation validate constraint acc_counts_sane;
alter table accommodation drop constraint if exists acc_counts_sane;
alter table accommodation add  constraint acc_counts_sane check (
  coalesce(n_athletes,0)   >= 0 and coalesce(n_officials,0)  >= 0 and
  coalesce(n_male,0)       >= 0 and coalesce(n_female,0)     >= 0 and
  coalesce(rooms_single,0) >= 0 and coalesce(rooms_twin,0)   >= 0 and
  coalesce(n_athletes,0) + coalesce(n_officials,0) between 1 and 2000 and
  coalesce(rooms_single,0) + coalesce(rooms_twin,0) between 1 and 2000
) not valid;

alter table accommodation drop constraint if exists acc_dates_real;
alter table accommodation add  constraint acc_dates_real check (
  check_in  ~ '^\d{4}-\d{2}-\d{2}$' and
  check_out ~ '^\d{4}-\d{2}-\d{2}$' and
  check_out::date > check_in::date
) not valid;

alter table accommodation drop constraint if exists acc_choices_known;
alter table accommodation add  constraint acc_choices_known check (
  choice_1 in ('GMA','GCC','ISQ') and
  choice_2 in ('GMA','GCC','ISQ') and
  choice_3 in ('GMA','GCC','ISQ')
) not valid;

--  allocated_hotel is set by the LOC by hand. A typo here is invisible: the
--  team keeps counting in "rooms requested" but silently vanishes from the
--  daily occupancy grid and therefore from the PEAK — the one number the
--  hotels actually block rooms against.
alter table accommodation drop constraint if exists acc_allocated_known;
alter table accommodation add  constraint acc_allocated_known check (
  coalesce(allocated_hotel,'') in ('','GMA','GCC','ISQ')
) not valid;

-- ======================================================= 6. AUDIT FIELDS ===
--  `verified` was missing from the watch list, so a change to it left no
--  trace. `allocated_hotel` was already watched; keep it.
create or replace function acc_log_changes() returns trigger
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  d      jsonb := '{}'::jsonb;
  k      text;
  ov     jsonb;
  nv     jsonb;
  who    text := case when auth.role() = 'service_role' then 'loc' else 'npc' end;
  watch  text[] := array[
    'country','country_name','team_name','contact_name','contact_email',
    'n_athletes','n_officials','n_male','n_female','check_in','check_out',
    'choice_1','choice_2','choice_3','rooms_single','rooms_twin',
    'dietary','notes','status','allocated_hotel','verified'];
begin
  if TG_OP = 'INSERT' then
    insert into accommodation_log(accommodation_id,country,team_name,action,changed,actor)
    values (NEW.id, NEW.country, NEW.team_name, 'insert',
            jsonb_build_object(
              'total_pax', to_jsonb(coalesce(NEW.n_athletes,0)+coalesce(NEW.n_officials,0)),
              'rooms',     to_jsonb(coalesce(NEW.rooms_single,0)+coalesce(NEW.rooms_twin,0)),
              'choice_1',  to_jsonb(NEW.choice_1)),
            who);
    return NEW;

  elsif TG_OP = 'DELETE' then
    insert into accommodation_log(accommodation_id,country,team_name,action,changed,actor)
    values (OLD.id, OLD.country, OLD.team_name, 'delete', '{}'::jsonb, who);
    return OLD;

  else
    foreach k in array watch loop
      ov := to_jsonb(OLD) -> k;
      nv := to_jsonb(NEW) -> k;
      if ov is distinct from nv then
        d := d || jsonb_build_object(k, jsonb_build_array(ov, nv));
      end if;
    end loop;
    if d <> '{}'::jsonb then
      insert into accommodation_log(accommodation_id,country,team_name,action,changed,actor)
      values (NEW.id, NEW.country, NEW.team_name, 'update', d, who);
    end if;
    return NEW;
  end if;
end $$;

-- ================================================== 7. acc_mirror v3 ========
--  Changes from v2:
--    * `changed` is redacted for everyone who is not the LOC (block 1).
--    * the LOC dashboard uses the service_role key, so it is recognised by
--      auth.role() and still sees everything — no token needed.
--    * dob goes through acc_safe_date, so one bad birthday can no longer
--      take the whole payload down.
--    * search_path includes pg_temp explicitly.
create or replace function acc_mirror(p_token text default null,
                                     p_since timestamptz default null)
returns json
language plpgsql security definer set search_path = public, pg_temp as $$
declare
  s        acc_share%rowtype;
  v_label  text := '';
  v_show   boolean := false;
  v_loc    boolean := (auth.role() = 'service_role');
  v_rows   json;
  v_log    json;
  v_hotels json;
  v_roster json;
begin
  if v_loc then
    v_show := true;
    v_label := 'LOC';
  elsif coalesce(p_token,'') <> '' then
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
      -- The bound is deliberately ASYMMETRIC. An upper limit catches a typo'd
      -- birth year (1016 instead of 2016 reads as "1010세" and drags the
      -- average with it). There is no meaningful lower limit: small
      -- delegations do travel with an accompanying child, and a floor would
      -- silently drop that person from the hotel's rooming list — the exact
      -- guest who most needs to appear on it.
      case
        when acc_safe_date(md.dob) is not null
         and date_part('year', age(current_date, acc_safe_date(md.dob)))::int between 0 and 100
          then date_part('year', age(current_date, acc_safe_date(md.dob)))::int
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
    select id, accommodation_id, country, team_name, action,
           case when v_show then changed else acc_log_public(changed) end as changed,
           actor, at
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

-- ==================================================== 8. search_path fix ====
--  `set search_path = public` does not exclude pg_temp, which Postgres
--  searches FIRST for relations. A SECURITY DEFINER function can therefore be
--  pointed at an attacker-owned temp table. Not reachable through PostgREST
--  today (it exposes no DDL), but it costs nothing to close.
alter function acc_load(text)  set search_path = public, pg_temp;
alter function acc_mine()      set search_path = public, pg_temp;
alter function acc_log_recent(timestamptz,int) set search_path = public, pg_temp;

-- ============================================================================
--  STILL OPEN — deliberate, listed so they are decisions and not oversights
--
--  * The partner mirror has NO access control by design: the plain link opens
--    the dashboard. Anyone who has the link, or the publishable anon key that
--    ships in every portal page, can read the totals AND the full 241-person
--    accreditation roster (name / country / gender / age / wheelchair). This
--    was chosen over a share code for accessibility. If that trade stops
--    being acceptable, the switch is one line: require a valid token before
--    filling v_roster.
--  * acc_submit is unauthenticated and unthrottled. A script can create
--    applications for any country with any email, and there is no delete
--    path, so junk rows are permanent and are re-sent to partners on every
--    poll. Mitigation would be a rate limit or Turnstile in front of the RPC.
--  * accommodation_log has no retention policy. At event scale this is a few
--    thousand rows; a sustained script could make it millions.
--    Suggested: delete from accommodation_log where at < now() - interval '1 year';
--  * Concurrent edits with the same edit link silently overwrite each other
--    and both submitters are told they succeeded. Fixing it needs an
--    optimistic-concurrency parameter in acc_submit and a client change.
--
--  ROLLBACK
--    -- re-run accommodation_roster_migration.sql to restore acc_mirror v2
--    -- re-run accommodation_migration.sql to restore acc_submit v1
--    alter table accommodation drop constraint if exists acc_counts_sane;
--    alter table accommodation drop constraint if exists acc_dates_real;
--    alter table accommodation drop constraint if exists acc_choices_known;
--    alter table accommodation drop constraint if exists acc_allocated_known;
-- ============================================================================
