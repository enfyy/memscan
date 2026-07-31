package flyff

import "core:fmt"
import "core:strings"

// ===========================================================================
// Prose - how a block is spelled for a HUMAN.
//
// WHY THIS IS NOT script_render_step. That renderer is the serializer: it produces the .bhv file, the
// `script show` listing and Script_Step.src, and everything it emits has to round-trip back through
// the parser. It therefore speaks the catalog's own spelling - `pick_density 0 0`, `skip_target ''`,
// `branch always ? #0 : #0` - which is exactly right for a file and unreadable on a node.
//
// So this is a SECOND, one-way rendering. Nothing here is ever parsed back, which is what buys the
// freedom to drop arguments, rename things and phrase conditions as questions. The rule that keeps
// the two from drifting is that neither is derived from the other: both read the block catalog.
//
// It is also GUI-free on purpose (no imgui import). Colour and iconography for a Block_Cat live in
// gui_nodes.odin, so the core keeps knowing nothing about how it is drawn.
//
// ALLOCATION. Everything returns either a literal or a temp-allocated string, valid until the end of
// the frame. Only the draw phase calls this, and the radar frees temp per frame - do NOT call it from
// the watcher tick, which has no temp boundary at all (see the note atop behaviour_tick).
// ===========================================================================

// What a block is ABOUT. Drives node colour and the palette's grouping - one glance should say
// "this part of the chart picks a target, that part fights".
Block_Cat :: enum {
  Flow, // stop, fail, and the control-flow ops themselves
  Sense, // looking at the world without acting on it
  Target, // choosing and holding WHICH monster
  Move, // going somewhere
  Combat, // fighting the thing you chose, and counting it
  Timing, // waiting, and the dice
  Vars, // the script's own scratch values
  System, // memscan and the client: alerts, keys, commands, chat
}

BLOCK_CAT_NAMES := [Block_Cat]string {
  .Flow   = "flow",
  .Sense  = "sense",
  .Target = "targeting",
  .Move   = "movement",
  .Combat = "combat",
  .Timing = "timing",
  .Vars   = "variables",
  .System = "system",
}

// ===========================================================================
// Small string helpers
// ===========================================================================

// `min_gain` -> `min gain`. Parameter names are catalog identifiers; underscores are a spelling
// detail of the command line, not something a label should inherit.
prose_words :: proc(s: string, allocator := context.temp_allocator) -> string {
  if strings.index_byte(s, '_') < 0 {
    return s
  }
  out, _ := strings.replace_all(s, "_", " ", allocator)
  return out
}

// The fallback title for a block whose catalog row has none: `pick_density` -> `Pick density`. It
// exists so that adding a block can never produce an unreadable node - only an unpolished one.
prose_title_of_name :: proc(name: string, allocator := context.temp_allocator) -> string {
  w := prose_words(name, allocator)
  if len(w) == 0 || w[0] < 'a' || w[0] > 'z' {
    return w
  }
  b := strings.builder_make(allocator)
  strings.write_byte(&b, w[0] - 32)
  strings.write_string(&b, w[1:])
  return strings.to_string(b)
}

prose_num :: proc(b: ^strings.Builder, v: f64) {
  script_write_num(b, v, display = true) // two decimals - this only ever ends up on the canvas
}

// The label for one argument. Same fallback rule as a block's title: the catalog is supposed to carry
// a real one (script_selftest_meta refuses to pass otherwise), and prettifying the identifier is only
// here so a half-finished block draws as "Min gain" rather than as nothing at all.
param_title :: proc(p: Param_Spec, allocator := context.temp_allocator) -> string {
  if p.title != "" {
    return p.title
  }
  return prose_title_of_name(p.name, allocator)
}

// ===========================================================================
// Titles
// ===========================================================================

action_title :: proc(kind: Script_Action_Kind, allocator := context.temp_allocator) -> string {
  def := action_def(kind)
  if def == nil {
    return "(unknown block)"
  }
  if def.title != "" {
    return def.title
  }
  return prose_title_of_name(def.name, allocator)
}

// Event titles are STATEMENTS ("Target died"), so the same string serves a branch's question and a
// while-loop's condition. `not` is spelled out rather than folded into the wording, because there is
// no reliable way to negate an arbitrary English phrase and a wrong one would misdescribe the program.
event_title :: proc(ev: Script_Event, allocator := context.temp_allocator) -> string {
  def := event_def(ev.kind)
  base := "(unknown condition)"
  if def != nil {
    base = def.title != "" ? def.title : prose_title_of_name(def.name, allocator)
  }
  if ev.negate {
    return fmt.aprintf("Not: %s", base, allocator = allocator)
  }
  return base
}

// A whole condition as one phrase: "HP below 30% and Something wants me". The joiner is lower-case
// against the Sentence-cased rows on purpose - it is the only word in the line that is not a block
// name, and looking different is how you see the shape of the test at a glance.
condition_title :: proc(condition: Script_Condition, allocator := context.temp_allocator) -> string {
  n := condition_row_count(condition)
  if n == 1 {
    return event_title(condition.first_row, allocator)
  }
  b := strings.builder_make(allocator)
  for i in 0 ..< n {
    if i > 0 {
      strings.write_string(&b, condition.match_any ? " or " : " and ")
    }
    strings.write_string(&b, event_title(condition_row(condition, i), allocator))
  }
  return strings.to_string(b)
}

event_cat :: proc(ev: Script_Event) -> Block_Cat {
  if def := event_def(ev.kind); def != nil {
    return def.cat
  }
  return .Flow
}

// The headline on a node. The OP decides the SHAPE of the sentence; the block decides its subject.
block_title :: proc(s: Script_Step, allocator := context.temp_allocator) -> string {
  switch s.op {
  case .Action:
    return action_title(s.action.kind, allocator)
  case .Branch, .If:
    return fmt.aprintf("%s?", condition_title(s.condition, allocator), allocator = allocator)
  case .While:
    return fmt.aprintf("While %s", condition_title(s.condition, allocator), allocator = allocator)
  case .Wait_For:
    return fmt.aprintf("Wait until %s", condition_title(s.condition, allocator), allocator = allocator)
  case .On:
    return fmt.aprintf("Whenever %s", condition_title(s.condition, allocator), allocator = allocator)
  case .Else:
    return "Otherwise"
  case .End:
    return "End of block"
  case .Repeat, .Loop:
    return "Repeat"
  case .Goto:
    return "Jump"
  case .Return:
    return "Hand control back"
  }
  return "?"
}

block_cat :: proc(s: Script_Step) -> Block_Cat {
  switch s.op {
  case .Action:
    if def := action_def(s.action.kind); def != nil {
      return def.cat
    }
    return .Flow
  case .Branch, .If, .While, .Wait_For:
    return event_cat(s.condition.first_row)
  case .On:
    // An interrupt is control flow whatever it watches for: what matters at a glance is that this
    // node is not in the program's path at all.
    return .Flow
  case .Else, .End, .Repeat, .Loop, .Goto, .Return:
    return .Flow
  }
  return .Flow
}

// ===========================================================================
// Parameters
// ===========================================================================

// The unit a number is measured in. .Duration and .Percent carry their own; anything else says so on
// the Param_Spec, or reads as a bare count.
prose_unit :: proc(p: Param_Spec) -> string {
  if p.unit != "" {
    return p.unit == "bool" ? "" : p.unit
  }
  #partial switch p.kind {
  case .Duration:
    return "s"
  case .Percent:
    return "%"
  }
  return ""
}

// One argument, formatted for reading. Coord eats two numeric slots, which is why the caller hands in
// the whole payload and the slot rather than a single value.
param_value_text :: proc(spec: []Param_Spec, i: int, nums: [4]f64, strs: [2]string, allocator := context.temp_allocator) -> string {
  p := spec[i]
  slot, coord_str := param_slots(spec, i)
  if param_kind_is_str(p.kind) {
    slot = coord_str
  }
  b := strings.builder_make(allocator)
  switch p.kind {
  case .Num, .Duration, .Percent:
    if p.unit == "bool" {
      return nums[slot] != 0 ? "on" : "off"
    }
    prose_num(&b, nums[slot])
    strings.write_string(&b, prose_unit(p))
  case .Coord:
    // Show the expression rather than the numbers under it: `@spot` is what the author wrote, and
    // "0, 0" is what the unused literal half happens to hold.
    if strs[coord_str] != "" {
      return strs[coord_str]
    }
    prose_num(&b, nums[slot])
    strings.write_string(&b, ", ")
    prose_num(&b, nums[slot + 1])
  case .Str, .Names, .Mob, .Key, .Var_Name, .Choice:
    if strs[slot] == "" {
      return "any"
    }
    return strs[slot]
  }
  return strings.to_string(b)
}

// Is this argument still exactly what omitting it would give you? Those are the ones the compact node
// body drops - `pick_density 0 0` means "use the configured gates", and printing two zeros to say so
// is what made the old labels read like a memory dump. The hover card still shows them.
param_is_default :: proc(spec: []Param_Spec, i: int, nums: [4]f64, strs: [2]string) -> bool {
  p := spec[i]
  if !p.optional {
    return false
  }
  num_slot, str_slot := param_slots(spec, i)
  switch p.kind {
  case .Num, .Duration, .Percent:
    return nums[num_slot] == p.def
  case .Coord:
    return nums[num_slot] == 0 && nums[num_slot + 1] == 0 && strs[str_slot] == ""
  case .Str, .Names, .Mob, .Key, .Var_Name, .Choice:
    return strs[str_slot] == ""
  }
  return false
}

// The detail line under a node's title: every argument that was deliberately SET, named and united.
// Empty when the block is fully at its defaults, which is the common and correct case for a ladder
// rung - there the title alone is the whole truth.
prose_params :: proc(spec: []Param_Spec, nums: [4]f64, strs: [2]string, allocator := context.temp_allocator) -> string {
  b := strings.builder_make(allocator)
  n := 0
  for _, i in spec {
    if param_is_default(spec, i, nums, strs) {
      continue
    }
    if n > 0 {
      strings.write_string(&b, "   ")
    }
    strings.write_string(&b, prose_words(spec[i].name, allocator))
    strings.write_byte(&b, ' ')
    strings.write_string(&b, param_value_text(spec, i, nums, strs, allocator))
    n += 1
  }
  return strings.to_string(b)
}

// The tuned arguments of every ROW of a condition, run together. The title already names which blocks
// are involved and how they are joined; this is the numbers under it, and a row that was left at its
// defaults contributes nothing, exactly as for a single event.
condition_params_line :: proc(condition: Script_Condition, allocator := context.temp_allocator) -> string {
  b := strings.builder_make(allocator)
  n := 0
  for i in 0 ..< condition_row_count(condition) {
    ev := condition_row(condition, i)
    def := event_def(ev.kind)
    if def == nil {
      continue
    }
    part := prose_params(def.params, ev.nums, ev.strs, allocator)
    if part == "" {
      continue
    }
    if n > 0 {
      strings.write_string(&b, "   ")
    }
    strings.write_string(&b, part)
    n += 1
  }
  return strings.to_string(b)
}

// What a step's payload says, for the node body. Structured ops carry no block of their own, so they
// describe their own shape instead.
step_params_line :: proc(s: Script_Step, allocator := context.temp_allocator) -> string {
  line := ""
  switch s.op {
  case .Action, .On:
    if def := action_def(s.action.kind); def != nil {
      line = prose_params(def.params, s.action.nums, s.action.strs, allocator)
    }
    // A watcher's title is its trigger, so its body line has to be the thing it DOES. When it names a
    // subgraph rather than carrying one action, the honest answer is that the wire says where.
    if s.op == .On {
      if s.goto_id != 0 {
        return "takes over and runs its own steps"
      }
      what := action_title(s.action.kind, allocator)
      line = line == "" ? what : fmt.aprintf("%s   %s", what, line, allocator = allocator)
    }
  case .Branch, .If, .While, .Wait_For:
    line = condition_params_line(s.condition, allocator)
  case .Repeat, .Loop:
    return fmt.aprintf("%d times", s.count, allocator = allocator)
  case .End:
    return s.close == .If ? "end of the if" : "back to the top"
  case .Else, .Goto, .Return:
    return ""
  }
  if s.has_until {
    u := fmt.aprintf("until %s", condition_title(s.until, allocator), allocator = allocator)
    line = line == "" ? u : fmt.aprintf("%s   %s", line, u, allocator = allocator)
  }
  return line
}

// The first clause of a blurb, for a node body. The catalog's blurbs are written as "rung 1: a monster
// already coming for you (any distance). Fails if none" - the lead is the useful half and the rest is
// detail for the hover card, so this cuts at the first sentence break and drops the "rung N:" prefix
// (the chart's own order already says which rung it is).
prose_lead_sentence :: proc(text: string, allocator := context.temp_allocator) -> string {
  s := text
  if c := strings.index_byte(s, ':'); c > 0 && c < 12 {
    s = strings.trim_left_space(s[c + 1:])
  }
  for cut in ([]string{". ", " - ", " (", ";"}) {
    if i := strings.index(s, cut); i > 0 {
      s = s[:i]
    }
  }
  return strings.trim_right(s, ".")
}

// The line under a node's title. Prefers the arguments this block was actually TUNED with; when there
// are none - which is most of a farm chart, since every ladder rung runs on configured values - it
// falls back to WHAT THE BLOCK DOES rather than leaving the box empty.
//
// `hint` says which one you got, so the canvas can draw the fallback dimmer: a value someone chose and
// a description of the block are different kinds of fact and should not look alike.
step_body_line :: proc(s: Script_Step, allocator := context.temp_allocator) -> (text: string, is_description: bool) {
  if line := step_params_line(s, allocator); line != "" {
    return line, false
  }
  #partial switch s.op {
  case .Goto, .Return, .Else, .End:
    return "", false // these say everything they have to say in their title and their wire
  }
  return prose_lead_sentence(block_blurb(s), allocator), true
}

// The one-paragraph explanation, for the hover card. Straight off the catalog row, so it can never
// drift from what the block does.
block_blurb :: proc(s: Script_Step) -> string {
  #partial switch s.op {
  case .Action, .On:
    if def := action_def(s.action.kind); def != nil {
      return def.blurb
    }
  case .Branch, .If, .While, .Wait_For:
    if def := event_def(s.condition.kind); def != nil {
      return def.blurb
    }
  case .Goto:
    return "jump to another node - how a loop is drawn"
  case .Return:
    return "end an interrupt and hand control back to where the program was suspended"
  case .Repeat:
    return "run the nodes below a fixed number of times"
  case .Loop:
    return "take the 'each pass' edge a fixed number of times, then leave by 'when done'"
  case .End:
    return "closes the block above it"
  case .Else:
    return "the other arm of the if above it"
  }
  return ""
}

// The catalog spelling, for the surfaces that also have to tell you what to TYPE (the palette, the
// inspector's kind picker). Kept next to the prose so the pairing is obvious.
block_name :: proc(s: Script_Step) -> string {
  #partial switch s.op {
  case .Action, .On:
    if def := action_def(s.action.kind); def != nil {
      return def.name
    }
  case .Branch, .If, .While, .Wait_For:
    if def := event_def(s.condition.kind); def != nil {
      return def.name
    }
  }
  return BHV_OP_NAMES[s.op]
}
