-- =====================================================================
-- Security hardening migration  (Changwon 2026 WSPS WCH — NPC Portal)
-- Run in Supabase SQL Editor (project tkdvyxouknhjhaqjrotb).
-- Two independent parts. Each is idempotent and reversible.
-- Rollback statements are at the bottom (commented out).
-- =====================================================================

-- ---------------------------------------------------------------------
-- PART 1 — firearms Storage: public bucket -> private, own-country read
--   Why: photos were world-readable by URL. App never renders them as
--   <img> (only a "2/2" presence count), so making the bucket private
--   has NO UI impact. Admin uses service_role -> bypasses RLS.
-- ---------------------------------------------------------------------
update storage.buckets set public = false where id = 'firearms';

drop policy if exists firearms_rd on storage.objects;
create policy firearms_rd on storage.objects for select to authenticated
  using (bucket_id = 'firearms' and (storage.foldername(name))[1] = my_country());
-- (firearms_up / firearms_del policies unchanged — own-country upload/delete)

-- ---------------------------------------------------------------------
-- PART 2 — npc_directory: stop anon bulk-dump of contact emails / user_id
--   Login still needs the email for the SELECTED country, so we expose
--   ONLY that via SECURITY DEFINER functions and remove the open SELECT
--   policy. This kills `select * from npc_directory` (whole-list harvest)
--   and hides user_id / created_at. Per-country lookup remains (inherent
--   to email login). Updates (activation) use return=minimal -> no SELECT
--   needed, so the dir_upd policy is sufficient.
-- ---------------------------------------------------------------------
create or replace function dir_lookup(p_country text)
returns table(email text, active boolean)
language sql stable security definer set search_path = public as
$$ select email, active from npc_directory where country = p_country limit 1 $$;

create or replace function dir_country(p_email text)
returns text
language sql stable security definer set search_path = public as
$$ select country from npc_directory where email = p_email limit 1 $$;

revoke all on function dir_lookup(text)  from public;
revoke all on function dir_country(text) from public;
grant execute on function dir_lookup(text)  to anon, authenticated;
grant execute on function dir_country(text) to anon, authenticated;

-- remove the open read policy (anon/authenticated can no longer read rows)
drop policy if exists dir_sel on npc_directory;
-- dir_upd stays; my_country() is SECURITY DEFINER so all rw_own gates keep working.

-- ---------------------------------------------------------------------
-- Verify
-- ---------------------------------------------------------------------
select 'bucket_public' k, (public::text) v from storage.buckets where id='firearms'
union all select 'firearms_rd_policy', coalesce((select 'own-country' from pg_policies where schemaname='storage' and tablename='objects' and policyname='firearms_rd'),'MISSING')
union all select 'dir_sel_present', coalesce((select 'STILL-OPEN' from pg_policies where tablename='npc_directory' and policyname='dir_sel'),'removed')
union all select 'dir_lookup_fn', coalesce((select 'ok' from pg_proc where proname='dir_lookup'),'MISSING')
union all select 'dir_country_fn', coalesce((select 'ok' from pg_proc where proname='dir_country'),'MISSING');

-- =====================================================================
-- ROLLBACK (uncomment to revert)
-- update storage.buckets set public = true where id='firearms';
-- drop policy if exists firearms_rd on storage.objects;
-- create policy firearms_rd on storage.objects for select to anon, authenticated using (bucket_id='firearms');
-- create policy dir_sel on npc_directory for select to anon, authenticated using (true);
-- drop function if exists dir_lookup(text);
-- drop function if exists dir_country(text);
-- =====================================================================
