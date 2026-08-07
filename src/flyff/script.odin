package flyff

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

import "../engine"

// ===========================================================================
// Behaviour runtime - the shared types, and the REPL surface.
//
// A behaviour is a ROUTE plus one ordered list of `WHEN <condition> DO <steps>` rules. The list is
// read top to bottom every tick and the first rule whose WHEN holds runs its DO; the evaluator lives
// in script_rules.odin, which is also where the model is argued. This file holds what both that
// evaluator and the interrupt list are built from: a step, a run, the trace ring, and the renderer
// that turns a block back into text.
//
// WHERE THE STATE MACHINE FITS. engine/statemachine.odin governs the machine's TOP-LEVEL states
// (behaviour.odin: Idle, Script). Inside a running behaviour, st_script's Update arbitrates the rule
// list and walks whatever won, calling each step's start/poll/exit - those ARE that step's
// Enter/Update/Exit. A single state proc could not give per-step Enter/Exit, because a state
// returning itself is not a transition; the walker provides it instead. The payoff is st_script's
// OWN Exit: leaving the script state for any reason - a `stop` block, `script stop`, detach - tears
// down whatever action was in flight. That is the guarantee the hardcoded modes never had.
//
// INTERRUPTS ARE NOT A SEPARATE MECHANISM. They are a second rule list above the running behaviour's,
// evaluated first by globals_tick - same rows, same walker, same latch. See interrupt.odin.
//
// THREADING. Everything here is mutated and read only under exec_mutex, like fence and sweep_*.
// The walker runs on the watcher thread; the CLI runs on the REPL thread; both hold the lock.
// Prints from the watcher do the "\n...\n" + "memscan> " prompt dance (see auto_skip_blocked).
// ===========================================================================

SCRIPT_MAX_STEPS_PER_TICK :: 64 // a pure var/add rule must not spin the watcher tick
// Rules suspended by higher ones at once. A list has no other kind of nesting: there are no loops to
// keep a stack for and no calls to return from, so this bounds the one thing that can stack.
SCRIPT_MAX_FRAMES :: 8

// --- program representation -------------------------------------------------------------------

// The whole instruction set. Two entries, and that is the design rather than an accident of what has
// been built so far: a rule's DO is a LINEAR sequence, so there is nothing for an op to branch to.
//
// It used to be thirteen. Five structured ops (If/Else/End/Repeat/While) carried nesting in array
// order, four graph ops (Loop/Goto/Branch/Return) named every edge explicitly, plus .On and .Call.
// All of it expressed control flow, and control flow in this domain turned out to be trivial - see
// script_rules.odin's header, and BACKLOG.md for the corpus measurement that settled it. A procedure
// that genuinely needs a branch becomes one Odin verb, exactly as `approach` and `kill` already are.
Script_Op :: enum {
  Action,   // run a block
  Wait_For, // sit here until the condition holds
}

// A step's stable identity, shared with Rule. The trace ring, the Problems tab and the editor all
// address by THIS and never by position, so inserting or removing a step cannot silently retarget what
// points at it. 0 means "none".
Node_Id :: distinct u32

Script_Step :: struct {
  // --- identity (authoring; this is what the editor edits and the file holds) ---
  id:        Node_Id,
  op:        Script_Op,
  action:    Script_Action,    // op == .Action
  condition: Script_Condition, // op == .Wait_For
  until:     Script_Condition, // the optional `until <event>` suffix on a long-running action
  has_until: bool,

  // --- presentation + per-run state ---
  src:       string, // one-line label, owned - drives `script show` and the step trace
  scratch:   Step_Scratch,
  // Per-site baseline, ONE PER CONDITION ROW: `kills 50 and elapsed 5` needs two independent
  // baselines, and sharing one would make whichever row armed second measure from the other's start.
  condition_state: Condition_State, // armed when the step is entered
}

// --- run state ---------------------------------------------------------------------------------

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
  // Where the ACTIVE RULE is in its own steps. Not a program counter over the whole behaviour - a rule
  // list has no such position, which is the design's central claim (see script_rules.odin). Everything
  // that reports on a run reads these two, which is why the rule walker reuses them.
  pc:             int,
  entered:        bool, // has the current step's start() run?
  started_at:     i64,
  step_at:        i64,
  steps_done:     int,
  stop_requested: bool, // set by the `stop` block / an interrupt; the walker ends the run
  paused:         bool, // transport: the machine is frozen entirely - no arbitration AND no walk
  last_line:      string, // owned - the last step's source, for `script`
  auto_owned:     bool, // a farm/sweep block turned auto on, so leaving must turn it off
  // Does this behaviour contain a `kill` that side-steps? Decided once at rules_begin and read by
  // hunt_steering_on, which relaxes the reach gate: a behaviour that steps around jams has to be
  // allowed to pick a mob it cannot currently walk to. Derived from the RULES, because "is this hunt"
  // stopped being a mode you toggle and became a property of what you ran.
  sidestep_chart: bool,
  // The chart declared `ignore_collision` (Behaviour_Doc.ignore_collision) - the proactive reach gate
  // is off for this whole run. Copied onto the run beside sidestep_chart, and for the same reason: it
  // is fixed for the duration, and the pick loop should not be re-reading the document. Zero when no
  // chart is running, which is what makes reach_gate_active inert outside one.
  ignore_collision: bool,
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

  // --- the rule list (script_rules.odin) ---------------------------------------------------------
  rules:          [dynamic]Rule, // owned; taken from the document at rules_begin
  route:          string, // owned; the .waypoints set `patrol` walks, or ""
  // Which stop of that route is next. ON THE RUN, not in the program - that is the design's "state
  // moves into the world": an interrupting kill resumes the route where it left off instead of
  // restarting it, and there is no program counter parked in a chain of 45 walk_to nodes to explain.
  route_stop:     int,
  // Which rule has control, -1 when none. Not zero: a zeroed Script_Run would otherwise claim rule 0
  // is running before anything has arbitrated, so rules_begin sets it explicitly.
  active_rule:    int,
  // Rules suspended by higher ones, innermost last. `pc` and `entered` are reused as the position
  // WITHIN the active rule's steps, so everything that reports on a run keeps working unchanged.
  rule_frames:    [SCRIPT_MAX_FRAMES]Rule_Frame,
  rule_depth:     int,
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
  Note,  // worth knowing, nothing is wrong (a higher rule took over, a rule ended)
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

// Insert <v> at <at>, sliding everything after it up. Generic because the two things that need it -
// a waypoint moved within a route, a step inserted into a rule - are the same operation on different
// element types, and an ordered insert is the one array move `append` does not give you.
inject_at :: proc(arr: ^[dynamic]$T, at: int, v: T) {
  append(arr, T{})
  for i := len(arr) - 1; i > at; i -= 1 {
    arr[i] = arr[i - 1]
  }
  arr[at] = v
}

script_run_free :: proc(run: ^Script_Run) {
  rules_free(&run.rules)
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
  delete(run.route)
  delete(run.last_line)
  run^ = {}
}

// --- rendering ------------------------------------------------------------------------------------
//
// One block, one condition, back to the text that produced it. Load-bearing in three places: the .bhv
// writer (bhv_write_step), the console (`script show`, `interrupt list`) and step_label, which is what
// a rule row and the trace ring display.
//
// There is no whole-program renderer any more. A graph had to be printed as an indented instruction
// listing because its shape was not otherwise visible; a rule list IS the shape, and script_show_rules
// prints it as the WHEN/DO table the editor draws.

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
    case .Str, .Names, .Mob, .Key, .Var_Name, .Choice, .Chart_Name:
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

