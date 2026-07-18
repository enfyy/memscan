package flyff

import "core:fmt"
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
    // Closing in - real progress. Reset the stuck window.
    session.auto_best_dist = d
    session.auto_progress_at = now
    return
  }
  // Plateaued while still far. Once that's persisted for STUCK_NS, treat the mob as unreachable.
  if now - session.auto_progress_at >= STUCK_NS {
    auto_skip_blocked(session, focus, ppos, tpos, fmt.tprintf("blocked (d=%.1f)", d), true, now)
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
  session.auto_last = 0
  session.auto_next_set = false // the precompute for this abandoned target is stale
  session.auto_next_for = 0
  fmt.printf("\n[auto] '%s' %s - skipping\n", name, reason)
  fmt.print("memscan> ")
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
  // A live target is still selected: watch it for obstacle-stuck (every tick, unthrottled) and, while
  // we fight it, precompute the NEXT target so the advance is instant when it dies (pre-select).
  if focus, fok := read_focus_ptr(session); fok && focus != 0 && focus_obj_live(session, focus) {
    if session.auto_stuck_on {
      auto_monitor(session, focus, now)
    }
    if session.reach_gate_on {
      auto_reach_watch(session, focus, now) // reach can be lost AFTER selection - watch it, don't jam
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
  if session.lookalive_on {
    if session.lookalive_hold_until == 0 {
      session.lookalive_hold_until = now + lookalive_rand_ns(LA_HOLD_MIN_NS, LA_HOLD_MAX_NS)
      return
    }
    if now < session.lookalive_hold_until {
      return // still hesitating
    }
    session.lookalive_hold_until = 0 // hold elapsed - engage now; re-armed on the next kill
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
      if focus_set_obj(session, nobj, session.auto_names[:]) == .Picked {
        session.auto_sel_pos = lpos // LIVE position (not the snapshot) - keeps the kill anchor honest
        session.auto_sel_obj = nobj
        session.auto_sel_set = true
        // Carry the cluster commitment forward, exactly like tc_select's post-pick bookkeeping.
        if session.layout.density_on {
          _, engage := pick_ranges(session)
          session.cluster_committed, session.cluster_origin_pos = cluster_advance(
            session.cluster_committed, session.cluster_origin_pos, nstage, lpos, npack, density_radius(engage),
          )
        } else {
          session.cluster_committed = false
          session.cluster_origin_pos = {}
        }
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

// Look-alive tuning. The post-kill hesitation before engaging the next target (delayed lock-on) and the
// interval between travel-jumps are each randomized per event, so the cadence never reads as robotic.
LA_HOLD_MIN_NS :: i64(800_000_000) // 0.8s min hesitation before locking the next target
LA_HOLD_MAX_NS :: i64(3_000_000_000) // 3.0s max
LA_JUMP_MIN_NS :: i64(4_000_000_000) // 4s min between travel-jump attempts
LA_JUMP_MAX_NS :: i64(12_000_000_000) // 12s max
LA_JUMP_MIN_DIST :: f32(8.0) // only jump while still this far from the target (travelling, not in melee)

lookalive_seeded: bool // one-time seed guard for the look-alive RNG (see lookalive_rand_ns)

// Uniform random duration in [lo, hi) nanoseconds for look-alive's jitter. Seeds the context random
// generator once from the wall clock (on the watcher thread, which owns a valid default context) so runs
// don't repeat the same delay pattern. Returns lo when the range is empty/inverted.
lookalive_rand_ns :: proc(lo, hi: i64) -> i64 {
  if !lookalive_seeded {
    rand.reset_u64(u64(time.now()._nsec))
    lookalive_seeded = true
  }
  if hi <= lo {
    return lo
  }
  return rand.int64_range(lo, hi)
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

// Per-tick travel-jump scheduler (look-alive). Jumps at randomized intervals, but only while still
// travelling to the target (>= LA_JUMP_MIN_DIST away) so we don't hop in place during melee. Seeds the
// first interval instead of jumping on the very first tick.
lookalive_jump_tick :: proc(session: ^Session, focus: uintptr, now: i64) {
  if !jump_configured(session) {
    return
  }
  if session.lookalive_jump_at == 0 {
    session.lookalive_jump_at = now + lookalive_rand_ns(LA_JUMP_MIN_NS, LA_JUMP_MAX_NS)
    return
  }
  if now < session.lookalive_jump_at {
    return
  }
  session.lookalive_jump_at = now + lookalive_rand_ns(LA_JUMP_MIN_NS, LA_JUMP_MAX_NS)
  ppos, pok := read_player_pos(session)
  tpos, tok := engine.read_vec3(session.proc_info.handle, focus + uintptr(session.layout.pos_off))
  if pok && tok && engine.dist_horizontal(ppos, tpos) >= LA_JUMP_MIN_DIST {
    lookalive_do_jump(session)
  }
}

// lookalive | lookalive on|off -> toggle look-alive mode (opt-in). When on, auto farms more like a human:
// a random hesitation before engaging each new target (delayed lock-on) plus occasional jumps while
// travelling to one. Deliberately less efficient than the snappy loop - for low-spawn quest grinds where
// AFK-looking farming is the concern - so it's OFF by default. Jumps need 'findmove'; without it the
// hesitation still applies and jumps are skipped.
cli_lookalive :: proc(session: ^Session, args: []string) {
  switch {
  case len(args) == 0:
    session.lookalive_on = !session.lookalive_on
  case len(args) == 1 && args[0] == "on":
    session.lookalive_on = true
  case len(args) == 1 && args[0] == "off":
    session.lookalive_on = false
  case:
    fmt.eprintln("usage: lookalive [on|off]")
    return
  }
  session.lookalive_hold_until = 0
  session.lookalive_jump_at = 0
  session.layout.lookalive_on = session.lookalive_on // cfg mirror (see on_attach)
  if session.attached {
    flyff_save_cfg(session.layout, flyff_cfg_path()) // attach-gated (see cli_preselect note)
  }
  note := ""
  if session.lookalive_on && !jump_configured(session) {
    note = "  (jumps need 'findmove'; delayed lock-on still active)"
  }
  fmt.printfln("look-alive %s.%s", session.lookalive_on ? "ON" : "OFF", note)
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

