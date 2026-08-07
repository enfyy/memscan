package flyff

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "../engine"

// ===========================================================================
// GLOBAL INTERRUPTS - behaviour charts that arm themselves and are never tied to a running chart.
//
// A `.bhv` file with `kind interrupt` and a `trigger <event>` header is not something you run; it is
// something you ENABLE. Once enabled it is watched whatever the machine is doing - sitting idle,
// farming under the old `auto` brain, or running a chart - and when its trigger fires, its whole body
// runs. That is the point: an escape hatch you have to remember to paste into every chart is not an
// escape hatch. It is what finishes peace-out-mode (see BACKLOG.md).
//
// ONE EVALUATION SITE, ONE LIST. The globals are simply A SECOND RULE LIST ABOVE the running
// behaviour's - evaluated first, every tick, whatever is or is not running. globals_tick below is the
// only place that reads them, and it runs the winning row's steps with rule_steps_run, the same proc
// the behaviour's own rules go through.
//
// WHAT THIS DELETED, and it is the argument for the whole redesign. There used to be TWO evaluation
// sites for one logical watcher - this file's tick while nothing ran, and a hoist inside script_begin
// that spliced every enabled interrupt into the running chart's watcher array with its body appended as
// a region past main_len. Two sites meant two Event_States, so the edge latch had to be handed over in
// BOTH directions (script_begin seeded it, script_teardown copied it back) or the thing would
// double-fire across the boundary; it forced a "an interrupt must not hoist interrupts" special case;
// and it forced this file's tick to no-op whenever a chart was active, a hand-written mutual exclusion
// between two evaluators. All of it existed only because the watcher was not in the list. It is in the
// list now, so all of it is gone.
//
// A global that fires SUSPENDS the behaviour rather than racing it: behaviour_tick runs the globals
// first and returns while one has control, so the behaviour's in-flight step is left mid-flight and
// resumed exactly where it was. That is rule 4 of the model, applied across the two lists.
// ===========================================================================

// ONE GLOBAL RULE of an enabled document. A document may hold several rules, so what is ENABLED is a
// document and what is EVALUATED is a row - the list is flattened here rather than nested, because
// every consumer (the tick, the status line) works one row at a time.
//
// The persisted half - just the document name - lives in Flyff_Layout.interrupts so it survives a
// restart; this is rebuilt from it by armed_watcher_reload.
//
// IT IS A `Rule`, not a parallel type. That is the whole of this phase: an interrupt was always "a
// condition, and what to do when it holds", which is exactly a rule - and the only reason it needed its
// own struct was that it lived OUTSIDE whatever was running and therefore needed its own copy of the
// edge latch. One list, one latch, one evaluator.
Armed_Watcher :: struct {
  using rule: Rule, // owned - condition, latch, steps, label, fires
  doc:        string, // owned - the behaviour this row came out of
  ok:         bool, // the document loaded and this row is usable
  why:        string, // owned - why it is not, for `interrupt list` and `status`
}

armed_watcher_free_one :: proc(g: ^Armed_Watcher) {
  delete(g.doc)
  delete(g.why)
  rule_free(&g.rule)
  g^ = {}
}

armed_watcher_free_all :: proc(session: ^Session) {
  for i in 0 ..< session.armed_watcher_count {
    armed_watcher_free_one(&session.armed_watchers[i])
  }
  session.armed_watcher_count = 0
}

// --- the enabled set -----------------------------------------------------------------------------

armed_watcher_layout_index :: proc(L: ^Flyff_Layout, name: string) -> int {
  for i in 0 ..< int(L.interrupts_n) {
    if armed_watcher_layout_name(L, i) == name {
      return i
    }
  }
  return -1
}

armed_watcher_behaviour_enabled :: proc(session: ^Session, name: string) -> bool {
  return armed_watcher_layout_index(&session.layout, name) >= 0
}

// Rebuild the runtime list from the persisted names. Reads each file for its trigger and arms it.
//
// PRESERVES THE LATCH of an interrupt that is still enabled and whose trigger is unchanged. Without
// that, anything that reloads - toggling a second interrupt, `interrupt reload` - would re-arm a
// watcher whose condition is currently TRUE and fire it again immediately.
armed_watcher_reload :: proc(session: ^Session) {
  old := session.armed_watchers
  old_n := session.armed_watcher_count
  session.armed_watcher_count = 0

  L := &session.layout
  ctx := Behaviour_Context {
    session = session,
    now     = time.now()._nsec,
    board   = &session.bh_board,
  }
  for i in 0 ..< int(L.interrupts_n) {
    if session.armed_watcher_count >= FLYFF_MAX_ARMED_WATCHERS {
      break
    }
    name := armed_watcher_layout_name(L, i)
    doc, dok := bhv_open(name)
    defer if dok {
      behaviour_doc_free(&doc)
    }

    // Count first, so a document with nothing to arm produces ONE explanatory row rather than silently
    // vanishing from `interrupt list` while still being enabled.
    if !dok || len(doc.rules) == 0 {
      g := Armed_Watcher {
        doc = strings.clone(name),
      }
      g.why = !dok \
      ? strings.clone("no behaviour by that name (or it would not parse)") \
      : strings.clone("it has no rules - a global interrupt is a rule list, and this one is empty (a graph chart cannot be armed any more)")
      session.armed_watchers[session.armed_watcher_count] = g
      session.armed_watcher_count += 1
      continue
    }

    for r in doc.rules {
      if session.armed_watcher_count >= FLYFF_MAX_ARMED_WATCHERS {
        break
      }
      g := Armed_Watcher {
        rule = rule_clone(r),
        doc  = strings.clone(name),
        ok   = true,
      }
      script_arm_condition(&ctx, g.condition, &g.condition_state)
      // Carry the latch (and the fire tally) over from the row this replaces, when it is the same rule
      // on the same condition. NOT a leftover of the two-site design - this is here because toggling
      // ANY interrupt rebuilds the whole array, and re-arming a row whose condition is currently TRUE
      // would fire it again immediately. The rendered condition is the cheap structural comparison: two
      // triggers that print identically are the same trigger.
      for k in 0 ..< old_n {
        if old[k].doc != g.doc || !old[k].ok || old[k].id != g.id {
          continue
        }
        if armed_watcher_condition_text(old[k].condition) == armed_watcher_condition_text(g.condition) {
          g.condition_state = old[k].condition_state
          g.fires = old[k].fires
        }
        break
      }
      session.armed_watchers[session.armed_watcher_count] = g
      session.armed_watcher_count += 1
    }
  }
  // A row that was mid-flight cannot survive a rebuild - the steps it was walking have been freed.
  session.global_active = -1
  session.global_pc = 0
  session.global_entered = false
  for k in 0 ..< old_n {
    armed_watcher_free_one(&old[k])
  }
}

@(private = "file")
armed_watcher_condition_text :: proc(ev: Script_Condition) -> string {
  b := strings.builder_make(context.temp_allocator)
  script_write_condition(&b, ev)
  return strings.to_string(b)
}

// The trigger as one readable line, for the UI snapshot. Takes an allocator because the radar's
// snapshot runs under exec_mutex and needs the result to outlive this call.
armed_watcher_trigger_text :: proc(g: Armed_Watcher, allocator := context.temp_allocator) -> string {
  b := strings.builder_make(allocator)
  script_write_condition(&b, g.condition)
  return strings.to_string(b)
}

// Enable / disable by name. Returns whether anything changed.
armed_watcher_set_enabled :: proc(session: ^Session, name: string, on: bool) -> bool {
  L := &session.layout
  idx := armed_watcher_layout_index(L, name)
  if on {
    if idx >= 0 {
      return false
    }
    if int(L.interrupts_n) >= FLYFF_MAX_INTERRUPTS {
      fmt.eprintfln("interrupt: %d are already enabled, which is the cap - turn one off first.", FLYFF_MAX_INTERRUPTS)
      return false
    }
    n := min(len(name), FLYFF_IRQ_NAME_MAX - 1)
    slot := &L.interrupts[L.interrupts_n]
    slot^ = {}
    copy(slot[:], name[:n])
    L.interrupts_n += 1
  } else {
    if idx < 0 {
      return false
    }
    // Order is not meaningful (first-match-wins applies to the RUN's watcher array, which is rebuilt
    // per run), so a swap-with-last remove is fine - same as collider_ignore_toggle.
    L.interrupts[idx] = L.interrupts[L.interrupts_n - 1]
    L.interrupts_n -= 1
  }
  armed_watcher_reload(session)
  return true
}

// --- the idle evaluation pass ---------------------------------------------------------------------

// Does anything need the behaviour tick to keep running on our account? Read by behaviour_tick's
// gate: without this, a session with no chart and `sense off` would return before ever looking at an
// interrupt, and the peace-out escape would be armed only while something else happened to be on.
armed_watcher_any :: proc(session: ^Session) -> bool {
  for i in 0 ..< session.armed_watcher_count {
    if session.armed_watchers[i].ok {
      return true
    }
  }
  return false
}

// THE evaluator. Arbitrate the global list, then walk whatever won - the same two moves rules_tick
// makes over a behaviour's own rules, and through the same rule_steps_run.
//
// Returns true while a global has control, which is how behaviour_tick knows to suspend the behaviour.
// It is not a lock: the behaviour's in-flight step is simply not polled, so it resumes exactly where it
// was the moment the global finishes. Rule 4 of the model, applied across the two lists.
globals_tick :: proc(ctx: ^Behaviour_Context) -> bool {
  session := ctx.session

  // Already running one: walk it. It cannot be preempted by another global - an escape hatch that can
  // be cut off by a second escape hatch is not one, and the old design said the same thing with a
  // special case ("an interrupt does not hoist interrupts") instead of with the shape.
  if session.global_active >= 0 {
    if session.global_active >= session.armed_watcher_count {
      session.global_active = -1 // the array was rebuilt under us
      return false
    }
    g := &session.armed_watchers[session.global_active]
    switch rule_steps_run(ctx, g.steps[:], &session.global_pc, &session.global_entered, SCRIPT_MAX_STEPS_PER_TICK) {
    case .Running:
      return true
    case .Done, .Aborted:
      script_trace(session, g.id, .Note, "interrupt '%s' finished", g.doc)
      session.global_active = -1
      session.global_pc = 0
      session.global_entered = false
    }
    return false
  }

  // EVERY row is evaluated, even once a winner is known - a condition row updates its own baseline as a
  // side effect of being asked. Same reason script_condition_holds evaluates every row of a condition.
  winner := -1
  for i in 0 ..< session.armed_watcher_count {
    g := &session.armed_watchers[i]
    if !g.ok || !g.enabled {
      continue
    }
    // Through script_condition_holds, not def.fired, so `not <event>` negates like everywhere else.
    if !script_condition_holds(ctx, g.condition, &g.condition_state) {
      g.condition_state.latched = false // condition went away - re-arm for the next edge
      continue
    }
    // Globals are EDGE-triggered whatever the row says: an interrupt is about something HAPPENING, and
    // a level-triggered escape would re-enter itself every tick its condition stayed true.
    if g.condition_state.latched {
      continue
    }
    if winner < 0 {
      winner = i
    }
  }
  if winner < 0 {
    return false
  }
  g := &session.armed_watchers[winner]
  g.condition_state.latched = true
  g.fires += 1
  session.global_active = winner
  session.global_pc = 0
  session.global_entered = false
  fmt.printf("\n[interrupt] %s fired (%s)\n", g.doc, g.label)
  fmt.print("memscan> ")
  script_trace(session, g.id, .Note, "INTERRUPT '%s': %s", g.doc, g.label)
  return true // one per tick, first match wins
}

// Tear down whatever a global left in flight. Called on detach and when the list is rebuilt, for the
// same reason script_teardown exists: leaving a step for any reason has to undo what it started.
globals_stop :: proc(ctx: ^Behaviour_Context) {
  session := ctx.session
  if session.global_active < 0 || session.global_active >= session.armed_watcher_count {
    session.global_active = -1
    return
  }
  g := &session.armed_watchers[session.global_active]
  rule_steps_exit(ctx, g.steps[:], session.global_pc, &session.global_entered)
  session.global_active = -1
  session.global_pc = 0
}

// --- CLI ------------------------------------------------------------------------------------------

// interrupt                  -> list them
// interrupt on <name>        -> enable (persisted)
// interrupt off <name>       -> disable
// interrupt reload           -> re-read the files (after editing one outside the editor)
// interrupt test <name>      -> run its body now, ignoring the trigger
cli_interrupt :: proc(session: ^Session, args: []string) {
  if len(args) == 0 || args[0] == "list" {
    armed_watcher_print_list(session)
    return
  }
  switch args[0] {
  case "on", "enable":
    if len(args) < 2 {
      fmt.eprintln("usage: interrupt on <name>   ('interrupt list' shows what's available)")
      return
    }
    name := args[1]
    doc, ok := bhv_open(name)
    if !ok {
      fmt.eprintfln("interrupt on: no behaviour named '%s'. 'script list' shows what's available.", name)
      return
    }
    rules := len(doc.rules)
    behaviour_doc_free(&doc)
    if rules == 0 {
      fmt.eprintfln("interrupt on: '%s' has no rules, so there is nothing to arm.", name)
      fmt.eprintln("  a global interrupt is a rule list: give it a WHEN and what to DO about it.")
      return
    }
    if !armed_watcher_set_enabled(session, name, true) {
      fmt.printfln("interrupt: '%s' is already on.", name)
      return
    }
    flyff_save_cfg(session.layout, flyff_cfg_path())
    engine.ensure_hotkey_thread(&session.eng) // it is only evaluated on the watcher tick
    for i in 0 ..< session.armed_watcher_count {
      g := &session.armed_watchers[i]
      if g.doc == name && g.ok {
        fmt.printfln("interrupt: '%s' ARMED on %s.", name, armed_watcher_condition_text(g.condition))
      }
    }

  case "off", "disable":
    if len(args) < 2 {
      fmt.eprintln("usage: interrupt off <name>")
      return
    }
    if !armed_watcher_set_enabled(session, args[1], false) {
      fmt.eprintfln("interrupt off: '%s' is not on.", args[1])
      return
    }
    flyff_save_cfg(session.layout, flyff_cfg_path())
    fmt.printfln("interrupt: '%s' off.", args[1])

  case "reload":
    armed_watcher_reload(session)
    fmt.printfln("interrupt: re-read %d file(s).", session.armed_watcher_count)
    armed_watcher_print_list(session)

  case "test", "fire":
    if len(args) < 2 {
      fmt.eprintln("usage: interrupt test <name>   (runs its body now, ignoring the trigger)")
      return
    }
    // Force the first row of <name> to take control, ignoring its condition. It has to be ENABLED -
    // the armed list is the only place a global's steps live now, so there is nothing to run otherwise.
    idx := -1
    for i in 0 ..< session.armed_watcher_count {
      if session.armed_watchers[i].doc == args[1] && session.armed_watchers[i].ok {
        idx = i
        break
      }
    }
    if idx < 0 {
      fmt.eprintfln("interrupt test: '%s' is not armed - 'interrupt on %s' first.", args[1], args[1])
      return
    }
    session.global_active = idx
    session.global_pc = 0
    session.global_entered = false
    session.armed_watchers[idx].condition_state.latched = true // it has been serviced; do not re-fire on the edge
    fmt.printfln("interrupt: running '%s' now (%s).", args[1], session.armed_watchers[idx].label)

  case:
    fmt.eprintfln("interrupt: unknown subcommand '%s'", args[0])
    fmt.eprintln("  list | on <name> | off <name> | reload | test <name>")
  }
}

// How many rules a saved behaviour has, counted off the file rather than parsed.
//
// QUIET ON PURPOSE, which is the whole reason it does not just call bhv_open: this drives a MENU of
// everything you could arm, and bhv_deserialize reports a file it cannot read - so a directory holding
// a few pre-cutover graph charts would print a paragraph of refusals in the middle of the list. Those
// belong in `script lint`, which is the command that exists to say what is wrong with what.
bhv_rule_count :: proc(name: string) -> int {
  data, err := os.read_entire_file(bhv_file_path(name), context.temp_allocator)
  if err != nil {
    return 0
  }
  n := 0
  versioned := false
  for raw in strings.split_lines(strings.trim_prefix(string(data), BHV_BOM), context.temp_allocator) {
    line := strings.trim_space(raw)
    if strings.has_prefix(line, "version ") {
      versioned = true
    } else if strings.has_prefix(line, "rule ") {
      n += 1
    }
  }
  return versioned ? n : 0
}

armed_watcher_print_list :: proc(session: ^Session) {
  fmt.println("always watching (armed whatever else is running):")
  if session.armed_watcher_count == 0 {
    fmt.println("  (nothing armed)")
  }
  for i in 0 ..< session.armed_watcher_count {
    g := &session.armed_watchers[i]
    if g.ok {
      fmt.printfln("  ON   %-16s on %-28s fired %d time(s)", g.doc, armed_watcher_condition_text(g.condition), g.fires)
    } else {
      fmt.printfln("  BAD  %-16s %s", g.doc, g.why)
    }
  }
  // Everything that COULD be turned on, so the list is a menu and not just a receipt. That is now
  // every saved behaviour: arming one puts its rules above whatever is running, and there is no
  // separate kind of document that is allowed to be armed.
  first := true
  for name in bhv_list_names() {
    if armed_watcher_behaviour_enabled(session, name) {
      continue
    }
    n := bhv_rule_count(name)
    if n == 0 {
      continue
    }
    if first {
      fmt.println("  --- off ---")
      first = false
    }
    fmt.printfln("  off  %-16s %d rule(s)", name, n)
  }
  fmt.println("  'interrupt on <name>' arms one, and 'interrupt test <name>' runs its top rule right now.")
  fmt.println("  One edge-triggered rule is the usual shape: a whole farm loop armed here would never hand the tick back.")
}

// The `status full` detail section (see cli_status_behaviour).
cli_status_interrupts :: proc(session: ^Session) {
  fmt.printfln("  always watching: %d watcher(s)", session.armed_watcher_count)
  for i in 0 ..< session.armed_watcher_count {
    g := &session.armed_watchers[i]
    if g.ok {
      fmt.printfln("    %-16s on %-28s fired %d", g.doc, armed_watcher_condition_text(g.condition), g.fires)
    } else {
      fmt.printfln("    %-16s NOT USABLE - %s", g.doc, g.why)
    }
  }
  if session.armed_watcher_count > 0 && !session.bh_sense_on && !session.script.active {
    fmt.println("    ^ evaluated on the watcher tick; they keep it running on their own.")
  }
}
