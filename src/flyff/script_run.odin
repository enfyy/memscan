package flyff

import "core:fmt"
import "core:os"
import "core:slice"
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
    // PAUSED is the transport's stop button: nothing at all runs, not even interrupt evaluation, so the
    // machine you come back to is exactly the one you left. STEPPING is the debugger and is weaker on
    // purpose - it still services interrupts, so an `on ... -> stop` can always break you out of a
    // stalled step. Once an interrupt HAS fired, its region runs to completion even while stepping;
    // otherwise that escape hatch would need you to hand-step your own kill switch.
    if !run.paused {
      script_interrupts(ctx)
      if !run.stepping || run.irq_depth > 0 {
        script_walk(ctx)
      }
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
}

// Tear down whatever the run left in flight. Called from st_script's Exit, so it runs on every exit
// path without any of them having to remember.
script_teardown :: proc(ctx: ^Behaviour_Context) {
  script_exit_current(ctx)
  ctx.session.script.active = false
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
  // Already inside a region: evaluate nothing. Not even the latches - a condition that becomes true
  // while the region runs is a real edge that has not been serviced yet, and it should fire once the
  // region returns rather than be quietly swallowed here.
  if run.irq_depth > 0 {
    return
  }
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
    fmt.printf("\n[script] interrupt: %s\n", w.src)
    fmt.print("memscan> ")
    if w.entry < 0 {
      return // nothing to run (an unimplemented block); the edge still counts as serviced
    }
    // Suspend the main program and jump into this watcher's region. The body is a normal part of the
    // program from here on: it polls across ticks and its exit runs, so an interrupt can walk somewhere
    // and actually arrive. A body that never finishes freezes the main program until `script stop` -
    // which is the same deal as any other blocking step, and visible in `script` as the current step.
    run.irq_save = Irq_Frame {
      pc      = run.pc,
      entered = run.entered,
      nloop   = run.nloop,
      loops   = run.loops,
    }
    run.irq_depth = 1
    run.nloop = 0 // the region gets its own loop stack; the main program's is in irq_save
    script_goto(run, w.entry)
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

// Where control goes once <step> is done. A step with no explicit edge falls through to the next array
// slot - which is what builder.odin emits, since it writes steps in execution order. A node placed on a
// canvas has no "next slot" to fall into, so it names its successor and that wins.
script_next_pc :: proc(run: ^Script_Run, step: ^Script_Step) -> int {
  return step.goto_id != 0 ? step.jump : run.pc + 1
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
  script_goto(run, script_next_pc(run, step))
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
    // The main program ends at main_len, not at the end of the array: everything past that point is
    // interrupt-region code, which is only reachable by an interrupt firing.
    off_end := run.pc < 0 || run.pc >= len(run.steps) || (run.irq_depth == 0 && run.pc >= run.main_len)
    if off_end {
      if run.irq_depth > 0 {
        script_irq_return(run) // a region that ran off its end - resume as if it had returned
        continue
      }
      if !script_program_end(ctx) {
        return
      }
      continue
    }
    step := &run.steps[run.pc]
    // Every op below that reaches its end in ONE visit counts as an instruction retired; .Action and
    // .Wait_For do it themselves, because they can yield and be revisited many times before they finish.
    #partial switch step.op {
    case .On, .If, .Else, .Repeat, .While, .End, .Goto, .Branch, .Return:
      run.steps_done += 1
    }
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
        run.steps_done += 1
        script_goto(run, script_next_pc(run, step))
        continue
      }
      return // yield

    // --- graph ops (the node editor's control flow) ---

    case .Goto:
      script_note_line(run, step.src)
      script_goto(run, step.jump)

    case .Branch:
      // Armed on the FIRST visit only, unlike .If which re-arms every time. A branch is how a graph
      // draws a loop exit, so control comes back to it once per iteration - re-arming there would reset
      // `elapsed`/`kills` baselines every pass and the exit could never be reached. This is the same
      // rule .While follows for its condition, for the same reason. (.If keeps re-arming: it is a
      // point-in-time test that control passes through once.)
      if !step.ev_state.armed {
        script_arm_event(ctx, step.cond, &step.ev_state)
      }
      script_note_line(run, step.src)
      script_goto(run, script_event_fired(ctx, step.cond, &step.ev_state) ? step.jump : step.jump_else)

    case .Return:
      if run.irq_depth == 0 {
        // A `return` reached in the main program is simply the end of it - a graph's terminator.
        if !script_program_end(ctx) {
          return
        }
        continue
      }
      script_irq_return(run)
    }
  }
}

// Resume the main program where the interrupt suspended it. pc is restored DIRECTLY rather than through
// script_goto because `entered` must come back too: the suspended step may have been mid-flight (a walk
// that is still walking), and re-entering it would re-issue its start.
script_irq_return :: proc(run: ^Script_Run) {
  run.pc = run.irq_save.pc
  run.entered = run.irq_save.entered
  run.nloop = run.irq_save.nloop
  run.loops = run.irq_save.loops
  run.irq_depth = 0
}
// The pc ran off the end. Returns true if the walker should keep going (the program looped), false
// if the run is over. There is no sub-script return path any more: sub-scripts were a stand-in for
// procedures, and behaviours are Odin now, so factoring is a proc call at BUILD time and the
// runtime only ever sees one flat program.
script_program_end :: proc(ctx: ^Behaviour_Context) -> bool {
  run := &ctx.session.script
  if run.mode == .Loop {
    script_goto(run, run.entry_pc) // back to the START NODE, not to index 0 - a graph may begin anywhere
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
  name := run.name
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
//
// <entry> is the node to start at, BY IDENTITY - 0 means "the first step", which is what a program
// built by builder.odin wants (it emits in execution order). A saved graph names its start node
// instead, because on a canvas the topmost array slot is not necessarily where control begins.
script_begin :: proc(session: ^Session, name: string, steps: [dynamic]Script_Step, mode: Script_Mode, entry: Node_Id = 0) {
  script_run_free(&session.script)
  run := &session.script
  run.steps = steps
  // The main program is everything the caller handed us; interrupt regions are appended AFTER this
  // mark, so the walker knows where to stop even though the array keeps going.
  run.main_len = len(run.steps)
  run.watchers = make([dynamic]Script_Watcher)
  script_build_irq_regions(run)
  // Identity -> position, once, here, AFTER the regions exist so their ids are in the map too.
  // Everything downstream (the walker) reads the derived jump index; nothing downstream knows ids
  // exist. Re-run this after any structural edit.
  if ok, dangling := script_resolve_ids(run.steps[:]); !ok {
    fmt.eprintfln("script: '%s' has an edge pointing at node %d, which does not exist - not started.", name, u32(dangling))
    script_run_free(run)
    return
  }
  start := 0
  if entry != 0 {
    start = -1
    for s, i in run.steps {
      if s.id == entry {
        start = i
        break
      }
    }
    if start < 0 {
      fmt.eprintfln("script: '%s' starts at node %d, which does not exist - not started.", name, u32(entry))
      script_run_free(run)
      return
    }
  }
  run.name = strings.clone(name)
  run.mode = mode
  run.active = true
  run.pc = start
  run.entry_pc = start // where a Loop-mode wrap and `script reset` go back to
  run.entered = false
  run.paused = false
  run.irq_depth = 0
  run.started_at = time.now()._nsec
  run.step_at = run.started_at

  ctx := Behaviour_Context {
    session = session,
    now     = run.started_at,
    board   = &session.bh_board,
  }
  for &w in run.watchers {
    script_arm_event(&ctx, w.cond, &w.ev_state)
  }
  engine.ensure_hotkey_thread(&session.eng) // the walker only advances on the watcher tick
  behaviour_goto(session, .Script)
}

// Hoist every `on <event> -> <action>` out of the instruction stream and give it a REGION: a copy of its
// body appended past main_len, terminated by .Return. Position in the program therefore has no effect on
// when a watcher arms, and - the point of the region - the body is ordinary program text, so it polls
// across ticks and its exit runs like any other step.
//
// A single-action `on` produces a two-step region. That is the same machinery a multi-step interrupt
// CHART will use; it just supplies a longer body.
@(private = "file")
script_build_irq_regions :: proc(run: ^Script_Run) {
  next_id := Node_Id(0)
  for s in run.steps {
    next_id = max(next_id, s.id)
  }
  for i in 0 ..< run.main_len {
    if run.steps[i].op != .On {
      continue
    }
    if len(run.watchers) >= SCRIPT_MAX_WATCHERS {
      fmt.eprintfln("script: more than %d 'on' watchers - the rest are ignored.", SCRIPT_MAX_WATCHERS)
      break
    }
    s := run.steps[i]
    w := Script_Watcher {
      cond   = script_event_clone(s.cond),
      action = script_action_clone(s.action),
      src    = strings.clone(s.src),
      entry  = -1,
    }
    if s.action.kind != .None {
      w.entry = len(run.steps)
      next_id += 1
      body := Script_Step {
        id     = next_id,
        op     = .Action,
        action = script_action_clone(s.action),
      }
      body.src = step_label(body)
      append(&run.steps, body)
      next_id += 1
      ret := Script_Step {
        id  = next_id,
        op  = .Return,
        src = strings.clone("return"),
      }
      append(&run.steps, ret)
    }
    append(&run.watchers, w)
  }
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

// --- transport (what a play/pause/reset control drives) --------------------------------------------

script_set_paused :: proc(session: ^Session, on: bool) -> bool {
  run := &session.script
  if !run.active || run.paused == on {
    return false
  }
  run.paused = on
  return true
}

// Rewind to the start node without rebuilding the program. Everything a fresh run would reset gets
// reset - the loop stack, the kill tally, the interrupt latches and their fire counts, the clocks - and
// the in-flight step's exit runs first, so a walk in progress is actually halted rather than left
// steering toward a waypoint the rewound program no longer knows about.
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

  run.irq_depth = 0
  run.irq_save = {}
  run.nloop = 0
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
  for &w in run.watchers {
    w.fires = 0
    script_arm_event(&ctx, w.cond, &w.ev_state)
  }
  // Disarm every per-site baseline. A .Branch arms once and keeps its baseline for the whole run (see
  // the walker), so without this a rewound program would inherit the previous run's clock and take its
  // loop exit immediately.
  for &s in run.steps {
    s.ev_state = {}
  }
  script_goto(run, run.entry_pc)
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
    script_cmd_selftest()
  case "list":
    script_cmd_list(session)
  case "show":
    script_cmd_show(session, args[1:])
  case "run", "start":
    script_cmd_run(session, args[1:])
  case "step":
    script_cmd_step(session, args[1:])
  case "pause":
    if !session.script.active {
      fmt.eprintln("script pause: nothing running.")
    } else if script_set_paused(session, true) {
      fmt.printfln("script: '%s' PAUSED at step %d/%d. 'script resume' to continue.", session.script.name, min(session.script.pc + 1, len(session.script.steps)), session.script.main_len)
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
      fmt.printfln("script: '%s' rewound to the start%s.", session.script.name, session.script.paused ? " (still paused)" : "")
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
    fmt.eprintln("  status | blocks | list | show <name> | run <name> [once|loop] | stop")
    fmt.eprintln("  pause | resume | reset | step [off]")
    fmt.eprintln("  export <builtin> [as] | save <name> | delete <name> | rename <old> <new>")
  }
}

// The `status full` detail section: the machine's state, and every block that is NOT usable right
// now with the reason. Deliberately lists only the gated ones - the point is "what do I still need",
// and `script blocks` is there for the full catalog.
cli_status_behaviour :: proc(session: ^Session) {
  fmt.println("BEHAVIOUR (scripts + the state machine that will replace the hardcoded 'auto'):")
  fmt.printfln("  machine  : %s%s", behaviour_state_name(session.bh_state), session.bh_entered ? "" : "  (not entered yet)")
  fmt.printfln("  script   : %s", script_status_line(session))
  saved := bhv_list_names()
  fmt.printfln(
    "  behaviours: %d in Odin (flyff/behaviours.odin) + %d saved in %s - 'script list'",
    len(BEHAVIOURS), len(saved), bhv_dir_path(),
  )
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
  if run := &session.script; run.active {
    what := run.paused ? "PAUSED" : (run.irq_depth > 0 ? "INTERRUPT" : "RUNNING")
    state = fmt.tprintf("%s '%s' step %d/%d", what, run.name, min(run.pc + 1, run.main_len), run.main_len)
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
  fmt.printfln("script: '%s' %s (%s)%s", run.name, what, run.mode == .Loop ? "loop" : "once", run.stepping ? ", stepping" : "")
  fmt.printfln("  step %d/%d, %d executed, %s elapsed", min(run.pc + 1, run.main_len), run.main_len, run.steps_done, fmt_elapsed(now - run.started_at))
  if run.last_line != "" {
    fmt.printfln("  current: %s", run.last_line)
  }
  if run.irq_depth > 0 {
    fmt.printfln("  ^ inside an INTERRUPT; the main program is suspended at step %d and resumes when it returns.", run.irq_save.pc + 1)
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
  fmt.println("STRUCTURE (nesting - what Odin authoring emits):")
  fmt.println("           if <event> / else / end,  repeat <n> / end,  while <event> / end,")
  fmt.println("           wait_for <event>,  <action> until <event>,  on <event> -> <action>")
  fmt.println("GRAPH (explicit edges - what the node editor emits):")
  fmt.println("           goto #<node>,  branch <event> ? #<node> : #<node>,  return")
  fmt.println("           an edge may point BACKWARDS - that is how a loop is drawn rather than declared.")
  fmt.println("           'on' is an INTERRUPT: checked before every step, first match wins, and its body")
  fmt.println("           is a full region (it can walk and wait, then control resumes where it was).")
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
  script_selftest_roundtrip()
}

// Prove the file format is lossless: build every Odin behaviour, serialize it, parse it back, and
// compare the RENDERED programs. Rendering both sides rather than memcmp-ing the structs is the point -
// it compares exactly what the walker will execute (ops, edges, block kinds, every argument) while
// ignoring the things that legitimately differ (heap pointers, per-run scratch).
@(private = "file")
script_selftest_roundtrip :: proc() {
  fmt.println("  --- save/load round-trip ---")
  fails := 0
  for &d in BEHAVIOURS {
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

    if back.mode != doc.mode || back.entry != doc.entry || len(back.steps) != len(doc.steps) {
      fmt.eprintfln(
        "  FAIL: '%s' header/shape differs (mode %v->%v, entry %d->%d, %d->%d steps)",
        d.name, doc.mode, back.mode, u32(doc.entry), u32(back.entry), len(doc.steps), len(back.steps),
      )
      fails += 1
      continue
    }
    lhs := script_render(doc.steps[:], doc.mode)
    rhs := script_render(back.steps[:], back.mode)
    if lhs != rhs {
      fmt.eprintfln("  FAIL: '%s' changed across a save/load:", d.name)
      fmt.eprintfln("--- built ---\n%s--- reloaded ---\n%s", lhs, rhs)
      fails += 1
      continue
    }
    // Edges must survive by IDENTITY, not just render the same.
    for s, i in doc.steps {
      if back.steps[i].id != s.id || back.steps[i].goto_id != s.goto_id {
        fmt.eprintfln("  FAIL: '%s' step %d: id/goto %d/%d -> %d/%d", d.name, i, u32(s.id), u32(s.goto_id), u32(back.steps[i].id), u32(back.steps[i].goto_id))
        fails += 1
        break
      }
    }
  }
  if fails == 0 {
    fmt.printfln("  PASS: all %d behaviours survive serialize -> parse -> render unchanged", len(BEHAVIOURS))
  } else {
    fmt.eprintfln("  %d behaviour(s) did not round-trip", fails)
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
  doc, ok := bhv_open(args[0])
  if !ok {
    fmt.eprintfln("script show: no behaviour named '%s'. 'script list' shows what's available.", args[0])
    return
  }
  defer behaviour_doc_free(&doc)
  src := bhv_exists(doc.name) ? "saved" : "Odin"
  fmt.printfln("=== %s (%s, %s, %d steps) ===", doc.name, src, doc.mode == .Loop ? "loop" : "once", len(doc.steps))
  fmt.print(script_render(doc.steps[:], doc.mode))
  if problems := script_check_avail(session, doc.steps[:]); len(problems) > 0 {
    fmt.printfln("%d block(s) not usable right now:", len(problems))
    for p in problems {
      fmt.printfln("  %s", p)
    }
  }
}


script_cmd_list :: proc(session: ^Session) {
  saved := bhv_list_names()
  fmt.println("behaviours:")
  for d in BEHAVIOURS {
    mark := d.test ? "T " : "  " // T = runs detached, the verification set
    shadow := ""
    if slice.contains(saved, d.name) {
      shadow = "   <- shadowed by the saved copy of the same name"
    }
    fmt.printfln("  %s%-14s %s%s", mark, d.name, d.blurb, shadow)
  }
  fmt.printfln("  ^ defined in Odin (flyff/behaviours.odin). T = runs with nothing attached.")
  if len(saved) == 0 {
    fmt.printfln("saved behaviours: (none yet in %s)", bhv_dir_path())
  } else {
    fmt.printfln("saved behaviours (%s):", bhv_dir_path())
    for n in saved {
      fmt.printfln("    %s", n)
    }
  }
  fmt.println("  'script run <name>' to start, 'script show <name>' to see the blocks it builds.")
  fmt.println("  A saved behaviour WINS over an Odin one of the same name - delete it to get the original back.")
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
  if out == src && !bhv_exists(src) {
    // Exporting a built-in onto its own name is the "make this editable" case, and it is worth saying
    // out loud that the file now wins.
    fmt.println("script: the copy has the same name as the Odin behaviour, so it will SHADOW it ('script delete' undoes that).")
  } else if out == src {
    fmt.eprintfln("script export: '%s' would overwrite itself - pass 'as <newname>'.", src)
    return
  }
  delete(doc.name)
  doc.name = strings.clone(out)
  if !bhv_save(&doc) {
    return
  }
  fmt.printfln("script: '%s' -> %s (%d steps).", src, bhv_file_path(out), len(doc.steps))
}

// Snapshot whatever is running to a file - the run already owns a resolved, validated program, so this
// is the honest way to capture a behaviour you started from Odin and want to keep editing.
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
    mode  = run.mode,
    entry = run.entry_pc >= 0 && run.entry_pc < len(run.steps) ? run.steps[run.entry_pc].id : 0,
  }
  defer delete(doc.name)
  doc.steps = run.steps // BORROWED for the write only; never freed through doc (the run still owns it).
  if !bhv_save(&doc) {
    return
  }
  fmt.printfln("script: saved '%s' -> %s (%d steps).", name, bhv_file_path(name), len(run.steps))
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
  // A saved file wins over an Odin behaviour of the same name; an Odin one is rebuilt FRESH here, so
  // editing a Dungeon_Cfg and re-running picks the change up with no reload step.
  doc, ok := bhv_open(name)
  if !ok {
    fmt.eprintfln("script run: no behaviour named '%s'. 'script list' shows what's available.", name)
    return
  }
  label := doc.name
  if len(doc.steps) == 0 {
    fmt.eprintln("script run: nothing to run (the behaviour has no blocks).")
    behaviour_doc_free(&doc)
    return
  }
  // Refuse UP FRONT if any block it uses isn't usable, rather than dying mid-run.
  if problems := script_check_avail(session, doc.steps[:]); len(problems) > 0 {
    fmt.eprintfln("script run: '%s' uses %d block(s) that aren't available yet - not started:", label, len(problems))
    for p in problems {
      fmt.eprintfln("  %s", p)
    }
    fmt.eprintln("  'script blocks' shows the whole catalog and what each missing one needs.")
    behaviour_doc_free(&doc)
    return
  }
  mode := doc.mode
  if mode_override >= 0 {
    mode = Script_Mode(mode_override)
  }
  n := len(doc.steps)
  // script_begin takes ownership of the steps; the doc's own name is all that is left to release.
  script_begin(session, label, doc.steps, mode, doc.entry)
  delete(doc.name)
  fmt.printfln("script: '%s' started (%d steps, %s).", label, n, mode == .Loop ? "loop" : "once")
}
