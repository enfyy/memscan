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
//   1. NOTHING RUNNING (idle, or `auto` farming). This file's irq_tick evaluates the triggers on the
//      behaviour tick and, on a rising edge, starts the interrupt's chart as an ordinary run.
//   2. A CHART IS RUNNING. script_begin HOISTS every enabled interrupt into that run's watcher array,
//      exactly like the chart's own `on` lines, with its body appended as a region past main_len. So
//      an interrupt can suspend the chart mid-step, walk somewhere, and hand control back where it
//      left off - the region machinery from P2, supplied with a longer body.
//
// Two sites means two Event_States, and an edge latch that lived in only one of them would either
// double-fire or miss a transition across the boundary. So the latch is HANDED OVER both ways:
// script_begin seeds the hoisted watcher's latch from the Global_Irq, and script_teardown copies it
// back. The pair therefore behaves as one continuous watcher that never stops watching.
//
// WHY AN INTERRUPT DOES NOT HOIST INTERRUPTS. When an interrupt's own chart is the thing running,
// script_begin skips the hoist. You do not want your escape interrupted by the same escape (it would
// re-fire on its own still-true trigger, forever), and `irq_depth` only caps nesting WITHIN one run.
// ===========================================================================

// One enabled interrupt, runtime half. The persisted half - just the name - lives in
// Flyff_Layout.interrupts so it survives a restart; this is rebuilt from it by irq_reload.
Global_Irq :: struct {
  name:     string, // owned
  cond:     Script_Event, // owned; the file's `trigger` line
  ev_state: Event_State, // the edge latch - the reason this cannot be re-derived every tick
  fires:    int,
  ok:       bool, // the file loaded and is a usable interrupt
  why:      string, // owned - why it is not, for `interrupt list` and `status`
}

irq_free_one :: proc(g: ^Global_Irq) {
  delete(g.name)
  delete(g.cond.strs[0])
  delete(g.cond.strs[1])
  delete(g.why)
  g^ = {}
}

irq_free :: proc(session: ^Session) {
  for i in 0 ..< session.irq_n {
    irq_free_one(&session.irq[i])
  }
  session.irq_n = 0
}

// --- the enabled set -----------------------------------------------------------------------------

irq_layout_index :: proc(L: ^Flyff_Layout, name: string) -> int {
  for i in 0 ..< int(L.interrupts_n) {
    if irq_layout_name(L, i) == name {
      return i
    }
  }
  return -1
}

irq_is_enabled :: proc(session: ^Session, name: string) -> bool {
  return irq_layout_index(&session.layout, name) >= 0
}

// Rebuild the runtime list from the persisted names. Reads each file for its trigger and arms it.
//
// PRESERVES THE LATCH of an interrupt that is still enabled and whose trigger is unchanged. Without
// that, anything that reloads - toggling a second interrupt, `interrupt reload` - would re-arm a
// watcher whose condition is currently TRUE and fire it again immediately.
irq_reload :: proc(session: ^Session) {
  old := session.irq
  old_n := session.irq_n
  session.irq_n = 0

  L := &session.layout
  ctx := Behaviour_Context {
    session = session,
    now     = time.now()._nsec,
    board   = &session.bh_board,
  }
  for i in 0 ..< int(L.interrupts_n) {
    if session.irq_n >= FLYFF_MAX_INTERRUPTS {
      break
    }
    name := irq_layout_name(L, i)
    g := Global_Irq {
      name = strings.clone(name),
    }
    doc, dok := bhv_open(name)
    switch {
    case !dok:
      g.why = strings.clone("no behaviour by that name (or it would not parse)")
    case doc.kind != .Interrupt:
      g.why = strings.clone("that behaviour is a chart, not an interrupt - it has no trigger")
    case len(doc.steps) == 0:
      g.why = strings.clone("it has no blocks, so there is nothing to run")
    case:
      g.ok = true
      g.cond = script_event_clone(doc.trigger)
    }
    if dok {
      behaviour_doc_free(&doc)
    }
    script_arm_event(&ctx, g.cond, &g.ev_state)
    // Carry the latch (and the fire tally) over from the entry this replaces, when it is the same
    // watcher on the same condition. script_render_event is the cheap structural comparison - two
    // triggers that print identically are the same trigger.
    for k in 0 ..< old_n {
      if old[k].name != g.name {
        continue
      }
      if old[k].ok && g.ok && irq_cond_text(old[k].cond) == irq_cond_text(g.cond) {
        g.ev_state = old[k].ev_state
        g.fires = old[k].fires
      }
      break
    }
    session.irq[session.irq_n] = g
    session.irq_n += 1
  }
  for k in 0 ..< old_n {
    irq_free_one(&old[k])
  }
}

@(private = "file")
irq_cond_text :: proc(ev: Script_Event) -> string {
  b := strings.builder_make(context.temp_allocator)
  script_write_event(&b, ev)
  return strings.to_string(b)
}

// The trigger as one readable line, for the UI snapshot. Takes an allocator because the radar's
// snapshot runs under exec_mutex and needs the result to outlive this call.
irq_trigger_text :: proc(g: Global_Irq, allocator := context.temp_allocator) -> string {
  b := strings.builder_make(allocator)
  script_write_event(&b, g.cond)
  return strings.to_string(b)
}

irq_find :: proc(session: ^Session, name: string) -> ^Global_Irq {
  for i in 0 ..< session.irq_n {
    if session.irq[i].name == name {
      return &session.irq[i]
    }
  }
  return nil
}

// Enable / disable by name. Returns whether anything changed.
irq_set :: proc(session: ^Session, name: string, on: bool) -> bool {
  L := &session.layout
  idx := irq_layout_index(L, name)
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
  irq_reload(session)
  return true
}

// --- the idle evaluation pass ---------------------------------------------------------------------

// Does anything need the behaviour tick to keep running on our account? Read by behaviour_tick's
// gate: without this, a session with no chart and `sense off` would return before ever looking at an
// interrupt, and the peace-out escape would be armed only while something else happened to be on.
irq_any_armed :: proc(session: ^Session) -> bool {
  for i in 0 ..< session.irq_n {
    if session.irq[i].ok {
      return true
    }
  }
  return false
}

// Evaluate the enabled interrupts and start one if its trigger just went true. Called every behaviour
// tick. Does nothing while a chart is running - the hoisted watchers own the evaluation then, and
// evaluating here as well is exactly the double-fire the latch handover exists to prevent.
irq_tick :: proc(ctx: ^Behaviour_Context) {
  session := ctx.session
  if session.script.active {
    return
  }
  for i in 0 ..< session.irq_n {
    g := &session.irq[i]
    if !g.ok {
      continue
    }
    // Through script_event_fired, not def.fired, so `trigger not <event>` negates like everywhere else.
    if !script_event_fired(ctx, g.cond, &g.ev_state) {
      g.ev_state.latched = false // condition went away - re-arm for the next edge
      continue
    }
    if g.ev_state.latched {
      continue // still true from a previous fire; not a new edge
    }
    g.ev_state.latched = true
    g.fires += 1
    fmt.printf("\n[interrupt] %s fired\n", g.name)
    fmt.print("memscan> ")
    irq_launch(session, g.name)
    return // one per tick, first match wins - same rule as a chart's own watchers
  }
}

// Run an interrupt's chart standalone. Separate from script_cmd_run because the refusal paths have to
// be quiet-ish and non-fatal: this is fired by a condition, not typed, so a chart that cannot start
// must say why once and leave the session alone rather than look like a crash.
irq_launch :: proc(session: ^Session, name: string) {
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
  entry := doc.entry
  // .Once, and the doc's own mode is ignored: an interrupt that looped would never give control back,
  // which is the one thing an interrupt must always do.
  script_begin(session, name, doc.steps, .Once, entry, .Interrupt)
  delete(doc.name)
  delete(doc.trigger.strs[0])
  delete(doc.trigger.strs[1])
}

// --- CLI ------------------------------------------------------------------------------------------

// interrupt                  -> list them
// interrupt on <name>        -> enable (persisted)
// interrupt off <name>       -> disable
// interrupt reload           -> re-read the files (after editing one outside the editor)
// interrupt test <name>      -> run its body now, ignoring the trigger
cli_interrupt :: proc(session: ^Session, args: []string) {
  if len(args) == 0 || args[0] == "list" {
    irq_print_list(session)
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
    kind := doc.kind
    behaviour_doc_free(&doc)
    if kind != .Interrupt {
      fmt.eprintfln("interrupt on: '%s' is a chart, not an interrupt - it has no trigger.", name)
      fmt.eprintln("  open it in the node editor and switch its kind, or 'script run' it instead.")
      return
    }
    if !irq_set(session, name, true) {
      fmt.printfln("interrupt: '%s' is already on.", name)
      return
    }
    flyff_save_cfg(session.layout, flyff_cfg_path())
    engine.ensure_hotkey_thread(&session.eng) // it is only evaluated on the watcher tick
    if g := irq_find(session, name); g != nil && g.ok {
      fmt.printfln("interrupt: '%s' ARMED on %s.", name, irq_cond_text(g.cond))
    }

  case "off", "disable":
    if len(args) < 2 {
      fmt.eprintln("usage: interrupt off <name>")
      return
    }
    if !irq_set(session, args[1], false) {
      fmt.eprintfln("interrupt off: '%s' is not on.", args[1])
      return
    }
    flyff_save_cfg(session.layout, flyff_cfg_path())
    fmt.printfln("interrupt: '%s' off.", args[1])

  case "reload":
    irq_reload(session)
    fmt.printfln("interrupt: re-read %d file(s).", session.irq_n)
    irq_print_list(session)

  case "test", "fire":
    if len(args) < 2 {
      fmt.eprintln("usage: interrupt test <name>   (runs its body now, ignoring the trigger)")
      return
    }
    if session.script.active {
      fmt.eprintln("interrupt test: something is already running - 'script stop' first.")
      return
    }
    irq_launch(session, args[1])

  case:
    fmt.eprintfln("interrupt: unknown subcommand '%s'", args[0])
    fmt.eprintln("  list | on <name> | off <name> | reload | test <name>")
  }
}

irq_print_list :: proc(session: ^Session) {
  fmt.println("global interrupts (armed whatever else is running):")
  if session.irq_n == 0 {
    fmt.println("  (none on)")
  }
  for i in 0 ..< session.irq_n {
    g := &session.irq[i]
    if g.ok {
      fmt.printfln("  ON   %-16s trigger %-28s fired %d time(s)", g.name, irq_cond_text(g.cond), g.fires)
    } else {
      fmt.printfln("  BAD  %-16s %s", g.name, g.why)
    }
  }
  // Everything that COULD be turned on, so the list is a menu and not just a receipt.
  first := true
  for name in bhv_list_names() {
    if irq_is_enabled(session, name) {
      continue
    }
    doc, ok := bhv_open(name)
    if !ok {
      continue
    }
    is_irq := doc.kind == .Interrupt
    trig := is_irq ? strings.clone(irq_cond_text(doc.trigger), context.temp_allocator) : ""
    behaviour_doc_free(&doc)
    if !is_irq {
      continue
    }
    if first {
      fmt.println("  --- off ---")
      first = false
    }
    fmt.printfln("  off  %-16s trigger %s", name, trig)
  }
  fmt.println("  'interrupt on <name>' arms one. Make one in the node editor: set kind to interrupt.")
}

// The `status full` detail section (see cli_status_behaviour).
cli_status_interrupts :: proc(session: ^Session) {
  fmt.printfln("  global interrupts: %d on", session.irq_n)
  for i in 0 ..< session.irq_n {
    g := &session.irq[i]
    if g.ok {
      fmt.printfln("    %-16s on %-28s fired %d", g.name, irq_cond_text(g.cond), g.fires)
    } else {
      fmt.printfln("    %-16s NOT USABLE - %s", g.name, g.why)
    }
  }
  if session.irq_n > 0 && !session.bh_sense_on && !session.script.active {
    fmt.println("    ^ evaluated on the watcher tick; they keep it running on their own.")
  }
}
