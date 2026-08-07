package flyff

import "core:fmt"
import "core:slice"
import "core:strings"

// ===========================================================================
// Chart lint - everything that is wrong with a behaviour BEFORE you run it.
//
// WHY THIS EXISTS. The editor could draw a chart that saved fine, loaded fine, and then stopped on its
// second node with the reason on a console nobody was looking at. Every mistake below is one the canvas
// renders as a perfectly finished-looking node:
//
//   `var @dir D`             creates a variable literally called "@dir", which no @name can reference
//   `key_down @dir`          with nothing in the chart setting `dir`
//   `key_down Q7`            a key name that is not a key name
//   a pick_* with no fail wire on a chart that is nothing but a fall-through ladder
//   a branch with one arm unwired, on a loop chart that therefore stops rather than looping
//
// ONE ANALYZER, THREE CONSUMERS. The editor's Problems tab, the save button, and `script lint <name>`
// all read this - the same reason the block catalog is one table. A check that only the CLI ran would be
// a check the person authoring in the editor never sees, which is the exact failure being fixed.
//
// NO SESSION, ON PURPOSE. This runs on the GUI thread, which may not touch Session unlocked, so every
// check here is answerable from the DOCUMENT alone. That is why the unset-variable check says "nothing in
// this chart sets it" rather than "it is not set": whether the REPL happens to have one right now is a
// different question, and a linter that changed its mind based on live state would be untrustworthy.
// Availability (`script_check_avail`, which does need a session) stays where it is - on the run gate.
// ===========================================================================

Chart_Problem_Level :: enum {
  Error,   // it will not do what the chart says: a dead edge, an argument that cannot work
  Warning, // it will probably not do what you meant
  Note,    // worth knowing, and legitimate
}

CHART_PROBLEM_LEVEL_NAMES := [Chart_Problem_Level]string {
  .Error   = "ERROR",
  .Warning = "warning",
  .Note    = "note",
}

Chart_Problem :: struct {
  node:  Node_Id, // 0 = about the document as a whole
  level: Chart_Problem_Level,
  text:  string, // what is wrong
  hint:  string, // what to do about it
}

// Everything wrong with <doc>, worst first. Strings are allocated from <allocator> (temp by default), so
// a caller that keeps the list past the frame has to say so.
//
// Sorted by LEVEL only, keeping document order within a level: the order nodes were authored in is the
// order the author will look for them, and a secondary sort on node id would scatter one section's
// problems through the list.
script_lint :: proc(doc: ^Behaviour_Doc, allocator := context.temp_allocator) -> []Chart_Problem {
  context.allocator = allocator
  out := make([dynamic]Chart_Problem, allocator)

  ids := make(map[Node_Id]int, len(doc.steps), context.temp_allocator)
  defer delete(ids)
  for s, i in doc.steps {
    ids[s.id] = i
  }
  set_names := lint_variables_set(doc)
  defer delete(set_names)
  reachable := lint_reachable(doc, ids)
  defer delete(reachable)

  for level in Chart_Problem_Level {
    if level == .Error {
      lint_document(doc, &out)
    }
    for s, i in doc.steps {
      lint_step(doc, s, i, ids, set_names, reachable, level, &out)
    }
  }
  return out[:]
}

// How many of <problems> are at <level>. The toolbar badge and the tab headers want a count, and
// counting at the call site three times is how the three would disagree.
script_lint_count :: proc(problems: []Chart_Problem, level: Chart_Problem_Level) -> int {
  n := 0
  for p in problems {
    if p.level == level {
      n += 1
    }
  }
  return n
}

// --- the document as a whole ---------------------------------------------------------------------

@(private = "file")
lint_document :: proc(doc: ^Behaviour_Doc, out: ^[dynamic]Chart_Problem) {
  if len(doc.steps) == 0 {
    append(out, Chart_Problem{level = .Error, text = "the chart is empty", hint = "add a node from the palette"})
    return
  }
  // An entry naming a node that is not there is the one document-level dangling edge, and it is worse
  // than an edge one: the run refuses to start at all rather than misbehaving somewhere.
  if doc.entry != 0 {
    found := false
    for s in doc.steps {
      if s.id == doc.entry {
        found = true
        break
      }
    }
    if !found {
      append(out, Chart_Problem{
        level = .Error,
        text  = fmt.aprintf("the start node is #%d, which is not in this chart", u32(doc.entry)),
        hint  = "right-click the node you want to start at and choose Start here",
      })
    }
  }
  // Not a fault - it is a deliberate declaration - but it changes what every targeting node in the
  // chart does, and nothing on the canvas shows it. A note is how this pane says "know this about the
  // document you are reading".
  if doc.ignore_collision {
    append(out, Chart_Problem{
      level = .Note,
      text  = "this chart ignores collision - monsters are picked and approached without checking the path is clear",
      hint  = "written for a map whose floor props do not really block; untick it in Chart options for anywhere else",
    })
  }
  if doc.is_subchart {
    lint_subchart_document(doc, out)
  }
}

// What a sub-chart may not be. Every one of these is refused again at run start
// (subchart_callable_why) - this half exists so you find out while you are drawing it rather than the
// first time something tries to call it.
@(private = "file")
lint_subchart_document :: proc(doc: ^Behaviour_Doc, out: ^[dynamic]Chart_Problem) {
  if doc.mode == .Loop {
    append(out, Chart_Problem{
      level = .Error,
      text  = "a block is set to loop, so a chart that called it would never get control back",
      hint  = "set the mode to 'once' in this chart's options",
    })
  }
  for s in doc.steps {
    if s.op == .On {
      append(out, Chart_Problem{
        node  = s.id,
        level = .Error,
        text  = "a block cannot declare a watcher - a watcher belongs to the chart you RUN",
        hint  = "move this 'on' node into the chart that calls this block, or arm it globally",
      })
      break // one is the point; five copies of it is a list nobody reads
    }
  }
  if len(doc.uses) > 0 {
    append(out, Chart_Problem{
      level = .Error,
      text  = fmt.aprintf("a block cannot borrow watchers ('uses %s') - a watcher belongs to the chart you RUN", doc.uses[0]),
      hint  = "borrow it in the chart that calls this block instead",
    })
  }
  // A parameter with no sentence beside it is a knob you have to read the source to set. Exactly the
  // bar script_selftest_meta holds the built-in catalog to, applied to the catalog the user is writing.
  for p in subchart_params(doc) {
    if p.title == "" || p.help == "" {
      append(out, Chart_Problem{
        level = .Warning,
        text  = fmt.aprintf("the '%s' setting has no %s", p.name, p.title == "" ? "label" : "description"),
        hint  = "every block in the palette says what its settings do; give this one a sentence too",
      })
    }
  }
  // Free variables: read by this block, set by nobody. Inside a BLOCK that is nearly always a missing
  // parameter, which is a much more useful thing to say than the generic "nothing sets it" warning -
  // so it replaces it here (lint_references skips a name that is declared).
  set_names := lint_variables_set(doc)
  defer delete(set_names)
  declared := make(map[string]bool, SUBCHART_MAX_PARAMS, context.temp_allocator)
  defer delete(declared)
  for p in subchart_params(doc) {
    declared[p.name] = true
  }
  seen := make(map[string]bool, 8, context.temp_allocator)
  defer delete(seen)
  for s in doc.steps {
    for name in lint_step_references(s) {
      if set_names[name] || declared[name] || seen[name] {
        continue
      }
      seen[name] = true
      append(out, Chart_Problem{
        node  = s.id,
        level = .Warning,
        text  = fmt.aprintf("this block reads @%s but never sets it", name),
        hint  = fmt.aprintf("add '%s' as a setting in this chart's options, so whoever places the block fills it in", name),
      })
    }
  }
}

// --- one step -------------------------------------------------------------------------------------

@(private = "file")
lint_step :: proc(
  doc: ^Behaviour_Doc,
  s: Script_Step,
  index: int,
  ids: map[Node_Id]int,
  set_names: map[string]bool,
  reachable: map[Node_Id]bool,
  level: Chart_Problem_Level,
  out: ^[dynamic]Chart_Problem,
) {
  add :: proc(out: ^[dynamic]Chart_Problem, node: Node_Id, level: Chart_Problem_Level, text, hint: string) {
    append(out, Chart_Problem{node = node, level = level, text = text, hint = hint})
  }

  switch level {
  case .Error:
    // A dangling edge. script_resolve_ids finds the same thing, but it MUTATES the steps to do it and an
    // analyzer that rewrote the document it was asked about would be a trap.
    if s.goto_id != 0 && s.goto_id not_in ids {
      add(out, s.id, .Error,
        fmt.aprintf("goes to node #%d, which is not in this chart", u32(s.goto_id)),
        "re-wire it, or delete the wire by clicking it")
    }
    if s.else_id != 0 && s.else_id not_in ids {
      add(out, s.id, .Error,
        fmt.aprintf("falls back to node #%d, which is not in this chart", u32(s.else_id)),
        "re-wire it, or delete the wire by clicking it")
    }
    lint_arguments(s, set_names, .Error, out, doc.is_subchart)
    // A branch or a graph loop with an unwired arm does not fall through - script_resolve_ids leaves it
    // at -1 ("no edge = end, not index 0"), so taking that arm ENDS THE RUN. On a loop chart that is
    // always a mistake; on a once chart it may well be the intended ending, hence the split.
    #partial switch s.op {
    case .Branch:
      lint_arm(s, s.goto_id, "yes", doc.mode, out)
      lint_arm(s, s.else_id, "no", doc.mode, out)
    case .Loop:
      lint_arm(s, s.goto_id, "each pass", doc.mode, out)
      lint_arm(s, s.else_id, "when done", doc.mode, out)
    case .Call:
      lint_call(doc, s, .Error, out)
    }

  case .Warning:
    lint_arguments(s, set_names, .Warning, out, doc.is_subchart)
    if s.id not_in reachable {
      add(out, s.id, .Warning,
        "nothing leads here - this node can never run",
        "wire something into it, or delete it")
    }
    // A watcher with no body cannot be armed and cannot be borrowed: there is nothing for its trigger
    // to run. There is no longer an exception for the legacy shape (an `on` carrying a single action
    // and naming no body) - files holding it are upgraded on load, and nothing can author a new one.
    if s.op == .On && s.goto_id == 0 {
      add(out, s.id, .Warning,
        "this watcher has no body wired, so it does nothing",
        "drag from its port to the first node of what it should do")
    }
    // `not_built`, not the stub proc's identity: the catalog row is the single source of truth for
    // "there is no code behind this", and it carries the reason as well. Note this is the ONLY
    // availability question the linter asks - "needs an attach / needs findmove" is about this moment,
    // not about the document, and a chart written on a plane is not wrong for saying walk_to.
    if def := action_def(s.action.kind); def != nil && def.not_built {
      add(out, s.id, .Warning,
        fmt.aprintf("'%s' is not built yet - the run will refuse to start", def.name),
        "'script blocks' lists what each gated block still needs")
    }
    for i in 0 ..< condition_row_count(s.condition) {
      if def := event_def(condition_row(s.condition, i).kind); def != nil && def.not_built {
        add(out, s.id, .Warning,
          fmt.aprintf("'%s' is not built yet - the run will refuse to start", def.name),
          "'script blocks' lists what each gated block still needs")
      }
    }
    if s.op == .Call {
      lint_call(doc, s, .Warning, out)
    }

  case .Note:
    // Where the run can END without a Stop node saying so. A NOTE, not a warning, and that was a
    // correction worth recording: as a warning it fired 19 times across the shipped charts, every one of
    // them deliberate - the last rung of the targeting ladder has nowhere to fall back TO, and a
    // press_key that fails means the game window is gone, which nobody wires around. A list that is
    // mostly noise is a list nobody reads, which is the problem this whole file exists to fix.
    if def := action_def(s.action.kind); def != nil && def.can_fail && s.else_id == 0 && s.op == .Action {
      add(out, s.id, .Note,
        fmt.aprintf("'%s' can fail, and nothing is wired to its fail port - the run would end here", def.name),
        "wire the second (red) port if a failure should go somewhere instead")
    }
    // Not an error: the run releases every held key on the way out (script_teardown), and holding W for
    // a whole chart is exactly what key_down is for. Worth saying because the pairing is easy to intend
    // and forget, and an unpaired hold behaves differently from every other block on the canvas.
    if s.action.kind == .Key_Down && !lint_any_key_up(doc) {
      add(out, s.id, .Note,
        "nothing in this chart releases a key - the run lets go when it ends",
        "add a 'key_up' if you want it released sooner")
    }
    // `chance` re-rolls every time it is ASKED, and a branch on a bare loop is asked every watcher tick
    // (20ms). Authors read "30% chance" as "30% chance per pass", which it only is if a pass takes time.
    if s.op == .Branch && lint_condition_has(s.condition, .Chance) && !lint_waits_before(doc, s.id) {
      add(out, s.id, .Note,
        "this coin flip is re-rolled every tick (20ms), so it fires almost immediately",
        "put a 'wait' or 'wait_random' on the path into it to make it a chance per pass")
    }
  }
}

// A call node: does it name a block that exists, is that block still shaped the way this call site
// remembers, and would running it loop forever?
//
// This is the ONE check in the file that looks past the document, via the sub-chart registry - which is
// a header cache, not a session, so the "no Session" rule at the top still holds. Everything it reports
// is refused again at run start (script_expand_calls); the point of having it here is that a chart with
// a broken call should look broken on the canvas.
@(private = "file")
lint_call :: proc(doc: ^Behaviour_Doc, s: Script_Step, level: Chart_Problem_Level, out: ^[dynamic]Chart_Problem) {
  add :: proc(out: ^[dynamic]Chart_Problem, node: Node_Id, level: Chart_Problem_Level, text, hint: string) {
    append(out, Chart_Problem{node = node, level = level, text = text, hint = hint})
  }
  if level == .Error && s.call_name == "" {
    add(out, s.id, .Error, "this node calls no block", "pick one in the inspector, or delete the node")
    return
  }
  if s.call_name == "" {
    return
  }
  info := subchart_registry_find(s.call_name)
  if level == .Error {
    if info == nil {
      add(out, s.id, .Error,
        fmt.aprintf("there is no block called '%s'", s.call_name),
        "it may have been renamed or deleted - pick another in the inspector")
      return
    }
    // Direct self-call. The indirect case needs the whole graph and is caught at run start, where the
    // full call chain is available to name; catching the obvious half here is what makes the canvas
    // refuse the mistake as you draw it.
    if s.call_name == doc.name {
      add(out, s.id, .Error,
        "this block calls itself",
        "a block cannot call itself, directly or through another block")
      return
    }
    // A missing REQUIRED argument. Same rule and the same words as a blank required field on a catalog
    // block (lint_payload), because to whoever placed it they are the same mistake.
    for p in subchart_info_params(info) {
      if p.optional {
        continue
      }
      filled := false
      for i in 0 ..< min(s.call_arg_count, len(s.call_args)) {
        if s.call_args[i].name == p.name && strings.trim_space(s.call_args[i].value) != "" {
          filled = true
          break
        }
      }
      if !filled {
        add(out, s.id, .Error,
          fmt.aprintf("'%s' needs a %s and the field is empty", s.call_name, p.title == "" ? p.name : p.title),
          p.help)
      }
    }
    return
  }
  if level != .Warning || info == nil {
    return
  }
  // An argument for a setting the block no longer has: it was renamed or removed after this call was
  // placed. Not an error - the run ignores it - but it is silently doing nothing, which is exactly the
  // kind of thing the Problems tab exists to surface.
  for i in 0 ..< min(s.call_arg_count, len(s.call_args)) {
    a := s.call_args[i]
    if a.name == "" {
      continue
    }
    known := false
    for p in subchart_info_params(info) {
      if p.name == a.name {
        known = true
        break
      }
    }
    if !known {
      add(out, s.id, .Warning,
        fmt.aprintf("'%s' has no setting called '%s' any more - this value is ignored", s.call_name, a.name),
        "open the block to see what it takes now, or clear the value")
    }
  }
}

@(private = "file")
lint_arm :: proc(s: Script_Step, arm: Node_Id, name: string, mode: Script_Mode, out: ^[dynamic]Chart_Problem) {
  if arm != 0 {
    return
  }
  if mode == .Loop {
    append(out, Chart_Problem{
      node  = s.id,
      level = .Error,
      text  = fmt.aprintf("the '%s' arm goes nowhere, so the run ENDS when it is taken", name),
      hint  = "this chart is set to loop - wire the arm, or switch the mode to 'once' if ending is the point",
    })
    return
  }
  append(out, Chart_Problem{
    node  = s.id,
    level = .Warning,
    text  = fmt.aprintf("the '%s' arm goes nowhere, so the run ends when it is taken", name),
    hint  = "fine for a 'once' chart that is finished here; wire it otherwise",
  })
}

// --- arguments -------------------------------------------------------------------------------------

// Every string argument of the step's action and of every condition row. Two passes over the same walk,
// selected by <level>, so the ERROR findings (a blank required field, a key name that is not one) and
// the WARNING ones (an @name nothing sets) stay in their own sections of the report.
@(private = "file")
lint_arguments :: proc(
  s: Script_Step,
  set_names: map[string]bool,
  level: Chart_Problem_Level,
  out: ^[dynamic]Chart_Problem,
  in_subchart: bool,
) {
  if def := action_def(s.action.kind); def != nil {
    lint_payload(s, def.name, def.params, s.action.strs, set_names, level, out, in_subchart)
  }
  for i in 0 ..< condition_row_count(s.condition) {
    r := condition_row(s.condition, i)
    if def := event_def(r.kind); def != nil {
      lint_payload(s, def.name, def.params, r.strs, set_names, level, out, in_subchart)
    }
  }
  if s.has_until {
    for i in 0 ..< condition_row_count(s.until) {
      r := condition_row(s.until, i)
      if def := event_def(r.kind); def != nil {
        lint_payload(s, def.name, def.params, r.strs, set_names, level, out, in_subchart)
      }
    }
  }
}

@(private = "file")
lint_payload :: proc(
  s: Script_Step,
  block: string,
  spec: []Param_Spec,
  strs: [2]string,
  set_names: map[string]bool,
  level: Chart_Problem_Level,
  out: ^[dynamic]Chart_Problem,
  // Inside a BLOCK, an unset @name gets the sub-chart-specific message from lint_subchart_document
  // instead ("reads @x but never sets it - add it as a setting"), which is both more accurate and more
  // actionable. Emitting both would be two warnings about one thing.
  in_subchart: bool,
) {
  for p, i in spec {
    // A Coord's expression slot is a string argument in every way that matters here: it is where
    // `walk_to @spot` lives, so an @name in it has to be checked like any other. Its EMPTY state is
    // not a blank field though - it means "the numbers next to it are the value" - so it skips the
    // required-and-empty check below rather than reporting a chart that is perfectly filled in.
    if p.kind == .Coord {
      _, expression_slot := param_slots(spec, i)
      if level == .Warning && !in_subchart && strs[expression_slot] != "" {
        lint_references(s, strs[expression_slot], set_names, out)
      }
      continue
    }
    if !param_kind_is_str(p.kind) {
      continue
    }
    raw := strs[param_slot(spec, i)]
    if level == .Error && !p.optional && strings.trim_space(raw) == "" {
      append(out, Chart_Problem{
        node  = s.id,
        level = .Error,
        text  = fmt.aprintf("'%s' needs a %s and the field is empty", block, p.title),
        hint  = p.help,
      })
      continue
    }
    if raw == "" {
      continue
    }
    // A variable NAME field holding "@dir": the mistake the runtime now works around and the linter has
    // to name, because working around it silently is how it stays in the file forever.
    if p.kind == .Var_Name && strings.has_prefix(strings.trim_space(raw), "@") {
      if level == .Error {
        append(out, Chart_Problem{
          node  = s.id,
          level = .Error,
          text  = fmt.aprintf("'%s' is the NAME field - '%s' would name a variable no @reference can reach", p.title, raw),
          hint  = fmt.aprintf("write it without the @: %s", strings.trim_left(strings.trim_space(raw), "@")),
        })
      }
      continue
    }
    if level == .Warning && !in_subchart {
      lint_references(s, raw, set_names, out)
    }
    // A value with an @name in it is whatever the variable turns out to hold, which is not a question
    // this file can answer - every check below has to stand down for one.
    if strings.contains(raw, "@") {
      continue
    }
    #partial switch p.kind {
    case .Key:
      if level == .Error {
        if _, ok := vk_from_name(raw); !ok {
          append(out, Chart_Problem{
            node  = s.id,
            level = .Error,
            text  = fmt.aprintf("'%s' is not a key name", raw),
            hint  = "try a single letter or digit, or space / enter / esc / tab / f1-f12",
          })
        }
      }
    case .Choice:
      // A WARNING, never an error. `choices` is what the block knows about today; a value outside it
      // is more likely to be something this build has not learned than a typo, and a linter that
      // refuses the unfamiliar is one you start ignoring.
      if level == .Warning && !name_list_contains(p.choices, raw) {
        append(out, Chart_Problem{
          node  = s.id,
          level = .Warning,
          text  = fmt.aprintf("'%s' is not one of the values '%s' knows", raw, p.title),
          hint  = fmt.aprintf("expected one of: %s", strings.join(p.choices, ", ", context.temp_allocator)),
        })
      }
    }
  }
}

// Every @name in <raw> that nothing in this chart sets. A WARNING, never an error: the REPL's own `var`
// command writes the same store, so `var dir D` typed once before the run is a perfectly good way to
// seed one - the linter simply cannot see it, and says what it can see instead.
@(private = "file")
lint_references :: proc(s: Script_Step, raw: string, set_names: map[string]bool, out: ^[dynamic]Chart_Problem) {
  names := make([dynamic]string, 0, 4, context.temp_allocator)
  lint_scan_references(raw, &names)
  for name in names {
    if set_names[name] {
      continue
    }
    append(out, Chart_Problem{
      node  = s.id,
      level = .Warning,
      text  = fmt.aprintf("nothing in this chart sets '%s', so @%s stays as literal text", name, name),
      hint  = fmt.aprintf("add a 'var' node that sets %s, or set it from the REPL with: var %s <value>", name, name),
    })
  }
}

// Same alphabet expand_vars uses. Kept in step with it by hand rather than exported from engine: a
// linter that accepted a name the expander would not is worse than no linter.
@(private = "file")
lint_name_byte :: proc(c: byte) -> bool {
  return c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// Every variable this chart WRITES. `var`, `add` and `read_value` all create one - `add` at 0 and
// `read_value` at whatever the game says - so all three count as setting it.
//
// A CALL COUNTS TOO, twice over: it sets every argument it passes (script_take_call does exactly that),
// and it runs a whole document that sets things of its own. The second half is why Subchart_Info
// carries `sets` - without it, the normal way to get a value out of a block (the block computes it, the
// caller reads it, because a call has no return value) would warn at every caller.
@(private = "file")
lint_variables_set :: proc(doc: ^Behaviour_Doc) -> map[string]bool {
  out := make(map[string]bool, 8, context.temp_allocator)
  for s in doc.steps {
    #partial switch s.action.kind {
    case .Var, .Add, .Read_Value:
      if name := script_var_name_of(s.action.strs[0]); name != "" {
        out[name] = true
      }
    }
    if s.op != .Call {
      continue
    }
    for i in 0 ..< min(s.call_arg_count, len(s.call_args)) {
      if s.call_args[i].name != "" {
        out[s.call_args[i].name] = true
      }
    }
    // One level, not the whole call graph. A block's OWN blocks are its business, and following the
    // graph from a linter that runs every frame would put a file read per call site per depth on it.
    if info := subchart_registry_find(s.call_name); info != nil {
      for n in info.sets {
        out[n] = true
      }
    }
  }
  return out
}

// Every @name <raw> references. The scan expand_vars does, factored out because two callers want it:
// lint_references, which reports the ones nothing sets, and the sub-chart free-variable check, which
// wants the names themselves.
@(private = "file")
lint_scan_references :: proc(raw: string, out: ^[dynamic]string) {
  i := 0
  for i < len(raw) {
    if raw[i] != '@' {
      i += 1
      continue
    }
    if i + 1 < len(raw) && raw[i + 1] == '@' {
      i += 2 // an escaped literal '@', same rule expand_vars follows
      continue
    }
    j := i + 1
    for j < len(raw) && lint_name_byte(raw[j]) {
      j += 1
    }
    if j == i + 1 {
      i += 1 // a bare '@' with nothing after it
      continue
    }
    append(out, raw[i + 1:j])
    i = j
  }
}

// Every @name anywhere in <s> - its action's arguments, every condition row's, and a call's argument
// values. Order is document order; duplicates are the caller's to collapse.
@(private = "file")
lint_step_references :: proc(s: Script_Step, allocator := context.temp_allocator) -> []string {
  out := make([dynamic]string, 0, 4, allocator)
  for str in s.action.strs {
    lint_scan_references(str, &out)
  }
  for i in 0 ..< condition_row_count(s.condition) {
    for str in condition_row(s.condition, i).strs {
      lint_scan_references(str, &out)
    }
  }
  if s.has_until {
    for i in 0 ..< condition_row_count(s.until) {
      for str in condition_row(s.until, i).strs {
        lint_scan_references(str, &out)
      }
    }
  }
  for i in 0 ..< min(s.call_arg_count, len(s.call_args)) {
    lint_scan_references(s.call_args[i].value, &out)
  }
  return out[:]
}

// The same set, sorted, as a slice - what the editor's variable-name picker offers. It deliberately
// asks the DOCUMENT rather than the session: the REPL may well have a `dir` set from an hour ago, and
// offering it here would suggest a chart reads something it never writes.
chart_variable_names :: proc(doc: ^Behaviour_Doc, allocator := context.temp_allocator) -> []string {
  set := lint_variables_set(doc)
  out := make([dynamic]string, 0, len(set), allocator)
  for name in set {
    append(&out, name)
  }
  slice.sort(out[:])
  return out[:]
}

// --- graph walks ----------------------------------------------------------------------------------

// Which nodes control can actually get to. Seeded from the start node AND from every watcher, because a
// watcher is hoisted out of the instruction stream (so it is always live) and its body is only ever
// entered by its own edge.
//
// <from> overrides the document's own start node - what `script run <x> from <node>` asks, to work out
// which half of the chart a debug run will actually see. 0 means "the document's start node", which is
// the linting case and every other caller.
@(private = "file")
lint_reachable :: proc(doc: ^Behaviour_Doc, ids: map[Node_Id]int, from: Node_Id = 0) -> map[Node_Id]bool {
  seen := make(map[Node_Id]bool, len(doc.steps), context.temp_allocator)
  if len(doc.steps) == 0 {
    return seen
  }
  pending := make([dynamic]Node_Id, context.temp_allocator)
  defer delete(pending)

  entry := from != 0 ? from : (doc.entry != 0 ? doc.entry : doc.steps[0].id)
  append(&pending, entry)
  for s in doc.steps {
    if s.op == .On {
      append(&pending, s.id) // hoisted: armed whether or not anything wires to it
    }
  }
  for len(pending) > 0 {
    id := pop(&pending)
    if seen[id] {
      continue
    }
    seen[id] = true
    index, ok := ids[id]
    if !ok {
      continue
    }
    s := doc.steps[index]
    if s.goto_id != 0 {
      append(&pending, s.goto_id)
    }
    if s.else_id != 0 {
      append(&pending, s.else_id)
    }
    // FALL-THROUGH to the next array slot, for the ops that still have one - `.On`, whose body is
    // reached by its edge while the main program walks PAST it, and any structured op that outlived
    // lowering. An .Action with no successor ends the program (script_op_falls_through).
    //
    // `.On` IS THE ONE OP WITH BOTH, and the `goto_id == 0` guard is wrong for it: its edge names a
    // BODY, reached only when the trigger fires, and the next slot is where the main program carries
    // on regardless. Every other op has one or the other. This was latent for as long as a
    // builder-made `on` carried its action inline and named no body - the guard happened to hold.
    // The moment script_materialize_watcher_bodies gave it one, this severed the entire main program
    // of every chart with a watcher at the top of it, and `clockworks` linted 41 unreachable nodes.
    if (s.op == .On || s.goto_id == 0) && script_op_falls_through(s.op) && index + 1 < len(doc.steps) {
      append(&pending, doc.steps[index + 1].id)
    }
  }
  return seen
}

// Does anything on a path INTO <target> take time? Answered by walking backwards one edge at a time from
// every node that leads to it, so a `wait` three nodes up still counts - what the `chance` note is really
// asking is "does a pass round this loop take longer than a tick".
//
// Bounded by the node count: a cycle is the normal case here (the loop is the point), so the visited set
// is what terminates it.
@(private = "file")
lint_waits_before :: proc(doc: ^Behaviour_Doc, target: Node_Id) -> bool {
  seen := make(map[Node_Id]bool, len(doc.steps), context.temp_allocator)
  defer delete(seen)
  pending := make([dynamic]Node_Id, context.temp_allocator)
  defer delete(pending)
  append(&pending, target)
  for len(pending) > 0 {
    id := pop(&pending)
    if seen[id] {
      continue
    }
    seen[id] = true
    for s, i in doc.steps {
      if !lint_leads_to(doc, s, i, id) {
        continue
      }
      #partial switch s.action.kind {
      case .Wait, .Wait_Random, .Walk_To, .Approach, .Hold_Target, .Sweep_Lane, .Sweep_To, .Farm, .Press_Key:
        return true
      }
      if s.op == .Wait_For {
        return true
      }
      append(&pending, s.id)
    }
  }
  return false
}

@(private = "file")
lint_leads_to :: proc(doc: ^Behaviour_Doc, s: Script_Step, index: int, target: Node_Id) -> bool {
  if s.goto_id == target || s.else_id == target {
    return true
  }
  return(
    s.goto_id == 0 &&
    script_op_falls_through(s.op) &&
    index + 1 < len(doc.steps) &&
    doc.steps[index + 1].id == target \
  )
}

@(private = "file")
lint_any_key_up :: proc(doc: ^Behaviour_Doc) -> bool {
  for s in doc.steps {
    if s.action.kind == .Key_Up {
      return true
    }
  }
  return false
}

@(private = "file")
lint_condition_has :: proc(condition: Script_Condition, kind: Script_Event_Kind) -> bool {
  for i in 0 ..< condition_row_count(condition) {
    if condition_row(condition, i).kind == kind {
      return true
    }
  }
  return false
}

// --- starting somewhere other than the top ----------------------------------------------------------
//
// What a chart is MISSING when you start it partway down. This is the honest half of `script run <x>
// from <node>`: the nodes you skipped are usually the ones that set the chart up, and a run that
// starts after them reads their variables as literal text and behaves like a different chart.
//
// The same shape as the warning script_cmd_run already prints when a BLOCK is run on its own with
// nothing binding its parameters - name what is unset and who would have set it, then let it run.

// One variable a from-here run will read but nothing on its path sets.
Entry_Gap :: struct {
  name:         string, // the variable, with no leading '@'
  set_by:       Node_Id, // the skipped node that writes it, 0 if nothing in the chart does
  set_by_label: string, // that node's caption, for "(set by node 3 'read my position')"
}

// Every variable read on some path out of <from> that no node on that path sets.
//
// DOCUMENT-ONLY, deliberately - it does not ask the session what happens to be set right now, for the
// reason chart_variable_names gives: this is a fact about the chart, and the caller is the one that
// knows whether a value in the store is a restored snapshot or an hour-old leftover. script_cmd_run
// filters the result against session.vars; a purely static caller does not have to.
//
// Strings point into <doc>, so they live exactly as long as it does.
script_entry_gap :: proc(doc: ^Behaviour_Doc, from: Node_Id, allocator := context.temp_allocator) -> []Entry_Gap {
  out := make([dynamic]Entry_Gap, 0, 4, allocator)
  if len(doc.steps) == 0 {
    return out[:]
  }
  ids := make(map[Node_Id]int, len(doc.steps), context.temp_allocator)
  defer delete(ids)
  for s, i in doc.steps {
    ids[s.id] = i
  }
  reachable := lint_reachable(doc, ids, from)
  defer delete(reachable)

  // What the half of the chart you WILL run writes for itself. A variable set downstream of the entry
  // is not missing, however far downstream - `read my position` two nodes in covers the `@home` a node
  // after that reads, and reporting it would be noise on every well-formed chart.
  written := make(map[string]bool, 8, context.temp_allocator)
  defer delete(written)
  for s in doc.steps {
    if !reachable[s.id] {
      continue
    }
    #partial switch s.action.kind {
    case .Var, .Add, .Read_Value:
      if name := script_var_name_of(s.action.strs[0]); name != "" {
        written[name] = true
      }
    }
    if s.op == .Call {
      for i in 0 ..< min(s.call_arg_count, len(s.call_args)) {
        if s.call_args[i].name != "" {
          written[s.call_args[i].name] = true
        }
      }
      // A called block sets things of its own, exactly as lint_variables_set counts them - without
      // this, the normal way to get a value out of a block would be reported missing at every caller.
      if info := subchart_registry_find(s.call_name); info != nil {
        for n in info.sets {
          written[n] = true
        }
      }
    }
  }

  seen := make(map[string]bool, 8, context.temp_allocator)
  defer delete(seen)
  for s in doc.steps {
    if !reachable[s.id] {
      continue
    }
    for name in lint_step_references(s) {
      if name == "" || seen[name] || written[name] {
        continue
      }
      seen[name] = true
      gap := Entry_Gap {
        name = name,
      }
      // Who WOULD have set it - a node outside the path, i.e. one of the ones being skipped. That is
      // the actually useful half: "@home_x (set by node 3 'read my position')" tells you both what to
      // supply and that running from node 3 instead would supply it for you.
      for other in doc.steps {
        if reachable[other.id] {
          continue
        }
        writes := false
        #partial switch other.action.kind {
        case .Var, .Add, .Read_Value:
          writes = script_var_name_of(other.action.strs[0]) == name
        }
        if !writes && other.op == .Call {
          for i in 0 ..< min(other.call_arg_count, len(other.call_args)) {
            if other.call_args[i].name == name {
              writes = true
              break
            }
          }
        }
        if writes {
          gap.set_by = other.id
          gap.set_by_label = other.src
          break
        }
      }
      append(&out, gap)
    }
  }
  return out[:]
}

// --- the CLI ---------------------------------------------------------------------------------------

// `script lint [<name>]` - the same verdict the editor's Problems tab shows, for a chart you have not
// opened. No argument lints every saved behaviour and every built-in, which is what makes it a
// regression check as well as an authoring one.
script_cmd_lint :: proc(session: ^Session, args: []string) {
  if len(args) == 0 {
    script_lint_all()
    return
  }
  doc, ok := bhv_open(args[0])
  if !ok {
    fmt.eprintfln("script lint: no behaviour named '%s'. 'script list' shows what's available.", args[0])
    return
  }
  defer behaviour_doc_free(&doc)
  problems := script_lint(&doc)
  script_print_problems(doc.name, len(doc.steps), problems)
}

// "Clean" means no errors and no warnings. Notes do NOT make a chart dirty - they are things that are
// true and legitimate, and counting them against a chart would mean `auto` never reads as clean.
@(private = "file")
script_print_problems :: proc(name: string, nodes: int, problems: []Chart_Problem) {
  errors := script_lint_count(problems, .Error)
  warnings := script_lint_count(problems, .Warning)
  notes := script_lint_count(problems, .Note)
  if errors + warnings == 0 {
    fmt.printfln("%s: clean (%d nodes%s).", name, nodes, notes > 0 ? fmt.tprintf(", %d note(s)", notes) : "")
  } else {
    fmt.printfln("%s: %d node(s), %d error(s), %d warning(s), %d note(s):", name, nodes, errors, warnings, notes)
  }
  for p in problems {
    where_at := p.node == 0 ? "chart" : fmt.tprintf("node #%d", u32(p.node))
    fmt.printfln("  %-8s %-10s %s", CHART_PROBLEM_LEVEL_NAMES[p.level], where_at, p.text)
    if p.hint != "" {
      fmt.printfln("           %-10s -> %s", "", p.hint)
    }
  }
}

// Every behaviour the tool can run, saved files and built-ins alike. Prints one line per clean chart and
// the full report for anything that is not.
@(private = "file")
script_lint_all :: proc() {
  names := make([dynamic]string, context.temp_allocator)
  defer delete(names)
  for &d in BEHAVIOURS {
    append(&names, d.name)
  }
  for &d in TEST_BEHAVIOURS {
    append(&names, d.name)
  }
  for n in bhv_list_names() {
    already := false
    for existing in names {
      if existing == n {
        already = true // a saved file that SHADOWS a built-in: bhv_open returns the file, so lint it once
        break
      }
    }
    if !already {
      append(&names, n)
    }
  }
  total_errors, total_warnings, dirty := 0, 0, 0
  for n in names {
    doc, ok := bhv_open(n)
    if !ok {
      continue
    }
    problems := script_lint(&doc)
    errors := script_lint_count(problems, .Error)
    warnings := script_lint_count(problems, .Warning)
    total_errors += errors
    total_warnings += warnings
    if errors + warnings > 0 {
      dirty += 1
      script_print_problems(doc.name, len(doc.steps), problems)
    } else {
      notes := script_lint_count(problems, .Note)
      fmt.printfln("%s: clean (%d nodes%s).", doc.name, len(doc.steps), notes > 0 ? fmt.tprintf(", %d note(s)", notes) : "")
    }
    behaviour_doc_free(&doc)
  }
  fmt.printfln(
    "%d behaviour(s) linted: %d with something to fix, %d error(s), %d warning(s) in total.",
    len(names), dirty, total_errors, total_warnings,
  )
}
