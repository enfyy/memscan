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
// WHY THIS IS NOT A TEXT LANGUAGE. The old `.ms` parser was deleted on purpose: it forced a bespoke
// syntax on anyone who wanted to author behaviour, which is the opposite of the goal. This is the other
// thing - a SERIALIZATION for data an editor produced. Nobody has to hand-write it, though it stays
// plain and readable because a file you can open and understand is worth more than a compact one.
//
// SHAPE. Line-based and tolerant, exactly like flyff.cfg and fences/*.fence. A behaviour is a route
// plus an ordered list of rules; a rule is a header, a label, its condition rows, then its steps:
//
//     # memscan behaviour
//     desc clear the totem circuit
//     version 2
//     route NewWilds
//     rule 1 while
//       name Something is attacking me
//       when aggro
//     node 10 action
//       do kill '' q
//     rule 2 while
//       name Otherwise walk the route
//       when always
//     node 20 action
//       do patrol
//
// `version 2` says this is a rule list. There is no version 1 reader any more - the graph format it
// described (mode/entry/goto=/else=/canvas positions) went away with the graph.
//
// THE PAYLOAD LINES ARE WRITTEN BY THE RENDERER THE REST OF THE TOOL ALREADY USES.
// script_write_action / script_write_event (script.odin) produce them, so a saved block is spelled the
// same way `script show` spells it. The reader is their mirror: it looks the block up by name in the
// catalog and then parses arguments straight off that row's []Param_Spec. Adding a block to
// script_blocks.odin therefore teaches this file about it too, with no edit here.
//
// A STEP IS STILL WRITTEN AS `node`. That word is a leftover from the graph and it is kept on purpose:
// renaming it would invalidate every saved behaviour to gain one better noun.
// ===========================================================================

BHV_EXT :: ".bhv"

// Spelled as bytes, not as the character: Odin's lexer rejects a literal BOM in a source file.
BHV_BOM :: "\xef\xbb\xbf"

// An authored behaviour. This is what the editor edits and what a file holds; `rules` is the same
// []Rule the runtime walks, so handing one to rules_begin needs no conversion.
Behaviour_Doc :: struct {
  name:  string, // owned; the file's basename
  rules: [dynamic]Rule,
  // The named `.waypoints` set this behaviour patrols, or "". A route is the one ordered thing in the
  // domain and it already has a better editor than any list could be (you draw it on the map), which
  // is why it sits BESIDE the rules rather than being flattened into them - 123 of the old corpus's
  // 322 nodes were a route pretending to be a program.
  route: string, // owned
  // One line of description. Every behaviour may have one - the browser had nowhere to read a blurb
  // from for a saved file, so every tile but the built-in ones was a bare name.
  desc:  string, // owned
  // Run this behaviour with the proactive collision gate OFF: pick, approach and hold a monster
  // without ever asking whether the straight line to it is clear. DECLARED, not derived - there is
  // nothing in a rule list that implies it.
  //
  // It exists because the gate can be WRONG. compute_reach treats every collider box as a wall, and
  // some maps - dungeons especially - are carpeted with props that a character walks straight over.
  // There the gate excludes most of the room and the ladder starves. The narrow fix is `collignore`
  // (drop one collider KIND, radar key I), and it is the better tool when one prop is the culprit;
  // this is the blunt one for a map where the whole floor is the problem.
  //
  // A property of the BEHAVIOUR rather than a setting on the session, so it travels in the .bhv and is
  // scoped to the run - a dungeon behaviour carries it, the field one next to it does not, and neither
  // has to remember to put a global back. See reach_gate_active.
  ignore_collision: bool,
}

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
  out.route = clone_if(doc.route)
  out.rules = make([dynamic]Rule, 0, len(doc.rules))
  for r in doc.rules {
    append(&out.rules, rule_clone(r))
  }
  return
}

behaviour_doc_free :: proc(doc: ^Behaviour_Doc) {
  rules_free(&doc.rules)
  delete(doc.route)
  delete(doc.name)
  delete(doc.desc)
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
  .Wait_For = "wait_for",
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
  // A bare flag line, high in the file, so what the behaviour IS reads before what it does.
  if doc.ignore_collision {
    fmt.sbprintln(b, "ignore_collision")
  }
  // Rest-of-line - a description is a sentence, and quoting one would be the only place in this format
  // where prose needed escaping.
  if doc.desc != "" {
    fmt.sbprintfln(b, "desc %s", doc.desc)
  }
  // Written even though there is only one shape left. It is what tells a build with the OLD graph
  // reader that this file is not for it, and dropping it would make every file written from here
  // silently parse as an empty graph in any copy of the tool that predates the cutover.
  fmt.sbprintln(b, "version 2")
  if doc.route != "" {
    fmt.sbprintfln(b, "route %s", doc.route)
  }
  for rule in doc.rules {
    bhv_write_rule(b, rule)
  }
}

// One rule: its header line, its label, its condition rows, then its steps as ordinary `node` lines.
// The steps deliberately reuse the graph format's node line rather than inventing a step syntax - the
// payload vocabulary (`do`, `until`) is the same vocabulary, and one spelling is one reader.
bhv_write_rule :: proc(b: ^strings.Builder, rule: Rule) {
  fmt.sbprintf(b, "rule %d %s", u32(rule.id), rule.fire_on_edge ? "once" : "while")
  if rule.condition.match_any {
    fmt.sbprint(b, " match=any")
  }
  if !rule.enabled {
    fmt.sbprint(b, " off")
  }
  fmt.sbprintln(b)
  // Rest-of-line, like `group` and `desc`: a label is a sentence and quoting one would be the only
  // place in this format where prose needed escaping.
  if rule.label != "" {
    fmt.sbprintfln(b, "  name %s", rule.label)
  }
  // ONE LINE PER CONDITION ROW, the same shape `if` uses on a node - repeating a line the reader
  // already understands rather than teaching the tokenizer about infix `and` / `or`.
  for i in 0 ..< condition_row_count(rule.condition) {
    strings.write_string(b, "  when ")
    script_write_event(b, condition_row(rule.condition, i))
    fmt.sbprintln(b)
  }
  for step in rule.steps {
    bhv_write_step(b, step)
  }
}

// One step of a rule's DO, as a numbered line with its payload indented under it.
bhv_write_step :: proc(b: ^strings.Builder, step: Script_Step) {
  fmt.sbprintf(b, "node %d %s", u32(step.id), BHV_OP_NAMES[step.op])
  // Only written when it is not the default, so a one-row condition's node line carries no key at all.
  if step.op == .Wait_For && step.condition.match_any {
    fmt.sbprint(b, " match=any")
  }
  if step.has_until && step.until.match_any {
    fmt.sbprint(b, " umatch=any")
  }
  fmt.sbprintln(b)
  // Payload, in the same spelling `script show` uses - script_write_* is the single renderer.
  if step.op == .Action {
    strings.write_string(b, "  do ")
    script_write_action(b, step.action)
    fmt.sbprintln(b)
  }
  // ONE LINE PER CONDITION ROW, repeating a line the reader already understands rather than teaching
  // the tokenizer about infix `and` / `or`. A single-row condition is therefore byte-identical to
  // what a plain event used to write, so every file this writes is still readable by eye.
  if step.op == .Wait_For {
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
  doc.rules = make([dynamic]Rule)
  problems := 0
  // Which rule the `node` lines below belong to, or -1 while we are still in the header. A `rule` line
  // opens one and every node after it is one of its steps, in order.
  rule_index := -1
  saw_version := false

  report :: proc(problems: ^int, lineno: int, msg: string) {
    fmt.eprintfln("  line %d: %s", lineno, msg)
    problems^ += 1
  }

  // A .bhv is machine-written, but it is plain text on purpose and people WILL open it in an editor -
  // and a Windows editor is entitled to prepend a UTF-8 BOM. Without this, saving from Notepad turns
  // line 1 into "unknown line".
  body := strings.trim_prefix(content, BHV_BOM)

  // AN OLD GRAPH FILE, REFUSED IN ONE LINE. Every version-2 file the writer produces declares itself,
  // so a file that does not is from before the cutover - and running it through the reader below would
  // produce sixty complaints ("unknown line 'mode'", "'do' before any node line", once per node) that
  // all describe the same single fact. Reporting every problem is right for a file this build could
  // have written; it is noise for one it could not.
  for raw in strings.split_lines(body, context.temp_allocator) {
    line := strings.trim_space(raw)
    if line == "" || line[0] == '#' {
      continue
    }
    if toks := bhv_tokens(line); len(toks) > 0 && toks[0] == "version" {
      saw_version = true
      break
    }
  }
  if !saw_version {
    fmt.eprintln("  this is an old GRAPH behaviour (no 'version 2' line) and this build only runs rule lists.")
    fmt.eprintln("  charts were converted by hand at the cutover - see BACKLOG.md; there is no automatic upgrade.")
    behaviour_doc_free(&doc)
    return {}, false
  }

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
    case "ignore_collision":
      doc.ignore_collision = true

    // The shape declaration. A file with no `version` line is a GRAPH, written before rule lists
    // existed, and this build cannot run one - so it is refused by name rather than silently read as
    // an empty behaviour. The version number is not a compatibility knob to negotiate.
    case "version":
      if len(toks) < 2 {
        report(&problems, lineno, "version: expected a number")
        continue
      }
      v, vok := strconv.parse_int(toks[1])
      if !vok {
        report(&problems, lineno, fmt.tprintf("version: '%s' is not a number", toks[1]))
        continue
      }
      if v != 2 {
        report(&problems, lineno, fmt.tprintf("version %d: this build only reads version 2 (a rule list)", v))
      }

    case "route":
      if len(toks) < 2 {
        report(&problems, lineno, "route: expected the name of a waypoint set to patrol")
        continue
      }
      if !bhv_name_ok(toks[1]) {
        report(&problems, lineno, fmt.tprintf("route: '%s' is not a usable name - %s", toks[1], BHV_NAME_RULE))
        continue
      }
      delete(doc.route)
      doc.route = strings.clone(toks[1])

    // rule <id> [once|while] [match=any] [off]
    //   name  <rest of line>     the row's label
    //   when  <event>            one condition row, repeated for all-of / any-of
    // ...followed by its steps, as ordinary `node` lines.
    case "rule":
      if len(toks) < 2 {
        report(&problems, lineno, "rule: expected 'rule <id> [once|while] [match=any] [off]'")
        continue
      }
      id, id_ok := strconv.parse_u64(toks[1])
      if !id_ok || id == 0 {
        report(&problems, lineno, fmt.tprintf("rule: '%s' is not an id (ids start at 1)", toks[1]))
        continue
      }
      rule := Rule {
        id      = Node_Id(id),
        steps   = make([dynamic]Script_Step),
        enabled = true,
      }
      bad_rule := false
      for t in toks[2:] {
        switch t {
        // The two firing modes, spelled the way the editor shows them: "once, when it starts" fires on
        // the rising edge and runs to completion; "while it's true" is stopped the moment it is not.
        case "once":
          rule.fire_on_edge = true
        case "while":
          rule.fire_on_edge = false
        case "off":
          rule.enabled = false
        case "match=any":
          rule.condition.match_any = true
        case "match=all":
        case:
          report(&problems, lineno, fmt.tprintf("rule: unknown token '%s' - written by a newer build?", t))
          bad_rule = true
        }
        if bad_rule {
          break
        }
      }
      if bad_rule {
        rule_free(&rule)
        continue
      }
      append(&doc.rules, rule)
      rule_index = len(doc.rules) - 1

    case "name", "when":
      if rule_index < 0 {
        report(&problems, lineno, fmt.tprintf("'%s' before any rule line", toks[0]))
        continue
      }
      rule := &doc.rules[rule_index]
      if toks[0] == "name" {
        // Verbatim like `group` and `desc` - a label is a sentence, not a token list.
        delete(rule.label)
        rule.label = strings.clone(strings.trim_space(line[len("name"):]))
        continue
      }
      ev, eok, eerr := bhv_parse_event(toks[1:])
      if !eok {
        report(&problems, lineno, eerr)
        continue
      }
      if rule.condition.row_count >= SCRIPT_MAX_CONDITION_ROWS {
        report(&problems, lineno, fmt.tprintf("when: more than %d conditions on one rule", SCRIPT_MAX_CONDITION_ROWS))
        delete(ev.strs[0])
        delete(ev.strs[1])
        continue
      }
      condition_row_ptr(&rule.condition, rule.condition.row_count)^ = ev
      rule.condition.row_count += 1

    case "desc":
      // Verbatim - it is a sentence, not a token list.
      doc.desc = strings.clone(strings.trim_space(line[len("desc"):]))

    case "node":
      if len(toks) < 3 {
        report(&problems, lineno, "node: expected 'node <id> <op> [key=value ...]'")
        continue
      }
      if rule_index < 0 {
        report(&problems, lineno, "node: a step has to belong to a rule - put a 'rule' line above it")
        continue
      }
      id, id_ok := strconv.parse_u64(toks[1])
      op, op_ok := bhv_op_from_name(toks[2])
      if !id_ok || id == 0 {
        report(&problems, lineno, fmt.tprintf("node: '%s' is not a node id (ids start at 1)", toks[1]))
        continue
      }
      if !op_ok {
        report(&problems, lineno, fmt.tprintf("node: unknown op '%s' - a rule's steps are 'action' or 'wait_for'", toks[2]))
        continue
      }
      step := Script_Step {
        id = Node_Id(id),
        op = op,
      }
      bad_key := false
      for kv in toks[3:] {
        eq := strings.index_byte(kv, '=')
        if eq < 0 {
          report(&problems, lineno, fmt.tprintf("node: '%s' is not key=value", kv))
          bad_key = true
          break
        }
        key, val := kv[:eq], kv[eq + 1:]
        switch key {
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
          // Loud, not silent: a key this build does not know means the file was written by a newer
          // one, and quietly dropping it would produce a behaviour that runs but does something else.
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
      append(&doc.rules[rule_index].steps, step)

    case "do", "if", "until":
      if rule_index < 0 || len(doc.rules[rule_index].steps) == 0 {
        report(&problems, lineno, fmt.tprintf("'%s' before any node line", toks[0]))
        continue
      }
      steps := &doc.rules[rule_index].steps
      step := &steps[len(steps) - 1]
      switch toks[0] {
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
  for &rule in doc.rules {
    for &s in rule.steps {
      s.src = step_label(s)
    }
  }
  if problems == 0 {
    if why := rules_document_why_not(&doc); why != "" {
      fmt.eprintfln("  %s", why)
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
  if def.build == nil {
    fmt.eprintfln("behaviour '%s' declares no rules to build", def.name)
    return {}, false
  }
  b := rules_builder_begin()
  def.build(b)
  doc.name = strings.clone(def.name)
  // The registry's blurb IS the document's description. One field, so the browser reads a built-in and
  // a saved behaviour the same way instead of special-casing which of the two carries a sentence.
  doc.desc = clone_if(def.blurb)
  doc.route = clone_if(def.route)
  doc.rules = rules_builder_end(b)
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
