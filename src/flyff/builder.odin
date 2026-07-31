package flyff

import "core:strings"

// ===========================================================================
// The behaviour builder - authoring behaviours as plain Odin.
//
// This is the library surface. You write ordinary Odin against it and it produces the same
// []Script_Step the runtime already walks, so nothing downstream changes.
//
// THE ONE RULE WORTH INTERNALISING: Odin's control flow runs at BUILD time; the three node
// builders below run at RUN time.
//
//   for i in 0 ..< 8 { key(s, "2") }        // unrolls to 8 steps - the loop is gone
//   loop_until(s, no_target())              // survives as a node - the condition is checked live
//
// So anything knowable while building (config variation, repeating over a list of spots,
// factoring a sequence into a proc) is just Odin, and only genuine runtime decisions cost a
// node. That is also why sub-scripts do not exist here: a sub-script is a procedure, and Odin
// already has those.
//
// NESTING WITHOUT end() PAIRS: branch/loop_until return a child Seq. Emitting to the PARENT
// again auto-closes any open child, so Odin's own braces give you the structure:
//
//   {
//       fight := loop_until(s, no_target())
//       key(fight, "2")
//       wait(fight, 0.4)
//   }
//   wait(s, 4)   // <- emitting to the parent closes the loop
//
// PACKAGE SEAM: this lives in `flyff` for now, but deliberately touches nothing flyff-specific -
// only Script_Step, Script_Action, Script_Event and the catalog enums. Extracting it into its own
// package later is a move, not a rewrite; what would have to come with it is the block-kind enums
// and Param_Spec, with the block IMPLEMENTATIONS staying behind and registering into a table.
// ===========================================================================

// --- builder state ---------------------------------------------------------------------------

Builder :: struct {
  steps:   [dynamic]Script_Step,
  open:    [SCRIPT_MAX_NEST]int, // indices of the currently-open If / Repeat / While steps
  nopen:   int,
  next_id: Node_Id, // monotonic per program - deterministic, so two builds of the same behaviour diff cleanly
  name:    string,
  mode:    Script_Mode,
  errs:    [dynamic]string, // authoring mistakes (over-nesting, bad key names) - reported, not fatal
  group:   string, // the section every emitted step is stamped with; see section()
}

// A cursor into the program at a given nesting depth. Emitting through a Seq whose depth is
// shallower than the builder's current one closes the intervening blocks first - that is the whole
// trick behind not needing end().
Seq :: struct {
  b:     ^Builder,
  depth: int,
}

builder_begin :: proc(name: string, mode: Script_Mode = .Once) -> ^Builder {
  b := new(Builder)
  b.steps = make([dynamic]Script_Step)
  b.errs = make([dynamic]string, context.temp_allocator)
  b.name = name
  b.mode = mode
  b.next_id = 1 // 0 is reserved for "no node"
  return b
}

// Finish the program: close anything still open and hand over the steps. The Builder itself is
// freed; the caller owns the returned steps (script_begin takes them).
builder_end :: proc(b: ^Builder) -> (steps: [dynamic]Script_Step, mode: Script_Mode, errs: []string) {
  for b.nopen > 0 {
    builder_close(b)
  }
  steps = b.steps
  mode = b.mode
  errs = b.errs[:]
  free(b)
  return
}

// The root cursor.
seq :: proc(b: ^Builder) -> Seq {
  return Seq{b = b, depth = 0}
}

builder_error :: proc(b: ^Builder, msg: string) {
  append(&b.errs, msg)
}

// --- emission --------------------------------------------------------------------------------

// Append a step at <s>'s depth, closing any blocks opened deeper than it first.
@(private = "file")
emit :: proc(s: ^Seq, step: Script_Step) -> int {
  b := s.b
  for b.nopen > s.depth {
    builder_close(b)
  }
  st := step
  st.id = b.next_id
  b.next_id += 1
  st.src = step_label(st) // human-readable label; drives `script step` and the status line
  if b.group != "" {
    st.group = strings.clone(b.group) // OWNED per step: script_step_free deletes it
  }
  append(&b.steps, st)
  return len(b.steps) - 1
}

// Name the part of the chart the following steps belong to. Pure annotation - the VM never reads it,
// two identical programs with different sections run identically - but it is the difference between a
// canvas showing twenty nodes and a canvas showing "Pick a target" as one labelled band you can take
// in at a glance. Call it before each part; `section(b, "")` stops stamping.
//
// It belongs on the BUILDER rather than on a Seq because a section is a horizontal slice of the
// program, and nesting depth is a vertical one - a branch inside "Fight" is still in "Fight".
section :: proc(b: ^Builder, name: string) {
  b.group = name
}

// Close the innermost open block: emit its End and wire the edge pair BY IDENTITY. No index
// arithmetic here at all - script_resolve_ids turns these into jump offsets at load, and re-running
// it after an edit is what keeps the structure correct when positions move.
@(private = "file")
builder_close :: proc(b: ^Builder) {
  if b.nopen == 0 {
    return
  }
  b.nopen -= 1
  head := b.open[b.nopen]
  head_op := b.steps[head].op

  end_step := Script_Step {
    op    = .End,
    id    = b.next_id,
    close = head_op == .If ? Script_Op.If : head_op,
  }
  b.next_id += 1
  end_step.src = strings.clone("end") // OWNED: script_step_free deletes src, so a literal would corrupt the heap
  if b.group != "" {
    end_step.group = strings.clone(b.group) // this path bypasses emit, so it stamps the section itself
  }

  // The block head leaves via its End (control resumes just past it); a loop's End returns to the head.
  b.steps[head].goto_id = end_step.id
  #partial switch head_op {
  case .Repeat, .While:
    end_step.goto_id = b.steps[head].id
  }
  append(&b.steps, end_step)
}

@(private = "file")
open_block :: proc(s: ^Seq, step: Script_Step) -> Seq {
  b := s.b
  if b.nopen >= SCRIPT_MAX_NEST {
    builder_error(b, "nesting deeper than the runtime allows - flatten it or factor part into a proc")
    return s^
  }
  idx := emit(s, step)
  b.open[b.nopen] = idx
  b.nopen += 1
  return Seq{b = b, depth = s.depth + 1}
}

// One-line label for a step, generated from its parsed form (NOT from source text - builder-made
// programs have no source). Same renderer the text view used, so `script step` reads identically
// whichever producer made the program.
// Returns an INDEPENDENTLY allocated string. Both halves of that matter: the render buffer is temp
// so it goes away on its own, and the result is cloned rather than handed back as a slice into that
// buffer - Script_Step.src is deleted by script_step_free, and freeing a trimmed sub-slice passes a
// length that doesn't match the allocation, which corrupts the heap.
step_label :: proc(step: Script_Step) -> string {
  sb := strings.builder_make(context.temp_allocator)
  // display: this is the node's caption and the dock's step readout, so a rolled f64 gets two decimals
  // instead of its full expansion. The file and `script show` still carry the exact value.
  script_render_step(&sb, step, 0, display = true)
  return strings.clone(strings.trim_right_space(strings.to_string(sb)))
}

// --- actions ---------------------------------------------------------------------------------

@(private = "file")
act :: proc(s: ^Seq, a: Script_Action) {
  emit(s, Script_Step{op = .Action, action = a})
}

// Press a game hotkey (skill slot, potion, teleport item).
key :: proc(s: ^Seq, k: string) {
  if _, ok := vk_from_name(k); !ok {
    builder_error(s.b, strings.concatenate({"press_key: '", k, "' is not a key name"}, context.temp_allocator))
  }
  a := Script_Action{kind = .Press_Key}
  a.strs[0] = strings.clone(k)
  act(s, a)
}

// Push a key down and leave it down. The following steps run with it held; `release_key` lets go,
// and the run releases anything still held when it ends (see keys.odin).
hold_key :: proc(s: ^Seq, k: string) {
  if _, ok := vk_from_name(k); !ok {
    builder_error(s.b, strings.concatenate({"key_down: '", k, "' is not a key name"}, context.temp_allocator))
  }
  a := Script_Action{kind = .Key_Down}
  a.strs[0] = strings.clone(k)
  act(s, a)
}

// Let go of a key `hold_key` is holding.
release_key :: proc(s: ^Seq, k: string) {
  if _, ok := vk_from_name(k); !ok {
    builder_error(s.b, strings.concatenate({"key_up: '", k, "' is not a key name"}, context.temp_allocator))
  }
  a := Script_Action{kind = .Key_Up}
  a.strs[0] = strings.clone(k)
  act(s, a)
}

// Walk to a world point and wait until you arrive.
walk :: proc(s: ^Seq, to: [3]f32) {
  a := Script_Action{kind = .Walk_To}
  a.nums[0] = f64(to[0])
  a.nums[1] = f64(to[2])
  act(s, a)
}

// Walk an OFFSET from wherever the character is standing when the block runs. Chain them and each leg
// starts where the last ended, so a set of offsets that sums to zero is a closed loop you can drop
// anywhere - which is the difference between a patrol that works here and one that works everywhere.
walk_by :: proc(s: ^Seq, dx, dz: f32) {
  a := Script_Action{kind = .Walk_By}
  a.nums[0] = f64(dx)
  a.nums[1] = f64(dz)
  act(s, a)
}

wait :: proc(s: ^Seq, secs: f64) {
  a := Script_Action{kind = .Wait}
  a.nums[0] = secs
  act(s, a)
}

jump_now :: proc(s: ^Seq) {
  act(s, Script_Action{kind = .Jump})
}

// A directional jump aimed by an offset rather than at a fixed point. Only the direction matters.
jump_by :: proc(s: ^Seq, dx, dz: f32) {
  a := Script_Action{kind = .Jump_By}
  a.nums[0] = f64(dx)
  a.nums[1] = f64(dz)
  act(s, a)
}

// Select the nearest matching monster. No names = any monster.
pick :: proc(s: ^Seq, names: string = "") {
  a := Script_Action{kind = .Target}
  a.strs[0] = strings.clone(names)
  act(s, a)
}

// Hand steering to the auto-brain. Pair with a `for_` limit or an interrupt, or it runs until auto
// stops itself.
farm :: proc(s: ^Seq, names: string = "") {
  a := Script_Action{kind = .Farm}
  a.strs[0] = strings.clone(names)
  act(s, a)
}

sweep :: proc(s: ^Seq, to: [3]f32) {
  a := Script_Action{kind = .Sweep_To}
  a.nums[0] = f64(to[0])
  a.nums[1] = f64(to[2])
  act(s, a)
}

alert :: proc(s: ^Seq) {
  act(s, Script_Action{kind = .Alert})
}

abort :: proc(s: ^Seq) {
  act(s, Script_Action{kind = .Stop})
}

// Fail on purpose. Wire its .False edge to say where a failure goes; unwired, it ends the run.
fail_now :: proc(s: ^Seq) {
  act(s, Script_Action{kind = .Fail})
}

// Set a session variable (the same @name the REPL's `var` command reads).
set_var :: proc(s: ^Seq, name, value: string) {
  a := Script_Action{kind = .Var}
  a.strs[0] = strings.clone(name)
  a.strs[1] = strings.clone(value)
  act(s, a)
}

// Add to a numeric variable; creates it at 0 if unset. Mostly a test/counter affordance.
add_var :: proc(s: ^Seq, name: string, delta: f64 = 1) {
  a := Script_Action{kind = .Add}
  a.strs[0] = strings.clone(name)
  a.nums[0] = delta
  act(s, a)
}

// Store a live reading in a variable - see READ_VALUE_SOURCES for the list. `read_value(&s, "spot",
// "player_position")` then `walk_to @spot` is what lets a chart be written once and run anywhere
// rather than only where its waypoints were typed.
read_value :: proc(s: ^Seq, name: string, source: string) {
  a := Script_Action{kind = .Read_Value}
  a.strs[0] = strings.clone(name)
  a.strs[1] = strings.clone(source)
  act(s, a)
}

// Escape hatch: run any REPL command line.
command :: proc(s: ^Seq, line: string) {
  a := Script_Action{kind = .Run_Cmd}
  a.strs[0] = strings.clone(line)
  act(s, a)
}

// Pause for a random time in [lo, hi] seconds - the human-hesitation delay.
wait_between :: proc(s: ^Seq, lo, hi: f64) {
  a := Script_Action{kind = .Wait_Random}
  a.nums[0] = lo
  a.nums[1] = hi
  act(s, a)
}

// --- the targeting ladder -----------------------------------------------------------------------
//
// These are emitted like any other action, but they are meant to be WIRED rather than stacked: each
// pick_* fails when its rung has nothing, and its .False edge is "ask the next rung". So the ladder is
// built with the graph helpers at the bottom of this file:
//
//     aggro := here_after(scan_then(pick_aggro))
//     wire(b, aggro, .False, melee_node)
//
// See bh_auto in behaviours.odin for the whole shape.

// Collect the nearby monsters once, for the pick_* rungs to score. No names = any monster.
scan_mobs :: proc(s: ^Seq, names: string = "") {
  a := Script_Action{kind = .Scan_Mobs}
  a.strs[0] = strings.clone(names)
  act(s, a)
}

pick_aggro :: proc(s: ^Seq) {act(s, Script_Action{kind = .Pick_Aggro})}
pick_avoid :: proc(s: ^Seq) {act(s, Script_Action{kind = .Pick_Avoid})}
pick_pocket :: proc(s: ^Seq) {act(s, Script_Action{kind = .Pick_Pocket})}
pick_cluster :: proc(s: ^Seq) {act(s, Script_Action{kind = .Pick_Cluster})}
pick_nearest :: proc(s: ^Seq) {act(s, Script_Action{kind = .Pick_Nearest})}

// 0 = use the configured melee_range.
pick_melee :: proc(s: ^Seq, range: f64 = 0) {
  a := Script_Action{kind = .Pick_Melee}
  a.nums[0] = range
  act(s, a)
}

// 0 = use the configured density_min_gain / density_max_detour.
pick_density :: proc(s: ^Seq, min_gain: f64 = 0, max_detour: f64 = 0) {
  a := Script_Action{kind = .Pick_Density}
  a.nums[0] = min_gain
  a.nums[1] = max_detour
  act(s, a)
}

// Only what is already in reach of where you stand - never proposes a walk. 0 = attack_range.
pick_in_range :: proc(s: ^Seq, range: f64 = 0) {
  a := Script_Action{kind = .Pick_In_Range}
  a.nums[0] = range
  act(s, a)
}

lock_target :: proc(s: ^Seq) {act(s, Script_Action{kind = .Lock_Target})}
count_kill :: proc(s: ^Seq) {act(s, Script_Action{kind = .Count_Kill})}

// Drive the painted lane. Fails when the lane is finished, so wire .False to whatever ends the run.
sweep_lane :: proc(s: ^Seq) {act(s, Script_Action{kind = .Sweep_Lane})}

// Walk to the picked monster before locking it. max_range > 0 keeps hopping until that close;
// sidestep = step around a jam and keep going instead of failing (what hunt mode was).
approach :: proc(s: ^Seq, max_range: f64 = 0, spread: f64 = 0, sidestep := false) {
  a := Script_Action{kind = .Approach}
  a.nums[0] = max_range
  a.nums[1] = spread
  a.nums[2] = sidestep ? 1 : 0
  act(s, a)
}

// Stay on the locked mob until it is gone. Fails when it decides to give up on it, so wire .False.
// grace 0 = the configured combat_grace.
hold_target :: proc(s: ^Seq, grace: f64 = 0) {
  a := Script_Action{kind = .Hold_Target}
  a.nums[0] = grace
  act(s, a)
}

skip_target :: proc(s: ^Seq, reason: string = "") {
  a := Script_Action{kind = .Skip_Target}
  a.strs[0] = strings.clone(reason)
  act(s, a)
}

// Attach an `until <cond>` to the step just emitted - it ends early when the condition fires.
// Written as a separate call rather than a parameter so the common case stays uncluttered.
until :: proc(s: ^Seq, c: Script_Event) {
  b := s.b
  if len(b.steps) == 0 {
    builder_error(b, "until: nothing to attach to")
    return
  }
  last := &b.steps[len(b.steps) - 1]
  if last.op != .Action {
    builder_error(b, "until: only attaches to an action")
    return
  }
  last.until = condition_of_event(clone_event(c))
  last.has_until = true
  last.src = step_label(last^)
}

// --- combining conditions -----------------------------------------------------------------------
//
// Every proc below that takes a condition is a PROC GROUP over Script_Event and Script_Condition, so an
// existing `branch(&s, focus_lost())` compiles untouched and `branch(&s, all(focus_lost(), aggro()))`
// is the same call with a different argument. That is the whole reason row 0 of a Script_Condition is
// embedded rather than being more[0]: one event IS a condition, so nothing had to be rewritten.

// Every one of them has to hold.
all :: proc(events: ..Script_Event) -> Script_Condition {
  out := Script_Condition{}
  for event, index in events {
    if index >= SCRIPT_MAX_CONDITION_ROWS {
      break
    }
    condition_row_ptr(&out, index)^ = event
    out.row_count = index + 1
  }
  return out
}

// One of them is enough.
any :: proc(evs: ..Script_Event) -> Script_Condition {
  out := all(..evs)
  out.match_any = true
  return out
}

@(private = "file")
clone_condition :: proc(condition: Script_Condition) -> Script_Condition {
  out := condition
  for row in 0 ..< condition_row_count(condition) {
    condition_row_ptr(&out, row)^ = clone_event(condition_row(condition, row))
  }
  return out
}

// --- conditions (values, evaluated at run time) -------------------------------------------------
//
// STRING OWNERSHIP: condition constructors BORROW their strings - the value you get back points at
// whatever you passed in (usually a literal). Only storing a condition into a step clones it, via
// clone_event in branch/loop_until/wait_until/on. Keep it that way: if constructors cloned too, the
// intermediate would leak on every use, and a borrowed literal reaching script_step_free's delete
// would corrupt the heap.

@(private = "file")
ev :: proc(kind: Script_Event_Kind) -> Script_Event {
  return Script_Event{kind = kind}
}

not         :: proc(c: Script_Event) -> Script_Event {out := c; out.negate = !c.negate; return out}
always      :: proc() -> Script_Event {return ev(.Always)}
never       :: proc() -> Script_Event {return ev(.Never)}
no_target   :: proc() -> Script_Event {return ev(.Focus_Lost)}
no_pet      :: proc() -> Script_Event {return not(ev(.Pet_Active))}
pet_out     :: proc() -> Script_Event {return ev(.Pet_Active)}
bag_full    :: proc() -> Script_Event {return ev(.Inv_Full)}
stuck       :: proc() -> Script_Event {return ev(.Stuck)}

killed :: proc(n: int) -> Script_Event {
  c := ev(.Kills)
  c.nums[0] = f64(n)
  return c
}

// NB the slot: nums and strs are counted separately, so `<name> <n>` is strs[0] + nums[0]. See the
// param_slot note in script_blocks.odin - this used to say nums[1] and the number was lost on save.
killed_of :: proc(name: string, n: int) -> Script_Event {
  c := ev(.Kills_Of)
  c.strs[0] = name
  c.nums[0] = f64(n)
  return c
}

after_minutes :: proc(m: f64) -> Script_Event {
  c := ev(.Elapsed)
  c.nums[0] = m
  return c
}

near :: proc(p: [3]f32, radius: f32 = 10) -> Script_Event {
  c := ev(.At_Position)
  c.nums[0] = f64(p[0])
  c.nums[1] = f64(p[2])
  c.nums[2] = f64(radius)
  return c
}

player_within :: proc(radius: f32) -> Script_Event {
  c := ev(.Player_Near)
  c.nums[0] = f64(radius)
  return c
}

player_named_within :: proc(name: string, radius: f32) -> Script_Event {
  c := ev(.Player_Named_Near)
  c.strs[0] = name
  c.nums[0] = f64(radius)
  return c
}

mob_within :: proc(names: string, radius: f32 = 0) -> Script_Event {
  c := ev(.Mob_In_Range)
  c.strs[0] = names
  c.nums[0] = f64(radius)
  return c
}

nothing_within :: proc(radius: f32) -> Script_Event {
  c := ev(.No_Mob_In_Range)
  c.nums[0] = f64(radius)
  return c
}

aggro_on_me :: proc(radius: f32 = 0) -> Script_Event {
  c := ev(.Aggro)
  c.nums[0] = f64(radius)
  return c
}

hp_under :: proc(pct: f64) -> Script_Event {
  c := ev(.Hp_Below)
  c.nums[0] = pct
  return c
}

target_hp_under :: proc(pct: f64) -> Script_Event {
  c := ev(.Target_Hp_Below)
  c.nums[0] = pct
  return c
}

have_target :: proc() -> Script_Event {return ev(.Focus_Live)}
have_pick :: proc() -> Script_Event {return ev(.Picked)}
target_died :: proc() -> Script_Event {return ev(.Target_Died)}

// A clear straight walk to the selected monster. Gate it behind focus_live: with nothing selected this
// is false, so `not target_reachable` on its own would claim something is in the way.
target_reachable :: proc() -> Script_Event {return ev(.Target_Reachable)}

// 0 = your attack_range.
target_within :: proc(range: f64 = 0) -> Script_Event {
  c := ev(.Target_Within)
  c.nums[0] = range
  return c
}

// True <pct> of the time it is asked - the roll behind look-alive's "sometimes take the scenic route".
chance :: proc(pct: f64) -> Script_Event {
  c := ev(.Chance)
  c.nums[0] = pct
  return c
}

penya_at_least :: proc(n: i64) -> Script_Event {
  c := ev(.Penya_At)
  c.nums[0] = f64(n)
  return c
}

// --- reading back what the chart set itself -----------------------------------------------------
//
// The read halves of set_var / add_var. `not(var_is(...))` is "differs from", `not(var_above(...))` is
// "at most" - there are no separate inverse twins, for the same reason no other predicate has one.

// Text match ignoring case; two numbers compare as numbers. <value> may itself be `@other`.
var_is :: proc(name: string, value: string) -> Script_Event {
  c := ev(.Var_Is)
  c.strs[0] = name
  c.strs[1] = value
  return c
}

// Strictly above. An unset (or non-numeric) variable reads as 0.
var_above :: proc(name: string, n: f64) -> Script_Event {
  c := ev(.Var_Above)
  c.strs[0] = name
  c.nums[0] = n
  return c
}

// Strictly below. An unset (or non-numeric) variable reads as 0.
var_below :: proc(name: string, n: f64) -> Script_Event {
  c := ev(.Var_Below)
  c.strs[0] = name
  c.nums[0] = n
  return c
}

@(private = "file")
clone_event :: proc(c: Script_Event) -> Script_Event {
  out := c
  out.strs[0] = strings.clone(c.strs[0])
  out.strs[1] = strings.clone(c.strs[1])
  return out
}

// --- the three runtime nodes --------------------------------------------------------------------

// Run the returned sub-sequence only if <c> holds at that moment.
branch :: proc {
	branch_event,
	branch_condition,
}
branch_event :: proc(s: ^Seq, c: Script_Event) -> Seq {
  return branch_condition(s, condition_of_event(c))
}
branch_condition :: proc(s: ^Seq, c: Script_Condition) -> Seq {
  return open_block(s, Script_Step{op = .If, condition = clone_condition(c)})
}

// Repeat the returned sub-sequence until <c> holds. Checked before each pass, so a condition that
// is already true skips the body entirely.
loop_until :: proc {
	loop_until_event,
	loop_until_condition,
}
loop_until_event :: proc(s: ^Seq, c: Script_Event) -> Seq {
  return open_block(s, Script_Step{op = .While, condition = condition_of_event(not(clone_event(c)))})
}
// Negating a MULTI-row condition is not `not` on each row - it is De Morgan's, so all-of becomes
// any-of and every row flips. Doing it here rather than asking the caller to is what keeps
// `loop_until(all(a, b))` meaning "until both hold".
loop_until_condition :: proc(s: ^Seq, c: Script_Condition) -> Seq {
  inv := clone_condition(c)
  inv.match_any = !c.match_any
  for i in 0 ..< condition_row_count(c) {
    r := condition_row_ptr(&inv, i)
    r.negate = !r.negate
  }
  return open_block(s, Script_Step{op = .While, condition = inv})
}

// A fixed repeat count. This one IS expressible with an Odin `for` when the body is identical every
// pass - reach for that first. Use this when the body must stay a single node for the editor's sake.
loop_times :: proc(s: ^Seq, n: int) -> Seq {
  return open_block(s, Script_Step{op = .Repeat, count = n})
}

// Block until <c> fires.
wait_until :: proc {
	wait_until_event,
	wait_until_condition,
}
wait_until_event :: proc(s: ^Seq, c: Script_Event) {
  wait_until_condition(s, condition_of_event(c))
}
wait_until_condition :: proc(s: ^Seq, c: Script_Condition) {
  emit(s, Script_Step{op = .Wait_For, condition = clone_condition(c)})
}

// Abort the whole run unless <c> holds - the "did that actually work" check after a teleport.
require :: proc(s: ^Seq, c: Script_Event) {
  fail := branch(s, not(c))
  abort(&fail)
}

// An interrupt: checked before every step for the whole run, edge-triggered (fires on the
// false->true transition, then latches until the condition drops).
on :: proc {
	on_event,
	on_condition,
}
on_event :: proc(s: ^Seq, c: Script_Event, do_action: Script_Action) {
  on_condition(s, condition_of_event(c), do_action)
}
on_condition :: proc(s: ^Seq, c: Script_Condition, do_action: Script_Action) {
  emit(s, Script_Step{op = .On, condition = clone_condition(c), action = do_action})
}

// The interrupt bodies worth having pre-made; `on` takes any Script_Action.
do_abort :: proc() -> Script_Action {return Script_Action{kind = .Stop}}
do_alert :: proc() -> Script_Action {return Script_Action{kind = .Alert}}

do_key :: proc(k: string) -> Script_Action {
  a := Script_Action{kind = .Press_Key}
  a.strs[0] = strings.clone(k)
  return a
}

do_wait :: proc(secs: f64) -> Script_Action {
  a := Script_Action{kind = .Wait}
  a.nums[0] = secs
  return a
}

// --- graph authoring ----------------------------------------------------------------------------
//
// Everything above builds STRUCTURED programs, where the shape is nesting and Odin's own scopes close
// the blocks. These build the other kind: a graph, where every node names its successors and an edge is
// free to point backwards. That is what the node editor produces, and these exist so a behaviour written
// in Odin can produce (and a self-test can exercise) exactly the same data.
//
// The idiom is EMIT FIRST, WIRE SECOND, because a back-edge names a node that does not exist yet when
// you reach the node that points at it:
//
//     top := here(b)                       // remember where the loop starts
//     wait(&s, 0.02)
//     out := branch_node(&s, after_minutes(0.005))
//     wire(b, out, .False, top)            // loop back
//     done := ...
//     wire(b, out, .True, done)
//
// A node with no outgoing edge falls through to the next emitted step, so a mostly-linear graph only
// needs wiring where it actually branches.

// Which of a node's two outgoing edges to set.
Edge_Kind :: enum {
  True, // goto_id - the only edge on a plain node, the TRUE arm of a branch
  False, // else_id - a branch's false arm
}

// The id of the step most recently emitted. Nothing is emitted yet -> 0, which is "no node".
here :: proc(b: ^Builder) -> Node_Id {
  return len(b.steps) == 0 ? 0 : b.steps[len(b.steps) - 1].id
}

wire :: proc(b: ^Builder, from: Node_Id, edge: Edge_Kind, to: Node_Id) {
  for &s in b.steps {
    if s.id != from {
      continue
    }
    if edge == .True {
      s.goto_id = to
    } else {
      s.else_id = to
    }
    s.src = step_label(s)
    return
  }
  builder_error(b, "wire: no node with that id in this program")
}

// An unconditional jump. Wire its .True edge to say where.
goto_node :: proc(s: ^Seq) -> Node_Id {
  emit(s, Script_Step{op = .Goto})
  return here(s.b)
}

// A two-way branch. Wire .True and .False; an unwired arm ends the program.
branch_node :: proc {
	branch_node_event,
	branch_node_condition,
}
branch_node_event :: proc(s: ^Seq, c: Script_Event) -> Node_Id {
  return branch_node_condition(s, condition_of_event(c))
}
branch_node_condition :: proc(s: ^Seq, c: Script_Condition) -> Node_Id {
  emit(s, Script_Step{op = .Branch, condition = clone_condition(c)})
  return here(s.b)
}

// An explicit terminator. In the main program it ends the run; inside an interrupt region it hands
// control back to the suspended program.
return_node :: proc(s: ^Seq) {
  emit(s, Script_Step{op = .Return})
}
