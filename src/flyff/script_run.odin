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
      if !run.stepping || run.watcher_depth > 0 {
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
  // Latch handover, half two: give the edge state back to the Session-level watchers before this run
  // stops being the evaluator. Without it, a trigger that is still true when the chart ends would look
  // like a fresh rising edge to armed_watcher_tick a moment later and fire again. See interrupt.odin.
  run := &ctx.session.script
  for &w in run.watchers {
    if w.global_source == "" {
      continue
    }
    if g := armed_watcher_find(ctx.session, w.global_source, w.global_body_id); g != nil {
      g.condition_state.latched = w.condition_state.latched
      g.fires += w.fires
    }
  }
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
  if run.watcher_depth > 0 {
    return
  }
  for &w, wi in run.watchers {
    // Through script_event_fired, not def.fired, so `on not <event> -> ...` negates like everywhere else.
    if !script_condition_holds(ctx, w.condition, &w.condition_state) {
      w.condition_state.latched = false // condition went away - re-arm for the next edge
      continue
    }
    if w.condition_state.latched {
      continue // still true from a previous fire; not a new edge
    }
    w.condition_state.latched = true
    w.fires += 1
    fmt.printf("\n[script] interrupt: %s\n", w.src)
    fmt.print("memscan> ")
    // Anchored on the first node of its BODY: a watcher's own `.On` node id is not carried on the
    // hoisted row, and the body is what the trace strip should jump you to anyway.
    body_node := w.entry >= 0 && w.entry < len(run.steps) ? run.steps[w.entry].id : Node_Id(0)
    script_trace(ctx.session, body_node, .Note, "WATCHER fired: %s", w.src)
    if w.entry < 0 {
      return // nothing to run (an unimplemented block); the edge still counts as serviced
    }
    // Suspend the main program and jump into this watcher's region. The body is a normal part of the
    // program from here on: it polls across ticks and its exit runs, so an interrupt can walk somewhere
    // and actually arrive. A body that never finishes freezes the main program until `script stop` -
    // which is the same deal as any other blocking step, and visible in `script` as the current step.
    run.suspended = Suspended_Frame {
      pc      = run.pc,
      entered = run.entered,
      nloop   = run.nloop,
      loops   = run.loops,
    }
    run.watcher_depth = 1
    run.active_watcher = wi // which watcher has control, so the UI can light the right chip
    run.nloop = 0 // the region gets its own loop stack; the main program's is in suspended
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

// Where control goes once <step> is done.
//
// Only .Action and .Wait_For reach here (script_advance is called from nowhere else - every structured
// op does its own `pc + 1`), and neither of them falls through any more: their fall-throughs were made
// explicit when the document was created. So an unnamed successor is the END of the program, and -1 is
// how the walker is already told that, by .Branch's unwired false arm. See script_op_falls_through.
script_next_pc :: proc(run: ^Script_Run, step: ^Script_Step) -> int {
  if step.goto_id != 0 {
    return step.jump
  }
  return script_op_falls_through(step.op) ? run.pc + 1 : -1
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

// An action that FAILED leaves by its else edge when one is wired, instead of ending the run.
//
// That edge is what lets a chart draw a fall-through chain: the priority ladder is a row of pick
// blocks whose fail edges point at the next rung, so "this rung found nothing, ask the next one" is
// one wire rather than a branch node per rung. Anything else that can fail usefully - a target lock
// refused because the mob died mid-reach - gets a retry path for free.
//
// UNWIRED KEEPS THE OLD BEHAVIOUR: jump_else < 0 means no edge was named, and a failing block then
// stops the program exactly as before. That is what you still want for, say, a walk that cannot
// start. The step's exit runs on this path too, same as script_advance - a failed block may well have
// started something that needs tearing down.
script_take_fail_edge :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> bool {
  if step.else_id == 0 || step.jump_else < 0 {
    return false
  }
  run := &ctx.session.script
  if def := action_def(step.action.kind); def != nil && def.exit != nil {
    def.exit(ctx, step)
  }
  run.steps_done += 1
  script_goto(run, step.jump_else)
  script_trace(ctx.session, step.id, .Note, "failed -> fail wire to node %d", u32(step.else_id))
  return true
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
    off_end := run.pc < 0 || run.pc >= len(run.steps) || (run.watcher_depth == 0 && run.pc >= run.main_len)
    if off_end {
      if run.watcher_depth > 0 {
        script_watcher_return(ctx) // a region that ran off its end - resume as if it had returned
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
    case .On, .If, .Else, .Repeat, .While, .End, .Loop, .Goto, .Branch, .Return:
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
          script_arm_condition(ctx, step.until, &step.condition_state)
        }
        script_note_line(ctx, step)
        def := action_def(step.action.kind)
        if def == nil || def.start == nil {
          script_fail(ctx, step, "block has no implementation")
          return
        }
        switch def.start(ctx, step) {
        case .Failed:
          if script_take_fail_edge(ctx, step) {
            continue
          }
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
      if step.has_until && script_condition_holds(ctx, step.until, &step.condition_state) {
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
        if script_take_fail_edge(ctx, step) {
          continue
        }
        script_fail(ctx, step, "failed")
        return
      case .Running:
        return // yield
      }

    case .If:
      script_arm_condition(ctx, step.condition, &step.condition_state)
      script_note_line(ctx, step)
      if script_condition_holds(ctx, step.condition, &step.condition_state) {
        script_trace(ctx.session, step.id, .Step, "-> yes")
        script_goto(run, run.pc + 1)
      } else {
        script_trace(ctx.session, step.id, .Step, "-> no")
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
          script_arm_condition(ctx, step.condition, &step.condition_state)
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
        keep = script_condition_holds(ctx, step.condition, &step.condition_state)
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
        script_arm_condition(ctx, step.condition, &step.condition_state)
        script_note_line(ctx, step)
      }
      if script_condition_holds(ctx, step.condition, &step.condition_state) {
        run.steps_done += 1
        script_goto(run, script_next_pc(run, step))
        continue
      }
      return // yield

    // --- graph ops (the node editor's control flow) ---

    case .Loop:
      // The graph twin of .Repeat/.End, with the count on the node instead of the run's loop stack.
      // Control leaves a graph loop by an EDGE, which need not come back through the head, so a stack
      // frame pushed here could never be reliably popped - and two loops entered in the "wrong" order
      // would unwind each other's. Per-node state has neither problem and costs two words.
      if !step.scratch.loop_active {
        step.scratch.loop_active = true
        step.scratch.loop_remaining = step.count
      }
      script_note_line(ctx, step)
      if step.scratch.loop_remaining > 0 {
        step.scratch.loop_remaining -= 1
        script_trace(ctx.session, step.id, .Step, "-> each pass (%d left after this)", step.scratch.loop_remaining)
        script_goto(run, step.jump) // another pass over the body
      } else {
        step.scratch.loop_active = false // re-arm, so re-entering it later loops again
        script_trace(ctx.session, step.id, .Step, "-> when done")
        script_goto(run, step.jump_else)
      }

    case .Goto:
      script_note_line(ctx, step)
      script_goto(run, step.jump)

    case .Branch:
      // Armed on the FIRST visit only, unlike .If which re-arms every time. A branch is how a graph
      // draws a loop exit, so control comes back to it once per iteration - re-arming there would reset
      // `elapsed`/`kills` baselines every pass and the exit could never be reached. This is the same
      // rule .While follows for its condition, for the same reason. (.If keeps re-arming: it is a
      // point-in-time test that control passes through once.)
      if !script_condition_armed(step.condition_state) {
        script_arm_condition(ctx, step.condition, &step.condition_state)
      }
      script_note_line(ctx, step)
      yes := script_condition_holds(ctx, step.condition, &step.condition_state)
      // Name the arm AND whether it goes anywhere. An unwired arm is a jump to -1, i.e. the end of the
      // run, and "-> no (nothing wired, run ends)" is the row that explains a chart stopping at a branch.
      dest := yes ? step.jump : step.jump_else
      script_trace(
        ctx.session, step.id, dest < 0 ? .Error : .Step,
        "-> %s%s", yes ? "yes" : "no", dest < 0 ? " (nothing wired, run ends)" : "",
      )
      script_goto(run, dest)

    case .Return:
      if run.watcher_depth == 0 {
        // A `return` reached in the main program is simply the end of it - a graph's terminator.
        if !script_program_end(ctx) {
          return
        }
        continue
      }
      script_watcher_return(ctx)
    }
  }
}

// Resume the main program where the interrupt suspended it. pc is restored DIRECTLY rather than through
// script_goto because `entered` must come back too: the suspended step may have been mid-flight (a walk
// that is still walking), and re-entering it would re-issue its start.
script_watcher_return :: proc(ctx: ^Behaviour_Context) {
  run := &ctx.session.script
  run.pc = run.suspended.pc
  run.entered = run.suspended.entered
  run.nloop = run.suspended.nloop
  run.loops = run.suspended.loops
  run.watcher_depth = 0
  run.active_watcher = -1
  script_trace(ctx.session, 0, .Note, "watcher done - back to step %d", run.pc + 1)
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

// The node the run is sitting on, for a trace row raised from INSIDE a block - a block proc gets the
// step it is running but the helpers it calls (script_arg) get only the context.
script_current_node :: proc(ctx: ^Behaviour_Context) -> Node_Id {
  run := &ctx.session.script
  if !run.active || run.pc < 0 || run.pc >= len(run.steps) {
    return 0
  }
  return run.steps[run.pc].id
}

// Now takes the STEP rather than its source text, because it is also the single place control-arrived-
// here is traced. Every op that can be entered calls it, so one call site per op covers the narration.
script_note_line :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) {
  run := &ctx.session.script
  delete(run.last_line)
  run.last_line = strings.clone(step.src)
  script_trace(ctx.session, step.id, .Step, "%s", step.src)
}

script_fail :: proc(ctx: ^Behaviour_Context, step: ^Script_Step, why: string) {
  fmt.printf("\n[script] step %d (%s) - %s. run stopped.\n", u32(step.id), step.src, why)
  fmt.print("memscan> ")
  // Say WHY the run is over here rather than leaving it to script_finish's "failed": the fail edge is
  // the thing an author forgot, and naming it is what turns "the chart stops on node 2" into a fix.
  script_trace(ctx.session, step.id, .Error, "%s - run ends (no fail wire on this node)", why)
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

// Take ownership of <steps> and begin running. Hoists the `on` watchers out of the instruction
// stream so their position in the file does not affect when they arm.
//
// <entry> is the node to start at, BY IDENTITY - 0 means "the first step", which is what a program
// built by builder.odin wants (it emits in execution order). A saved graph names its start node
// instead, because on a canvas the topmost array slot is not necessarily where control begins.
script_begin :: proc(
  session: ^Session,
  name: string,
  steps: [dynamic]Script_Step,
  mode: Script_Mode,
  entry: Node_Id = 0,
  kind: Behaviour_Kind = .Chart,
  uses: []string = nil,
) {
  script_run_free(&session.script)
  run := &session.script
  run.steps = steps
  run.watchers = make([dynamic]Script_Watcher)
  // "Is this a hunt chart" - see hunt_steering_on. Asked of the steps once, here, rather than per pick.
  run.sidestep_chart = false
  for step in run.steps {
    if step.op == .Action && step.action.kind == .Approach && step.action.nums[2] != 0 {
      run.sidestep_chart = true
      break
    }
  }
  if kind == .Interrupt {
    // A watcher's body, run on its own because its trigger fired. NOTHING is armed for it: not the
    // globals, not what the host borrowed, and not even the document's own `on` nodes. <entry> already
    // names the body, so the body IS the main program here - hoisting it into a region as well would
    // mean the run started by falling off the end of an empty program and only worked because the
    // watcher happened to fire on the first tick. And an escape that can be interrupted by the same
    // escape re-fires on its own still-true trigger forever; watcher_depth only caps nesting once inside.
    run.main_len = len(run.steps)
  } else {
    // The main program ends where the inline watcher bodies begin; regions are appended after that, so
    // the walker knows where to stop even though the array keeps going.
    run.main_len = script_partition_watcher_bodies(&run.steps, entry)
    script_build_irq_regions(run)
    // Then the borrowed ones, in the order the chart lists them, and the GLOBAL ones last - so a
    // chart's own `on` beats one it borrowed, which beats one that is simply always on. First match
    // wins, which is the rule script_interrupts already followed.
    for u in uses {
      script_attach_doc_watchers(session, run, u, "")
    }
    script_attach_global_irqs(session, run)
  }
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
  run.watcher_depth = 0
  run.active_watcher = -1
  run.started_at = time.now()._nsec
  run.step_at = run.started_at

  ctx := Behaviour_Context {
    session = session,
    now     = run.started_at,
    board   = &session.bh_board,
  }
  for &w in run.watchers {
    script_arm_condition(&ctx, w.condition, &w.condition_state)
    // Latch handover, half one. A hoisted global interrupt has been watching since it was enabled; if
    // its condition is currently true AND it has already been serviced, arming it fresh here would
    // fire it again the moment this chart starts. Carrying the latch makes the Session-level watcher
    // and this one behave as a single watcher that never stopped watching. (armed_watcher_tick's own pass does
    // nothing while a run is active, so there is exactly one evaluator at a time.)
    if w.global_source != "" {
      if g := armed_watcher_find(session, w.global_source, w.global_body_id); g != nil {
        w.condition_state.latched = g.condition_state.latched
      }
    }
  }
  // A fresh run starts a fresh story. Without the clear you cannot tell last run's failure rows from
  // this run's, which is exactly the confusion the ring exists to remove.
  session.script_trace = {}
  script_trace(
    session, run.steps[start].id, .Note,
    "RUN '%s' (%s) - %d nodes, %d watcher(s)",
    name, mode == .Loop ? "loop" : "once", run.main_len, len(run.watchers),
  )

  engine.ensure_hotkey_thread(&session.eng) // the walker only advances on the watcher tick
  behaviour_goto(session, .Script)
}

// Hoist every ENABLED global interrupt into <run> as a watcher with its whole chart as a region. The
// result is indistinguishable from an `on` line the chart wrote itself, which is the point: there is
// one interrupt mechanism, and "global" only describes where the definition came from.
@(private = "file")
script_attach_global_irqs :: proc(session: ^Session, run: ^Script_Run) {
  seen := make(map[string]bool, 8, context.temp_allocator)
  defer delete(seen)
  for i in 0 ..< session.armed_watcher_count {
    g := &session.armed_watchers[i]
    if !g.ok || seen[g.doc] {
      continue // one hoist per DOCUMENT: its watchers all come across together
    }
    seen[g.doc] = true
    script_attach_doc_watchers(session, run, g.doc, g.doc)
  }
}

// Copy <name>'s watchers - every `.On` node it holds, with the body each one points at - into <run>.
//
// ONE PROC FOR TWO SCOPES. `uses` (this chart borrows them) passes global="" and global arming passes
// the document name, and that string is the only difference between them: it is what makes the latch
// handover in script_begin / script_teardown find its Session-level twin. Everything else - the id
// remap, the availability gate, the watcher cap - is the same question either way, and having asked it
// twice in two places is how the two scopes would drift apart.
@(private = "file")
script_attach_doc_watchers :: proc(session: ^Session, run: ^Script_Run, name: string, global_source: string) {
  if name == run.name {
    return // a chart cannot borrow itself; its own watchers are already hoisted
  }
  doc, dok := bhv_open(name)
  if !dok {
    return // armed_watcher_reload / the editor already reported it; do not spam once per run
  }
  defer behaviour_doc_free(&doc)
  // A gated block in the body would die mid-region and take the chart down with it. Refuse the hoist
  // and say so once - the chart itself is still fine to run.
  if problems := script_check_avail(session, doc.steps[:]); len(problems) > 0 {
    fmt.eprintfln("script: watchers from '%s' are not armed for this run - %s", name, problems[0])
    return
  }
  base, ok := script_append_irq_region(run, &doc)
  if !ok {
    return
  }
  n := 0
  for s in doc.steps {
    if s.op != .On || s.goto_id == 0 {
      continue
    }
    if len(run.watchers) >= SCRIPT_MAX_WATCHERS {
      fmt.eprintfln("script: no room for the watchers in '%s' (%d is the cap).", name, SCRIPT_MAX_WATCHERS)
      break
    }
    entry := -1
    for rs, i in run.steps {
      if rs.id == s.goto_id + base {
        entry = i
        break
      }
    }
    if entry < 0 {
      continue
    }
    w := Script_Watcher {
      condition      = script_condition_clone(s.condition),
      src            = strings.clone(fmt.tprintf("%s: %s", name, s.src)),
      global_source = global_source == "" ? "" : strings.clone(global_source),
      global_body_id = s.goto_id, // the PRE-remap id, which is what Session.armed_watchers rows carry
      entry          = entry,
    }
    append(&run.watchers, w)
    n += 1
  }
  if n == 0 {
    fmt.eprintfln("script: '%s' has no watchers to borrow (it needs an 'on' node wired to a body).", name)
  }
}

// Append <doc>'s program to <run> as interrupt-region code, and return the id OFFSET it was pasted at.
//
// The ids have to be REMAPPED. Two independently authored charts both start numbering at 1, so
// pasting one into the other verbatim would give duplicate ids - and script_resolve_ids maps id ->
// index, so the second copy's edges would silently retarget onto the first's nodes. Offsetting every
// id (and every edge that names one) by the host's high-water mark keeps each region's edges pointing
// inside itself. The caller adds the same offset to find a watcher's entry.
//
// The doc is PARTITIONED on the way in, by the same proc a run's own steps go through, so each of its
// watcher bodies arrives as its own terminated block. Without that, one borrowed watcher's body would
// walk off its end straight into the next one's.
@(private = "file")
script_append_irq_region :: proc(run: ^Script_Run, doc: ^Behaviour_Doc) -> (base: Node_Id, ok: bool) {
  if len(doc.steps) == 0 {
    return 0, false
  }
  script_partition_watcher_bodies(&doc.steps, doc.entry)
  for s in run.steps {
    base = max(base, s.id)
  }
  for s in doc.steps {
    c := s
    c.id = s.id + base
    c.goto_id = s.goto_id != 0 ? s.goto_id + base : 0
    c.else_id = s.else_id != 0 ? s.else_id + base : 0
    c.action = script_action_clone(s.action)
    c.condition = script_condition_clone(s.condition)
    c.until = script_condition_clone(s.until)
    c.src = strings.clone(s.src)
    c.scratch = {}
    c.condition_state = {}
    append(&run.steps, c)
  }
  // The terminator is not optional. Without it a region that runs off its own end would fall into
  // whatever was appended next - which is the NEXT borrowed document's code.
  top := Node_Id(0)
  for s in run.steps {
    top = max(top, s.id)
  }
  append(&run.steps, Script_Step{id = top + 1, op = .Return, src = strings.clone("return")})
  return base, true
}

// --- graph reachability, shared by the partitioner and the "is this a chart?" question -------------

// Where control can go from step <i>. `.On` contributes only its FALL-THROUGH: its goto_id is a body,
// which is reached by the trigger firing and never by walking into it.
//
// <assume_fallthrough> is for the ONE caller that runs before the document has been materialised -
// script_materialize_fallthrough itself, which has to see the graph the way the walker used to in order
// to work out which nodes belong to a watcher body. Everything else asks after materialisation, where
// an .Action that continues somewhere says so.
@(private = "file")
script_step_successors :: proc(
  steps: []Script_Step,
  index_of: map[Node_Id]int,
  i: int,
  out: ^[3]int,
  assume_fallthrough := false,
) -> int {
  s := steps[i]
  m := 0
  push :: proc(out: ^[3]int, m: ^int, v: int) {
    if v >= 0 && m^ < 3 {
      out[m^] = v
      m^ += 1
    }
  }
  idx :: proc(index_of: map[Node_Id]int, id: Node_Id) -> int {
    if id == 0 {
      return -1
    }
    v, ok := index_of[id]
    return ok ? v : -1
  }
  fall := i + 1 < len(steps) ? i + 1 : -1
  #partial switch s.op {
  case .Return:
  // ends the region; nothing follows
  case .On:
    push(out, &m, fall)
  case .Goto:
    push(out, &m, idx(index_of, s.goto_id))
  case .Branch, .Loop:
    push(out, &m, idx(index_of, s.goto_id))
    push(out, &m, idx(index_of, s.else_id))
  case:
    // .Action / .Wait_For and anything structured that survived lowering: an explicit successor, or
    // the next slot for the ops that still fall through, plus a fail arm when one is wired.
    if s.goto_id != 0 {
      push(out, &m, idx(index_of, s.goto_id))
    } else if assume_fallthrough || script_op_falls_through(s.op) {
      push(out, &m, fall)
    }
    push(out, &m, idx(index_of, s.else_id))
  }
  return m
}

// Flood <seen> with everything reachable from <from>. <walls> is an optional set of indices the walk
// refuses to enter, which is how the main program is kept out of the watcher bodies.
@(private = "file")
script_mark_reachable :: proc(
  steps: []Script_Step,
  index_of: map[Node_Id]int,
  from: int,
  walls: []bool,
  seen: []bool,
  assume_fallthrough := false,
) {
  if from < 0 || from >= len(steps) {
    return
  }
  stack := make([dynamic]int, 0, len(steps), context.temp_allocator)
  append(&stack, from)
  for len(stack) > 0 {
    i := pop(&stack)
    if i < 0 || i >= len(steps) || seen[i] {
      continue
    }
    if walls != nil && walls[i] {
      continue
    }
    seen[i] = true
    out: [3]int
    m := script_step_successors(steps, index_of, i, &out, assume_fallthrough)
    for k in 0 ..< m {
      append(&stack, out[k])
    }
  }
}

// Which steps belong to a watcher's BODY - reachable from some `.On` node's edge. The `.On` nodes
// themselves are excluded: the walker steps over them and the canvas draws them above the chart, so
// they are part of the main program's array even though they are not part of its flow.
//
// Shared with the node editor, which needs the same answer to draw the watchers in their own band and
// to refuse to make one of them the start node. Deriving it twice is how the picture and the program
// would come to disagree.
script_watcher_body_mask :: proc(steps: []Script_Step, is_body: []bool, assume_fallthrough := false) {
  index_of := make(map[Node_Id]int, len(steps), context.temp_allocator)
  defer delete(index_of)
  for s, i in steps {
    if s.id != 0 {
      index_of[s.id] = i
    }
  }
  for s in steps {
    if s.op == .On && s.goto_id != 0 {
      if start, ok := index_of[s.goto_id]; ok {
        script_mark_reachable(steps, index_of, start, nil, is_body, assume_fallthrough)
      }
    }
  }
  for s, i in steps {
    if s.op == .On {
      is_body[i] = false
    }
  }
}

// Move every INLINE WATCHER BODY behind the main program, and return where the main program ends.
//
// A watcher is an `.On` node plus the subgraph its edge points at. That subgraph lives in the same
// array as the chart, which leaves one hazard: fall-through. Control that walks off the last node of
// the main program would land on the first node of a body it was never triggered into.
//
// Partitioning removes the hazard instead of guarding against it, and does so using machinery that
// already exists. Edges are resolved by IDENTITY after this runs, so reordering costs nothing; only
// fall-through is positional, and relative order is preserved inside each partition. Then:
//
//   - main runs off its end   -> pc >= main_len -> script_program_end. Exactly right.
//   - a body runs off its end -> watcher_depth > 0  -> script_watcher_return. Also exactly right.
//
// which is the same pair of rules that already governed the regions appended past main_len. Each body
// still gets an explicit .Return terminator, because two adjacent bodies would otherwise run into each
// other - the same reason script_append_irq_region appends one.
//
// A body that jumps BACK into the main program classifies those nodes as body. That is a broken chart
// either way (control would arrive there with an interrupt frame that never gets returned), and the
// editor warns about it at save time; the runtime just has to be deterministic about it.
@(private = "file")
script_partition_watcher_bodies :: proc(steps: ^[dynamic]Script_Step, entry: Node_Id) -> int {
  n := len(steps)
  if n == 0 {
    return 0
  }
  index_of := make(map[Node_Id]int, n, context.temp_allocator)
  defer delete(index_of)
  for s, i in steps {
    if s.id != 0 {
      index_of[s.id] = i
    }
  }
  has_on := false
  for s in steps {
    if s.op == .On && s.goto_id != 0 {
      has_on = true
      break
    }
  }
  if !has_on {
    return n // nothing to separate; every step is main, as before
  }

  // Bodies first, then main with the bodies as walls. Order matters: a watcher usually sits directly
  // above the body it triggers, so letting main fall through the `.On` node into it would swallow the
  // whole body - which is precisely the case an upgraded interrupt file produces.
  body := make([]bool, n, context.temp_allocator)
  script_watcher_body_mask(steps[:], body)
  main := make([]bool, n, context.temp_allocator)
  start := 0
  if entry != 0 {
    if v, ok := index_of[entry]; ok {
      start = v
    }
  }
  script_mark_reachable(steps[:], index_of, start, body, main)

  next_id := Node_Id(0)
  for s in steps {
    next_id = max(next_id, s.id)
  }
  emitted := make([]bool, n, context.temp_allocator)
  out := make([dynamic]Script_Step, 0, n + 8, context.temp_allocator)
  for s, i in steps {
    if !body[i] {
      append(&out, s) // main and orphans alike - an unreachable node is not a watcher body
      emitted[i] = true
    }
  }
  main_len := len(out)

  // One CONTIGUOUS, TERMINATED block per watcher, rather than one block for all of them. Two bodies
  // laid end to end would let the first run into the second the moment it walked off its own last
  // node - the exact failure the .Return after each region exists to prevent.
  for s in steps {
    if s.op != .On || s.goto_id == 0 {
      continue
    }
    head, sok := index_of[s.goto_id]
    if !sok {
      continue
    }
    mine := make([]bool, n, context.temp_allocator)
    script_mark_reachable(steps[:], index_of, head, nil, mine)
    added := false
    for j in 0 ..< n {
      if mine[j] && body[j] && !emitted[j] {
        append(&out, steps[j])
        emitted[j] = true
        added = true
      }
    }
    if added {
      next_id += 1
      append(&out, Script_Step{id = next_id, op = .Return, src = strings.clone("return")})
    }
  }
  clear(steps)
  for s in out {
    append(steps, s)
  }
  return main_len
}

// Hoist every `on` out of the instruction stream and give it a REGION: program text past main_len,
// terminated by .Return. Position in the file therefore has no effect on when a watcher arms, and -
// the point of the region - the body is ordinary program text, so it polls across ticks and its exit
// runs like any other step.
//
// TWO SHAPES OF BODY, one mechanism. An `.On` that NAMES one (goto_id) already has its subgraph sitting
// past main_len, put there by script_partition_watcher_bodies; the watcher just points at it. An `.On`
// that carries a single action instead - which is what builder.on() emits, and what every `on` was
// before bodies existed - gets a two-step region synthesized here. Everything downstream sees a region.
@(private = "file")
script_build_irq_regions :: proc(run: ^Script_Run) {
  next_id := Node_Id(0)
  for s in run.steps {
    next_id = max(next_id, s.id)
  }
  index_of := make(map[Node_Id]int, len(run.steps), context.temp_allocator)
  defer delete(index_of)
  for s, i in run.steps {
    if s.id != 0 {
      index_of[s.id] = i
    }
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
      condition      = script_condition_clone(s.condition),
      action = script_action_clone(s.action),
      src    = strings.clone(s.src),
      entry  = -1,
    }
    if s.goto_id != 0 {
      if e, ok := index_of[s.goto_id]; ok {
        w.entry = e
      }
    } else if s.action.kind != .None {
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

// Every ROW's strings, so a condition can be copied and freed as one thing. Rows past condition_row_count are
// left as the zero value rather than cloned: they hold no strings, and cloning "" would allocate.
script_condition_clone :: proc(condition: Script_Condition) -> Script_Condition {
  out := condition
  for row in 0 ..< condition_row_count(condition) {
    condition_row_ptr(&out, row)^ = script_event_clone(condition_row(condition, row))
  }
  return out
}

script_condition_free :: proc(condition: ^Script_Condition) {
  for index in 0 ..< condition_row_count(condition^) {
    row := condition_row_ptr(condition, index)
    delete(row.strs[0])
    delete(row.strs[1])
    row.strs = {}
  }
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
  keys_release_all(ctx.session) // a key held from the previous pass must not survive the rewind

  run.watcher_depth = 0
  run.suspended = {}
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
    script_arm_condition(&ctx, w.condition, &w.condition_state)
  }
  // Disarm every per-site baseline. A .Branch arms once and keeps its baseline for the whole run (see
  // the walker), so without this a rewound program would inherit the previous run's clock and take its
  // loop exit immediately.
  for &s in run.steps {
    s.condition_state = {}
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
    script_cmd_selftest(session)
  case "list":
    script_cmd_list(session)
  case "show":
    script_cmd_show(session, args[1:])
  case "run", "start":
    script_cmd_run(session, args[1:])
  case "step":
    script_cmd_step(session, args[1:])
  case "trace", "log":
    script_cmd_trace(session, args[1:])
  case "lint", "check":
    script_cmd_lint(session, args[1:])
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
    fmt.eprintln("  pause | resume | reset | step [off] | trace [n|all|clear] | lint [name]")
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
  // Only when something IS held: a key the tool is holding down is invisible otherwise, and it is the
  // one piece of state here that keeps acting on the game with nothing on screen to say so.
  if n := keys_held_count(session); n > 0 {
    fmt.printfln("  keys held: %s   ('key release' lets go of all %d)", keys_held_text(session), n)
  }
  saved := bhv_list_names()
  fmt.printfln(
    "  behaviours: %d in Odin (flyff/behaviours.odin) + %d saved in %s - 'script list'",
    len(BEHAVIOURS), len(saved), bhv_dir_path(),
  )
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
    what := run.paused ? "PAUSED" : (run.watcher_depth > 0 ? "INTERRUPT" : "RUNNING")
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
  if run.watcher_depth > 0 {
    fmt.printfln("  ^ inside an INTERRUPT; the main program is suspended at step %d and resumes when it returns.", run.suspended.pc + 1)
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
    mark, why := script_avail_mark(session, def.avail, def.not_built, def.not_built_why)
    fmt.printfln("  %s %-16s %s%s", mark, script_sig(def.name, def.params), def.blurb, why)
  }
  fmt.println("EVENTS (things a script can wait for / react to):")
  for def in EVENTS {
    mark, why := script_avail_mark(session, def.avail, def.not_built, def.not_built_why)
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

// Prove that node identity does what it exists for: survive a structural edit.
//
// Without it an edge is an array offset, so inserting a step anywhere silently retargets every jump
// after it. This builds a real nested program, records where each edge lands, inserts a node at the
// FRONT (the worst case - every position shifts), re-resolves, and checks each edge still lands on
// the same NODE. Cheap, exact, and it fails loudly if the resolver ever regresses.
script_cmd_selftest :: proc(session: ^Session) {
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
  ed_selftest_insert()
  name_list_selftest()
  // Last, and called from here rather than chained off the end of the others, because it is the one
  // section that needs the SESSION - it writes and reads real variables.
  script_selftest_coord(session)
}

// Prove the file format is lossless: build every Odin behaviour, serialize it, parse it back, and
// compare the RENDERED programs. Rendering both sides rather than memcmp-ing the structs is the point -
// it compares exactly what the walker will execute (ops, edges, block kinds, every argument) while
// ignoring the things that legitimately differ (heap pointers, per-run scratch).
@(private = "file")
script_selftest_roundtrip :: proc() {
  fmt.println("  --- save/load round-trip ---")
  fails := 0
  // BOTH registries: the hidden test set is most of the coverage here (it is the only thing that
  // exercises structured blocks, interrupt regions and back-edge loops in one place).
  all := make([dynamic]Behaviour_Def, 0, len(BEHAVIOURS) + len(TEST_BEHAVIOURS), context.temp_allocator)
  append(&all, ..BEHAVIOURS[:])
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
    //
    // ui_pos and `group` have to be checked HERE too, and for the same reason: script_render prints
    // neither, so a section name silently dropped by the writer or the reader would compare equal on
    // both sides and the loss would only show up as an unlabelled canvas much later.
    for s, i in doc.steps {
      if back.steps[i].id != s.id || back.steps[i].goto_id != s.goto_id {
        fmt.eprintfln("  FAIL: '%s' step %d: id/goto %d/%d -> %d/%d", d.name, i, u32(s.id), u32(s.goto_id), u32(back.steps[i].id), u32(back.steps[i].goto_id))
        fails += 1
        break
      }
      if back.steps[i].group != s.group {
        fmt.eprintfln("  FAIL: '%s' step %d: section '%s' came back as '%s'", d.name, i, s.group, back.steps[i].group)
        fails += 1
        break
      }
      if back.steps[i].ui_pos != s.ui_pos {
        fmt.eprintfln("  FAIL: '%s' step %d: ui_pos %v came back as %v", d.name, i, s.ui_pos, back.steps[i].ui_pos)
        fails += 1
        break
      }
    }
  }
  if fails == 0 {
    fmt.printfln("  PASS: all %d behaviours survive serialize -> parse -> render unchanged", len(all))
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
    case .Str, .Names, .Mob, .Key, .Var_Name, .Choice:
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
    case .Str, .Names, .Mob, .Key, .Var_Name, .Choice:
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
        op = .Branch,
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

      doc := Behaviour_Doc {
        name  = "condtest",
        entry = 1,
        steps = steps,
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
      got := back.steps[0].condition
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
        case .Coord, .Str, .Names, .Mob, .Key, .Var_Name, .Choice:
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
  for &def in BEHAVIOURS {
    one(&def, &checked, &fails)
  }
  for &def in TEST_BEHAVIOURS {
    one(&def, &checked, &fails)
  }
  if fails == 0 {
    fmt.printfln("  PASS: all %d built-in charts lint clean (no dangling edges, no blank required arguments)", checked)
  } else {
    fmt.eprintfln("  %d lint problem(s) in the shipped charts", fails)
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
    shadow := ""
    if slice.contains(saved, d.name) {
      shadow = "   <- shadowed by the saved copy of the same name"
    }
    fmt.printfln("  %-14s %s%s", d.name, d.blurb, shadow)
  }
  fmt.printfln("  ^ defined in Odin (flyff/behaviours.odin).")
  // Named, not listed. They are runnable by name and `script selftest` exercises them; putting nine of
  // them in front of the four you actually pick from is what made this list something to read past.
  fmt.printfln("  (+%d verification charts, hidden - 'script selftest' runs them; 'script show t_flow' names one)", len(TEST_BEHAVIOURS))
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
    node := r.node == 0 ? "     " : fmt.tprintf("n%-4d", u32(r.node))
    fmt.printfln("  %8.3fs  %s  %s%s", f64(r.at - base) / 1e9, node, tag, script_trace_text(&r))
  }
}

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
  // Start STOPPED on the first node. A modifier rather than two commands (`script run x` then
  // `script step`), because between two enqueued commands the watcher gets a tick and the chart is
  // already somewhere else by the time the step lands - which is exactly what the editor's Step button
  // needs not to happen.
  start_stepping := false
  for a in args {
    switch a {
    case "once":
      mode_override = int(Script_Mode.Once)
    case "loop":
      mode_override = int(Script_Mode.Loop)
    case "step", "stepping", "paused":
      start_stepping = true
    case:
      if name == "" {
        name = a
      }
    }
  }
  if name == "" {
    fmt.eprintln("usage: script run <name> [once|loop] [step]   ('script list' shows what's available)")
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
  // A document made entirely of watchers has no main program - running it would start and stop in the
  // same tick. That is not an error in the file, it is a different VERB: you arm it, or a chart borrows
  // it. Saying so beats "started (5 steps)" followed instantly by "complete".
  if script_doc_is_watchers_only(&doc) {
    fmt.eprintfln("script run: '%s' is a set of watchers, not a chart - there is no start node to run from.", label)
    fmt.eprintfln("  'interrupt on %s' arms it, a chart's options tab borrows it, or 'interrupt test %s' runs its body once.", label, label)
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
  script_begin(session, label, doc.steps, mode, doc.entry, .Chart, doc.uses[:])
  // AFTER script_begin, which zeroes the run. Setting it before would be silently discarded.
  if start_stepping && session.script.active {
    session.script.stepping = true
    script_trace(session, script_current_node(&Behaviour_Context{session = session}), .Note, "stepping - the walker will not advance on its own")
  }
  delete(doc.name)
  for u in doc.uses {
    delete(u)
  }
  delete(doc.uses)
  fmt.printfln(
    "script: '%s' started (%d steps, %s%s).",
    label, n, mode == .Loop ? "loop" : "once", start_stepping ? ", STEPPING - it will not advance until you step it" : "",
  )
}

// Is this document nothing but watchers? True when every step is either an `.On` node or part of some
// watcher's body - i.e. there is no main program for a start node to run.
//
// It is deliberately NOT "the entry step is an `.On`". A perfectly ordinary chart may declare a watcher
// on its first line (builder.on() does, and bh_test_interrupt is exactly that), and refusing to run
// that would break every chart with a timer on it.
script_doc_is_watchers_only :: proc(doc: ^Behaviour_Doc) -> bool {
  if len(doc.steps) == 0 {
    return false
  }
  body := make([]bool, len(doc.steps), context.temp_allocator)
  script_watcher_body_mask(doc.steps[:], body)
  for s, i in doc.steps {
    if s.op != .On && !body[i] {
      return false
    }
  }
  return true
}
