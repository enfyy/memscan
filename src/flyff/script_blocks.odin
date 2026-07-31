package flyff

import "core:fmt"
import "core:strconv"
import "core:strings"

import "../engine"

// ===========================================================================
// The block catalog - the single source of truth for what a behaviour script can DO and NOTICE.
//
// One table entry per block. The same entry drives the parser, the unparser (`script show`), the
// `script blocks` listing, the pre-run availability check, and - later - a node editor's palette
// and port list. Adding a block means adding a row plus its procs; nothing else has to learn
// about it. Same shape as PRESETS (preset.odin) and setup_groups (setup.odin).
//
// AVAILABILITY IS PART OF THE CATALOG. A block whose functionality does not exist yet (chat, key
// presses, NPC menus) is still listed, with `avail` reporting what it needs. It parses, `script
// blocks` shows it as [--] with the reason, and `script run` refuses UP FRONT rather than dying
// halfway through a run. That makes this table the feature's roadmap as well as its dispatch.
//
// PHASES. A long-running action is start-then-poll, which is exactly the state machine's
// Enter/Update/Exit (see engine/statemachine.odin):
//   start -> Enter   : issue the thing (write the destination, turn auto on)
//   poll  -> Update  : has it finished? (arrived, kill quota met)
//   exit  -> Exit    : undo whatever start did, on ANY exit - completion, abort, detach, or a
//                      script that stopped. This is the half the old hardcoded modes never had,
//                      and it is why `script stop` mid-walk actually halts the character.
// ===========================================================================

// --- parameters -----------------------------------------------------------------------------

// How one argument is parsed, stored, and printed back. Coord takes TWO num slots (x,z);
// everything else takes one slot of its storage class.
//
// The last five are ALL one string slot and are parsed, written and round-tripped identically - they
// differ only in what the node editor offers you and what the linter is allowed to say. That is the
// point: `.Str` used to mean a key name, a variable name, a monster name, a player name, an NPC name,
// a path name, a chat fragment and a whole command line, so every one of them drew as the same bare
// text box and the first feedback you got was a run that died. A kind is the cheapest place to put the
// answer, because every row already fills one in.
Param_Kind :: enum {
  Num,      // any number
  Duration, // seconds (float)
  Percent,  // 0-100
  // x,z. TWO num slots for the literal, plus ONE string slot for the case the numbers cannot hold:
  // `walk_to @spot`. Empty string = the numbers are the value, which is every chart written so far
  // and every literal written from now on. See script_coord.
  Coord,
  Str,      // free text - what is LEFT once the kinds below have claimed their meanings
  Names,    // a comma-separated monster-name list, stored verbatim (parse_target_names splits it)
  Mob,      // ONE monster name
  Key,      // a key name (KEY_NAMES is the corpus; vk_from_name is the judge)
  Var_Name, // NAMES a variable rather than referencing one - `dir`, never `@dir`
  Choice,   // one of a fixed set, spelled out by the row's `choices`
  // Names a BEHAVIOUR DOCUMENT - which sub-chart a call node runs. Its corpus is the sub-chart
  // registry, the way .Var_Name's is the chart's own variables: derived from what exists right now,
  // not from a table.
  Chart_Name,
}

// Is this kind stored in a string slot? Seven of the eleven are, and the count is what param_slot walks.
param_kind_is_str :: proc(k: Param_Kind) -> bool {
  switch k {
  case .Str, .Names, .Mob, .Key, .Var_Name, .Choice, .Chart_Name:
    return true
  case .Num, .Duration, .Percent, .Coord:
    return false
  }
  return false
}

Param_Spec :: struct {
  name:     string, // the parser / file / `script show` spelling. NOT a label.
  kind:     Param_Kind,
  optional: bool,
  def:      f64, // default when optional and omitted (numeric kinds only)
  // What the number MEANS, for the human-facing renderer only (script_prose.odin). .Duration already
  // implies seconds and .Percent implies %, so this is for the cases that would otherwise read as a
  // bare number: world units, and the one Duration measured in minutes rather than seconds. The
  // special value "bool" prints on/off - a 0/1 flag is a number to the parser and to the file, and
  // making it a Param_Kind of its own would ripple through every generic consumer to buy nothing.
  // (The node editor DOES draw a "bool" as a checkbox; that is a widget choice, not a storage one.)
  unit:     string,
  // The human half. The chart options panel is GENERATED from these rows, so a parameter without a
  // title is an unlabelled knob and a parameter without help is one you have to read the source to
  // set. script_selftest_meta fails when either is empty, which is what stops a new block landing
  // undocumented. `title` is the label; `help` is one sentence saying what it does and - for an
  // optional one - what its default means.
  title:    string,
  help:     string,
  min_value, max_value: f64, // drag/slider clamp. Both 0 = unbounded.
  // .Choice only: the values offered. A SUGGESTION, not a constraint - the field still takes free
  // text, because `@name` has to be typable into anything (a chart that picks its own key at run time
  // is the whole reason variables exist). The linter warns about a value outside the set; it never
  // refuses one.
  choices:  []string,
}

// WHICH SLOT A PARAMETER LIVES IN. The two storage classes are counted SEPARATELY: the n'th numeric
// parameter is nums[n] and the m'th string parameter is strs[m], regardless of how they interleave.
// So `kills_of <name> <n>` is strs[0] + nums[0], NOT strs[0] + nums[1].
//
// Every generic consumer already derives this - bhv_parse_params, script_write_params, and the node
// editor's inspector all walk the spec with two cursors - but a block's own start/fired proc indexes
// the payload BY HAND, and that is where the two can silently disagree. They did: kills_of and
// player_named_near read nums[1] while the file format wrote nums[0], so a saved .bhv came back with
// the number zeroed, and mob_within's builder stored a radius the block never read. Nothing crashes
// and `script show` looks right, because the renderer and the reader agreed with each other.
//
// param_slots is the one derivation; script_selftest_payload proves every row round-trips through it.
// If you hand-index a payload in a block proc, index it the way this says.
//
// A .Coord claims BOTH: nums[num_slot] and nums[num_slot+1] for the literal, strs[str_slot] for the
// `@spot` case. Every other kind uses one or the other, and param_slot hands back whichever one that
// is. (No block today has a .Coord followed by a string argument, so nothing was renumbered when the
// Coord started consuming a string slot - but the derivation is what keeps that true if one appears.)
param_slots :: proc(spec: []Param_Spec, i: int) -> (num_slot: int, str_slot: int) {
  ni, si := 0, 0
  for p, k in spec {
    if k == i {
      return ni, si
    }
    switch p.kind {
    case .Num, .Duration, .Percent:
      ni += 1
    case .Coord:
      ni += 2
      si += 1
    case .Str, .Names, .Mob, .Key, .Var_Name, .Choice, .Chart_Name:
      si += 1
    }
  }
  return 0, 0
}

// The one slot a non-Coord argument lives in. A .Coord answers with its NUMERIC slot; ask
// param_slots for its string half.
param_slot :: proc(spec: []Param_Spec, i: int) -> int {
  num_slot, str_slot := param_slots(spec, i)
  if i >= 0 && i < len(spec) && param_kind_is_str(spec[i].kind) {
    return str_slot
  }
  return num_slot
}

// A parsed block instance. Deliberately a flat fixed payload rather than a per-kind union: it
// keeps the table generic, makes the whole step POD (no ownership beyond `strs`), and gives a node
// editor a fixed port layout to bind to.
Script_Action :: struct {
  kind: Script_Action_Kind,
  nums: [4]f64,
  strs: [2]string, // owned by the Script_Run that parsed them
}

Script_Event :: struct {
  kind:   Script_Event_Kind,
  nums:   [4]f64,
  strs:   [2]string, // owned by the Script_Run that parsed them
  // `not <event>` - the negation lives on the EVENT rather than on the step, so one implementation
  // covers every site an event can appear: if / while / until / wait_for / on. Without it every
  // predicate would need a hand-written inverse twin (the way no_mob_in_range mirrors mob_in_range),
  // which does not scale past a handful of blocks.
  negate: bool,
}

// A CONDITION: one or more events, joined by all-of or any-of.
//
// Every place that takes a condition takes one of these - a branch, a wait, a watcher's trigger, an
// action's `until`. There are deliberately NO boolean nodes on the canvas: a second kind of wire
// (data, feeding a control node) would have doubled what a reader has to understand, to express
// something that is really a property of the test itself. Rows in a list are what people already draw
// when they write a rule down.
//
// Row 0 is EMBEDDED rather than sitting in the array, which is the whole reason this could be dropped
// in: `condition.kind`, `condition.strs[0]` and `condition.negate` still mean row 0, so the hundred
// places that only ever cared about one event did not have to change, and a one-row condition is
// byte-identical in the file to what an event used to write.
//
// `row_count` counts ALL rows including row 0, and 0 is read as 1 - so a zero-valued Script_Condition
// is one empty event, exactly what a zero-valued Script_Event was. Iterate with condition_row_count,
// never with the field.
SCRIPT_MAX_CONDITION_ROWS :: 4

Script_Condition :: struct {
  using first_row: Script_Event,
  extra_rows:      [SCRIPT_MAX_CONDITION_ROWS - 1]Script_Event, // rows 1 .. row_count-1
  row_count:       int,
  match_any:       bool, // false = every row must hold; true = one is enough
}

// How many rows this condition really has. 0 is stored by everything that never set it, and means one.
condition_row_count :: proc(condition: Script_Condition) -> int {
  return condition.row_count <= 1 ? 1 : min(condition.row_count, SCRIPT_MAX_CONDITION_ROWS)
}

// Row <index>, for read-only walks. Row 0 is the embedded one.
condition_row :: proc(condition: Script_Condition, index: int) -> Script_Event {
  return index == 0 ? condition.first_row : condition.extra_rows[index - 1]
}

// Row <index> for mutation. Same split, and the one place that has to know about it.
condition_row_ptr :: proc(condition: ^Script_Condition, index: int) -> ^Script_Event {
  return index == 0 ? &condition.first_row : &condition.extra_rows[index - 1]
}

// Wrap a single event as a one-row condition. The bridge for every existing caller that has an event.
condition_of_event :: proc(ev: Script_Event) -> Script_Condition {
  return Script_Condition{first_row = ev, row_count = 1}
}

// Append a row. Returns false when the condition is already full. The caller owns <event>'s strings on
// the way in and the condition owns them afterwards.
condition_add_row :: proc(condition: ^Script_Condition, event: Script_Event) -> bool {
  rows := condition_row_count(condition^)
  if rows >= SCRIPT_MAX_CONDITION_ROWS {
    return false
  }
  condition_row_ptr(condition, rows)^ = event
  condition.row_count = rows + 1
  return true
}

// Remove row <index>, shifting the rest down. Frees that row's strings - it is being deleted, and
// nothing else holds them. Refuses to remove the last row: a condition with no rows would render as
// nothing and evaluate as nothing, where an empty ROW at least says "pick a condition".
condition_remove_row :: proc(condition: ^Script_Condition, index: int) -> bool {
  rows := condition_row_count(condition^)
  if rows <= 1 || index < 0 || index >= rows {
    return false
  }
  removed := condition_row_ptr(condition, index)
  delete(removed.strs[0])
  delete(removed.strs[1])
  for shift := index; shift < rows - 1; shift += 1 {
    condition_row_ptr(condition, shift)^ = condition_row(condition^, shift + 1)
  }
  condition_row_ptr(condition, rows - 1)^ = {}
  condition.row_count = rows - 1
  return true
}

Step_Status :: enum {
  Running,
  Done,
  Failed,
}

// Per-instance event bookkeeping. Each `until` / `if` / `while` / `wait_for` / `on` site gets its
// own, armed when the site is entered - so `until kills 50` counts from where IT started, and two
// sites watching the same event never share a baseline.
Event_State :: struct {
  armed_at:  i64,
  base_i64:  i64, // baseline counter (kills, penya, ...)
  next_poll: i64, // throttle deadline for events that cost something to check
  armed:     bool,
  latched:   bool, // edge-detection for `on` watchers - see script_interrupts
}

// One Event_State per row of a Script_Condition, plus the LATCH for the condition as a whole. The latch
// belongs to the condition rather than to a row: an `on` watcher fires on the false->true edge of the
// whole test, and a per-row latch would fire on whichever row happened to flip.
Condition_State :: struct {
  rows:    [SCRIPT_MAX_CONDITION_ROWS]Event_State,
  latched: bool,
}

// Per-instance action scratch, reset by the pc walker when the step is entered.
Step_Scratch :: struct {
  started_at:  i64,
  wp:          [3]f32, // waypoint (walk-style actions)
  best:        f32,    // closest distance seen (progress watchdog)
  progress_at: i64,
  flag:        bool,   // per-action spare (e.g. "start already issued")
  deadline:    i64,    // absolute end time (wait_random rolls its duration once, on entry)
  // The key press_key actually put down, resolved once in start. Re-resolving it in exit would re-read
  // the argument, and an argument can be `@dir` - so a variable that changed in between would release a
  // key that was never pressed and leave the real one down.
  vk:          u32,
  // Target-holding actions (hold_target, approach) keep their whole watch state here rather than on
  // Session. That is the point of the migration: the stuck window, the combat-grace stamp and the
  // reach debounce belong to the BLOCK that is watching, so they are torn down with it and two charts
  // can never share one baseline.
  obj:         uintptr, // the object this step latched onto
  hp_last:     i64,     // its last seen HP
  hp_drop_at:  i64,     // when that HP last FELL - the combat-grace stamp
  probe_at:    i64,     // next reach-probe deadline
  fails:       int,     // consecutive failed probes (debounce) / side-step attempts
  // Progress against the TARGET, as opposed to `best`/`progress_at` which watch the current WAYPOINT.
  // approach needs both: reaching every waypoint you aim at while the mob walks away from you at the
  // same speed is perfect waypoint progress and no progress at all, and the waypoint watchdog cannot
  // see it because each new hop resets it.
  target_best:        f32,
  target_progress_at: i64,
  // .Loop's iteration count. It lives on the NODE rather than on the run's loop stack because a graph
  // loop can be entered from anywhere and left by an edge that never comes back through the head -
  // a stack frame would be pushed and never popped. loop_active says "I am mid-loop", which is what
  // distinguishes arriving fresh from coming back round.
  loop_active:   bool,
  loop_remaining:   int,
}

// --- kinds ----------------------------------------------------------------------------------

Script_Action_Kind :: enum {
  None,
  Wait,
  Var,
  Add,
  Read_Value,
  Stop,
  Fail,
  Wait_Random,
  // The targeting ladder, one block per rung of tc_pick_one. Scan once, then ask each rung in turn;
  // a rung that finds nothing FAILS, so its fail edge is the wire to the next rung.
  Scan_Mobs,
  Pick_Aggro,
  Pick_Melee,
  Pick_Avoid,
  Pick_Pocket,
  Pick_Cluster,
  Pick_Density,
  Pick_Nearest,
  Pick_In_Range,
  Sweep_Lane,
  Lock_Target,
  Approach,
  Hold_Target,
  Count_Kill,
  Skip_Target,
  Walk_To,
  Walk_By,
  Jump,
  Jump_To,
  Jump_By,
  Target,
  Farm,
  Sweep_To,
  Alert,
  Alert_Clear,
  Pause,
  Run_Cmd,
  Press_Key,
  Key_Down,
  Key_Up,
  // --- not implemented yet (see the NOT-YET block section); registered so they parse and are
  // discoverable, and so `script run` refuses up front instead of dying mid-run.
  Attack_Once,
  Say,
  Whisper,
  Npc_Talk,
  Npc_Menu,
  Sweep_Record,
  Sweep_Play,
}

Script_Event_Kind :: enum {
  None,
  Always,
  Never,
  Kills,
  Kills_Of,
  Elapsed,
  Inv_Full,
  Penya_At,
  Mob_In_Range,
  No_Mob_In_Range,
  Aggro,
  Player_Near,
  Player_Named_Near,
  Hp_Below,
  Target_Hp_Below,
  At_Position,
  Pet_Active,
  Focus_Lost,
  Focus_Live,
  Picked,
  Target_Died,
  Target_Within,
  Target_Reachable,
  Chance,
  Stuck,
  // Reading the script's own scratch values. THREE kinds rather than one with a comparison argument:
  // a comparison would have to live in a numeric slot (both string slots are taken by the name and the
  // value), so the file would read `var_is dir 0 D` and the .bhv format would stop being legible. The
  // negative halves come free from `not`, which every condition row already draws: `not var_is` is !=,
  // `not var_above` is <=, `not var_below` is >=.
  Var_Is,
  Var_Above,
  Var_Below,
  // --- not implemented yet (see the NOT-YET block section)
  Chat_Msg,
  Whisper_From,
  Captcha,
}

// --- definitions ----------------------------------------------------------------------------

// `name` is the SPELLING - what you type, what the .bhv file holds, what `script show` prints. `title`
// is what a human reads on a node, and `cat` is what colours it. The two are deliberately separate:
// the machine surfaces must stay stable and greppable, and the readable surfaces must not be forced to
// inherit snake_case from them. An empty title falls back to a prettified name (see block_title), so a
// newly added block is never unreadable, only unpolished.
Action_Def :: struct {
  kind:   Script_Action_Kind,
  name:   string,
  title:  string,
  cat:    Block_Cat,
  params: []Param_Spec,
  blurb:  string,
  // Can this block's start or poll ever report .Failed? Declared rather than derived, because the
  // linter is the consumer and it has no way to ask a proc what it might return. What it buys: "this
  // node can fail and its fail wire goes nowhere, so the run will end here" - the single most common
  // way an authored chart stops somewhere its author did not expect. Keep it honest when adding a
  // block: a false `false` turns the warning off for the one node that needed it.
  can_fail: bool,
  // Is there code behind this block AT ALL? Static, unlike `avail` - which answers the dynamic "can it
  // run right now" (attached? findmove pinned? game window up?). The two used to be one field and that
  // conflation is why the editor refused to PLACE a block while detached: readiness is a property of
  // this moment, implementedness is a property of the tool. Authoring is gated on this and nothing
  // else - a block that merely needs an attach or a pin is placeable, drawn dimmed with its reason,
  // and still refused by script_check_avail when the run starts.
  not_built:     bool,
  not_built_why: string, // what recon would unblock it; only read when not_built
  avail:  proc(session: ^Session) -> (ok: bool, why: string), // nil = always available
  start:  proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status,
  poll:   proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status, // nil = start's verdict is final
  exit:   proc(ctx: ^Behaviour_Context, step: ^Script_Step),                // nil = nothing to undo
}

Event_Def :: struct {
  kind:   Script_Event_Kind,
  name:   string,
  // Phrased as a STATEMENT ("Target died", "Bag is full"), because the same string has to work as a
  // branch's question with a "?" appended and as a while/wait_for's condition without one.
  title:  string,
  cat:    Block_Cat,
  params: []Param_Spec,
  blurb:  string,
  not_built:     bool,   // see Action_Def.not_built - same split, same reason
  not_built_why: string,
  avail:  proc(session: ^Session) -> (ok: bool, why: string),
  arm:    proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State), // nil = stateless
  fired:  proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool,
}

// --- param spec tables ----------------------------------------------------------------------

// PARAMETER TABLES. One per block wherever the block would want to SAY something different about
// "the same" argument, shared only where the sentence is genuinely identical. A radius is not a
// radius: `no_mob_in_range`'s is the emptiness you are waiting for, `player_near`'s is how close
// somebody may come, and `aggro`'s is a cap on how far away a monster may notice you from. A shared
// table can carry a shared `name` honestly but not a shared `help`, and the options panel is nothing
// but those help lines - so the tables split along the sentence, not along the type.
//
// Every ladder tunable is OPTIONAL with def = 0 meaning "use the configured value" (attack_range,
// melee_range, density_min_gain, ...). A chart therefore stays correct when you retune from the CLI,
// and only states a number when it deliberately wants to differ. Every one of them says so in `help`,
// because a bare 0 in the options panel otherwise reads as "disabled".

@(rodata)
PARAMS_WAIT := [?]Param_Spec {
  {
    name = "seconds", kind = .Duration, title = "Seconds", max_value = 600,
    help = "How long to stand still here before the chart moves on.",
  },
}

@(rodata)
PARAMS_VAR := [?]Param_Spec {
  {
    name = "name", kind = .Var_Name, title = "Variable name",
    help = "Which variable to write - the bare name, NOT @name. The REPL's own 'var' command reads and writes the same store.",
  },
  {
    name = "value", kind = .Str, title = "Value",
    help = "What to store in it. Anything; a number can then be compared and added to. @name works here, so one variable can be copied into another.",
  },
}

@(rodata)
PARAMS_ADD := [?]Param_Spec {
  {
    name = "name", kind = .Var_Name, title = "Variable name",
    help = "Which counter to add to - the bare name, NOT @name. It is created at 0 the first time, so you need not set it up.",
  },
  {
    name = "delta", kind = .Num, optional = true, def = 1, title = "Amount",
    help = "How much to add each time this runs. Negative counts down.",
  },
}

// What `read_value` can pull out of the running game. ONE block with a list rather than a block per
// reading: they differ only in which four lines of RPM run, and thirteen near-identical rows would
// bury the palette for no gain. The list is also the honest statement of what the tool can see.
//
// A `_position` reads as "x,z", which is exactly what a Coord argument takes - so
// `read_value spot player_position` then `walk_to @spot` is the round trip, and neither end had to
// learn a position TYPE. `_percent` is 0-100 so it can be compared with var_above/var_below directly.
// A constant rather than an @(rodata) variable, so it can be named inside PARAMS_READ_VALUE below -
// a rodata initializer has to be constant, and a slice OF one is not.
READ_VALUE_SOURCES :: []string {
  "player_position",
  "player_hp",
  "player_hp_max",
  "player_hp_percent",
  "target_name",
  "target_position",
  "target_hp",
  "target_hp_max",
  "target_hp_percent",
  "target_distance",
  "penya",
  "inventory_used",
  "inventory_free",
}

@(rodata)
PARAMS_READ_VALUE := [?]Param_Spec {
  {
    name = "name", kind = .Var_Name, title = "Variable name",
    help = "Which variable to write it into - the bare name, NOT @name. Read a position into one and a later 'Walk to a spot' can take @name instead of numbers, which is what makes a chart work anywhere rather than only where it was written.",
  },
  {
    name = "source", kind = .Choice, title = "What to read", choices = READ_VALUE_SOURCES,
    help = "Which reading to store. The target ones mean the monster you currently have selected, and the block fails when there is nothing selected. A position is stored as x,z; a percent as 0-100.",
  },
}

@(rodata)
PARAMS_WAIT_RANDOM := [?]Param_Spec {
  {
    name = "min", kind = .Duration, title = "Shortest", max_value = 600,
    help = "Lower bound of the pause, in seconds.",
  },
  {
    name = "max", kind = .Duration, title = "Longest", max_value = 600,
    help = "Upper bound of the pause, in seconds. The actual wait is rolled once, on entry.",
  },
}

// --- targeting ladder ---

@(rodata)
PARAMS_SCAN_NAMES := [?]Param_Spec {
  {
    name = "names", kind = .Names, optional = true, title = "Monster names",
    help = "Comma-separated list to collect. Leave empty to collect every monster nearby.",
  },
}

@(rodata)
PARAMS_TARGET_NAMES := [?]Param_Spec {
  {
    name = "names", kind = .Names, optional = true, title = "Monster names",
    help = "Comma-separated list; the nearest match is selected. Leave empty for any monster.",
  },
}

@(rodata)
PARAMS_FARM_NAMES := [?]Param_Spec {
  {
    name = "names", kind = .Names, optional = true, title = "Monster names",
    help = "Comma-separated list the auto-brain restricts itself to. Leave empty for any monster.",
  },
}

@(rodata)
PARAMS_MELEE_RANGE := [?]Param_Spec {
  {
    name = "range", kind = .Num, optional = true, def = 0, unit = "u", title = "Melee reach", max_value = 100,
    help = "How close counts as already on top of you, in world units. 0 uses the configured melee_range.",
  },
}

@(rodata)
PARAMS_IN_RANGE := [?]Param_Spec {
  {
    name = "range", kind = .Num, optional = true, def = 0, unit = "u", title = "Reach", max_value = 100,
    help = "Only consider monsters this close, so the rung never proposes a walk. 0 uses the configured attack_range.",
  },
}

@(rodata)
PARAMS_DENSITY := [?]Param_Spec {
  {
    name = "min_gain", kind = .Num, optional = true, def = 0, title = "Minimum gain", max_value = 20,
    help = "How many extra monsters a denser pack must be worth before leaving this one. 0 uses the configured density_min_gain.",
  },
  {
    name = "max_detour", kind = .Num, optional = true, def = 0, unit = "u", title = "Maximum detour", max_value = 500,
    help = "How far you are willing to walk for that denser pack, in world units. 0 uses the configured density_max_detour.",
  },
}

@(rodata)
PARAMS_APPROACH := [?]Param_Spec {
  {
    name = "max_range", kind = .Num, optional = true, def = 0, unit = "u", title = "Stop within", max_value = 200,
    help = "Walk until the monster is this close, in world units, hopping in stages. 0 means walk all the way in - to within melee reach.",
  },
  {
    name = "spread", kind = .Num, optional = true, def = 0, unit = "u", title = "Waypoint jitter", max_value = 50,
    help = "Random scatter added to each waypoint, in world units, so the path does not look machine-straight. 0 walks straight at it.",
  },
  {
    name = "sidestep", kind = .Num, optional = true, def = 0, unit = "bool", title = "Step around blocks",
    help = "On: never give up on a blocked monster, side-step around the obstacle instead. This is what hunt mode does.",
  },
}

@(rodata)
PARAMS_GRACE_OPT := [?]Param_Spec {
  {
    name = "grace", kind = .Duration, optional = true, def = 0, title = "Combat grace", max_value = 60,
    help = "Seconds to keep fighting a monster whose HP is still falling before the stuck watchdog may drop it. 0 uses the configured combat_watch grace.",
  },
}

@(rodata)
PARAMS_REASON_OPT := [?]Param_Spec {
  {
    name = "reason", kind = .Str, optional = true, title = "Reason",
    help = "Free text shown in the log and the step trace, so a blacklisting says why it happened.",
  },
}

// --- movement ---

@(rodata)
PARAMS_WALK_TO := [?]Param_Spec {
  {
    name = "x,z", kind = .Coord, title = "Destination",
    help = "The world point to walk to. Here fills in where you are standing right now.",
  },
}

@(rodata)
PARAMS_JUMP_TO := [?]Param_Spec {
  {
    name = "x,z", kind = .Coord, title = "Direction",
    help = "The world point to face and jump towards. Here fills in where you are standing right now.",
  },
}

// RELATIVE coords. `unit = "rel"` is a rendering hint, exactly like "bool" on a numeric flag: it tells
// the node editor this Coord is an OFFSET, so it drops the "Here" button (pasting your absolute position
// into an offset field is nonsense) and labels the axes with a sign.
//
// The point of these two blocks: a chart written with absolute waypoints only works in the spot it was
// authored, and a chart written with offsets works anywhere. Chain them and the offsets are CHORDS - each
// leg starts where the last one ended - so N legs whose vectors sum to zero trace a closed shape around
// wherever you happened to be standing. That is what makes a patrol loop portable.

PARAMS_WALK_BY := [?]Param_Spec {
  {
    name = "dx,dz", kind = .Coord, unit = "rel", title = "Offset from here",
    help = "How far to walk, in world units, measured from where you are standing when this block starts - not an absolute point. Chain several and each leg starts where the last ended.",
  },
}

@(rodata)
PARAMS_JUMP_BY := [?]Param_Spec {
  {
    name = "dx,dz", kind = .Coord, unit = "rel", title = "Offset from here",
    help = "Which way to face and jump, as an offset from where you are standing when this block starts. Only the direction matters, not the distance.",
  },
}

@(rodata)
PARAMS_SWEEP_TO := [?]Param_Spec {
  {
    name = "x,z", kind = .Coord, title = "Lane end",
    help = "The far end of the lane to paint and clear. Here fills in where you are standing right now.",
  },
}

// --- system ---

@(rodata)
PARAMS_RUN_CMD := [?]Param_Spec {
  {
    name = "text", kind = .Str, title = "Command line",
    help = "Any line you could type at the memscan prompt, run exactly as typed.",
  },
}

// Every argument is optional, so a bare `alert` written before these existed still parses and still
// means something sensible. Slots: strs[0]=message, strs[1]=severity, nums[0]=seconds, nums[1]=beep -
// the two storage classes count separately, see param_slots.
@(rodata)
PARAMS_ALERT := [?]Param_Spec {
  {
    name = "message", kind = .Str, optional = true, title = "Message",
    help = "What the banner says - @name is filled in, so 'HP at @hp%' reads the variable. Leave it blank for the border alone, which is the quieter option when the chart itself is the explanation.",
  },
  {
    name = "severity", kind = .Choice, optional = true, title = "Severity", choices = ALERT_SEVERITY_NAMES,
    help = "How loud it looks: info is blue and faint, warn amber, danger red and heaviest. All three move the same way - only the weight changes. Blank means warn.",
  },
  {
    name = "seconds", kind = .Duration, optional = true, def = ALERT_DEFAULT_SECONDS, max_value = 600, title = "Seconds",
    help = "How long it stays up before fading. 0 leaves it up until a 'Clear the alert' block takes it down, which is what you want for something you must acknowledge.",
  },
  {
    name = "beep", kind = .Num, optional = true, unit = "bool", max_value = 1, title = "Beep",
    help = "Also sound the system beep. Off by default; worth turning on for the ones that matter, because it is the only half that still works with the radar window closed.",
  },
}

@(rodata)
PARAMS_KEY := [?]Param_Spec {
  {
    name = "key", kind = .Key, title = "Key",
    help = "The game hotkey to press, such as F1 or 1. The game window does not need to be focused.",
  },
}

// key_down / key_up take the same argument as press_key, but the help has to say something different
// about it: one describes a tap, the others describe half of a hold that outlives the block.
@(rodata)
PARAMS_KEY_DOWN := [?]Param_Spec {
  {
    name = "key", kind = .Key, title = "Key",
    help = "The key to push down and leave down, such as W or space. It stays down until a 'Release a held key' block lets go of it, or the run ends.",
  },
}

@(rodata)
PARAMS_KEY_UP := [?]Param_Spec {
  {
    name = "key", kind = .Key, title = "Key",
    help = "The key to let go of. Releasing one that was never held does nothing.",
  },
}

@(rodata)
PARAMS_SAY := [?]Param_Spec {
  {
    name = "text", kind = .Str, title = "Message",
    help = "The line to write in chat.",
  },
}

@(rodata)
PARAMS_WHISPER := [?]Param_Spec {
  {
    name = "who", kind = .Str, title = "Player",
    help = "Exact character name to whisper.",
  },
  {
    name = "text", kind = .Str, title = "Message",
    help = "The line to send them.",
  },
}

@(rodata)
PARAMS_NPC_NAME := [?]Param_Spec {
  {
    name = "name", kind = .Str, title = "NPC name",
    help = "Exact name of the NPC to open dialogue with.",
  },
}

@(rodata)
PARAMS_NPC_MENU := [?]Param_Spec {
  {
    name = "n", kind = .Num, title = "Option number", min_value = 1, max_value = 20,
    help = "Which entry of the open NPC menu to choose, counting from 1 at the top.",
  },
}

@(rodata)
PARAMS_PATH_NAME := [?]Param_Spec {
  {
    name = "name", kind = .Str, title = "Path name",
    help = "What to save the recorded path as, or which saved path to replay.",
  },
}

// --- events ---

@(rodata)
PARAMS_KILLS := [?]Param_Spec {
  {
    name = "n", kind = .Num, title = "Kill count", min_value = 1, max_value = 5000,
    help = "How many kills have to happen after this point in the chart before the condition holds.",
  },
}

@(rodata)
PARAMS_KILLS_OF := [?]Param_Spec {
  {
    name = "name", kind = .Mob, title = "Monster name",
    help = "Exact species name, spelled the way the game shows it.",
  },
  {
    name = "n", kind = .Num, title = "Kill count", min_value = 1, max_value = 5000,
    help = "How many of that species have to die since the run started.",
  },
}

// The one Duration that is NOT seconds - hence the explicit unit.
@(rodata)
PARAMS_MINUTES := [?]Param_Spec {
  {
    name = "minutes", kind = .Duration, unit = "min", title = "Minutes", max_value = 720,
    help = "How long has to pass after this point in the chart before the condition holds.",
  },
}

@(rodata)
PARAMS_PENYA := [?]Param_Spec {
  {
    name = "n", kind = .Num, title = "Penya", max_value = 1e9,
    help = "The balance to wait for. Holds once your penya has reached this number.",
  },
}

@(rodata)
PARAMS_MOB_RANGE := [?]Param_Spec {
  {
    name = "names", kind = .Names, title = "Monster names",
    help = "Comma-separated list to look for. Leave empty to accept any monster.",
  },
  {
    name = "radius", kind = .Num, optional = true, def = 0, unit = "u", title = "Radius", max_value = 500,
    help = "How far around you to look, in world units. 0 uses the configured attack_range.",
  },
}

@(rodata)
PARAMS_CLEAR_RADIUS := [?]Param_Spec {
  {
    name = "radius", kind = .Num, unit = "u", title = "Radius", max_value = 500,
    help = "How large a circle around you has to be empty of monsters, in world units.",
  },
}

@(rodata)
PARAMS_AGGRO_RADIUS := [?]Param_Spec {
  {
    name = "radius", kind = .Num, optional = true, def = 0, unit = "u", title = "Radius", max_value = 500,
    help = "Only count monsters coming for you from within this distance. 0 counts them at any distance.",
  },
}

@(rodata)
PARAMS_PLAYER_RADIUS := [?]Param_Spec {
  {
    name = "radius", kind = .Num, unit = "u", title = "Radius", max_value = 500,
    help = "How close another player has to come, in world units.",
  },
}

@(rodata)
PARAMS_NAME_RADIUS := [?]Param_Spec {
  {
    name = "name", kind = .Str, title = "Player name",
    help = "Exact character name to watch for.",
  },
  {
    name = "radius", kind = .Num, unit = "u", title = "Radius", max_value = 500,
    help = "How close that player has to come, in world units.",
  },
}

@(rodata)
PARAMS_HP_PERCENT := [?]Param_Spec {
  {
    name = "percent", kind = .Percent, title = "HP threshold",
    help = "Holds while YOUR health is under this share of maximum.",
  },
}

@(rodata)
PARAMS_TARGET_HP_PERCENT := [?]Param_Spec {
  {
    name = "percent", kind = .Percent, title = "Target HP threshold",
    help = "Holds while the selected monster's health is under this share of maximum. It reads 0 when it dies.",
  },
}

@(rodata)
PARAMS_CHANCE := [?]Param_Spec {
  {
    name = "percent", kind = .Percent, title = "Odds",
    help = "How often this comes out true. Rolled fresh every single time the condition is asked.",
  },
}

@(rodata)
PARAMS_TARGET_RANGE := [?]Param_Spec {
  {
    name = "range", kind = .Num, optional = true, def = 0, unit = "u", title = "Range", max_value = 200,
    help = "How close the selected monster has to be, in world units. 0 uses the configured attack_range.",
  },
}

@(rodata)
PARAMS_COORD_RADIUS := [?]Param_Spec {
  {
    name = "x,z", kind = .Coord, title = "Spot",
    help = "The world point to test against. Here fills in where you are standing right now.",
  },
  {
    name = "radius", kind = .Num, optional = true, def = 10, unit = "u", title = "Radius", max_value = 500,
    help = "How close to that point counts as arrived, in world units.",
  },
}

// --- reading a variable ---

@(rodata)
PARAMS_VAR_IS := [?]Param_Spec {
  {
    name = "name", kind = .Var_Name, title = "Variable name",
    help = "Which variable to look at. Write the bare name here, not @name.",
  },
  {
    name = "value", kind = .Str, title = "Equals",
    help = "What it has to hold. Text matches ignoring case; two numbers compare as numbers. @name works here, so one variable can be compared to another.",
  },
}

@(rodata)
PARAMS_VAR_ABOVE := [?]Param_Spec {
  {
    name = "name", kind = .Var_Name, title = "Variable name",
    help = "Which counter to look at. Write the bare name here, not @name.",
  },
  {
    name = "n", kind = .Num, title = "Is more than",
    help = "The threshold it has to be strictly above. A variable that is unset, or that does not hold a number, counts as 0.",
  },
}

@(rodata)
PARAMS_VAR_BELOW := [?]Param_Spec {
  {
    name = "name", kind = .Var_Name, title = "Variable name",
    help = "Which counter to look at. Write the bare name here, not @name.",
  },
  {
    name = "n", kind = .Num, title = "Is less than",
    help = "The threshold it has to be strictly below. A variable that is unset, or that does not hold a number, counts as 0.",
  },
}

@(rodata)
PARAMS_CHAT_TEXT := [?]Param_Spec {
  {
    name = "text", kind = .Str, title = "Text",
    help = "The message fragment to watch for in chat.",
  },
}

@(rodata)
PARAMS_WHISPER_FROM := [?]Param_Spec {
  {
    name = "name", kind = .Str, title = "Player name",
    help = "Exact character name whose whisper to watch for.",
  },
}

// --- the action catalog ---------------------------------------------------------------------
// Not @(rodata): the rows hold proc pointers and param slices, which aren't constant initializers,
// and the lookups below hand out ^Action_Def (so the array has to be addressable). Treat as
// read-only by convention - nothing mutates these after startup.

ACTIONS := [?]Action_Def {
  {
    kind = .Wait, name = "wait", title = "Wait", cat = .Timing, params = PARAMS_WAIT[:],
    blurb = "pause the script for N seconds",
    start = act_wait_start, poll = act_wait_poll,
  },
  {
    kind = .Var, name = "var", title = "Set a variable", cat = .Vars, params = PARAMS_VAR[:],
    blurb = "set a session variable (the same @name the REPL's 'var' command sets)",
    start = act_var_start,
  },
  {
    kind = .Add, name = "add", title = "Add to a variable", cat = .Vars, params = PARAMS_ADD[:],
    blurb = "add to a numeric variable (counters); creates it at 0 if unset",
    start = act_add_start,
  },
  {
    kind = .Read_Value, name = "read_value", title = "Read a value", cat = .Vars,
    params = PARAMS_READ_VALUE[:], can_fail = true,
    blurb = "store a live reading in a variable - where you are, the selected monster's name/HP/position/distance, your HP, penya, bag space",
    avail = avail_attached, start = act_read_value_start,
  },
  {
    kind = .Stop, name = "stop", title = "Stop the run", cat = .Flow, params = {},
    blurb = "end the run here (the script's Exit still runs, so anything in flight is torn down)",
    start = act_stop_start,
  },
  {
    kind = .Fail, name = "fail", title = "Fail on purpose", cat = .Flow, params = {}, can_fail = true,
    blurb = "fail on purpose - takes the fail edge if one is wired, else ends the run (authoring/tests)",
    start = act_fail_start,
  },
  {
    kind = .Wait_Random, name = "wait_random", title = "Wait a random moment", cat = .Timing, params = PARAMS_WAIT_RANDOM[:],
    blurb = "pause for a random time between min and max seconds (the human-hesitation delay)",
    start = act_wait_random_start, poll = act_wait_random_poll,
  },

  // --- the targeting ladder ---------------------------------------------------------------------
  {
    kind = .Scan_Mobs, name = "scan_mobs", title = "Look around", cat = .Sense, params = PARAMS_SCAN_NAMES[:], can_fail = true,
    blurb = "collect the nearby monsters once, for the pick_* rungs to choose from (no names = any)",
    avail = avail_attached, start = act_scan_start, poll = act_scan_poll,
  },
  {
    kind = .Pick_Aggro, name = "pick_aggro", title = "One coming at me", cat = .Target, params = {}, can_fail = true,
    blurb = "rung 1: a monster already coming for you (any distance). Fails if none",
    avail = avail_attached, start = act_pick_aggro,
  },
  {
    kind = .Pick_Melee, name = "pick_melee", title = "One in melee reach", cat = .Target, params = PARAMS_MELEE_RANGE[:], can_fail = true,
    blurb = "rung 2: a monster on top of you (default melee_range). Fails if none",
    avail = avail_attached, start = act_pick_melee,
  },
  {
    kind = .Pick_Avoid, name = "pick_avoid", title = "One the other way", cat = .Target, params = {}, can_fail = true,
    blurb = "rung 3: after a blocked skip, one on the opposite side. Fails unless a skip just armed it",
    avail = avail_attached, start = act_pick_avoid,
  },
  {
    kind = .Pick_Pocket, name = "pick_pocket", title = "One right here", cat = .Target, params = {}, can_fail = true,
    blurb = "rung 4: within attack_range of where you stand, nearest the last kill. Fails if none",
    avail = avail_attached, start = act_pick_pocket,
  },
  {
    kind = .Pick_Cluster, name = "pick_cluster", title = "Stay on this pack", cat = .Target, params = {}, can_fail = true,
    blurb = "rung 5: keep eating the pack you committed to. Fails if there is no live commitment",
    avail = avail_attached, start = act_pick_cluster,
  },
  {
    kind = .Pick_Density, name = "pick_density", title = "Densest pack", cat = .Target, params = PARAMS_DENSITY[:], can_fail = true,
    blurb = "rung 6: detour to a denser pack, if it clears both the gain and detour gates",
    avail = avail_attached, start = act_pick_density,
  },
  {
    kind = .Pick_Nearest, name = "pick_nearest", title = "Nearest one", cat = .Target, params = {}, can_fail = true,
    blurb = "rung 7: the nearest eligible monster - the fallback. Fails only if nothing is eligible",
    avail = avail_attached, start = act_pick_nearest,
  },
  {
    kind = .Pick_In_Range, name = "pick_in_range", title = "Only what's in reach", cat = .Target, params = PARAMS_IN_RANGE[:], can_fail = true,
    blurb = "only what is already in reach of where you stand - never proposes a walk (sweep lanes)",
    avail = avail_attached, start = act_pick_in_range,
  },
  {
    kind = .Sweep_Lane, name = "sweep_lane", title = "Drive the lane", cat = .Move, params = {}, can_fail = true,
    blurb = "drive the painted lane: erase what you cover, hop forward once the circle is clear",
    avail = avail_attached, start = act_sweep_lane_start, poll = act_sweep_lane_poll, exit = act_sweep_lane_exit,
  },
  {
    kind = .Lock_Target, name = "lock_target", title = "Select it", cat = .Target, params = {}, can_fail = true,
    blurb = "select the monster the rungs picked. Fails if it died or moved out from under the pick",
    avail = avail_attached, start = act_lock_target,
  },
  {
    kind = .Approach, name = "approach", title = "Walk to it", cat = .Move, params = PARAMS_APPROACH[:], can_fail = true,
    blurb = "walk to the picked monster before locking it (jittered waypoints). Fails when blocked",
    avail = avail_moveto, start = act_approach_start, poll = act_approach_poll, exit = act_approach_exit,
  },
  {
    kind = .Hold_Target, name = "hold_target", title = "Stay on target", cat = .Combat, params = PARAMS_GRACE_OPT[:], can_fail = true,
    blurb = "stay on the locked monster until it is gone; fails if the approach jams or it goes unreachable",
    avail = avail_attached, start = act_hold_start, poll = act_hold_poll,
  },
  {
    kind = .Count_Kill, name = "count_kill", title = "Count the kill", cat = .Combat, params = {},
    blurb = "count the picked monster as killed (stats, leaderboard, kill anchor, radar zap)",
    avail = avail_attached, start = act_count_kill,
  },
  {
    kind = .Skip_Target, name = "skip_target", title = "Blacklist and drop", cat = .Target, params = PARAMS_REASON_OPT[:],
    blurb = "blacklist the picked monster and deselect, so the next pass takes a different one",
    avail = avail_attached, start = act_skip_target,
  },

  {
    kind = .Walk_To, name = "walk_to", title = "Walk to a spot", cat = .Move, params = PARAMS_WALK_TO[:], can_fail = true,
    blurb = "walk to a world point and wait until you arrive",
    avail = avail_moveto, start = act_walk_start, poll = act_walk_poll, exit = act_walk_exit,
  },
  {
    kind = .Walk_By, name = "walk_by", title = "Walk a bit further", cat = .Move, params = PARAMS_WALK_BY[:], can_fail = true,
    blurb = "walk an OFFSET from where you are standing, not to a fixed point - so the chart works anywhere in the world",
    avail = avail_moveto, start = act_walk_by_start, poll = act_walk_poll, exit = act_walk_exit,
  },
  {
    kind = .Jump, name = "jump", title = "Jump", cat = .Move, params = {}, can_fail = true,
    blurb = "jump once (the client's own jump guards all apply)",
    avail = avail_jump, start = act_jump_start,
  },
  {
    kind = .Jump_To, name = "jump_to", title = "Jump towards a spot", cat = .Move, params = PARAMS_JUMP_TO[:], can_fail = true,
    blurb = "face a world point, start walking there, and jump (a directional jump)",
    avail = avail_move_and_jump, start = act_jump_to_start,
  },
  {
    kind = .Jump_By, name = "jump_by", title = "Jump a bit further", cat = .Move, params = PARAMS_JUMP_BY[:], can_fail = true,
    blurb = "a directional jump, aimed by an OFFSET from where you are standing rather than at a fixed point",
    avail = avail_move_and_jump, start = act_jump_by_start,
  },
  {
    kind = .Target, name = "target", title = "Select nearest monster", cat = .Target, params = PARAMS_TARGET_NAMES[:], can_fail = true,
    blurb = "select the nearest matching monster (no names = any monster)",
    avail = avail_attached, start = act_target_start,
  },
  {
    kind = .Farm, name = "farm", title = "Hand over to auto", cat = .Combat, params = PARAMS_FARM_NAMES[:],
    blurb = "hand steering to the auto-brain and farm (pair it with 'until <event>')",
    avail = avail_attached, start = act_farm_start, poll = act_farm_poll, exit = act_farm_exit,
  },
  {
    kind = .Sweep_To, name = "sweep_to", title = "Sweep to a spot", cat = .Move, params = PARAMS_SWEEP_TO[:], can_fail = true,
    blurb = "paint a lane from here to a world point and clear it (turns the auto-brain on)",
    avail = avail_moveto, start = act_sweep_start, poll = act_sweep_poll, exit = act_sweep_exit,
  },
  {
    kind = .Alert, name = "alert", title = "Raise an alert", cat = .System, params = PARAMS_ALERT[:],
    blurb = "put a coloured border and a banner over the radar window - the way a chart says something you need to look at",
    start = act_alert_start,
  },
  {
    kind = .Alert_Clear, name = "alert_clear", title = "Clear the alert", cat = .System, params = {},
    blurb = "take the alert down early (it fades); pairs with an alert whose duration is 0",
    start = act_alert_clear_start,
  },
    {
    kind = .Pause, name = "pause", title = "Pause the run", cat = .Flow, params = {},
    blurb = "freeze the chart here until you press play again (the transport, or 'script resume')",
    avail = avail_attached, start = act_pause_start,
  },
  {
    kind = .Run_Cmd, name = "run", title = "Run a command", cat = .System, params = PARAMS_RUN_CMD[:],
    blurb = "run any REPL command line - the escape hatch that makes every existing feature scriptable",
    start = act_run_cmd_start,
  },

  {
    kind = .Press_Key, name = "press_key", title = "Press a key", cat = .System, params = PARAMS_KEY[:], can_fail = true,
    blurb = "press a hotkey in the game (skill slot, potion, teleport item) - the game need not be focused",
    avail = avail_press_key, start = act_press_key_start, poll = act_press_key_poll, exit = act_press_key_exit,
  },
  {
    kind = .Key_Down, name = "key_down", title = "Hold a key down", cat = .System, params = PARAMS_KEY_DOWN[:], can_fail = true,
    blurb = "push a key down and LEAVE it down - for anything the client only does while the key is held (walking, hold-to-attack). Pair it with 'key_up'; the run releases it anyway when it ends",
    avail = avail_press_key, start = act_key_down_start,
  },
  {
    kind = .Key_Up, name = "key_up", title = "Release a held key", cat = .System, params = PARAMS_KEY_UP[:], can_fail = true,
    blurb = "let go of a key that 'key_down' is holding (releasing one that was never held does nothing)",
    avail = avail_press_key, start = act_key_up_start,
  },

  // --- NOT YET IMPLEMENTED --------------------------------------------------------------------
  // These are the blocks the design calls for whose underlying capability does not exist in the tool
  // yet. They are listed on purpose: `script blocks` doubles as the roadmap, the parser accepts them
  // so a script can be written ahead of the capability, and script_check_avail refuses the run up
  // front with the reason - which beats discovering it halfway through a farm. Each `not_built_why`
  // names the recon that would unblock it. Implementing one = clearing not_built and swapping in a
  // real `start`, nothing else changes.
  //
  // These are also the ONLY blocks the editor refuses to place. Everything above is placeable whether
  // or not a process is attached - see Action_Def.not_built.
  {
    kind = .Attack_Once, name = "attack_once", title = "Swing once", cat = .Combat, params = {}, can_fail = true,
    blurb = "swing once at the current target, then move on (for AoE pulls)",
    not_built = true,
    not_built_why = "no attack primitive yet (you hold the attack key today) - needs SendActMsg(OBJMSG_ATTACK..) recon, like derive_jump_msg did for jump",
    start = act_not_implemented,
  },
  {
    kind = .Say, name = "say", title = "Say in chat", cat = .System, params = PARAMS_SAY[:], can_fail = true,
    blurb = "write a message in chat",
    not_built = true,
    not_built_why = "needs chat-send recon (the client's own say/whisper packet builder)",
    start = act_not_implemented,
  },
  {
    kind = .Whisper, name = "whisper", title = "Whisper", cat = .System, params = PARAMS_WHISPER[:], can_fail = true,
    blurb = "whisper a message to one player",
    not_built = true,
    not_built_why = "needs chat-send recon (the client's own say/whisper packet builder)",
    start = act_not_implemented,
  },
  {
    kind = .Npc_Talk, name = "npc_talk", title = "Talk to an NPC", cat = .System, params = PARAMS_NPC_NAME[:], can_fail = true,
    blurb = "open dialogue with a named NPC",
    not_built = true,
    not_built_why = "needs NPC interaction + menu recon (dialogue open / menu select packets)",
    start = act_not_implemented,
  },
  {
    kind = .Npc_Menu, name = "npc_menu", title = "Pick an NPC option", cat = .System, params = PARAMS_NPC_MENU[:], can_fail = true,
    blurb = "choose entry N of the open NPC menu",
    not_built = true,
    not_built_why = "needs NPC interaction + menu recon (dialogue open / menu select packets)",
    start = act_not_implemented,
  },
  {
    kind = .Sweep_Record, name = "sweep_record", title = "Record a path", cat = .Move, params = PARAMS_PATH_NAME[:], can_fail = true,
    blurb = "record the path you walk and save it under <name>",
    not_built = true,
    not_built_why = "needs path recording + serialization (the 2.0 backlog item) - 'sweep to <x,z>' works today",
    start = act_not_implemented,
  },
  {
    kind = .Sweep_Play, name = "sweep_play", title = "Replay a path", cat = .Move, params = PARAMS_PATH_NAME[:], can_fail = true,
    blurb = "replay a recorded path as a sweep lane",
    not_built = true,
    not_built_why = "needs path recording + serialization (the 2.0 backlog item) - 'sweep to <x,z>' works today",
    start = act_not_implemented,
  },
}

// --- the event catalog -----------------------------------------------------------------------
// Not @(rodata), same reason as ACTIONS.

EVENTS := [?]Event_Def {
  {
    kind = .Always, name = "always", title = "Always", cat = .Flow, params = {},
    blurb = "always true (authoring + testing)",
    fired = ev_always,
  },
  {
    kind = .Never, name = "never", title = "Never", cat = .Flow, params = {},
    blurb = "never true (authoring + testing)",
    fired = ev_never,
  },
  {
    kind = .Kills, name = "kills", title = "Enough kills", cat = .Combat, params = PARAMS_KILLS[:],
    blurb = "N kills have happened since this point in the script",
    avail = avail_attached, arm = ev_kills_arm, fired = ev_kills,
  },
  {
    kind = .Kills_Of, name = "kills_of", title = "Enough of one kind", cat = .Combat, params = PARAMS_KILLS_OF[:],
    blurb = "N kills of one species since the run started (name must match exactly)",
    avail = avail_attached, arm = ev_kills_of_arm, fired = ev_kills_of,
  },
  {
    kind = .Elapsed, name = "elapsed", title = "Long enough", cat = .Timing, params = PARAMS_MINUTES[:],
    blurb = "N minutes have passed since this point in the script",
    fired = ev_elapsed,
  },
  {
    kind = .Inv_Full, name = "inv_full", title = "Bag is full", cat = .Sense, params = {},
    blurb = "the bag has no free slots",
    avail = avail_inv, fired = ev_inv_full,
  },
  {
    kind = .Penya_At, name = "penya_at", title = "Penya target hit", cat = .Sense, params = PARAMS_PENYA[:],
    blurb = "your penya balance has reached N",
    avail = avail_penya, fired = ev_penya_at,
  },
  {
    kind = .Mob_In_Range, name = "mob_in_range", title = "Monster in range", cat = .Sense, params = PARAMS_MOB_RANGE[:],
    blurb = "a matching monster is within <radius> (0 = your attack_range)",
    avail = avail_movers, fired = ev_mob_in_range,
  },
  {
    kind = .No_Mob_In_Range, name = "no_mob_in_range", title = "Spot is clear", cat = .Sense, params = PARAMS_CLEAR_RADIUS[:],
    blurb = "NO monster is within <radius> - the spot is cleared out",
    avail = avail_movers, fired = ev_no_mob_in_range,
  },
  {
    kind = .Aggro, name = "aggro", title = "Something wants me", cat = .Sense, params = PARAMS_AGGRO_RADIUS[:],
    blurb = "something is coming for YOU (its m_idDest is your objid)",
    avail = avail_aggro, fired = ev_aggro,
  },
  {
    kind = .Player_Near, name = "player_near", title = "Player nearby", cat = .Sense, params = PARAMS_PLAYER_RADIUS[:],
    blurb = "another PLAYER is within <radius> (the peace-out trigger)",
    avail = avail_players, fired = ev_player_near,
  },
  {
    kind = .Player_Named_Near, name = "player_named_near", title = "That player is nearby", cat = .Sense, params = PARAMS_NAME_RADIUS[:],
    blurb = "a player with that exact name is within <radius>",
    avail = avail_players, fired = ev_player_named_near,
  },
  {
    kind = .Hp_Below, name = "hp_below", title = "My HP is low", cat = .Sense, params = PARAMS_HP_PERCENT[:],
    blurb = "your HP has dropped below <percent> of maximum",
    avail = avail_hp, fired = ev_hp_below,
  },
  {
    kind = .Target_Hp_Below, name = "target_hp_below", title = "Target HP is low", cat = .Combat, params = PARAMS_TARGET_HP_PERCENT[:],
    blurb = "the SELECTED mob's HP is below <percent> (0 = it died / stopped being selectable)",
    avail = avail_hp, fired = ev_target_hp_below,
  },
  {
    kind = .At_Position, name = "at_position", title = "I'm at the spot", cat = .Sense, params = PARAMS_COORD_RADIUS[:],
    blurb = "you are within <radius> of that world point - the teleport / zone-change confirmation",
    avail = avail_attached, fired = ev_at_position,
  },
  {
    kind = .Pet_Active, name = "pet_active", title = "Pet is out", cat = .Sense, params = {},
    blurb = "your loot-collecting pet is summoned ('not pet_active' to check it needs calling out)",
    avail = avail_pet, fired = ev_pet_active,
  },
  {
    kind = .Focus_Lost, name = "focus_lost", title = "Nothing selected", cat = .Target, params = {},
    blurb = "nothing is selected right now (the target died, or was dropped)",
    avail = avail_attached, fired = ev_focus_lost,
  },
  {
    kind = .Focus_Live, name = "focus_live", title = "Something selected", cat = .Target, params = {},
    blurb = "something IS selected and still alive",
    avail = avail_attached, fired = ev_focus_live,
  },
  {
    kind = .Picked, name = "picked", title = "A rung picked one", cat = .Target, params = {},
    blurb = "a pick_* rung has chosen a monster this pass",
    fired = ev_picked,
  },
  {
    kind = .Target_Died, name = "target_died", title = "Target died", cat = .Combat, params = {},
    blurb = "the monster you picked actually DIED (not merely deselected) - the kill test",
    avail = avail_attached, fired = ev_target_died,
  },
  {
    kind = .Target_Reachable, name = "target_reachable", title = "Target is reachable", cat = .Target, params = {},
    blurb = "a straight walk to the selected monster is clear of terrain and props ('not' = something is in the way)",
    avail = avail_attached, fired = ev_target_reachable,
  },
  {
    kind = .Target_Within, name = "target_within", title = "Target in range", cat = .Target, params = PARAMS_TARGET_RANGE[:],
    blurb = "the selected monster is within <range> of you (0 = your attack_range)",
    avail = avail_attached, fired = ev_target_within,
  },
  {
    kind = .Chance, name = "chance", title = "Coin flip", cat = .Timing, params = PARAMS_CHANCE[:],
    blurb = "a coin flip: true <percent> of the time it is asked (rolled fresh on every visit)",
    fired = ev_chance,
  },
  {
    kind = .Stuck, name = "stuck", title = "Walk got stuck", cat = .Move, params = {},
    blurb = "a walk stopped making progress (posted by walk_to before it gives up)",
    fired = ev_stuck,
  },
  {
    kind = .Var_Is, name = "var_is", title = "Variable equals", cat = .Vars, params = PARAMS_VAR_IS[:],
    blurb = "a variable holds this value - the way a chart branches on something it set itself ('not' makes it 'differs from')",
    fired = ev_var_is,
  },
  {
    kind = .Var_Above, name = "var_above", title = "Variable is more than", cat = .Vars, params = PARAMS_VAR_ABOVE[:],
    blurb = "a numeric variable is above N ('not var_above' is 'at most N')",
    fired = ev_var_above,
  },
  {
    kind = .Var_Below, name = "var_below", title = "Variable is less than", cat = .Vars, params = PARAMS_VAR_BELOW[:],
    blurb = "a numeric variable is below N ('not var_below' is 'at least N')",
    fired = ev_var_below,
  },

  // --- NOT YET IMPLEMENTED (see the note on the action side) -----------------------------------
  {
    kind = .Chat_Msg, name = "chat_msg", title = "Chat says", cat = .Sense, params = PARAMS_CHAT_TEXT[:],
    blurb = "a chat message containing <text> appeared",
    not_built = true,
    not_built_why = "needs chat-read recon (where incoming chat lands, and how to watch it)",
    fired = ev_not_implemented,
  },
  {
    kind = .Whisper_From, name = "whisper_from", title = "Whisper from", cat = .Sense, params = PARAMS_WHISPER_FROM[:],
    blurb = "that player whispered you",
    not_built = true,
    not_built_why = "needs chat-read recon (where incoming chat lands, and how to watch it)",
    fired = ev_not_implemented,
  },
  {
    kind = .Captcha, name = "captcha", title = "CAPTCHA appeared", cat = .Sense, params = {},
    blurb = "an anti-bot CAPTCHA popup appeared",
    not_built = true,
    not_built_why = "needs CAPTCHA popup recon (finding the dialog's live state)",
    fired = ev_not_implemented,
  },
}

// --- lookup ---------------------------------------------------------------------------------

action_def :: proc(kind: Script_Action_Kind) -> ^Action_Def {
  for &d in ACTIONS {
    if d.kind == kind {
      return &d
    }
  }
  return nil
}

action_def_by_name :: proc(name: string) -> ^Action_Def {
  for &d in ACTIONS {
    if d.name == name {
      return &d
    }
  }
  return nil
}

event_def :: proc(kind: Script_Event_Kind) -> ^Event_Def {
  for &d in EVENTS {
    if d.kind == kind {
      return &d
    }
  }
  return nil
}

event_def_by_name :: proc(name: string) -> ^Event_Def {
  for &d in EVENTS {
    if d.name == name {
      return &d
    }
  }
  return nil
}

// --- arguments --------------------------------------------------------------------------------
//
// EVERY string argument of every block goes through here, so `key_down @dir` and `scan_mobs @quarry`
// mean what they look like they mean.
//
// EXECUTION TIME, not load time. The whole point of a variable is that it differs between two visits to
// the same node, so the expansion has to happen where the argument is READ rather than where the step
// was parsed - which also means `script show` and the .bhv file keep the `@name` you wrote instead of
// freezing whatever it happened to hold when you saved.
//
// A MISS IS TRACED, NOT SWALLOWED. engine.expand_vars treats an unknown @name as a hard error precisely
// so `poke 0 @typo` cannot write to address 0; a block argument is gentler - there is nothing dangerous
// about a key name - but silence was the actual bug being fixed here. An unexpanded @name surfaces three
// layers away as "'@dir' isn't a key name", which reads like a typo in the key rather than a missing
// variable. So the raw text goes through (the block's own validation then refuses it, as before) and the
// trace says why.
//
// NUMERIC arguments are deliberately NOT interpolated: they are f64 slots on a POD payload with no text
// to hold an expression. `var_is` is how a variable reaches a numeric DECISION; `run` is the escape
// hatch for feeding one to a command. A .Coord is the ONE exception (script_coord below) - not as the
// first step of a general expression system, but because a place is the numeric value people actually
// need to name, and it is the only one with somewhere to put the text.
script_arg :: proc(ctx: ^Behaviour_Context, raw: string) -> string {
  if !strings.contains(raw, "@") {
    return raw // the common case, and expand_vars would hand it straight back anyway
  }
  out, ok, bad := engine.expand_vars(&ctx.session.eng, raw, context.temp_allocator)
  if !ok {
    script_trace(ctx.session, script_current_node(ctx), .Warn, "no variable named '%s' - '%s' used as-is", bad, raw)
    return raw
  }
  return out
}

// A .Coord argument, resolved. The literal in nums[] is the value unless the expression slot holds
// something, in which case that is expanded and parsed - `walk_to @spot`, where `spot` is a variable
// holding "6800,3300" (the store is text, so a position needs no new kind of variable; see
// engine/vars.odin, whose own example is exactly this).
//
// A miss FAILS the step rather than quietly walking to 0,0. That is the difference between this and a
// bad key name: an unresolved key does nothing, an unresolved destination sends the character across
// the map.
script_coord :: proc(ctx: ^Behaviour_Context, nums: [4]f64, strs: [2]string, spec: []Param_Spec, index: int) -> (x: f32, z: f32, ok: bool) {
  num_slot, str_slot := param_slots(spec, index)
  raw := strs[str_slot]
  if strings.trim_space(raw) == "" {
    return f32(nums[num_slot]), f32(nums[num_slot + 1]), true
  }
  text := script_arg(ctx, raw)
  v, vok := parse_vec2_literal(text)
  if !vok {
    script_trace(
      ctx.session,
      script_current_node(ctx),
      .Warn,
      "'%s' is not a position - expected x,z, got '%s'",
      raw,
      text,
    )
    return 0, 0, false
  }
  return v[0], v[1], true
}

// The two call shapes, so no block proc has to reach through action_def(..).params - which is a nil
// deref waiting for the one kind that ever loses its catalog row.
script_action_coord :: proc(ctx: ^Behaviour_Context, step: ^Script_Step, index: int) -> (x: f32, z: f32, ok: bool) {
  def := action_def(step.action.kind)
  if def == nil {
    return 0, 0, false
  }
  return script_coord(ctx, step.action.nums, step.action.strs, def.params, index)
}

script_event_coord :: proc(ctx: ^Behaviour_Context, ev: Script_Event, index: int) -> (x: f32, z: f32, ok: bool) {
  def := event_def(ev.kind)
  if def == nil {
    return 0, 0, false
  }
  return script_coord(ctx, ev.nums, ev.strs, def.params, index)
}

// A variable NAME argument (`var`, `add`, `var_is`, ...). NOT expanded - `@dir` there would mean "the
// variable whose name is in dir", and indirection nobody asked for is worse than the mistake it would
// enable. What it does instead is strip a leading `@`, because that mistake is easy, silent and total:
// `var @dir D` creates a variable literally CALLED "@dir", which no @name can ever reference, so every
// later read of @dir misses and the chart dies somewhere else entirely. The linter flags it at authoring
// time; this is the runtime doing the obvious thing anyway.
script_var_name_of :: proc(raw: string) -> string {
  return strings.trim_left(strings.trim_space(raw), "@")
}

// The same, but says so. For ACTIONS only: an action runs once per visit, whereas a condition can be
// polled every 20ms and a trace row per poll would bury the ring it is meant to explain.
script_var_name :: proc(ctx: ^Behaviour_Context, raw: string) -> string {
  name := script_var_name_of(raw)
  if trimmed := strings.trim_space(raw); trimmed != name {
    script_trace(ctx.session, script_current_node(ctx), .Warn, "'%s' is a NAME, not a reference - using '%s'", trimmed, name)
  }
  return name
}

// A variable read as a number. An UNSET one reads as 0 rather than failing, which matches `add`'s "it is
// created at 0 the first time" - so `var_above kills 5` is simply false before anything has counted,
// instead of needing a set-it-up node ahead of the test.
@(private = "file")
script_var_number :: proc(ctx: ^Behaviour_Context, raw_name: string) -> f64 {
  if s, ok := engine.session_var_get(&ctx.session.eng, script_var_name_of(raw_name)); ok {
    if v, vok := strconv.parse_f64(strings.trim_space(s)); vok {
      return v
    }
  }
  return 0
}

// --- action implementations -------------------------------------------------------------------

act_wait_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  step.scratch.started_at = ctx.now
  return .Running
}

act_wait_poll :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  if ctx.now - step.scratch.started_at >= script_secs_ns(step.action.nums[0]) {
    return .Done
  }
  return .Running
}

act_var_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  name := script_var_name(ctx, step.action.strs[0])
  // The VALUE is expanded, so `var previous @dir` copies one variable into another - which is how a
  // chart remembers what it was doing before it changed its mind.
  value := script_arg(ctx, step.action.strs[1])
  engine.session_var_set(&ctx.session.eng, name, value)
  script_trace(ctx.session, step.id, .Step, "%s = %s", name, value == "" ? "(unset)" : value)
  return .Done
}

// Pull one live reading out of the game and store it as text.
//
// There is no position TYPE and no number type anywhere in this: the store is text, a position is
// "x,z", a number is its digits. That is what lets `var`, the REPL, the .bhv file, var_above and a
// Coord argument all agree without any of them learning a new shape - and it is why reading the
// player's position and then walking back to it needs no machinery beyond this block.
//
// FAILS when the reading is not there (nothing selected, not attached), rather than storing a zero.
// A chart that wants to cope wires the fail edge; one that stored 0 for "no target" would compare
// happily against it and act on a number that means nothing.
act_read_value_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  s := ctx.session
  name := script_var_name(ctx, step.action.strs[0])
  if name == "" {
    return .Failed
  }
  source := strings.to_lower(strings.trim_space(script_arg(ctx, step.action.strs[1])), context.temp_allocator)
  text, ok := script_read_value(ctx, source)
  if !ok {
    script_trace(ctx.session, step.id, .Warn, "could not read '%s' - nothing stored in %s", source, name)
    return .Failed
  }
  engine.session_var_set(&s.eng, name, text)
  script_trace(ctx.session, step.id, .Step, "%s = %s", name, text)
  return .Done
}

// One reading, as the text that goes in the variable. Split out so the whole list is readable in one
// screen and so a new source is one case rather than a new block.
@(private = "file")
script_read_value :: proc(ctx: ^Behaviour_Context, source: string) -> (text: string, ok: bool) {
  s := ctx.session
  // Y is deliberately never stored: every consumer re-derives the ground height live, because the
  // height of a spot is the client's business and a saved one goes stale the moment terrain does.
  position_text :: proc(p: [3]f32) -> string {
    return fmt.tprintf("%.1f,%.1f", p[0], p[2])
  }
  // maxHP is the field right after currentHP (see the hp_off note in flyff.odin).
  read_max_hp :: proc(s: ^Session, obj: uintptr) -> (i64, bool) {
    v, vok := engine.read_value(s.proc_info.handle, obj + uintptr(s.layout.hp_off + 4), .I32)
    if !vok {
      return 0, false
    }
    return i64(i32(engine.value_as_u64(.I32, v))), true
  }

  switch source {
  case "player_position":
    ppos, pok := read_player_pos(s)
    if !pok {
      return "", false
    }
    return position_text(ppos), true

  case "player_hp", "player_hp_max", "player_hp_percent":
    player := read_ptr_at(s.proc_info.handle, s.proc_info.base + s.layout.player_rva, engine.Value_Type.U32)
    if player == 0 {
      return "", false
    }
    return script_hp_text(s, player, source, read_max_hp)

  case "target_name":
    focus, fok := read_focus_ptr(s)
    if !fok || focus == 0 {
      return "", false
    }
    nm, nok := read_mover_name(s, focus)
    if !nok || nm == "" {
      return "", false
    }
    return nm, true

  case "target_position":
    focus, fok := read_focus_ptr(s)
    if !fok || focus == 0 {
      return "", false
    }
    tpos, tok := engine.read_vec3(s.proc_info.handle, focus + uintptr(s.layout.pos_off))
    if !tok {
      return "", false
    }
    return position_text(tpos), true

  case "target_hp", "target_hp_max", "target_hp_percent":
    focus, fok := read_focus_ptr(s)
    if !fok || focus == 0 {
      return "", false
    }
    return script_hp_text(s, focus, source, read_max_hp)

  case "target_distance":
    focus, fok := read_focus_ptr(s)
    if !fok || focus == 0 {
      return "", false
    }
    ppos, pok := read_player_pos(s)
    tpos, tok := engine.read_vec3(s.proc_info.handle, focus + uintptr(s.layout.pos_off))
    if !pok || !tok {
      return "", false
    }
    return script_number_text(f64(engine.dist_horizontal(ppos, tpos))), true

  case "penya":
    if !s.penya_seeded {
      return "", false // never read one - 0 here would read as "broke" rather than "unknown"
    }
    return script_number_text(f64(s.penya_last)), true

  case "inventory_used", "inventory_free":
    used, free, _, iok := read_inventory_counts(s)
    if !iok {
      return "", false
    }
    return script_number_text(f64(source == "inventory_used" ? used : free)), true
  }
  return "", false
}

// The HP family, shared by the player and the target because the three readings and the two failure
// modes are identical - only the object differs.
@(private = "file")
script_hp_text :: proc(
  s: ^Session,
  obj: uintptr,
  source: string,
  read_max_hp: proc(s: ^Session, obj: uintptr) -> (i64, bool),
) -> (text: string, ok: bool) {
  if strings.has_suffix(source, "_hp") {
    hp, hok := read_mob_hp(s, obj)
    if !hok {
      return "", false
    }
    return script_number_text(f64(hp)), true
  }
  maxhp, mok := read_max_hp(s, obj)
  if !mok || maxhp <= 0 {
    return "", false
  }
  if strings.has_suffix(source, "_hp_max") {
    return script_number_text(f64(maxhp)), true
  }
  hp, hok := read_mob_hp(s, obj)
  if !hok {
    return "", false
  }
  return script_number_text(f64(hp) * 100.0 / f64(maxhp)), true
}

// A number as a variable's text. Whole values lose the ".000" so a counter reads as a counter, and so
// `var_is kills 20` matches what `add` wrote.
script_number_text :: proc(v: f64) -> string {
  if v == f64(i64(v)) {
    return fmt.tprintf("%d", i64(v))
  }
  return fmt.tprintf("%.2f", v)
}

act_add_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  name := script_var_name(ctx, step.action.strs[0])
  cur := f64(0)
  if s, ok := engine.session_var_get(&ctx.session.eng, name); ok {
    if v, vok := strconv.parse_f64(strings.trim_space(s)); vok {
      cur = v
    }
  }
  cur += step.action.nums[0]
  txt := script_number_text(cur)
  engine.session_var_set(&ctx.session.eng, name, txt)
  script_trace(ctx.session, step.id, .Step, "%s = %s", name, txt)
  return .Done
}

act_stop_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  ctx.session.script.stop_requested = true
  return .Done
}

// The action counterpart of the `never` event: something that reliably fails, so a fail edge can be
// authored and tested without needing a block whose failure depends on the game.
act_fail_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  return .Failed
}

act_wait_random_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  lo := script_secs_ns(min(step.action.nums[0], step.action.nums[1]))
  hi := script_secs_ns(max(step.action.nums[0], step.action.nums[1]))
  step.scratch.started_at = ctx.now
  // Rolled ONCE, on entry, and stored as an absolute deadline - re-rolling every poll would make the
  // delay the minimum of many draws instead of one uniform draw.
  step.scratch.deadline = ctx.now + lookalive_rand_ns(lo, hi)
  return .Running
}

act_wait_random_poll :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  return ctx.now >= step.scratch.deadline ? .Done : .Running
}

// ===========================================================================
// THE TARGETING LADDER
//
// `auto`'s pick used to be one call that ran the whole cascade. Here it is a CHAIN of nodes: one
// scan_mobs, then a pick_* block per rung of tc_pick_one, each wired to the next by its FAIL edge, and
// finally lock_target. That is the whole point of the migration - the priority order is the chart, so
// it can be rewired, and a rung can be dropped by deleting a node.
//
// THE COST MODEL, which is why scan is its own block: tc_collect_cands is a full writable-region scan
// and the watcher ticks every 20ms. It runs ONCE per pick cycle, on the existing background worker
// (scan_job) with no lock held, and every rung then scores the cached list - which is O(n) arithmetic.
// A rung that rescanned would put the whole enumeration back on the tick, which is exactly the stutter
// the background-scan fix removed.
//
// PRE-SELECT SURVIVES AS AN IMPLEMENTATION DETAIL, not a mode: hold_target kicks one background scan
// while you are fighting, anchored at the mob you are killing, so the scan_mobs after the kill finds a
// batch already waiting and completes in the same tick it started.
// ===========================================================================

// Optional per-block overrides. Zero means "use what's configured", so a chart stays correct when the
// numbers are retuned from the CLI and only names a value when it deliberately wants to differ.
@(private = "file")
Rung_Opts :: struct {
  melee, engage, min_gain, max_detour: f64,
}

// The context the rungs score against. Mirrors tc_finish_select's exactly - same ladder, same inputs -
// with one deliberate difference: every rung ENABLE is forced on, because in a chart the node's
// presence is the enable and this block was asked for by name.
@(private = "file")
script_pick_ctx :: proc(ctx: ^Behaviour_Context, opts: Rung_Opts) -> (pick_context: Pick_Ctx, ok: bool) {
  s := ctx.session
  run := &s.script
  world, _, live_player, aok := tc_resolve_anchors(s)
  if !aok {
    return {}, false
  }
  melee, engage := pick_ranges(s)
  if opts.melee > 0 {
    melee = f32(opts.melee)
  }
  if opts.engage > 0 {
    engage = f32(opts.engage)
  }
  min_gain := s.layout.density_min_gain
  if opts.min_gain > 0 {
    min_gain = int(opts.min_gain)
  }
  max_detour := s.layout.density_max_detour
  if opts.max_detour > 0 {
    max_detour = f32(opts.max_detour)
  }
  pick_context = Pick_Ctx {
    // Rank from where the batch was MEASURED (the kill spot for a prefetched batch, the player for a
    // reactive one) but gate in-range on where the player actually stands. Same split as auto.
    player_pos         = run.cand_anchor,
    live_player        = live_player,
    world              = world,
    now                = ctx.now,
    name_filtered      = len(run.cand_names) > 0,
    require_fresh      = true,
    aggro_on           = true,
    melee_on           = true,
    pocket_on          = true,
    gate               = s.reach_gate_on && !hunt_steering_on(s),
    sweep_on           = false, // pick_in_range is the block form of the sweep short-circuit
    fence_on           = s.fence.active,
    avoid_on           = true,
    avoid_dir          = s.auto_avoid_dir,
    last_kill_set      = s.last_kill_set,
    last_kill_pos      = s.last_kill_pos,
    melee              = melee,
    engage             = engage,
    recent             = s.tc_recent[:],
    blocked            = s.auto_blocked[:],
    density            = run.cand_dens,
    density_on         = true,
    min_gain           = min_gain,
    max_detour         = max_detour,
    cluster_committed  = s.cluster_committed,
    cluster_origin_pos = s.cluster_origin_pos,
  }
  return pick_context, true
}

// Every pick_* block is this, with a different rung. Failing (rather than succeeding with nothing) is
// what makes the ladder wireable: the fail edge IS "ask the next rung".
@(private = "file")
script_run_rung :: proc(ctx: ^Behaviour_Context, rung: Rung_Fn, opts := Rung_Opts{}) -> Step_Status {
  s := ctx.session
  run := &s.script
  if len(run.cands) == 0 {
    return .Failed // nothing scanned, or the last scan found nothing
  }
  pick_context, ok := script_pick_ctx(ctx, opts)
  if !ok {
    return .Failed
  }
  idx, stage := rung(s, run.cands[:], pick_context, nil)
  if idx < 0 {
    return .Failed
  }
  c := run.cands[idx]
  run.pick = Script_Pick {
    set   = true,
    obj   = c.obj,
    pos   = c.pos,
    stage = stage,
    pack  = idx < len(run.cand_dens) ? run.cand_dens[idx] : 0,
  }
  return .Done
}

// --- scan_mobs --------------------------------------------------------------------------------

@(private = "file")
script_set_cand_names :: proc(run: ^Script_Run, spec: string) {
  for n in run.cand_names {
    delete(n)
  }
  clear(&run.cand_names)
  for n in parse_target_names(spec) {
    append(&run.cand_names, strings.clone(n))
  }
}

// Kick a background enumeration. False = the anchors are unreadable (not in-game, or the layout is
// unpinned), which is a real failure rather than "wait longer".
@(private = "file")
script_request_scan :: proc(ctx: ^Behaviour_Context) -> bool {
  s := ctx.session
  world, player, player_pos, ok := tc_resolve_anchors(s)
  if !ok {
    return false
  }
  tc_scan_request(s, s.script.cand_names[:], world, player, player_pos, false, 0)
  return true
}

// Take a published batch, if one is waiting. This is also how a batch prefetched by hold_target during
// the fight gets picked up, which is what makes the post-kill pick instant.
@(private = "file")
script_consume_batch :: proc(ctx: ^Behaviour_Context) -> bool {
  s := ctx.session
  run := &s.script
  if !s.scan_job.res_ready {
    return false
  }
  cands := s.scan_job.res_cands
  run.cand_anchor = s.scan_job.res_anchor
  s.scan_job.res_ready = false
  s.scan_job.res_cands = nil

  clear(&run.cands)
  append(&run.cands, ..cands[:])
  delete(cands)
  run.cand_at = ctx.now
  run.pick = {} // a new batch invalidates the previous pass's choice

  // Pack sizes for the cluster/density rungs. Always computed: it is O(n^2) over a list of tens, which
  // is nothing next to the scan that produced it, and a chart may add a density rung at any time.
  delete(run.cand_dens)
  run.cand_dens = nil
  if len(run.cands) > 0 {
    _, engage := pick_ranges(s)
    // context.allocator, NOT the default temp: this batch is read by the rungs on later ticks, and
    // behaviour_tick free_all's the scratch arena temp points at every tick.
    run.cand_dens = compute_densities(run.cands[:], density_radius(engage), context.allocator)
  }
  return true
}

act_scan_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  // The block's own names are the chart's answer; `auto 'Aibatt'` is a RUN-SCOPED override of it.
  // That is the whole of what the target spec still means now that the config layer is gone: not a
  // setting that rebuilds the chart, just an argument to this run, which is why it wins over a blank
  // block and loses to one that names something.
  spec := script_arg(ctx, step.action.strs[0])
  if spec == "" && len(ctx.session.auto_names) > 0 {
    spec = strings.join(ctx.session.auto_names[:], ",", context.temp_allocator)
  }
  script_set_cand_names(&ctx.session.script, spec)
  if script_consume_batch(ctx) {
    return .Done // a prefetched batch was already waiting - no wait at all
  }
  if !script_request_scan(ctx) {
    return .Failed
  }
  return .Running
}

act_scan_poll :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  if script_consume_batch(ctx) {
    return .Done
  }
  // The worker can be dropped mid-flight (a generation bump from `auto` stopping, a detach), so
  // re-request rather than waiting forever on a batch that will never arrive.
  if !ctx.session.scan_job.active {
    if !script_request_scan(ctx) {
      return .Failed
    }
  }
  return .Running
}

// --- the rungs --------------------------------------------------------------------------------

act_pick_aggro :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  return script_run_rung(ctx, rung_aggro)
}

act_pick_melee :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  return script_run_rung(ctx, rung_melee, Rung_Opts{melee = step.action.nums[0]})
}

// The one rung with a precondition outside the candidate list: it only means anything right after a
// skip armed the opposite-side hint. Unarmed it must fail so the ladder moves on, or it would just
// return the nearest mob under a misleading stage name.
act_pick_avoid :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  if !ctx.session.auto_avoid_on {
    return .Failed
  }
  return script_run_rung(ctx, rung_avoid)
}

act_pick_pocket :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  return script_run_rung(ctx, rung_pocket)
}

act_pick_cluster :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  return script_run_rung(ctx, rung_cluster)
}

act_pick_density :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  return script_run_rung(ctx, rung_density, Rung_Opts{min_gain = step.action.nums[0], max_detour = step.action.nums[1]})
}

act_pick_nearest :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  return script_run_rung(ctx, rung_nearest)
}

act_pick_in_range :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  return script_run_rung(ctx, rung_sweep, Rung_Opts{engage = step.action.nums[0]})
}

// --- lock / approach / hold -------------------------------------------------------------------

act_lock_target :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  s := ctx.session
  run := &s.script
  if !run.pick.set {
    return .Failed
  }
  // COMMIT-TIME REVALIDATION. The pick came off a batch that may be a second old and was measured from
  // wherever the last kill happened, so between the scan and here the mob can have wandered, been
  // dragged behind cover, or left the fence. tc_precompute_still_valid re-reads its LIVE position and
  // re-tests drift + reach + fence from where the player actually stands - a handful of reads, not a
  // rescan.
  //
  // Legacy auto ran exactly this check at its commit site and the chart cutover dropped it, which left
  // the reach gate's only say over a pre-selected pick being a test measured from the kill spot. That
  // is the whole of "collisions get ignored": nothing between the scan and the lock ever asked whether
  // the thing was reachable from HERE. Failing sends the chart back to rescan (lock's fail edge), and
  // the fresh scan - anchored at the live player - then filters the mob out properly.
  tpos, tok := tc_precompute_still_valid(s, run.pick.obj, run.pick.pos)
  if !tok {
    run.pick.set = false
    return .Failed // freed, wandered too far, now blocked, or outside the fence
  }
  if !auto_commit_pick(s, run.pick.obj, tpos, run.pick.stage, run.pick.pack) {
    run.pick.set = false
    return .Failed // refused: freed, model-less, or already dead
  }
  run.pick.pos = tpos
  s.auto_avoid_on = false // one-shot steer hint, consumed by a pick that stuck
  return .Done
}

@(private = "file")
script_grace_ns :: proc(session: ^Session, param: f64) -> i64 {
  g := param
  if g <= 0 {
    g = f64(session.layout.combat_grace)
  }
  if g <= 0 {
    g = f64(FLYFF_COMBAT_GRACE)
  }
  return i64(g * 1_000_000_000)
}

// Walk to the picked mob before locking it, via jittered intermediate waypoints - the look-alive
// "don't teleport your attention onto things across the map" behaviour, now a node you can delete.
//
// THE BLOCK IS DONE WHEN THE TARGET IS WITHIN <stop_within>, and that is asked every tick rather than
// only when a waypoint is reached. It used to be asked in one place - after arriving at a hop - which
// gave two failures with the same cause:
//   - with max_range unset the FIRST hop ended the block, and a hop is only 40-60% of the way, so
//     "walk to it" stopped half way and reported success;
//   - with it set, a mob that kept moving was chased hop after hop with nothing bounding it, because
//     the only watchdog measured the current WAYPOINT and every new hop reset it. Perfect waypoint
//     progress, no progress at all. From the outside: it follows the mob around and never finishes.
// `sidestep` makes a jam step AROUND the obstacle and keep going instead of failing, which is what
// hunt mode was - a chart that says that is asking not to give up, so the target watchdog side-steps
// for it rather than failing.
act_approach_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  s := ctx.session
  run := &s.script
  if !run.pick.set {
    return .Failed
  }
  ppos, pok := read_player_pos(s)
  if !pok {
    return .Failed
  }
  tpos, tok := engine.read_vec3(s.proc_info.handle, run.pick.obj + uintptr(s.layout.pos_off))
  if !tok {
    run.pick.set = false
    return .Failed
  }
  // Already close enough - nothing to walk. Self-guarding like this is what lets a chart put approach
  // on the path unconditionally: auto had to test the distance at the CALL site (la_max_range for the
  // shrinking hop, LA_STEP_MIN_DIST for a single detour) before deciding to enter the approach at all.
  d := engine.dist_horizontal(ppos, tpos)
  if d <= script_approach_stop_within(step) {
    return .Done
  }
  step.scratch.obj = run.pick.obj
  step.scratch.target_best = d
  step.scratch.target_progress_at = ctx.now
  if !script_approach_hop(ctx, step, ppos, tpos) {
    return .Failed
  }
  return .Running
}

// How close counts as arrived. ONE definition, used by start and by every poll - they disagreed
// before, which is how "0 walks the whole way" ended up meaning "0 walks half way".
@(private = "file")
script_approach_stop_within :: proc(step: ^Script_Step) -> f32 {
  within := f32(step.action.nums[0])
  if within <= 0 {
    within = LA_STEP_MIN_DIST
  }
  return within
}

// Issue one leg of the walk and arm the waypoint watchdog against it. Shared by the first hop and
// every shrinking hop after it.
@(private = "file")
script_approach_hop :: proc(ctx: ^Behaviour_Context, step: ^Script_Step, ppos, tpos: [3]f32) -> bool {
  s := ctx.session
  stop_within := script_approach_stop_within(step)
  remaining := engine.dist_horizontal(ppos, tpos)
  // THE LAST LEG GOES STRAIGHT AT THE MOB. A hop covers 40-60% of what is left and then jitters
  // sideways by up to la_step_spread, so once the gap is comparable to that jitter the hops stop
  // closing it and start circling - the same "follows it around" symptom, arrived at from the other
  // direction. Above that distance the scenic route is the whole point and stays.
  wp: [3]f32
  if remaining <= max(stop_within * 2, LA_STEP_MIN_DIST) {
    wp = {tpos[0], ppos[1], tpos[2]}
  } else {
    spread := f32(step.action.nums[1])
    wp = lookalive_step_point(s, ppos, tpos, spread > 0 ? spread : -1)
  }
  if !write_dest_pos(s, ppos, wp) {
    return false // fence-gated, or the move fields are unpinned
  }
  remote_send_snapshot(s) // broadcast, so other clients see a walk and not a teleport
  step.scratch.wp = wp
  step.scratch.best = engine.dist_horizontal(ppos, wp)
  step.scratch.progress_at = ctx.now
  return true
}

act_approach_poll :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  s := ctx.session
  run := &s.script
  obj := step.scratch.obj
  world, _, ppos, aok := tc_resolve_anchors(s)
  if !aok {
    return .Running // transient read failure; the walk continues client-side meanwhile
  }
  // Still a live, selectable mob? Someone else may have killed it, or it despawned mid-walk.
  if !obj_is_selectable(s, obj, run.cand_names[:]) {
    run.pick.set = false
    return .Failed
  }
  tpos, tok := engine.read_vec3(s.proc_info.handle, obj + uintptr(s.layout.pos_off))
  if !tok || (s.fence.active && !fence_contains(s.fence, tpos[0], tpos[2])) {
    run.pick.set = false
    return .Failed // unreadable, or it drifted outside the geo-fence
  }
  if s.lookalive_on {
    lookalive_jump_core(s, tpos, ctx.now) // occasional travel-jump; self-throttling
  }

  stop_within := script_approach_stop_within(step)
  sidestep := step.action.nums[2] != 0

  // ARE WE THERE YET - asked first, and asked of the TARGET. This is the block's actual exit
  // condition, so it cannot be buried at the end behind "did we reach the waypoint": a mob that walks
  // into range while we are still mid-hop has satisfied the block, and waiting for a stale waypoint
  // before noticing is how a completed approach kept walking.
  d_target := engine.dist_horizontal(ppos, tpos)
  if d_target <= stop_within {
    return .Done
  }

  // Progress watchdog against the TARGET, across hops. `best`/`progress_at` below watch the current
  // waypoint and are reset by every new hop, so on their own they can never see a chase that is going
  // nowhere - which is exactly what following a mob that moves as fast as you do looks like.
  if d_target < step.scratch.target_best - PROGRESS_EPS {
    step.scratch.target_best = d_target
    step.scratch.target_progress_at = ctx.now
  } else if ctx.now - step.scratch.target_progress_at >= APPROACH_CHASE_NS {
    if !sidestep {
      return .Failed // we are not gaining on it - the fail edge decides (normally skip_target)
    }
    // A sidestep chart said "never drop this one", so losing ground is a reason to try another line,
    // not a reason to stop. Re-arm the window so the next stall is judged on its own.
    step.scratch.target_best = d_target
    step.scratch.target_progress_at = ctx.now
    step.scratch.fails += 1
    if step.scratch.fails % HUNT_SIDESTEP_FLIP == 0 {
      s.hunt_side_flip = !s.hunt_side_flip
    }
    wp := hunt_sidestep_point(s, ppos, tpos, s.hunt_side_flip)
    if write_dest_pos(s, ppos, wp) {
      remote_send_snapshot(s)
      step.scratch.wp = wp
      step.scratch.best = engine.dist_horizontal(ppos, wp)
      step.scratch.progress_at = ctx.now
    }
    return .Running
  }

  // Progress watchdog against the CURRENT waypoint: if we stop closing on it while still far, the path
  // is blocked.
  d_wp := engine.dist_horizontal(ppos, step.scratch.wp)
  if d_wp > LA_WP_ARRIVE {
    if d_wp < step.scratch.best - PROGRESS_EPS {
      step.scratch.best = d_wp
      step.scratch.progress_at = ctx.now
      step.scratch.fails = 0
      return .Running
    }
    if ctx.now - step.scratch.progress_at < STUCK_NS {
      return .Running // still walking
    }
    if !sidestep {
      return .Failed // blocked - the fail edge decides what happens (normally skip_target)
    }
    // Committed to this target: step AROUND the obstacle instead of dropping it, flipping the side
    // every few stalls so a dead end eventually gets tried from the other direction.
    step.scratch.fails += 1
    if step.scratch.fails % HUNT_SIDESTEP_FLIP == 0 {
      s.hunt_side_flip = !s.hunt_side_flip
    }
    wp := hunt_sidestep_point(s, ppos, tpos, s.hunt_side_flip)
    if !write_dest_pos(s, ppos, wp) {
      return .Failed
    }
    remote_send_snapshot(s)
    step.scratch.wp = wp
    step.scratch.best = engine.dist_horizontal(ppos, wp)
    step.scratch.progress_at = ctx.now
    return .Running
  }

  // Reached the waypoint and still short of the target: aim the next leg. The mob has almost certainly
  // moved since the last one was chosen, so this re-reads it rather than continuing an old line.
  if s.reach_gate_on && !sidestep && !cand_reachable(s, world, ppos, tpos) {
    return .Failed // the next leg is blocked now
  }
  if !script_approach_hop(ctx, step, ppos, tpos) {
    return .Failed
  }
  return .Running
}

// Halt the walk. This is the Exit that auto had to hand-write at every site that left the approach -
// without it, `script stop` mid-approach leaves the character strolling to the waypoint.
act_approach_exit :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) {
  move_stop(ctx.session)
}

// Stay on the locked mob until it is gone, and be the one place that decides to give up on it.
//
// It folds in all three of auto's target-drop watches, because they share one input (is its HP
// falling?) and duplicating that across separate event blocks would give them racing baselines:
//   - combat watch   - stamp the moment its HP last fell; suppresses both drops below
//   - stuck plateau  - the distance stopped closing while still far = jammed on geometry
//   - reach re-check - it got dragged behind cover after we locked it
// Done = the mob is gone (ask target_died whether that was a kill). Failed = we are dropping it, so
// the fail edge normally goes to skip_target.
act_hold_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  s := ctx.session
  focus, fok := read_focus_ptr(s)
  if !fok || focus == 0 {
    return .Done // nothing selected - nothing to hold
  }
  step.scratch.obj = focus
  step.scratch.best = 1e30
  step.scratch.progress_at = ctx.now
  step.scratch.probe_at = ctx.now + REACH_RECHECK_NS
  step.scratch.fails = 0
  step.scratch.hp_drop_at = 0
  if hp, hok := read_mob_hp(s, focus); hok {
    step.scratch.hp_last = hp
  }
  return .Running
}

act_hold_poll :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  s := ctx.session
  sc := &step.scratch
  focus, fok := read_focus_ptr(s)
  if !fok {
    return .Running // transient read failure
  }
  if focus == 0 || focus != sc.obj || !focus_obj_live(s, focus) {
    return .Done // gone: killed, freed, or deselected. target_died says which.
  }

  // Combat watch. Only a strict DECREASE counts as damage - a rise is regen, a heal, or the allocator
  // handing this pointer to a different mob, and none of those are a fight.
  if hp, hok := read_mob_hp(s, focus); hok {
    if hp < sc.hp_last {
      sc.hp_drop_at = ctx.now
    }
    sc.hp_last = hp
  }
  in_combat := s.combat_watch_on && sc.hp_drop_at != 0 && ctx.now - sc.hp_drop_at < script_grace_ns(s, step.action.nums[0])

  // Pre-select: one background enumeration while the fight runs, anchored where the mob is (which is
  // where we will be standing when it dies), so the scan_mobs after the kill completes immediately.
  // This is all `preselect on|off` means now - there is no cache to invalidate, just a scan started
  // early or not.
  if s.preselect_on && !sc.flag && !s.scan_job.active && !s.scan_job.res_ready {
    if world, player, _, aok := tc_resolve_anchors(s); aok {
      if tpos, tok := engine.read_vec3(s.proc_info.handle, focus + uintptr(s.layout.pos_off)); tok {
        sc.flag = true
        tc_scan_request(s, s.script.cand_names[:], world, player, tpos, true, focus)
      }
    }
  }

  ppos, pok := read_player_pos(s)
  tpos, tok := engine.read_vec3(s.proc_info.handle, focus + uintptr(s.layout.pos_off))
  if !pok || !tok {
    return .Running
  }
  d := engine.dist_3d(ppos, tpos)

  // Stuck plateau. Arriving or landing hits keeps the window fresh, which is what stops a high-HP mob
  // fought from range - a legitimate plateau for the whole kill - from reading as a jam.
  switch {
  case d <= ARRIVE_DIST || in_combat:
    sc.best = d
    sc.progress_at = ctx.now
  case d < sc.best - PROGRESS_EPS:
    sc.best = d
    sc.progress_at = ctx.now
  case s.auto_stuck_on && ctx.now - sc.progress_at >= STUCK_NS:
    return .Failed // `stuck off` keeps holding instead - the old behaviour for ranged play
  }

  // Reach re-check: a mob can be dragged behind cover after it was locked. Probed on a slow cadence and
  // debounced, since clipping happens transiently while rounding a corner.
  if s.reach_gate_on && ctx.now >= sc.probe_at {
    sc.probe_at = ctx.now + REACH_RECHECK_NS
    switch {
    case in_combat, d <= ARRIVE_DIST:
      sc.fails = 0 // demonstrably hitting it - a blocked sightline is moot
    case cand_reachable(s, script_world_ptr(s), ppos, tpos):
      sc.fails = 0
    case:
      sc.fails += 1
      if sc.fails >= REACH_BLOCKED_DEBOUNCE {
        return .Failed
      }
    }
  }
  return .Running
}

@(private = "file")
script_world_ptr :: proc(session: ^Session) -> uintptr {
  world, _, _, _ := tc_resolve_anchors(session)
  return world
}

// --- kill accounting / giving up ----------------------------------------------------------------

// Everything auto did at its kill site, as a node: the tally, the leaderboard attribution, the
// per-species count `kills_of` reads, the kill anchor the pocket/cluster rungs rank from, and the
// radar's laser + zap. A no-op with nothing picked, so a chart that reaches it after a plain deselect
// does not invent a kill.
act_count_kill :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  s := ctx.session
  run := &s.script
  if !run.pick.set {
    return .Done
  }
  s.auto_count += 1
  lb_record_kill(s, run.pick.obj)
  script_note_kill(s, run.pick.obj)
  s.last_kill_pos = run.pick.pos
  s.last_kill_set = true
  record_kill_event(s, run.pick.pos, ctx.now)
  run.pick.set = false
  // auto_stats measures from auto_start, which cli_auto sets. A chart started directly (`script run
  // auto`) never went through it, so without this the rate is computed against a zero epoch and prints
  // a six-figure hour count.
  if s.auto_start == 0 {
    s.auto_start = run.started_at
  }
  fmt.printf("\n[auto] %s\n", auto_stats(s, ctx.now))
  fmt.print("memscan> ")
  return .Done
}

// --- the painted lane ---------------------------------------------------------------------------

// sweep_tick already answers exactly the question a block needs: `handled` means "I own this tick"
// (erasing paint, settling, hopping forward), and false means "your turn - work the circle I am
// standing in". So the block is a thin poll over it:
//
//   Running - the lane is driving; nothing else should happen this tick
//   Done    - it handed back, so the chart falls through to its in-range pick
//   Failed  - the lane is finished or was cleared, which ends the sweep chart
//
// This is the one place the migration REHOSTS rather than rewrites: the lane's erase/settle/hop logic
// is self-contained and had no business being reimplemented as nodes. What changes is who calls it -
// a block the chart owns, instead of a branch near the top of auto_tick.
act_sweep_lane_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  if !ctx.session.sweep_on {
    return .Failed // no lane armed - `sweep to <x,z>` paints one
  }
  return .Running
}

act_sweep_lane_poll :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  s := ctx.session
  if !s.sweep_on {
    return .Failed // finished, or cleared out from under us
  }
  if sweep_tick(s, ctx.now) {
    return .Running
  }
  return .Done
}

act_sweep_lane_exit :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) {
  s := ctx.session
  if s.sweep_walking {
    move_stop(s)
    s.sweep_walking = false
  }
}

act_skip_target :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  s := ctx.session
  run := &s.script
  if !run.pick.set {
    clear_focus(s)
    return .Done
  }
  reason := strings.trim_space(script_arg(ctx, step.action.strs[0]))
  if reason == "" {
    reason = "blocked"
  }
  ppos, _ := read_player_pos(s)
  tpos, _ := engine.read_vec3(s.proc_info.handle, run.pick.obj + uintptr(s.layout.pos_off))
  // steer=true: we jammed trying to reach it, so the obstacle is roughly in its direction and the
  // avoid rung should prefer the other side next pass.
  auto_skip_blocked(s, run.pick.obj, ppos, tpos, reason, true, ctx.now)
  run.pick.set = false
  return .Done
}

// --- event implementations ---------------------------------------------------------------------

ev_always :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return true
}

ev_never :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return false
}

// --- availability predicates ---------------------------------------------------------------------

avail_attached :: proc(session: ^Session) -> (bool, string) {
  if !session.attached || session.ptr_size != 4 {
    return false, "needs a 32-bit Neuz attached"
  }
  return true, ""
}

avail_moveto :: proc(session: ^Session) -> (bool, string) {
  if ok, why := avail_attached(session); !ok {
    return false, why
  }
  if !moveto_configured(session) {
    return false, "needs the move offsets - run 'findmove' (or 'setup <name>')"
  }
  return true, ""
}

avail_jump :: proc(session: ^Session) -> (bool, string) {
  if ok, why := avail_attached(session); !ok {
    return false, why
  }
  if !jump_configured(session) {
    return false, "needs sendactmsg_rva/actmover_off/jump_msg - run 'findmove'"
  }
  return true, ""
}

avail_move_and_jump :: proc(session: ^Session) -> (bool, string) {
  if ok, why := avail_moveto(session); !ok {
    return false, why
  }
  return avail_jump(session)
}

// The tile-window mover gather (radar_gather_movers) needs the landscape object arrays.
avail_movers :: proc(session: ^Session) -> (bool, string) {
  if ok, why := avail_attached(session); !ok {
    return false, why
  }
  L := session.layout
  if L.landobj_off == 0 || L.land_off == 0 || L.landwidth_off == 0 {
    return false, "needs the landscape offsets - run 'setup <name>' (worldscan)"
  }
  return true, ""
}

avail_players :: proc(session: ^Session) -> (bool, string) {
  if ok, why := avail_movers(session); !ok {
    return false, why
  }
  if !prop_gate_ready(session) {
    return false, "can't tell players from monsters without the species gate - run 'findprop'"
  }
  return true, ""
}

avail_aggro :: proc(session: ^Session) -> (bool, string) {
  if ok, why := avail_movers(session); !ok {
    return false, why
  }
  if session.layout.objid_off == 0 || session.layout.iddest_off == 0 {
    return false, "needs objid_off/iddest_off - run 'setup <name>' (findsettarget)"
  }
  return true, ""
}

// --- movement + combat actions ---------------------------------------------------------------------

// A script owns movement. Handing steering to the auto-brain is what `farm` / `sweep_to` are FOR, so
// every other movement block refuses while auto is running rather than fighting it for the character.
script_movement_ok :: proc(ctx: ^Behaviour_Context, what: string) -> bool {
  if !ctx.session.auto_on {
    return true
  }
  fmt.printf(
    "\n[script] '%s' needs the auto-farm off (it steers the character too).\n  fix: 'auto off' before the script, or wrap the farming in a 'farm ... until <event>' block.\n",
    what,
  )
  fmt.print("memscan> ")
  return false
}

act_walk_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  return act_walk_common(ctx, step, "walk_to", false)
}

// The same walk, aimed by an OFFSET from wherever the character is standing when the block starts. Shares
// act_walk_poll and act_walk_exit unchanged - the destination is resolved to a world point here, so
// everything downstream (progress watchdog, stuck posting, move_stop on exit) is identical.
act_walk_by_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  return act_walk_common(ctx, step, "walk_by", true)
}

@(private = "file")
act_walk_common :: proc(ctx: ^Behaviour_Context, step: ^Script_Step, block: string, relative: bool) -> Step_Status {
  if !script_movement_ok(ctx, block) {
    return .Failed
  }
  ppos, pok := read_player_pos(ctx.session)
  if !pok {
    return .Failed
  }
  cx, cz, cok := script_action_coord(ctx, step, 0)
  if !cok {
    return .Failed
  }
  // Y comes from the player either way: the walk is horizontal and the client owns the ground height.
  dest := [3]f32{cx, ppos[1], cz}
  if relative {
    dest[0] += ppos[0]
    dest[2] += ppos[2]
  }
  if !write_dest_pos(ctx.session, ppos, dest) {
    return .Failed // refused (an avoid(!) fence zone) or the player couldn't be resolved
  }
  remote_send_snapshot(ctx.session) // so other clients see a walk, not a teleport
  step.scratch.wp = dest
  step.scratch.best = engine.dist_horizontal(ppos, dest)
  step.scratch.progress_at = ctx.now
  return .Running
}

act_walk_poll :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  ppos, pok := read_player_pos(ctx.session)
  if !pok {
    return .Running // transient read failure - keep walking
  }
  d := engine.dist_horizontal(ppos, step.scratch.wp)
  if d <= SWEEP_ARRIVE {
    return .Done
  }
  if d < step.scratch.best - PROGRESS_EPS {
    step.scratch.best = d
    step.scratch.progress_at = ctx.now
    return .Running
  }
  if ctx.now - step.scratch.progress_at >= STUCK_NS {
    // Give up on this leg but let the script continue, and post Stuck so `on stuck -> ...` and
    // `sense` can see it. Same judgement sweep_tick makes about a jammed hop: whatever is in the way
    // is usually transient (a mob body, another player), and hard-failing the whole run over one
    // blocked leg would kill a long patrol for a temporary obstacle.
    behaviour_raise(ctx.session, .Stuck, Behaviour_Signal{at = ctx.now, num = f64(d)})
    fmt.printf("\n[script] walk_to: no progress for %.0fs, %.0f units short - moving on.\n", f64(STUCK_NS) / 1e9, d)
    fmt.print("memscan> ")
    return .Done
  }
  return .Running
}

// Halt the walk on ANY exit - arrival, `script stop`, an interrupt, a detach. This is the phase the
// old hardcoded modes never had, and it is exactly why stopping a script stops the character instead
// of letting it drift to the waypoint.
act_walk_exit :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) {
  move_stop(ctx.session)
}

act_jump_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  ret, ok := remote_send_actmsg(ctx.session, ctx.session.layout.jump_msg)
  if !ok {
    return .Failed
  }
  if ret == 1 {
    ctx.session.jump_fired_at = ctx.now // radar dot-hop animation
    remote_send_playermoved(ctx.session) // broadcast so others see it
  }
  // A refused jump (airborne / casting / sitting) is not a script error - the client's own guards
  // said no, which is normal mid-combat. Report Done either way.
  return .Done
}

act_jump_to_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  return act_jump_dir_common(ctx, step, "jump_to", false)
}

// The offset twin, same relationship walk_by has to walk_to.
act_jump_by_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  return act_jump_dir_common(ctx, step, "jump_by", true)
}

@(private = "file")
act_jump_dir_common :: proc(ctx: ^Behaviour_Context, step: ^Script_Step, block: string, relative: bool) -> Step_Status {
  if !script_movement_ok(ctx, block) {
    return .Failed
  }
  ppos, pok := read_player_pos(ctx.session)
  if !pok {
    return .Failed
  }
  cx, cz, cok := script_action_coord(ctx, step, 0)
  if !cok {
    return .Failed
  }
  dest := [3]f32{cx, ppos[1], cz}
  if relative {
    dest[0] += ppos[0]
    dest[2] += ppos[2]
  }
  if !write_dest_pos(ctx.session, ppos, dest) {
    return .Failed
  }
  remote_send_snapshot(ctx.session)
  return act_jump_start(ctx, step) // walking + jumping = a directional jump
}

act_target_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  names := parse_target_names(script_arg(ctx, step.action.strs[0]))
  res, _, _, _, _ := tc_select(ctx.session, names[:], false)
  #partial switch res {
  case .AnchorFail, .WriteFail:
    return .Failed
  }
  // NoCandidates / AllOnCooldown are ordinary conditions (nothing nearby right now), not errors -
  // a script gates on mob_in_range if it cares.
  return .Done
}

// --- farm (hands steering to the auto-brain) --------------------------------------------------------

act_farm_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  s := ctx.session
  spec := strings.trim_space(script_arg(ctx, step.action.strs[0]))
  cmd := spec == "" ? "auto" : fmt.tprintf("auto %s", spec)
  // Routed through the REPL rather than reimplemented: cli_auto owns the arming semantics (starts
  // paused, the F10 re-arm spec, the name parsing, the printed summary) and duplicating any of that
  // here is how the two would drift. NOTE: execute_line frees the temp allocator on the way out, so
  // nothing temp-allocated may be read after this call.
  if s.exec_line != nil {
    s.exec_line(&s.eng, cmd)
  }
  s.script.auto_owned = true
  return .Running
}

act_farm_poll :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  // The `until` event is checked by the walker before this. Without one, the block ends when auto
  // turns itself off (its own 'timer' / 'kills' quota, or F10).
  if !ctx.session.auto_on {
    return .Done
  }
  return .Running
}

act_farm_exit :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) {
  if ctx.session.script.auto_owned {
    auto_stop(ctx.session)
    ctx.session.script.auto_owned = false
  }
}

// --- sweep ---------------------------------------------------------------------------------------

act_sweep_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  s := ctx.session
  if s.sweep_on {
    return .Failed // a lane is already armed; two routes would fight
  }
  if s.layout.attack_range <= 0 {
    return .Failed // attack_range IS the brush width
  }
  world, _, ppos, aok := tc_resolve_anchors(s)
  if !aok {
    return .Failed
  }
  cx, cz, cok := script_action_coord(ctx, step, 0)
  if !cok {
    return .Failed
  }
  wip: Sweep_Wip
  defer sweep_wip_free(&wip)
  sweep_wip_begin(&wip, ppos)
  sweep_wip_extend(s, world, &wip, cx, cz, ppos[1])
  if !sweep_arm(s, &wip) {
    return .Failed // too short, or blocked right at the start (sweep_arm printed why)
  }
  // A painted lane is walked by sweep_tick, which only runs inside auto_tick - so sweeping means
  // handing steering to the auto-brain, exactly like `farm`.
  if !s.auto_on {
    if s.exec_line != nil {
      s.exec_line(&s.eng, "auto")
    }
    s.script.auto_owned = true
  }
  return .Running
}

act_sweep_poll :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  if !ctx.session.sweep_on {
    return .Done // sweep_finish cleared it - the lane is swept
  }
  return .Running
}

act_sweep_exit :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) {
  if ctx.session.sweep_on {
    sweep_clear(ctx.session) // also halts an in-flight hop
  }
  if ctx.session.script.auto_owned {
    auto_stop(ctx.session)
    ctx.session.script.auto_owned = false
  }
}

// --- misc actions ------------------------------------------------------------------------------------

// The visual half lives in alert.odin; this is only the argument unpacking. The beep is a flag rather
// than a separate block because "make sure I notice this" is one intent, and splitting it across two
// nodes would mean every alert that matters is two nodes.
act_alert_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  message := script_arg(ctx, step.action.strs[0])
  severity, ok := alert_severity_from_name(step.action.strs[1])
  if !ok && step.action.strs[1] != "" {
    // Not fatal: an alert that argues about its own colour is worse than one that shows up in amber.
    script_trace(ctx.session, script_current_node(ctx), .Warn, "unknown severity '%s' - using warn", step.action.strs[1])
  }
  alert_show(ctx.session, severity, message, i64(step.action.nums[0] * 1e9), step.action.nums[1] != 0)
  return .Done
}

act_alert_clear_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  alert_clear(ctx.session)
  return .Done
}

// Freeze the RUN, not "the auto-farm". Those were two different things while auto had a mode of its
// own; now that auto is a chart, the only thing there is to pause is the chart, and the transport's
// play button is what resumes it. That makes `on inv_full -> pause` mean "stop and wait for me".
act_pause_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  run := &ctx.session.script
  if !run.active {
    return .Done
  }
  run.paused = true
  fmt.printf("\n[script] paused - press play (or 'script resume') to carry on\n")
  fmt.print("memscan> ")
  return .Done
}

act_run_cmd_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  s := ctx.session
  if s.exec_line != nil {
    s.exec_line(&s.eng, step.action.strs[0])
  }
  return .Done
}

// --- event implementations (Stage 2) ------------------------------------------------------------------

ev_kills_arm :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) {
  st.base_i64 = i64(ctx.session.auto_count)
}

ev_kills :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return i64(ctx.session.auto_count) - st.base_i64 >= i64(ev.nums[0])
}

ev_kills_of_arm :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) {
  st.base_i64 = i64(script_kills_of(&ctx.session.script, script_arg(ctx, ev.strs[0])))
}

ev_kills_of :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return i64(script_kills_of(&ctx.session.script, script_arg(ctx, ev.strs[0]))) - st.base_i64 >= i64(ev.nums[0])
}

ev_elapsed :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return ctx.now - st.armed_at >= i64(ev.nums[0] * 60 * 1e9)
}

// --- reading a variable -----------------------------------------------------------------------------
//
// Stateless: no `arm`, because there is no baseline to take. Unlike `kills` or `elapsed`, "what does dir
// hold" is a question about right now and means the same thing asked from anywhere in the chart.

// NUMERIC WHEN BOTH SIDES ARE NUMBERS, text otherwise. That split is what makes one block serve both
// jobs honestly: `var_is count 5` still matches a counter that `add` left holding "5" (or "5.0"), while
// `var_is dir D` compares the two words. Text compares ignoring case, because the thing stored is
// normally something you also typed somewhere else and "D" vs "d" is not a distinction anybody means.
//
// An UNSET variable equals nothing at all, not even "" - use `not var_is` for "it is not D yet".
ev_var_is :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  got, ok := engine.session_var_get(&ctx.session.eng, script_var_name_of(ev.strs[0]))
  if !ok {
    return false
  }
  want := script_arg(ctx, ev.strs[1])
  got, want = strings.trim_space(got), strings.trim_space(want)
  if a, aok := strconv.parse_f64(got); aok {
    if b, bok := strconv.parse_f64(want); bok {
      return a == b
    }
  }
  return strings.equal_fold(got, want)
}

ev_var_above :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return script_var_number(ctx, ev.strs[0]) > ev.nums[0]
}

ev_var_below :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return script_var_number(ctx, ev.strs[0]) < ev.nums[0]
}

// Reads the sense Board rather than re-walking the inventory: the sense layer already paid for it
// this tick, on its own throttle (see SENSES in behaviour.odin).
ev_inv_full :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return engine.board_has(ctx.board, Behaviour_Event.Inv_Full)
}

ev_focus_lost :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return engine.board_has(ctx.board, Behaviour_Event.Focus_Lost)
}

ev_stuck :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return engine.board_has(ctx.board, Behaviour_Event.Stuck)
}

// Read directly rather than off the sense board: a ladder chart asks this between two steps of the
// SAME tick (lock_target then the fight loop), and the board is only refreshed once per tick, so a
// board read would answer with the state from before the lock.
ev_focus_live :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  focus, ok := read_focus_ptr(ctx.session)
  return ok && focus != 0 && focus_obj_live(ctx.session, focus)
}

ev_picked :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return ctx.session.script.pick.set
}

// Did the mob we picked actually DIE, as opposed to being deselected? Asked after hold_target reports
// the target gone, and it is what stops a stray Esc from being counted as a kill. Same test auto used:
// the object is freed / no longer selectable, or its HP has reached zero.
ev_target_died :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  s := ctx.session
  run := &s.script
  if !run.pick.set {
    return false
  }
  if !focus_obj_live(s, run.pick.obj) {
    return true
  }
  if hp, ok := read_mob_hp(s, run.pick.obj); ok && hp <= 0 {
    return true
  }
  return false
}

ev_target_within :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  s := ctx.session
  focus, fok := read_focus_ptr(s)
  if !fok || focus == 0 || !focus_obj_live(s, focus) {
    return false
  }
  ppos, pok := read_player_pos(s)
  tpos, tok := engine.read_vec3(s.proc_info.handle, focus + uintptr(s.layout.pos_off))
  if !pok || !tok {
    return false
  }
  r := f32(ev.nums[0])
  if r <= 0 {
    _, r = pick_ranges(s)
  }
  return engine.dist_horizontal(ppos, tpos) <= r
}

// Rolled fresh on every ask, deliberately NOT in `arm`. The chart shapes that use it - a .Branch
// choosing whether to take the scenic route this pass - visit it once per pass, so a per-ask roll is
// what "40% of the time" means. (.Branch arms once and then only calls `fired`, which is exactly the
// behaviour this needs.)
ev_chance :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  pct := ev.nums[0]
  if pct <= 0 {
    return false
  }
  if pct >= 100 {
    return true
  }
  return f64(lookalive_rand_f32(0, 100)) < pct
}

ev_penya_at :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return ctx.session.penya_last >= i64(ev.nums[0])
}

ev_hp_below :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  s := ctx.session
  player := read_ptr_at(s.proc_info.handle, s.proc_info.base + s.layout.player_rva, engine.Value_Type.U32)
  if player == 0 {
    return false
  }
  hp, ok := read_mob_hp(s, player)
  if !ok {
    return false
  }
  // maxHP is the field right after currentHP (see the hp_off note in flyff.odin).
  maxv, mok := engine.read_value(s.proc_info.handle, player + uintptr(s.layout.hp_off + 4), .I32)
  if !mok {
    return false
  }
  maxhp := i64(i32(engine.value_as_u64(.I32, maxv)))
  if maxhp <= 0 {
    return false
  }
  return f64(hp) * 100.0 / f64(maxhp) < ev.nums[0]
}

// --- mover-gathering events ------------------------------------------------------------------------
// All four share one bounded, camera-independent gather (radar_gather_movers - the same one the radar
// runs at 30fps), throttled here and pointed at the behaviour machine's own arena so the watcher tick
// never accumulates temp allocations. See behaviour_scratch.

EV_MOVER_POLL_NS :: i64(500_000_000)
EV_MOVER_RADIUS_MAX :: f32(200)

// Uses context.temp_allocator, which behaviour_tick has already pointed at the machine's own arena
// for the whole tick (see behaviour_scratch) - so the per-tile scratch inside radar_gather_movers is
// reclaimed with everything else at the top of the next tick, instead of accumulating forever on a
// thread that has no free_all boundary.
script_gather_movers :: proc(ctx: ^Behaviour_Context, radius: f32, filter: []string) -> []Radar_Blip {
  s := ctx.session
  world, player, ppos, ok := tc_resolve_anchors(s)
  if !ok {
    return nil
  }
  propbase, player_ai := radar_prop_ctx(s, player)
  blips := make([dynamic]Radar_Blip, context.temp_allocator)
  cache := make(map[uintptr]Radar_Name_Entry, 16, context.temp_allocator)
  r := clamp(radius, 1, EV_MOVER_RADIUS_MAX)
  radar_gather_movers(s, world, player, propbase, player_ai, ppos[0], ppos[2], r, &blips, filter, &cache, ctx.now)
  return blips[:]
}

// Throttle gate: these cost a real enumeration, so they answer from the last result between polls.
script_mover_due :: proc(ctx: ^Behaviour_Context, st: ^Event_State) -> bool {
  if ctx.now < st.next_poll {
    return false
  }
  st.next_poll = ctx.now + EV_MOVER_POLL_NS
  return true
}

ev_mob_in_range :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  if !script_mover_due(ctx, st) {
    return st.base_i64 != 0 // hold the last verdict until the next poll is due
  }
  radius := f32(ev.nums[0])
  if radius <= 0 {
    radius = ctx.session.layout.attack_range
  }
  names := parse_target_names(script_arg(ctx, ev.strs[0]))
  hit := false
  for b in script_gather_movers(ctx, radius, names[:]) {
    if b.kind == .Monster || b.kind == .Unclassified {
      hit = true
      break
    }
  }
  st.base_i64 = hit ? 1 : 0
  return hit
}

ev_no_mob_in_range :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  if !script_mover_due(ctx, st) {
    return st.base_i64 != 0
  }
  clear_ := true
  for b in script_gather_movers(ctx, f32(ev.nums[0]), nil) {
    if b.kind == .Monster || b.kind == .Unclassified {
      clear_ = false
      break
    }
  }
  st.base_i64 = clear_ ? 1 : 0
  return clear_
}

ev_player_near :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  if !script_mover_due(ctx, st) {
    return st.base_i64 != 0
  }
  hit := false
  for b in script_gather_movers(ctx, f32(ev.nums[0]), nil) {
    if b.kind == .Player {
      hit = true
      break
    }
  }
  st.base_i64 = hit ? 1 : 0
  return hit
}

ev_player_named_near :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  if !script_mover_due(ctx, st) {
    return st.base_i64 != 0
  }
  want := script_arg(ctx, ev.strs[0])
  hit := false
  for b in script_gather_movers(ctx, f32(ev.nums[0]), nil) {
    if b.kind != .Player {
      continue
    }
    if nm, ok := read_mover_name(ctx.session, b.obj); ok && nm == want {
      hit = true
      break
    }
  }
  st.base_i64 = hit ? 1 : 0
  return hit
}

ev_aggro :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  if !script_mover_due(ctx, st) {
    return st.base_i64 != 0
  }
  my_id, idok := read_player_objid(ctx.session)
  if !idok || my_id == 0 {
    return false
  }
  radius := f32(ev.nums[0])
  if radius <= 0 {
    radius = EV_MOVER_RADIUS_MAX
  }
  hit := false
  for b in script_gather_movers(ctx, radius, nil) {
    if b.kind != .Monster && b.kind != .Unclassified {
      continue
    }
    if mob_targets_player(ctx.session, b.obj, my_id) {
      hit = true
      break
    }
  }
  st.base_i64 = hit ? 1 : 0
  return hit
}

// --- press_key ------------------------------------------------------------------------------------

avail_press_key :: proc(session: ^Session) -> (bool, string) {
  if !session.attached {
    return false, "needs a Neuz attached"
  }
  if _, ok := game_window(session); !ok {
    return false, "can't find the game's main window to post keys to (is it minimised to tray?)"
  }
  return true, ""
}

// Complain once, in the one shape all three key blocks want. Split out because a bad key name is a
// FILE-level mistake (it parsed, the chart drew, and it only turns out to be nonsense at run time),
// so the message has to name the block that carries it rather than just say "bad key".
// Complain once, in the one shape all three key blocks want. Split out because a bad key name is a
// FILE-level mistake (it parsed, the chart drew, and it only turns out to be nonsense at run time),
// so the message has to name the block that carries it rather than just say "bad key".
//
// It traces as well as printing, and that pairing is the entire reason a chart like Circle_jump looked
// like it never started: this message WAS being produced, to a console nobody editing a graph is looking
// at. Both spellings are shown when the argument was a variable, because "'D' isn't a key name" and
// "'@dir' isn't a key name" send you to very different places.
@(private = "file")
key_name_failed :: proc(ctx: ^Behaviour_Context, block: string, raw: string, expanded: string) -> Step_Status {
  shown := expanded == raw ? raw : fmt.tprintf("%s -> '%s'", raw, expanded)
  fmt.printf("\n[script] %s: '%s' isn't a key name (try 1-9, a-z, f1-f12, space, enter).\n", block, shown)
  fmt.print("memscan> ")
  script_trace(ctx.session, script_current_node(ctx), .Error, "%s: '%s' isn't a key name", block, shown)
  return .Failed
}

act_press_key_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  name := script_arg(ctx, step.action.strs[0])
  vk, ok := vk_from_name(name)
  if !ok {
    return key_name_failed(ctx, "press_key", step.action.strs[0], name)
  }
  // Through key_hold rather than key_post: exit below is what normally releases it, and registering
  // the hold means the run-level release-all still catches it if exit somehow never runs.
  if !key_hold(ctx.session, vk) {
    return .Failed
  }
  step.scratch.started_at = ctx.now
  step.scratch.vk = vk // exit releases THIS key, not whatever the argument resolves to later
  step.scratch.flag = true // the key is DOWN - exit must release it (see keys.odin)
  return .Running
}

act_press_key_poll :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  if ctx.now - step.scratch.started_at < KEY_HOLD_NS {
    return .Running
  }
  return .Done // exit releases it - one place, so completion and abort behave identically
}

// Release on EVERY exit path: completion, `script stop`, an interrupt, a detach. A key left down
// would keep firing whatever it is bound to with nothing left running to stop it.
act_press_key_exit :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) {
  if !step.scratch.flag {
    return
  }
  key_release(ctx.session, step.scratch.vk)
  step.scratch.flag = false
}

// --- key_down / key_up ------------------------------------------------------------------------------
//
// The held pair, and the one place in the block catalog where an action deliberately leaves something
// switched on behind it. press_key cannot express "walk forward for as long as this loop runs" or
// "hold the attack key while the target lives": its down/up are 45ms apart and both inside one step.
// So key_down puts the key down and RETURNS, and every later step runs with it still down.
//
// That is why neither block has an `exit`. An exit here would release the key the instant the step
// finished, which is exactly the behaviour these exist to avoid. The release contract moves up to the
// run instead - script_teardown and script_reset call keys_release_all, and so does on_detach - so a
// chart that is stopped mid-hold, or that simply forgets its key_up, still lets go. See keys.odin.

act_key_down_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  name := script_arg(ctx, step.action.strs[0])
  vk, ok := vk_from_name(name)
  if !ok {
    return key_name_failed(ctx, "key_down", step.action.strs[0], name)
  }
  if !key_hold(ctx.session, vk) {
    return .Failed
  }
  script_trace(ctx.session, step.id, .Step, "holding '%s' down", name)
  return .Done
}

// Reports Done even when the post fails. This is the block an author reaches for to GUARANTEE a key is
// let go, often on an escape path, and a failed post means the window is already gone - failing the
// step there would abort the run (or take a fail edge) over a key that is provably no longer held.
act_key_up_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  name := script_arg(ctx, step.action.strs[0])
  vk, ok := vk_from_name(name)
  if !ok {
    return key_name_failed(ctx, "key_up", step.action.strs[0], name)
  }
  key_release(ctx.session, vk)
  script_trace(ctx.session, step.id, .Step, "let go of '%s'", name)
  return .Done
}

// --- target / position events -----------------------------------------------------------------------

// The SELECTED mob's HP as a percentage. Same shape as ev_hp_below but anchored on m_pObjFocus, so a
// boss fight can end on "it died" rather than a fixed timer. Reports false with nothing selected,
// which is what makes `while not target_hp_below 1` terminate when the mob despawns.
// Is a straight walk to the SELECTED monster clear? The same oracle the reach gate uses to filter
// candidates (terrain attribute grid + collider boxes), asked about the thing you already have selected
// rather than about a list you are choosing from - which is what makes it usable as a branch: "walk to
// it if you can, otherwise skip it" is a decision a chart wants to make out loud.
//
// Polled, not latched, and that is on purpose: what is in the way changes as you and it move, so the
// answer is about NOW. Reads a few pages of game memory, so keep it off a hot loop's every tick if the
// chart can gate it behind something cheaper.
ev_target_reachable :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  s := ctx.session
  focus, ok := read_focus_ptr(s)
  if !ok || focus == 0 || !focus_obj_live(s, focus) {
    return false // nothing selected is not "reachable" - `not target_reachable` would then be true,
    // which reads as "something is in the way" and would be a lie. Gate on focus_live first.
  }
  world, _, ppos, aok := tc_resolve_anchors(s)
  if !aok {
    return false
  }
  tpos, tok := engine.read_vec3(s.proc_info.handle, focus + uintptr(s.layout.pos_off))
  if !tok {
    return false
  }
  return cand_reachable(s, world, ppos, tpos)
}

ev_target_hp_below :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  s := ctx.session
  focus, ok := read_focus_ptr(s)
  if !ok || focus == 0 || !focus_obj_live(s, focus) {
    return false
  }
  hp, hok := read_mob_hp(s, focus)
  if !hok {
    return false
  }
  maxv, mok := engine.read_value(s.proc_info.handle, focus + uintptr(s.layout.hp_off + 4), .I32)
  if !mok {
    return false
  }
  maxhp := i64(i32(engine.value_as_u64(.I32, maxv)))
  if maxhp <= 0 {
    return false
  }
  return f64(hp) * 100.0 / f64(maxhp) < ev.nums[0]
}

avail_pet :: proc(session: ^Session) -> (bool, string) {
  if ok, why := avail_attached(session); !ok {
    return false, why
  }
  if session.layout.petid_off == 0 {
    return false, "needs petid_off - summon/unsummon your pet and diff the player object, then 'set petid_off 0x..'"
  }
  return true, ""
}

// Is the loot-collecting pet out? This is the client's own HasActivatedSystemPet() test, which is
// literally `m_dwPetId != NULL_ID`: the field holds the INVENTORY SLOT of the summoned pet item, and
// NULL_ID (0xFFFFFFFF) when nothing is out.
//
// Worth knowing if this ever needs re-deriving: there is no pointer link to follow. The player object
// holds no pointer to the pet, and the pet holds none back - verified by scanning all writable memory
// for both addresses while a pet was out. The association is by slot/OBJID only, so this field (or the
// pet's OBJID at a neighbouring offset) is the only honest signal.
ev_pet_active :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  s := ctx.session
  player := read_ptr_at(s.proc_info.handle, s.proc_info.base + s.layout.player_rva, engine.Value_Type.U32)
  if player == 0 {
    return false
  }
  v, ok := engine.read_value(s.proc_info.handle, player + uintptr(s.layout.petid_off), .U32)
  if !ok {
    return false
  }
  return u32(engine.value_as_u64(.U32, v)) != NULL_ID
}

// Are we standing within <radius> of a world point? The teleport / zone-change confirmation: after a
// hotkey teleport, this is how a script tells "it worked" from "it was on cooldown / I'm still here".
ev_at_position :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  ppos, ok := read_player_pos(ctx.session)
  if !ok {
    return false
  }
  cx, cz, cok := script_event_coord(ctx, ev, 0)
  if !cok {
    return false // a spot we cannot resolve is not a spot we are standing on
  }
  target := [3]f32{cx, ppos[1], cz}
  return engine.dist_horizontal(ppos, target) <= f32(ev.nums[2])
}

// --- NOT-YET blocks: the stubs ---------------------------------------------------------------------
// The reason each one is unavailable is a `not_built_why` string on its catalog row, not a proc: it is
// a fact about the tool, not about this session, and there is no question to ask the Session. The stubs
// below are unreachable in practice (a run is refused before it starts) and exist as defence in depth.

act_not_implemented :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  return .Failed // unreachable: script_check_avail refuses the run before it starts
}

ev_not_implemented :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return false
}

// --- shared helpers used by the tables ---------------------------------------------------------

// Seconds -> nanoseconds, guarding against a negative literal.
script_secs_ns :: proc(secs: f64) -> i64 {
  if secs <= 0 {
    return 0
  }
  return i64(secs * 1e9)
}
