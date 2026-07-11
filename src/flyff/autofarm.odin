package flyff

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import "../engine"

// Auto-farm: the hands-free farming layer on top of the selection logic in target.odin - the
// watcher-thread tick (auto_tick / auto_monitor / pause_*) and the REPL commands (auto, timer,
// kills, stuck, reachgate, pause). Same package as target.odin, so this is purely organisational.

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
    name, _ := read_mover_name(session, focus)
    mark_blocked(session, focus, now)
    // We jammed trying to reach this mob, so the obstacle is roughly in its direction. Hint the next
    // pick to steer to the opposite side of us (see the retarget in tc_select).
    session.auto_avoid_dir = {tpos[0] - ppos[0], tpos[2] - ppos[2]}
    session.auto_avoid_on = true
    // Clear m_pObjFocus so the next tick advances; reset tracking + throttle so it fires promptly.
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
    fmt.printf("\n[auto] '%s' blocked (d=%.1f) - skipping\n", name, d)
    fmt.print("memscan> ")
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
  // A live target is still selected: watch it for obstacle-stuck (every tick, unthrottled) and wait.
  if focus, fok := read_focus_ptr(session); fok && focus != 0 && focus_obj_live(session, focus) {
    if session.auto_stuck_on {
      auto_monitor(session, focus, now)
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
      fmt.printf("\n[auto] %s\n", auto_stats(session, now))
      fmt.print("memscan> ")
    }
    session.auto_sel_set = false
    // Hit the kill quota ('kills' command)? Stop before advancing so we don't grab an extra target.
    if died && auto_count_reached(session, now) {
      return
    }
  }
  // Advance to the next mob. Selection itself is silent now - no print unless something died above.
  tc_select(session, session.auto_names[:], true)
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

// If auto is in any-monster mode (empty name list) but the species prop-table gate isn't configured
// yet, warn that pets / other players / NPCs will also be targeted, and point at the one-time fix.
auto_warn_mobgate :: proc(session: ^Session) {
  if len(session.auto_names) == 0 && !prop_gate_ready(session) {
    fmt.println("  note: any-monster mode will also target pets / players / NPCs until you run 'findprop' once (target your pet, with monsters on screen).")
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
  clear(&session.auto_blocked)
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
  auto_set_names(session, names[:])
  session.auto_last = 0
  session.auto_count = 0
  session.auto_start = time.now()._nsec
  session.auto_focus_obj = 0 // reset obstacle/stuck tracking for the new run
  session.auto_avoid_on = false
  session.auto_sel_set = false
  session.last_kill_set = false
  clear(&session.auto_blocked)
  // Start ARMED (paused): the first kill kicks off farming (see pause_tick). This avoids auto grabbing
  // a target the instant you type the command - you engage the first mob yourself.
  session.auto_paused = true
  session.pause_obj = 0
  session.auto_on = true
  ensure_hotkey_thread(session)
  fmt.printfln(
    "auto-farm ARMED: %s. target a mob and kill it to start; then it advances on each kill. F10 to pause, 'auto off' to stop.",
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

// reachgate | reachgate on|off -> toggle the PROACTIVE reach filter for auto: skip candidate mobs whose
// straight approach is blocked by terrain or a placed-object OBB, before selecting (the reactive
// stuck-monitor still catches the rest). On by default, but inert until 'findcull' sets aobjcull_rva (so
// it can't accidentally starve target selection or fall back to the slow scan in the pick loop).
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
  inert := session.layout.aobjcull_rva == 0
  hint := (session.reach_gate_on && inert) ? "  (inert: run 'findcull' once in-game to enable it)" : ""
  fmt.printfln("reach-gate %s.%s", session.reach_gate_on ? "ON" : "OFF", hint)
}

// meshreach | meshreach on|off -> toggle the mesh-accurate reach confirm. When on, a candidate our loose
// OBB marks blocked is re-tested with the client's own IntersectObjLine (OBB + triangle mesh) and kept if
// the client can reach it - recovers mobs the whole-silhouette OBB false-blocks. Injects a game-code
// thread per OBB-blocked candidate. On by default, inert until intersectobjline_rva is set + prologue-valid.
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

// pause -> toggle the auto-farm pause (default key: F10). Paused = auto stays on but stops advancing;
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
  ensure_hotkey_thread(session) // keep the watcher alive so the deadline is serviced
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
  ensure_hotkey_thread(session) // keep the watcher alive so the quota is serviced
  // Arming at or below the current run count -> the quota is already met; stop now.
  if session.auto_on && auto_count_reached(session, time.now()._nsec) {
    return
  }
  note := session.auto_on ? "" : "  (auto is off now - it will only stop a run that's in progress then.)"
  remaining := n - session.auto_count
  fmt.printfln("kill quota armed: auto-farm OFF after %d more kill(s) (target %d).%s", remaining, n, note)
}

