package flyff

import "core:fmt"
import "core:math"
import "core:math/rand"
import "core:strconv"
import "core:strings"
import "core:time"

import "../engine"

// Auto-farm: the REPL surface (auto, timer, kills, stuck, reachgate, pause, hunt, lookalive) plus the
// pieces the farm BLOCKS are built from - the kill/penya event log, the stats line, the commit and
// skip helpers, and the look-alive randomness.
//
// The farm LOOP itself is not here any more. `auto` builds and runs a behaviour chart (auto_start_chart
// below -> bh_auto in behaviours.odin), so the priority ladder, the approach and the target-drop
// watches are nodes in a graph rather than a precedence chain of booleans in a tick function. What
// survives here is what a block calls into, and what the user types.

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
          session.penya_last = cur // current gold always tracks the real balance (bottom-left HUD readout)
          // Count it as EARNED (session penya total + radar "+penya" pop) only if it pairs with a recent
          // kill AND isn't a wallet-sized jump: a Perin conversion / sale / trade changes your gold but is
          // not farming income. Uses the same window + cap as the leaderboard so the two never disagree.
          pcap := session.layout.lb_penya_cap
          earned := (now - session.last_kill_ns <= LB_PENYA_KILL_WINDOW_NS) && (pcap <= 0 || gain <= pcap)
          if earned {
            session.penya_total += gain
            session.penya_seq += 1
            pos, _ := read_player_pos(session)
            append(&session.penya_events, Penya_Event{amount = gain, pos = pos, t = now, seq = session.penya_seq})
          }
          lb_note_penya_gain(session, gain, now) // leaderboard span (its own active + window + cap gates)
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
  session.last_kill_ns = now // opens the penya "earned" window (see penya_tick) for auto + manual kills
  append(&session.kill_events, Kill_Event{pos = pos, t = now, seq = session.kill_seq})
}

// Detect a HAND kill (auto off) so the radar laser/zap still fire when you farm manually. Watches the
// player's own m_pObjFocus: when the watched target's HP hits 0 it records ONE kill event at its last
// live position. No-op while auto is on (the chart's count_kill block owns kill detection then -
// running both would double the laser, and the fast re-target would race this). Called from the radar
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

// Stop condition for the 'kills' command: once the run's confirmed-kill count reaches auto_count_limit,
// turn auto-farm off and self-disarm. Returns true if it fired (so a caller can skip advancing to a
// next mob). No-op (returns false) while disarmed or below the quota.
auto_count_reached :: proc(session: ^Session, now: i64) -> bool {
  if session.auto_count_limit == 0 || session.auto_count < session.auto_count_limit {
    return false
  }
  session.auto_on = false
  session.auto_count_limit = 0
  fmt.printf("\n[auto] count reached (%d kills) - auto-farm OFF.  %s\n", session.auto_count, auto_stats(session, now))
  fmt.print("memscan> ")
  return true
}

// Is hunt's commit-and-chase steering live? Hunt never drops a target and side-steps around blockers to
// keep chasing it - which is exactly the "walk wherever the mob is" behaviour a painted sweep lane must
// not have, so a live lane suppresses it. hunt_on itself is left alone, so hunt comes straight back when
// the sweep ends. Gate every hunt-vs-farm BRANCH on this, not on session.hunt_on directly.
// Is the RUNNING CHART one that commits to its target and steps around jams? That is what has to
// relax the reach gate: hunt deliberately picks mobs it cannot currently walk to, because side-stepping
// in is the whole point, and gating them out would leave it nothing to commit to.
//
// It used to be `session.hunt_on`, a mode you toggled. There is no mode any more - "hunt" is a chart -
// so the question is asked of the PROGRAM: does it contain an approach that side-steps? script_begin
// answers it once at start (script_run.sidestep_chart) rather than re-scanning the steps per pick.
// A live sweep still suppresses it: the lane owns the route, and stepping off it to reach something is
// exactly what sweep must not do.
hunt_steering_on :: proc(session: ^Session) -> bool {
  return session.script.sidestep_chart && !session.sweep_on
}

// THE question every collision check asks: should the proactive reach gate run at all right now?
//
// Three ways it can be off, and they are genuinely different things:
//   - session.reach_gate_on   - the global default (on; nothing turns it off today, see BACKLOG)
//   - hunt_steering_on        - INFERRED from the chart: it side-steps, so it must be allowed to pick
//                               mobs it cannot currently walk to
//   - script.ignore_collision - DECLARED by the chart: on this map the gate is simply wrong. Props a
//                               character walks straight over still produce collider boxes, and
//                               compute_reach cannot tell those from a wall, so a floor full of them
//                               excludes the room and the ladder starves.
//
// Every site that used to test `session.reach_gate_on` goes through here instead, so the three cannot
// disagree and a new consumer cannot accidentally honour only one of them. Inert with no chart running:
// script.ignore_collision is false whenever session.script is not a run that declared it.
//
// What this does NOT touch: the stuck monitor (a distance plateau is measured, not predicted, so it
// still catches a real jam), the `target_reachable` block (asking the question explicitly deserves the
// honest answer), and the radar's reach fade, which is a view toggle of its own.
reach_gate_active :: proc(session: ^Session) -> bool {
  return session.reach_gate_on && !session.script.ignore_collision && !hunt_steering_on(session)
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
  // Drop the combat-watch anchor too: the allocator can hand the same CObj* back for a later mob, and a
  // stale "damage landed" stamp would grant that fresh target an unearned grace window.
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

// Leave the paused state and let auto resume advancing. Seeds the bow-range anchor from where the mob
// died so the first pick after resuming stays on that spot's pack.
pause_resume :: proc(session: ^Session, killed_obj: uintptr, now: i64) {
  session.auto_count += 1 // the kill that resumes us counts too (this is the first kill when armed)
  lb_record_kill(session, killed_obj) // attribute to the leaderboard span (no-op unless recording)
  script_note_kill(session, killed_obj) // per-species tally for a script's `kills_of` (no-op unless running)
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

// Parse a raw target argument into a list of names. Semicolon-separated; each name may be wrapped
// in single/double quotes and may contain spaces. Empty input (or only whitespace) yields an
// empty list, meaning "any monster". Allocated in the temp allocator. Examples:
//   ""                                        -> []            (any monster)
//   "Aibatt"                                  -> ["Aibatt"]
//   "Mutant Yetti"                            -> ["Mutant Yetti"]
//   "'Club-tailed Reptillion'; 'Captain ...'" -> ["Club-tailed Reptillion", "Captain ..."]
parse_target_names :: proc(raw: string) -> [dynamic]string {
	out := make([dynamic]string, context.temp_allocator)
	for part in strings.split(raw, ";", context.temp_allocator) {
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
  // `auto` IS the chart, so stopping one stops the other. script_stop runs the in-flight step's Exit,
  // which is what halts a walk that was in progress instead of letting it stroll to its waypoint.
  if session.script.active && session.script.name == "auto" {
    script_stop(session)
  }
  session.auto_timer_at = 0 // stopping the run cancels any pending auto-off timer
  session.auto_count_limit = 0 // ...and any pending kill-count limit
  session.auto_avoid_on = false
  session.auto_sel_set = false
  session.auto_start = 0
  session.auto_count = 0
  session.last_kill_set = false
  session.cluster_committed = false
  session.cluster_origin_pos = {}
  session.lookalive_jump_at = 0 // run-state only; lookalive_on persists (a mode toggle)
  session.hunt_side_flip = false // hunt side-step state is per-run (hunt_on the mode persists)
  // Sweep: reset the WALK bookkeeping but KEEP the path + cursor, so an F10 pause/resume continues the
  // lane exactly where it left off. Only completing it, 'sweep off', or a radar right-click drops it.
  // The kill baseline is re-zeroed because auto_count is (above), so the tally counts the resumed run.
  if session.sweep_walking {
    move_stop(session) // don't leave a hop running after the farm has been told to stop
  }
  session.sweep_walking = false
  session.sweep_best = 1e30
  session.sweep_progress_at = 0
  session.sweep_clear_since = 0
  session.sweep_kills_start = 0
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
      // Stats BEFORE the stop: auto_stop zeroes auto_count and auto_start, so reading them afterwards
      // reported "kill #0" and an elapsed measured from the epoch.
      summary := auto_stats(session, time.now()._nsec)
      auto_stop(session)
      fmt.printfln("auto-farm OFF.  %s", summary)
    } else {
      fmt.println("auto-farm already off.")
    }
    return
  }

  // Bare 'auto' while running -> status peek (don't disturb the run). When off it falls through
  // and starts any-monster mode.
  if len(args) == 0 && session.auto_on {
    // The ladder and the tunables used to be printed here, read off a dozen session flags. They are the
    // CHART now, so the honest answer is "open it" - and `script` already says which node is executing.
    state := session.script.paused ? "PAUSED" : "ON"
    fmt.printfln("auto-farm %s: %s.  %s", state, auto_target_desc(session.auto_names[:]), auto_stats(session, time.now()._nsec))
    melee_r, engage_r := pick_ranges(session)
    fmt.printfln("  ranges: melee<%.1f  in-range<%.1f   ('set melee_range' / 'set attack_range')", melee_r, engage_r)
    fmt.println("  the ladder, the walk-in and the give-up rules are nodes: 'script show auto', or the radar's chart editor.")
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
      summary := auto_stats(session, time.now()._nsec) // before the stop - see the note above
      auto_stop(session)
      fmt.printfln("auto-farm OFF.  %s", summary)
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
  session.auto_avoid_on = false
  session.auto_sel_set = false
  session.last_kill_set = false
  session.cluster_committed = false // a new run starts uncommitted; the first pick decides
  session.cluster_origin_pos = {}
  clear(&session.auto_blocked)
  session.auto_on = true
  engine.ensure_hotkey_thread(&session.eng)
  if !auto_start_chart(session) {
    session.auto_on = false
    return
  }
  fmt.printfln(
    "auto-farm ON: %s.  F10 stops/starts, 'pause' pauses, 'script' shows the chart driving it.",
    auto_target_desc(session.auto_names[:]),
  )
  auto_warn_mobgate(session)
}

// Build the farm chart from the live configuration and start it. THIS IS THE CUTOVER: `auto` is no
// longer a tick function reading thirty booleans, it is this chart - and every command that used to
// shape those booleans (priority, preset, density, lookalive, hunt, timer, kills) now shapes which
// NODES bh_auto emits. See the header on bh_auto in behaviours.odin.
//
// Goes through bhv_open rather than straight to the builder, so a saved `auto.bhv` shadows the built-in
// exactly like every other behaviour: duplicating it in the editor is how you get an editable farm loop,
// and deleting the file restores the original. That shadowing rule is the whole reason the ladder is
// "editable" rather than merely "expressed as nodes".
auto_start_chart :: proc(session: ^Session) -> bool {
  doc, ok := bhv_open("auto")
  if !ok {
    fmt.eprintln("auto: the 'auto' behaviour would not build - 'script show auto' says why.")
    return false
  }
  if problems := script_check_avail(session, doc.steps[:]); len(problems) > 0 {
    fmt.eprintfln("auto: %d block(s) it needs aren't available:", len(problems))
    for p in problems {
      fmt.eprintfln("  %s", p)
    }
    fmt.eprintln("  run `setup <name>` (see `status`), then try again.")
    behaviour_doc_free(&doc)
    return false
  }
  entry := doc.entry
  mode := doc.mode
  script_begin(session, "auto", doc.steps, mode, entry, .Chart, doc.uses[:], doc.ignore_collision)
  delete(doc.name)
  delete(doc.trigger.strs[0])
  delete(doc.trigger.strs[1])
  for u in doc.uses {
    delete(u)
  }
  delete(doc.uses)
  return true
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
  lb_note_commit(session, obj, pack) // carry name + pack to the kill site (no-op unless a run is recording)
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
// <spread> negative = use the configured la_step_spread; a caller (the `approach` block) may name its
// own so the jitter is a property of the node rather than a global.
lookalive_step_point :: proc(session: ^Session, p, t: [3]f32, spread: f32 = -1) -> [3]f32 {
  dx := t[0] - p[0]
  dz := t[2] - p[2]
  length := math.sqrt(dx * dx + dz * dz)
  if length < 0.001 {
    return p
  }
  frac := lookalive_rand_f32(0.4, 0.6)
  ax := p[0] + dx * frac
  az := p[2] + dz * frac
  sp := spread >= 0 ? spread : session.layout.la_step_spread
  // Perpendicular unit vector in the ground plane is (-dz, dx)/length; offset a random signed amount.
  off := lookalive_rand_f32(-sp, sp)
  return {ax + (-dz / length) * off, p[1], az + (dx / length) * off}
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

