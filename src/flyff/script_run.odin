package flyff

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "../engine"

// ===========================================================================
// Behaviour script runtime - the pc walker, the interrupt pass, and the REPL surface.
// The language itself (types, parser, unparser) is in script.odin; the catalog is in
// script_blocks.odin.
// ===========================================================================

// --- the script state ---------------------------------------------------------------------------

// "A script is running." Its Update walks the program counter; each step's start/poll/exit are that
// step's Enter/Update/Exit (a single state proc cannot provide per-step phases - a state returning
// itself is not a transition - so the walker provides them).
//
// The Exit below is the whole reason this is a state rather than a flag: leaving the script for ANY
// reason - the program ended, `script stop`, an interrupt, a detach - tears down the action that was
// in flight. That is what makes `script stop` mid-walk actually halt the character instead of
// letting it drift to the waypoint.
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
    script_interrupts(ctx)
    // In stepping mode the watcher still senses and still services interrupts (so an `on ... -> stop`
    // can always break you out of a stalled step), but it does not advance the program - `script step`
    // does that one instruction at a time.
    if !run.stepping {
      script_walk(ctx)
    }
    if !run.active {
      return st_idle
    }
  case .Exit:
    script_teardown(ctx)
  }
  return st_script
}

// Tear down whatever the run left in flight. Called from st_script's Exit, so it runs on every exit
// path without any of them having to remember.
script_teardown :: proc(ctx: ^Behaviour_Context) {
  run := &ctx.session.script
  if run.active && run.entered && run.pc >= 0 && run.pc < len(run.steps) {
    step := &run.steps[run.pc]
    if step.op == .Action {
      if def := action_def(step.action.kind); def != nil && def.exit != nil {
        def.exit(ctx, step)
      }
    }
  }
  run.entered = false
  run.active = false
}

// --- interrupts ------------------------------------------------------------------------------------

// Evaluate the `on <event> -> <action>` watchers, in declaration order, before the current step.
// First match wins - a tick never fires two interrupts, so a script author can reason about priority
// as "the order I wrote them in".
//
// EDGE-TRIGGERED, not level-triggered: a watcher fires on the false->true transition and then latches
// until its condition goes false again. An interrupt is about something HAPPENING - a player arriving,
// the bag filling - not about a condition being continuously true. Without the latch, `on player_near
// 30 -> alert` would re-fire every 20ms for as long as anyone stood near you. (`until` / `if` /
// `while` / `wait_for` stay level-triggered: those ask "is it true now", which is the right question
// for a completion or branch condition.)
script_interrupts :: proc(ctx: ^Behaviour_Context) {
  run := &ctx.session.script
  for &w in run.watchers {
    // Through script_event_fired, not def.fired, so `on not <event> -> ...` negates like everywhere else.
    if !script_event_fired(ctx, w.cond, &w.ev_state) {
      w.ev_state.latched = false // condition went away - re-arm for the next edge
      continue
    }
    if w.ev_state.latched {
      continue // still true from a previous fire; not a new edge
    }
    w.ev_state.latched = true
    w.fires += 1
    // A watcher body is one-shot: run its start and take the verdict. Actions that need polling are
    // not meaningful as an interrupt body yet - that grows here when `call` lands (Stage 2), which
    // needs to redirect the pc rather than run to completion inline.
    if adef := action_def(w.action.kind); adef != nil && adef.start != nil {
      tmp := Script_Step {
        op      = .Action,
        action  = w.action,
        scratch = Step_Scratch{started_at = ctx.now},
      }
      adef.start(ctx, &tmp)
    }
    fmt.printf("\n[script] interrupt: %s\n", w.src)
    fmt.print("memscan> ")
    return
  }
}

// --- the walker --------------------------------------------------------------------------------------

// Move to <pc> and mark the step as not-yet-entered, so the next visit runs its enter work (arm
// events, reset scratch, call start). Every pc change goes through here - that is the single
// mechanism that guarantees a step's start() runs exactly once per visit.
script_goto :: proc(run: ^Script_Run, pc: int) {
  run.pc = pc
  run.entered = false
}

// Advance past the current step, running its exit first.
script_advance :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) {
  run := &ctx.session.script
  if step.op == .Action {
    if def := action_def(step.action.kind); def != nil && def.exit != nil {
      def.exit(ctx, step)
    }
  }
  run.steps_done += 1
  script_goto(run, run.pc + 1)
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

// Run up to SCRIPT_MAX_STEPS_PER_TICK instructions. The budget matters: a program that is all
// if/var/end would otherwise spin the watcher tick forever without ever yielding.
script_walk :: proc(ctx: ^Behaviour_Context) {
  script_walk_n(ctx, SCRIPT_MAX_STEPS_PER_TICK)
}

// The walker proper, bounded to <budget> instructions. `script step` calls it with 1.
script_walk_n :: proc(ctx: ^Behaviour_Context, budget: int) {
  run := &ctx.session.script
  for _ in 0 ..< budget {
    if !run.active {
      return
    }
    if run.stop_requested {
      script_finish(ctx, "stopped")
      return
    }
    if run.pc < 0 || run.pc >= len(run.steps) {
      if !script_program_end(ctx) {
        return
      }
      continue
    }
    step := &run.steps[run.pc]
    switch step.op {
    case .On:
      script_goto(run, run.pc + 1) // hoisted at start; never executed in sequence

    case .Action:
      if !run.entered {
        run.entered = true
        run.step_at = ctx.now
        step.scratch = Step_Scratch {
          started_at = ctx.now,
        }
        if step.has_until {
          script_arm_event(ctx, step.until, &step.ev_state)
        }
        script_note_line(run, step.src)
        def := action_def(step.action.kind)
        if def == nil || def.start == nil {
          script_fail(ctx, step, "block has no implementation")
          return
        }
        switch def.start(ctx, step) {
        case .Failed:
          script_fail(ctx, step, "failed to start")
          return
        case .Done:
          script_advance(ctx, step)
        case .Running:
          if def.poll == nil {
            script_advance(ctx, step) // no poll => start's verdict was final
          } else {
            return // yield; poll it next tick
          }
        }
        continue
      }
      // Already started: the `until` event can end it early, otherwise poll it.
      if step.has_until && script_event_fired(ctx, step.until, &step.ev_state) {
        script_advance(ctx, step)
        continue
      }
      def := action_def(step.action.kind)
      if def == nil || def.poll == nil {
        script_advance(ctx, step)
        continue
      }
      switch def.poll(ctx, step) {
      case .Done:
        script_advance(ctx, step)
      case .Failed:
        script_fail(ctx, step, "failed")
        return
      case .Running:
        return // yield
      }

    case .If:
      script_arm_event(ctx, step.cond, &step.ev_state)
      script_note_line(run, step.src)
      if script_event_fired(ctx, step.cond, &step.ev_state) {
        script_goto(run, run.pc + 1)
      } else {
        script_goto(run, step.jump)
      }

    case .Else:
      script_goto(run, step.jump) // reached only by falling out of the true branch

    case .Repeat, .While:
      head_is_open := run.nloop > 0 && run.loops[run.nloop - 1].head == run.pc
      if !head_is_open {
        if run.nloop >= SCRIPT_MAX_NEST {
          script_fail(ctx, step, "loop nesting too deep")
          return
        }
        run.loops[run.nloop] = Loop_Frame {
          head      = run.pc,
          remaining = step.count,
        }
        run.nloop += 1
        // Arm a while-condition once, when the loop is first entered - not per iteration, so
        // `while <event>` measures from the loop's start rather than resetting its own baseline.
        if step.op == .While {
          script_arm_event(ctx, step.cond, &step.ev_state)
        }
      }
      frame := &run.loops[run.nloop - 1]
      keep := false
      if step.op == .Repeat {
        keep = frame.remaining > 0
        if keep {
          frame.remaining -= 1
        }
      } else {
        keep = script_event_fired(ctx, step.cond, &step.ev_state)
      }
      if keep {
        script_goto(run, run.pc + 1)
      } else {
        run.nloop -= 1
        script_goto(run, step.jump)
      }

    case .End:
      if step.close == .If {
        script_goto(run, run.pc + 1)
      } else {
        script_goto(run, step.jump) // back to the loop head
      }

    case .Wait_For:
      if !run.entered {
        run.entered = true
        run.step_at = ctx.now
        script_arm_event(ctx, step.cond, &step.ev_state)
        script_note_line(run, step.src)
      }
      if script_event_fired(ctx, step.cond, &step.ev_state) {
        script_goto(run, run.pc + 1)
        continue
      }
      return // yield
    }
  }
}
// The pc ran off the end. Returns true if the walker should keep going (the program looped), false
// if the run is over. There is no sub-script return path any more: sub-scripts were a stand-in for
// procedures, and behaviours are Odin now, so factoring is a proc call at BUILD time and the
// runtime only ever sees one flat program.
script_program_end :: proc(ctx: ^Behaviour_Context) -> bool {
  run := &ctx.session.script
  if run.mode == .Loop {
    script_goto(run, 0)
    run.nloop = 0
    return true
  }
  script_finish(ctx, "complete")
  return false
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

script_note_line :: proc(run: ^Script_Run, src: string) {
  delete(run.last_line)
  run.last_line = strings.clone(src)
}

script_fail :: proc(ctx: ^Behaviour_Context, step: ^Script_Step, why: string) {
  fmt.printf("\n[script] step %d (%s) - %s. run stopped.\n", u32(step.id), step.src, why)
  fmt.print("memscan> ")
  script_finish(ctx, "failed")
}

script_finish :: proc(ctx: ^Behaviour_Context, how: string) {
  run := &ctx.session.script
  el := ctx.now - run.started_at
  name := run.name == "" ? "(buffer)" : run.name
  script_teardown(ctx) // runs the in-flight step's exit; also clears active
  fmt.printf("\n[script] %s - '%s' %s after %s (%d steps)\n", how, name, how == "complete" ? "finished" : "ended", fmt_elapsed(el), run.steps_done)
  fmt.print("memscan> ")
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
    if def := action_def(act.kind); def != nil && def.avail != nil {
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
    if def := event_def(ev.kind); def != nil && def.avail != nil {
      if ok, why := def.avail(session); !ok {
        append(out, fmt.tprintf("%s: %s", def.name, why))
      }
    }
  }
  for s in steps {
    check_action(session, s.action, &seen_a, &out)
    check_event(session, s.cond, &seen_e, &out)
    if s.has_until {
      check_event(session, s.until, &seen_e, &out)
    }
  }
  return out
}

// Take ownership of <steps> and begin running. Hoists the `on` watchers out of the instruction
// stream so their position in the file does not affect when they arm.
script_begin :: proc(session: ^Session, name: string, steps: [dynamic]Script_Step, mode: Script_Mode) {
  script_run_free(&session.script)
  run := &session.script
  run.steps = steps
  // Identity -> position, once, here. Everything downstream (the walker) reads the derived jump
  // index; nothing downstream knows ids exist. Re-run this after any structural edit.
  if ok, dangling := script_resolve_ids(run.steps[:]); !ok {
    fmt.eprintfln("script: '%s' has an edge pointing at node %d, which does not exist - not started.", name, u32(dangling))
    script_steps_free(&run.steps)
    return
  }
  run.name = strings.clone(name)
  run.mode = mode
  run.active = true
  run.pc = 0
  run.entered = false
  run.started_at = time.now()._nsec
  run.step_at = run.started_at

  run.watchers = make([dynamic]Script_Watcher)
  ctx := Behaviour_Context {
    session = session,
    now     = run.started_at,
    board   = &session.bh_board,
  }
  for s in run.steps {
    if s.op != .On {
      continue
    }
    if len(run.watchers) >= SCRIPT_MAX_WATCHERS {
      fmt.eprintfln("script: more than %d 'on' watchers - the rest are ignored.", SCRIPT_MAX_WATCHERS)
      break
    }
    w := Script_Watcher {
      cond   = script_event_clone(s.cond),
      action = script_action_clone(s.action),
      src    = strings.clone(s.src),
    }
    script_arm_event(&ctx, w.cond, &w.ev_state)
    append(&run.watchers, w)
  }
  engine.ensure_hotkey_thread(&session.eng) // the walker only advances on the watcher tick
  behaviour_goto(session, .Script)
}

// Watchers outlive the step they were parsed from (they are hoisted), so their strings must be
// their own - the step list is freed independently.
script_event_clone :: proc(ev: Script_Event) -> Script_Event {
  out := ev
  out.strs[0] = strings.clone(ev.strs[0])
  out.strs[1] = strings.clone(ev.strs[1])
  return out
}

script_action_clone :: proc(act: Script_Action) -> Script_Action {
  out := act
  out.strs[0] = strings.clone(act.strs[0])
  out.strs[1] = strings.clone(act.strs[1])
  return out
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
    script_cmd_selftest()
  case "list":
    script_cmd_list(session)
  case "show":
    script_cmd_show(session, args[1:])
  case "run", "start":
    script_cmd_run(session, args[1:])
  case "step":
    script_cmd_step(session, args[1:])
  case "stop":
    if !session.script.active {
      fmt.println("script: nothing running.")
      return
    }
    name := session.script.name == "" ? "(buffer)" : session.script.name
    script_stop(session)
    fmt.printfln("script: '%s' stopped (anything in flight was torn down).", name)
  case:
    fmt.eprintfln("script: unknown subcommand '%s'", args[0])
    fmt.eprintln("  status | blocks | list | show <name> | run <name> [once|loop] | step [off] | stop")
  }
}

// The `status full` detail section: the machine's state, and every block that is NOT usable right
// now with the reason. Deliberately lists only the gated ones - the point is "what do I still need",
// and `script blocks` is there for the full catalog.
cli_status_behaviour :: proc(session: ^Session) {
  fmt.println("BEHAVIOUR (scripts + the state machine that will replace the hardcoded 'auto'):")
  fmt.printfln("  machine  : %s%s", behaviour_state_name(session.bh_state), session.bh_entered ? "" : "  (not entered yet)")
  fmt.printfln("  script   : %s", script_status_line(session))
  fmt.printfln("  behaviours: %d defined in Odin (flyff/behaviours.odin) - 'script list'", len(BEHAVIOURS))
  gated := 0
  for def in ACTIONS {
    if def.avail == nil {
      continue
    }
    if ok, why := def.avail(session); !ok {
      if gated == 0 {
        fmt.println("  blocks not usable right now:")
      }
      fmt.printfln("    [--] %-18s %s", def.name, why)
      gated += 1
    }
  }
  for def in EVENTS {
    if def.avail == nil {
      continue
    }
    if ok, why := def.avail(session); !ok {
      if gated == 0 {
        fmt.println("  blocks not usable right now:")
      }
      fmt.printfln("    [--] %-18s %s", def.name, why)
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
    if def.avail != nil {
      if ok, _ := def.avail(session); !ok {
        gated += 1
      }
    }
  }
  for def in EVENTS {
    if def.avail != nil {
      if ok, _ := def.avail(session); !ok {
        gated += 1
      }
    }
  }
  state := "idle"
  if session.script.active {
    name := session.script.name == "" ? "(buffer)" : session.script.name
    state = fmt.tprintf(
      "RUNNING '%s' step %d/%d",
      name, min(session.script.pc + 1, len(session.script.steps)), len(session.script.steps),
    )
  } else if len(session.script_buf) > 0 {
    state = fmt.tprintf("idle, buffer '%s' (%d lines)", session.script_buf_name, len(session.script_buf))
  }
  sensing := session.bh_sense_on ? ", sensing on" : ""
  return fmt.tprintf("%s%s  |  %d/%d blocks usable ('script blocks')", state, sensing, total - gated, total)
}

script_print_status :: proc(session: ^Session) {
  run := &session.script
  if !run.active {
    fmt.println("script: nothing running.")
    if n := len(session.script_buf); n > 0 {
      fmt.printfln("  authoring buffer: '%s', %d line(s) - 'script show' to review, 'script run' to start.", session.script_buf_name, n)
    } else {
      fmt.println("  no authoring buffer. 'script new <name>' then 'script add <block>', or 'script load <name>'.")
    }
    fmt.println("  'script blocks' lists everything a script can do.")
    return
  }
  now := time.now()._nsec
  name := run.name == "" ? "(buffer)" : run.name
  fmt.printfln("script: '%s' RUNNING (%s)", name, run.mode == .Loop ? "loop" : "once")
  fmt.printfln("  step %d/%d, %d executed, %s elapsed", min(run.pc + 1, len(run.steps)), len(run.steps), run.steps_done, fmt_elapsed(now - run.started_at))
  if run.last_line != "" {
    fmt.printfln("  current: %s", run.last_line)
  }
  if len(run.watchers) > 0 {
    fmt.printfln("  %d interrupt(s) armed (first match wins):", len(run.watchers))
    for w in run.watchers {
      fmt.printfln("    %-40s fired %d time(s)", w.src, w.fires)
    }
  }
  fmt.println("  'script stop' ends it.")
}

script_print_blocks :: proc(session: ^Session) {
  fmt.println("=== behaviour blocks ===")
  fmt.println("ACTIONS (things a script does):")
  for def in ACTIONS {
    mark, why := script_avail_mark(session, def.avail)
    fmt.printfln("  %s %-16s %s%s", mark, script_sig(def.name, def.params), def.blurb, why)
  }
  fmt.println("EVENTS (things a script can wait for / react to):")
  for def in EVENTS {
    mark, why := script_avail_mark(session, def.avail)
    fmt.printfln("  %s %-16s %s%s", mark, script_sig(def.name, def.params), def.blurb, why)
  }
  fmt.println("STRUCTURE: if <event> / else / end,  repeat <n> / end,  while <event> / end,")
  fmt.println("           wait_for <event>,  <action> until <event>,  on <event> -> <action>")
  fmt.println("           '#! loop' as the first line re-runs the script forever; '#! once' is the default.")
  fmt.println("[--] means the block exists but isn't usable yet - the reason says what it needs.")
}

script_avail_mark :: proc(session: ^Session, avail: proc(session: ^Session) -> (ok: bool, why: string)) -> (mark: string, why: string) {
  if avail == nil {
    return "[OK]", ""
  }
  ok, w := avail(session)
  if ok {
    return "[OK]", ""
  }
  return "[--]", fmt.tprintf("   -> %s", w)
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

// Prove that node identity does what it exists for: survive a structural edit.
//
// Without it an edge is an array offset, so inserting a step anywhere silently retargets every jump
// after it. This builds a real nested program, records where each edge lands, inserts a node at the
// FRONT (the worst case - every position shifts), re-resolves, and checks each edge still lands on
// the same NODE. Cheap, exact, and it fails loudly if the resolver ever regresses.
script_cmd_selftest :: proc() {
  fmt.println("=== behaviour data self-test ===")
  b := builder_begin("selftest", .Once)
  bh_test_nesting(b)
  steps, _, _ := builder_end(b)
  defer script_steps_free(&steps)

  if ok, bad := script_resolve_ids(steps[:]); !ok {
    fmt.eprintfln("  FAIL: initial resolve found a dangling edge to node %d", u32(bad))
    return
  }
  // Record, per edge, WHICH NODE it lands on (not which index).
  Edge :: struct {
    from:    Node_Id,
    lands_on: Node_Id,
  }
  before := make([dynamic]Edge, context.temp_allocator)
  for s in steps {
    if s.goto_id == 0 {
      continue
    }
    if s.jump >= 0 && s.jump < len(steps) {
      append(&before, Edge{s.id, steps[s.jump].id})
    } else {
      append(&before, Edge{s.id, 0}) // lands past the end - legitimate for a trailing block
    }
  }
  fmt.printfln("  built %d steps, %d structured edges", len(steps), len(before))

  // The hostile edit: insert at index 0 so every single position moves.
  inserted := Script_Step {
    op  = .Action,
    id  = 9999,
    src = strings.clone("wait 0"),
  }
  inserted.action = Script_Action{kind = .Wait}
  inject_at(&steps, 0, inserted)

  if ok, bad := script_resolve_ids(steps[:]); !ok {
    fmt.eprintfln("  FAIL: resolve after insert found a dangling edge to node %d", u32(bad))
    return
  }
  fails := 0
  for e in before {
    idx := -1
    for s, i in steps {
      if s.id == e.from {
        idx = i
        break
      }
    }
    if idx < 0 {
      fmt.eprintfln("  FAIL: node %d vanished", u32(e.from))
      fails += 1
      continue
    }
    j := steps[idx].jump
    now: Node_Id = 0
    if j >= 0 && j < len(steps) {
      now = steps[j].id
    }
    if now != e.lands_on {
      fmt.eprintfln("  FAIL: node %d used to land on node %d, now lands on %d", u32(e.from), u32(e.lands_on), u32(now))
      fails += 1
    }
  }
  if fails == 0 {
    fmt.printfln("  PASS: all %d edges still land on the same nodes after inserting at the front", len(before))
    fmt.println("  (with positional jumps every one of them would have been off by one)")
  } else {
    fmt.eprintfln("  %d edge(s) broke", fails)
  }
}

@(private = "file")
inject_at :: proc(steps: ^[dynamic]Script_Step, at: int, s: Script_Step) {
  append(steps, Script_Step{})
  for i := len(steps) - 1; i > at; i -= 1 {
    steps[i] = steps[i - 1]
  }
  steps[at] = s
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
  def := behaviour_def(args[0])
  if def == nil {
    fmt.eprintfln("script show: no behaviour named '%s'.", args[0])
    return
  }
  b := builder_begin(def.name, .Once)
  def.build(b)
  steps, mode, berrs := builder_end(b)
  defer script_steps_free(&steps)
  for e in berrs {
    fmt.eprintfln("  authoring problem: %s", e)
  }
  fmt.printfln("=== %s (%s, %d steps) ===", def.name, mode == .Loop ? "loop" : "once", len(steps))
  fmt.print(script_render(steps[:], mode))
  if problems := script_check_avail(session, steps[:]); len(problems) > 0 {
    fmt.printfln("%d block(s) not usable right now:", len(problems))
    for p in problems {
      fmt.printfln("  %s", p)
    }
  }
}


script_cmd_list :: proc(session: ^Session) {
  fmt.println("behaviours (defined in Odin - see flyff/behaviours.odin):")
  for d in BEHAVIOURS {
    mark := "  "
    if d.test {
      mark = "T " // runs detached - the verification set
    }
    fmt.printfln("  %s%-14s %s", mark, d.name, d.blurb)
  }
  fmt.println("  T = runs with nothing attached (verification behaviour).")
  fmt.println("  'script run <name>' to start, 'script show <name>' to see the blocks it builds.")
}

// script step        -> freeze the walker and execute exactly ONE instruction
// script step off    -> hand the program back to the watcher tick
//
// Runs the instruction here on the REPL thread (we already hold exec_mutex, the same lock the
// watcher takes), which is what makes single-stepping meaningful: with stepping on, the watcher
// still senses and still services interrupts, but it will not advance the program underneath you.
script_cmd_step :: proc(session: ^Session, args: []string) {
  run := &session.script
  if !run.active {
    fmt.eprintln("script step: nothing running - 'script run <name>' first.")
    return
  }
  if len(args) >= 1 && (args[0] == "off" || args[0] == "go" || args[0] == "continue") {
    run.stepping = false
    fmt.println("script: stepping off - the run continues on its own.")
    return
  }
  if !run.stepping {
    run.stepping = true
    fmt.println("script: stepping ON (the watcher no longer advances it). 'script step off' resumes.")
  }
  before := run.pc
  ctx := Behaviour_Context {
    session = session,
    now     = time.now()._nsec,
    board   = &session.bh_board,
  }
  script_walk_n(&ctx, 1)
  if !run.active {
    return // the instruction ended the run; script_finish already reported it
  }
  cur := "(end)" // NB: not `where` - that is an Odin keyword (parametric constraint clauses)
  if run.pc >= 0 && run.pc < len(run.steps) {
    cur = run.steps[run.pc].src
  }
  if run.pc == before && run.entered {
    fmt.printfln("  step %d/%d still running: %s", run.pc + 1, len(run.steps), cur)
  } else {
    fmt.printfln("  -> step %d/%d: %s", run.pc + 1, len(run.steps), cur)
  }
}

script_cmd_run :: proc(session: ^Session, args: []string) {
  if session.script.active {
    fmt.eprintln("script: already running - 'script stop' first.")
    return
  }
  name := ""
  mode_override := -1
  for a in args {
    switch a {
    case "once":
      mode_override = int(Script_Mode.Once)
    case "loop":
      mode_override = int(Script_Mode.Loop)
    case:
      if name == "" {
        name = a
      }
    }
  }
  if name == "" {
    fmt.eprintln("usage: script run <name> [once|loop]   ('script list' shows what's available)")
    return
  }
  def := behaviour_def(name)
  if def == nil {
    fmt.eprintfln("script run: no behaviour named '%s'. 'script list' shows what's available.", name)
    return
  }
  // Build it fresh every run: the builder procs read their config at build time, so editing a
  // Dungeon_Cfg and re-running picks the change up without any reload step.
  b := builder_begin(def.name, .Once)
  def.build(b)
  steps, mode, berrs := builder_end(b)
  label := def.name
  if len(berrs) > 0 {
    fmt.eprintfln("script run: '%s' has %d authoring problem(s) - not started:", label, len(berrs))
    for e in berrs {
      fmt.eprintfln("  %s", e)
    }
    script_steps_free(&steps)
    return
  }
  if len(steps) == 0 {
    fmt.eprintln("script run: nothing to run (the behaviour built no blocks).")
    script_steps_free(&steps)
    return
  }
  // Refuse UP FRONT if any block it uses isn't usable, rather than dying mid-run.
  if problems := script_check_avail(session, steps[:]); len(problems) > 0 {
    fmt.eprintfln("script run: '%s' uses %d block(s) that aren't available yet - not started:", label, len(problems))
    for p in problems {
      fmt.eprintfln("  %s", p)
    }
    fmt.eprintln("  'script blocks' shows the whole catalog and what each missing one needs.")
    script_steps_free(&steps)
    return
  }
  if mode_override >= 0 {
    mode = Script_Mode(mode_override)
  }
  script_begin(session, label, steps, mode)
  fmt.printfln("script: '%s' started (%d steps, %s).", label, len(steps), mode == .Loop ? "loop" : "once")
}
