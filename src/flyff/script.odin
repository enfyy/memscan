package flyff

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "../engine"

// ===========================================================================
// Behaviour scripts - the VM, the text syntax, and the REPL surface.
//
// A script is a FLAT instruction list with jumps resolved at parse time, not a tree. That buys
// three things at once: it single-steps one instruction per tick without a recursion stack, it
// unparses back to the exact source (`script show`), and a node graph can emit it directly later
// without the VM learning anything new.
//
// WHERE THE STATE MACHINE FITS. engine/statemachine.odin governs the machine's TOP-LEVEL states
// (behaviour.odin: Idle, Script, and eventually the ported auto states). Inside a running script,
// st_script's Update walks the program counter and calls each step's start/poll/exit - those ARE
// that step's Enter/Update/Exit. A single state proc could not give per-step Enter/Exit, because a
// state returning itself is not a transition; the pc walker provides it instead. The payoff is
// st_script's OWN Exit: leaving the script state for any reason - completion, `script stop`, an
// interrupt, detach - tears down whatever action was in flight. That is the guarantee the
// hardcoded modes never had.
//
// INTERRUPTS. `on <event> -> <action>` watchers are evaluated BEFORE the current step each tick,
// in declaration order (first match wins). They are the generalisation of what the RTS exemplar
// does with early `return other_state` checks at the top of each Update - which does not
// generalise to user-authored machines, so it lives here rather than in the copied core.
//
// THREADING. Everything here is mutated and read only under exec_mutex, like fence and sweep_*.
// The pc walker runs on the watcher thread; the CLI runs on the REPL thread; both hold the lock.
// Prints from the watcher do the "\n...\n" + "memscan> " prompt dance (see auto_skip_blocked).
// ===========================================================================

SCRIPT_MAX_STEPS_PER_TICK :: 64 // a pure if/var script must not spin the watcher tick
SCRIPT_MAX_NEST :: 16 // if/repeat/while nesting depth
SCRIPT_MAX_WATCHERS :: 16

// --- program representation -------------------------------------------------------------------

Script_Op :: enum {
  Action, // run a block
  If, // jump past the block when the condition is false
  Else,
  End, // closes If (fall through) or Repeat/While (jump back)
  Repeat, // fixed count
  While, // condition re-tested each iteration
  Wait_For, // block until the event fires
  On, // register an interrupt watcher (hoisted at start; never executed in sequence)
}

// A node's stable identity. Edges reference THIS, never a position, so inserting or removing a step
// cannot silently retarget the jumps around it. 0 means "none".
Node_Id :: distinct u32

Script_Step :: struct {
  // --- identity + structure (authoring; this is what an editor would save) ---
  id:        Node_Id,
  goto_id:   Node_Id, // structured edge BY IDENTITY. For .If/.While/.Repeat it names the matching
  // .End and control resumes at the step AFTER it; for a loop's .End it names the loop head exactly.
  // Naming the End rather than "the step after the block" is deliberate: every referenced node
  // already exists when the edge is created, and inserting a step right after a block correctly
  // becomes the block's new continuation.
  op:        Script_Op,
  action:    Script_Action, // op == .Action, or the watcher's action for .On
  cond:      Script_Event, // .If / .While / .Wait_For / .On
  until:     Script_Event, // the optional `until <event>` suffix on a long-running action
  has_until: bool,
  close:     Script_Op, // for .End: which op it closes (so the walker knows fall-through vs loop-back)
  count:     int, // .Repeat iteration count

  // --- derived (runtime) ---
  jump:      int, // DERIVED from goto_id by script_resolve_ids at load. Never author this directly:
  // it is a cache of a position, and positions move. It exists so the hot walker indexes straight
  // into the array instead of hashing an id on every branch.

  // --- presentation + per-run state ---
  src:       string, // one-line label, owned - drives `script show` and the step trace
  scratch:   Step_Scratch,
  ev_state:  Event_State, // per-site baseline for cond/until (armed when the step is entered)
}

// Turn every goto_id into a jump index. Run once when a program is handed to the runtime - and again
// after ANY structural edit, which is the whole point of identities existing.
script_resolve_ids :: proc(steps: []Script_Step) -> (ok: bool, dangling: Node_Id) {
  index_of := make(map[Node_Id]int, len(steps), context.temp_allocator)
  defer delete(index_of)
  for s, i in steps {
    if s.id != 0 {
      index_of[s.id] = i
    }
  }
  for &s in steps {
    if s.goto_id == 0 {
      continue
    }
    tgt, found := index_of[s.goto_id]
    if !found {
      return false, s.goto_id
    }
    #partial switch s.op {
    case .If, .Else, .Repeat, .While:
      s.jump = tgt + 1 // past the matching End
    case .End:
      s.jump = tgt // back to the loop head, exactly
    }
  }
  return true, 0
}

Script_Mode :: enum {
  Once,
  Loop,
}

// An `on <event> -> <action>` interrupt. Hoisted out of the instruction stream at run start, so
// declaration position does not affect when it is armed.
Script_Watcher :: struct {
  cond:     Script_Event,
  action:   Script_Action,
  ev_state: Event_State,
  src:      string, // owned
  fires:    int, // how many times it has fired this run (shown by `script`)
}

// --- run state ---------------------------------------------------------------------------------

Loop_Frame :: struct {
  head:      int, // index of the .Repeat / .While step
  remaining: int, // .Repeat only
}

Script_Run :: struct {
  active:         bool,
  name:           string, // owned
  mode:           Script_Mode,
  steps:          [dynamic]Script_Step,
  watchers:       [dynamic]Script_Watcher,
  pc:             int,
  entered:        bool, // has the current step's start() run?
  started_at:     i64,
  step_at:        i64,
  steps_done:     int,
  loops:          [SCRIPT_MAX_NEST]Loop_Frame,
  nloop:          int,
  stop_requested: bool, // set by the `stop` block / an interrupt; the walker ends the run
  stepping:       bool, // debug: the watcher does NOT advance the walker; `script step` does, one at a time
  last_line:      string, // owned - the last step's source, for `script`
  auto_owned:     bool, // a farm/sweep block turned auto on, so leaving must turn it off
  kills_by_name:  map[string]int, // per-species kill tally for `kills_of` (keys owned)
}

// --- lifetime -----------------------------------------------------------------------------------

script_step_free :: proc(step: ^Script_Step) {
  delete(step.src)
  delete(step.action.strs[0])
  delete(step.action.strs[1])
  delete(step.cond.strs[0])
  delete(step.cond.strs[1])
  delete(step.until.strs[0])
  delete(step.until.strs[1])
}

script_steps_free :: proc(steps: ^[dynamic]Script_Step) {
  for &s in steps {
    script_step_free(&s)
  }
  delete(steps^)
  steps^ = nil
}

script_run_free :: proc(run: ^Script_Run) {
  script_steps_free(&run.steps)
  for &w in run.watchers {
    delete(w.src)
    delete(w.action.strs[0])
    delete(w.action.strs[1])
    delete(w.cond.strs[0])
    delete(w.cond.strs[1])
  }
  delete(run.watchers)
  run.watchers = nil
  for k in run.kills_by_name {
    delete(k) // the map owns its key strings (see script_note_kill)
  }
  delete(run.kills_by_name)
  run.kills_by_name = nil
  delete(run.name)
  delete(run.last_line)
  run^ = {}
}

// --- rendering ------------------------------------------------------------------------------------
//
// The FORMATTER half of what used to be a parse/unparse pair. The parser is gone (behaviours are
// built in Odin now - see builder.odin), but rendering a step back to one readable line is still
// load-bearing: it labels every step for `script step`, the status line, and `script show`.

// Rebuild the canonical source for one step from its PARSED form (never from step.src). That makes
// `script show` a genuine round-trip check: if the printed text differs from the file, the parse
// lost something. Indentation is recomputed from block depth.
script_render_step :: proc(b: ^strings.Builder, step: Script_Step, depth: int) {
  for _ in 0 ..< depth {
    strings.write_string(b, "  ")
  }
  switch step.op {
  case .Action:
    script_write_action(b, step.action)
    if step.has_until {
      strings.write_string(b, " until ")
      script_write_event(b, step.until)
    }
  case .If:
    strings.write_string(b, "if ")
    script_write_event(b, step.cond)
  case .While:
    strings.write_string(b, "while ")
    script_write_event(b, step.cond)
  case .Wait_For:
    strings.write_string(b, "wait_for ")
    script_write_event(b, step.cond)
  case .On:
    strings.write_string(b, "on ")
    script_write_event(b, step.cond)
    strings.write_string(b, " -> ")
    script_write_action(b, step.action)
  case .Repeat:
    fmt.sbprintf(b, "repeat %d", step.count)
  case .Else:
    strings.write_string(b, "else")
  case .End:
    strings.write_string(b, "end")
  }
  strings.write_string(b, "\n")
}

script_write_action :: proc(b: ^strings.Builder, act: Script_Action) {
  def := action_def(act.kind)
  if def == nil {
    strings.write_string(b, "?")
    return
  }
  strings.write_string(b, def.name)
  script_write_params(b, def.params, act.nums, act.strs)
}

script_write_event :: proc(b: ^strings.Builder, ev: Script_Event) {
  def := event_def(ev.kind)
  if def == nil {
    strings.write_string(b, "?")
    return
  }
  if ev.negate {
    strings.write_string(b, "not ")
  }
  strings.write_string(b, def.name)
  script_write_params(b, def.params, ev.nums, ev.strs)
}

script_write_params :: proc(b: ^strings.Builder, spec: []Param_Spec, nums: [4]f64, strs: [2]string) {
  ni := 0
  si := 0
  for p in spec {
    switch p.kind {
    case .Num, .Duration, .Percent:
      strings.write_string(b, " ")
      script_write_num(b, nums[ni])
      ni += 1
    case .Coord:
      strings.write_string(b, " ")
      script_write_num(b, nums[ni])
      strings.write_string(b, ",")
      script_write_num(b, nums[ni + 1])
      ni += 2
    case .Str, .Names:
      strings.write_string(b, " ")
      // Re-quote anything with whitespace or a comma so the round-trip re-parses identically.
      if strings.contains_any(strs[si], " \t,") {
        fmt.sbprintf(b, "'%s'", strs[si])
      } else {
        strings.write_string(b, strs[si])
      }
      si += 1
    }
  }
}

// Whole numbers print without a decimal tail, so `wait 2` round-trips as `wait 2` not `wait 2.000`.
script_write_num :: proc(b: ^strings.Builder, v: f64) {
  if v == f64(i64(v)) {
    fmt.sbprintf(b, "%d", i64(v))
  } else {
    fmt.sbprintf(b, "%v", v)
  }
}

script_render :: proc(steps: []Script_Step, mode: Script_Mode, allocator := context.temp_allocator) -> string {
  b := strings.builder_make(allocator)
  if mode == .Loop {
    strings.write_string(&b, "#! loop\n")
  }
  depth := 0
  for step in steps {
    #partial switch step.op {
    case .End, .Else:
      depth = max(0, depth - 1)
    }
    script_render_step(&b, step, depth)
    #partial switch step.op {
    case .If, .Repeat, .While, .Else:
      depth += 1
    }
  }
  return strings.to_string(b)
}
