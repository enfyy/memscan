package flyff

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

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
//       if not focus_lost
//
// A `node` line carries identity, op, editor position and the structural edges; the indented lines that
// follow carry its payload (`do` = action, `if` = condition, `until` = the early-out on an action). The
// FILENAME is the behaviour's name - there is no name field to drift out of sync with it.
//
// THE PAYLOAD LINES ARE WRITTEN BY THE RENDERER THE REST OF THE TOOL ALREADY USES.
// script_write_action / script_write_event (script.odin) produce them, so a saved block is spelled the
// same way `script show` spells it. The reader is their mirror: it looks the block up by name in the
// catalog and then parses arguments straight off that row's []Param_Spec. Adding a block to
// script_blocks.odin therefore teaches this file about it too, with no edit here.
// ===========================================================================

BHV_EXT :: ".bhv"

// Spelled as bytes, not as the character: Odin's lexer rejects a literal BOM in a source file.
BHV_BOM :: "\xef\xbb\xbf"

// A chart is something you RUN; an interrupt is something that is armed and runs itself when its
// trigger fires. The distinction is one line in the file rather than a separate format, because the
// body is identical - an interrupt IS a chart, it just has a condition attached and no start button.
Behaviour_Kind :: enum {
  Chart,
  Interrupt,
}

// An authored behaviour. This is what an editor edits and what a file holds; `steps` is the same
// []Script_Step the VM walks, so handing one to script_begin needs no conversion.
Behaviour_Doc :: struct {
  name:    string, // owned; the file's basename
  kind:    Behaviour_Kind,
  trigger: Script_Event, // .Interrupt only - the condition that fires it. Owned strings.
  mode:    Script_Mode,
  entry:   Node_Id, // node the run starts at. 0 = "the first step", which is what a linear program wants.
  steps:   [dynamic]Script_Step,
}

behaviour_doc_free :: proc(doc: ^Behaviour_Doc) {
  script_steps_free(&doc.steps)
  delete(doc.trigger.strs[0])
  delete(doc.trigger.strs[1])
  delete(doc.name)
  doc^ = {}
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
  .Goto     = "goto",
  .Branch   = "branch",
  .Return   = "return",
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
  // Written only for an interrupt, so a plain chart's file is byte-identical to what earlier builds
  // produced and an older memscan can still read it. Absent `kind` means Chart.
  if doc.kind == .Interrupt {
    fmt.sbprintln(b, "kind interrupt")
    strings.write_string(b, "trigger ")
    script_write_event(b, doc.trigger)
    fmt.sbprintln(b)
  }
  fmt.sbprintfln(b, "mode %s", doc.mode == .Loop ? "loop" : "once")
  fmt.sbprintfln(b, "entry %d", u32(doc.entry))
  for step in doc.steps {
    fmt.sbprintf(b, "node %d %s %v %v", u32(step.id), BHV_OP_NAMES[step.op], step.ui_pos[0], step.ui_pos[1])
    if step.goto_id != 0 {
      fmt.sbprintf(b, " goto=%d", u32(step.goto_id))
    }
    if step.else_id != 0 {
      fmt.sbprintf(b, " else=%d", u32(step.else_id))
    }
    if step.op == .Repeat {
      fmt.sbprintf(b, " count=%d", step.count)
    }
    if step.op == .End {
      fmt.sbprintf(b, " close=%s", BHV_OP_NAMES[step.close])
    }
    fmt.sbprintln(b)
    // Payload, in the same spelling `script show` uses - script_write_* is the single renderer.
    if step.op == .Action || step.op == .On {
      strings.write_string(b, "  do ")
      script_write_action(b, step.action)
      fmt.sbprintln(b)
    }
    if step.op == .If || step.op == .While || step.op == .Wait_For || step.op == .On || step.op == .Branch {
      strings.write_string(b, "  if ")
      script_write_event(b, step.cond)
      fmt.sbprintln(b)
    }
    if step.has_until {
      strings.write_string(b, "  until ")
      script_write_event(b, step.until)
      fmt.sbprintln(b)
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
      case .Str, .Names:
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
    case .Str, .Names:
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

    case "do", "if", "until":
      if len(doc.steps) == 0 {
        report(&problems, lineno, fmt.tprintf("'%s' before any node line", toks[0]))
        continue
      }
      step := &doc.steps[len(doc.steps) - 1]
      switch toks[0] {
      case "do":
        act, aok, aerr := bhv_parse_action(toks[1:])
        if !aok {
          report(&problems, lineno, aerr)
          continue
        }
        step.action = act
      case "if":
        ev, eok, eerr := bhv_parse_event(toks[1:])
        if !eok {
          report(&problems, lineno, eerr)
          continue
        }
        step.cond = ev
      case "until":
        ev, eok, eerr := bhv_parse_event(toks[1:])
        if !eok {
          report(&problems, lineno, eerr)
          continue
        }
        step.until = ev
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
  if len(doc.steps) > 0 {
    doc.entry = doc.steps[0].id
  }
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
