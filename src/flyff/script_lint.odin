package flyff

import "core:fmt"
import "core:slice"
import "core:strings"

// ===========================================================================
// Behaviour lint - everything that is wrong with a behaviour BEFORE you run it.
//
// WHY THIS EXISTS. The editor could save a behaviour that loaded fine and then failed on its second
// step with the reason on a console nobody was looking at. Every mistake below is one the editor
// renders as a perfectly finished-looking row:
//
//   `var @dir D`             creates a variable literally called "@dir", which no @name can reference
//   `key_down @dir`          with nothing in the behaviour setting `dir`
//   `key_down Q7`            a key name that is not a key name
//   an `always` rule with rules under it, which can therefore never run
//
// IT GOT MUCH SHORTER WITH THE GRAPH. Most of what a chart linter did was answer "can control actually
// get here" - reachability, dangling edges, unwired arms, "does a wait come before this node on every
// path into it". A list has no edges, so the answer is always yes unless something above it is
// unconditional, and that is one check rather than four walks.
//
// ONE ANALYZER, THREE CONSUMERS. The editor's Problems tab, the save button, and `script lint <name>`
// all read this - the same reason the block catalog is one table. A check that only the CLI ran would be
// a check the person authoring in the editor never sees, which is the exact failure being fixed.
//
// NO SESSION, ON PURPOSE. This runs on the GUI thread, which may not touch Session unlocked, so every
// check here is answerable from the DOCUMENT alone. That is why the unset-variable check says "nothing
// in this behaviour sets it" rather than "it is not set": whether the REPL happens to have one right
// now is a different question, and a linter that changed its mind based on live state would be
// untrustworthy. Availability (`script_check_avail`, which does need a session) stays on the run gate.
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
  lint_rules(doc, &out)
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

// --- the rule list ---------------------------------------------------------------------------------

// Everything a rule list can get wrong.
@(private = "file")
lint_rules :: proc(doc: ^Behaviour_Doc, out: ^[dynamic]Chart_Problem) {
  set_names := lint_variables_set(doc)
  defer delete(set_names)

  for level in Chart_Problem_Level {
    if level == .Error {
      if len(doc.rules) == 0 {
        append(out, Chart_Problem{level = .Error, text = "the behaviour has no rules", hint = "add a rule - one WHEN and what to DO about it"})
      }
      for rule in doc.rules {
        if condition_row(rule.condition, 0).kind == .None {
          append(out, Chart_Problem{
            node  = rule.id,
            level = .Error,
            text  = fmt.aprintf("rule '%s' has no WHEN, so nothing can ever select it", rule.label),
            hint  = "give it a condition, or 'always' if it is the fallback",
          })
        }
        if len(rule.steps) == 0 {
          append(out, Chart_Problem{
            node  = rule.id,
            level = .Error,
            text  = fmt.aprintf("rule '%s' has nothing to DO", rule.label),
            hint  = "add a step, or delete the rule",
          })
        }
      }
    }
    if level == .Warning {
      // The list's only unreachability: an unconditional rule shadows everything under it. This is the
      // one mistake the shape still allows, so it is worth naming precisely.
      for rule, i in doc.rules {
        if !rule.enabled || i == len(doc.rules) - 1 {
          continue
        }
        // A `once` rule does NOT shadow, even on `always`. It fires on the rising edge and then latches
        // for as long as the condition stays true - and `always` never goes false - so it runs exactly
        // once and then stands aside forever. That is how a rule list spells "do this at the start",
        // which is what bh_test_vars needs, and the check reported it as dead code.
        if rule.fire_on_edge {
          continue
        }
        if condition_row_count(rule.condition) != 1 || condition_row(rule.condition, 0).kind != .Always {
          continue
        }
        if condition_row(rule.condition, 0).negate {
          continue
        }
        append(out, Chart_Problem{
          node  = doc.rules[i + 1].id,
          level = .Warning,
          text  = fmt.aprintf("rule '%s' above this one is always true, so nothing below it can ever run", rule.label),
          hint  = "an 'always' rule is the fallback - move it to the bottom of the list",
        })
        break
      }
    }
    // Not a fault - it is a deliberate declaration - but it changes what every targeting step in the
    // behaviour does, and nothing in the list itself shows it. A note is how this pane says "know this
    // about what you are reading".
    if level == .Note && doc.ignore_collision {
      append(out, Chart_Problem{
        level = .Note,
        text  = "this behaviour ignores collision - monsters are picked and approached without checking the path is clear",
        hint  = "written for a map whose floor props do not really block; untick it in the options tab for anywhere else",
      })
    }
    for rule in doc.rules {
      // A rule's WHEN is a Script_Condition and a step is a Script_Step, so both go through exactly
      // the argument checks the catalog already drives - see lint_arguments.
      lint_condition_arguments(rule.id, rule.condition, set_names, level, out)
      for s in rule.steps {
        lint_arguments(s, set_names, level, out)
      }
    }
  }
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
) {
  if def := action_def(s.action.kind); def != nil {
    lint_payload(s.id, def.name, def.params, s.action.strs, set_names, level, out)
  }
  lint_condition_arguments(s.id, s.condition, set_names, level, out)
  if s.has_until {
    lint_condition_arguments(s.id, s.until, set_names, level, out)
  }
}

// The same walk over a condition that belongs to no step - a rule's WHEN. Anchored on a Node_Id rather
// than a Script_Step, which is what lets one implementation serve both: a rule and a step share the id
// space, and everything downstream (the Problems tab, the trace strip) addresses by id anyway.
@(private = "file")
lint_condition_arguments :: proc(
  node: Node_Id,
  condition: Script_Condition,
  set_names: map[string]bool,
  level: Chart_Problem_Level,
  out: ^[dynamic]Chart_Problem,
) {
  for i in 0 ..< condition_row_count(condition) {
    r := condition_row(condition, i)
    if def := event_def(r.kind); def != nil {
      lint_payload(node, def.name, def.params, r.strs, set_names, level, out)
    }
  }
}

@(private = "file")
lint_payload :: proc(
  node: Node_Id,
  block: string,
  spec: []Param_Spec,
  strs: [2]string,
  set_names: map[string]bool,
  level: Chart_Problem_Level,
  out: ^[dynamic]Chart_Problem,
) {
  for p, i in spec {
    // A Coord's expression slot is a string argument in every way that matters here: it is where
    // `walk_to @spot` lives, so an @name in it has to be checked like any other. Its EMPTY state is
    // not a blank field though - it means "the numbers next to it are the value" - so it skips the
    // required-and-empty check below rather than reporting a chart that is perfectly filled in.
    if p.kind == .Coord {
      _, expression_slot := param_slots(spec, i)
      if level == .Warning && strs[expression_slot] != "" {
        lint_references(node, strs[expression_slot], set_names, out)
      }
      continue
    }
    if !param_kind_is_str(p.kind) {
      continue
    }
    raw := strs[param_slot(spec, i)]
    if level == .Error && !p.optional && strings.trim_space(raw) == "" {
      append(out, Chart_Problem{
        node  = node,
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
          node  = node,
          level = .Error,
          text  = fmt.aprintf("'%s' is the NAME field - '%s' would name a variable no @reference can reach", p.title, raw),
          hint  = fmt.aprintf("write it without the @: %s", strings.trim_left(strings.trim_space(raw), "@")),
        })
      }
      continue
    }
    if level == .Warning {
      lint_references(node, raw, set_names, out)
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
            node  = node,
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
          node  = node,
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
lint_references :: proc(node: Node_Id, raw: string, set_names: map[string]bool, out: ^[dynamic]Chart_Problem) {
  names := make([dynamic]string, 0, 4, context.temp_allocator)
  lint_scan_references(raw, &names)
  for name in names {
    if set_names[name] {
      continue
    }
    append(out, Chart_Problem{
      node  = node,
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
@(private = "file")
lint_variables_set :: proc(doc: ^Behaviour_Doc) -> map[string]bool {
  out := make(map[string]bool, 8, context.temp_allocator)
  for rule in doc.rules {
    for s in rule.steps {
      #partial switch s.action.kind {
      case .Var, .Add, .Read_Value:
        if name := script_var_name_of(s.action.strs[0]); name != "" {
          out[name] = true
        }
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
  script_print_problems(doc.name, script_doc_size_text(&doc), problems)
}

script_doc_size_text :: proc(doc: ^Behaviour_Doc) -> string {
  n := len(doc.rules)
  return fmt.tprintf("%d rule%s", n, n == 1 ? "" : "s")
}

// "Clean" means no errors and no warnings. Notes do NOT make a chart dirty - they are things that are
// true and legitimate, and counting them against a chart would mean `auto` never reads as clean.
@(private = "file")
script_print_problems :: proc(name: string, size: string, problems: []Chart_Problem) {
  errors := script_lint_count(problems, .Error)
  warnings := script_lint_count(problems, .Warning)
  notes := script_lint_count(problems, .Note)
  if errors + warnings == 0 {
    fmt.printfln("%s: clean (%s%s).", name, size, notes > 0 ? fmt.tprintf(", %d note(s)", notes) : "")
  } else {
    fmt.printfln("%s: %s, %d error(s), %d warning(s), %d note(s):", name, size, errors, warnings, notes)
  }
  for p in problems {
    where_at := p.node == 0 ? "whole" : fmt.tprintf("#%d", u32(p.node))
    fmt.printfln("  %-8s %-10s %s", CHART_PROBLEM_LEVEL_NAMES[p.level], where_at, p.text)
    if p.hint != "" {
      fmt.printfln("           %-10s -> %s", "", p.hint)
    }
  }
}

// Every behaviour the tool can run: every saved file, plus the hidden verification set. Prints one line
// per clean behaviour and the full report for anything that is not.
@(private = "file")
script_lint_all :: proc() {
  names := make([dynamic]string, context.temp_allocator)
  defer delete(names)
  for &d in TEST_BEHAVIOURS {
    append(&names, d.name)
  }
  for n in bhv_list_names() {
    already := false
    for existing in names {
      if existing == n {
        already = true // a saved file named like a verification fixture: bhv_open returns the file
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
      script_print_problems(doc.name, script_doc_size_text(&doc), problems)
    } else {
      notes := script_lint_count(problems, .Note)
      fmt.printfln("%s: clean (%s%s).", doc.name, script_doc_size_text(&doc), notes > 0 ? fmt.tprintf(", %d note(s)", notes) : "")
    }
    behaviour_doc_free(&doc)
  }
  fmt.printfln(
    "%d behaviour(s) linted: %d with something to fix, %d error(s), %d warning(s) in total.",
    len(names), dirty, total_errors, total_warnings,
  )
}
