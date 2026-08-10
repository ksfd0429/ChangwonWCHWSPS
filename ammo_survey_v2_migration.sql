-- Changwon 2026 · Shotgun ammunition demand survey — v2
-- Removes the 400-rounds-per-athlete-per-day cap and the per-day breakdown.
-- New unit of declaration: one row per (athlete, product) with a total round count
-- in multiples of 25.  2026-08-10

begin;

-- 1) drop the daily-cap trigger and its function (keep the submit-lock trigger)
do $$
declare r record;
begin
  for r in
    select tg.tgname
      from pg_trigger tg join pg_proc p on p.oid = tg.tgfoid
     where tg.tgrelid = 'public.ammo_survey'::regclass
       and not tg.tgisinternal
       and p.proname = 'ammo_daily_cap'
  loop
    execute format('drop trigger %I on public.ammo_survey', r.tgname);
  end loop;
end $$;
drop function if exists public.ammo_daily_cap();

-- 2) no submissions exist yet, so the day dimension can be dropped outright
delete from public.ammo_survey;

do $$
declare c record;
begin
  for c in
    select conname from pg_constraint
     where conrelid = 'public.ammo_survey'::regclass and contype = 'u'
  loop
    execute format('alter table public.ammo_survey drop constraint %I', c.conname);
  end loop;
end $$;

alter table public.ammo_survey drop column if exists use_date;

alter table public.ammo_survey
  add constraint ammo_survey_member_product_uniq unique (member_id, product_id);

-- 3) settings: daily_cap no longer applies
update public.oc_settings
   set value = '{"open": true, "deadline": "2026-08-17", "currency": "EUR", "step": 25, "pack": 250}'
 where key = 'ammo_survey';

commit;

-- verification
select column_name from information_schema.columns
 where table_schema='public' and table_name='ammo_survey' order by ordinal_position;
select conname, pg_get_constraintdef(oid) from pg_constraint
 where conrelid='public.ammo_survey'::regclass;
select tg.tgname, p.proname from pg_trigger tg join pg_proc p on p.oid=tg.tgfoid
 where tg.tgrelid='public.ammo_survey'::regclass and not tg.tgisinternal;
select value from public.oc_settings where key='ammo_survey';
