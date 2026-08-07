package flyff

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"

// ===========================================================================
// Behaviour documents on disk - <exe-dir>/behaviours/<name>.bhv
//
// WHY THIS IS NOT THE OLD TEXT LANGUAGE COMING BACK. The `.ms` parser was deleted on purpose: it forced
// a bespoke syntax on anyone who wanted to author behaviour, which is the opposite of the goal. This is
// the other thing - a SERIALIZATION for data an editor produced. Nobody hand-writes it, nothing here is
// a syntax to learn, and it exists because a visual editor needs somewhere to save. Odin stays the
// authoring language for behaviours that live in the repo (builder.odin / behaviours.odin); the node
// editor is the authoring surface for behaviours that live in a file.
//
// SHAPE. Line-based and tolerant, exactly like flyff.cfg and fences/*.fence:
//
//     # memscan behaviour
//     mode loop
//     entry 1
//     node 1 action 120 80
//       do target 'Aibatt'
//     node 2 while 120 200 goto=6
//       group Pick a target
//       if not focus_lost
//
// A `node` line carries identity, op, editor position and the structural edges; the indented lines that
// follow carry its payload (`do` = action, `if` = condition, `until` = the early-out on an action, and
// `group` = which named section of the chart it belongs to). The
// FILENAME is the behaviour's name - there is no name field to drift out of sync with it.
//
// THE PAYLOAD LINES ARE WRITTEN BY THE RENDERER THE REST OF THE TOOL ALREADY USES.
// script_write_action / script_write_event (script.odin) produce them, so a saved block is spelled the
// same way `script show` spells it. The reader is their mirror: it looks the block up by name in the
// catalog and then parses arguments straight off that row's []Param_Spec. Adding a block to
// script_blocks.odin therefore teaches this file about it too, with no edit here.
// ===========================================================================

// ===========================================================================
// The sub-chart registry - package-level state, refreshed from disk on a throttle
// ===========================================================================
//
// What blocks the user has made. Package-level rather than carried on Panel_State because the readers
// are scattered and most of them are not the GUI: the palette, a suggestion field, the canvas title of
// a call node, `script list`, and the LINTER, which has to know what a called block sets before it can
// tell an author that nothing sets it.
//
// SELF-THROTTLING, so no caller has to remember to refresh it. Every accessor below refreshes first;
// at one directory scan per REGISTRY_INTERVAL that is cheap enough for a per-frame linter and correct
// enough for a CLI command that runs once. Timed off core:time rather than raylib, because the CLI
// half of the tool has no window and must not depend on one.
REGISTRY_INTERVAL_NS :: i64(1_500_000_000)

@(private = "file")
subchart_registry: [dynamic]Subchart_Info
@(private = "file")
subchart_registry_at: i64
@(private = "file")
subchart_registry_names_cache: [dynamic]string

// Rebuild from disk if the cache is stale. <force> is for the one case a throttle gets wrong: something
// this process just SAVED, where the answer has to change now rather than within a second and a half.
subchart_registry_refresh :: proc(force := false) {
  now := time.now()._nsec
  if !force && subchart_registry_at != 0 && now - subchart_registry_at < REGISTRY_INTERVAL_NS {
    return
  }
  subchart_registry_at = now
  for &info in subchart_registry {
    subchart_info_free(&info)
  }
  clear(&subchart_registry)
  clear(&subchart_registry_names_cache)
  for name in bhv_list_names() {
    info, ok := bhv_read_header(name)
    if !ok {
      continue
    }
    if !info.is_subchart {
      subchart_info_free(&info)
      continue
    }
    append(&subchart_registry, info)
    append(&subchart_registry_names_cache, info.name)
  }
}

// Every sub-chart, in directory order. Borrowed - valid until the next refresh.
subchart_registry_rows :: proc() -> []Subchart_Info {
  subchart_registry_refresh()
  return subchart_registry[:]
}

// Just the names, for a suggestion corpus.
subchart_registry_names :: proc() -> []string {
  subchart_registry_refresh()
  return subchart_registry_names_cache[:]
}

// One row by name, or nil. This is how a call node finds the parameters to draw fields for.
subchart_registry_find :: proc(name: string) -> ^Subchart_Info {
  subchart_registry_refresh()
  for &info in subchart_registry {
    if info.name == name {
      return &info
    }
  }
  return nil
}

BHV_EXT :: ".bhv"

// Spelled as bytes, not as the character: Odin's lexer rejects a literal BOM in a source file.
BHV_BOM :: "\xef\xbb\xbf"

// LEGACY, read-only. A file used to declare itself `kind interrupt` with a `trigger <event>` header,
// which made an interrupt a second sort of document: a whole program with one condition bolted to the
// front, armed instead of started. Meanwhile a chart could also hold `on` nodes, which were a watcher
// with a SINGLE action and no body. Two spellings of one idea, with different powers - and the `on`
// node could end up drawn where the start node belongs, so a chart looked like it began at a watcher.
//
// There is now one concept: a WATCHER is an `.On` node plus the body its edge points at. It can sit
// inline in any chart, be attached to one by name (Behaviour_Doc.uses), or be armed globally. This
// enum survives only so bhv_deserialize can UPGRADE an old file - see bhv_upgrade_interrupt - and the
// writer never emits it again.
Behaviour_Kind :: enum {
  Chart,
  Interrupt,
}

// An authored behaviour. This is what an editor edits and what a file holds; `steps` is the same
// []Script_Step the VM walks, so handing one to script_begin needs no conversion.
Behaviour_Doc :: struct {
  name:    string, // owned; the file's basename
  kind:    Behaviour_Kind, // legacy, see above; always .Chart after a load
  trigger: Script_Event, // legacy, see above; consumed by the upgrade. Owned strings.
  mode:    Script_Mode,
  entry:   Node_Id, // node the run starts at. 0 = "the first step", which is what a linear program wants.
  steps:   [dynamic]Script_Step,
  // Other behaviours whose WATCHERS this chart borrows, by name, in priority order (first match wins,
  // the same rule the run's own watcher array follows). `uses <name>` in the file. This is the middle
  // of the three scopes: inline is one chart's own business, global is everything's, and this is "this
  // chart also watches for that".
  uses:    [dynamic]string, // owned
  // One line of description. Every chart may have one - the browser had nowhere to read a blurb from
  // for a saved file, so every tile but the built-in ones was a bare name. A sub-chart NEEDS one: it
  // appears in the palette next to blocks that all carry a sentence saying what they do.
  desc:    string, // owned
  // Run this chart with the proactive collision gate OFF: pick, approach and hold a monster without
  // ever asking whether the straight line to it is clear. DECLARED, not derived - there is nothing in
  // a chart's nodes that implies it, and it is the same kind of statement as `subchart`.
  //
  // It exists because the gate can be WRONG. compute_reach treats every collider box as a wall, and
  // some maps - dungeons especially - are carpeted with props that a character walks straight over.
  // There the gate excludes most of the room and the ladder starves. The narrow fix is `collignore`
  // (drop one collider KIND, radar key I), and it is the better tool when one prop is the culprit;
  // this is the blunt one for a map where the whole floor is the problem.
  //
  // A property of the CHART rather than a setting on the session, so it travels in the .bhv and is
  // scoped to the run - a dungeon chart carries it, the field chart next to it does not, and neither
  // has to remember to put a global back. See reach_gate_active.
  ignore_collision: bool,
  // --- the sub-chart half -------------------------------------------------------------------------
  // Is this document a BLOCK rather than a program? Declared by a `subchart` line, not derived from
  // content the way "watchers only" is: there is nothing in a chart's nodes from which a parameter list
  // could be inferred, and a chart that silently changed kind when you added a parameter would be worse
  // than one that says so. What it costs you is listed in script_lint - once mode, no watchers, no
  // borrowing, no recursion.
  is_subchart: bool,
  // What a call site fills in. Param_Spec is REUSED rather than mirrored: it is exactly what ed_params
  // renders a field from and what the linter judges a value against, so a declared parameter is the
  // same kind of thing as a catalog one and every generic consumer already knows how to treat it.
  // `name`, `title` and `help` are owned; see behaviour_doc_free.
  params:      [SUBCHART_MAX_PARAMS]Param_Spec,
  param_count: int,
}

// The declared parameters, as the slice every spec-driven consumer wants.
subchart_params :: proc(doc: ^Behaviour_Doc) -> []Param_Spec {
  if doc == nil {
    return nil
  }
  return doc.params[:min(doc.param_count, SUBCHART_MAX_PARAMS)]
}

// Which parameter kinds a sub-chart may declare, and why not the others.
//
// An argument arrives as a VARIABLE, and `@name` is only expanded in slots that have text to expand -
// script_arg for the string kinds, script_coord for a Coord's expression slot. A numeric slot is an
// f64 with nowhere to put an expression, so `approach @dist` cannot work; declaring a numeric parameter
// would produce a block whose knob silently did nothing. See BACKLOG.md, "Numeric block arguments do
// not interpolate" - that item is what unblocks the other four kinds.
subchart_param_kind_ok :: proc(kind: Param_Kind) -> bool {
  switch kind {
  case .Str, .Names, .Mob, .Key, .Var_Name, .Choice, .Chart_Name, .Coord:
    return true
  case .Num, .Duration, .Percent:
    return false
  }
  return false
}

SUBCHART_NUMERIC_WHY :: "a number cannot be passed in yet - an argument arrives as @name, and numeric slots do not interpolate (BACKLOG: 'Numeric block arguments do not interpolate'). Use a text kind, or test the value with var_above / var_below inside the sub-chart."

// A string field of a step, copied so the copy owns it. Empty stays empty rather than becoming a
// zero-length allocation: script_step_free deletes every one of these, and "" carries no pointer to
// free, so the two halves agree without either having to remember which fields were set.
@(private = "file")
clone_if :: proc(s: string) -> string {
  return s == "" ? "" : strings.clone(s)
}

// A deep copy: the result owns every string, so freeing it cannot disturb the original. This is what
// makes undo possible - a snapshot that shared its strings would be freed twice the moment either
// copy went away.
script_step_clone :: proc(s: Script_Step) -> Script_Step {
  out := s
  out.src = clone_if(s.src)
  out.group = clone_if(s.group)
  out.call_name = clone_if(s.call_name)
  // Every slot, not just [0, call_arg_count) - script_step_free deletes every slot, so cloning fewer
  // would hand the copy a pointer into the original's strings and free it twice.
  for a, i in s.call_args {
    out.call_args[i].name = clone_if(a.name)
    out.call_args[i].value = clone_if(a.value)
  }
  out.action.strs[0] = clone_if(s.action.strs[0])
  out.action.strs[1] = clone_if(s.action.strs[1])
  // Every ROW of each condition, not just row 0 - see script_condition_free for the other half of this.
  for i in 0 ..< condition_row_count(s.condition) {
    r := condition_row_ptr(&out.condition, i)
    r.strs[0] = clone_if(r.strs[0])
    r.strs[1] = clone_if(r.strs[1])
  }
  for i in 0 ..< condition_row_count(s.until) {
    r := condition_row_ptr(&out.until, i)
    r.strs[0] = clone_if(r.strs[0])
    r.strs[1] = clone_if(r.strs[1])
  }
  return out
}

behaviour_doc_clone :: proc(doc: Behaviour_Doc) -> (out: Behaviour_Doc) {
  out = doc
  out.name = clone_if(doc.name)
  out.desc = clone_if(doc.desc)
  for p, i in doc.params {
    out.params[i].name = clone_if(p.name)
    out.params[i].title = clone_if(p.title)
    out.params[i].help = clone_if(p.help)
    out.params[i].choices = subchart_choices_clone(p.choices)
  }
  out.trigger.strs[0] = clone_if(doc.trigger.strs[0])
  out.trigger.strs[1] = clone_if(doc.trigger.strs[1])
  out.steps = make([dynamic]Script_Step, 0, len(doc.steps))
  for s in doc.steps {
    append(&out.steps, script_step_clone(s))
  }
  out.uses = make([dynamic]string, 0, len(doc.uses))
  for u in doc.uses {
    append(&out.uses, strings.clone(u))
  }
  return
}

behaviour_doc_free :: proc(doc: ^Behaviour_Doc) {
  script_steps_free(&doc.steps)
  delete(doc.trigger.strs[0])
  delete(doc.trigger.strs[1])
  for u in doc.uses {
    delete(u)
  }
  delete(doc.uses)
  delete(doc.name)
  delete(doc.desc)
  // Every slot, past param_count too - dropping a parameter in the editor lowers the count without
  // clearing the row behind it, and the row still owns its strings.
  for &p in doc.params {
    delete(p.name)
    delete(p.title)
    delete(p.help)
    subchart_choices_free(&p.choices)
  }
  doc^ = {}
}

// A .Choice parameter's value list. Owned as a whole - the slice AND every string in it - because it
// is built from a `choices=a,b,c` token rather than pointing at the rodata a catalog row uses.
subchart_choices_clone :: proc(src: []string) -> []string {
  if len(src) == 0 {
    return nil
  }
  out := make([]string, len(src))
  for s, i in src {
    out[i] = strings.clone(s)
  }
  return out
}

subchart_choices_free :: proc(choices: ^[]string) {
  for c in choices^ {
    delete(c)
  }
  delete(choices^)
  choices^ = nil
}

// --- paths ---------------------------------------------------------------------------------------

bhv_dir_path :: proc(allocator := context.temp_allocator) -> string {
  exe := os.args[0]
  slash := strings.last_index_any(exe, "\\/")
  dir := slash >= 0 ? exe[:slash] : "."
  return fmt.aprintf("%s/behaviours", dir, allocator = allocator)
}

bhv_file_path :: proc(name: string, allocator := context.temp_allocator) -> string {
  return fmt.aprintf("%s/%s%s", bhv_dir_path(allocator), name, BHV_EXT, allocator = allocator)
}

// A behaviour name becomes both a filename and a REPL argument, so it may not contain anything that
// would escape the directory or survive `strings.fields` badly. SPACES ARE OUT for the second reason:
// every UI action is issued as the command a user would type (`script run <name>`), and the REPL splits
// arguments on whitespace - a name with a space would work in the browser and break on the command line,
// which is exactly the private-code-path the UI is not allowed to have.
bhv_name_ok :: proc(name: string) -> bool {
  if name == "" || len(name) > 64 {
    return false
  }
  for r in name {
    switch r {
    case 'a' ..= 'z', 'A' ..= 'Z', '0' ..= '9', '_', '-':
      continue
    case:
      return false
    }
  }
  return true
}

BHV_NAME_RULE :: "letters, digits, - and _ only (no spaces: the name is also a command argument)"

// A PARAMETER's name, which is a stricter thing than a document's: it becomes a variable, so it has to
// survive `@name` interpolation. That alphabet is engine/vars.odin's var_name_byte - a hyphen would end
// the name early and `@stop-at` would read as `@stop` followed by "-at". Kept in step with it by hand
// for the same reason lint_name_byte is: the engine's copy is file-private.
bhv_param_name_ok :: proc(name: string) -> bool {
  if name == "" || len(name) >= SUBCHART_SAVE_NAME {
    return false // SUBCHART_SAVE_NAME is what a call frame can remember; a longer name could not be restored
  }
  for i in 0 ..< len(name) {
    c := name[i]
    if c != '_' && !(c >= '0' && c <= '9') && !(c >= 'a' && c <= 'z') && !(c >= 'A' && c <= 'Z') {
      return false
    }
  }
  return true
}

// --- op names ------------------------------------------------------------------------------------

@(rodata)
BHV_OP_NAMES := [Script_Op]string {
  .Action   = "action",
  .If       = "if",
  .Else     = "else",
  .End      = "end",
  .Repeat   = "repeat",
  .While    = "while",
  .Wait_For = "wait_for",
  .On       = "on",
  .Loop     = "loop",
  .Goto     = "goto",
  .Branch   = "branch",
  .Return   = "return",
  .Call     = "call",
}

// The parameter kind names a `param` line spells. Not derived from the enum: the file's vocabulary is
// its own contract, and renaming a Param_Kind variant must not silently invalidate every saved
// sub-chart. A kind with no entry here simply cannot be declared, which is how the numeric three stay
// out (see subchart_param_kind_ok).
@(rodata)
BHV_PARAM_KIND_NAMES := [Param_Kind]string {
  .Num        = "num",
  .Duration   = "duration",
  .Percent    = "percent",
  .Coord      = "coord",
  .Str        = "text",
  .Names      = "names",
  .Mob        = "mob",
  .Key        = "key",
  .Var_Name   = "var",
  .Choice     = "choice",
  .Chart_Name = "chart",
}

bhv_param_kind_from_name :: proc(s: string) -> (kind: Param_Kind, ok: bool) {
  for n, k in BHV_PARAM_KIND_NAMES {
    if n == s {
      return k, true
    }
  }
  return .Str, false
}

bhv_op_from_name :: proc(s: string) -> (op: Script_Op, ok: bool) {
  for n, o in BHV_OP_NAMES {
    if n == s {
      return o, true
    }
  }
  return .Action, false
}

// --- write ---------------------------------------------------------------------------------------

bhv_serialize :: proc(doc: ^Behaviour_Doc, b: ^strings.Builder) {
  fmt.sbprintln(b, "# memscan behaviour")
  // `kind` / `trigger` are NOT written any more - a watcher is an `.On` node now, and bhv_deserialize
  // rewrites an old file into that shape on the way in. The reader still understands them, so an
  // existing interrupt file keeps working; re-saving one writes the new form.
  // A bare flag line, first, so `head -3` on a file answers "is this a block or a program".
  if doc.is_subchart {
    fmt.sbprintln(b, "subchart")
  }
  // Same shape and the same reason: a bare flag, high in the file, so what the chart IS reads before
  // what it does.
  if doc.ignore_collision {
    fmt.sbprintln(b, "ignore_collision")
  }
  // Rest-of-line, like `group` - a description is a sentence, and quoting one would be the only place
  // in this format where prose needed escaping.
  if doc.desc != "" {
    fmt.sbprintfln(b, "desc %s", doc.desc)
  }
  fmt.sbprintfln(b, "mode %s", doc.mode == .Loop ? "loop" : "once")
  fmt.sbprintfln(b, "entry %d", u32(doc.entry))
  // Borrowed watchers, in priority order. One line each rather than a comma list, because a behaviour
  // name is a command argument everywhere else in the tool and this keeps it one token.
  for u in doc.uses {
    fmt.sbprintfln(b, "uses %s", u)
  }
  // Declared parameters, in order - the order is the order the call site's fields are drawn in, so it
  // is authoring data and has to round-trip. Title and help are quoted because they contain spaces;
  // bhv_tokens already honours a leading quote, so the reader learns nothing new.
  for p in subchart_params(doc) {
    fmt.sbprintf(b, "param %s %s '%s' '%s'", p.name, BHV_PARAM_KIND_NAMES[p.kind], p.title, p.help)
    if len(p.choices) > 0 {
      fmt.sbprintf(b, " choices=%s", strings.join(p.choices, ",", context.temp_allocator))
    }
    if p.optional {
      fmt.sbprint(b, " optional")
    }
    fmt.sbprintln(b)
  }
  for step in doc.steps {
    fmt.sbprintf(b, "node %d %s %v %v", u32(step.id), BHV_OP_NAMES[step.op], step.ui_pos[0], step.ui_pos[1])
    if step.goto_id != 0 {
      fmt.sbprintf(b, " goto=%d", u32(step.goto_id))
    }
    if step.else_id != 0 {
      fmt.sbprintf(b, " else=%d", u32(step.else_id))
    }
    if step.op == .Repeat || step.op == .Loop {
      fmt.sbprintf(b, " count=%d", step.count)
    }
    // Only written when it is not the default, so a one-row condition's node line is unchanged.
    if step.condition.match_any {
      fmt.sbprint(b, " match=any")
    }
    if step.has_until && step.until.match_any {
      fmt.sbprint(b, " umatch=any")
    }
    if step.op == .End {
      fmt.sbprintf(b, " close=%s", BHV_OP_NAMES[step.close])
    }
    fmt.sbprintln(b)
    // A payload LINE rather than a node key, because a group name has spaces and bhv_tokens only
    // honours a quote at the start of a token - `group='Pick a target'` would come back as the single
    // token `group='Pick`. Taking the rest of the line verbatim sidesteps quoting entirely.
    if step.group != "" {
      fmt.sbprintfln(b, "  group %s", step.group)
    }
    // A call names its document and then one line per argument. Rest-of-line for the same reason
    // `group` is: an argument's value is free text (a monster name has spaces, a coord has a comma),
    // and the alternative is teaching the tokenizer about quoting inside a key=value token.
    if step.op == .Call {
      fmt.sbprintfln(b, "  call %s", step.call_name)
      for i in 0 ..< min(step.call_arg_count, len(step.call_args)) {
        a := step.call_args[i]
        if a.name == "" {
          continue
        }
        fmt.sbprintfln(b, "  arg %s %s", a.name, a.value)
      }
    }
    // Payload, in the same spelling `script show` uses - script_write_* is the single renderer.
    // A watcher carries no action of its own - what it does is the body it names - so `.On` is not
    // here. It used to be, for the legacy one-node shape; a document cannot hold that any more
    // (script_materialize_watcher_bodies upgrades it on load), so writing one would be inventing it.
    if step.op == .Action {
      strings.write_string(b, "  do ")
      script_write_action(b, step.action)
      fmt.sbprintln(b)
    }
    // ONE LINE PER CONDITION ROW, repeating a line the reader already understands rather than teaching
    // the tokenizer about infix `and` / `or`. A single-row condition is therefore byte-identical to
    // what a plain event used to write, so every existing .bhv still loads and every file this writes
    // is still readable by eye.
    if step.op == .If || step.op == .While || step.op == .Wait_For || step.op == .On || step.op == .Branch {
      for i in 0 ..< condition_row_count(step.condition) {
        strings.write_string(b, "  if ")
        script_write_event(b, condition_row(step.condition, i))
        fmt.sbprintln(b)
      }
    }
    if step.has_until {
      for i in 0 ..< condition_row_count(step.until) {
        strings.write_string(b, "  until ")
        script_write_event(b, condition_row(step.until, i))
        fmt.sbprintln(b)
      }
    }
  }
}

// --- read ----------------------------------------------------------------------------------------

// Split a payload line into tokens, honouring 'single quotes' so a monster name with spaces or commas
// survives the trip. Returns SLICES INTO <line> - quoting only trims the ends, so nothing is copied
// here; the caller clones what it decides to keep.
bhv_tokens :: proc(line: string, allocator := context.temp_allocator) -> []string {
  out := make([dynamic]string, allocator)
  i := 0
  for i < len(line) {
    for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
      i += 1
    }
    if i >= len(line) {
      break
    }
    if line[i] == '\'' {
      i += 1
      start := i
      for i < len(line) && line[i] != '\'' {
        i += 1
      }
      append(&out, line[start:i])
      if i < len(line) {
        i += 1 // closing quote
      }
      continue
    }
    start := i
    for i < len(line) && line[i] != ' ' && line[i] != '\t' {
      i += 1
    }
    append(&out, line[start:i])
  }
  return out[:]
}

// Fill a block's flat payload from its catalog row's parameter spec. The spec drives everything: which
// storage slot each argument lands in, how many slots it eats (Coord takes two), and what an omitted
// optional falls back to. CLONES strings - the step owns them.
bhv_parse_params :: proc(spec: []Param_Spec, toks: []string, nums: ^[4]f64, strs: ^[2]string) -> (ok: bool, err: string) {
  ti, ni, si := 0, 0, 0
  for p in spec {
    have := ti < len(toks)
    if !have {
      if !p.optional {
        return false, fmt.tprintf("missing required argument '%s'", p.name)
      }
      switch p.kind {
      case .Num, .Duration, .Percent:
        nums[ni] = p.def
        ni += 1
      case .Coord:
        ni += 2
        strs[si] = strings.clone("")
        si += 1
      case .Str, .Names, .Mob, .Key, .Var_Name, .Choice, .Chart_Name:
        strs[si] = strings.clone("")
        si += 1
      }
      continue
    }
    t := toks[ti]
    ti += 1
    switch p.kind {
    case .Num, .Duration, .Percent:
      v, vok := strconv.parse_f64(t)
      if !vok {
        return false, fmt.tprintf("argument '%s': '%s' is not a number", p.name, t)
      }
      nums[ni] = v
      ni += 1
    case .Coord:
      // `@spot` (or `@x,@z`) is stored as TEXT and resolved when the block runs, because the point of
      // a variable is that it differs between two visits to the node. Anything else has to be a
      // literal pair here and now - `walk_to sometown` is a typo, not a late-bound value.
      if strings.contains(t, "@") {
        strs[si] = strings.clone(t)
        si += 1
        ni += 2
        break
      }
      comma := strings.index_byte(t, ',')
      if comma < 0 {
        return false, fmt.tprintf("argument '%s': expected x,z but got '%s'", p.name, t)
      }
      x, xok := strconv.parse_f64(t[:comma])
      z, zok := strconv.parse_f64(t[comma + 1:])
      if !xok || !zok {
        return false, fmt.tprintf("argument '%s': '%s' is not an x,z pair", p.name, t)
      }
      nums[ni] = x
      nums[ni + 1] = z
      ni += 2
      strs[si] = strings.clone("")
      si += 1
    case .Str, .Names, .Mob, .Key, .Var_Name, .Choice, .Chart_Name:
      strs[si] = strings.clone(t)
      si += 1
    }
  }
  return true, ""
}

bhv_parse_action :: proc(toks: []string) -> (act: Script_Action, ok: bool, err: string) {
  if len(toks) == 0 {
    return {}, false, "empty action"
  }
  def := action_def_by_name(toks[0])
  if def == nil {
    return {}, false, fmt.tprintf("unknown action '%s' ('script blocks' lists them)", toks[0])
  }
  act.kind = def.kind
  pok, perr := bhv_parse_params(def.params, toks[1:], &act.nums, &act.strs)
  if !pok {
    return {}, false, fmt.tprintf("%s: %s", def.name, perr)
  }
  return act, true, ""
}

bhv_parse_event :: proc(toks_in: []string) -> (ev: Script_Event, ok: bool, err: string) {
  toks := toks_in
  if len(toks) > 0 && toks[0] == "not" {
    ev.negate = true
    toks = toks[1:]
  }
  if len(toks) == 0 {
    return {}, false, "empty event"
  }
  def := event_def_by_name(toks[0])
  if def == nil {
    return {}, false, fmt.tprintf("unknown event '%s' ('script blocks' lists them)", toks[0])
  }
  ev.kind = def.kind
  pok, perr := bhv_parse_params(def.params, toks[1:], &ev.nums, &ev.strs)
  if !pok {
    return {}, false, fmt.tprintf("%s: %s", def.name, perr)
  }
  return ev, true, ""
}

// Parse a whole document. Reports every problem it finds rather than the first, because a file that a
// node editor wrote is data the user cannot fix by hand-editing one line - they want to know the shape
// of the damage. Returns ok=false if anything was rejected; <doc> is then empty and already freed.
bhv_deserialize :: proc(name: string, content: string) -> (doc: Behaviour_Doc, ok: bool) {
  doc.name = strings.clone(name)
  doc.steps = make([dynamic]Script_Step)
  doc.uses = make([dynamic]string)
  problems := 0

  report :: proc(problems: ^int, lineno: int, msg: string) {
    fmt.eprintfln("  line %d: %s", lineno, msg)
    problems^ += 1
  }

  // A .bhv is machine-written, but it is plain text on purpose and people WILL open it in an editor -
  // and a Windows editor is entitled to prepend a UTF-8 BOM. Without this, saving from Notepad turns
  // line 1 into "unknown line".
  body := strings.trim_prefix(content, BHV_BOM)

  for raw, li in strings.split_lines(body, context.temp_allocator) {
    lineno := li + 1
    line := strings.trim_space(raw)
    if line == "" || line[0] == '#' {
      continue
    }
    toks := bhv_tokens(line)
    if len(toks) == 0 {
      continue
    }
    switch toks[0] {
    case "kind":
      if len(toks) < 2 {
        report(&problems, lineno, "kind: expected 'chart' or 'interrupt'")
        continue
      }
      switch toks[1] {
      case "chart":
        doc.kind = .Chart
      case "interrupt":
        doc.kind = .Interrupt
      case:
        report(&problems, lineno, fmt.tprintf("kind: expected 'chart' or 'interrupt', got '%s'", toks[1]))
      }

    case "trigger":
      ev, eok, eerr := bhv_parse_event(toks[1:])
      if !eok {
        report(&problems, lineno, fmt.tprintf("trigger: %s", eerr))
        continue
      }
      doc.trigger = ev

    case "subchart":
      doc.is_subchart = true

    case "ignore_collision":
      doc.ignore_collision = true

    case "desc":
      // Verbatim like `group` - it is a sentence, not a token list.
      doc.desc = strings.clone(strings.trim_space(line[len("desc"):]))

    case "param":
      if len(toks) < 5 {
        report(&problems, lineno, "param: expected \"param <name> <kind> 'Title' 'help sentence'\"")
        continue
      }
      if doc.param_count >= SUBCHART_MAX_PARAMS {
        report(&problems, lineno, fmt.tprintf("param: more than %d parameters on one sub-chart", SUBCHART_MAX_PARAMS))
        continue
      }
      if !bhv_param_name_ok(toks[1]) {
        report(&problems, lineno, fmt.tprintf("param: '%s' is not a usable name - letters, digits and _ only (it is read as @%s)", toks[1], toks[1]))
        continue
      }
      kind, kok := bhv_param_kind_from_name(toks[2])
      if !kok {
        report(&problems, lineno, fmt.tprintf("param: unknown kind '%s'", toks[2]))
        continue
      }
      // Refused at READ time, not only by the linter: a numeric parameter would load into a field that
      // silently does nothing, and a file that cannot work should say so where it is opened.
      if !subchart_param_kind_ok(kind) {
        report(&problems, lineno, fmt.tprintf("param %s: %s", toks[1], SUBCHART_NUMERIC_WHY))
        continue
      }
      spec := Param_Spec {
        name  = strings.clone(toks[1]),
        kind  = kind,
        title = strings.clone(toks[3]),
        help  = strings.clone(toks[4]),
      }
      bad_param := false
      for kv in toks[5:] {
        if kv == "optional" {
          spec.optional = true
          continue
        }
        eq := strings.index_byte(kv, '=')
        if eq < 0 {
          report(&problems, lineno, fmt.tprintf("param: '%s' is not key=value", kv))
          bad_param = true
          break
        }
        key, val := kv[:eq], kv[eq + 1:]
        switch key {
        case "choices":
          parts := strings.split(val, ",", context.temp_allocator)
          spec.choices = subchart_choices_clone(parts)
        case:
          report(&problems, lineno, fmt.tprintf("param: unknown key '%s' - written by a newer build?", key))
          bad_param = true
        }
        if bad_param {
          break
        }
      }
      if bad_param {
        delete(spec.name)
        delete(spec.title)
        delete(spec.help)
        subchart_choices_free(&spec.choices)
        continue
      }
      doc.params[doc.param_count] = spec
      doc.param_count += 1

    case "uses":
      if len(toks) < 2 {
        report(&problems, lineno, "uses: expected a behaviour name whose watchers this chart borrows")
        continue
      }
      if !bhv_name_ok(toks[1]) {
        report(&problems, lineno, fmt.tprintf("uses: '%s' is not a usable name - %s", toks[1], BHV_NAME_RULE))
        continue
      }
      append(&doc.uses, strings.clone(toks[1]))

    case "mode":
      if len(toks) < 2 {
        report(&problems, lineno, "mode: expected 'once' or 'loop'")
        continue
      }
      switch toks[1] {
      case "loop":
        doc.mode = .Loop
      case "once":
        doc.mode = .Once
      case:
        report(&problems, lineno, fmt.tprintf("mode: expected 'once' or 'loop', got '%s'", toks[1]))
      }

    case "entry":
      if len(toks) < 2 {
        report(&problems, lineno, "entry: expected a node id")
        continue
      }
      v, vok := strconv.parse_u64(toks[1])
      if !vok {
        report(&problems, lineno, fmt.tprintf("entry: '%s' is not a node id", toks[1]))
        continue
      }
      doc.entry = Node_Id(v)

    case "node":
      if len(toks) < 5 {
        report(&problems, lineno, "node: expected 'node <id> <op> <x> <y> [key=value ...]'")
        continue
      }
      id, id_ok := strconv.parse_u64(toks[1])
      op, op_ok := bhv_op_from_name(toks[2])
      x, x_ok := strconv.parse_f64(toks[3])
      y, y_ok := strconv.parse_f64(toks[4])
      if !id_ok || id == 0 {
        report(&problems, lineno, fmt.tprintf("node: '%s' is not a node id (ids start at 1)", toks[1]))
        continue
      }
      if !op_ok {
        report(&problems, lineno, fmt.tprintf("node: unknown op '%s'", toks[2]))
        continue
      }
      if !x_ok || !y_ok {
        report(&problems, lineno, "node: editor position must be two numbers")
        continue
      }
      step := Script_Step {
        id     = Node_Id(id),
        op     = op,
        ui_pos = {f32(x), f32(y)},
      }
      bad_key := false
      for kv in toks[5:] {
        eq := strings.index_byte(kv, '=')
        if eq < 0 {
          report(&problems, lineno, fmt.tprintf("node: '%s' is not key=value", kv))
          bad_key = true
          break
        }
        key, val := kv[:eq], kv[eq + 1:]
        switch key {
        case "goto":
          v, vok := strconv.parse_u64(val)
          if !vok {
            report(&problems, lineno, fmt.tprintf("goto: '%s' is not a node id", val))
            bad_key = true
          } else {
            step.goto_id = Node_Id(v)
          }
        case "else":
          v, vok := strconv.parse_u64(val)
          if !vok {
            report(&problems, lineno, fmt.tprintf("else: '%s' is not a node id", val))
            bad_key = true
          } else {
            step.else_id = Node_Id(v)
          }
        case "count":
          v, vok := strconv.parse_int(val)
          if !vok {
            report(&problems, lineno, fmt.tprintf("count: '%s' is not a number", val))
            bad_key = true
          } else {
            step.count = v
          }
        case "close":
          o, ook := bhv_op_from_name(val)
          if !ook {
            report(&problems, lineno, fmt.tprintf("close: unknown op '%s'", val))
            bad_key = true
          } else {
            step.close = o
          }
        case "match", "umatch":
          // How the `if` / `until` rows below are joined. Absent means all-of, which is why a
          // single-row condition writes no key at all.
          switch val {
          case "all":
          case "any":
            if key == "match" {
              step.condition.match_any = true
            } else {
              step.until.match_any = true
            }
          case:
            report(&problems, lineno, fmt.tprintf("%s: expected 'all' or 'any', got '%s'", key, val))
            bad_key = true
          }
        case:
          // Loud, not silent: a key this build does not know is a newer file, and quietly dropping an
          // edge would produce a program that runs but goes somewhere else.
          report(&problems, lineno, fmt.tprintf("node: unknown key '%s' - written by a newer build?", key))
          bad_key = true
        }
        if bad_key {
          break
        }
      }
      if bad_key {
        continue
      }
      append(&doc.steps, step)

    case "do", "if", "until", "group", "call", "arg":
      if len(doc.steps) == 0 {
        report(&problems, lineno, fmt.tprintf("'%s' before any node line", toks[0]))
        continue
      }
      step := &doc.steps[len(doc.steps) - 1]
      switch toks[0] {
      case "group":
        // Verbatim, not tokenised: the name is free text and may contain spaces and punctuation.
        step.group = strings.clone(strings.trim_space(line[len("group"):]))
      case "call":
        if len(toks) < 2 {
          report(&problems, lineno, "call: expected the name of the sub-chart to run")
          continue
        }
        if !bhv_name_ok(toks[1]) {
          report(&problems, lineno, fmt.tprintf("call: '%s' is not a usable name - %s", toks[1], BHV_NAME_RULE))
          continue
        }
        delete(step.call_name)
        step.call_name = strings.clone(toks[1])
      case "arg":
        if len(toks) < 2 {
          report(&problems, lineno, "arg: expected 'arg <parameter> <value...>'")
          continue
        }
        if step.call_arg_count >= SUBCHART_MAX_PARAMS {
          report(&problems, lineno, fmt.tprintf("arg: more than %d arguments on one call", SUBCHART_MAX_PARAMS))
          continue
        }
        // Rest-of-line after the parameter name, verbatim: a value is free text (a monster name has
        // spaces, a coord has a comma), and it is handed to the variable store as-is.
        rest := strings.trim_space(line[len("arg"):])
        cut := strings.index_any(rest, " \t")
        value := cut < 0 ? "" : strings.trim_space(rest[cut:])
        slot := &step.call_args[step.call_arg_count]
        delete(slot.name)
        delete(slot.value)
        slot.name = strings.clone(toks[1])
        slot.value = strings.clone(value)
        step.call_arg_count += 1
      case "do":
        act, aok, aerr := bhv_parse_action(toks[1:])
        if !aok {
          report(&problems, lineno, aerr)
          continue
        }
        step.action = act
      // Each `if` / `until` line APPENDS a row rather than replacing the condition, which is what makes
      // repeating the line the whole multi-condition syntax. One line still parses to exactly the
      // one-row condition an event used to be.
      case "if":
        ev, eok, eerr := bhv_parse_event(toks[1:])
        if !eok {
          report(&problems, lineno, eerr)
          continue
        }
        if step.condition.row_count >= SCRIPT_MAX_CONDITION_ROWS {
          report(&problems, lineno, fmt.tprintf("if: more than %d conditions on one node", SCRIPT_MAX_CONDITION_ROWS))
          delete(ev.strs[0])
          delete(ev.strs[1])
          continue
        }
        condition_row_ptr(&step.condition, step.condition.row_count)^ = ev
        step.condition.row_count += 1
      case "until":
        ev, eok, eerr := bhv_parse_event(toks[1:])
        if !eok {
          report(&problems, lineno, eerr)
          continue
        }
        if step.until.row_count >= SCRIPT_MAX_CONDITION_ROWS {
          report(&problems, lineno, fmt.tprintf("until: more than %d conditions on one node", SCRIPT_MAX_CONDITION_ROWS))
          delete(ev.strs[0])
          delete(ev.strs[1])
          continue
        }
        condition_row_ptr(&step.until, step.until.row_count)^ = ev
        step.until.row_count += 1
        step.has_until = true
      }

    case:
      report(&problems, lineno, fmt.tprintf("unknown line '%s'", toks[0]))
    }
  }

  // src is presentation only and is regenerated from the parsed form, never stored in the file - the
  // same rule `script show` follows, so a label can never disagree with the block it labels.
  for &s in doc.steps {
    s.src = step_label(s)
  }

  // An interrupt with no trigger would be armed on nothing and could never fire - it is not a chart
  // with a missing field, it is a file that means nothing. Rejected here rather than at arm time so
  // the complaint lands next to the file that caused it.
  if problems == 0 && doc.kind == .Interrupt && doc.trigger.kind == .None {
    fmt.eprintln("  kind is 'interrupt' but there is no 'trigger <event>' line - it could never fire")
    problems += 1
  }
  if problems == 0 && doc.kind == .Interrupt {
    bhv_upgrade_interrupt(&doc)
  }
  // Upgrade a file written before graph ops were the only thing a document may hold. Nothing the
  // editor saves from here on can contain a structured op, so this only ever fires on an old file -
  // and re-saving it writes the lowered form.
  if problems == 0 {
    script_lower_structured(&doc.steps, &doc.entry)
    // BETWEEN the two, because it produces a node the fall-through pass has to see: the body it
    // appends is what makes the watcher's subgraph identifiable as a region rather than as loose
    // program text the node above it would be given an edge into.
    script_materialize_watcher_bodies(&doc.steps)
    // AFTER lowering, never before: lowering rewrites structured blocks into graph ops using array
    // order, so naming successors first would freeze edges it is about to redraw.
    script_materialize_fallthrough(doc.steps[:])
  }
  if problems == 0 {
    if rok, dangling := script_resolve_ids(doc.steps[:]); !rok {
      fmt.eprintfln("  an edge points at node %d, which no node in this file declares", u32(dangling))
      problems += 1
    }
  }
  if doc.entry != 0 && problems == 0 {
    found := false
    for s in doc.steps {
      if s.id == doc.entry {
        found = true
        break
      }
    }
    if !found {
      fmt.eprintfln("  entry names node %d, which no node in this file declares", u32(doc.entry))
      problems += 1
    }
  }
  if problems > 0 {
    behaviour_doc_free(&doc)
    return {}, false
  }
  return doc, true
}

// --- lowering ------------------------------------------------------------------------------------
//
// Rewrite the STRUCTURED family (If / Else / End / Repeat / While) into graph ops, in place.
//
// WHY THIS EXISTS. The canvas could DRAW those five and could never create them. Their edge names a
// matching .End and the pair's meaning lives in array order, so letting you re-aim one would silently
// desync it - which is why the palette has no row for them. The result was a chart containing blocks
// with no way to make another: you could see an "End of block" node, select it, and find nothing you
// were allowed to do. Lowering deletes the whole category. Every document that reaches the canvas or a
// .bhv file is graph ops, and every graph op is in the palette.
//
// It runs on DOCUMENTS only - bhv_from_builtin and bhv_deserialize, the two places one is made - and
// never inside the VM. builder.odin goes on emitting structured blocks, because a scope exit closing a
// block is the right shape for authoring in Odin, and the walker goes on executing them, because that
// is what lets the two producers share one runtime. This is the one-way door between the two.
//
// The mapping, with E = the head's matching .End:
//
//   if C      -> branch C ? first-body-node : (else-body-node, or past E)
//   else      -> goto past E                  (the true arm's skip over the false arm)
//   while C   -> branch C ? first-body-node : past E
//   repeat N  -> loop N: each pass -> first-body-node, when done -> past E
//   end(loop) -> goto head                    (it already names the head; only the op changes)
//   end(if)   -> REMOVED. It only ever meant "fall through", which the node above it already does.
//
// Nesting is read off ARRAY ORDER with a stack rather than off goto_id, because array order IS what a
// structured block means - and the pass has to be correct on a hand-edited file whose goto_id may not
// be.
// Give every fall-through a name, once, where a document is MADE - the same one-way door
// script_lower_structured goes through, and for the same reason: what the canvas and the .bhv format
// see should be one thing, not two things that happen to run the same.
//
// After this, an `.Action` or `.Wait_For` with no goto_id means THE PROGRAM ENDS HERE, and nothing
// depends on array order any more. What that buys, all of it consequences of one value having meant two
// things (see script_op_falls_through):
//
//   - two nodes can both be the end of a chart. They could not before: "ends here" and "falls through"
//     were the same stored value, so only the LAST node in the array could end.
//   - a wire can be cut and stay cut.
//   - adding a node cannot rewire an existing one. Appending used to hand the last node an exit it
//     never had, pointing at whatever you had just created somewhere else on the canvas.
//   - every wire on the canvas is real, so what you see is what runs.
//
// WHERE IT DELIBERATELY STOPS. A watcher's body lives in the same array as the chart, and the boundaries
// between the two are not fall-throughs even though they look like adjacency: main running off its end
// is the program ending, and a body running off its end is a return. script_partition_watcher_bodies
// moves the bodies out at run time and those two rules take over, so naming a successor across such a
// boundary would freeze an answer that is about to stop being true. Every skip below is one of those,
// and a skip only ever leaves things as they already were.
// Give a bodyless `on <event> -> <action>` a real body node, and wire the watcher to it.
//
// THE LEGACY WATCHER SHAPE. An `.On` used to be able to carry a single action itself, with no edge -
// which is what builder.on() emits and what every interrupt file written before bodies existed holds.
// The header of this file says there is one concept now ("a WATCHER is an `.On` node plus the body its
// edge points at"), and everything downstream believes it: `script_attach_doc_watchers`,
// `armed_watcher_reload` and `cli_interrupt` all skip an `.On` whose goto_id is 0. Only
// script_build_irq_regions still knew how to synthesize the missing half, at RUN time.
//
// So the shape was runnable and un-armable at the same time - `interrupt on <name>` refused it with
// "it has no watchers", which reads as a broken file rather than as an old one. It is the same
// one-way door as script_lower_structured: upgrade it on the way in, and everything past this point
// sees exactly one representation.
//
// The action's owned strings MOVE to the body rather than being cloned, so nothing is freed twice.
script_materialize_watcher_bodies :: proc(steps: ^[dynamic]Script_Step) -> (changed: bool) {
  next_id := Node_Id(0)
  for s in steps {
    next_id = max(next_id, s.id)
  }
  // Bounded to the ORIGINAL length: the bodies this appends are `.Action`s and can never need one.
  n := len(steps)
  for i in 0 ..< n {
    if steps[i].op != .On || steps[i].goto_id != 0 || steps[i].action.kind == .None {
      continue
    }
    next_id += 1
    body := Script_Step {
      id     = next_id,
      op     = .Action,
      action = steps[i].action, // ownership MOVES - see below
      // Under the watcher rather than on top of it, so a file opened in the editor for the first time
      // does not stack the two nodes at one point and look like a single node.
      ui_pos = {steps[i].ui_pos.x, steps[i].ui_pos.y + 120},
      group  = clone_if(steps[i].group),
    }
    body.src = step_label(body)
    steps[i].action = {} // the .On must not keep the strings it just handed over
    steps[i].goto_id = body.id
    delete(steps[i].src)
    steps[i].src = step_label(steps[i])
    // Nothing above is held across this: append may realloc, so every touch goes through steps[i].
    append(steps, body)
    changed = true
  }
  return
}

script_materialize_fallthrough :: proc(steps: []Script_Step) -> (changed: bool) {
  n := len(steps)
  if n < 2 {
    return false
  }
  // Which nodes belong to a watcher body, asked the way the WALKER saw the graph a moment ago - this
  // runs before the very fall-throughs it is about to name exist as edges, so the mask has to assume
  // them (see script_step_successors).
  body := make([]bool, n, context.temp_allocator)
  script_watcher_body_mask(steps, body, assume_fallthrough = true)
  // A node an `.On` edge names is where a body STARTS. Control only ever arrives there by the trigger
  // firing, never by walking in from whatever happens to sit above it.
  body_start := make(map[Node_Id]bool, 8, context.temp_allocator)
  for s in steps {
    if s.op == .On && s.goto_id != 0 {
      body_start[s.goto_id] = true
    }
  }
  for i in 0 ..< n - 1 {
    s := &steps[i]
    if s.goto_id != 0 || script_op_falls_through(s.op) {
      continue // already names one, or is an op whose fall-through is structural and stays
    }
    next := steps[i + 1]
    if next.op == .On || body_start[next.id] || body[i] != body[i + 1] {
      continue // a region boundary - see the note above
    }
    s.goto_id = next.id
    changed = true
  }
  return changed
}

script_lower_structured :: proc(steps: ^[dynamic]Script_Step, entry: ^Node_Id = nil) -> (changed: bool) {
  n := len(steps)
  if n == 0 {
    return false
  }

  index_of := make(map[Node_Id]int, n, context.temp_allocator)
  defer delete(index_of)
  for s, i in steps {
    if s.id != 0 {
      index_of[s.id] = i
    }
  }

  // Which nodes disappear, and where each block's parts are. Both computed BEFORE any rewriting, so
  // the scan never reads an op this pass has already changed.
  drop := make([]bool, n, context.temp_allocator)
  match_end := make([]int, n, context.temp_allocator)
  else_of := make([]int, n, context.temp_allocator)
  for i in 0 ..< n {
    match_end[i] = -1
    else_of[i] = -1
  }
  stack := make([dynamic]int, 0, n, context.temp_allocator)
  for s, i in steps {
    #partial switch s.op {
    case .If, .While, .Repeat:
      append(&stack, i)
    case .Else:
      if len(stack) > 0 {
        else_of[stack[len(stack) - 1]] = i
      }
    case .End:
      if s.close == .If || s.close == .Else {
        drop[i] = true
      }
      if len(stack) > 0 {
        h := pop(&stack)
        match_end[h] = i
        if else_of[h] >= 0 {
          match_end[else_of[h]] = i
        }
      }
    }
  }

  // The id control continues at, searching forward from k over the nodes that survive. 0 means "runs
  // off the end", which script_resolve_ids turns into -1 = the program stops here.
  survivor :: proc(steps: ^[dynamic]Script_Step, drop: []bool, k: int) -> Node_Id {
    for j := k; j < len(steps); j += 1 {
      if !drop[j] {
        return steps[j].id
      }
    }
    return 0
  }

  for i in 0 ..< n {
    s := &steps[i]
    e := match_end[i]
    #partial switch s.op {
    case .If:
      s.op = .Branch
      s.goto_id = survivor(steps, drop, i + 1)
      s.else_id = else_of[i] >= 0 ? survivor(steps, drop, else_of[i] + 1) : (e >= 0 ? survivor(steps, drop, e + 1) : 0)
      changed = true
    case .Else:
      s.op = .Goto
      s.goto_id = e >= 0 ? survivor(steps, drop, e + 1) : 0
      s.else_id = 0
      changed = true
    case .While:
      s.op = .Branch
      s.goto_id = survivor(steps, drop, i + 1)
      s.else_id = e >= 0 ? survivor(steps, drop, e + 1) : 0
      changed = true
    case .Repeat:
      s.op = .Loop
      s.goto_id = survivor(steps, drop, i + 1)
      s.else_id = e >= 0 ? survivor(steps, drop, e + 1) : 0
      changed = true
    case .End:
      if drop[i] {
        continue
      }
      s.op = .Goto // close == Repeat/While: goto_id already names the head
      s.close = .Action
      changed = true
    }
  }
  if !changed {
    return false
  }

  // Anything still NAMING a dropped node - a hand-written file, or the entry - follows it to wherever
  // control would have gone next.
  forward :: proc(steps: ^[dynamic]Script_Step, drop: []bool, index_of: map[Node_Id]int, id: Node_Id) -> Node_Id {
    if id == 0 {
      return 0
    }
    k, ok := index_of[id]
    if !ok || !drop[k] {
      return id
    }
    return survivor(steps, drop, k + 1)
  }
  for &s in steps {
    s.goto_id = forward(steps, drop, index_of, s.goto_id)
    s.else_id = forward(steps, drop, index_of, s.else_id)
  }
  if entry != nil {
    entry^ = forward(steps, drop, index_of, entry^)
  }

  w := 0
  for i in 0 ..< n {
    if drop[i] {
      script_step_free(&steps[i])
      continue
    }
    if w != i {
      steps[w] = steps[i]
    }
    w += 1
  }
  resize(steps, w)

  // Every rewritten op describes itself differently now, and src is what `script step` and the status
  // line read. Relabel the lot rather than tracking which ones moved.
  for &s in steps {
    delete(s.src)
    s.src = step_label(s)
  }
  return true
}

// Turn an old `kind interrupt` file into an ordinary chart holding one WATCHER.
//
// The old shape was: a whole program, plus a trigger header, plus "armed, not run". The new shape is
// an `.On` node whose edge points at that same program. Nothing about what runs changes - the body is
// the identical step list - but there is now only one kind of document and one kind of watcher, which
// is the point: a chart could always hold `on` nodes too, and having those be a WEAKER thing (one
// action, no body) than a file-with-a-trigger was the confusion.
//
// The watcher goes in at index 0 so it is the first thing in the file, and the entry stays pointing
// at it. A document whose entry is a watcher has no main program - script_begin lets it start and end
// immediately, and `script run` says so rather than pretending it did something. You ARM this, or you
// attach it with `uses`.
@(private = "file")
bhv_upgrade_interrupt :: proc(doc: ^Behaviour_Doc) {
  if len(doc.steps) == 0 {
    return
  }
  body := doc.entry
  if body == 0 {
    body = doc.steps[0].id
  }
  next_id := Node_Id(0)
  for s in doc.steps {
    next_id = max(next_id, s.id)
  }
  w := Script_Step {
    id      = next_id + 1,
    op      = .On,
    condition = condition_of_event(doc.trigger), // ownership moves to the step; the doc's copy is cleared below
    goto_id = body,
    ui_pos  = doc.steps[0].ui_pos - {0, 90},
  }
  w.src = step_label(w)
  inject_step_at(&doc.steps, 0, w)
  doc.entry = w.id
  doc.trigger = {}
  doc.kind = .Chart
}

// Insert at <at>, shifting the rest down. Only the upgrade needs this - every other producer appends.
@(private = "file")
inject_step_at :: proc(steps: ^[dynamic]Script_Step, index: int, step: Script_Step) {
  append(steps, Script_Step{})
  for shift := len(steps) - 1; shift > index; shift -= 1 {
    steps[shift] = steps[shift - 1]
  }
  steps[index] = step
}

// --- file operations -----------------------------------------------------------------------------

bhv_save :: proc(doc: ^Behaviour_Doc) -> bool {
  if !bhv_name_ok(doc.name) {
    fmt.eprintfln("behaviour: '%s' is not a usable name - %s.", doc.name, BHV_NAME_RULE)
    return false
  }
  dir := bhv_dir_path()
  os.make_directory(dir) // ignore "already exists"
  b := strings.builder_make(context.temp_allocator)
  bhv_serialize(doc, &b)
  path := bhv_file_path(doc.name)
  if err := os.write_entire_file(path, transmute([]byte)strings.to_string(b)); err != nil {
    fmt.eprintfln("behaviour save: write failed (%v): %s", err, path)
    return false
  }
  return true
}

bhv_load :: proc(name: string) -> (doc: Behaviour_Doc, ok: bool) {
  path := bhv_file_path(name)
  data, err := os.read_entire_file(path, context.temp_allocator)
  if err != nil {
    return {}, false
  }
  d, dok := bhv_deserialize(name, string(data))
  if !dok {
    fmt.eprintfln("behaviour '%s' was not loaded (see the problems above): %s", name, path)
    return {}, false
  }
  return d, true
}

bhv_exists :: proc(name: string) -> bool {
  return os.exists(bhv_file_path(name))
}

// What one saved behaviour DECLARES about itself, without parsing its program.
//
// The browser and the palette both need this for every behaviour on disk, several times a second. A
// full bhv_open per file per scan already costs a parse of every node; adding the palette as a second
// caller of that would double it, so this reads the header and STOPS at the first `node` line - which
// bhv_serialize guarantees comes after every header line it writes.
//
// Built-ins are answered from the registry rather than built: bhv_from_builtin runs the whole builder,
// which is not something to do inside a UI scan, and a built-in is never a sub-chart anyway.
Subchart_Info :: struct {
  name:        string, // owned by the caller's allocator
  desc:        string, // owned
  is_subchart: bool,
  params:      [SUBCHART_MAX_PARAMS]Param_Spec, // name/title/help owned; choices owned
  param_count: int,
  // Every variable this document WRITES - the same question lint_variables_set asks of an open
  // document, answered for one that is not open. The linter needs it: a chart that calls a block and
  // then reads what the block computed is doing the only thing there is to do (a call has no return
  // value), and warning "nothing sets it" at that chart would be wrong.
  sets:        []string, // owned
}

subchart_info_free :: proc(info: ^Subchart_Info) {
  delete(info.name)
  delete(info.desc)
  for &p in info.params {
    delete(p.name)
    delete(p.title)
    delete(p.help)
    subchart_choices_free(&p.choices)
  }
  subchart_choices_free(&info.sets)
  info^ = {}
}

bhv_read_header :: proc(name: string) -> (info: Subchart_Info, ok: bool) {
  if !bhv_exists(name) {
    if def := behaviour_def(name); def != nil {
      return Subchart_Info{name = strings.clone(name), desc = clone_if(def.blurb)}, true
    }
    return {}, false
  }
  data, err := os.read_entire_file(bhv_file_path(name), context.temp_allocator)
  if err != nil {
    return {}, false
  }
  info.name = strings.clone(name)
  // The whole file is already in memory, so walking past the header costs a token split per `do` line
  // and nothing else. That is what buys `sets` - the header alone could not answer it.
  sets := make([dynamic]string, 0, 8, context.temp_allocator)
  header_over := false
  for raw in strings.split_lines(strings.trim_prefix(string(data), BHV_BOM), context.temp_allocator) {
    line := strings.trim_space(raw)
    if line == "" || line[0] == '#' {
      continue
    }
    toks := bhv_tokens(line)
    if len(toks) == 0 {
      continue
    }
    if header_over {
      // Only the three blocks that create a variable, matched by the spelling script_write_action
      // produces. Kept in step with lint_variables_set by hand; the selftest checks the pair agree.
      if toks[0] == "do" && len(toks) >= 3 {
        switch toks[1] {
        case "var", "add", "read_value":
          if n := script_var_name_of(toks[2]); n != "" && !slice.contains(sets[:], n) {
            append(&sets, n)
          }
        }
      }
      continue
    }
    switch toks[0] {
    case "node":
      header_over = true // everything below is program; keep going for `sets`
    case "subchart":
      info.is_subchart = true
    case "desc":
      delete(info.desc)
      info.desc = strings.clone(strings.trim_space(line[len("desc"):]))
    case "param":
      // Silently skipped when malformed. This is the FAST path, not the judge - bhv_deserialize
      // reports the problem properly the moment anything opens the document for real.
      if len(toks) < 5 || info.param_count >= SUBCHART_MAX_PARAMS || !bhv_param_name_ok(toks[1]) {
        continue
      }
      kind, kok := bhv_param_kind_from_name(toks[2])
      if !kok || !subchart_param_kind_ok(kind) {
        continue
      }
      spec := Param_Spec {
        name  = strings.clone(toks[1]),
        kind  = kind,
        title = strings.clone(toks[3]),
        help  = strings.clone(toks[4]),
      }
      for kv in toks[5:] {
        if kv == "optional" {
          spec.optional = true
        } else if strings.has_prefix(kv, "choices=") {
          spec.choices = subchart_choices_clone(strings.split(kv[len("choices="):], ",", context.temp_allocator))
        }
      }
      info.params[info.param_count] = spec
      info.param_count += 1
    }
  }
  info.sets = subchart_choices_clone(sets[:])
  return info, true
}

// The declared parameters of an info row, as a slice.
subchart_info_params :: proc(info: ^Subchart_Info) -> []Param_Spec {
  if info == nil {
    return nil
  }
  return info.params[:min(info.param_count, SUBCHART_MAX_PARAMS)]
}

// `approach_and_kill <who> <spot>` - what a call site reads as. The same shape script_sig gives a
// catalog block, so the palette's sub-chart rows line up with its block rows.
subchart_signature :: proc(name: string, params: []Param_Spec, allocator := context.temp_allocator) -> string {
  b := strings.builder_make(allocator)
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

// Every saved behaviour, sorted the way the directory hands them over. Names are TEMP-allocated.
bhv_list_names :: proc(allocator := context.temp_allocator) -> []string {
  out := make([dynamic]string, allocator)
  infos, err := os.read_all_directory_by_path(bhv_dir_path(), context.temp_allocator)
  if err != nil {
    return out[:]
  }
  for fi in infos {
    if strings.has_suffix(fi.name, BHV_EXT) {
      append(&out, strings.clone(strings.trim_suffix(fi.name, BHV_EXT), allocator))
    }
  }
  return out[:]
}

// Build one of the Odin behaviours into a document, so it can be inspected, run, or written to a file
// by exactly the same code path a saved one uses.
bhv_from_builtin :: proc(def: ^Behaviour_Def) -> (doc: Behaviour_Doc, ok: bool) {
  b := builder_begin(def.name, .Once)
  def.build(b)
  steps, mode, berrs := builder_end(b)
  if len(berrs) > 0 {
    fmt.eprintfln("behaviour '%s' has %d authoring problem(s):", def.name, len(berrs))
    for e in berrs {
      fmt.eprintfln("  %s", e)
    }
    script_steps_free(&steps)
    return {}, false
  }
  doc.name = strings.clone(def.name)
  doc.mode = mode
  doc.steps = steps
  doc.uses = make([dynamic]string)
  // The registry's blurb IS the document's description. One field, so the browser reads a built-in and
  // a saved chart the same way instead of special-casing which of the two carries a sentence.
  doc.desc = clone_if(def.blurb)
  if len(doc.steps) > 0 {
    doc.entry = doc.steps[0].id
  }
  // The builder's structured blocks stop at the document boundary - see script_lower_structured. This
  // is a no-op for the graph-authored charts (auto, hunt, sweep), which is most of them.
  script_lower_structured(&doc.steps, &doc.entry)
  // builder.on() emits the bodyless shape, so an Odin behaviour with a watcher arrives needing this
  // too - and it has to be the same upgrade, or an exported built-in would differ from the file it
  // was exported from.
  script_materialize_watcher_bodies(&doc.steps)
  // ... and its fall-throughs stop here too. `seq` writes steps in execution order and lets adjacency
  // carry the flow, which is the right way to WRITE one and the wrong way to EDIT one.
  script_materialize_fallthrough(doc.steps[:])
  return doc, true
}

// THE resolver every caller goes through: a saved file wins over a built-in of the same name. User data
// beats compiled-in data, so editing a copy of a built-in actually takes effect; `script list` marks the
// shadowing so it is never a mystery, and deleting the file restores the original.
bhv_open :: proc(name: string) -> (doc: Behaviour_Doc, ok: bool) {
  if bhv_exists(name) {
    return bhv_load(name)
  }
  if def := behaviour_def(name); def != nil {
    return bhv_from_builtin(def)
  }
  return {}, false
}
