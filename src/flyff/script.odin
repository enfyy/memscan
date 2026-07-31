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

// TWO FAMILIES OF CONTROL FLOW, on purpose.
//
// The STRUCTURED ops (If/Else/End/Repeat/While) are what builder.odin emits: blocks that open and close,
// with the nesting implied by their order in the array. They are the natural shape for authoring in Odin,
// where scope exit closes a block for you.
//
// The GRAPH ops (Loop/Goto/Branch/Return) are what the node editor emits: no nesting at all, every edge
// named explicitly. A canvas has no "next line", so a node must say where control goes - including
// backwards, which is how a loop is drawn rather than declared.
//
// Both compile to the same flat array and the same walker. Keeping structured blocks rather than lowering
// them to Goto is deliberate: `script show` of an Odin behaviour then still reads as the nested program
// that was written, instead of as a pile of jumps.
//
// A DOCUMENT, though, never contains a structured op: bhv_deserialize and bhv_from_builtin both run
// script_lower_structured, so everything the .bhv format and the canvas ever see is graph ops. The
// invariant that buys is "a chart never contains a block the palette cannot create" - the editor used to
// draw If/Else/End/Repeat nodes that no amount of clicking could produce, because rewiring one would
// desync it from its partner. .Loop is what replaced .Repeat there: a loop that needs no partner.
Script_Op :: enum {
  Action, // run a block
  If, // jump past the block when the condition is false
  Else,
  End, // closes If (fall through) or Repeat/While (jump back)
  Repeat, // fixed count
  While, // condition re-tested each iteration
  Wait_For, // block until the event fires
  On, // register an interrupt watcher (hoisted at start; never executed in sequence)
  // graph: N passes over goto_id ("each pass"), then out by else_id ("when done"). Unlike .Repeat this
  // has no matching .End and keeps its remaining count ON THE NODE rather than on the run's loop stack,
  // so it survives being entered from anywhere in the graph and needs no nesting budget.
  Loop,
  Goto, // graph: continue at goto_id, unconditionally
  Branch, // graph: cond ? goto_id : else_id. Both edges are explicit - there is no fall-through arm.
  Return, // graph: end an interrupt region and resume the main program where it was suspended
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
  else_id:   Node_Id, // .Branch's FALSE edge. The true edge is goto_id, so a branch names both arms and
  // neither is "the next line" - that is what lets a node sit anywhere on the canvas.
  op:        Script_Op,
  action:    Script_Action, // op == .Action, or the watcher's action for .On
  condition:      Script_Condition, // .If / .While / .Wait_For / .On / .Branch
  until:     Script_Condition, // the optional `until <event>` suffix on a long-running action
  has_until: bool,
  close:     Script_Op, // for .End: which op it closes (so the walker knows fall-through vs loop-back)
  count:     int, // .Repeat iteration count

  // --- derived (runtime) ---
  jump:      int, // DERIVED from goto_id by script_resolve_ids at load. Never author this directly:
  // it is a cache of a position, and positions move. It exists so the hot walker indexes straight
  // into the array instead of hashing an id on every branch.
  jump_else: int, // DERIVED from else_id, same rules. -1 means "no edge" = the program ends here.

  // --- presentation + per-run state ---
  ui_pos:    [2]f32, // node position on the editor canvas. AUTHORING DATA the VM never reads - it is
  // saved and loaded like the edges are, because a graph you reopen has to look the way you left it.
  group:     string, // owned. Which named SECTION of the chart this step belongs to ("Pick a target",
  // "Fight"). Authoring data like ui_pos - the VM never reads it, and two steps in different groups
  // run exactly the same. It exists because a farm chart is a flat graph of ~20 nodes that a person
  // thinks about as five parts, and nothing in the data said what those parts were: the canvas drew a
  // correct program with no structure to hold on to. builder.section() stamps it, the .bhv file keeps
  // it, and the canvas lays out and labels a band per group.
  src:       string, // one-line label, owned - drives `script show` and the step trace
  scratch:   Step_Scratch,
  // Per-site baseline, ONE PER CONDITION ROW: `kills 50 and elapsed 5` needs two independent
  // baselines, and sharing one would make whichever row armed second measure from the other's start.
  condition_state:  Condition_State, // armed when the step is entered
}

// Does an op with no named successor continue at the NEXT ARRAY SLOT?
//
// **.Action and .Wait_For do NOT.** Every fall-through they ever had is made explicit when the document
// is created (script_materialize_fallthrough, on the same one-way door as script_lower_structured), so
// an unnamed successor on one of those means the program ENDS there.
//
// That is the whole point of materialising. `goto_id == 0` used to mean two different things - "ends
// here" and "falls through to steps[i+1]" - and which one you got depended on array position, which no
// canvas draws. Two nodes could not both be the end of a chart, a fall-through could not be cut, and
// creating a node handed the last node an exit it never had. Now array order decides nothing.
//
// Everything else still falls through, and for reasons that are not going away: `.On` is hoisted, so
// walking PAST it is how the main program gets by, and a structured block carries its body in array
// order by definition - that is what a structured block IS. Documents contain neither.
//
// This is the one definition. Four things ask the question - the walker, the successor walk the watcher
// partition uses, and two lint passes - and four copies of it is how they would come to disagree.
script_op_falls_through :: proc(op: Script_Op) -> bool {
  #partial switch op {
  case .Action, .Wait_For, .Goto, .Branch, .Loop, .Return:
    return false
  }
  return true
}

// Turn every goto_id / else_id into a jump index. Run once when a program is handed to the runtime - and
// again after ANY structural edit, which is the whole point of identities existing.
//
// The two families resolve differently, and the difference is the whole reason both can share an array:
//   structured (If/Else/Repeat/While) name their matching .End, and control resumes just PAST it (tgt+1);
//                                     a loop's .End names its head and goes exactly there.
//   graph      (Action/Wait_For/Goto/Branch) name the node control continues AT (tgt).
// An unset graph edge resolves to -1, which the walker reads as "the program ends here" - never as
// index 0, which is what a plain zero would silently mean.
script_resolve_ids :: proc(steps: []Script_Step) -> (ok: bool, dangling: Node_Id) {
  index_of := make(map[Node_Id]int, len(steps), context.temp_allocator)
  defer delete(index_of)
  for s, i in steps {
    if s.id != 0 {
      index_of[s.id] = i
    }
  }
  for &s in steps {
    // No SECOND edge unless one is named. This has to be unconditional: .Branch reads it as its false
    // arm and .Action reads it as its FAIL arm (see script_take_fail_edge), and a plain zero would be
    // read as "jump to index 0" - i.e. an unwired block would silently restart the program.
    s.jump_else = -1
    #partial switch s.op {
    case .Goto, .Branch, .Loop:
      s.jump = -1 // no edge = end, not index 0
    }
    if s.goto_id != 0 {
      tgt, found := index_of[s.goto_id]
      if !found {
        return false, s.goto_id
      }
      #partial switch s.op {
      case .If, .Else, .Repeat, .While:
        s.jump = tgt + 1 // past the matching End
      case:
        s.jump = tgt // .End back to the loop head; graph edges exactly where they point
      }
    } else if s.op == .Loop {
      s.jump = -1 // a graph loop with no body is over immediately, not a jump to index 0
    }
    if s.else_id != 0 {
      tgt, found := index_of[s.else_id]
      if !found {
        return false, s.else_id
      }
      s.jump_else = tgt
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
  condition:     Script_Condition,
  action:   Script_Action,
  condition_state: Condition_State,
  src:      string, // owned
  fires:    int, // how many times it has fired this run (shown by `script`)
  entry:    int, // first step of this watcher's REGION (see Script_Run.main_len). -1 = nothing to run.
  // Which Session-level row this was hoisted from, when it was: the document name plus the body node
  // it enters. Both are needed, because one document can contribute several watchers and each keeps
  // its own edge latch - matching on the name alone would hand the wrong one back at teardown.
  global_body_id: Node_Id,
  global_source: string, // owned; "" for a watcher the chart declared with `on`. Non-empty names the
  // GLOBAL interrupt this was hoisted from, which is how the edge latch is handed back to the
  // Session-level watcher when the run ends - see the two-sites note in interrupt.odin.
}

// The main program's position, saved while an interrupt region runs so it can be resumed exactly.
// Saving the loop stack matters as much as the pc: an interrupt that fires inside `repeat 8` has to come
// back to the same iteration, not to a loop that thinks it is starting over.
Suspended_Frame :: struct {
  pc:      int,
  entered: bool, // was the suspended step mid-flight? (a walk that is still walking)
  nloop:   int,
  loops:   [SCRIPT_MAX_NEST]Loop_Frame,
}

// --- run state ---------------------------------------------------------------------------------

Loop_Frame :: struct {
  head:      int, // index of the .Repeat / .While step
  remaining: int, // .Repeat only
}

// What a pick_* rung block chose. Also the run's equivalent of auto's auto_sel_* bookkeeping: it is
// still set after the mob dies, which is what lets `target_died` tell a kill from a stray deselect and
// `count_kill` attribute the kill to the right species and spot.
Script_Pick :: struct {
  set:   bool,
  obj:   uintptr,
  pos:   [3]f32, // the mob's position when it was chosen - the kill anchor
  stage: TC_Stage, // which rung chose it (feeds the cluster commitment)
  pack:  int, // local pack size at pick time (same)
}

Script_Run :: struct {
  active:         bool,
  name:           string, // owned
  mode:           Script_Mode,
  steps:          [dynamic]Script_Step,
  watchers:       [dynamic]Script_Watcher,
  pc:             int,
  entry_pc:       int, // index the run started at (resolved from the doc's entry node); Loop wraps here
  entered:        bool, // has the current step's start() run?
  started_at:     i64,
  step_at:        i64,
  steps_done:     int,
  loops:          [SCRIPT_MAX_NEST]Loop_Frame,
  nloop:          int,
  stop_requested: bool, // set by the `stop` block / an interrupt; the walker ends the run
  stepping:       bool, // debug: the watcher does NOT advance the walker; `script step` does, one at a time
  paused:         bool, // transport: the machine is frozen entirely - no walk AND no interrupts. Distinct
  // from `stepping`, which keeps servicing interrupts so a kill-switch can still break you out.

  // Interrupt regions. `steps` holds the main program in [0, main_len) followed by one region per
  // watcher; each region is a body ending in .Return. Firing a watcher saves the main program's
  // position into suspended and jumps into its region, so an interrupt body is a full multi-step
  // program (it can walk, wait, and have its exit run) rather than a single fire-and-forget call.
  main_len:       int,
  watcher_depth:      int, // 0 = running the main program. Capped at 1 - an interrupt cannot interrupt itself.
  active_watcher:          int, // which watcher has control while watcher_depth > 0; -1 otherwise. Read by the UI.
  suspended:       Suspended_Frame,
  last_line:      string, // owned - the last step's source, for `script`
  auto_owned:     bool, // a farm/sweep block turned auto on, so leaving must turn it off
  // Does this program contain an `approach` that side-steps? Decided once at script_begin and read by
  // hunt_steering_on, which relaxes the reach gate: a chart that steps around jams has to be allowed to
  // pick a mob it cannot currently walk to. Derived from the STEPS, because "is this hunt" stopped being
  // a mode you toggle and became a property of the chart you ran.
  sidestep_chart: bool,
  kills_by_name:  map[string]int, // per-species kill tally for `kills_of` (keys owned)

  // --- the targeting ladder's working set ---
  // `scan_mobs` does ONE background enumeration per pick cycle and parks the result here; every
  // pick_* rung block then scores against it and writes its choice into `pick`. Both live on the RUN
  // rather than on a step because the ladder is a CHAIN of nodes - the candidate list and the choice
  // have to survive the hop from one block to the next.
  //   The Pick_Ctx is deliberately NOT stored alongside them: it holds slices into session arrays (the
  // recent-pick cooldown and the stuck blacklist), and keeping those across ticks would outlive what
  // they point at. script_pick_ctx rebuilds it per rung, which costs nothing next to the scan.
  cands:          [dynamic]TC_Cand, // owned
  cand_names:     [dynamic]string, // owned clones of what scan_mobs was asked for; approach re-validates against them
  cand_dens:      []int, // owned; per-candidate pack size, index-aligned to cands. nil = density off
  cand_anchor:    [3]f32, // the position the batch was measured and sorted from
  cand_at:        i64, // when it was collected, for staleness
  pick:           Script_Pick,
}

// --- the run trace -----------------------------------------------------------------------------
//
// A ring of what the machine just DID, so "why did it stop" still has an answer after it stopped.
//
// IT LIVES ON THE SESSION, NOT ON Script_Run, and that is the entire point: script_run_free wipes the
// run the instant a program ends, which is exactly the moment you want to read the last few rows. The
// console carries the same information - every site that traces already printed - but the console is
// not where somebody working in the node editor is looking, and that gap is what made a chart that
// dies on its second node look like a chart that never started. See the trace strip in gui_nodes.odin.
//
// POD ON PURPOSE: a fixed byte buffer rather than an owned string. Rows are written on the watcher
// tick, read by the GUI snapshot under exec_mutex, and copied BY VALUE into Gui_Frame - three parties,
// and an allocator would need an ownership rule any of them could get wrong. fmt.bprintf into a fixed
// buffer truncates instead of growing, so a trace row can never allocate on the tick.
SCRIPT_TRACE_ROWS :: 256
SCRIPT_TRACE_TEXT :: 112

// Ordinary narration is its own level rather than the absence of one: the strip is mostly `Step` rows
// and the point of the other three is to be findable in among them.
Script_Trace_Level :: enum u8 {
  Step,  // control moved, a variable changed - the narration
  Note,  // worth knowing, nothing is wrong (an interrupt took over, a fail edge was taken)
  Warn,  // probably not what was meant (an @name with no value)
  Error, // the run is over, or a block refused
}

Script_Trace_Row :: struct {
  at:    i64,
  node:  Node_Id, // 0 = about the run as a whole rather than about one node
  level: Script_Trace_Level,
  count: u8, // bytes used in `text`
  text:  [SCRIPT_TRACE_TEXT]u8,
}

Script_Trace :: struct {
  rows:    [SCRIPT_TRACE_ROWS]Script_Trace_Row,
  next:    int, // where the next row goes
  written: int, // total ever written - tells a partly-filled ring from a wrapped one
}

// Newest-last, oldest-first. Returns at most <limit> rows (0 = all of them), copied out so a caller
// that is not holding exec_mutex cannot read a row mid-write.
script_trace_recent :: proc(trace: ^Script_Trace, limit: int, allocator := context.temp_allocator) -> []Script_Trace_Row {
  have := min(trace.written, SCRIPT_TRACE_ROWS)
  want := limit <= 0 ? have : min(limit, have)
  if want == 0 {
    return nil
  }
  out := make([]Script_Trace_Row, want, allocator)
  // `next` is one past the newest, so the oldest of the <want> newest sits `want` slots behind it.
  start := ((trace.next - want) % SCRIPT_TRACE_ROWS + SCRIPT_TRACE_ROWS) % SCRIPT_TRACE_ROWS
  for i in 0 ..< want {
    out[i] = trace.rows[(start + i) % SCRIPT_TRACE_ROWS]
  }
  return out
}

// By pointer, not by value: `text` is a fixed array, and slicing one needs an addressable operand -
// an Odin parameter is immutable and therefore is not one. Callers walk with `for &row in rows`.
script_trace_text :: proc(row: ^Script_Trace_Row) -> string {
  return string(row.text[:min(int(row.count), SCRIPT_TRACE_TEXT)])
}

// --- lifetime -----------------------------------------------------------------------------------

script_step_free :: proc(step: ^Script_Step) {
  delete(step.src)
  delete(step.group)
  delete(step.action.strs[0])
  delete(step.action.strs[1])
  // Through script_condition_free, not two deletes: a condition owns the strings of EVERY row, and freeing
  // only row 0 leaked the rest of a multi-condition test.
  script_condition_free(&step.condition)
  script_condition_free(&step.until)
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
    delete(w.global_source)
    delete(w.action.strs[0])
    delete(w.action.strs[1])
    script_condition_free(&w.condition)
  }
  delete(run.watchers)
  run.watchers = nil
  for k in run.kills_by_name {
    delete(k) // the map owns its key strings (see script_note_kill)
  }
  delete(run.kills_by_name)
  run.kills_by_name = nil
  delete(run.cands)
  for n in run.cand_names {
    delete(n)
  }
  delete(run.cand_names)
  delete(run.cand_dens)
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
script_render_step :: proc(b: ^strings.Builder, step: Script_Step, depth: int, display := false) {
  for _ in 0 ..< depth {
    strings.write_string(b, "  ")
  }
  switch step.op {
  case .Action:
    script_write_action(b, step.action, display)
    if step.has_until {
      strings.write_string(b, " until ")
      script_write_condition(b, step.until, display)
    }
    // An action's edges, when it names them. DISPLAY ONLY - the file format writes both on the `node`
    // line (script_write_action produces the payload alone), so this cannot leak into a .bhv. Printing
    // them matters because on a canvas an action may name its successor instead of falling through, and
    // a fail edge decides where a failure goes; `script show` hiding either would misdescribe the
    // program. Same reasoning as the canvas drawing implicit fall-through rather than pretending an
    // unwired node has no successor.
    if step.goto_id != 0 {
      fmt.sbprintf(b, " -> #%d", u32(step.goto_id))
    }
    if step.else_id != 0 {
      fmt.sbprintf(b, " else #%d", u32(step.else_id))
    }
  case .If:
    strings.write_string(b, "if ")
    script_write_condition(b, step.condition, display)
  case .While:
    strings.write_string(b, "while ")
    script_write_condition(b, step.condition, display)
  case .Wait_For:
    strings.write_string(b, "wait_for ")
    script_write_condition(b, step.condition, display)
  case .On:
    // Two shapes of watcher: one that names a BODY (the node editor's, and what an upgraded interrupt
    // file becomes) and one carrying a single action (builder.on()'s). Printing "-> ?" for the first
    // was the old renderer describing a body it did not know about.
    strings.write_string(b, "on ")
    script_write_condition(b, step.condition, display)
    strings.write_string(b, " -> ")
    if step.goto_id != 0 {
      fmt.sbprintf(b, "#%d", u32(step.goto_id))
    } else {
      script_write_action(b, step.action, display)
    }
  case .Repeat:
    fmt.sbprintf(b, "repeat %d", step.count)
  case .Else:
    strings.write_string(b, "else")
  case .End:
    strings.write_string(b, "end")
  // Graph ops print their edges by NODE ID, because that is the only thing about them that is stable -
  // a line number would mean nothing on a canvas where nodes are placed, not ordered.
  case .Loop:
    fmt.sbprintf(b, "loop %d times -> #%d else #%d", step.count, u32(step.goto_id), u32(step.else_id))
  case .Goto:
    fmt.sbprintf(b, "goto #%d", u32(step.goto_id))
  case .Branch:
    strings.write_string(b, "branch ")
    script_write_condition(b, step.condition, display)
    fmt.sbprintf(b, " ? #%d : #%d", u32(step.goto_id), u32(step.else_id))
  case .Return:
    strings.write_string(b, "return")
  }
  strings.write_string(b, "\n")
}

script_write_action :: proc(b: ^strings.Builder, act: Script_Action, display := false) {
  def := action_def(act.kind)
  if def == nil {
    strings.write_string(b, "?")
    return
  }
  strings.write_string(b, def.name)
  script_write_params(b, def.params, act.nums, act.strs, display)
}

script_write_event :: proc(b: ^strings.Builder, ev: Script_Event, display := false) {
  def := event_def(ev.kind)
  if def == nil {
    strings.write_string(b, "?")
    return
  }
  if ev.negate {
    strings.write_string(b, "not ")
  }
  strings.write_string(b, def.name)
  script_write_params(b, def.params, ev.nums, ev.strs, display)
}

// A whole condition on one line, joined by `and` / `or`. This is the CONSOLE spelling (`script show`,
// step labels, `interrupt list`). The .bhv format writes one row per line instead - see bhv_serialize -
// because a file is parsed back and repeating a line it already knows how to read beats teaching the
// tokenizer about infix words.
script_write_condition :: proc(b: ^strings.Builder, c: Script_Condition, display := false) {
  n := condition_row_count(c)
  for i in 0 ..< n {
    if i > 0 {
      strings.write_string(b, c.match_any ? " or " : " and ")
    }
    script_write_event(b, condition_row(c, i), display)
  }
}

script_write_params :: proc(b: ^strings.Builder, spec: []Param_Spec, nums: [4]f64, strs: [2]string, display := false) {
  ni := 0
  si := 0
  for p in spec {
    switch p.kind {
    case .Num, .Duration, .Percent:
      strings.write_string(b, " ")
      script_write_num(b, nums[ni], display)
      ni += 1
    case .Coord:
      // The expression, when there is one, IS the argument - one token, so the tokenizer needs to
      // learn nothing. A literal writes exactly as it always did, which is what keeps every .bhv
      // written before this change byte-identical after a load and re-save.
      strings.write_string(b, " ")
      if strs[si] != "" {
        strings.write_string(b, strs[si])
      } else {
        script_write_num(b, nums[ni], display)
        strings.write_string(b, ",")
        script_write_num(b, nums[ni + 1], display)
      }
      ni += 2
      si += 1
    case .Str, .Names, .Mob, .Key, .Var_Name, .Choice:
      strings.write_string(b, " ")
      // Quote anything with whitespace or a comma so the round-trip re-parses identically - and an
      // EMPTY string too, which is the case that actually bit. Written bare it is not a short
      // argument, it is no argument at all: `var  ` re-reads as `var` and the parser rejects the
      // line for a missing required 'name'. That made every chart the node editor saved with a
      // string field still blank unloadable, which is exactly the state a half-authored chart is in.
      if strs[si] == "" || strings.contains_any(strs[si], " \t,") {
        fmt.sbprintf(b, "'%s'", strs[si])
      } else {
        strings.write_string(b, strs[si])
      }
      si += 1
    }
  }
}

// Whole numbers print without a decimal tail, so `wait 2` round-trips as `wait 2` not `wait 2.000`.
//
// <display> rounds a fraction to TWO DECIMALS, and is only ever set on the paths that put a number in
// front of a person - `step_label`, which is the node's caption and the dock's step readout. The FILE
// and `script show` keep the exact value, because the file has to round-trip and `script show` is
// documented to spell a chart the way the .bhv does.
//
// A `wait_random` rolls its duration into an f64 and the label printed whatever came out, so the dock
// read `wait_random 2.0999999999999996 6.25`. That is a memory dump, not a duration.
script_write_num :: proc(b: ^strings.Builder, v: f64, display := false) {
  if display && v != f64(i64(v)) {
    fmt.sbprintf(b, "%.2f", v)
    return
  }
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
