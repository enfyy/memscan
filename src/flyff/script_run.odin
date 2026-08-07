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
      if !run.stepping || script_frame_in_watcher(run) {
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
  // Hand back what every live call borrowed. A run stopped INSIDE a sub-chart - `script stop`, a detach,
  // an interrupt that ended the program - still owes the caller its own values for that block's
  // parameters, and this is the one path every ending goes through. It sits with the key release below
  // for exactly that reason: both are things the RUN owes, not things a step can be asked to undo.
  script_frames_unwind(ctx.session)
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
  // Already inside a WATCHER: evaluate nothing. Not even the latches - a condition that becomes true
  // while the region runs is a real edge that has not been serviced yet, and it should fire once the
  // region returns rather than be quietly swallowed here.
  //
  // Deliberately not "already inside any region". A sub-chart is ordinary program text that happens to
  // live past main_len, and an escape hatch that stopped watching the moment you called one of your own
  // blocks would be an escape hatch with a hole in it. Only interrupting an interrupt is refused.
  if script_frame_in_watcher(run) {
    return
  }
  // ... and there has to be somewhere to put the frame. Full means a chart nested to its call limit,
  // which SUBCHART_MAX_DEPTH is set below the frame cap specifically to prevent.
  if run.depth >= SCRIPT_MAX_FRAMES {
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
    run.active_watcher = wi // which watcher has control, so the UI can light the right chip
    script_frame_push(
      run,
      Suspended_Frame{kind = .Watcher, pc = run.pc, entered = run.entered, nloop = run.nloop, loops = run.loops, watcher = wi},
      w.entry,
    )
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
    // region code - a watcher body or a called sub-chart - reachable only by being entered.
    off_end := run.pc < 0 || run.pc >= len(run.steps) || (run.depth == 0 && run.pc >= run.main_len)
    if off_end {
      if run.depth > 0 {
        script_frame_pop(ctx) // a region that ran off its end - resume as if it had returned
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
      if run.depth == 0 {
        // A `return` reached in the main program is simply the end of it - a graph's terminator.
        if !script_program_end(ctx) {
          return
        }
        continue
      }
      script_frame_pop(ctx)

    case .Call:
      if !script_take_call(ctx, step) {
        return
      }
    }
  }
}

// Enter the sub-chart <step> names. Returns false when the run cannot continue.
//
// Everything that can go wrong here was already refused at load - script_expand_calls resolves the
// entry, checks the cycle and checks the depth - so these are assertions with an explanation attached,
// not the primary gate. They are still checked, because a node whose callee failed to expand is a node
// that would otherwise jump to index 0 and silently restart the program.
@(private = "file")
script_take_call :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> bool {
  run := &ctx.session.script
  if step.call_entry < 0 || step.call_entry >= len(run.steps) {
    script_fail(ctx, step, fmt.tprintf("sub-chart '%s' was not loaded", step.call_name))
    return false
  }
  if run.depth >= SCRIPT_MAX_FRAMES {
    script_fail(ctx, step, fmt.tprintf("too many nested calls (%d) at '%s'", SCRIPT_MAX_FRAMES, step.call_name))
    return false
  }
  frame := Suspended_Frame {
    kind    = .Call,
    pc      = run.pc, // the .Call node itself: the pop continues past it, by its own edges
    entered = true,
    nloop   = run.nloop,
    loops   = run.loops,
  }
  // Bind the arguments, remembering what each name held first. Both halves in one pass, and in
  // ARGUMENT order rather than in the callee's declared order, because the frame only has to be able to
  // undo exactly what this loop did.
  for i in 0 ..< min(step.call_arg_count, len(step.call_args)) {
    a := step.call_args[i]
    if a.name == "" || frame.saved_count >= len(frame.saved) {
      continue
    }
    sv := &frame.saved[frame.saved_count]
    sv.name_len = copy(sv.name[:], a.name)
    if old, had := engine.session_var_get(&ctx.session.eng, a.name); had {
      sv.had = true
      sv.value_len = copy(sv.value[:], old)
    }
    frame.saved_count += 1
    // script_arg, so a caller can pass one of its OWN variables down: `who=@target_name`. Resolved
    // here, at the call, rather than inside the callee - the callee has no idea whose scope it came from.
    engine.session_var_set(&ctx.session.eng, a.name, script_arg(ctx, a.value))
  }
  script_trace(ctx.session, step.id, .Step, "CALL '%s'", step.call_name)
  script_frame_push(run, frame, step.call_entry)
  return true
}

// --- the frame stack ---------------------------------------------------------------------------
//
// Entering a region - a watcher body or a called sub-chart - is one operation with one shape: remember
// where you were, then jump. These four procs are that one operation, and every caller goes through
// them so that "what does it mean for the pc to run off the end" has exactly one answer.

// Is an interrupt currently in control? Not the same question as "is the stack non-empty" any more: a
// sub-chart may be several frames deep with no watcher anywhere. Read by the walker's interrupt gate
// (an interrupt cannot interrupt itself) and by the radar's status chips.
script_frame_in_watcher :: proc(run: ^Script_Run) -> bool {
  for i in 0 ..< min(run.depth, len(run.frames)) {
    if run.frames[i].kind == .Watcher {
      return true
    }
  }
  return false
}

// Push <frame> and jump to <entry>. The region gets its own loop stack; the caller's is in the frame.
@(private = "file")
script_frame_push :: proc(run: ^Script_Run, frame: Suspended_Frame, entry: int) {
  run.frames[run.depth] = frame
  run.depth += 1
  run.nloop = 0
  script_goto(run, entry)
}

// Leave the innermost region and resume its caller.
//
// pc is restored DIRECTLY rather than through script_goto because `entered` must come back too: the
// suspended step may have been mid-flight (a walk that is still walking), and re-entering it would
// re-issue its start. A CALL is the exception - it resumes PAST the node that made it, so it goes
// through script_goto after all, by way of the same success/fail arms every other block has.
@(private = "file")
script_frame_pop :: proc(ctx: ^Behaviour_Context) {
  run := &ctx.session.script
  if run.depth <= 0 {
    return
  }
  run.depth -= 1
  frame := run.frames[run.depth]
  run.frames[run.depth] = {}
  run.nloop = frame.nloop
  run.loops = frame.loops
  switch frame.kind {
  case .Watcher:
    run.pc = frame.pc
    run.entered = frame.entered
    run.active_watcher = -1
    // Named by NODE, not by step index. The index is a position in the flat array - regions included -
    // so once sub-charts exist "back to step 7" points at a node no open document contains.
    back := run.pc >= 0 && run.pc < len(run.steps) ? run.steps[run.pc].id : Node_Id(0)
    script_trace(ctx.session, back, .Note, "watcher done - back to where it was")
  case .Call:
    // Put the caller's own values back before anything else runs. A sub-chart's parameters behave as
    // locals for exactly the names it declared; everything else it touched is still shared, which is
    // the documented deal.
    script_restore_saved_vars(ctx.session, &frame)
    failed := run.call_failed
    run.call_failed = false
    run.pc = frame.pc
    run.entered = true // the .Call node is finished; do not re-enter it
    if run.pc < 0 || run.pc >= len(run.steps) {
      return
    }
    step := &run.steps[run.pc]
    if failed {
      script_trace(ctx.session, step.id, .Note, "'%s' failed", step.call_name)
      if !script_take_fail_edge(ctx, step) {
        script_fail(ctx, step, fmt.tprintf("'%s' failed", step.call_name))
      }
      return
    }
    script_trace(ctx.session, step.id, .Step, "'%s' done", step.call_name)
    script_goto(run, step.jump)
  }
}

// Unwind every frame, restoring what each one saved. For the paths that abandon a run mid-region -
// `script stop`, `script reset`, a detach. Without it a chart stopped inside a sub-chart would leave
// the caller's variables holding the callee's arguments.
@(private = "file")
script_frames_unwind :: proc(session: ^Session) {
  run := &session.script
  for run.depth > 0 {
    run.depth -= 1
    if run.frames[run.depth].kind == .Call {
      script_restore_saved_vars(session, &run.frames[run.depth])
    }
    run.frames[run.depth] = {}
  }
  run.active_watcher = -1
  run.call_failed = false
}

// Write a list of remembered variables back into the session store. An unset variable comes back
// UNSET rather than as "", because `var_is` treats those differently on purpose (an unset variable
// equals nothing, not even "").
//
// Shared by the two things that put variables back: a call frame handing its caller's values back
// (script_restore_saved_vars) and a `from <node>` run restoring the snapshot that node last saw
// (script_snapshot_restore). Same rule, so it is written once.
script_apply_saved_vars :: proc(session: ^Session, saved: []Saved_Var) {
  for &sv in saved {
    name := script_saved_var_name(&sv)
    if name == "" {
      continue
    }
    if sv.had {
      engine.session_var_set(&session.eng, name, script_saved_var_value(&sv))
    } else {
      engine.session_var_set(&session.eng, name, "") // "" unsets - see engine/vars.odin
    }
  }
}

// Put back what a call frame borrowed.
@(private = "file")
script_restore_saved_vars :: proc(session: ^Session, frame: ^Suspended_Frame) {
  script_apply_saved_vars(session, frame.saved[:min(frame.saved_count, len(frame.saved))])
  frame.saved_count = 0
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
  script_snapshot_take(ctx.session, step.id)
}

// Remember what the chart's variables hold as control arrives at <node>, so a later `script run <x>
// from <node>` can put them back. Piggy-backs on script_note_line because that is already THE
// control-arrived-here hook - one call site covers every op that can be entered.
//
// MAIN PROGRAM ONLY. A node inside a called sub-chart or a borrowed watcher carries an id that
// script_append_region REMAPPED by an offset, matching no node in any document you can open - so its
// snapshot could never be asked for, and keeping it would evict rows that can.
//
// Allocation-free: a bounded number of map lookups and two `copy`s into fixed buffers, on the same
// tick budget as the trace ring.
@(private = "file")
script_snapshot_take :: proc(session: ^Session, node: Node_Id) {
  run := &session.script
  if node == 0 || run.snap_count == 0 || run.depth != 0 || run.pc >= run.main_len {
    return
  }
  row := script_snapshot_slot(&session.script_snapshots, node)
  row.node = node
  row.at = time.now()._nsec
  row.count = min(run.snap_count, len(row.vars))
  for i in 0 ..< row.count {
    name := script_saved_var_name(&run.snap_names[i])
    dst := &row.vars[i]
    dst^ = {}
    dst.name_len = copy(dst.name[:], name)
    if value, had := engine.session_var_get(&session.eng, name); had {
      dst.had = true
      dst.value_len = copy(dst.value[:], value)
    }
  }
}

// Drop the snapshot of every node the chart no longer has. Run at script_begin, against the program
// that is about to run, so an edit between two runs cannot leave a row behind pointing at a node that
// was deleted - and, more to the point, cannot let ed_next_id hand that id to a NEW node and have it
// inherit the old one's variables. (ed_next_id is max+1 over what exists, so a deleted top id does
// come back round.)
//
// The residual case - delete node 12, add a node that becomes 12, run from it inside the same
// session - is why the restore report prints the values and their age rather than restoring silently.
@(private = "file")
script_snapshots_prune :: proc(session: ^Session) {
  run := &session.script
  for &row in session.script_snapshots.rows {
    if row.node == 0 {
      continue
    }
    found := false
    for &step in run.steps {
      if step.id == row.node {
        found = true
        break
      }
    }
    if !found {
      row = {}
    }
  }
}

// Put node <node>'s remembered variables back. Returns the row it used, so the caller can report both
// what came back and when it was recorded - a snapshot from three runs ago is still worth having, but
// only if you can see that is what it is.
script_snapshot_restore :: proc(session: ^Session, node: Node_Id) -> ^Script_Var_Snapshot {
  row := script_snapshot_find(&session.script_snapshots, node)
  if row == nil {
    return nil
  }
  script_apply_saved_vars(session, row.vars[:min(row.count, len(row.vars))])
  return row
}

// The variables this program WRITES, collected once at script_begin. The same set the linter derives
// from a document (lint_variables_set), asked of the STEPS instead - the run has no document.
@(private = "file")
script_collect_snap_names :: proc(run: ^Script_Run) {
  run.snap_names = {}
  run.snap_count = 0
  add :: proc(run: ^Script_Run, name: string) {
    if name == "" || run.snap_count >= len(run.snap_names) {
      return
    }
    for i in 0 ..< run.snap_count {
      if script_saved_var_name(&run.snap_names[i]) == name {
        return
      }
    }
    run.snap_names[run.snap_count].name_len = copy(run.snap_names[run.snap_count].name[:], name)
    run.snap_count += 1
  }
  for &step in run.steps {
    #partial switch step.action.kind {
    case .Var, .Add, .Read_Value:
      add(run, script_var_name_of(step.action.strs[0]))
    }
    // A call's arguments are variables the callee is handed, so they are part of the state a node
    // downstream of it sees - the same reason lint_variables_set counts them as written.
    if step.op == .Call {
      for i in 0 ..< min(step.call_arg_count, len(step.call_args)) {
        add(run, step.call_args[i].name)
      }
    }
  }
}

script_fail :: proc(ctx: ^Behaviour_Context, step: ^Script_Step, why: string) {
  run := &ctx.session.script
  // INSIDE A SUB-CHART, a failure with nowhere to go fails the CALL, not the run. That is what makes
  // the call node's fail arm mean what every other block's fail arm means: "this did not work out, go
  // this way instead". Without it a sub-chart would be the one block in the tool that can take the whole
  // program down, and factoring a chart would change what it does.
  //
  // A WATCHER frame is deliberately not treated this way. An interrupt body that fails has no caller
  // that asked for it - it fired on its own - so the run ending is the honest outcome.
  if run.depth > 0 && run.frames[run.depth - 1].kind == .Call {
    script_trace(ctx.session, step.id, .Note, "%s - sub-chart fails", why)
    run.call_failed = true
    script_frame_pop(ctx)
    return
  }
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

// The same gate, over <doc> AND every sub-chart it can reach. Problems are prefixed with the document
// they came from, because "approach: needs findmove" is unhelpful when the approach is three calls down
// in a chart you did not write.
//
// Bounded by SUBCHART_MAX_DEPTH and by a visited set, so a cycle cannot spin here - script_expand_calls
// is what REPORTS the cycle, and this runs before it.
script_check_avail_deep :: proc(session: ^Session, doc: ^Behaviour_Doc) -> [dynamic]string {
  out := script_check_avail(session, doc.steps[:])
  seen := make(map[string]bool, 8, context.temp_allocator)
  defer delete(seen)
  seen[doc.name] = true

  walk :: proc(session: ^Session, doc: ^Behaviour_Doc, seen: ^map[string]bool, depth: int, out: ^[dynamic]string) {
    if depth > SUBCHART_MAX_DEPTH {
      return
    }
    for s in doc.steps {
      if s.op != .Call || s.call_name == "" || seen[s.call_name] {
        continue
      }
      seen[s.call_name] = true
      sub, ok := bhv_open(s.call_name)
      if !ok {
        continue // script_expand_calls reports the missing document; saying it twice helps nobody
      }
      defer behaviour_doc_free(&sub)
      for p in script_check_avail(session, sub.steps[:]) {
        append(out, fmt.tprintf("in sub-chart '%s': %s", s.call_name, p))
      }
      walk(session, &sub, seen, depth + 1, out)
    }
  }
  walk(session, doc, &seen, 0, &out)
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
  ignore_collision := false,
) {
  script_run_free(&session.script)
  run := &session.script
  run.steps = steps
  run.watchers = make([dynamic]Script_Watcher)
  // Named BEFORE the appending passes, because two of them ask who is running: the self-borrow guard in
  // script_attach_doc_watchers, and the cycle check in script_expand_calls, which starts its path here.
  // (It used to be assigned at the bottom, which quietly made that guard compare against "".)
  run.name = strings.clone(name)
  // "Is this a hunt chart" - see hunt_steering_on. Asked of the steps once, here, rather than per pick.
  run.sidestep_chart = false
  for step in run.steps {
    if step.op == .Action && step.action.kind == .Approach && step.action.nums[2] != 0 {
      run.sidestep_chart = true
      break
    }
  }
  // The declared one, from the document - see reach_gate_active. It sits beside sidestep_chart because
  // the two answer the same question from opposite ends: that one INFERS "this chart steps around
  // obstacles, so relax the gate", this one is told "this map's obstacles are not real, so drop it".
  run.ignore_collision = ignore_collision
  if kind == .Interrupt {
    // A watcher's body, run on its own because its trigger fired. NOTHING is armed for it: not the
    // globals, not what the host borrowed, and not even the document's own `on` nodes. <entry> already
    // names the body, so the body IS the main program here - hoisting it into a region as well would
    // mean the run started by falling off the end of an empty program and only worked because the
    // watcher happened to fire on the first tick. And an escape that can be interrupted by the same
    // escape re-fires on its own still-true trigger forever; the frame stack only caps nesting once inside.
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
  // Sub-charts LAST of the appending passes, and after the watcher regions on purpose: a borrowed
  // watcher's body may itself call one, and by now it is in the array to be found.
  if problems := script_expand_calls(session, run); len(problems) > 0 {
    fmt.eprintfln("script: '%s' cannot start - %d problem(s) with the sub-charts it calls:", name, len(problems))
    for p in problems {
      fmt.eprintfln("  %s", p)
    }
    script_run_free(run)
    return
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
  run.mode = mode
  run.active = true
  run.pc = start
  run.entry_pc = start // where a Loop-mode wrap and `script reset` go back to
  run.entered = false
  run.paused = false
  run.depth = 0
  run.frames = {}
  run.call_failed = false
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
  // The snapshots, though, deliberately SURVIVE a re-run of the same chart - that is the whole point
  // of them (you run it from the top once, then start from the middle as often as you like). They
  // are dropped only when a different chart takes over, because node ids mean nothing across
  // documents. Collected after the appending passes, so a borrowed watcher's variables count too.
  script_collect_snap_names(run)
  if script_snapshots_chart(&session.script_snapshots) != name {
    script_snapshots_reset(&session.script_snapshots, name)
  } else {
    script_snapshots_prune(session)
  }
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
  base, ok := script_append_region(run, &doc)
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

// Append <doc>'s program to <run> as REGION code, and return the id OFFSET it was pasted at.
//
// The ids have to be REMAPPED. Two independently authored charts both start numbering at 1, so
// pasting one into the other verbatim would give duplicate ids - and script_resolve_ids maps id ->
// index, so the second copy's edges would silently retarget onto the first's nodes. Offsetting every
// id (and every edge that names one) by the host's high-water mark keeps each region's edges pointing
// inside itself. The caller adds the same offset to find the entry it wants.
//
// The doc is PARTITIONED on the way in, by the same proc a run's own steps go through, so each of its
// watcher bodies arrives as its own terminated block. Without that, one borrowed watcher's body would
// walk off its end straight into the next one's.
//
// TWO CALLERS, one mechanism: a borrowed document's watchers and a called sub-chart. They differ only
// in what points at the pasted code afterwards - a Script_Watcher.entry, or a .Call node's call_entry.
@(private = "file")
script_append_region :: proc(run: ^Script_Run, doc: ^Behaviour_Doc, partition := true) -> (base: Node_Id, ok: bool) {
  if len(doc.steps) == 0 {
    return 0, false
  }
  if partition {
    script_partition_watcher_bodies(&doc.steps, doc.entry)
  }
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
    // A call inside the pasted code keeps its OWN name and arguments; its call_entry_id is stamped by
    // the recursion in script_expand_calls, which runs over the appended steps after this returns.
    c.call_name = strings.clone(s.call_name)
    c.call_entry_id = 0
    for a, i in s.call_args {
      c.call_args[i].name = strings.clone(a.name)
      c.call_args[i].value = strings.clone(a.value)
    }
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

// --- sub-chart calls -------------------------------------------------------------------------------
//
// Paste in every sub-chart the program calls, so a call is a jump into program text that is already
// there rather than a load in the middle of a run. Nothing is read from disk once a run has started -
// which is the same guarantee `uses` gives, and is what makes a run reproducible while you are editing
// the sub-chart in another window.
//
// ONE REGION PER DOCUMENT, not per call site. Two call sites of the same sub-chart share its steps and
// therefore its per-node Step_Scratch, which is only safe because recursion is refused below: at most
// one activation of a region is ever live. Per-call-site copies would lift that restriction at the cost
// of duplicating the callee once per call, and nothing wants recursion badly enough to pay for it.

// Everything script_expand_calls needs to carry through the recursion. A struct because the recursive
// call already has five arguments and half of them are bookkeeping the caller should not have to spell.
@(private = "file")
Expand_Ctx :: struct {
  session:  ^Session,
  run:      ^Script_Run,
  // Where each already-pasted document's entry ended up, by name. This is the dedup.
  entry_of: map[string]Node_Id,
  // The names on the path from the main program down to here, for the cycle message. Not a set: the
  // point of the error is to be able to print the loop in the order you would walk it.
  path:     [dynamic]string,
  problems: [dynamic]string,
}

// Expand every call reachable from the program, depth first. Returns the problems (temp-allocated);
// a non-empty list means the run must not start.
@(private = "file")
script_expand_calls :: proc(session: ^Session, run: ^Script_Run) -> []string {
  ctx := Expand_Ctx {
    session  = session,
    run      = run,
    entry_of = make(map[string]Node_Id, 8, context.temp_allocator),
    path     = make([dynamic]string, 0, SUBCHART_MAX_DEPTH + 1, context.temp_allocator),
    problems = make([dynamic]string, context.temp_allocator),
  }
  append(&ctx.path, run.name)
  // [0, len) over the WHOLE array, not just the main program: a borrowed watcher's body is allowed to
  // call a sub-chart too, and it was already appended by the time we get here.
  script_expand_calls_over(&ctx, 0, len(run.steps), 0)
  return ctx.problems[:]
}

// Expand the calls in steps[from:to]. <depth> is how many calls deep this range already is.
//
// The range is explicit because expanding APPENDS: each pasted document lands past `to`, and its own
// calls are then expanded by the recursive call over exactly that new range. Walking to len(run.steps)
// instead would re-visit nodes whose entry is already stamped and, worse, lose track of which depth
// they are at.
@(private = "file")
script_expand_calls_over :: proc(ctx: ^Expand_Ctx, from, to: int, depth: int) {
  for i in from ..< to {
    if ctx.run.steps[i].op != .Call {
      continue
    }
    name := ctx.run.steps[i].call_name
    if name == "" {
      append(&ctx.problems, "a call node names no sub-chart")
      continue
    }
    if depth >= SUBCHART_MAX_DEPTH {
      append(&ctx.problems, fmt.tprintf(
        "'%s' calls '%s' more than %d deep - flatten one of them",
        ctx.path[len(ctx.path) - 1], name, SUBCHART_MAX_DEPTH,
      ))
      continue
    }
    // Recursion, direct or indirect. Refused rather than depth-limited because regions are shared per
    // document: a second live activation would be walking the same nodes with the first one's scratch.
    if slice.contains(ctx.path[:], name) {
      b := strings.builder_make(context.temp_allocator)
      for p in ctx.path {
        fmt.sbprintf(&b, "%s -> ", p)
      }
      strings.write_string(&b, name)
      append(&ctx.problems, fmt.tprintf("'%s' would call itself: %s", name, strings.to_string(b)))
      continue
    }
    // Already pasted by another call site - just point at it. Deliberately BEFORE the file read, so a
    // chart calling the same helper ten times opens it once.
    if entry, done := ctx.entry_of[name]; done {
      ctx.run.steps[i].call_entry_id = entry
      continue
    }
    doc, dok := bhv_open(name)
    if !dok {
      append(&ctx.problems, fmt.tprintf("'%s' calls '%s', which does not exist", ctx.path[len(ctx.path) - 1], name))
      continue
    }
    defer behaviour_doc_free(&doc)
    if why, bad := subchart_callable_why(&doc); bad {
      append(&ctx.problems, fmt.tprintf("'%s' cannot be called: %s", name, why))
      continue
    }
    // NOT partitioned: a sub-chart may not declare watchers (subchart_callable_why refuses one), so
    // there are no bodies to separate, and partitioning would reorder the steps for nothing.
    region_start := len(ctx.run.steps)
    base, ok := script_append_region(ctx.run, &doc, partition = false)
    if !ok {
      append(&ctx.problems, fmt.tprintf("'%s' has no blocks to run", name))
      continue
    }
    region_end := len(ctx.run.steps)
    // The entry BY IDENTITY, remapped. `entry == 0` means "the first step", which after the paste is
    // the first node of the region rather than the first node of the run.
    entry_id := doc.entry != 0 ? doc.entry + base : ctx.run.steps[region_start].id
    ctx.run.steps[i].call_entry_id = entry_id
    ctx.entry_of[strings.clone(name, context.temp_allocator)] = entry_id
    append(&ctx.path, name)
    script_expand_calls_over(ctx, region_start, region_end, depth + 1)
    pop(&ctx.path)
  }
}

// Why <doc> may not be used as a sub-chart, or ok. THE one statement of the restrictions - the linter
// reports them per-document while you author, and this refuses them at run start; two lists would be
// two chances to disagree about what a sub-chart is.
subchart_callable_why :: proc(doc: ^Behaviour_Doc) -> (why: string, bad: bool) {
  if !doc.is_subchart {
    return "it is a chart, not a block - tick 'Use as a block' in its chart options", true
  }
  if len(doc.steps) == 0 {
    return "it has no blocks", true
  }
  if doc.mode == .Loop {
    return "it loops, so it would never return - set its mode to 'once'", true
  }
  for s in doc.steps {
    if s.op == .On {
      return "it declares a watcher, and a watcher belongs to the chart you RUN - move the 'on' node to the caller", true
    }
  }
  if len(doc.uses) > 0 {
    return "it borrows watchers with 'uses', and a watcher belongs to the chart you RUN", true
  }
  return "", false
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
//   - a body runs off its end -> depth > 0        -> script_frame_pop. Also exactly right.
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
// ONE SHAPE OF BODY. An `.On` NAMES its subgraph, which script_partition_watcher_bodies has already
// moved past main_len; the watcher just points at it.
//
// There used to be a second shape - an `.On` carrying a single action and naming no body - and this
// proc synthesized the missing two-step region for it at run time. That made the shape RUNNABLE while
// every arming path still refused it (they all require goto_id != 0), so a perfectly good interrupt
// file could not be switched on and the browser's checkbox appeared to fight you. It is now upgraded
// on the way in instead, by script_materialize_watcher_bodies, so a document never holds it and there
// is nothing left to synthesize here.
@(private = "file")
script_build_irq_regions :: proc(run: ^Script_Run) {
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
      condition = script_condition_clone(s.condition),
      src       = strings.clone(s.src),
      entry     = -1,
    }
    // entry stays -1 when nothing is wired: the edge still counts as serviced, so a bodyless watcher
    // latches instead of re-firing every tick. script_lint warns about one.
    if s.goto_id != 0 {
      if e, ok := index_of[s.goto_id]; ok {
        w.entry = e
      }
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

  // Unwound, not just zeroed: a rewind from inside a sub-chart owes the caller its variables back.
  script_frames_unwind(session)
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
  case "snapshot", "snapshots", "snap":
    script_cmd_snapshot(session, args[1:])
  case "lint", "check":
    script_cmd_lint(session, args[1:])
  case "subchart", "block":
    script_cmd_subchart(args[1:])
  case "nocollision", "ignorecollision":
    script_cmd_ignore_collision(args[1:])
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
      run := &session.script
      // Name the node when it is NOT the chart's start node. "rewound to the start" is a lie on a
      // debug run - it goes back to where that run began, which is the whole point of `from`.
      target := "the start"
      if run.debug_entry && run.entry_pc >= 0 && run.entry_pc < len(run.steps) {
        target = fmt.tprintf("node %d, where this run started", u32(run.steps[run.entry_pc].id))
      }
      fmt.printfln("script: '%s' rewound to %s%s.", run.name, target, run.paused ? " (still paused)" : "")
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
    fmt.eprintln("  status | blocks | list | show <name> | run <name> [once|loop] [step] [from <node>] | stop")
    fmt.eprintln("  pause | resume | reset | step [off] | trace [n|all|clear] | lint [name]")
    fmt.eprintln("  snapshot [clear] - what each node's variables held, for 'run ... from <node>'")
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
  subchart_registry_refresh(force = true)
  blocks := len(subchart_registry_rows())
  fmt.printfln(
    "  behaviours: %d in Odin (flyff/behaviours.odin) + %d saved in %s - 'script list'",
    len(BEHAVIOURS), len(saved), bhv_dir_path(),
  )
  // Counted separately from the saved total it is part of: a block is not something you can run, so a
  // "12 saved" that turns out to be 3 charts and 9 blocks would misdescribe what is there.
  if blocks > 0 {
    fmt.printfln("    ... %d of those are BLOCKS (sub-charts you place in a chart) - 'script list' names them", blocks)
  }
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
    what := run.paused ? "PAUSED" : (script_frame_in_watcher(run) ? "INTERRUPT" : (run.depth > 0 ? "IN SUB-CHART" : "RUNNING"))
    // "from node N" belongs on the ONE-LINE status, not only in the detail: a chart that skipped its
    // own setup is a different chart, and a status line that hides that is how you spend ten minutes
    // debugging the run instead of the bug.
    from := ""
    if run.debug_entry && run.entry_pc >= 0 && run.entry_pc < len(run.steps) {
      from = fmt.tprintf(" from node %d", u32(run.steps[run.entry_pc].id))
    }
    state = fmt.tprintf("%s '%s'%s step %d/%d", what, run.name, from, min(run.pc + 1, run.main_len), run.main_len)
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
  // A DEBUG ENTRY changes two things you would otherwise have to discover by being surprised: half the
  // chart never runs, and the rewind button does not go to the top.
  if run.debug_entry && run.entry_pc >= 0 && run.entry_pc < len(run.steps) {
    fmt.printfln(
      "  started at node %d, not the chart's start node - 'script reset' rewinds there and %s.",
      u32(run.steps[run.entry_pc].id),
      run.mode == .Loop ? "'loop' wraps there" : "the nodes above it never run",
    )
  }
  // The whole stack, innermost last, so "why is it not on the step I expect" has an answer that names
  // every region between here and the main program.
  for i in 0 ..< min(run.depth, len(run.frames)) {
    f := run.frames[i]
    switch f.kind {
    case .Watcher:
      fmt.printfln("  ^ inside an INTERRUPT; what it suspended is at step %d and resumes when it returns.", f.pc + 1)
    case .Call:
      name := f.pc >= 0 && f.pc < len(run.steps) ? run.steps[f.pc].call_name : "?"
      fmt.printfln("  ^ inside sub-chart '%s', called from step %d.", name, f.pc + 1)
    }
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
  // The catalog you WROTE, after the one that shipped. Listed here and not only in `script list`
  // because this command answers "what can a chart do", and a block you made is an answer to that.
  subchart_registry_refresh(force = true)
  if blocks := subchart_registry_rows(); len(blocks) > 0 {
    fmt.println("YOUR BLOCKS (sub-charts - each one is a whole chart, run as a single node):")
    for &info in blocks {
      fmt.printfln("  [OK] %-28s %s", subchart_signature(info.name, subchart_info_params(&info)), info.desc)
    }
    fmt.println("       'script subchart <name>' makes a saved chart into one, or takes it back.")
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
  script_selftest_alert()
  // Last, and called from here rather than chained off the end of the others, because they are the
  // sections that need the SESSION - they write and read real variables.
  script_selftest_coord(session)
  script_selftest_subchart(session)
  script_selftest_entry(session)
}

// Starting a run somewhere other than the top: `script run <x> from <node>`.
//
// The three halves that can each be right on their own and still add up to a lie - the pc lands on
// the node, the variables that node last saw come back, and what is STILL missing gets named - plus
// the two entries that must be refused.
@(private = "file")
script_selftest_entry :: proc(session: ^Session) {
  fmt.println("  --- starting from a node ---")
  fails := 0
  PREFIX :: "zz_selftest_from_"
  chart :: PREFIX + "chain"
  irq :: PREFIX + "irq"

  written := make([dynamic]string, context.temp_allocator)
  defer {
    for n in written {
      os.remove(bhv_file_path(n))
    }
    subchart_registry_refresh(force = true)
  }
  add :: proc(written: ^[dynamic]string, name: string, body: string, fails: ^int) -> bool {
    os.make_directory(bhv_dir_path())
    if err := os.write_entire_file(bhv_file_path(name), transmute([]byte)body); err != nil {
      fmt.eprintfln("  FAIL: could not write the fixture '%s' (%v)", name, err)
      fails^ += 1
      return false
    }
    append(written, name)
    return true
  }

  // Two setup nodes, then two nodes that READ what they set. Starting at node 3 skips both setters,
  // which is exactly the shape the feature exists for.
  ok := add(&written, chart, `# memscan behaviour
desc from-node fixture
mode once
entry 1
node 1 action 0 0 goto=2
  do var se_home 6800
node 2 action 0 120 goto=3
  do var se_lane north
node 3 action 0 240 goto=4
  do var se_seen @se_home
node 4 action 0 360
  do var se_done @se_lane
`, &fails)
  // Node 1 is a watcher and node 3 is its body; node 2 is the whole main program.
  ok &= add(&written, irq, `# memscan behaviour
desc a watcher and its body
mode once
entry 2
node 1 on 0 0 goto=3
  if always
node 2 action 0 120
  do var se_main 1
node 3 action 0 240
  do var se_body 1
`, &fails)
  if !ok {
    return
  }

  // Drive a run to completion the way the sub-chart section does: synchronously, so the suite never
  // depends on the watcher thread getting scheduled.
  drain :: proc(session: ^Session) {
    ctx := Behaviour_Context {
      session = session,
      now     = time.now()._nsec,
      board   = &session.bh_board,
    }
    for _ in 0 ..< 400 {
      if !session.script.active {
        return
      }
      ctx.now = time.now()._nsec
      script_walk_n(&ctx, 1)
    }
  }
  clear_fixture_vars :: proc(session: ^Session) {
    for name in ([?]string{"se_home", "se_lane", "se_seen", "se_done", "se_main", "se_body"}) {
      engine.session_var_set(&session.eng, name, "")
    }
  }

  script_stop(session)
  clear_fixture_vars(session)

  // 1. A full lap from the top - this is what RECORDS the snapshots everything below reads.
  script_cmd_run(session, []string{chart})
  if !session.script.active {
    fmt.eprintfln("  FAIL: '%s' refused to start from the top", chart)
    fails += 1
    return
  }
  drain(session)
  if v, _ := engine.session_var_get(&session.eng, "se_seen"); v != "6800" {
    fmt.eprintfln("  FAIL: the full lap should have left se_seen=6800, got '%s'", v)
    fails += 1
  }

  // 2. From node 3, with the setters skipped. The snapshot has to put se_home back, or the `var
  // se_seen @se_home` on node 3 stores the literal text "@se_home" and the chart quietly means
  // something else.
  script_stop(session)
  clear_fixture_vars(session)
  script_cmd_run(session, []string{chart, "from", "3", "step"})
  if !session.script.active {
    fmt.eprintfln("  FAIL: '%s' refused to start from node 3", chart)
    fails += 1
  } else {
    run := &session.script
    if run.pc < 0 || run.pc >= len(run.steps) || run.steps[run.pc].id != 3 {
      fmt.eprintfln("  FAIL: started at node %d, want node 3", run.pc >= 0 && run.pc < len(run.steps) ? u32(run.steps[run.pc].id) : 0)
      fails += 1
    }
    if run.entry_pc != run.pc {
      fmt.eprintfln("  FAIL: entry_pc is %d but pc is %d - 'loop' and 'script reset' would go somewhere else", run.entry_pc, run.pc)
      fails += 1
    }
    if !run.debug_entry {
      fmt.eprintln("  FAIL: the run does not know it started at a debug node, so the status will not say so")
      fails += 1
    }
    // The restore happened at START, before a single step ran.
    if v, _ := engine.session_var_get(&session.eng, "se_home"); v != "6800" {
      fmt.eprintfln("  FAIL: the snapshot did not put se_home back (got '%s')", v)
      fails += 1
    }
    // ... and rewinding goes to the DEBUG node, not to the top.
    run.stepping = false
    drain(session)
    script_cmd_run(session, []string{chart, "from", "3", "step"})
    if session.script.active {
      script_reset(session)
      r := &session.script
      if r.pc < 0 || r.pc >= len(r.steps) || r.steps[r.pc].id != 3 {
        fmt.eprintfln("  FAIL: 'script reset' on a from-node run went to node %d, want node 3", r.pc >= 0 && r.pc < len(r.steps) ? u32(r.steps[r.pc].id) : 0)
        fails += 1
      }
    }
  }
  script_stop(session)

  // 3. The GAP: with no snapshot to lean on, the two variables the skipped nodes would have set are
  // named, along with which node sets each. This is the static half, so it is asked of the document.
  {
    doc, dok := bhv_open(chart)
    if !dok {
      fmt.eprintfln("  FAIL: '%s' would not load back", chart)
      fails += 1
    } else {
      defer behaviour_doc_free(&doc)
      gaps := script_entry_gap(&doc, 3)
      Want :: struct {
        name:   string,
        set_by: Node_Id,
      }
      want := [?]Want{{"se_home", 1}, {"se_lane", 2}}
      if len(gaps) != len(want) {
        fmt.eprintfln("  FAIL: starting at node 3 should be missing %d variable(s), the gap report found %d", len(want), len(gaps))
        for g in gaps {
          fmt.eprintfln("        @%s (set by node %d)", g.name, u32(g.set_by))
        }
        fails += 1
      }
      for g in gaps {
        known := false
        for w in want {
          if w.name != g.name {
            continue
          }
          known = true
          if g.set_by != w.set_by {
            fmt.eprintfln("  FAIL: @%s is set by node %d, the gap report blamed node %d", g.name, u32(w.set_by), u32(g.set_by))
            fails += 1
          }
        }
        if !known {
          fmt.eprintfln("  FAIL: the gap report named @%s, which nothing above node 3 sets", g.name)
          fails += 1
        }
      }
      // A start node that IS the entry has nothing missing - the report must not cry wolf on the
      // ordinary case, which is the whole chart running as written.
      if from_top := script_entry_gap(&doc, doc.entry); len(from_top) != 0 {
        fmt.eprintfln("  FAIL: running from the chart's own start node reported %d missing variable(s)", len(from_top))
        fails += 1
      }
    }
  }

  // 4. The two refusals. Control can never ARRIVE at either of these first, so offering to start there
  // would be offering a run that cannot happen.
  {
    doc, dok := bhv_open(irq)
    if !dok {
      fmt.eprintfln("  FAIL: '%s' would not load back", irq)
      fails += 1
    } else {
      defer behaviour_doc_free(&doc)
      if script_entry_node_ok(&doc, 1) {
        fmt.eprintln("  FAIL: node 1 is a watcher and was accepted as a start node")
        fails += 1
      }
      if script_entry_node_ok(&doc, 3) {
        fmt.eprintln("  FAIL: node 3 is a watcher's body and was accepted as a start node")
        fails += 1
      }
      if !script_entry_node_ok(&doc, 2) {
        fmt.eprintln("  FAIL: node 2 is ordinary main-program text and was refused as a start node")
        fails += 1
      }
      if script_entry_node_ok(&doc, 99) {
        fmt.eprintln("  FAIL: a node that does not exist was accepted as a start node")
        fails += 1
      }
    }
  }

  script_stop(session)
  clear_fixture_vars(session)
  if fails == 0 {
    fmt.println("  PASS: a run starts at any node, restores what that node last saw, names what is still missing, and refuses watchers")
  } else {
    fmt.eprintfln("  %d from-node check(s) failed", fails)
  }
}

// Sub-charts: the file format, the expansion, and what a call does to the caller's variables.
//
// Everything here is built and torn down in a temp directory of its own making - real .bhv files,
// because the feature IS cross-document and a test that skipped the file would skip the half that
// carries the parameter declarations. The names all start with the same prefix and are deleted at the
// end, so running the suite twice cannot leave a chart behind for `script list` to show.
@(private = "file")
script_selftest_subchart :: proc(session: ^Session) {
  fmt.println("  --- sub-charts ---")
  fails := 0
  PREFIX :: "zz_selftest_"

  write :: proc(name: string, body: string, fails: ^int) -> bool {
    os.make_directory(bhv_dir_path())
    if err := os.write_entire_file(bhv_file_path(name), transmute([]byte)body); err != nil {
      fmt.eprintfln("  FAIL: could not write the fixture '%s' (%v)", name, err)
      fails^ += 1
      return false
    }
    return true
  }
  // Fixtures are deleted whatever happens - a failure part-way through must not leave three charts in
  // the user's behaviours folder.
  written := make([dynamic]string, context.temp_allocator)
  defer {
    for n in written {
      os.remove(bhv_file_path(n))
    }
    subchart_registry_refresh(force = true)
  }
  add :: proc(written: ^[dynamic]string, name: string, body: string, fails: ^int) -> bool {
    if !write(name, body, fails) {
      return false
    }
    append(written, name)
    return true
  }

  // CONSTANTS, so the fixture bodies below can be built by concatenating literals - the bodies name
  // each other, and Odin only folds a concatenation of constants.
  leaf :: PREFIX + "leaf"
  mid :: PREFIX + "mid"
  host :: PREFIX + "host"
  loopy :: PREFIX + "loopy"
  cyc_a :: PREFIX + "cyc_a"
  cyc_b :: PREFIX + "cyc_b"
  slow :: PREFIX + "slow"
  stopper :: PREFIX + "stopper"

  ok := true
  ok &= add(&written, leaf, `# memscan behaviour
subchart
desc innermost block
mode once
entry 1
param who mob 'Monster' 'which monster this pass is about'
node 1 action 0 0
  do var leaf_saw @who
`, &fails)
  ok &= add(&written, mid, `# memscan behaviour
subchart
desc calls the leaf
mode once
entry 1
param who mob 'Monster' 'passed straight down'
node 1 call 0 0 goto=2
  call ` + leaf + `
  arg who @who
node 2 action 0 120
  do var mid_saw @leaf_saw
`, &fails)
  ok &= add(&written, host, `# memscan behaviour
desc calls mid twice
mode once
entry 1
node 1 action 0 0 goto=2
  do var who HOST_OWN
node 2 call 0 120 goto=3
  call ` + mid + `
  arg who Aibatt
node 3 action 0 240 goto=4
  do var first @leaf_saw
node 4 call 0 360 goto=5
  call ` + mid + `
  arg who Mushpang
node 5 action 0 480
  do var second @leaf_saw
`, &fails)
  ok &= add(&written, loopy, `# memscan behaviour
subchart
desc a block that loops, which is not allowed
mode loop
entry 1
node 1 action 0 0
  do wait 0
`, &fails)
  ok &= add(&written, cyc_a, `# memscan behaviour
subchart
desc half of a cycle
mode once
entry 1
node 1 call 0 0
  call ` + cyc_b + `
`, &fails)
  ok &= add(&written, cyc_b, `# memscan behaviour
subchart
desc the other half
mode once
entry 1
node 1 call 0 0
  call ` + cyc_a + `
`, &fails)
  // A block that parks in a long wait, so the run can be stopped from INSIDE it.
  ok &= add(&written, slow, `# memscan behaviour
subchart
desc parks in a wait so a stop can land mid-call
mode once
entry 1
param who mob 'Monster' 'bound for as long as the wait lasts'
node 1 action 0 0
  do wait 600
`, &fails)
  ok &= add(&written, stopper, `# memscan behaviour
desc gets stopped while inside a call
mode once
entry 1
node 1 action 0 0 goto=2
  do var who CALLER_OWN
node 2 call 0 120
  call ` + slow + `
  arg who CALLEE_OWN
`, &fails)
  if !ok {
    return
  }
  subchart_registry_refresh(force = true)

  // 1. The FORMAT round-trips: subchart / desc / param on the way in, call / arg on the way out.
  {
    doc, dok := bhv_open(mid)
    if !dok {
      fmt.eprintfln("  FAIL: '%s' would not load back", mid)
      fails += 1
    } else {
      defer behaviour_doc_free(&doc)
      if !doc.is_subchart {
        fmt.eprintfln("  FAIL: '%s' lost its 'subchart' flag through save/load", mid)
        fails += 1
      }
      if doc.desc != "calls the leaf" {
        fmt.eprintfln("  FAIL: '%s' description came back as '%s'", mid, doc.desc)
        fails += 1
      }
      if doc.param_count != 1 || doc.params[0].name != "who" || doc.params[0].kind != .Mob {
        fmt.eprintfln("  FAIL: '%s' parameter did not survive the load (%d declared)", mid, doc.param_count)
        fails += 1
      } else if doc.params[0].title != "Monster" || doc.params[0].help != "passed straight down" {
        fmt.eprintfln("  FAIL: '%s' parameter lost its title or help", mid)
        fails += 1
      }
      // The call node, and its argument. Both come off payload LINES rather than the node line, which
      // is the part a `key=value` shape would have got wrong for a value with a space in it.
      found := false
      for s in doc.steps {
        if s.op != .Call {
          continue
        }
        found = true
        if s.call_name != leaf {
          fmt.eprintfln("  FAIL: the call in '%s' names '%s', want '%s'", mid, s.call_name, leaf)
          fails += 1
        }
        if s.call_arg_count != 1 || s.call_args[0].name != "who" || s.call_args[0].value != "@who" {
          fmt.eprintfln("  FAIL: the call in '%s' lost its argument", mid)
          fails += 1
        }
      }
      if !found {
        fmt.eprintfln("  FAIL: '%s' has no call node after a load - the 'call' line was dropped", mid)
        fails += 1
      }
      // ... and back OUT again. The load half above proves the reader; this proves the WRITER, which is
      // the half a hand-written fixture cannot exercise - every chart the editor saves goes through it.
      // Compared as text rather than field by field, because the file is the contract.
      b := strings.builder_make(context.temp_allocator)
      bhv_serialize(&doc, &b)
      again, aok := bhv_deserialize(mid, strings.to_string(b))
      if !aok {
        fmt.eprintfln("  FAIL: what bhv_serialize wrote for '%s' would not load back", mid)
        fails += 1
      } else {
        defer behaviour_doc_free(&again)
        b2 := strings.builder_make(context.temp_allocator)
        bhv_serialize(&again, &b2)
        if strings.to_string(b) != strings.to_string(b2) {
          fmt.eprintfln("  FAIL: '%s' does not survive a second save/load:\n--- once ---\n%s--- twice ---\n%s", mid, strings.to_string(b), strings.to_string(b2))
          fails += 1
        }
      }
    }
  }

  // 2. RUNNING it: two calls, two levels, and the caller's own `who` untouched afterwards.
  //
  // Run synchronously here rather than by handing it to the watcher tick: the suite is headless and
  // must not depend on a thread getting scheduled. script_walk_n is the same walker either way.
  engine.session_var_set(&session.eng, "leaf_saw", "")
  engine.session_var_set(&session.eng, "who", "")
  {
    doc, dok := bhv_open(host)
    if !dok {
      fmt.eprintfln("  FAIL: '%s' would not load", host)
      fails += 1
    } else {
      script_begin(session, host, doc.steps, doc.mode, doc.entry, .Chart, doc.uses[:])
      doc.steps = nil // script_begin took ownership
      defer behaviour_doc_free(&doc)
      if !session.script.active {
        fmt.eprintfln("  FAIL: '%s' refused to start", host)
        fails += 1
      } else {
        ctx := Behaviour_Context {
          session = session,
          now     = time.now()._nsec,
          board   = &session.bh_board,
        }
        // Generous, and bounded: the program is ~10 instructions, so anything near this cap means it
        // is looping rather than finishing.
        for _ in 0 ..< 200 {
          if !session.script.active {
            break
          }
          ctx.now = time.now()._nsec
          script_walk_n(&ctx, 8)
        }
        if session.script.active {
          fmt.eprintfln("  FAIL: '%s' did not finish - a call never returned", host)
          fails += 1
          script_stop(session)
        }
      }
    }
  }
  expect :: proc(session: ^Session, name, want: string, fails: ^int) {
    got, _ := engine.session_var_get(&session.eng, name)
    if got != want {
      fmt.eprintfln("  FAIL: after the run, %s = '%s', want '%s'", name, got, want)
      fails^ += 1
    }
  }
  expect(session, "first", "Aibatt", &fails) // the argument reached two levels down
  expect(session, "second", "Mushpang", &fails) // ... and the second call bound its own
  expect(session, "mid_saw", "Mushpang", &fails) // the callee saw what the leaf wrote
  // THE ownership rule: `who` is a parameter of the block, and the caller had its own. It must come
  // back. Without the save/restore in script_take_call this reads "Mushpang".
  expect(session, "who", "HOST_OWN", &fails)

  // 3. Expansion produced ONE region per document, with no id collisions. Ids are what edges resolve
  // through, so a duplicate would silently retarget a jump into the wrong copy.
  {
    doc, dok := bhv_open(host)
    if dok {
      script_begin(session, host, doc.steps, doc.mode, doc.entry, .Chart, doc.uses[:])
      doc.steps = nil
      defer behaviour_doc_free(&doc)
      run := &session.script
      seen := make(map[Node_Id]bool, len(run.steps), context.temp_allocator)
      defer delete(seen)
      dupes := 0
      for s in run.steps {
        if s.id != 0 && seen[s.id] {
          dupes += 1
        }
        seen[s.id] = true
      }
      if dupes > 0 {
        fmt.eprintfln("  FAIL: %d duplicate node id(s) after expanding the calls", dupes)
        fails += 1
      }
      calls, unresolved := 0, 0
      for s in run.steps {
        if s.op != .Call {
          continue
        }
        calls += 1
        if s.call_entry < 0 || s.call_entry >= len(run.steps) {
          unresolved += 1
        }
      }
      // Three call sites: two in the host, one in the single pasted copy of mid.
      if calls != 3 {
        fmt.eprintfln("  FAIL: expanded program has %d call node(s), want 3 (two in the host, one in the single copy of the middle block)", calls)
        fails += 1
      }
      if unresolved > 0 {
        fmt.eprintfln("  FAIL: %d call node(s) resolved to nothing", unresolved)
        fails += 1
      }
      script_stop(session)
    }
  }

  // 4. The refusals. Each must be caught BEFORE the run starts, and each for its own reason.
  refuse :: proc(session: ^Session, name: string, what: string, fails: ^int) {
    doc, dok := bhv_open(name)
    if !dok {
      fmt.eprintfln("  FAIL: fixture '%s' would not load", name)
      fails^ += 1
      return
    }
    script_begin(session, name, doc.steps, doc.mode, doc.entry, .Chart, doc.uses[:])
    doc.steps = nil
    defer behaviour_doc_free(&doc)
    if session.script.active {
      fmt.eprintfln("  FAIL: '%s' started, but %s", name, what)
      fails^ += 1
      script_stop(session)
    }
  }
  refuse(session, cyc_a, "it calls itself through another block", &fails)

  // 5. STOPPED MID-CALL. `script stop`, a detach, an interrupt that ends the program - every one of
  // them leaves the run inside the callee, still owing the caller the values it borrowed. This is the
  // half script_reset had and script_teardown did not, so a stopped chart left the caller's variables
  // holding the callee's arguments.
  engine.session_var_set(&session.eng, "who", "")
  {
    doc, dok := bhv_open(stopper)
    if !dok {
      fmt.eprintfln("  FAIL: fixture '%s' would not load", stopper)
      fails += 1
    } else {
      script_begin(session, stopper, doc.steps, doc.mode, doc.entry, .Chart, doc.uses[:])
      doc.steps = nil
      defer behaviour_doc_free(&doc)
      ctx := Behaviour_Context {
        session = session,
        now     = time.now()._nsec,
        board   = &session.bh_board,
      }
      // Two instructions in: the `var`, then the call, which parks on a ten-minute wait.
      script_walk_n(&ctx, 4)
      if session.script.depth == 0 {
        fmt.eprintfln("  FAIL: the run was not inside the call after four instructions - the fixture is wrong")
        fails += 1
      }
      if got, _ := engine.session_var_get(&session.eng, "who"); got != "CALLEE_OWN" {
        fmt.eprintfln("  FAIL: inside the call, who = '%s', want 'CALLEE_OWN'", got)
        fails += 1
      }
      script_stop(session)
      expect(session, "who", "CALLER_OWN", &fails)
    }
  }
  // A loop-mode block: refused as a CALLEE (it would never return), while remaining a perfectly
  // runnable chart on its own - which is why this checks the call rather than the run.
  {
    doc, dok := bhv_open(loopy)
    if dok {
      defer behaviour_doc_free(&doc)
      if _, bad := subchart_callable_why(&doc); !bad {
        fmt.eprintfln("  FAIL: a block set to 'loop' was accepted as callable - it would never return")
        fails += 1
      }
    }
  }
  // And the linter has to say so too, on the document itself - otherwise the first you hear of it is a
  // run that refuses to start.
  {
    doc, dok := bhv_open(loopy)
    if dok {
      defer behaviour_doc_free(&doc)
      if script_lint_count(script_lint(&doc), .Error) == 0 {
        fmt.eprintfln("  FAIL: the linter passed a block that loops")
        fails += 1
      }
    }
  }

  if fails == 0 {
    fmt.println("  PASS: sub-charts round-trip, nest two deep, restore the caller's variables on return AND on stop, and refuse cycles and loops")
  } else {
    fmt.eprintfln("  %d sub-chart problem(s)", fails)
  }
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
  // With a NODE ID gutter, which is what `script run <name> from <node>` needs you to be able to read
  // off. Rendered here rather than inside script_render, because that one's output is compared for
  // equality by the round-trip selftest and is the step-label source - ids do not belong in either.
  entry := doc.entry != 0 ? doc.entry : (len(doc.steps) > 0 ? doc.steps[0].id : 0)
  for line, i in strings.split_lines(strings.trim_right(script_render(doc.steps[:], doc.mode), "\n"), context.temp_allocator) {
    // script_render prefixes a "#! loop" header, so the step lines are offset by one on a loop chart.
    step := doc.mode == .Loop ? i - 1 : i
    if step < 0 || step >= len(doc.steps) {
      fmt.printfln("       %s", line)
      continue
    }
    // Padded as a STRING, not with a numeric width - `%4d` fills with '0' here, so node 1 renders as
    // "0001" and the gutter names ids that do not exist. Same trap script_cmd_trace documents.
    id := doc.steps[step].id
    fmt.printfln("%s%4s  %s", id == entry ? ">" : " ", fmt.tprintf("%d", u32(id)), line)
  }
  fmt.println("  ^ the number is the node id: 'script run <name> from <id>' starts there; '>' is the start node.")
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
  // Blocks the user made, listed apart from charts because they are a different VERB: you place one in
  // another chart, you do not run it. Same split the browser draws as its own tab.
  subchart_registry_refresh(force = true)
  blocks := subchart_registry_rows()
  if len(saved) == 0 {
    fmt.printfln("saved behaviours: (none yet in %s)", bhv_dir_path())
  } else {
    fmt.printfln("saved behaviours (%s):", bhv_dir_path())
    for n in saved {
      is_block := false
      for &info in blocks {
        if info.name == n {
          is_block = true
          break
        }
      }
      if !is_block {
        fmt.printfln("    %s", n)
      }
    }
  }
  if len(blocks) > 0 {
    fmt.println("your blocks (sub-charts - place them in a chart, don't run them):")
    for &info in blocks {
      fmt.printfln("    %-28s %s", subchart_signature(info.name, subchart_info_params(&info)), info.desc)
    }
  }
  fmt.println("  'script run <name>' to start, 'script show <name>' to see the blocks it builds.")
  fmt.println("  'script subchart <name>' turns a saved chart into a block, and back.")
  fmt.println("  'script nocollision <name>' drops the reach check for one chart (dungeons with fake floor props).")
  fmt.println("  A saved behaviour WINS over an Odin one of the same name - delete it to get the original back.")
}

// Flip a saved chart between "a program you run" and "a block you place".
//
// The typable twin of the tick-box in the editor's chart options - the browser's rule is that every
// action in it is a command you could have typed, and this is the one the tick-box issues.
@(private = "file")
script_cmd_subchart :: proc(args: []string) {
  if len(args) == 0 {
    fmt.eprintln("usage: script subchart <name> [on|off]   (no on/off toggles it)")
    return
  }
  name := args[0]
  if !bhv_exists(name) {
    if behaviour_def(name) != nil {
      fmt.eprintfln("script subchart: '%s' is an Odin behaviour - 'script export %s' first to get an editable copy.", name, name)
      return
    }
    fmt.eprintfln("script subchart: no saved behaviour named '%s'. 'script list' shows what's available.", name)
    return
  }
  doc, ok := bhv_open(name)
  if !ok {
    return // bhv_load already reported why
  }
  defer behaviour_doc_free(&doc)
  want := !doc.is_subchart
  if len(args) >= 2 {
    switch args[1] {
    case "on", "yes", "1":
      want = true
    case "off", "no", "0":
      want = false
    case:
      fmt.eprintfln("script subchart: expected 'on' or 'off', got '%s'.", args[1])
      return
    }
  }
  if want == doc.is_subchart {
    fmt.printfln("script: '%s' is already %s.", name, want ? "a block" : "a chart")
    return
  }
  doc.is_subchart = want
  // Say what it would refuse BEFORE writing, not after: turning a loop chart into a block is a
  // reasonable thing to try, and the fix (switch the mode) is one the message can name.
  if want {
    if why, bad := subchart_callable_why(&doc); bad {
      fmt.eprintfln("script subchart: '%s' cannot be a block yet - %s", name, why)
      return
    }
  }
  if !bhv_save(&doc) {
    return
  }
  subchart_registry_refresh(force = true) // this process just changed the answer; do not wait out the throttle
  fmt.printfln("script: '%s' is now %s.", name, want ? "a BLOCK - place it in a chart from the palette" : "a chart you run")
}

// Turn the proactive collision gate off for one saved chart - the typable twin of the tick-box in the
// editor's chart options, exactly as script_cmd_subchart is for the other one.
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
    // Padded as a STRING, not with a numeric width: `%-4d` fills with '0' here, so node 1 printed as
    // "n1000" and every trace row named a node that does not exist.
    node := r.node == 0 ? "     " : fmt.tprintf("%-5s", fmt.tprintf("n%d", u32(r.node)))
    // The elapsed column needs the space flag for the same reason - '%8.3f' printed 1.5s as "0001.500".
    fmt.printfln("  % 8.3fs  %s  %s%s", f64(r.at - base) / 1e9, node, tag, script_trace_text(&r))
  }
}

// `script snapshot [clear]` - what each node's variables held last time control reached it. Reading
// this is how you decide whether `script run <x> from <node>` will start from a state worth starting
// from, or whether the chart needs one lap from the top first.
script_cmd_snapshot :: proc(session: ^Session, args: []string) {
  snapshots := &session.script_snapshots
  if len(args) >= 1 && (args[0] == "clear" || args[0] == "wipe") {
    kept := 0
    for &row in snapshots.rows {
      if row.node != 0 {
        kept += 1
      }
    }
    snapshots^ = {}
    fmt.printfln("script snapshot: cleared (%d node(s)).", kept)
    return
  }
  chart := script_snapshots_chart(snapshots)
  rows := 0
  for &row in snapshots.rows {
    if row.node != 0 {
      rows += 1
    }
  }
  if rows == 0 {
    fmt.println("script snapshot: nothing recorded yet - run a chart and every node it reaches gets one.")
    return
  }
  now := time.now()._nsec
  fmt.printfln("'%s': %d node(s) with a remembered state, newest first:", chart, rows)
  // Newest first, because the useful one is nearly always where the chart just was. A selection sort
  // over 64 fixed slots rather than a sorted copy - the rows are big and this is a REPL print.
  shown := make(map[Node_Id]bool, rows, context.temp_allocator)
  defer delete(shown)
  for _ in 0 ..< rows {
    best: ^Script_Var_Snapshot
    for &row in snapshots.rows {
      if row.node == 0 || shown[row.node] {
        continue
      }
      if best == nil || row.at > best.at {
        best = &row
      }
    }
    if best == nil {
      break
    }
    shown[best.node] = true
    // Both numbers padded as STRINGS: a numeric width fills with '0' in this fmt, which turned node
    // 13 into "1300" and "0s ago" into "000000s ago". See the same note in script_cmd_trace.
    fmt.printfln(
      "  node %-4s  %5s ago  %d var(s)",
      fmt.tprintf("%d", u32(best.node)),
      fmt.tprintf("%.0fs", time.duration_seconds(time.Duration(now - best.at))),
      best.count,
    )
    for i in 0 ..< min(best.count, len(best.vars)) {
      saved := &best.vars[i]
      name := script_saved_var_name(saved)
      if name == "" {
        continue
      }
      fmt.printfln("      @%-14s %s", name, saved.had ? script_saved_var_value(saved) : "(unset)")
    }
  }
  fmt.println("  'script run <name> from <node>' puts one of these back before it starts.")
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
  // `from <id>` - start at that node instead of the chart's own start node, for THIS run only, leaving
  // the file alone. The editor's "Start here" is the other verb: it edits the document.
  from_node := Node_Id(0)
  // Indexed rather than `for a in args`, because `from` consumes the token after it.
  i := 0
  for i < len(args) {
    a := args[i]
    i += 1
    switch a {
    case "once":
      mode_override = int(Script_Mode.Once)
    case "loop":
      mode_override = int(Script_Mode.Loop)
    case "step", "stepping", "paused":
      start_stepping = true
    case "from", "at":
      if i >= len(args) {
        fmt.eprintln("script run: 'from' needs a node id - 'script show <name>' lists them, and the editor shows #id on each node.")
        return
      }
      id, ok := strconv.parse_uint(args[i], 10)
      if !ok || id == 0 {
        fmt.eprintfln("script run: '%s' is not a node id. 'script show <name>' lists them.", args[i])
        return
      }
      from_node = Node_Id(id)
      i += 1
    case:
      if name == "" {
        name = a
      }
    }
  }
  if name == "" {
    fmt.eprintln("usage: script run <name> [once|loop] [step] [from <node>]   ('script list' shows what's available)")
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
  // Refuse UP FRONT if any block it uses isn't usable, rather than dying mid-run - and that includes
  // the blocks inside every sub-chart it calls, however deep. A gated block down there would otherwise
  // die halfway through a call, which is exactly the mid-run death this gate exists to prevent.
  if problems := script_check_avail_deep(session, &doc); len(problems) > 0 {
    fmt.eprintfln("script run: '%s' uses %d block(s) that aren't available yet - not started:", label, len(problems))
    for p in problems {
      fmt.eprintfln("  %s", p)
    }
    fmt.eprintln("  'script blocks' shows the whole catalog and what each missing one needs.")
    behaviour_doc_free(&doc)
    return
  }
  // A BLOCK is allowed to run on its own - that is how you test one without wiring it into a chart
  // first - but nothing has bound its settings, so every @name it reads stays as literal text. Said out
  // loud, with the names, because "seen = @who" as the result is a confusing way to find that out.
  if doc.is_subchart {
    fmt.printfln("script: '%s' is a BLOCK. Running it on its own is fine for a test, but nothing is filling in its settings:", label)
    for p in subchart_params(&doc) {
      if _, set := engine.session_var_get(&session.eng, p.name); !set {
        fmt.printfln("    @%s is unset - 'var %s <value>' before this, or place the block in a chart", p.name, p.name)
      }
    }
  }
  // `from <node>` - checked before anything starts, because the two ways it can be wrong have better
  // answers here than "started at a node that never runs".
  if from_node != 0 && !script_entry_node_ok(&doc, from_node) {
    behaviour_doc_free(&doc)
    return
  }
  mode := doc.mode
  if mode_override >= 0 {
    mode = Script_Mode(mode_override)
  }
  n := len(doc.steps)
  // The gap report needs the DOCUMENT, and script_begin is about to take its steps - so ask now and
  // print after, once it is known the run actually started.
  gaps: []Entry_Gap
  if from_node != 0 {
    gaps = script_entry_gap(&doc, from_node)
  }
  entry := from_node != 0 ? from_node : doc.entry
  // script_begin takes ownership of the steps; the doc's own name is all that is left to release.
  script_begin(session, label, doc.steps, mode, entry, .Chart, doc.uses[:], doc.ignore_collision)
  // AFTER script_begin, which zeroes the run. Setting it before would be silently discarded.
  if from_node != 0 && session.script.active {
    session.script.debug_entry = true
  }
  if start_stepping && session.script.active {
    session.script.stepping = true
    script_trace(session, script_current_node(&Behaviour_Context{session = session}), .Note, "stepping - the walker will not advance on its own")
  }
  delete(doc.name)
  for u in doc.uses {
    delete(u)
  }
  delete(doc.uses)
  // Only when it ACTUALLY started. script_begin has three refusals of its own - a dangling edge, a
  // start node that is not there, and a sub-chart it cannot expand - and each frees the run and returns.
  // Announcing "started" after one of those printed the refusal and then contradicted it on the next
  // line, which reads as the tool ignoring its own error.
  if !session.script.active {
    return
  }
  fmt.printfln(
    "script: '%s' started (%d steps, %s%s).",
    label, n, mode == .Loop ? "loop" : "once", start_stepping ? ", STEPPING - it will not advance until you step it" : "",
  )
  // Said out loud, every run. A chart that ignores collision will happily pick and walk at a mob behind
  // a real wall, so "why is it walking into that" needs an answer that is already on screen.
  if session.script.ignore_collision {
    fmt.println("  ignoring collision - targets are picked and approached without checking the path is clear.")
  }
  if from_node != 0 {
    script_report_debug_entry(session, from_node, gaps)
  }
}

// Say what starting partway down a chart actually did to its state: what came back from the snapshot,
// and what is still missing. Printed AFTER "started", because both halves describe a run that is
// already going - none of this refuses anything.
//
// Same shape as the warning above for running a BLOCK on its own: name the variables, name who would
// have set them, then get out of the way.
@(private = "file")
script_report_debug_entry :: proc(session: ^Session, from: Node_Id, gaps: []Entry_Gap) {
  fmt.printfln(
    "  starting at node %d, NOT the chart's start node - 'loop' wraps here and 'script reset' rewinds here.",
    u32(from),
  )
  if row := script_snapshot_restore(session, from); row != nil {
    ago := time.duration_seconds(time.Duration(time.now()._nsec - row.at))
    fmt.printfln("  restored %d variable(s) from what node %d last saw (%.0fs ago):", row.count, u32(from), ago)
    for i in 0 ..< min(row.count, len(row.vars)) {
      saved := &row.vars[i]
      name := script_saved_var_name(saved)
      if name == "" {
        continue
      }
      if saved.had {
        fmt.printfln("    @%s = %s", name, script_saved_var_value(saved))
      } else {
        fmt.printfln("    @%s was unset then too", name)
      }
    }
  } else {
    fmt.println("  no snapshot for that node yet - run the chart from the top once and it will have one.")
  }
  // AFTER the restore, so a variable the snapshot just supplied is not reported missing. The gap list
  // is static (it is a fact about the chart); whether each one still matters is this check.
  missing := 0
  for gap in gaps {
    if _, set := engine.session_var_get(&session.eng, gap.name); set {
      continue
    }
    if missing == 0 {
      fmt.println("  the skipped nodes would have set these, and nothing has:")
    }
    missing += 1
    if gap.set_by != 0 {
      fmt.printfln("    @%s   (set by node %d '%s')", gap.name, u32(gap.set_by), gap.set_by_label)
    } else {
      fmt.printfln("    @%s   (nothing in this chart sets it)", gap.name)
    }
  }
  if missing > 0 {
    fmt.println("  'var <name> <value>' before running, or start from a node above the one that sets them.")
  }
}

// Can a run start at <node>? The same two refusals the editor applies to its "Start here" button, in
// the one place the CLI can reach - and they are refusals rather than warnings because control can
// genuinely never begin at either kind of node.
@(private = "file")
script_entry_node_ok :: proc(doc: ^Behaviour_Doc, node: Node_Id) -> bool {
  index := -1
  for s, i in doc.steps {
    if s.id == node {
      index = i
      break
    }
  }
  if index < 0 {
    fmt.eprintfln("script run: '%s' has no node %d. 'script show %s' lists them.", doc.name, u32(node), doc.name)
    return false
  }
  body := make([]bool, len(doc.steps), context.temp_allocator)
  script_watcher_body_mask(doc.steps[:], body)
  if doc.steps[index].op == .On {
    fmt.eprintfln("script run: node %d is a watcher - it is checked before every step, so it is never where a chart starts.", u32(node))
    return false
  }
  if body[index] {
    fmt.eprintfln("script run: node %d is part of a watcher's body - it is reached when the trigger fires, never from a start.", u32(node))
    fmt.eprintfln("  script_begin hoists those out of the main program, so a run could not sit there.")
    return false
  }
  return true
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
