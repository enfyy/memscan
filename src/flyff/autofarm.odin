package flyff

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:strconv"
import "core:strings"
import "core:time"

import "../engine"

// Auto-farm: the hands-free farming layer on top of the selection logic in target.odin - the
// watcher-thread tick (auto_tick / auto_monitor / pause_*) and the REPL commands (auto, timer,
// kills, stuck, reachgate, pause). Same package as target.odin, so this is purely organisational.

// A penya-gain / kill event, appended by the watcher and drained by the radar for its juice (the
// "+penya" pop + chime, the kill laser + zap). Seq-tagged so the radar replays only events newer than
// when its window opened; pruned after the TTL so the lists stay bounded with the radar closed.
Penya_Event :: struct {
  amount: i64,
  pos:    [3]f32,
  t:      i64, // time.now()._nsec
  seq:    i64,
}
Kill_Event :: struct {
  pos: [3]f32,
  t:   i64,
  seq: i64,
}
EVENT_TTL :: i64(5_000_000_000) // drop penya/kill events older than this (~5s; radar juice is sub-second)

// Watch the live penya field and record gains; prune stale penya/kill events. Called every watcher tick
// (module_tick) AND every radar frame under exec_mutex, so the total accrues whether or not the radar is
// open, and both callers are serialized by the mutex (no double-count). Inert until findpenya pins penya_off.
penya_tick :: proc(session: ^Session) {
  if !session.attached {
    return
  }
  now := time.now()._nsec
  if session.layout.penya_off != 0 {
    handle := session.proc_info.handle
    base := session.proc_info.base
    pt := session.ptr_size == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
    player := read_ptr_at(handle, base + session.layout.player_rva, pt)
    if player != 0 {
      if pvv, ok := engine.read_value(handle, player + uintptr(session.layout.penya_off), .U32); ok {
        cur := i64(u32(engine.value_as_u64(.U32, pvv)))
        if !session.penya_seeded {
          session.penya_last = cur
          session.penya_seeded = true
        } else if cur > session.penya_last {
          gain := cur - session.penya_last
          session.penya_total += gain
          session.penya_seq += 1
          pos, _ := read_player_pos(session)
          append(&session.penya_events, Penya_Event{amount = gain, pos = pos, t = now, seq = session.penya_seq})
          session.penya_last = cur
        } else if cur < session.penya_last {
          session.penya_last = cur // spent penya (repair / buy) - re-baseline, no pop
        }
      }
    }
  }
  // Prune expired events (both lists). ordered_remove keeps chronological order for the radar drain.
  for i := 0; i < len(session.penya_events); {
    if now - session.penya_events[i].t > EVENT_TTL {
      ordered_remove(&session.penya_events, i)
    } else {
      i += 1
    }
  }
  for i := 0; i < len(session.kill_events); {
    if now - session.kill_events[i].t > EVENT_TTL {
      ordered_remove(&session.kill_events, i)
    } else {
      i += 1
    }
  }
}

// Record a confirmed kill at <pos> for the radar's laser/zap juice. Shared by both kill sites.
record_kill_event :: proc(session: ^Session, pos: [3]f32, now: i64) {
  session.kill_seq += 1
  append(&session.kill_events, Kill_Event{pos = pos, t = now, seq = session.kill_seq})
}

// Detect a HAND kill (auto off) so the radar laser/zap still fire when you farm manually. Watches the
// player's own m_pObjFocus: when the watched target's HP hits 0 it records ONE kill event at its last
// live position. No-op while auto is on (auto_tick owns kill detection then - running both would double
// the laser, and auto's fast re-target would race this). Called from the radar frame loop (where the
// laser is drawn); the guard obj/recorded flag lives on the session and resets when the focus changes.
kill_watch_tick :: proc(session: ^Session, now: i64) {
  if session.auto_on {
    session.manual_kill_obj = 0
    session.manual_kill_recorded = false
    return
  }
  focus, ok := read_focus_ptr(session)
  if !ok || focus == 0 || !focus_obj_live(session, focus) {
    session.manual_kill_obj = 0
    session.manual_kill_recorded = false
    return
  }
  if focus != session.manual_kill_obj {
    session.manual_kill_obj = focus // a new target - track it fresh
    session.manual_kill_recorded = false
  }
  if pos, pok := engine.read_vec3(session.proc_info.handle, focus + uintptr(session.layout.pos_off)); pok {
    session.manual_kill_pos = pos // keep the death-spot fresh while it's alive
  }
  if !session.manual_kill_recorded {
    if hp, hok := read_mob_hp(session, focus); hok && hp <= 0 {
      record_kill_event(session, session.manual_kill_pos, now) // it just died - one beam + zap
      session.manual_kill_recorded = true
    }
  }
}

// Human-readable run timer: "45s", "4m12s", "1h04m22s".
fmt_elapsed :: proc(ns: i64) -> string {
  s := ns / 1_000_000_000
  if s < 0 {
    s = 0
  }
  h := s / 3600
  m := (s % 3600) / 60
  sec := s % 60
  if h > 0 {
    return fmt.tprintf("%dh%02dm%02ds", h, m, sec)
  }
  if m > 0 {
    return fmt.tprintf("%dm%02ds", m, sec)
  }
  return fmt.tprintf("%ds", sec)
}

// One-line auto-farm stats since toggle-on: kill counter, run timer, kills/min.
auto_stats :: proc(session: ^Session, now: i64) -> string {
  el := now - session.auto_start
  if el < 0 {
    el = 0
  }
  mins := f64(el) / 60_000_000_000.0
  kpm := mins > 0 ? f64(session.auto_count) / mins : 0
  ppos, ppos_ok := read_player_pos(session)
  if !ppos_ok {
    return fmt.tprintf("kill #%d  %s  %.1f/min", session.auto_count, fmt_elapsed(el), kpm)
  }
  return fmt.tprintf("kill #%d  %s  %.1f/min dist_3d: %.1f", session.auto_count, fmt_elapsed(el), kpm, engine.dist_3d(session.last_kill_pos, ppos))
}

// Panel variant of auto_stats: the essentials only, sized for larger type. dist_3d is dropped on
// purpose - it measures walk-since-last-kill and read as noise in the UI; the CLI line keeps it.
auto_stats_panel :: proc(session: ^Session, now: i64) -> string {
  el := now - session.auto_start
  if el < 0 {
    el = 0
  }
  mins := f64(el) / 60_000_000_000.0
  kpm := mins > 0 ? f64(session.auto_count) / mins : 0
  return fmt.tprintf("kill #%d  %s  %.1f/min", session.auto_count, fmt_elapsed(el), kpm)
}

// Stop condition for the 'kills' command: once the run's confirmed-kill count reaches auto_count_limit,
// turn auto-farm off and self-disarm. Returns true if it fired (so a caller can skip advancing to a
// next mob). No-op (returns false) while disarmed or below the quota. Mirrors the timer stop in auto_tick.
auto_count_reached :: proc(session: ^Session, now: i64) -> bool {
  if session.auto_count_limit == 0 || session.auto_count < session.auto_count_limit {
    return false
  }
  session.auto_on = false
  session.auto_count_limit = 0
  session.auto_paused = false
  session.pause_obj = 0
  fmt.printf("\n[auto] count reached (%d kills) - auto-farm OFF.  %s\n", session.auto_count, auto_stats(session, now))
  fmt.print("memscan> ")
  return true
}

// Progress monitor for the focused mob, called every tick while a live target is selected. Detects
// the character jamming against an obstacle: if the player->target distance stops dropping for
// STUCK_NS while still farther than ARRIVE_DIST, the mob is unreachable -> blacklist it and clear
// focus so the next tick re-acquires a reachable one. Reaching/attacking keeps d <= ARRIVE_DIST so
// combat is never flagged; a kill clears focus through the normal (advance) path instead.
auto_monitor :: proc(session: ^Session, focus: uintptr, now: i64) {
  // New target (or first sighting) -> (re)establish the baseline; judge progress from the next tick.
  if focus != session.auto_focus_obj {
    session.auto_focus_obj = focus
    session.auto_best_dist = 1e30
    session.auto_progress_at = now
    return
  }
  handle := session.proc_info.handle
  ppos, pok := read_player_pos(session)
  tpos, tok := engine.read_vec3(handle, focus + uintptr(session.layout.pos_off))
  if !pok || !tok {
    return // transient read failure; retry next tick
  }
  d := engine.dist_3d(ppos, tpos)
  if d <= ARRIVE_DIST {
    // Arrived / in melee - keep the window fresh so standing in combat never trips the monitor.
    session.auto_best_dist = d
    session.auto_progress_at = now
    return
  }
  if d < session.auto_best_dist - PROGRESS_EPS {
    // Closing in - real progress. Reset the stuck window (and the hunt side-step flip cadence).
    session.auto_best_dist = d
    session.auto_progress_at = now
    session.hunt_sidestep_count = 0
    return
  }
  // Plateaued while still far. Once that's persisted for STUCK_NS, treat the mob as blocked.
  if now - session.auto_progress_at >= STUCK_NS {
    if session.hunt_on {
      // Hunt commits to this target: never drop it - side-step around the obstacle and re-lock (below).
      hunt_on_stuck(session, focus, ppos, tpos, now)
    } else {
      auto_skip_blocked(session, focus, ppos, tpos, fmt.tprintf("blocked (d=%.1f)", d), true, now)
    }
  }
}

// Blacklist <focus> and clear m_pObjFocus so the next tick advances to a different mob. Shared by the
// distance-plateau stuck monitor (auto_monitor) and the locked-target reach re-watch (auto_reach_watch).
// <reason> feeds the log line; <steer> arms the one-shot opposite-side avoid hint (the stuck case - a
// reach-loss skip keeps picking freely, since a blocked sightline is not a jam direction).
auto_skip_blocked :: proc(session: ^Session, focus: uintptr, ppos, tpos: [3]f32, reason: string, steer: bool, now: i64) {
  name, _ := read_mover_name(session, focus)
  mark_blocked(session, focus, now)
  if steer {
    // We jammed trying to reach this mob, so the obstacle is roughly in its direction. Hint the next
    // pick to steer to the opposite side of us (see the retarget in tc_select).
    session.auto_avoid_dir = {tpos[0] - ppos[0], tpos[2] - ppos[2]}
    session.auto_avoid_on = true
  }
  // Clear m_pObjFocus so the next tick advances; reset tracking + throttle so it fires promptly.
  clear_focus(session)
  session.auto_last = 0
  session.auto_next_set = false // the precompute for this abandoned target is stale
  session.auto_next_for = 0
  fmt.printf("\n[auto] '%s' %s - skipping\n", name, reason)
  fmt.print("memscan> ")
}

// Write 0 into m_pObjFocus (deselect the current target) and clear the progress-monitor anchor. Shared by
// auto_skip_blocked (blacklist + drop) and hunt_on_stuck (unlock so a moveto side-step isn't overridden by
// the held-attack walk-in). Does NOT touch the advance/precompute bookkeeping - the caller owns that.
clear_focus :: proc(session: ^Session) {
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  if wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt); wok {
    world := uintptr(engine.value_as_u64(pt, wv))
    if world != 0 {
      engine.write_value(handle, world + uintptr(session.layout.focus_off), pt, engine.ptr_to_value(0, session.ptr_size))
    }
  }
  session.auto_focus_obj = 0
}

// Reach re-watch for the LOCKED target (reach used to be checked only at pick time): a mob can be
// dragged behind a collider - or we can chase it onto unreachable ground - after selection, and the
// old behavior kept pushing into the wall until the distance-plateau monitor fired. Probes the
// straight approach every REACH_RECHECK_NS; REACH_BLOCKED_DEBOUNCE consecutive blocked probes
// (transient clips happen while rounding corners) skip the mob like a stuck-skip, minus the steer
// hint. Cheap: compute_reach is pure math once the collider cache is warm. Gated on reach_gate_on at
// the call site (auto_tick).
auto_reach_watch :: proc(session: ^Session, focus: uintptr, now: i64) {
  if focus != session.auto_reach_obj {
    session.auto_reach_obj = focus
    session.auto_reach_next_check = now + REACH_RECHECK_NS
    session.auto_reach_fail_count = 0
    return
  }
  if now < session.auto_reach_next_check {
    return
  }
  session.auto_reach_next_check = now + REACH_RECHECK_NS
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := session.ptr_size == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  if !wok {
    return
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  if world == 0 {
    return
  }
  ppos, pok := read_player_pos(session)
  tpos, tok := engine.read_vec3(handle, focus + uintptr(session.layout.pos_off))
  if !pok || !tok {
    return // transient read failure; retry at the next probe
  }
  if engine.dist_3d(ppos, tpos) <= ARRIVE_DIST {
    session.auto_reach_fail_count = 0 // already on top of it - combat, reach is moot
    return
  }
  if cand_reachable(session, world, ppos, tpos) {
    session.auto_reach_fail_count = 0
    return
  }
  session.auto_reach_fail_count += 1
  if session.auto_reach_fail_count >= REACH_BLOCKED_DEBOUNCE {
    session.auto_reach_fail_count = 0
    auto_skip_blocked(session, focus, ppos, tpos, "unreachable", false, now)
  }
}

// Read a mover's current HP (hp_off). ok=false when hp_off isn't configured or the read fails.
read_mob_hp :: proc(session: ^Session, obj: uintptr) -> (hp: i64, ok: bool) {
  if session.layout.hp_off == 0 {
    return 0, false
  }
  if v, rok := engine.read_value(session.proc_info.handle, obj + uintptr(session.layout.hp_off), .U32); rok {
    return i64(u32(engine.value_as_u64(.U32, v))), true
  }
  return 0, false
}

// Called every tick while auto is PAUSED. It doesn't advance/select; it just watches the currently
// targeted mob and resumes auto when that mob is KILLED (HP hits 0, or it despawns/frees). A mere
// deselect (mob still alive) keeps us paused, and with no target it idles - so you resume by targeting
// a mob and killing it (this is also how the armed 'auto' kicks off on the first kill).
pause_tick :: proc(session: ^Session, now: i64) {
  focus, fok := read_focus_ptr(session)
  if fok && focus != 0 && focus_obj_live(session, focus) {
    if hp, hok := read_mob_hp(session, focus); hok && hp <= 0 {
      pause_resume(session, focus, now) // HP hit 0 while focused = kill
      return
    }
    session.pause_obj = focus // alive (or HP unknown) - keep watching this one
    return
  }
  // No live target now. If we were watching one, tell a kill (freed / HP<=0) from a plain deselect.
  if session.pause_obj != 0 {
    watched := session.pause_obj
    session.pause_obj = 0
    killed := !focus_obj_live(session, watched)
    if !killed {
      if hp, hok := read_mob_hp(session, watched); hok && hp <= 0 {
        killed = true
      }
    }
    if killed {
      pause_resume(session, watched, now)
    }
  }
}

// Leave the paused state and let auto resume advancing. Seeds the bow-range anchor from where the mob
// died so the first pick after resuming stays on that spot's pack.
pause_resume :: proc(session: ^Session, killed_obj: uintptr, now: i64) {
  session.auto_paused = false
  session.pause_obj = 0
  session.auto_count += 1 // the kill that resumes us counts too (this is the first kill when armed)
  if pos, ok := engine.read_vec3(session.proc_info.handle, killed_obj + uintptr(session.layout.pos_off)); ok {
    session.last_kill_pos = pos
    session.last_kill_set = true
    record_kill_event(session, pos, now) // radar laser + zap
  }
  session.auto_last = 0 // advance promptly on the next tick
  fmt.printf("\n[auto] resumed (kill).  %s\n", auto_stats(session, now))
  fmt.print("memscan> ")
  auto_count_reached(session, now) // 'kills 1' (or a mid-run re-arm at/below current count): stop right away
}

// Auto-farm tick: called every ~20ms by the watcher thread. When a live target is selected, run the
// obstacle monitor (auto_monitor). When no live target is selected (m_pObjFocus cleared on kill, or
// pointing at a freed object), advance the focus to the next fresh mob matching auto_names. Your held
// attack key then keeps attacking it.
auto_tick :: proc(session: ^Session) {
  if !session.attached {
    return
  }
  now := time.now()._nsec
  // Auto-off timer ('timer' command): when the deadline passes, stop auto-farm. Self-disarms even
  // if auto is already off (silently, so a stale deadline can't kill a later run).
  if session.auto_timer_at != 0 && now >= session.auto_timer_at {
    was_on := session.auto_on
    session.auto_on = false
    session.auto_timer_at = 0
    session.auto_paused = false
    session.pause_obj = 0
    session.la_approach_on = false // cancel any in-progress look-alive walk
    if was_on {
      fmt.printf("\n[auto] timer elapsed - auto-farm OFF.  %s\n", auto_stats(session, now))
      fmt.print("memscan> ")
    }
    return
  }
  if !session.auto_on {
    return
  }
  // Paused (armed): don't advance; just watch the targeted mob and resume auto when it's killed.
  if session.auto_paused {
    pause_tick(session, now)
    return
  }
  // Look-alive approach in progress: we've picked the next mob but are still WALKING to it (waypoints)
  // before locking. Runs every tick (unthrottled) for responsive arrival detection, ahead of the normal
  // focus-live / advance logic - nothing is locked yet, so the focus-live branch below would never fire.
  if session.la_approach_on {
    lookalive_approach_tick(session, now)
    return
  }
  // A live target is still selected: watch it for obstacle-stuck (every tick, unthrottled) and, while
  // we fight it, precompute the NEXT target so the advance is instant when it dies (pre-select).
  if focus, fok := read_focus_ptr(session); fok && focus != 0 && focus_obj_live(session, focus) {
    if session.auto_stuck_on {
      auto_monitor(session, focus, now)
    }
    if session.reach_gate_on && !session.hunt_on {
      auto_reach_watch(session, focus, now) // reach can be lost AFTER selection - watch it, don't jam
      // (hunt commits to the target and never drops it for reachability - it side-steps instead, below)
    }
    // hunt_on_stuck (above) may have unlocked the target and entered the side-step approach - if so, the
    // pre-select work below would run against a now-cleared focus. Hand off to the approach next tick.
    if session.la_approach_on {
      return
    }
    if session.preselect_on && focus != session.auto_next_for {
      // One precompute per distinct locked target, stutter-safe: the expensive enumeration runs on a
      // background worker (tc_scan_request) with no lock held; only the cheap cascade tail runs here.
      // auto_next_for is marked when the batch is CONSUMED (not requested), so this branch re-enters
      // until the worker publishes; scan_job.active stops it re-requesting meanwhile.
      if session.scan_job.res_ready && session.scan_job.res_for == focus {
        cands := session.scan_job.res_cands
        anchor := session.scan_job.res_anchor
        anchor_set := session.scan_job.res_anchor_set
        session.scan_job.res_ready = false
        session.scan_job.res_cands = nil
        session.auto_next_for = focus
        session.auto_next_set = false
        if world, _, lplayer, aok := tc_resolve_anchors(session); aok {
          if nobj, npos, nstage, npack, nok := tc_finish_precompute(session, cands[:], session.auto_names[:], world, anchor, anchor_set, focus, lplayer); nok {
            session.auto_next_obj = nobj
            session.auto_next_pos = npos
            session.auto_next_stage = nstage
            session.auto_next_pack = npack
            session.auto_next_anchor = anchor
            session.auto_next_set = true
          }
        }
        delete(cands)
      } else if !session.scan_job.active {
        if world, player, player_pos, aok := tc_resolve_anchors(session); aok {
          anchor, anchor_set := tc_precompute_anchor(session, focus, player_pos)
          tc_scan_request(session, session.auto_names[:], world, player, anchor, anchor_set, focus)
        }
      }
    } else if session.preselect_on && session.auto_next_set {
      // The cache was measured from the fight's position at lock time (auto_next_anchor). If the fight
      // drags away from that spot the cached "next" is anchored to stale ground - re-arm so the next
      // tick recomputes from where the fight actually is. One cheap read per tick; the full rescan only
      // happens on real drift.
      if cpos, cok := engine.read_vec3(session.proc_info.handle, focus + uintptr(session.layout.pos_off)); cok {
        if engine.dist_horizontal(cpos, session.auto_next_anchor) > PRESELECT_DRIFT_MAX {
          session.auto_next_for = 0
          session.auto_next_set = false
        }
      }
    }
    if session.lookalive_on {
      lookalive_jump_tick(session, focus, now) // occasional jump while travelling to the target
    }
    return
  }
  // Focus cleared (kill) or focused obj freed -> advance to the next fresh mob. Throttle only this
  // rescan path (not the monitor above) so idle rescans stay capped.
  if now - session.auto_last < AUTO_MIN_INTERVAL_NS {
    return
  }
  session.auto_focus_obj = 0 // reset progress tracking for the mob we're about to pick
  // The focus cleared. If that was a genuine KILL (not a stuck-skip, which sets auto_avoid_on),
  // count it, anchor the next pick to its spot, and print - a kill is the ONLY thing that prints here.
  // auto_avoid_on is still set at this point (tc_select consumes it just below), so this reads it.
  if session.auto_sel_set {
    // Confirm the selected mob actually died (freed, or HP<=0) rather than being deselected - so a
    // stray Esc/deselect never prints a phantom kill. Stuck-skips (auto_avoid_on) are never kills.
    died := false
    if !session.auto_avoid_on {
      if !focus_obj_live(session, session.auto_sel_obj) {
        died = true
      } else if hp, hok := read_mob_hp(session, session.auto_sel_obj); hok && hp <= 0 {
        died = true
      }
    }
    if died {
      session.auto_count += 1
      session.last_kill_pos = session.auto_sel_pos
      session.last_kill_set = true
      record_kill_event(session, session.auto_sel_pos, now) // radar laser + zap
      fmt.printf("\n[auto] %s\n", auto_stats(session, now))
      fmt.print("memscan> ")
    }
    session.auto_sel_set = false
    // Hit the kill quota ('kills' command)? Stop before advancing so we don't grab an extra target.
    if died && auto_count_reached(session, now) {
      return
    }
  }
  // Look-alive: a randomized "human reaction" hesitation before engaging the next target (delayed
  // lock-on). Holds the whole advance - including the pre-select fast-commit - so we don't insta-lock
  // onto the next mob the instant the current one dies. The kill above is still counted immediately.
  // Gated on the per-feature enable: with hesitation off, we advance without any hold.
  if session.lookalive_on && session.layout.la_hesitate_on {
    if session.lookalive_hold_until == 0 {
      session.lookalive_hold_until = now + lookalive_rand_ns(la_secs_ns(session.layout.la_hold_min), la_secs_ns(session.layout.la_hold_max))
      return
    }
    if now < session.lookalive_hold_until {
      return // still hesitating
    }
    session.lookalive_hold_until = 0 // hold elapsed - engage now; re-armed on the next kill
  }
  // Look-alive walk-first approach (intermediate step / max-range): before locking, pick the next mob
  // WITHOUT locking and, if it's far enough / rolls the chance, walk there via waypoints and lock only on
  // arrival (see lookalive_approach_tick). Needs moveto (findmove). This mode bypasses the pre-select fast
  // path - fine, since look-alive targets low-spawn grinds where a per-kill synchronous pick isn't a
  // stutter concern (the background-scan fix exists for high kill rates).
  if session.lookalive_on && (session.layout.la_step_on || session.layout.la_maxrange_on) && moveto_configured(session) {
    session.auto_next_set = false // the pre-select cache is unused in approach mode; don't let it commit stale
    session.auto_next_for = 0
    if obj, tpos, stage, pack, _, ok := tc_precompute_next(session, session.auto_names[:], 0); ok {
      if ppos, pok := read_player_pos(session); pok {
        dist := engine.dist_horizontal(ppos, tpos)
        multi := session.layout.la_maxrange_on && dist > session.layout.la_max_range
        single := !multi && session.layout.la_step_on && dist > LA_STEP_MIN_DIST && lookalive_step_roll(session.layout.la_step_chance)
        if multi || single {
          lookalive_begin_approach(session, obj, tpos, stage, pack, multi, now)
          session.auto_last = now
          return
        }
        // Close, or the step roll failed - lock it straight away like the normal advance.
        if auto_commit_pick(session, obj, tpos, stage, pack) {
          session.auto_last = now
          return
        }
      }
    }
    // Nothing eligible / pick failed: fall through to the reactive advance (auto_next_set is cleared, so
    // the pre-select branch is skipped and the background scan handles it).
  }
  // Advance to the next mob. Pre-select fast path: if we precomputed a next target during combat (and
  // this isn't a stuck-skip, which needs the reactive avoid steer), commit it instantly with no scan.
  // The cache can be seconds old (one precompute per locked target), so it's re-validated first:
  // tc_precompute_still_valid covers position drift / reach / fence, focus_set_obj covers freed/HP/
  // model. On any staleness we fall through to the reactive tc_select scan THIS SAME tick - worst case
  // is the old post-kill behavior, best case is instant.
  advanced := false
  if session.preselect_on && session.auto_next_set && !session.auto_avoid_on {
    nobj := session.auto_next_obj
    nstage := session.auto_next_stage
    npack := session.auto_next_pack
    session.auto_next_set = false
    if lpos, lok := tc_precompute_still_valid(session, nobj, session.auto_next_pos); lok {
      if auto_commit_pick(session, nobj, lpos, nstage, npack) {
        advanced = true
      }
    }
  }
  session.auto_next_for = 0 // re-arm the precompute for whatever target we land on
  if !advanced {
    // Reactive advance, stutter-safe: consume a finished background batch if one is waiting (a
    // pre-select batch doubles as one - its anchor IS the kill spot - with the dead focus excluded),
    // else kick a scan off and stand idle a tick or two while it runs off-thread. Selection itself is
    // silent - no print unless something died above.
    if session.scan_job.res_ready {
      cands := session.scan_job.res_cands
      anchor := session.scan_job.res_anchor
      excl := session.scan_job.res_for
      session.scan_job.res_ready = false
      session.scan_job.res_cands = nil
      if world, _, _, aok := tc_resolve_anchors(session); aok {
        tc_finish_select(session, cands[:], session.auto_names[:], world, anchor, true, excl)
      }
      delete(cands)
    } else if !session.scan_job.active {
      if world, player, player_pos, aok := tc_resolve_anchors(session); aok {
        tc_scan_request(session, session.auto_names[:], world, player, player_pos, false, 0)
      }
    }
  }
  session.auto_last = now
}

// Parse a raw target argument into a list of names. Comma-separated; each name may be wrapped
// in single/double quotes and may contain spaces. Empty input (or only whitespace) yields an
// empty list, meaning "any monster". Allocated in the temp allocator. Examples:
//   ""                                        -> []            (any monster)
//   "Aibatt"                                  -> ["Aibatt"]
//   "Mutant Yetti"                            -> ["Mutant Yetti"]
//   "'Club-tailed Reptillion', 'Captain ...'" -> ["Club-tailed Reptillion", "Captain ..."]
parse_target_names :: proc(raw: string) -> [dynamic]string {
  out := make([dynamic]string, context.temp_allocator)
  for part in strings.split(raw, ",", context.temp_allocator) {
    n := strings.trim_space(part)
    n = strings.trim(n, "'\"") // strip one layer of surrounding quotes
    n = strings.trim_space(n)
    if len(n) > 0 {
      append(&out, n)
    }
  }
  return out
}

// Human-readable description of a target-name list, for status/log lines.
//   []            -> "any monster"
//   ["A"]         -> "'A'"
//   ["A","B"]     -> "'A', 'B'"
auto_target_desc :: proc(names: []string) -> string {
  if len(names) == 0 {
    return "any monster"
  }
  sb := strings.builder_make(context.temp_allocator)
  for n, i in names {
    if i > 0 {
      fmt.sbprint(&sb, ", ")
    }
    fmt.sbprintf(&sb, "'%s'", n)
  }
  return strings.to_string(sb)
}

// Set-equality of two name lists (order-insensitive, case-insensitive). Two empty lists are
// equal (both "any monster"), so re-issuing the same request toggles auto off.
names_equal :: proc(a, b: []string) -> bool {
  if len(a) != len(b) {
    return false
  }
  for x in a {
    if !name_matches(x, b) {
      return false
    }
  }
  return true
}

// Free the cloned auto_names list (each string + the backing array). Idempotent.
auto_free_names :: proc(session: ^Session) {
  for n in session.auto_names {
    delete(n)
  }
  delete(session.auto_names)
  session.auto_names = nil
}

// Replace auto_names with persistent clones of <names> (default allocator, so they survive
// across REPL/watcher calls). Frees the previous list first.
auto_set_names :: proc(session: ^Session, names: []string) {
  auto_free_names(session)
  session.auto_names = make([dynamic]string)
  for n in names {
    append(&session.auto_names, strings.clone(n))
  }
}

// Remember the target spec of this auto run so the F10 hotkey can re-arm the same hunt after an
// 'auto off' (see module_tick / auto_rearm_command). Survives auto_stop; freed on session close.
auto_remember_spec :: proc(session: ^Session, names: []string) {
  for n in session.last_auto_names {
    delete(n)
  }
  clear(&session.last_auto_names)
  if session.last_auto_names == nil {
    session.last_auto_names = make([dynamic]string)
  }
  for n in names {
    append(&session.last_auto_names, strings.clone(n))
  }
  session.last_auto_set = true
}

// The command line F10 re-arms auto with: the remembered spec in the same quoted-comma form the
// panel's Start button builds, or any-monster when nothing was remembered. Temp-allocated.
auto_rearm_command :: proc(session: ^Session) -> string {
  if !session.last_auto_set || len(session.last_auto_names) == 0 {
    return "auto any"
  }
  sb := strings.builder_make(context.temp_allocator)
  fmt.sbprint(&sb, "auto ")
  for n, i in session.last_auto_names {
    if i > 0 {
      fmt.sbprint(&sb, ", ")
    }
    fmt.sbprintf(&sb, "'%s'", n)
  }
  return strings.to_string(sb)
}

// If auto is in any-monster mode (empty name list) but the species prop-table gate isn't configured
// yet, warn that pets / other players / NPCs will also be targeted, and point at the one-time fix.
auto_warn_mobgate :: proc(session: ^Session) {
  if len(session.auto_names) == 0 && !prop_gate_ready(session) {
    fmt.println("  note: any-monster mode will also target pets / players / NPCs until you run 'findprop' once (a few distinct monsters on screen; no target needed).")
  }
}

// Turn auto-farm off and clear all its run state - timers, kill quota, progress/anchor tracking, the
// stuck blacklist, and pause. Shared by 'auto off'/'auto stop', the same-request toggle, and detach.
auto_stop :: proc(session: ^Session) {
  session.auto_on = false
  session.auto_timer_at = 0 // stopping the run cancels any pending auto-off timer
  session.auto_count_limit = 0 // ...and any pending kill-count limit
  session.auto_focus_obj = 0
  session.auto_avoid_on = false
  session.auto_sel_set = false
  session.auto_start = 0
  session.auto_count = 0
  session.last_kill_set = false
  session.auto_paused = false
  session.pause_obj = 0
  session.auto_next_set = false
  session.auto_next_for = 0
  session.auto_next_obj = 0
  session.auto_next_stage = .None
  session.auto_next_pack = 0
  session.auto_next_anchor = {}
  session.cluster_committed = false
  session.cluster_origin_pos = {}
  session.lookalive_hold_until = 0 // run-state only; lookalive_on persists (a mode toggle)
  session.lookalive_jump_at = 0
  session.la_approach_on = false // abandon any in-progress look-alive walk
  session.la_approach_obj = 0
  session.hunt_side_flip = false // hunt side-step state is per-run (hunt_on the mode persists)
  session.hunt_sidestep_count = 0
  session.auto_reach_obj = 0 // reach re-watch state is per-run
  session.auto_reach_next_check = 0
  session.auto_reach_fail_count = 0
  clear(&session.auto_blocked)
  tc_scan_invalidate(session) // orphan any in-flight background scan; its publish will discard
}

// auto                     -> off: start farming ANY nearby monster;  on: show status
// auto off | auto stop     -> turn auto-farm off
// auto any                 -> explicitly farm any monster (same as bare 'auto' when off)
// auto <name>              -> farm <name> (re-issuing the same request toggles off)
// auto 'A', 'B', ...       -> farm any of the listed names (comma-separated; quote names that
//                             contain spaces). A different request while on switches target.
// Good to bind to a single hotkey (re-issue toggles).
cli_auto :: proc(session: ^Session, args: []string) {
  // Stop.
  if len(args) == 1 && (args[0] == "off" || args[0] == "stop") {
    if session.auto_on {
      auto_stop(session)
      fmt.printfln("auto-farm OFF.  %s", auto_stats(session, time.now()._nsec))
    } else {
      fmt.println("auto-farm already off.")
    }
    return
  }

  // Bare 'auto' while running -> status peek (don't disturb the run). When off it falls through
  // and starts any-monster mode.
  if len(args) == 0 && session.auto_on {
    state := session.auto_paused ? "ARMED/paused" : "ON"
    fmt.printfln("auto-farm %s: %s.  %s", state, auto_target_desc(session.auto_names[:]), auto_stats(session, time.now()._nsec))
    fmt.printfln(
      "  stuck:%s  preselect:%s  lookalive:%s  reachgate:%s  density:%s",
      session.auto_stuck_on ? "on" : "off",
      session.preselect_on ? "on" : "off",
      session.lookalive_on ? "on" : "off",
      session.reach_gate_on ? "on" : "off",
      session.layout.density_on ? fmt.tprintf("on (mingain=%d detour=%v)", session.layout.density_min_gain, session.layout.density_max_detour) : "off",
    )
    return
  }

  // Resolve the requested targets. No args, or the alias any/anything/*, means "any monster".
  names := parse_target_names(strings.join(args, " ", context.temp_allocator))
  if len(names) == 1 &&
     (strings.equal_fold(names[0], "any") || strings.equal_fold(names[0], "anything") || names[0] == "*") {
    clear(&names)
  }

  // Already running -> the same request toggles off; a different one switches target.
  if session.auto_on {
    if names_equal(names[:], session.auto_names[:]) {
      auto_stop(session)
      fmt.printfln("auto-farm OFF.  %s", auto_stats(session, time.now()._nsec))
      return
    }
    auto_set_names(session, names[:])
    auto_remember_spec(session, names[:])
    tc_scan_invalidate(session) // any in-flight/pending batch was collected for the old names
    session.auto_last = 0
    fmt.printfln("auto-farm target -> %s.", auto_target_desc(session.auto_names[:]))
    auto_warn_mobgate(session)
    return
  }

  // Start.
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  // Preflight: warn (don't block) if required setup is missing, so a broken config doesn't silently farm
  // nothing. Non-fatal - auto still ARMs (you engage the first mob yourself). See `setup` / `status`.
  {
    miss := make([dynamic]string, context.temp_allocator)
    for g in setup_groups(session) {
      if g.required && !g.ok {append(&miss, g.label)}
    }
    if len(miss) > 0 {
      fmt.eprintfln("[!] setup incomplete: %s - run `setup <name>` for reliable farming (`status` for detail).", strings.join(miss[:], ", ", context.temp_allocator))
    }
  }
  auto_set_names(session, names[:])
  auto_remember_spec(session, names[:])
  session.auto_last = 0
  session.auto_count = 0
  session.auto_start = time.now()._nsec
  session.auto_focus_obj = 0 // reset obstacle/stuck tracking for the new run
  session.auto_avoid_on = false
  session.auto_sel_set = false
  session.last_kill_set = false
  session.cluster_committed = false // a new run starts uncommitted; the first pick decides
  session.cluster_origin_pos = {}
  clear(&session.auto_blocked)
  // Start ARMED (paused): the first kill kicks off farming (see pause_tick). This avoids auto grabbing
  // a target the instant you type the command - you engage the first mob yourself.
  session.auto_paused = true
  session.pause_obj = 0
  session.auto_on = true
  engine.ensure_hotkey_thread(&session.eng)
  fmt.printfln(
    "auto-farm ARMED: %s. target a mob and kill it to start; then it advances on each kill. F10 stops/starts, 'pause' to pause.",
    auto_target_desc(session.auto_names[:]),
  )
  auto_warn_mobgate(session)
}

// stuck | stuck on|off -> toggle obstacle/stuck detection (auto_monitor). On by default. Disable for
// ranged/standing playstyles that attack without closing in, where "not getting closer" is normal and
// would otherwise be mis-read as blocked.
cli_stuck :: proc(session: ^Session, args: []string) {
  switch {
  case len(args) == 0:
    session.auto_stuck_on = !session.auto_stuck_on
  case len(args) == 1 && args[0] == "on":
    session.auto_stuck_on = true
  case len(args) == 1 && args[0] == "off":
    session.auto_stuck_on = false
  case:
    fmt.eprintln("usage: stuck [on|off]")
    return
  }
  fmt.printfln("stuck-detection %s.", session.auto_stuck_on ? "ON" : "OFF")
}

// preselect | preselect on|off -> toggle pre-selection: while fighting a mob, precompute the NEXT target
// and commit it the instant the current one dies, removing the ~0.5s post-kill enumeration gap. On by
// default. A latency/smoothness setting: the precompute measures everything from the CURRENT TARGET's
// position (= where you'll stand at kill time, see tc_precompute_next), so it picks what the reactive
// post-kill scan would. (Pre-1.0 it measured from the live player - i.e. the PREVIOUS kill spot, since
// the focus locks before the walk - which committed a behind-us "nearest" on every kill: the ping-pong
// bug.) Turn off to revert to scan-after-kill.
cli_preselect :: proc(session: ^Session, args: []string) {
  switch {
  case len(args) == 0:
    session.preselect_on = !session.preselect_on
  case len(args) == 1 && args[0] == "on":
    session.preselect_on = true
  case len(args) == 1 && args[0] == "off":
    session.preselect_on = false
  case:
    fmt.eprintln("usage: preselect [on|off]")
    return
  }
  if !session.preselect_on {
    session.auto_next_set = false // drop any cached pick so a re-enable starts fresh
    session.auto_next_for = 0
    session.auto_next_stage = .None
    session.auto_next_pack = 0
  }
  session.layout.preselect_on = session.preselect_on // cfg mirror (see on_attach)
  if session.attached {
    flyff_save_cfg(session.layout, flyff_cfg_path()) // attach-gated: pre-attach layout is defaults - never clobber a calibrated cfg with it
  }
  fmt.printfln("pre-select %s.", session.preselect_on ? "ON" : "OFF")
}

// ===========================================================================
// Look-alive mode: opt-in human-like farming for low-spawn quest grinds.
// ===========================================================================

// Look-alive tuning. The post-kill hesitation before engaging the next target (delayed lock-on), the
// interval between travel-jumps, and whether any given jump window fires are each randomized per event so
// the cadence never reads as robotic. The delay ranges + jump chance are USER-TUNABLE and persisted in
// flyff.cfg (Flyff_Layout.la_*; defaults FLYFF_LA_* in flyff.odin) - edit them via the radar Options
// "look-alive" section or 'lookalive hold|jump|chance'. Only the fixed cutoffs below stay constants.
LA_JUMP_MIN_DIST :: f32(8.0) // only jump while still this far from the target (travelling, not in melee)
LA_STEP_MIN_DIST :: f32(12.0) // don't bother with a single intermediate detour for mobs nearer than this
LA_WP_ARRIVE :: f32(3.5) // horizontal distance at/under which an approach waypoint counts as reached

// Hunt mode side-step (hunt_on_stuck): how far to the side to step around an obstacle, and how many
// consecutive stalls before flipping to the other side (so a repeatedly-jammed hunt sweeps both ways).
HUNT_SIDESTEP_DIST :: f32(10.0)
HUNT_SIDESTEP_FLIP :: 3

lookalive_seeded: bool // one-time seed guard for the look-alive RNG (see lookalive_seed)

// Seed the context random generator once from the wall clock (on the watcher thread, which owns a valid
// default context) so look-alive runs don't repeat the same delay/jump pattern across restarts.
lookalive_seed :: proc() {
  if !lookalive_seeded {
    rand.reset_u64(u64(time.now()._nsec))
    lookalive_seeded = true
  }
}

// Seconds (a tunable la_* field) -> nanoseconds for the look-alive scheduler. Negatives clamp to 0.
la_secs_ns :: proc(secs: f32) -> i64 {
  if secs <= 0 {
    return 0
  }
  return i64(f64(secs) * 1e9)
}

// Uniform random duration in [lo, hi) nanoseconds for look-alive's jitter. Returns lo when the range is
// empty/inverted (also the natural result of a min==max range, e.g. a fixed delay).
lookalive_rand_ns :: proc(lo, hi: i64) -> i64 {
  lookalive_seed()
  if hi <= lo {
    return lo
  }
  return rand.int64_range(lo, hi)
}

// Uniform random f32 in [lo, hi] for the approach waypoint jitter (perpendicular offset, along-vector
// fraction). Returns lo when the range is empty/inverted.
lookalive_rand_f32 :: proc(lo, hi: f32) -> f32 {
  lookalive_seed()
  if hi <= lo {
    return lo
  }
  return lo + rand.float32() * (hi - lo)
}

// Per-advance roll for the single intermediate detour step. Same 0-100 semantics as the jump-window roll.
lookalive_step_roll :: proc(pct: int) -> bool {
  return lookalive_jump_roll(pct)
}

// True if a scheduled travel-jump should actually fire this window. pct is the 0-100 la_jump_chance:
// <=0 never jumps, >=100 always jumps, in between rolls the seeded RNG. Skipping windows makes the jump
// cadence sporadic (human) rather than a metronome.
lookalive_jump_roll :: proc(pct: int) -> bool {
  if pct >= 100 {
    return true
  }
  if pct <= 0 {
    return false
  }
  lookalive_seed()
  return rand.int_max(100) < pct
}

// Silent check that the jump primitive is fully configured (mirrors jump_ready without its eprintln
// output), so the look-alive hot loop can skip jumps quietly when char-control ('findmove') isn't set up.
jump_configured :: proc(session: ^Session) -> bool {
  if !session.attached || session.ptr_size != 4 {
    return false
  }
  return sendactmsg_rva_sane(session) && session.layout.actmover_off != 0 && session.layout.jump_msg != 0
}

// Fire one look-alive jump: the client's own SendActMsg(jump), then broadcast the jump state so other
// clients see it (best-effort - both primitives no-op silently when unconfigured). No console output.
lookalive_do_jump :: proc(session: ^Session) {
  if ret, ok := remote_send_actmsg(session, session.layout.jump_msg); ok && ret == 1 {
    session.jump_fired_at = time.now()._nsec // radar dot-hop animation, same as manual `jump`
    remote_send_playermoved(session)
  }
}

// Shared travel-jump scheduler core (look-alive). Jumps at randomized intervals while travelling toward
// <tpos> - a locked focus OR the target of an in-progress approach - but only while still >=
// LA_JUMP_MIN_DIST away so we don't hop in place during melee. Seeds the first interval instead of jumping
// on the very first tick. Gated on the la_jump_on enable + jump_configured; disabled/unconfigured no-ops.
lookalive_jump_core :: proc(session: ^Session, tpos: [3]f32, now: i64) {
  if !session.layout.la_jump_on || !jump_configured(session) {
    return
  }
  if session.lookalive_jump_at == 0 {
    session.lookalive_jump_at = now + lookalive_rand_ns(la_secs_ns(session.layout.la_jump_min), la_secs_ns(session.layout.la_jump_max))
    return
  }
  if now < session.lookalive_jump_at {
    return
  }
  // Re-arm the next window regardless of whether we jump this time (so a rolled-skip still advances).
  session.lookalive_jump_at = now + lookalive_rand_ns(la_secs_ns(session.layout.la_jump_min), la_secs_ns(session.layout.la_jump_max))
  if !lookalive_jump_roll(session.layout.la_jump_chance) {
    return // rolled to skip this window - keeps jumping sporadic, not metronomic
  }
  if ppos, pok := read_player_pos(session); pok && engine.dist_horizontal(ppos, tpos) >= LA_JUMP_MIN_DIST {
    lookalive_do_jump(session)
  }
}

// Per-tick travel-jump scheduler while a focus is locked (the game walks us to it): read the focus
// position and defer to the shared core.
lookalive_jump_tick :: proc(session: ^Session, focus: uintptr, now: i64) {
  if !session.layout.la_jump_on || !jump_configured(session) {
    return
  }
  if tpos, tok := engine.read_vec3(session.proc_info.handle, focus + uintptr(session.layout.pos_off)); tok {
    lookalive_jump_core(session, tpos, now)
  }
}

// Silent check that moveto (the CMover dest-field walk) is fully configured - mirrors moveto_ready without
// its eprintln output, so the look-alive approach can skip walking quietly when 'findmove' isn't set up.
moveto_configured :: proc(session: ^Session) -> bool {
  if !session.attached || session.ptr_size != 4 {
    return false
  }
  L := session.layout
  return L.destpos_off != 0 && L.iddest_off != 0 && L.forward_off != 0
}

// Lock <obj> as the active target (m_pObjFocus) and set auto's kill-anchor + density cluster bookkeeping,
// exactly like tc_finish_select's post-pick tail. <live_pos> is the mob's live position (keeps the kill
// anchor honest); <stage>/<pack> feed the cluster commitment. Returns false when the focus write is refused
// (freed / model-less / HP<=0) so the caller can fall back. Shared by the pre-select fast-commit and the
// look-alive approach's arrival-lock.
auto_commit_pick :: proc(session: ^Session, obj: uintptr, live_pos: [3]f32, stage: TC_Stage, pack: int) -> bool {
  if focus_set_obj(session, obj, session.auto_names[:]) != .Picked {
    return false
  }
  session.auto_sel_pos = live_pos
  session.auto_sel_obj = obj
  session.auto_sel_set = true
  if session.layout.density_on {
    _, engage := pick_ranges(session)
    session.cluster_committed, session.cluster_origin_pos = cluster_advance(
      session.cluster_committed, session.cluster_origin_pos, stage, live_pos, pack, density_radius(engage),
    )
  } else {
    session.cluster_committed = false
    session.cluster_origin_pos = {}
  }
  return true
}

// Compute a walk-first waypoint from player <p> toward target <t>: a point ~halfway along the p->t vector
// (fraction jittered 0.4-0.6 so it never reads as exactly halfway), pushed sideways by a random amount
// within la_step_spread perpendicular to that vector. Ground-plane (x/z); Y is taken from p (the client
// ground-clamps the walk). Degenerate (p == t) returns p.
lookalive_step_point :: proc(session: ^Session, p, t: [3]f32) -> [3]f32 {
  dx := t[0] - p[0]
  dz := t[2] - p[2]
  length := math.sqrt(dx * dx + dz * dz)
  if length < 0.001 {
    return p
  }
  frac := lookalive_rand_f32(0.4, 0.6)
  ax := p[0] + dx * frac
  az := p[2] + dz * frac
  // Perpendicular unit vector in the ground plane is (-dz, dx)/length; offset a random signed amount.
  off := lookalive_rand_f32(-session.layout.la_step_spread, session.layout.la_step_spread)
  return {ax + (-dz / length) * off, p[1], az + (dx / length) * off}
}

// Enter the look-alive walk-first approach for <obj> (position <tpos>, cascade <stage>/<pack> carried to
// the eventual lock). <multi> = the max-range shrinking-hop approach; else a single intermediate detour.
// Computes the first waypoint, walks there (moveto = dest field-write + snapshot broadcast), and arms the
// progress watchdog. From here lookalive_approach_tick drives it each tick until it locks or abandons.
lookalive_begin_approach :: proc(session: ^Session, obj: uintptr, tpos: [3]f32, stage: TC_Stage, pack: int, multi: bool, now: i64) {
  ppos, pok := read_player_pos(session)
  if !pok {
    session.la_approach_on = false // can't read our own position - let the normal advance retry
    session.auto_last = 0
    return
  }
  wp := lookalive_step_point(session, ppos, tpos)
  if !write_dest_pos(session, ppos, wp) {
    session.la_approach_on = false
    session.auto_last = 0
    return
  }
  remote_send_snapshot(session) // broadcast so other clients see the walk, not a teleport
  session.la_approach_obj = obj
  session.la_approach_multi = multi
  session.la_approach_stage = stage
  session.la_approach_pack = pack
  session.la_approach_wp = wp
  session.la_approach_best = engine.dist_horizontal(ppos, wp)
  session.la_approach_progress_at = now
  session.la_approach_on = true
}

// Per-tick driver for an in-progress look-alive approach. Re-validates the pending target, watches for a
// stuck plateau against the current waypoint, fires travel-jumps, and - on reaching a waypoint - either
// locks the target (single step, or a multi-hop now inside la_max_range) or walks the next shrinking hop.
lookalive_approach_tick :: proc(session: ^Session, now: i64) {
  world, _, ppos, aok := tc_resolve_anchors(session)
  if !aok {
    return // transient read failure; retry next tick (the walk continues client-side meanwhile)
  }
  obj := session.la_approach_obj
  // Target still a live, selectable mob? (Someone else may have killed it, or it despawned mid-walk.)
  if !obj_is_selectable(session, obj, session.auto_names[:]) {
    session.la_approach_on = false
    session.auto_last = 0 // re-pick promptly next tick
    return
  }
  tpos, tok := engine.read_vec3(session.proc_info.handle, obj + uintptr(session.layout.pos_off))
  if !tok || (session.fence.active && !fence_contains(session.fence, tpos[0], tpos[2])) {
    session.la_approach_on = false // unreadable, or it drifted outside the geo-fence
    session.auto_last = 0
    return
  }
  if session.lookalive_on {
    lookalive_jump_core(session, tpos, now) // travel-jumps use the live target (a hunt-only walk stays plain)
  }
  // Stuck watchdog against the current waypoint: if we stop closing on it for STUCK_NS while still far, the
  // path is blocked. Farming abandons (auto_skip_blocked clears focus + prints "skipping"); hunt never drops
  // the target - it just tries another side-step (hunt_on_stuck flips the side after a few tries).
  d_wp := engine.dist_horizontal(ppos, session.la_approach_wp)
  if d_wp > LA_WP_ARRIVE {
    if d_wp < session.la_approach_best - PROGRESS_EPS {
      session.la_approach_best = d_wp
      session.la_approach_progress_at = now
    } else if now - session.la_approach_progress_at >= STUCK_NS {
      session.la_approach_on = false
      if session.hunt_on {
        hunt_on_stuck(session, obj, ppos, tpos, now) // sets up a fresh (flipped) side-step; never drops
      } else {
        auto_skip_blocked(session, obj, ppos, tpos, "blocked on approach", true, now)
      }
    }
    return // still walking to this waypoint
  }
  // Reached the waypoint. Multi-hop: keep hopping until inside la_max_range, then fall through to lock.
  if session.la_approach_multi && engine.dist_horizontal(ppos, tpos) > session.layout.la_max_range {
    if session.reach_gate_on && !session.hunt_on && !cand_reachable(session, world, ppos, tpos) {
      session.la_approach_on = false // next leg is blocked now - let the reactive pick re-steer
      session.auto_last = 0
      return
    }
    wp := lookalive_step_point(session, ppos, tpos)
    if !write_dest_pos(session, ppos, wp) {
      session.la_approach_on = false
      session.auto_last = 0
      return
    }
    remote_send_snapshot(session)
    session.la_approach_wp = wp
    session.la_approach_best = engine.dist_horizontal(ppos, wp)
    session.la_approach_progress_at = now
    return
  }
  // Arrived (single step done, or the multi-hop is now within max-range): lock it and let the game finish.
  session.la_approach_on = false
  if auto_commit_pick(session, obj, tpos, session.la_approach_stage, session.la_approach_pack) {
    session.auto_last = now
  } else {
    session.auto_last = 0 // lock refused (freed/model) - re-pick next tick
  }
}

// A hunt side-step waypoint: HUNT_SIDESTEP_DIST to one side of the player (perpendicular to player->target),
// plus a little forward toward the target, so a jammed hunt walks AROUND the obstacle rather than purely
// sideways. <left> picks the side (flipped across repeated stalls). Ground plane (x/z); Y from the player.
hunt_sidestep_point :: proc(session: ^Session, p, t: [3]f32, left: bool) -> [3]f32 {
  dx := t[0] - p[0]
  dz := t[2] - p[2]
  length := math.sqrt(dx * dx + dz * dz)
  if length < 0.001 {
    return p
  }
  ux := dx / length // unit toward the target
  uz := dz / length
  side: f32 = left ? 1 : -1
  // Perpendicular (-uz, ux); step to the side and ~half that distance forward.
  fwd := HUNT_SIDESTEP_DIST * 0.5
  return {p[0] + (-uz) * HUNT_SIDESTEP_DIST * side + ux * fwd, p[1], p[2] + ux * HUNT_SIDESTEP_DIST * side + uz * fwd}
}

// Hunt mode's response to a blocked/plateaued target (from auto_monitor or an approach-waypoint stall):
// NEVER drop the target. Unlock it (so the held-attack walk-in stops overriding our moveto), walk a
// perpendicular side-step around the obstacle via the approach machinery, and re-lock on arrival. The side
// alternates every HUNT_SIDESTEP_FLIP stalls so a stubborn jam is probed from both directions. Without
// 'findmove' we can't walk - so we just refresh the progress window and keep letting the game push in.
hunt_on_stuck :: proc(session: ^Session, focus: uintptr, ppos, tpos: [3]f32, now: i64) {
  name, _ := read_mover_name(session, focus)
  if !moveto_configured(session) {
    // Can't side-step without char-control. Hunt still never drops: reset the window and keep pushing.
    session.auto_best_dist = 1e30
    session.auto_progress_at = now
    fmt.printf("\n[hunt] '%s' blocked - holding (need 'findmove' to step around)\n", name)
    fmt.print("memscan> ")
    return
  }
  session.hunt_sidestep_count += 1
  if session.hunt_sidestep_count % HUNT_SIDESTEP_FLIP == 0 {
    session.hunt_side_flip = !session.hunt_side_flip // sweep the other way after a few tries
  }
  wp := hunt_sidestep_point(session, ppos, tpos, session.hunt_side_flip)
  clear_focus(session) // unlock: a locked focus + held attack re-paths straight at the mob every frame
  if !write_dest_pos(session, ppos, wp) {
    // Couldn't issue the walk. Focus is cleared, so the reactive advance re-locks the same target (hunt
    // commits) next tick - don't enter the approach.
    session.auto_last = 0
    return
  }
  remote_send_snapshot(session) // broadcast so other clients see the side-step, not a teleport
  // Re-use the look-alive approach machinery to walk to the side-step waypoint and re-lock on arrival.
  session.la_approach_obj = focus
  session.la_approach_multi = false
  session.la_approach_stage = .None // plain re-lock; no cascade/cluster steering for a committed hunt
  session.la_approach_pack = 0
  session.la_approach_wp = wp
  session.la_approach_best = engine.dist_horizontal(ppos, wp)
  session.la_approach_progress_at = now
  session.la_approach_on = true
  // Fresh monitor window so the re-locked target gets a full STUCK_NS before the next side-step.
  session.auto_best_dist = 1e30
  session.auto_progress_at = now
  fmt.printf("\n[hunt] '%s' blocked - stepping around\n", name)
  fmt.print("memscan> ")
}

// Persist the layout after a look-alive tuning edit (attach-gated, like cli_preselect - the live layout
// is defaults until attach loads flyff.cfg, so saving before attach would clobber the file with defaults).
lookalive_save :: proc(session: ^Session) {
  if session.attached {
    flyff_save_cfg(session.layout, flyff_cfg_path())
  }
}

// Dump of the current look-alive enables + tuning (shared by 'lookalive show', toggling on, and status).
lookalive_print_tuning :: proc(session: ^Session) {
  L := session.layout
  fmt.printfln(
    "  enables: hesitate %s  jump %s  step %s  max-range %s",
    L.la_hesitate_on ? "on" : "off", L.la_jump_on ? "on" : "off", L.la_step_on ? "on" : "off", L.la_maxrange_on ? "on" : "off",
  )
  fmt.printfln(
    "  hesitation %.2f-%.2fs  jump %.2f-%.2fs @ %d%%  step %d%% spread %.1fu  max-range %.1fu%s",
    L.la_hold_min, L.la_hold_max, L.la_jump_min, L.la_jump_max, L.la_jump_chance,
    L.la_step_chance, L.la_step_spread, L.la_max_range,
    moveto_configured(session) ? "" : "  (step/max-range + jumps inert until 'findmove')",
  )
}

// Parse an on/off token. ok=false for anything else (so callers can distinguish a toggle from a value).
la_parse_onoff :: proc(s: string) -> (val: bool, ok: bool) {
  switch s {
  case "on":
    return true, true
  case "off":
    return false, true
  }
  return false, false
}

// lookalive | lookalive on|off        -> toggle look-alive mode (opt-in). When on, auto farms more like a
//                                        human, via four independently-toggleable sub-behaviors below.
// lookalive hesitate|jump|step|maxrange on|off  -> enable/disable one sub-behavior.
// lookalive hold <min> <max>          -> set the hesitation window (seconds; delayed lock-on).
// lookalive jump <min> <max>          -> set the travel-jump interval (seconds).
// lookalive chance <0-100>            -> set the odds a scheduled jump actually fires (percent).
// lookalive step chance <0-100>       -> set the odds an advance takes a single detour step (percent).
// lookalive step spread <units>       -> set the max perpendicular waypoint offset (world units).
// lookalive maxrange <units>          -> set the "too far to beeline" distance (shrinking-hop approach).
// lookalive show                      -> print the current enables + tuning.
// The mode is deliberately less efficient than the snappy loop - for low-spawn quest grinds where
// AFK-looking farming is the concern - so it's OFF by default. Jumps + step + max-range need 'findmove';
// without it hesitation still applies and the walk-based behaviors are skipped. Sub-commands never toggle
// the mode itself.
cli_lookalive :: proc(session: ^Session, args: []string) {
  if len(args) >= 1 {
    switch args[0] {
    case "hesitate", "hesitation":
      if len(args) == 2 {
        if b, ok := la_parse_onoff(args[1]); ok {
          session.layout.la_hesitate_on = b
          fmt.printfln("look-alive hesitation %s.", b ? "ON" : "off")
          lookalive_save(session)
          return
        }
      }
      fmt.eprintln("usage: lookalive hesitate on|off")
      return
    case "hold":
      if len(args) != 3 {
        fmt.eprintln("usage: lookalive hold <min-seconds> <max-seconds>")
        return
      }
      lo, lok := strconv.parse_f64(args[1])
      hi, hik := strconv.parse_f64(args[2])
      if !lok || !hik || lo < 0 || hi < 0 {
        fmt.eprintln("min/max must be numbers >= 0 (seconds).")
        return
      }
      if hi < lo {
        lo, hi = hi, lo // tolerate swapped order
      }
      session.layout.la_hold_min = f32(lo)
      session.layout.la_hold_max = f32(hi)
      fmt.printfln("look-alive hesitation = %.2f - %.2f s.", lo, hi)
      lookalive_save(session)
      return
    case "jump":
      if len(args) == 2 {
        if b, ok := la_parse_onoff(args[1]); ok {
          session.layout.la_jump_on = b
          session.lookalive_jump_at = 0 // re-seed the schedule from the new state
          fmt.printfln("look-alive jumps %s.", b ? "ON" : "off")
          lookalive_save(session)
          return
        }
      }
      if len(args) != 3 {
        fmt.eprintln("usage: lookalive jump on|off | lookalive jump <min-seconds> <max-seconds>")
        return
      }
      lo, lok := strconv.parse_f64(args[1])
      hi, hik := strconv.parse_f64(args[2])
      if !lok || !hik || lo < 0 || hi < 0 {
        fmt.eprintln("min/max must be numbers >= 0 (seconds).")
        return
      }
      if hi < lo {
        lo, hi = hi, lo // tolerate swapped order
      }
      session.layout.la_jump_min = f32(lo)
      session.layout.la_jump_max = f32(hi)
      session.lookalive_jump_at = 0 // re-seed the next interval from the new range
      fmt.printfln("look-alive jump interval = %.2f - %.2f s.", lo, hi)
      lookalive_save(session)
      return
    case "chance":
      if len(args) != 2 {
        fmt.eprintln("usage: lookalive chance <0-100>   (percent a scheduled jump fires)")
        return
      }
      n, nok := strconv.parse_int(args[1])
      if !nok || n < 0 || n > 100 {
        fmt.eprintln("chance must be an integer 0-100 (percent).")
        return
      }
      session.layout.la_jump_chance = n
      fmt.printfln("look-alive jump chance = %d%%.", n)
      lookalive_save(session)
      return
    case "step":
      if len(args) == 2 {
        if b, ok := la_parse_onoff(args[1]); ok {
          session.layout.la_step_on = b
          fmt.printfln("look-alive intermediate step %s.", b ? "ON" : "off")
          lookalive_save(session)
          return
        }
      }
      if len(args) == 3 && args[1] == "chance" {
        n, nok := strconv.parse_int(args[2])
        if !nok || n < 0 || n > 100 {
          fmt.eprintln("step chance must be an integer 0-100 (percent).")
          return
        }
        session.layout.la_step_chance = n
        fmt.printfln("look-alive step chance = %d%%.", n)
        lookalive_save(session)
        return
      }
      if len(args) == 3 && args[1] == "spread" {
        v, vok := strconv.parse_f64(args[2])
        if !vok || v < 0 {
          fmt.eprintln("step spread must be a number >= 0 (world units).")
          return
        }
        session.layout.la_step_spread = f32(v)
        fmt.printfln("look-alive step spread = %.1f units.", v)
        lookalive_save(session)
        return
      }
      fmt.eprintln("usage: lookalive step on|off | lookalive step chance <0-100> | lookalive step spread <units>")
      return
    case "maxrange", "max":
      if len(args) == 2 {
        if b, ok := la_parse_onoff(args[1]); ok {
          session.layout.la_maxrange_on = b
          fmt.printfln("look-alive max-range approach %s.", b ? "ON" : "off")
          lookalive_save(session)
          return
        }
        if v, vok := strconv.parse_f64(args[1]); vok && v >= 0 {
          session.layout.la_max_range = f32(v)
          fmt.printfln("look-alive max-range = %.1f units.", v)
          lookalive_save(session)
          return
        }
      }
      fmt.eprintln("usage: lookalive maxrange on|off | lookalive maxrange <units>")
      return
    case "show", "tuning", "cfg":
      lookalive_print_tuning(session)
      return
    }
  }
  switch {
  case len(args) == 0:
    session.lookalive_on = !session.lookalive_on
  case len(args) == 1 && args[0] == "on":
    session.lookalive_on = true
  case len(args) == 1 && args[0] == "off":
    session.lookalive_on = false
  case:
    fmt.eprintln("usage: lookalive [on|off] | hesitate|jump|step|maxrange on|off | hold <min> <max> | jump <min> <max> | chance <0-100> | step chance|spread <v> | maxrange <units> | show")
    return
  }
  session.lookalive_hold_until = 0
  session.lookalive_jump_at = 0
  session.la_approach_on = false // toggling the mode cancels any in-progress walk
  session.layout.lookalive_on = session.lookalive_on // cfg mirror (see on_attach)
  if session.attached {
    flyff_save_cfg(session.layout, flyff_cfg_path()) // attach-gated (see cli_preselect note)
  }
  note := ""
  if session.lookalive_on && !moveto_configured(session) {
    note = "  (step/max-range + jumps need 'findmove'; delayed lock-on still active)"
  }
  fmt.printfln("look-alive %s.%s", session.lookalive_on ? "ON" : "OFF", note)
  if session.lookalive_on {
    lookalive_print_tuning(session)
  }
}

// reachgate | reachgate on|off -> toggle the PROACTIVE reach filter for auto: skip candidate mobs whose
// straight approach is blocked by terrain or a placed-object OBB, before selecting (the reactive
// stuck-monitor still catches the rest). On by default; active once the world resolves (calibrated) -
// object colliders come from the cached full-scan, so it no longer needs findcull/aobjcull_rva.
cli_reachgate :: proc(session: ^Session, args: []string) {
  switch {
  case len(args) == 0:
    session.reach_gate_on = !session.reach_gate_on
  case len(args) == 1 && args[0] == "on":
    session.reach_gate_on = true
  case len(args) == 1 && args[0] == "off":
    session.reach_gate_on = false
  case:
    fmt.eprintln("usage: reachgate [on|off]")
    return
  }
  session.layout.reach_gate_on = session.reach_gate_on // cfg mirror (see on_attach)
  if session.attached {
    flyff_save_cfg(session.layout, flyff_cfg_path()) // attach-gated (see cli_preselect note)
  }
  fmt.printfln("reach-gate %s.", session.reach_gate_on ? "ON" : "OFF")
}

// hunt | hunt on|off -> toggle hunt mode. Farming's opposite: instead of mowing down whatever herd is
// nearest and dropping any mob that turns out to be far/unreachable, hunt COMMITS to the current target
// (a giant, a quest mob) and never drops it for distance/reachability - it keeps walking in, and when the
// path stalls it side-steps around the obstacle (unlock -> moveto a perpendicular waypoint -> re-lock)
// rather than blacklisting and re-picking. Standalone (works with or without lookalive). Side-stepping
// walks the character, so it needs 'findmove'; without it hunt still never drops, it just can't step around.
cli_hunt :: proc(session: ^Session, args: []string) {
  switch {
  case len(args) == 0:
    session.hunt_on = !session.hunt_on
  case len(args) == 1 && args[0] == "on":
    session.hunt_on = true
  case len(args) == 1 && args[0] == "off":
    session.hunt_on = false
  case:
    fmt.eprintln("usage: hunt [on|off]")
    return
  }
  session.layout.hunt_on = session.hunt_on // cfg mirror (see on_attach)
  if session.attached {
    flyff_save_cfg(session.layout, flyff_cfg_path()) // attach-gated (see cli_preselect note)
  }
  hint := (session.hunt_on && !moveto_configured(session)) ? "  (side-step around blocks needs 'findmove')" : ""
  fmt.printfln("hunt mode %s.%s", session.hunt_on ? "ON" : "OFF", hint)
}

// meshreach | meshreach on|off -> toggle the mesh-accurate reach confirm. When on, a candidate our loose
// OBB marks blocked is re-tested with the client's own IntersectObjLine (OBB + triangle mesh) and kept if
// the client can reach it - recovers mobs the whole-silhouette OBB false-blocks. Injects a game-code
// thread per OBB-blocked candidate. Off by default (opt-in); inert until 'findobjline' pins intersectobjline_rva.
cli_meshreach :: proc(session: ^Session, args: []string) {
  switch {
  case len(args) == 0:
    session.mesh_reach_on = !session.mesh_reach_on
  case len(args) == 1 && args[0] == "on":
    session.mesh_reach_on = true
  case len(args) == 1 && args[0] == "off":
    session.mesh_reach_on = false
  case:
    fmt.eprintln("usage: meshreach [on|off]")
    return
  }
  inert := !intersectobjline_rva_sane(session)
  hint := (session.mesh_reach_on && inert) ? "  (inert: intersectobjline_rva unset or prologue mismatch)" : ""
  fmt.printfln("mesh-reach confirm %s.%s", session.mesh_reach_on ? "ON" : "OFF", hint)
  if session.mesh_reach_on && !inert {
    fmt.println("  WARNING: this injects a game-code thread per OBB-blocked pick (walks the live collision lists).")
    fmt.println("           it recovers loose-OBB false blocks but has correlated with more client crashes under")
    fmt.println("           sustained farming. The decorative filter (collscan) is the safe, no-injection win.")
  }
}

// pause -> toggle the auto-farm pause (no default key; F10 is the full stop/start toggle now). Paused
// = auto stays on but stops advancing;
// killing the targeted mob resumes it. Does nothing if auto is off (won't start it).
cli_pause :: proc(session: ^Session, args: []string) {
  if !session.auto_on {
    fmt.println("auto is off - nothing to pause. start it with 'auto <name>'.")
    return
  }
  if session.auto_paused {
    session.auto_paused = false
    session.pause_obj = 0
    session.auto_last = 0 // advance promptly now that we've resumed
    fmt.println("auto-farm RESUMED.")
  } else {
    session.auto_paused = true
    session.pause_obj = 0
    fmt.println("auto-farm PAUSED - kill the targeted mob (or 'pause' again) to resume.")
  }
}

// timer <minutes> -> auto-disable 'auto' after <minutes> elapse (e.g. 'timer 60'): a safety stop
//                    for an unattended farm session. Absolute deadline from when you run it. If auto
//                    is already off when it elapses it just does nothing.
// timer           -> show the time remaining.
// timer off | 0   -> cancel the pending timer.
cli_timer :: proc(session: ^Session, args: []string) {
  now := time.now()._nsec

  if len(args) == 0 {
    if session.auto_timer_at == 0 {
      fmt.println("no auto-off timer armed.  usage: timer <minutes>   (e.g. 'timer 60')")
      return
    }
    rem := session.auto_timer_at - now
    if rem < 0 {
      rem = 0
    }
    fmt.printfln("auto-off timer: %s remaining%s.", fmt_elapsed(rem), session.auto_on ? "" : "  (auto is off)")
    return
  }

  if args[0] == "off" || args[0] == "stop" || args[0] == "cancel" {
    session.auto_timer_at = 0
    fmt.println("auto-off timer cancelled.")
    return
  }

  mins, ok := strconv.parse_f64(args[0])
  if !ok || mins < 0 {
    fmt.eprintln("usage: timer <minutes>   (e.g. 'timer 60'; 'timer off' to cancel)")
    return
  }
  if mins == 0 {
    session.auto_timer_at = 0
    fmt.println("auto-off timer cancelled.")
    return
  }
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }

  session.auto_timer_at = now + i64(mins * 60_000_000_000.0)
  engine.ensure_hotkey_thread(&session.eng) // keep the watcher alive so the deadline is serviced
  note := session.auto_on ? "" : "  (auto is off now - it will only stop a run that's in progress then.)"
  fmt.printfln("auto-off timer armed: auto-farm OFF in %s.%s", fmt_elapsed(session.auto_timer_at - now), note)
}

// kills <n>  -> auto-disable 'auto' after <n> confirmed kills in the current run (e.g. 'kills 100'):
//               a quota stop for an unattended session. The count is the run total since 'auto'
//               started (auto resets it to 0), so 'auto <name>' then 'kills 100' stops after 100.
//               If auto is off when the quota is hit it just does nothing.
// kills      -> show progress (kills so far / target).
// kills off | 0 -> cancel the pending kill quota.
cli_kills :: proc(session: ^Session, args: []string) {
  if len(args) == 0 {
    if session.auto_count_limit == 0 {
      fmt.println("no kill quota armed.  usage: kills <n>   (e.g. 'kills 100')")
      return
    }
    fmt.printfln("kill quota: %d / %d%s.", session.auto_count, session.auto_count_limit, session.auto_on ? "" : "  (auto is off)")
    return
  }

  if args[0] == "off" || args[0] == "stop" || args[0] == "cancel" {
    session.auto_count_limit = 0
    fmt.println("kill quota cancelled.")
    return
  }

  n, ok := strconv.parse_int(args[0])
  if !ok || n < 0 {
    fmt.eprintln("usage: kills <n>   (e.g. 'kills 100'; 'kills off' to cancel)")
    return
  }
  if n == 0 {
    session.auto_count_limit = 0
    fmt.println("kill quota cancelled.")
    return
  }
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }

  session.auto_count_limit = n
  engine.ensure_hotkey_thread(&session.eng) // keep the watcher alive so the quota is serviced
  // Arming at or below the current run count -> the quota is already met; stop now.
  if session.auto_on && auto_count_reached(session, time.now()._nsec) {
    return
  }
  note := session.auto_on ? "" : "  (auto is off now - it will only stop a run that's in progress then.)"
  remaining := n - session.auto_count
  fmt.printfln("kill quota armed: auto-farm OFF after %d more kill(s) (target %d).%s", remaining, n, note)
}

