-- ============================================================================
--  Changwon 2026 WSPS — Accommodation: change log + read-only mirror
--  Migration: accommodation_tracking_migration.sql
--  Run AFTER accommodation_migration.sql
--
--  WHY THIS EXISTS
--  1. Every change to an application is recorded, so the LOC and its partners
--     can see what moved since they last looked (the red badge).
--  2. Partners (hotels, transport, catering) open a PLAIN LINK — no code, no
--     login. What protects the data is not a gate but the payload itself:
--     acc_mirror() returns operational figures only, with every contact
--     detail, edit code and internal note stripped in SQL before it leaves
--     the database. The service_role key is never present on that page.
--     An optional token still exists for the rare partner who needs contact
--     details, but it is not required to view the dashboard.
-- ============================================================================

-- ============================================================ change log ====
create table if not exists accommodation_log (
  id               bigint generated always as identity primary key,
  accommodation_id bigint,
  country          text default '',
  team_name        text default '',
  action           text not null check (action in ('insert','update','delete')),
  changed          jsonb not null default '{}'::jsonb,  -- {field:[old,new]}
  actor            text default '',                      -- 'npc' | 'loc'
  at               timestamptz not null default now()
);
create index if not exists acc_log_at      on accommodation_log(at desc);
create index if not exists acc_log_country on accommodation_log(country);
create index if not exists acc_log_row     on accommodation_log(accommodation_id);

create or replace function acc_log_changes() returns trigger
language plpgsql security definer set search_path = public as $$
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
    'dietary','notes','status','allocated_hotel'];
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

drop trigger if exists trg_accommodation_log on accommodation;
create trigger trg_accommodation_log
  after insert or update or delete on accommodation
  for each row execute function acc_log_changes();

alter table accommodation_log enable row level security;
-- no policies: only service_role and the definer functions below can read it
revoke all on accommodation_log from anon, authenticated;

-- ========================================================= share tokens =====
create table if not exists acc_share (
  token        text primary key
               default substr(replace(gen_random_uuid()::text,'-',''),1,16),
  label        text not null default '',      -- e.g. '그랜드머큐어 예약팀'
  active       boolean not null default true,
  show_contact boolean not null default false, -- almost always false
  created_at   timestamptz not null default now(),
  last_used_at timestamptz
);
alter table acc_share enable row level security;
revoke all on acc_share from anon, authenticated;

-- Optional. Only needed for a partner who must also see contact details
-- (set show_contact = true on their row). The plain link needs none of this.
--   accommodation_mirror.html          <- what you send to partners
--   accommodation_mirror.html?t=<token> <- labelled / contact-enabled variant
insert into acc_share(label) values
  ('그랜드머큐어 앰배서더 창원'),
  ('그랜드시티호텔 창원'),
  ('아이스퀘어호텔 김해'),
  ('수송·셔틀 업체'),
  ('조직위 내부 공유')
on conflict do nothing;

-- ============================================================ mirror RPC ====
-- One call returns everything the mirror needs. Contact details are stripped
-- unless the token explicitly allows them.
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
begin
  -- No token: the plain link. Everyone gets the de-identified operational view.
  -- With a token: only difference is the label and, if granted, contact details.
  if coalesce(p_token,'') <> '' then
    select * into s from acc_share where token = p_token and active;
    if found then
      v_label := s.label;
      v_show  := s.show_contact;
      update acc_share set last_used_at = now() where token = p_token;
    end if;
  end if;

  select coalesce(json_agg(t order by t.country, t.team_name), '[]'::json) into v_rows
  from (
    select a.id, a.country, a.country_name, a.team_name,
           case when v_show then a.contact_name  else null end as contact_name,
           case when v_show then a.contact_email else null end as contact_email,
           a.n_athletes, a.n_officials, a.n_male, a.n_female,
           a.check_in, a.check_out,
           a.choice_1, a.choice_2, a.choice_3,
           a.rooms_single, a.rooms_twin,
           a.dietary,                      -- hotels need this for catering
           a.status, a.allocated_hotel, a.verified,
           a.submitted_at, a.updated_at
    from accommodation a
  ) t;

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
    'label',        v_label,
    'show_contact', v_show,
    'generated_at', to_char(now() at time zone 'Asia/Seoul','YYYY-MM-DD HH24:MI:SS'),
    'generated_utc', now(),
    'rows',         v_rows,
    'log',          v_log,
    'hotels',       coalesce(v_hotels,'[]'::json)
  );
end $$;

-- anon may call this with no arguments: that IS the partner link
grant execute on function acc_mirror(text, timestamptz) to anon, authenticated;

-- ===================================================== admin convenience ====
-- Recent activity for the LOC dashboard badge (service_role reads the table
-- directly, but this keeps the shape identical to the mirror).
create or replace function acc_log_recent(p_since timestamptz default null, p_limit int default 500)
returns json language sql security definer set search_path = public as $$
  select coalesce(json_agg(l order by l.at desc),'[]'::json) from (
    select id, accommodation_id, country, team_name, action, changed, actor, at
    from accommodation_log
    where p_since is null or at > p_since
    order by at desc limit p_limit
  ) l
$$;
revoke execute on function acc_log_recent(timestamptz,int) from anon, authenticated;

-- ============================================================================
--  ROLLBACK
--    drop trigger if exists trg_accommodation_log on accommodation;
--    drop function if exists acc_log_changes();
--    drop function if exists acc_mirror(text,timestamptz);
--    drop function if exists acc_log_recent(timestamptz,int);
--    drop table if exists accommodation_log;
--    drop table if exists acc_share;
-- ============================================================================
