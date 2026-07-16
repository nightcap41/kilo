-- Fix profile<->health mirror watermark drift (issue #508).
--
-- kilo.health_parity_report() flagged 2 divergences, both 'timestamp_mismatch'
-- with kilo.health_values_differ(...) = false: the mirrored health content was
-- identical on both sides, only the updated_at watermark disagreed. This is a
-- hard blocker for #492 (Article 9 consent enforcement cannot flip on a red
-- parity gate).
--
-- Root cause
-- ----------
-- kilo.mirror_profile_to_health() and kilo.mirror_health_to_profile()
-- (20260714120000_health_data_expand.sql) each skip their upsert on UPDATE
-- when kilo.health_values_differ(old, new) is false, to avoid writing a
-- phantom health-table row per unrelated user_profile edit (display_name,
-- unit_system, ui_state). But kilo.set_updated_at_compat() stamps
-- user_profile.updated_at = now() on *every* top-level write, health-relevant
-- or not. So an edit that only touches, e.g., display_name advances
-- user_profile.updated_at while the mirror is skipped and
-- user_health_profile.updated_at stays frozen at the last genuine health
-- write -- exactly the drift the parity gate flagged. The mirror write path
-- was therefore never fully atomic with respect to updated_at: it was atomic
-- only for writes that also touched health content.
--
-- Fix
-- ---
-- Drop the health_values_differ guard from both mirror functions so every
-- genuine top-level write to either table always upserts the other side, in
-- the same transaction, carrying the same updated_at across (the existing
-- pg_trigger_depth() > 1 recursion guard is unchanged and still prevents the
-- two mirrors from ping-ponging). When content did not change, the upsert
-- writes the same content values back -- a no-op for content -- but still
-- carries updated_at across, so the two rows can no longer disagree after a
-- genuine write. kilo.health_values_differ(...) itself is untouched; it is
-- still used by kilo.health_parity_report() to distinguish a real content
-- divergence ('value_mismatch') from a timestamp-only one.
--
-- This changes only the mirror-write path. It does not touch
-- health_sync_config, any consent policy, or enforcement -- that is #492.

create or replace function kilo.mirror_profile_to_health()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  -- Recursion guard. A mirror write into user_health_profile fires that table's
  -- AFTER trigger at depth 2; without this the two mirrors would ping-pong.
  if pg_trigger_depth() > 1 then
    return null;
  end if;

  -- #508: always mirror on a genuine top-level write, even when
  -- kilo.health_values_differ(...) is false for this row (a health-irrelevant
  -- edit such as display_name or ui_state). The content columns then upsert to
  -- the same values they already held, but updated_at still carries across, so
  -- the two rows share one watermark per genuine write instead of drifting
  -- whenever an unrelated column changes.
  insert into kilo.user_health_profile as h (
    user_id,
    current_deload_note_raw_text,
    current_deload_note_saved_at,
    current_deload_note_updated_at,
    fatigue_multiplier,
    tracked_lifts,
    current_workout_note_id,
    updated_at,
    deleted_at
  ) values (
    new.user_id,
    new.current_deload_note_raw_text,
    new.current_deload_note_saved_at,
    new.current_deload_note_updated_at,
    new.fatigue_multiplier,
    new.tracked_lifts,
    new.current_workout_note_id,
    new.updated_at,
    new.deleted_at
  )
  on conflict (user_id) do update set
    current_deload_note_raw_text   = excluded.current_deload_note_raw_text,
    current_deload_note_saved_at   = excluded.current_deload_note_saved_at,
    current_deload_note_updated_at = excluded.current_deload_note_updated_at,
    fatigue_multiplier             = excluded.fatigue_multiplier,
    tracked_lifts                  = excluded.tracked_lifts,
    current_workout_note_id        = excluded.current_workout_note_id,
    updated_at                     = excluded.updated_at,
    deleted_at                     = excluded.deleted_at
  -- Strictly later wins. On an exact tie the canonical table is authoritative,
  -- so an equal-timestamp legacy write does NOT overwrite it.
  where excluded.updated_at > h.updated_at;

  return null;
end;
$$;

create or replace function kilo.mirror_health_to_profile()
  returns trigger
  language plpgsql
  security definer
  set search_path = ''
as $$
begin
  if pg_trigger_depth() > 1 then
    return null;
  end if;

  -- #508: see kilo.mirror_profile_to_health() above -- always mirror on a
  -- genuine top-level write so the two watermarks cannot drift apart.
  --
  -- The legacy row may not exist yet for a user who only ever ran a new client.
  -- Insert it so an old client on a second device still sees the health values.
  insert into kilo.user_profile as p (
    user_id,
    current_deload_note_raw_text,
    current_deload_note_saved_at,
    current_deload_note_updated_at,
    fatigue_multiplier,
    tracked_lifts,
    current_workout_note_id,
    updated_at
  ) values (
    new.user_id,
    new.current_deload_note_raw_text,
    new.current_deload_note_saved_at,
    new.current_deload_note_updated_at,
    new.fatigue_multiplier,
    new.tracked_lifts,
    new.current_workout_note_id,
    new.updated_at
  )
  on conflict (user_id) do update set
    current_deload_note_raw_text   = excluded.current_deload_note_raw_text,
    current_deload_note_saved_at   = excluded.current_deload_note_saved_at,
    current_deload_note_updated_at = excluded.current_deload_note_updated_at,
    fatigue_multiplier             = excluded.fatigue_multiplier,
    tracked_lifts                  = excluded.tracked_lifts,
    current_workout_note_id        = excluded.current_workout_note_id,
    updated_at                     = excluded.updated_at
  -- The canonical table wins ties, so it mirrors out on >= rather than >.
  -- deleted_at is deliberately not mirrored outward: user_profile.deleted_at is
  -- an account-level tombstone, not a health-row tombstone, and overwriting it
  -- from the health row would resurrect or bury the account row.
  where excluded.updated_at >= p.updated_at;

  return null;
end;
$$;

-- ---------------------------------------------------------------------------
-- Reconcile the two rows kilo.health_parity_report() currently flags.
-- ---------------------------------------------------------------------------
--
-- kilo.reconcile_user_health(uuid) (20260714120000_health_data_expand.sql)
-- already does exactly what's needed here: it copies the LWW winner's content
-- onto the loser WITHOUT restamping (it suppresses kilo.set_updated_at_compat()
-- via kilo.suppress_updated_at_stamp), so the loser's watermark is repaired to
-- match the winner's genuine, originating updated_at rather than being reset to
-- now(). Since kilo.health_values_differ(...) is already false for both rows,
-- this only moves the watermark -- content is copied but is identical either
-- way, so no health content changes. It is called once per user; any
-- cross-table follow-up caused by the (now-unconditional) mirror trigger
-- converges to the same watermark on both sides in the same statement.
--
-- The whole migration runs in one transaction: if parity is not fully restored,
-- the assertion below raises and the transaction rolls back rather than leaving
-- a partially-repaired production row.
do $$
declare
  v_remaining int;
begin
  perform kilo.reconcile_user_health('841fa8e5-d1c0-41c4-9ebb-464599b27aa5');
  perform kilo.reconcile_user_health('dee2d064-287c-4178-9caa-e5ed0f4b96b9');

  select count(*) into v_remaining from kilo.health_parity_report();
  if v_remaining <> 0 then
    raise exception
      '#508: kilo.health_parity_report() still reports % divergent row(s) after reconciliation',
      v_remaining;
  end if;
end;
$$;
