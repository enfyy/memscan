package flyff

// base:builtin only for `builtin.any`: this package declares its own `any` (builder.odin's condition
// join, `any(a, b)`), which shadows the builtin TYPE of that name - so a `..any` vararg here resolves to
// the proc and does not compile. Qualifying it is the fix; see script_trace.
import "base:builtin"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "core:unicode/utf8"

import "../engine"

// ===========================================================================
// Behaviour runtime - the state that hosts a rule list, and the REPL surface.
// The evaluator is in script_rules.odin, the types in script.odin, the catalog in script_blocks.odin.
// ===========================================================================

// --- the script state ---------------------------------------------------------------------------

// "A behaviour is running." Its Update arbitrates the rule list and walks whatever won; each step's
// start/poll/exit are that step's Enter/Update/Exit (a single state proc cannot provide per-step
// phases - a state returning itself is not a transition - so the walker provides them).
//
// The Exit below is the whole reason this is a state rather than a flag: leaving the behaviour for ANY
// reason - a `stop` block, `script stop`, a detach - tears down the action that was in flight. That is
// what makes `script stop` mid-walk actually halt the character instead of letting it drift to the
// waypoint.
st_script :: proc(user_data: rawptr, phase: engine.State_Phase) -> engine.State_Function {
  ctx := bh_ctx(user_data)
  run := &ctx.session.script
  switch phase {
  case .Enter:
    ctx.session.bh_state = .Script
    ctx.session.bh_state_at = ctx.now
  case .Update:
    if !run.active {
      return st_idle
    }
    // PAUSED is the transport's stop button: nothing at all runs, not even arbitration, so the machine
    // you come back to is exactly the one you left. It has to cover arbitration and not just the walk -
    // a paused list that kept arbitrating would hand control to a different rule while you were away.
    if !run.paused {
      rules_tick(ctx)
    }
    if !run.active {
      return st_idle
    }
  case .Exit:
    script_teardown(ctx)
  }
  return st_script
}

// Run the in-flight step's exit, if there is one. Split out from script_teardown because `script reset`
// needs exactly this half: undo what the current step started, but keep the run alive.
script_exit_current :: proc(ctx: ^Behaviour_Context) {
  rules_exit_current(ctx)
}

// Tear down whatever the run left in flight. Called from st_script's Exit, so it runs on every exit
// path without any of them having to remember.
script_teardown :: proc(ctx: ^Behaviour_Context) {
  script_exit_current(ctx)
  run := &ctx.session.script
  // NO LATCH HANDOVER. The globals are one list with one latch, evaluated in one place whether or not
  // anything is running (globals_tick), so there is nothing to give back. This used to be half of a
  // two-way copy that existed purely because a hoisted watcher was a SECOND owner of the same edge.
  //
  // Let go of every key a key_down left held. Those blocks have no `exit` on purpose - the whole point
  // is that the hold outlives the step - so the run is the level that owes the release, and this is the
  // one path every ending goes through. Without it, stopping a chart mid-hold would leave you running
  // into a wall with nothing left to stop it (see keys.odin).
  if n := keys_release_all(ctx.session); n > 0 {
    fmt.printf("\n[script] released %d key(s) still held down.\n", n)
    fmt.print("memscan> ")
    script_trace(ctx.session, 0, .Note, "released %d key(s) still held down", n)
  }
  // The farm chart ending IS auto ending - `script stop` on it, its kill quota running out, or a
  // `stop` node all have to leave auto_on false, or `status` and F10 would keep claiming it is farming.
  // The other direction lives in auto_stop.
  if run.name == "auto" {
    ctx.session.auto_on = false
  }
  run.active = false
}

script_arm_event :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) {
  st^ = Event_State {
    armed_at = ctx.now,
    armed    = true,
  }
  if def := event_def(ev.kind); def != nil && def.arm != nil {
    def.arm(ctx, ev, st)
  }
}

// THE single place an event is evaluated - so the `not` prefix applies everywhere an event can be
// written (if / while / until / wait_for / on) without any of those sites knowing about it.
script_event_fired :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  def := event_def(ev.kind)
  if def == nil || def.fired == nil {
    return false
  }
  res := def.fired(ctx, ev, st)
  return ev.negate ? !res : res
}

// --- conditions (one or more events, all-of or any-of) --------------------------------------------

// Arm every row. Each gets its OWN baseline: `kills 20 and elapsed 5` has to count kills from here and
// minutes from here, and one shared Event_State would let whichever row armed second inherit the
// other's clock.
script_arm_condition :: proc(ctx: ^Behaviour_Context, condition: Script_Condition, state: ^Condition_State) {
  latched := state.latched // the latch belongs to the condition and survives a re-arm of its rows
  state^ = {}
  state.latched = latched
  for row in 0 ..< condition_row_count(condition) {
    script_arm_event(ctx, condition_row(condition, row), &state.rows[row])
  }
}

// Evaluate the whole condition. EVERY row is evaluated, even once the answer is known: a row like
// `kills 20` updates its own state as a side effect of being asked, and short-circuiting would leave
// the rows after the deciding one frozen at whatever they last saw.
script_condition_holds :: proc(ctx: ^Behaviour_Context, condition: Script_Condition, state: ^Condition_State) -> bool {
  rows := condition_row_count(condition)
  holding := 0
  for row in 0 ..< rows {
    if script_event_fired(ctx, condition_row(condition, row), &state.rows[row]) {
      holding += 1
    }
  }
  return condition.match_any ? holding > 0 : holding == rows
}

script_condition_armed :: proc(state: Condition_State) -> bool {
  return state.rows[0].armed
}


// Attribute one confirmed kill to the running script's per-species tally, so `kills_of '<name>' <n>`
// can count them. Called from both auto kill sites beside lb_record_kill, and resolves the name the
// same way it does: the committed pick's name (lb_cur_name, set at pick time - the object may already
// be freed by now), falling back to a live read. No-op unless a script is running.
script_note_kill :: proc(session: ^Session, killed_obj: uintptr) {
  run := &session.script
  if !run.active {
    return
  }
  name := panel_buf_str(session.lb_cur_name[:])
  if name == "" {
    if nm, ok := engine.read_obj_name(session.proc_info.handle, session.ptr_size, killed_obj, session.layout.name_off); ok {
      name = nm
    }
  }
  if name == "" {
    return
  }
  if run.kills_by_name == nil {
    run.kills_by_name = make(map[string]int)
  }
  if _, ok := run.kills_by_name[name]; ok {
    run.kills_by_name[name] += 1
  } else {
    run.kills_by_name[strings.clone(name)] = 1 // own the key (name may be temp/stack)
  }
}

script_kills_of :: proc(run: ^Script_Run, name: string) -> int {
  n, _ := run.kills_by_name[name]
  return n
}

// --- the trace ring --------------------------------------------------------------------------------
//
// Append one row. Allocation-free (fmt.bprintf into the row's own fixed buffer, which truncates rather
// than growing), so this is safe to call from anywhere on the watcher tick including inside a block.
//
// Every caller ALSO keeps whatever it printed to the console. The trace is an additional surface, not a
// replacement: the console is the copyable record and the ring is what the editor can show.
script_trace :: proc(session: ^Session, node: Node_Id, level: Script_Trace_Level, format: string, args: ..builtin.any) {
  t := &session.script_trace
  row := &t.rows[t.next]
  row^ = Script_Trace_Row {
    at    = time.now()._nsec,
    node  = node,
    level = level,
  }
  row.count = u8(len(fmt.bprintf(row.text[:], format, ..args)))
  t.next = (t.next + 1) % SCRIPT_TRACE_ROWS
  t.written += 1
}

// The step the run is sitting on, for a trace row raised from INSIDE a block - a block proc gets the
// step it is running but the helpers it calls (script_arg) get only the context.
script_current_node :: proc(ctx: ^Behaviour_Context) -> Node_Id {
  step := rules_current_step(&ctx.session.script)
  return step == nil ? 0 : step.id
}

// Takes the STEP rather than its source text, because it is also the single place control-arrived-here
// is traced. Both ops that can be entered call it, so one call site per op covers the narration.
script_note_line :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) {
  run := &ctx.session.script
  delete(run.last_line)
  run.last_line = strings.clone(step.src)
  script_trace(ctx.session, step.id, .Step, "%s", step.src)
}


// A block refused outright - it could not even start. Distinct from a step RETURNING .Failed, which the
// rule walker handles by aborting the rest of that rule's steps: this is the harder case where the
// block wants the whole run to end, and it is what a `stop`-shaped failure means.
//
// There is no fail EDGE to take any more. On a graph a failing block could name where a failure goes,
// which is how the priority ladder was drawn; in a rule list a failure aborts the sequence and control
// returns to the top of the list, so "where does a failure go" has one answer and no wiring.
script_fail :: proc(ctx: ^Behaviour_Context, step: ^Script_Step, why: string) {
  fmt.printf("\n[script] step %d (%s) - %s. run stopped.\n", u32(step.id), step.src, why)
  fmt.print("memscan> ")
  script_trace(ctx.session, step.id, .Error, "%s - run ends", why)
  script_finish(ctx, "failed")
}

script_finish :: proc(ctx: ^Behaviour_Context, how: string) {
  run := &ctx.session.script
  el := ctx.now - run.started_at
  name := run.name
  steps_done := run.steps_done
  script_teardown(ctx) // runs the in-flight step's exit; also clears active
  fmt.printf("\n[script] %s - '%s' %s after %s (%d steps)\n", how, name, how == "complete" ? "finished" : "ended", fmt_elapsed(el), steps_done)
  fmt.print("memscan> ")
  script_trace(
    ctx.session, 0, how == "failed" ? .Error : .Note,
    "run %s after %s (%d steps)", how, fmt_elapsed(el), steps_done,
  )
}

// --- starting / stopping ------------------------------------------------------------------------------

// Availability gate: every block a program uses must be implemented and configured BEFORE the run
// starts. Refusing up front beats dying halfway through, which would leave the character somewhere
// unexpected. Returns the list of problems (temp-allocated).
script_check_avail :: proc(session: ^Session, steps: []Script_Step) -> [dynamic]string {
  out := make([dynamic]string, context.temp_allocator)
  seen_a: bit_set[Script_Action_Kind]
  seen_e: bit_set[Script_Event_Kind]
  check_action :: proc(session: ^Session, act: Script_Action, seen: ^bit_set[Script_Action_Kind], out: ^[dynamic]string) {
    if act.kind == .None || act.kind in seen^ {
      return
    }
    seen^ += {act.kind}
    def := action_def(act.kind)
    if def == nil {
      return
    }
    // not_built first: "there is no code behind this" outranks "the process isn't attached", and it is
    // the answer that stays true after you attach.
    if def.not_built {
      append(out, fmt.tprintf("%s: %s", def.name, def.not_built_why))
      return
    }
    if def.avail != nil {
      if ok, why := def.avail(session); !ok {
        append(out, fmt.tprintf("%s: %s", def.name, why))
      }
    }
  }
  check_event :: proc(session: ^Session, ev: Script_Event, seen: ^bit_set[Script_Event_Kind], out: ^[dynamic]string) {
    if ev.kind == .None || ev.kind in seen^ {
      return
    }
    seen^ += {ev.kind}
    def := event_def(ev.kind)
    if def == nil {
      return
    }
    if def.not_built {
      append(out, fmt.tprintf("%s: %s", def.name, def.not_built_why))
      return
    }
    if def.avail != nil {
      if ok, why := def.avail(session); !ok {
        append(out, fmt.tprintf("%s: %s", def.name, why))
      }
    }
  }
  for s in steps {
    check_action(session, s.action, &seen_a, &out)
    check_event(session, s.condition, &seen_e, &out)
    if s.has_until {
      check_event(session, s.until, &seen_e, &out)
    }
  }
  return out
}


// Every ROW's strings, freed as one thing - because a condition OWNS the strings of every row it has,
// and deleting only row 0 leaked the rest of a multi-row test. The cloning half lives with the things
// that clone: rule_clone (the armed interrupt list, the editor's undo ring) and script_step_clone.
script_condition_free :: proc(condition: ^Script_Condition) {
  for index in 0 ..< condition_row_count(condition^) {
    row := condition_row_ptr(condition, index)
    delete(row.strs[0])
    delete(row.strs[1])
    row.strs = {}
  }
}

// --- transport (what a play/pause/reset control drives) --------------------------------------------

script_set_paused :: proc(session: ^Session, on: bool) -> bool {
  run := &session.script
  if !run.active || run.paused == on {
    return false
  }
  run.paused = on
  return true
}

// Start the list over without rebuilding it. Everything a fresh run would reset gets reset - the kill
// tally, every rule's latch and fire count, the clocks - and the in-flight step's exit runs first, so a
// walk in progress is actually halted rather than left steering toward a waypoint the rewound
// behaviour no longer knows about.
//
// There is nowhere to rewind TO, which is the point of the model: a list has no position, so "reset"
// means drop whoever has control and let the next tick arbitrate from the top. What actually needed
// resetting was never the pc - it was the baselines, and those are per rule.
script_reset :: proc(session: ^Session) -> bool {
  run := &session.script
  if !run.active {
    return false
  }
  now := time.now()._nsec
  ctx := Behaviour_Context {
    session = session,
    now     = now,
    board   = &session.bh_board,
  }
  script_exit_current(&ctx)
  keys_release_all(ctx.session) // a key held from the previous pass must not survive the rewind

  run.active_rule = -1
  run.rule_depth = 0
  run.rule_frames = {}
  run.pc = 0
  run.entered = false
  run.steps_done = 0
  run.stop_requested = false
  run.started_at = now
  run.step_at = now
  delete(run.last_line)
  run.last_line = ""
  for k in run.kills_by_name {
    delete(k) // the map owns its keys (see script_note_kill)
  }
  clear(&run.kills_by_name)
  // Re-arm every row's baseline, and disarm every step's. A rule that has already fired is latched,
  // and a `kills 20` row measures from when it was armed - inheriting either from the previous pass
  // would make a rewound behaviour either refuse to fire or fire instantly.
  for &rule in run.rules {
    rule.fires = 0
    rule.condition_state = {}
    script_arm_condition(&ctx, rule.condition, &rule.condition_state)
    for &s in rule.steps {
      s.condition_state = {}
    }
  }
  return true
}

// Stop a run from outside the machine (the CLI, detach). Goes through the state machine so
// st_script's Exit runs and the in-flight action is torn down.
script_stop :: proc(session: ^Session) {
  if !session.script.active {
    return
  }
  behaviour_goto(session, .Idle)
  script_run_free(&session.script)
}

// --- CLI --------------------------------------------------------------------------------------------

cli_script :: proc(session: ^Session, args: []string) {
  if len(args) == 0 {
    script_print_status(session)
    return
  }
  switch args[0] {
  case "status":
    script_print_status(session)
  case "blocks", "catalog":
    script_print_blocks(session)
  case "selftest":
    script_cmd_selftest(session)
  case "list":
    script_cmd_list(session)
  case "show":
    script_cmd_show(session, args[1:])
  case "run", "start":
    script_cmd_run(session, args[1:])
  case "trace", "log":
    script_cmd_trace(session, args[1:])
  case "lint", "check":
    script_cmd_lint(session, args[1:])
  case "reseed", "defaults":
    // The replacement for "delete the file to get the built-in back", now that there are no built-ins.
    // Only fills GAPS - an edited auto.bhv is yours and is never overwritten - so this is safe to run
    // at any time, which is what makes it a usable answer to "I broke auto".
    if n := bhv_seed_defaults(quiet = false); n > 0 {
      fmt.printfln("script: wrote %d missing default behaviour(s).", n)
    } else {
      fmt.println("script: nothing to write - every default behaviour already exists.")
      fmt.println("  'script delete <name>' one first if you want it back at its default.")
    }
  case "nocollision", "ignorecollision":
    script_cmd_ignore_collision(args[1:])
  case "pause":
    if !session.script.active {
      fmt.eprintln("script pause: nothing running.")
    } else if script_set_paused(session, true) {
      fmt.printfln("script: '%s' PAUSED - %s. 'script resume' to continue.", session.script.name, script_where(&session.script))
    } else {
      fmt.println("script: already paused.")
    }
  case "resume", "play", "continue":
    if !session.script.active {
      fmt.eprintln("script resume: nothing running.")
    } else if script_set_paused(session, false) {
      fmt.printfln("script: '%s' resumed.", session.script.name)
    } else {
      fmt.println("script: not paused.")
    }
  case "reset", "restart":
    if !script_reset(session) {
      fmt.eprintln("script reset: nothing running.")
    } else {
      run := &session.script
      fmt.printfln("script: '%s' reset - every rule re-armed, reading from the top%s.", run.name, run.paused ? " (still paused)" : "")
    }
  case "export":
    script_cmd_export(args[1:])
  case "save":
    script_cmd_save(session, args[1:])
  case "delete", "rm":
    script_cmd_delete(args[1:])
  case "rename", "mv":
    script_cmd_rename(args[1:])
  case "stop":
    if !session.script.active {
      fmt.println("script: nothing running.")
      return
    }
    name := session.script.name
    script_stop(session)
    fmt.printfln("script: '%s' stopped (anything in flight was torn down).", name)
  case:
    fmt.eprintfln("script: unknown subcommand '%s'", args[0])
    fmt.eprintln("  status | blocks | list | show <name> | run <name> | stop")
    fmt.eprintln("  pause | resume | reset | trace [n|all|clear] | lint [name]")
    fmt.eprintln("  export <name> [as <new>] | save <name> | delete <name> | rename <old> <new>")
    fmt.eprintln("  reseed - write the default behaviours (auto, hunt, sweep) back if any are missing")
  }
}

// Where a run currently is, as one phrase. A list has no program counter, so the honest answer names
// the RULE that has control and how far into its steps it is - which is also the only position that
// exists to name.
script_where :: proc(run: ^Script_Run) -> string {
  if run.active_rule < 0 || run.active_rule >= len(run.rules) {
    return fmt.tprintf("no rule has control (reading %d from the top)", len(run.rules))
  }
  rule := &run.rules[run.active_rule]
  return fmt.tprintf(
    "rule %d/%d '%s', step %d/%d",
    run.active_rule + 1, len(run.rules), rule.label,
    min(run.pc + 1, len(rule.steps)), len(rule.steps),
  )
}

// The `status full` detail section: the machine's state, and every block that is NOT usable right
// now with the reason. Deliberately lists only the gated ones - the point is "what do I still need",
// and `script blocks` is there for the full catalog.
cli_status_behaviour :: proc(session: ^Session) {
  fmt.println("BEHAVIOUR (scripts + the state machine that will replace the hardcoded 'auto'):")
  fmt.printfln("  machine  : %s%s", behaviour_state_name(session.bh_state), session.bh_entered ? "" : "  (not entered yet)")
  fmt.printfln("  script   : %s", script_status_line(session))
  // Only when something IS held: a key the tool is holding down is invisible otherwise, and it is the
  // one piece of state here that keeps acting on the game with nothing on screen to say so.
  if n := keys_held_count(session); n > 0 {
    fmt.printfln("  keys held: %s   ('key release' lets go of all %d)", keys_held_text(session), n)
  }
  fmt.printfln("  behaviours: %d in %s - 'script list'", len(bhv_list_names()), bhv_dir_path())
  cli_status_interrupts(session)
  gated := 0
  for def in ACTIONS {
    if ok, why := script_block_gate(session, def.avail, def.not_built, def.not_built_why); !ok {
      if gated == 0 {
        fmt.println("  blocks not usable right now:")
      }
      fmt.printfln("    %s %-18s %s", def.not_built ? "[xx]" : "[--]", def.name, why)
      gated += 1
    }
  }
  for def in EVENTS {
    if ok, why := script_block_gate(session, def.avail, def.not_built, def.not_built_why); !ok {
      if gated == 0 {
        fmt.println("  blocks not usable right now:")
      }
      fmt.printfln("    %s %-18s %s", def.not_built ? "[xx]" : "[--]", def.name, why)
      gated += 1
    }
  }
  if gated == 0 {
    fmt.println("  every block is usable.")
  }
}

// One line for `status` - the whole feature's state, and how many blocks are still gated. Kept here
// beside the rest of the script surface so `status` can never drift from what the catalog actually
// says (the same single-source-of-truth rule setup_groups follows).
script_status_line :: proc(session: ^Session) -> string {
  gated := 0
  total := len(ACTIONS) + len(EVENTS)
  for def in ACTIONS {
    if ok, _ := script_block_gate(session, def.avail, def.not_built, def.not_built_why); !ok {
      gated += 1
    }
  }
  for def in EVENTS {
    if ok, _ := script_block_gate(session, def.avail, def.not_built, def.not_built_why); !ok {
      gated += 1
    }
  }
  state := "idle"
  if run := &session.script; run.active {
    // An interrupt outranks the behaviour's own state on this line, because while one has control the
    // behaviour is suspended and its rule is NOT what is happening.
    what := run.paused ? "PAUSED" : (session.global_active >= 0 ? "INTERRUPT" : "RUNNING")
    state = fmt.tprintf("%s '%s' - %s", what, run.name, script_where(run))
  }
  sensing := session.bh_sense_on ? ", sensing on" : ""
  return fmt.tprintf("%s%s  |  %d/%d blocks usable ('script blocks')", state, sensing, total - gated, total)
}

script_print_status :: proc(session: ^Session) {
  run := &session.script
  if !run.active {
    fmt.println("script: nothing running.")
    fmt.println("  'script list' shows every behaviour, 'script run <name>' starts one.")
    fmt.println("  'script blocks' lists everything a script can do.")
    return
  }
  now := time.now()._nsec
  what := run.paused ? "PAUSED" : "RUNNING"
  fmt.printfln("script: '%s' %s%s", run.name, what, run.route == "" ? "" : fmt.tprintf(", route '%s'", run.route))
  fmt.printfln("  %s, %d step(s) executed, %s elapsed", script_where(run), run.steps_done, fmt_elapsed(now - run.started_at))
  if run.last_line != "" {
    fmt.printfln("  current: %s", run.last_line)
  }
  // THE WHOLE LIST, every time. This is the payoff of the model: "why is it doing that" is answered by
  // reading the rules in order and seeing which one is lit, not by tracing edges backwards from a node.
  for &rule, i in run.rules {
    mark := i == run.active_rule ? ">" : " "
    b := strings.builder_make(context.temp_allocator)
    script_write_condition(&b, rule.condition, true)
    fmt.printfln(
      "  %s %2d. WHEN %-34s %s%s   x%d",
      mark, i + 1, strings.to_string(b), rule.label,
      rule.enabled ? "" : "  [OFF]", rule.fires,
    )
  }
  // Innermost last, so "why is it not on the rule I expect" names everything between here and the top.
  for i in 0 ..< min(run.rule_depth, len(run.rule_frames)) {
    f := run.rule_frames[i]
    if f.rule >= 0 && f.rule < len(run.rules) {
      fmt.printfln("  ^ rule %d was interrupted at step %d and resumes when this one finishes.", f.rule + 1, f.step + 1)
    }
  }
  fmt.println("  'script stop' ends it.")
}

script_print_blocks :: proc(session: ^Session) {
  fmt.println("=== behaviour blocks ===")
  fmt.println("ACTIONS (things a script does):")
  for def in ACTIONS {
    mark, why := script_avail_mark(session, def.avail, def.not_built, def.not_built_why)
    fmt.printfln("  %s %-16s %s%s", mark, script_sig(def.name, def.params), def.blurb, why)
  }
  fmt.println("EVENTS (things a script can wait for / react to):")
  for def in EVENTS {
    mark, why := script_avail_mark(session, def.avail, def.not_built, def.not_built_why)
    fmt.printfln("  %s %-16s %s%s", mark, script_sig(def.name, def.params), def.blurb, why)
  }
  fmt.println("STRUCTURE - there is almost none, and that is the design:")
  fmt.println("           a behaviour is a ROUTE plus an ordered list of WHEN <condition> DO <steps>.")
  fmt.println("           The list is read top to bottom every tick and the first WHEN that holds wins;")
  fmt.println("           a rule higher up interrupts one lower down, and the lower one RESUMES.")
  fmt.println("           Inside a DO the only shapes are an action and 'wait_for <event>' - no branching,")
  fmt.println("           ever. Anything that needs one is an Odin verb instead (see 'kill', 'approach').")
  fmt.println("[--] means the block is built but not usable right NOW - the reason says what it needs")
  fmt.println("     (an attach, a finder). You can still put it in a chart; the run is what gets refused.")
  fmt.println("[xx] means the block is not built yet - the reason names the recon that would unblock it.")
  fmt.println("     These are the only blocks the editor will not let you place.")
}

// "Can this block run right now, and if not, why not" - the ONE place the two refusals are combined,
// so `script blocks`, `script status`, `status` and the editor's greying can never disagree about which
// blocks are live. Note this is RUNNABILITY, not placeability: the editor gates placing a node on
// def.not_built alone (see Action_Def.not_built), and uses this only to decide how to draw it.
script_block_gate :: proc(
  session: ^Session,
  avail: proc(session: ^Session) -> (ok: bool, why: string),
  not_built: bool,
  not_built_why: string,
) -> (ok: bool, why: string) {
  if not_built {
    return false, not_built_why
  }
  if avail == nil {
    return true, ""
  }
  return avail(session)
}

// The mark for one catalog row. Two different "no" answers, deliberately spelled differently: [xx] is a
// property of the tool and will read the same tomorrow, [--] is a property of this moment and clears
// the instant you attach or run the finder it names.
script_avail_mark :: proc(
  session: ^Session,
  avail: proc(session: ^Session) -> (ok: bool, why: string),
  not_built: bool,
  not_built_why: string,
) -> (mark: string, why: string) {
  ok, w := script_block_gate(session, avail, not_built, not_built_why)
  if ok {
    return "[OK]", ""
  }
  return not_built ? "[xx]" : "[--]", fmt.tprintf("   -> %s", w)
}

script_sig :: proc(name: string, params: []Param_Spec) -> string {
  if len(params) == 0 {
    return name
  }
  b := strings.builder_make(context.temp_allocator)
  strings.write_string(&b, name)
  for p in params {
    if p.optional {
      fmt.sbprintf(&b, " [%s]", p.name)
    } else {
      fmt.sbprintf(&b, " <%s>", p.name)
    }
  }
  return strings.to_string(b)
}

// --- self-test --------------------------------------------------------------------------------------

// Every headless check the behaviour half has, in one command.
//
// It USED to open on a proof that node identity survives a structural edit - insert a step at the
// front, re-resolve, check every edge still lands on the same node. That claim went away with the
// edges: a rule's steps are a numbered list, so there is nothing an insert can silently retarget.
// What replaced it as the load-bearing evaluation test is script_selftest_rules, which proves the four
// rules of arbitration directly.
script_cmd_selftest :: proc(session: ^Session) {
  fmt.println("=== behaviour data self-test ===")
  script_selftest_roundtrip()
  name_list_selftest()
  script_selftest_alert()
  // Last, and called from here rather than chained off the end of the others, because they are the
  // sections that need the SESSION - they write and read real variables.
  script_selftest_coord(session)
  script_selftest_rules(session)
  script_selftest_behaviours(session)
}

// The alert envelope (alert.odin), checked as arithmetic - it drives a full-window effect that no
// headless test can look at, so the numbers are the only thing there is to hold on to.
//
// Two of these are real invariants rather than regression guards. The border must never cross
// ALERT_ALPHA_CEILING, because an alert you cannot read the map through stops being a notification and
// becomes a modal. And it must reach EXACTLY zero, because an alert that leaves a permanent tint on the
// window is a bug everyone would blame on the renderer.
@(private = "file")
script_selftest_alert :: proc() {
  fmt.println("=== alert envelope ===")
  fails := 0

  hold := i64(3 * time.Second)
  a := Alert_State{active = true, severity = .Danger, hold_ns = hold}
  total := ALERT_ATTACK_NS + hold + ALERT_RELEASE_NS

  if v := alert_envelope(a, 0); v != 0 {
    fmt.eprintfln("  FAIL: envelope at t=0 is %v, want 0", v)
    fails += 1
  }
  if v := alert_envelope(a, ALERT_ATTACK_NS); v < 0.999 {
    fmt.eprintfln("  FAIL: envelope at the top of the attack is %v, want 1", v)
    fails += 1
  }
  if v := alert_envelope(a, ALERT_ATTACK_NS + hold / 2); v < 0.999 {
    fmt.eprintfln("  FAIL: envelope mid-sustain is %v, want 1", v)
    fails += 1
  }
  if v := alert_envelope(a, total); v != 0 {
    fmt.eprintfln("  FAIL: envelope at the end is %v, want 0", v)
    fails += 1
  }
  if v := alert_envelope(a, total + i64(time.Second)); v != 0 {
    fmt.eprintfln("  FAIL: envelope a second past the end is %v, want 0", v)
    fails += 1
  }

  // Monotonic on both ramps. A wobble on the way in or out reads as a dropped frame, and a dropped
  // frame in the one thing that is meant to look deliberate undermines the whole effect.
  previous := f32(-1)
  for i in 0 ..= 40 {
    v := alert_envelope(a, ALERT_ATTACK_NS * i64(i) / 40)
    if v < previous {
      fmt.eprintfln("  FAIL: attack ramp went backwards at step %d (%v after %v)", i, v, previous)
      fails += 1
      break
    }
    previous = v
  }
  previous = 2
  for i in 0 ..= 40 {
    v := alert_envelope(a, ALERT_ATTACK_NS + hold + ALERT_RELEASE_NS * i64(i) / 40)
    if v > previous {
      fmt.eprintfln("  FAIL: release ramp went back up at step %d (%v after %v)", i, v, previous)
      fails += 1
      break
    }
    previous = v
  }

  // A sticky alert holds until something clears it, and the clear FADES rather than cutting.
  sticky := Alert_State{active = true, severity = .Warn, hold_ns = 0}
  if v := alert_envelope(sticky, i64(time.Hour)); v < 0.999 {
    fmt.eprintfln("  FAIL: a 0-second alert faded on its own (%v an hour in), want it held", v)
    fails += 1
  }
  sticky.ended_at = i64(time.Second)
  if v := alert_envelope(sticky, sticky.ended_at + ALERT_RELEASE_NS / 2); v <= 0 || v >= 1 {
    fmt.eprintfln("  FAIL: a cleared alert is at %v halfway through its fade, want strictly between 0 and 1", v)
    fails += 1
  }
  if v := alert_envelope(sticky, sticky.ended_at + ALERT_RELEASE_NS); v != 0 {
    fmt.eprintfln("  FAIL: a cleared alert is at %v after its fade, want 0", v)
    fails += 1
  }

  // A clear that lands mid-attack must come back DOWN, not finish rising first.
  interrupted := Alert_State{active = true, severity = .Info, hold_ns = 0, ended_at = ALERT_ATTACK_NS / 2}
  if v := alert_envelope(interrupted, ALERT_ATTACK_NS / 2 + ALERT_RELEASE_NS); v != 0 {
    fmt.eprintfln("  FAIL: an alert cleared mid-attack is at %v after its fade, want 0", v)
    fails += 1
  }

  // THE readability invariant: peak border opacity, breathing and all, over a full cycle.
  worst := f32(0)
  for severity in Alert_Severity {
    for i in 0 ..< 400 {
      seconds := f64(i) / 400 / f64(ALERT_PULSE_HZ) // one whole breath
      worst = max(worst, ALERT_PEAK_ALPHA[severity] * alert_pulse(seconds))
    }
  }
  if worst > ALERT_ALPHA_CEILING {
    fmt.eprintfln("  FAIL: border peaks at alpha %v, over the %v ceiling - the map stops being readable through it", worst, ALERT_ALPHA_CEILING)
    fails += 1
  }

  // The banner's size animation: lands oversized, settles to 1, swells again as it goes. The settled
  // size is the one that matters - text that comes to rest anywhere but 1 is text drawn at the wrong
  // size for as long as it is up.
  steady := alert_pulse(0.25 / f64(ALERT_PULSE_HZ)) // the top of the breath, where the wobble is +ALERT_BREATH
  if v := alert_text_scale(a, 0, steady); v < 1 + ALERT_PUNCH - 0.01 {
    fmt.eprintfln("  FAIL: banner lands at %vx, want about %vx", v, 1 + ALERT_PUNCH)
    fails += 1
  }
  if v := alert_text_scale(a, ALERT_ATTACK_NS + hold / 2, steady); abs(v - 1) > ALERT_BREATH + 0.001 {
    fmt.eprintfln("  FAIL: banner settles at %vx, want 1x give or take the %v breath", v, ALERT_BREATH)
    fails += 1
  }
  if v := alert_text_scale(a, total, steady); v < 1 + ALERT_DISSIPATE - ALERT_BREATH - 0.001 {
    fmt.eprintfln("  FAIL: banner ends at %vx, want it swollen to about %vx", v, 1 + ALERT_DISSIPATE)
    fails += 1
  }
  // Monotonic settle: a wobble on the way down would read as the text bouncing, which is a different
  // (and much noisier) effect from the one intended.
  previous = f32(1e9)
  for i in 0 ..= 40 {
    v := alert_text_scale(a, ALERT_ATTACK_NS * i64(i) / 40, steady)
    if v > previous + 0.0001 {
      fmt.eprintfln("  FAIL: banner grew again while settling, at step %d (%v after %v)", i, v, previous)
      fails += 1
      break
    }
    previous = v
  }

  // The message is user text, so it can be any length and any encoding. Truncating it must not leave a
  // half-written rune behind - that draws as a replacement box and looks like a bug in the alert.
  long := strings.repeat("★", 60, context.temp_allocator) // 60 stars, 3 bytes each
  truncated := Alert_State{}
  alert_set_text(&truncated, long)
  text := alert_text(&truncated)
  if len(text) > ALERT_TEXT_MAX {
    fmt.eprintfln("  FAIL: truncated message is %d bytes, over the %d cap", len(text), ALERT_TEXT_MAX)
    fails += 1
  }
  if !utf8.valid_string(text) {
    fmt.eprintfln("  FAIL: truncation split a rune - %q is not valid UTF-8", text)
    fails += 1
  }

  if fails == 0 {
    fmt.printfln(
      "  PASS: envelope, sticky/clear fades, banner size %.2fx -> 1x -> %.2fx, alpha ceiling (peak %.3f of %.2f)",
      1 + ALERT_PUNCH,
      1 + ALERT_DISSIPATE,
      worst,
      ALERT_ALPHA_CEILING,
    )
  } else {
    fmt.eprintfln("  %d alert check(s) failed", fails)
  }
}

// Prove the file format is lossless: build every Odin behaviour, serialize it, parse it back, and
// compare the RENDERED programs. Rendering both sides rather than memcmp-ing the structs is the point -
// it compares exactly what the walker will execute (ops, edges, block kinds, every argument) while
// ignoring the things that legitimately differ (heap pointers, per-run scratch).
@(private = "file")
script_selftest_roundtrip :: proc() {
  fmt.println("  --- save/load round-trip ---")
  fails := 0
  // BOTH registries: the hidden verification set is most of the coverage here, because it is the only
  // thing that puts every kind of payload - numbers, strings, multi-row conditions, `until` - through
  // the writer and the reader in one pass.
  all := make([dynamic]Behaviour_Def, 0, len(SEED_BEHAVIOURS) + len(TEST_BEHAVIOURS), context.temp_allocator)
  append(&all, ..SEED_BEHAVIOURS[:])
  append(&all, ..TEST_BEHAVIOURS[:])
  for &d in all {
    doc, ok := bhv_from_builtin(&d)
    if !ok {
      fmt.eprintfln("  FAIL: '%s' would not build", d.name)
      fails += 1
      continue
    }
    defer behaviour_doc_free(&doc)

    b := strings.builder_make(context.temp_allocator)
    bhv_serialize(&doc, &b)
    text := strings.to_string(b)

    back, bok := bhv_deserialize(d.name, text)
    if !bok {
      fmt.eprintfln("  FAIL: '%s' did not parse back", d.name)
      fails += 1
      continue
    }
    defer behaviour_doc_free(&back)

    if back.route != doc.route || len(back.rules) != len(doc.rules) {
      fmt.eprintfln(
        "  FAIL: '%s' header/shape differs (route '%s'->'%s', %d->%d rules)",
        d.name, doc.route, back.route, len(doc.rules), len(back.rules),
      )
      fails += 1
      continue
    }
    // THE WRITER'S OWN OUTPUT is the comparison, re-serialized. That makes this a genuine fixed-point
    // check over every field the format carries - a rule's id, its firing mode, its enabled flag, its
    // label, every condition row and every step payload - rather than over whichever subset a
    // hand-written comparator remembered to look at. It is also what caught a rule losing `off` across
    // a save, which no field-by-field check had been written for.
    again := strings.builder_make(context.temp_allocator)
    bhv_serialize(&back, &again)
    if strings.to_string(again) != text {
      fmt.eprintfln("  FAIL: '%s' changed across a save/load:", d.name)
      fmt.eprintfln("--- built ---\n%s--- reloaded ---\n%s", text, strings.to_string(again))
      fails += 1
      continue
    }
    // Identity has to survive too, and re-serializing cannot prove it: ids are written, so two
    // documents that renumbered identically would still compare equal. The trace ring and the Problems
    // tab both address rows by id, so a renumber is a silently broken editor rather than a bad file.
    for rule, i in doc.rules {
      if back.rules[i].id != rule.id || len(back.rules[i].steps) != len(rule.steps) {
        fmt.eprintfln("  FAIL: '%s' rule %d: id/steps %d/%d -> %d/%d", d.name, i + 1, u32(rule.id), len(rule.steps), u32(back.rules[i].id), len(back.rules[i].steps))
        fails += 1
        break
      }
      for s, si in rule.steps {
        if back.rules[i].steps[si].id != s.id {
          fmt.eprintfln("  FAIL: '%s' rule %d step %d: id %d came back as %d", d.name, i + 1, si + 1, u32(s.id), u32(back.rules[i].steps[si].id))
          fails += 1
          break
        }
      }
    }
  }
  if fails == 0 {
    fmt.printfln("  PASS: all %d behaviours survive serialize -> parse -> serialize unchanged", len(all))
  } else {
    fmt.eprintfln("  %d behaviour(s) did not round-trip", fails)
  }
  script_selftest_payload()
}

// The Coord expression path, end to end and WITHOUT a client: script_coord touches only the variable
// store, so the one part of "positions are variables" that needs a game attached is the walking.
//
// What it guards: a literal must keep ignoring the string slot (every chart written before this
// change), an expression must beat the literal sitting underneath it, a composite must work because
// expansion is textual and `@x,@z` is a perfectly good way to write one, and a miss must FAIL rather
// than resolve to 0,0 - which would send the character across the map instead of refusing.
@(private = "file")
script_selftest_coord :: proc(session: ^Session) {
  fmt.println("  --- coordinate expressions ---")
  fails := 0
  board: Behaviour_Board
  ctx := Behaviour_Context {
    session = session,
    board   = &board,
  }
  spec := PARAMS_WALK_TO[:]

  engine.session_var_set(&session.eng, "st_spot", "6800,3300")
  engine.session_var_set(&session.eng, "st_x", "120")
  engine.session_var_set(&session.eng, "st_z", "-45.5")
  defer {
    for name in ([?]string{"st_spot", "st_x", "st_z"}) {
      engine.session_var_set(&session.eng, name, "")
    }
  }

  check :: proc(what: string, got_x, got_z: f32, got_ok: bool, want_x, want_z: f32, want_ok: bool, fails: ^int) {
    if got_ok != want_ok || (want_ok && (got_x != want_x || got_z != want_z)) {
      fmt.eprintfln("  FAIL: %s: got (%v, %v) ok=%v, wanted (%v, %v) ok=%v", what, got_x, got_z, got_ok, want_x, want_z, want_ok)
      fails^ += 1
    }
  }

  x, z, ok := script_coord(&ctx, {10, 20, 0, 0}, {"", ""}, spec, 0)
  check("literal", x, z, ok, 10, 20, true, &fails)

  x, z, ok = script_coord(&ctx, {10, 20, 0, 0}, {"@st_spot", ""}, spec, 0)
  check("expression wins over the literal", x, z, ok, 6800, 3300, true, &fails)

  x, z, ok = script_coord(&ctx, {}, {"@st_x,@st_z", ""}, spec, 0)
  check("one variable per axis", x, z, ok, 120, -45.5, true, &fails)

  _, _, ok = script_coord(&ctx, {10, 20, 0, 0}, {"@st_nothing", ""}, spec, 0)
  if ok {
    fmt.eprintfln("  FAIL: an unset variable resolved instead of failing")
    fails += 1
  }
  _, _, ok = script_coord(&ctx, {10, 20, 0, 0}, {"@st_x", ""}, spec, 0)
  if ok {
    fmt.eprintfln("  FAIL: '120' is one number, not a position, and was accepted as one")
    fails += 1
  }

  if fails == 0 {
    fmt.println("  PASS: coordinates resolve from literals, variables and per-axis variables; a miss fails")
  }
}

// Prove that the three things which decide WHERE an argument lives agree, for every row in the
// catalog: the writer (script_write_params), the reader (bhv_parse_params) and param_slot - which is
// what the node editor's inspector binds its widgets through.
//
// The round-trip test above cannot see this. It compares RENDERED programs, and the renderer reads
// the same slot it wrote, so a value stored in the wrong slot renders as its default on both sides
// and compares equal while the number is silently gone. This test puts a DISTINCT probe in every
// parameter and checks each one comes back where param_slot says it should, which is exactly the
// failure kills_of and player_named_near had.
// Distinct, exactly-representable probes: whole numbers (so script_write_num round-trips without a
// decimal tail) and bare words (so no quoting is involved).
@(private = "file")
probe_num :: proc(i: int) -> f64 {return f64(3 + i * 7)}

@(private = "file")
probe_str :: proc(i: int) -> string {return fmt.tprintf("p%d", i)}

// <blank> fills every STRING argument with "" instead. That is not a contrived case: it is exactly
// what the node editor saves while a chart is half-authored, and writing an empty argument bare made
// the line re-read as if the argument were absent, so the file would not load back.
@(private = "file")
probe_fill :: proc(spec: []Param_Spec, nums: ^[4]f64, strs: ^[2]string, blank: bool) {
  for p, i in spec {
    num_slot, str_slot := param_slots(spec, i)
    switch p.kind {
    case .Num, .Duration, .Percent:
      nums[num_slot] = probe_num(i)
    case .Coord:
      // Both halves, in both passes: <blank> exercises the LITERAL (empty expression, real numbers),
      // and the filled pass exercises the EXPRESSION, whose numbers must come back zeroed because the
      // file only carried the text. Those are the two states a Coord can be in, and neither is
      // covered by the other.
      if blank {
        nums[num_slot] = probe_num(i)
        nums[num_slot + 1] = probe_num(i) + 1
        strs[str_slot] = ""
      } else {
        nums[num_slot] = 0
        nums[num_slot + 1] = 0
        strs[str_slot] = fmt.tprintf("@p%d", i)
      }
    case .Str, .Names, .Mob, .Key, .Var_Name, .Choice, .Chart_Name:
      strs[str_slot] = blank ? "" : probe_str(i)
    }
  }
}

// Compare only the slots the spec actually claims - the rest of the flat payload is untouched.
@(private = "file")
probe_check :: proc(what: string, spec: []Param_Spec, want_n, got_n: [4]f64, want_s, got_s: [2]string, fails: ^int) {
  for p, i in spec {
    num_slot, str_slot := param_slots(spec, i)
    slot := num_slot
    bad := false
    switch p.kind {
    case .Num, .Duration, .Percent:
      bad = want_n[slot] != got_n[slot]
    case .Coord:
      bad =
        want_n[slot] != got_n[slot] ||
        want_n[slot + 1] != got_n[slot + 1] ||
        want_s[str_slot] != got_s[str_slot]
    case .Str, .Names, .Mob, .Key, .Var_Name, .Choice, .Chart_Name:
      slot = str_slot
      bad = want_s[slot] != got_s[slot]
    }
    if bad {
      fmt.eprintfln("  FAIL: %s: argument '%s' (%v) did not survive slot %d", what, p.name, p.kind, slot)
      fails^ += 1
    }
  }
}

@(private = "file")
probe_action :: proc(def: Action_Def, blank: bool, fails: ^int) {
  a := Script_Action {
    kind = def.kind,
  }
  probe_fill(def.params, &a.nums, &a.strs, blank)
  b := strings.builder_make(context.temp_allocator)
  script_write_action(&b, a)
  back, ok, err := bhv_parse_action(bhv_tokens(strings.to_string(b)))
  if !ok {
    fmt.eprintfln("  FAIL: action '%s' rendered as '%s' but would not parse back: %s", def.name, strings.to_string(b), err)
    fails^ += 1
    return
  }
  defer {delete(back.strs[0]);delete(back.strs[1])}
  if back.kind != a.kind {
    fmt.eprintfln("  FAIL: action '%s' came back as a different block", def.name)
    fails^ += 1
    return
  }
  probe_check(def.name, def.params, a.nums, back.nums, a.strs, back.strs, fails)
}

@(private = "file")
probe_event :: proc(def: Event_Def, blank: bool, fails: ^int) {
  e := Script_Event {
    kind = def.kind,
  }
  probe_fill(def.params, &e.nums, &e.strs, blank)
  b := strings.builder_make(context.temp_allocator)
  script_write_event(&b, e)
  back, ok, err := bhv_parse_event(bhv_tokens(strings.to_string(b)))
  if !ok {
    fmt.eprintfln("  FAIL: event '%s' rendered as '%s' but would not parse back: %s", def.name, strings.to_string(b), err)
    fails^ += 1
    return
  }
  defer {delete(back.strs[0]);delete(back.strs[1])}
  if back.kind != e.kind {
    fmt.eprintfln("  FAIL: event '%s' came back as a different block", def.name)
    fails^ += 1
    return
  }
  probe_check(def.name, def.params, e.nums, back.nums, e.strs, back.strs, fails)
}

@(private = "file")
script_selftest_payload :: proc() {
  fmt.println("  --- parameter slots ---")
  fails := 0
  // Twice over: once with a distinct value in every argument, once with every STRING blank. The
  // second pass is the half-authored chart, and it is the one that found a real bug.
  for pass in 0 ..< 2 {
    blank := pass == 1
    for def in ACTIONS {
      probe_action(def, blank, &fails)
    }
    for def in EVENTS {
      probe_event(def, blank, &fails)
    }
  }
  if fails == 0 {
    fmt.printfln("  PASS: all %d blocks round-trip every argument, filled and blank", len(ACTIONS) + len(EVENTS))
  } else {
    fmt.eprintfln("  %d argument(s) did not survive", fails)
  }
  script_selftest_conditions()
  script_selftest_meta()
}

// Prove a MULTI-ROW condition survives the file format, in both join modes.
//
// The format spells one out as repeated `if` lines plus a `match=` key, so the two failure modes are
// specific and neither would crash: rows collapsing into one (the reader replacing instead of
// appending, which is what it used to do) and the join mode being dropped (an `any of` coming back as
// `all of`, silently turning a rescue that fires on either signal into one that needs both).
@(private = "file")
script_selftest_conditions :: proc() {
  fmt.println("  --- multi-condition rows ---")
  fails := 0
  for mode in 0 ..< 2 {
    for rows in 1 ..= SCRIPT_MAX_CONDITION_ROWS {
      steps := make([dynamic]Script_Step, context.temp_allocator)
      st := Script_Step {
        id = 1,
        op = .Wait_For,
      }
      st.condition.match_any = mode == 1
      st.condition.row_count = rows
      // Distinct rows, so a collapse or a reorder cannot pass by looking like the row it replaced.
      for i in 0 ..< rows {
        r := condition_row_ptr(&st.condition, i)
        r^ = Script_Event {
          kind = .Kills,
        }
        r.nums[0] = f64(10 + i)
        r.negate = i % 2 == 1
      }
      st.src = step_label(st)
      append(&steps, st)

      rule := Rule {
        id      = 1,
        steps   = steps,
        enabled = true,
      }
      condition_row_ptr(&rule.condition, 0)^ = Script_Event{kind = .Always}
      rule.condition.row_count = 1
      rules := make([dynamic]Rule, context.temp_allocator)
      append(&rules, rule)
      doc := Behaviour_Doc {
        name  = "condtest",
        rules = rules,
      }
      b := strings.builder_make(context.temp_allocator)
      bhv_serialize(&doc, &b)
      back, ok := bhv_deserialize("condtest", strings.to_string(b))
      if !ok {
        fmt.eprintfln("  FAIL: %d-row '%s' condition would not parse back:\n%s", rows, mode == 1 ? "any" : "all", strings.to_string(b))
        fails += 1
        continue
      }
      defer behaviour_doc_free(&back)
      got := back.rules[0].steps[0].condition
      if condition_row_count(got) != rows {
        fmt.eprintfln("  FAIL: %d rows came back as %d", rows, condition_row_count(got))
        fails += 1
        continue
      }
      if got.match_any != st.condition.match_any {
        fmt.eprintfln("  FAIL: %d-row join mode came back as '%s'", rows, got.match_any ? "any" : "all")
        fails += 1
        continue
      }
      for i in 0 ..< rows {
        w, g := condition_row(st.condition, i), condition_row(got, i)
        if w.kind != g.kind || w.nums[0] != g.nums[0] || w.negate != g.negate {
          fmt.eprintfln("  FAIL: row %d of %d changed (%v %v %v -> %v %v %v)", i, rows, w.kind, w.nums[0], w.negate, g.kind, g.nums[0], g.negate)
          fails += 1
          break
        }
      }
    }
  }
  if fails == 0 {
    fmt.printfln("  PASS: conditions of 1..%d rows survive a save/load in both join modes", SCRIPT_MAX_CONDITION_ROWS)
  } else {
    fmt.eprintfln("  %d condition(s) did not round-trip", fails)
  }
}

// Prove every block and every ARGUMENT is documented.
//
// This is a lint, not a behaviour test, and it is here rather than in a code review because the chart
// options panel is GENERATED from this metadata: a Param_Spec with no title is an unlabelled box in
// the UI and one with no help is a number you have to read script_blocks.odin to set. Neither fails
// anything at runtime, so nothing else would ever catch it - the block just quietly ships unusable to
// anyone who did not write it. Adding a block to the catalog now fails the test suite until it is
// described, which is the only enforcement that actually holds up over time.
//
// `name` is deliberately NOT accepted as a substitute for `title`. prose_title_of_name does prettify
// it, and the editor still falls back to that so a half-finished block is drawn rather than blank,
// but "min gain" is not a label - it is a variable name with the underscore taken out.
@(private = "file")
script_selftest_meta :: proc() {
  fmt.println("  --- block documentation ---")
  fails := 0

  check_params :: proc(what: string, spec: []Param_Spec, fails: ^int) {
    for p in spec {
      if p.title == "" {
        fmt.eprintfln("  FAIL: %s: argument '%s' has no title", what, p.name)
        fails^ += 1
      }
      if p.help == "" {
        fmt.eprintfln("  FAIL: %s: argument '%s' has no help text", what, p.name)
        fails^ += 1
      }
      // A .Choice with no values is worse than a .Str: the picker offers nothing and the linter
      // warns about every value it ever sees, because none of them is in the empty set. Anything
      // whose values are only known at run time (a saved path, a character name) is a .Str.
      if p.kind == .Choice && len(p.choices) == 0 {
        fmt.eprintfln("  FAIL: %s: argument '%s' is a Choice with no choices", what, p.name)
        fails^ += 1
      }
      // An optional numeric argument whose default is 0 reads as "off" in the options panel unless the
      // help says otherwise, and for every ladder tunable 0 means the OPPOSITE - "use the configured
      // value". Requiring the word is crude but it has to be said somewhere, and here is the only
      // place that can insist.
      // A "bool" is exempt: it is drawn as a checkbox, and an unticked box already says what 0 means.
      if p.optional && p.def == 0 && p.help != "" && p.unit != "bool" {
        switch p.kind {
        case .Num, .Duration, .Percent:
          if !strings.contains(p.help, "0 ") {
            fmt.eprintfln("  FAIL: %s: argument '%s' defaults to 0 but its help never says what 0 means", what, p.name)
            fails^ += 1
          }
        case .Coord, .Str, .Names, .Mob, .Key, .Var_Name, .Choice, .Chart_Name:
        }
      }
    }
  }

  for def in ACTIONS {
    if def.title == "" {
      fmt.eprintfln("  FAIL: action '%s' has no title", def.name)
      fails += 1
    }
    if def.blurb == "" {
      fmt.eprintfln("  FAIL: action '%s' has no blurb", def.name)
      fails += 1
    }
    check_params(def.name, def.params, &fails)
  }
  for def in EVENTS {
    if def.title == "" {
      fmt.eprintfln("  FAIL: event '%s' has no title", def.name)
      fails += 1
    }
    if def.blurb == "" {
      fmt.eprintfln("  FAIL: event '%s' has no blurb", def.name)
      fails += 1
    }
    check_params(def.name, def.params, &fails)
  }

  if fails == 0 {
    fmt.printfln("  PASS: all %d blocks and every argument carry a title and a description", len(ACTIONS) + len(EVENTS))
  } else {
    fmt.eprintfln("  %d piece(s) of metadata missing - the options panel would draw them unlabelled", fails)
  }
  script_selftest_lint()
}

// Every SHIPPED behaviour must lint clean of errors and warnings.
//
// The regression this guards: `auto`, `hunt` and `sweep` are generated from a config (bh_auto walks
// Auto_Cfg and decides which nodes exist), so a change to the ladder's shape can leave a rung wired to a
// node that is no longer emitted - a dangling edge that nothing notices until the run refuses to start.
// The linter answers exactly that question, and asking it here means a broken built-in fails the suite
// rather than failing a farm. Notes are excluded on purpose: they are true and deliberate on these
// charts (the last rung of the ladder has nowhere to fall back to), and a test that failed on them would
// be a test somebody turns off.
@(private = "file")
script_selftest_lint :: proc() {
  fmt.println("  --- chart lint ---")
  fails := 0
  checked := 0
  one :: proc(def: ^Behaviour_Def, checked: ^int, fails: ^int) {
    doc, ok := bhv_from_builtin(def)
    if !ok {
      fmt.eprintfln("  FAIL: '%s' would not build", def.name)
      fails^ += 1
      return
    }
    defer behaviour_doc_free(&doc)
    checked^ += 1
    for p in script_lint(&doc) {
      if p.level == .Note {
        continue
      }
      fmt.eprintfln("  FAIL: %s node #%d: %s", def.name, u32(p.node), p.text)
      fails^ += 1
    }
  }
  for &def in SEED_BEHAVIOURS {
    one(&def, &checked, &fails)
  }
  for &def in TEST_BEHAVIOURS {
    one(&def, &checked, &fails)
  }
  if fails == 0 {
    fmt.printfln("  PASS: all %d shipped behaviours lint clean (the seeded defaults and the verification set)", checked)
  } else {
    fmt.eprintfln("  %d lint problem(s) in the shipped behaviours", fails)
  }
}

// --- show -------------------------------------------------------------------------------------------

// script show <name> -> build the behaviour and print the blocks it produces, WITHOUT running it.
// Rendered from the built data rather than from any source text, so what you read here is exactly
// what the walker will step through.
script_cmd_show :: proc(session: ^Session, args: []string) {
  if len(args) == 0 {
    fmt.eprintln("usage: script show <name>   ('script list' shows what's available)")
    return
  }
  doc, ok := bhv_open(args[0])
  if !ok {
    fmt.eprintfln("script show: no behaviour named '%s'. 'script list' shows what's available.", args[0])
    return
  }
  defer behaviour_doc_free(&doc)
  script_show_rules(session, &doc, bhv_exists(doc.name) ? "saved" : "verification")
}


script_cmd_list :: proc(session: ^Session) {
  saved := bhv_list_names()
  if len(saved) == 0 {
    fmt.printfln("behaviours: (none in %s)", bhv_dir_path())
    fmt.println("  'script reseed' writes the defaults (auto, hunt, sweep) back.")
  } else {
    fmt.printfln("behaviours (%s):", bhv_dir_path())
    for n in saved {
      // A file that will not OPEN is named as such rather than shown with a blank description, which
      // would read as "no desc" and not as "this cannot run". The reason is left to `script lint <name>`,
      // where you have asked about that one file - see the quiet flag on bhv_open.
      desc := fmt.tprintf("(will not load - 'script lint %s' says why)", n)
      if doc, ok := bhv_open(n, quiet = true); ok {
        desc = strings.clone(doc.desc, context.temp_allocator)
        behaviour_doc_free(&doc)
      }
      fmt.printfln("  %-22s %s", n, desc)
    }
  }
  // Named, not listed. They are runnable by name and `script selftest` exercises them; they are
  // fixtures rather than behaviours, which is the one reason anything is still resolved by name.
  fmt.printfln("  (+%d verification behaviours, hidden - 'script selftest' runs them; 'script show t_vars' names one)", len(TEST_BEHAVIOURS))
  fmt.println("  'script run <name>' to start, 'script show <name>' to see its rules.")
  fmt.println("  'script nocollision <name>' drops the reach check for one behaviour (dungeons with fake floor props).")
  fmt.println("  Every behaviour is a FILE. Delete one of the defaults and 'script reseed' (or a restart) writes it back.")
}

// Turn the proactive collision gate off for one saved behaviour - the typable twin of the tick-box in
// the editor's options tab, following the browser's rule that every action in it is a command you
// could have typed.
//
// It is a per-CHART setting and not a global for a reason worth keeping in view: the gate is right
// nearly everywhere, and a global would silently stay off after you left the map that needed it.
@(private = "file")
script_cmd_ignore_collision :: proc(args: []string) {
  if len(args) == 0 {
    fmt.eprintln("usage: script nocollision <name> [on|off]   (no on/off toggles it)")
    fmt.eprintln("  drops the reach check from picking, approaching and holding, for that chart only.")
    return
  }
  name := args[0]
  if !bhv_exists(name) {
    if behaviour_def(name) != nil {
      fmt.eprintfln("script nocollision: '%s' is an Odin behaviour - 'script export %s' first to get an editable copy.", name, name)
      return
    }
    fmt.eprintfln("script nocollision: no saved behaviour named '%s'. 'script list' shows what's available.", name)
    return
  }
  doc, ok := bhv_open(name)
  if !ok {
    return // bhv_load already reported why
  }
  defer behaviour_doc_free(&doc)
  want := !doc.ignore_collision
  if len(args) >= 2 {
    switch args[1] {
    case "on", "yes", "1":
      want = true
    case "off", "no", "0":
      want = false
    case:
      fmt.eprintfln("script nocollision: expected 'on' or 'off', got '%s'.", args[1])
      return
    }
  }
  if want == doc.ignore_collision {
    fmt.printfln("script: '%s' already %s collision.", name, want ? "ignores" : "checks")
    return
  }
  doc.ignore_collision = want
  if !bhv_save(&doc) {
    return
  }
  if want {
    fmt.printfln("script: '%s' now IGNORES collision - it will pick and walk at monsters behind real walls too.", name)
  } else {
    fmt.printfln("script: '%s' now checks collision again (the normal behaviour).", name)
  }
}

// --- file commands ------------------------------------------------------------------------------
//
// There is deliberately no `script load`: `show` and `run` take a saved name directly (bhv_open resolves
// a file before a built-in), so a separate verb would only be a second way to say the same thing.

// Write ANY behaviour out as an editable file. Two jobs, one command, because they are the same
// operation: exporting a built-in is how it becomes editable, and exporting a saved chart under a new
// name is how you duplicate it. Goes through bhv_open, so the source may be either kind.
script_cmd_export :: proc(args: []string) {
  if len(args) == 0 {
    fmt.eprintln("usage: script export <name> [as <newname>]   ('script list' shows what's available)")
    return
  }
  src := args[0]
  out := src
  if len(args) >= 3 && args[1] == "as" {
    out = args[2]
  } else if len(args) >= 2 && args[1] != "as" {
    out = args[1]
  }
  doc, ok := bhv_open(src)
  if !ok {
    fmt.eprintfln("script export: no behaviour named '%s'. 'script list' shows what's available.", src)
    return
  }
  defer behaviour_doc_free(&doc)
  if out == src {
    fmt.eprintfln("script export: '%s' would overwrite itself - pass 'as <newname>'.", src)
    return
  }
  delete(doc.name)
  doc.name = strings.clone(out)
  if !bhv_save(&doc) {
    return
  }
  fmt.printfln("script: '%s' -> %s (%d rule(s)).", src, bhv_file_path(out), len(doc.rules))
}

// Snapshot whatever is running to a file - the run already owns a validated rule list, so this is the
// honest way to capture a behaviour you started from Odin and want to keep editing.
script_cmd_save :: proc(session: ^Session, args: []string) {
  run := &session.script
  if !run.active {
    fmt.eprintln("script save: nothing running - 'script run <name>' first, or 'script export <builtin>'.")
    return
  }
  name := len(args) > 0 ? args[0] : run.name
  if name == "" {
    fmt.eprintln("usage: script save <name>")
    return
  }
  doc := Behaviour_Doc {
    name  = strings.clone(name),
    route = strings.clone(run.route),
  }
  defer delete(doc.name)
  defer delete(doc.route)
  doc.rules = run.rules // BORROWED for the write only; never freed through doc (the run still owns it).
  if !bhv_save(&doc) {
    return
  }
  fmt.printfln("script: saved '%s' -> %s (%d rule(s)).", name, bhv_file_path(name), len(run.rules))
}

script_cmd_delete :: proc(args: []string) {
  if len(args) == 0 {
    fmt.eprintln("usage: script delete <name>")
    return
  }
  if !bhv_exists(args[0]) {
    fmt.eprintfln("script delete: no saved behaviour named '%s'.", args[0])
    return
  }
  path := bhv_file_path(args[0])
  if err := os.remove(path); err != nil {
    fmt.eprintfln("script delete: could not remove %s (%v)", path, err)
    return
  }
  fmt.printfln("script: deleted '%s'.", args[0])
  if behaviour_def(args[0]) != nil {
    fmt.printfln("  the Odin behaviour '%s' is visible again.", args[0])
  }
}

script_cmd_rename :: proc(args: []string) {
  if len(args) < 2 {
    fmt.eprintln("usage: script rename <old> <new>")
    return
  }
  old_name, new_name := args[0], args[1]
  if !bhv_exists(old_name) {
    fmt.eprintfln("script rename: no saved behaviour named '%s'.", old_name)
    return
  }
  if !bhv_name_ok(new_name) {
    fmt.eprintfln("script rename: '%s' is not a usable name - %s.", new_name, BHV_NAME_RULE)
    return
  }
  if bhv_exists(new_name) {
    fmt.eprintfln("script rename: '%s' already exists - delete it first.", new_name)
    return
  }
  if err := os.rename(bhv_file_path(old_name), bhv_file_path(new_name)); err != nil {
    fmt.eprintfln("script rename: failed (%v)", err)
    return
  }
  fmt.printfln("script: renamed '%s' -> '%s'.", old_name, new_name)
}

// script step        -> freeze the walker and execute exactly ONE instruction
// script step off    -> hand the program back to the watcher tick
//
// Runs the instruction here on the REPL thread (we already hold exec_mutex, the same lock the
// watcher takes), which is what makes single-stepping meaningful: with stepping on, the watcher
// still senses and still services interrupts, but it will not advance the program underneath you.
// The console half of the trace strip. Reads the ring rather than the run, so it still answers after a
// run has ended - which is the whole reason the ring is session-scoped.
@(private = "file")
script_cmd_trace :: proc(session: ^Session, args: []string) {
  limit := 40
  if len(args) >= 1 {
    switch args[0] {
    case "clear", "wipe":
      // The ring also clears itself at script_begin, so this is for "I have read that, give me a clean
      // slate" rather than for correctness. Both doors: the editor's strip enqueues this command.
      n := min(session.script_trace.written, SCRIPT_TRACE_ROWS)
      session.script_trace = {}
      fmt.printfln("script trace: cleared (%d row(s)).", n)
      return
    case "all":
      limit = 0
    case:
      if n, ok := strconv.parse_int(args[0]); ok && n > 0 {
        limit = n
      }
    }
  }
  rows := script_trace_recent(&session.script_trace, limit)
  if len(rows) == 0 {
    fmt.println("script trace: nothing recorded yet - 'script run <name>' first.")
    return
  }
  total := min(session.script_trace.written, SCRIPT_TRACE_ROWS)
  fmt.printfln("last %d of %d trace row(s), oldest first:", len(rows), total)
  // Relative to the FIRST row shown, not wall-clock: what you want to read off a trace is how long the
  // chart sat on a step, and a run that started two hours ago makes absolute stamps unreadable.
  base := rows[0].at
  for &r in rows {
    tag := ""
    switch r.level {
    case .Step:
    case .Note:
      tag = "note "
    case .Warn:
      tag = "WARN "
    case .Error:
      tag = "ERROR "
    }
    // Padded as a STRING, not with a numeric width: `%-4d` fills with '0' here, so node 1 printed as
    // "n1000" and every trace row named a node that does not exist.
    node := r.node == 0 ? "     " : fmt.tprintf("%-5s", fmt.tprintf("n%d", u32(r.node)))
    // The elapsed column needs the space flag for the same reason - '%8.3f' printed 1.5s as "0001.500".
    fmt.printfln("  % 8.3fs  %s  %s%s", f64(r.at - base) / 1e9, node, tag, script_trace_text(&r))
  }
}


// `script run <name>` - open the behaviour and hand its rules to the runtime.
//
// Notice how little is left. This used to parse four modifiers (`once`, `loop`, `step`, `from <node>`)
// and apply five refusals before starting, every one of them a question only a graph could raise: which
// node do we begin at, does the file even have a start node, is this document actually a set of
// watchers with no main program, is a sub-chart it calls missing a block. A rule list answers none of
// them because it asks none of them - it always loops, it has no position to start from, and every rule
// IS a watcher. What survives is the one gate that was never about the graph: are the blocks usable.
script_cmd_run :: proc(session: ^Session, args: []string) {
  if session.script.active {
    fmt.eprintln("script: already running - 'script stop' first.")
    return
  }
  if len(args) == 0 {
    fmt.eprintln("usage: script run <name>   ('script list' shows what's available)")
    return
  }
  name := args[0]
  // A saved file wins over an Odin behaviour of the same name; an Odin one is rebuilt FRESH here, so
  // editing behaviours.odin and re-running picks the change up with no reload step.
  doc, ok := bhv_open(name)
  if !ok {
    fmt.eprintfln("script run: no behaviour named '%s'. 'script list' shows what's available.", name)
    return
  }
  script_cmd_run_rules(session, &doc) // TAKES OWNERSHIP of doc, including on every refusal
}
