package flyff

import "core:fmt"
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
// TWO EVALUATION SITES, ONE WATCHER. This is the part worth understanding before changing anything.
//
//   1. NOTHING RUNNING (idle, or `auto` farming). This file's armed_watcher_tick evaluates the triggers on the
//      behaviour tick and, on a rising edge, starts the interrupt's chart as an ordinary run.
//   2. A CHART IS RUNNING. script_begin HOISTS every enabled interrupt into that run's watcher array,
//      exactly like the chart's own `on` lines, with its body appended as a region past main_len. So
//      an interrupt can suspend the chart mid-step, walk somewhere, and hand control back where it
//      left off - the region machinery from P2, supplied with a longer body.
//
// Two sites means two Event_States, and an edge latch that lived in only one of them would either
// double-fire or miss a transition across the boundary. So the latch is HANDED OVER both ways:
// script_begin seeds the hoisted watcher's latch from the Armed_Watcher, and script_teardown copies it
// back. The pair therefore behaves as one continuous watcher that never stops watching.
//
// WHY AN INTERRUPT DOES NOT HOIST INTERRUPTS. When an interrupt's own chart is the thing running,
// script_begin skips the hoist. You do not want your escape interrupted by the same escape (it would
// re-fire on its own still-true trigger, forever), and `watcher_depth` only caps nesting WITHIN one run.
// ===========================================================================

// ONE WATCHER of an enabled document, runtime half. A document may hold several `on` nodes, so what is
// ENABLED is a document and what is WATCHED is a row - the list is flattened here rather than nested,
// because every consumer (the tick, the status line, the latch handover) works one watcher at a time.
//
// The persisted half - just the document name - lives in Flyff_Layout.interrupts so it survives a
// restart; this is rebuilt from it by armed_watcher_reload.
Armed_Watcher :: struct {
  doc:      string, // owned - the behaviour this watcher came out of
  label:    string, // owned - the watcher's own one-line description, for lists
  condition:     Script_Condition, // owned; the `.On` node's condition
  body:     Node_Id, // the node its edge points at - where armed_watcher_launch starts
  condition_state: Condition_State, // the edge latch - the reason this cannot be re-derived every tick
  fires:    int,
  ok:       bool, // the document loaded and this row is usable
  why:      string, // owned - why it is not, for `interrupt list` and `status`
}

armed_watcher_free_one :: proc(g: ^Armed_Watcher) {
  delete(g.doc)
  delete(g.label)
  script_condition_free(&g.condition)
  delete(g.why)
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

    // Count first, so a document with nothing to watch produces ONE explanatory row rather than
    // silently vanishing from `interrupt list` while still being enabled.
    watchers := 0
    if dok {
      for s in doc.steps {
        if s.op == .On && s.goto_id != 0 {
          watchers += 1
        }
      }
    }
    if !dok || watchers == 0 {
      g := Armed_Watcher {
        doc = strings.clone(name),
      }
      g.why = !dok \
      ? strings.clone("no behaviour by that name (or it would not parse)") \
      : strings.clone("it has no watchers - it needs an 'on' node wired to a body")
      session.armed_watchers[session.armed_watcher_count] = g
      session.armed_watcher_count += 1
      continue
    }

    for s in doc.steps {
      if s.op != .On || s.goto_id == 0 {
        continue
      }
      if session.armed_watcher_count >= FLYFF_MAX_ARMED_WATCHERS {
        break
      }
      g := Armed_Watcher {
        doc   = strings.clone(name),
        label = strings.clone(s.src),
        condition = script_condition_clone(s.condition),
        body  = s.goto_id,
        ok    = true,
      }
      script_arm_condition(&ctx, g.condition, &g.condition_state)
      // Carry the latch (and the fire tally) over from the row this replaces, when it is the same
      // watcher on the same condition. The rendered condition is the cheap structural comparison - two
      // triggers that print identically are the same trigger.
      for k in 0 ..< old_n {
        if old[k].doc != g.doc || !old[k].ok || old[k].body != g.body {
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

// The row a hoisted watcher came from, for the latch handover. Matched on the document AND the body it
// enters, because one document may contribute several rows and they must not share a latch.
armed_watcher_find :: proc(session: ^Session, doc: string, body: Node_Id) -> ^Armed_Watcher {
  for i in 0 ..< session.armed_watcher_count {
    if session.armed_watchers[i].doc == doc && session.armed_watchers[i].body == body {
      return &session.armed_watchers[i]
    }
  }
  return nil
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

// Evaluate the enabled interrupts and start one if its trigger just went true. Called every behaviour
// tick. Does nothing while a chart is running - the hoisted watchers own the evaluation then, and
// evaluating here as well is exactly the double-fire the latch handover exists to prevent.
armed_watcher_tick :: proc(ctx: ^Behaviour_Context) {
  session := ctx.session
  if session.script.active {
    return
  }
  for i in 0 ..< session.armed_watcher_count {
    g := &session.armed_watchers[i]
    if !g.ok {
      continue
    }
    // Through script_event_fired, not def.fired, so `trigger not <event>` negates like everywhere else.
    if !script_condition_holds(ctx, g.condition, &g.condition_state) {
      g.condition_state.latched = false // condition went away - re-arm for the next edge
      continue
    }
    if g.condition_state.latched {
      continue // still true from a previous fire; not a new edge
    }
    g.condition_state.latched = true
    g.fires += 1
    fmt.printf("\n[interrupt] %s fired (%s)\n", g.doc, g.label)
    fmt.print("memscan> ")
    armed_watcher_launch(session, g.doc, g.body)
    return // one per tick, first match wins - same rule as a chart's own watchers
  }
}

// Run ONE watcher's body standalone, starting at <body>. Separate from script_cmd_run because the
// refusal paths have to be quiet-ish and non-fatal: this is fired by a condition, not typed, so a
// document that cannot start must say why once and leave the session alone rather than look like a
// crash. <body> = 0 means "the first watcher this document declares", which is what `interrupt test`
// wants.
armed_watcher_launch :: proc(session: ^Session, name: string, body: Node_Id = 0) {
  doc, ok := bhv_open(name)
  if !ok {
    fmt.eprintfln("[interrupt] '%s' would not load - disable it with 'interrupt off %s'.", name, name)
    return
  }
  if problems := script_check_avail(session, doc.steps[:]); len(problems) > 0 {
    fmt.eprintfln("[interrupt] '%s' uses %d block(s) that aren't available - not started:", name, len(problems))
    for p in problems {
      fmt.eprintfln("  %s", p)
    }
    behaviour_doc_free(&doc)
    return
  }
  entry := body
  if entry == 0 {
    for s in doc.steps {
      if s.op == .On && s.goto_id != 0 {
        entry = s.goto_id
        break
      }
    }
  }
  if entry == 0 {
    fmt.eprintfln("[interrupt] '%s' has no watcher body to run.", name)
    behaviour_doc_free(&doc)
    return
  }
  // .Once, and the doc's own mode is ignored: an interrupt that looped would never give control back,
  // which is the one thing an interrupt must always do. It also does NOT borrow anything - see the
  // header note on why an escape must not be interruptible by itself.
  script_begin(session, name, doc.steps, .Once, entry, .Interrupt, nil, doc.ignore_collision)
  delete(doc.name)
  delete(doc.trigger.strs[0])
  delete(doc.trigger.strs[1])
  for u in doc.uses {
    delete(u)
  }
  delete(doc.uses)
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
    watchers := 0
    for s in doc.steps {
      if s.op == .On && s.goto_id != 0 {
        watchers += 1
      }
    }
    behaviour_doc_free(&doc)
    if watchers == 0 {
      fmt.eprintfln("interrupt on: '%s' has no watchers, so there is nothing to arm.", name)
      fmt.eprintln("  open it in the node editor and add an 'on' node wired to what it should do.")
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
    if session.script.active {
      fmt.eprintln("interrupt test: something is already running - 'script stop' first.")
      return
    }
    armed_watcher_launch(session, args[1])

  case:
    fmt.eprintfln("interrupt: unknown subcommand '%s'", args[0])
    fmt.eprintln("  list | on <name> | off <name> | reload | test <name>")
  }
}

// How many watchers a saved behaviour declares, without keeping the document. Used by the lists to
// tell "this is a chart" from "this is something you arm" - which is now a property of the CONTENT, not
// a header, because there is only one kind of document.
bhv_watcher_count :: proc(name: string) -> int {
  doc, ok := bhv_open(name)
  if !ok {
    return 0
  }
  defer behaviour_doc_free(&doc)
  n := 0
  for s in doc.steps {
    if s.op == .On && s.goto_id != 0 {
      n += 1
    }
  }
  return n
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
  // Everything that COULD be turned on, so the list is a menu and not just a receipt.
  first := true
  for name in bhv_list_names() {
    if armed_watcher_behaviour_enabled(session, name) {
      continue
    }
    n := bhv_watcher_count(name)
    if n == 0 {
      continue
    }
    if first {
      fmt.println("  --- off ---")
      first = false
    }
    fmt.printfln("  off  %-16s %d watcher(s)", name, n)
  }
  fmt.println("  'interrupt on <name>' arms one. Make one in the node editor: add an 'on' node and wire it.")
  fmt.println("  A chart can also borrow one for itself - `uses <name>` in its file, or the editor's options tab.")
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
