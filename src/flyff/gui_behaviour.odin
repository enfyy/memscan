package flyff

import "core:fmt"
import "core:strings"
import rl "vendor:raylib"

import imgui "../../lib/odin-imgui"

// ===========================================================================
// The behaviour surface: a transport strip and a chart browser.
//
// Same contract as the rest of gui.odin - this runs in the exec_mutex-UNLOCKED draw phase, so it reads
// the Gui_Frame snapshot and issues every action as a CLI command through panel_enqueue. There is not a
// single behaviour operation here that you could not type.
//
// THE DIRECTORY IS READ FROM THE DRAW PHASE, and that is deliberate rather than sloppy: the behaviours
// folder is not session state - no lock protects it and the watcher never touches it - so snapshotting it
// under exec_mutex would buy nothing and would put a filesystem hit on the locked path, which is the one
// place that must stay short. It is throttled and refreshed on demand exactly like the attach dialog's
// process scan (gui_scan_processes).
// ===========================================================================

BROWSER_SCAN_INTERVAL :: 1.5 // seconds between directory scans while the browser is open

// Tile metrics. A tile is a FULL-WIDTH row now, so the only fixed numbers are the inside padding and the
// icon gutter - the height falls out of the two text lines, and the width out of the dialog. Every tile's
// contents are placed from these two constants by gui_bhv_tile_body and nowhere else, which is the point:
// the old per-call-site offsets are how "test" ended up hanging off the right edge on its own baseline.
TILE_PAD :: f32(12) // inside padding, all four sides
TILE_GUTTER :: f32(30) // the icon column, between the left padding and the text column
TILE_LINE_GAP :: f32(4) // between the title line and the line under it

// One row in the browser. Both kinds of behaviour appear here: the ones compiled into the exe and the
// ones saved as files, because "which behaviours exist" is a single question with a single answer.
Gui_Bhv_Row :: struct {
  name:      string, // owned
  blurb:     string, // owned ("" for a saved chart - a file carries no description)
  builtin:   bool, // defined in Odin: read-only, duplicate it to edit
  shadowed:  bool, // a saved file of the same name wins over this built-in
  test:      bool, // runs with nothing attached (the verification set)
  interrupt: bool, // nothing but watchers: armed, not run - it belongs in the Interrupts tab
  trigger:   string, // owned; the interrupt's trigger as one line ("" for a chart)
  subchart:  bool, // declared `subchart`: placed in another chart, not run - the Your blocks tab
  signature: string, // owned; `approach_and_kill <who> <spot>` for a block, "" otherwise
}

gui_free_bhv_rows :: proc(ps: ^Panel_State) {
  for r in ps.browser_rows {
    delete(r.name)
    delete(r.blurb)
    delete(r.trigger)
    delete(r.signature)
  }
  clear(&ps.browser_rows)
}

// Rebuild the row list: every Odin behaviour, then every saved file. Mirrors `script list` exactly,
// including the shadowing rule, so the browser and the console can never disagree about what exists.
gui_scan_behaviours :: proc(ps: ^Panel_State) {
  gui_free_bhv_rows(ps)
  saved := bhv_list_names()
  for d in BEHAVIOURS {
    shadowed := false
    for s in saved {
      if s == d.name {
        shadowed = true
        break
      }
    }
    append(
      &ps.browser_rows,
      Gui_Bhv_Row {
        name = strings.clone(d.name),
        blurb = strings.clone(d.blurb),
        builtin = true,
        shadowed = shadowed,
        test = d.test,
        trigger = strings.clone(""),
        signature = strings.clone(""),
      },
    )
  }
  for s in saved {
    row := Gui_Bhv_Row {
      name  = strings.clone(s),
      blurb = strings.clone(""),
    }
    // Read the CONTENT to find out which tab it belongs in - a document is "something you arm" when it
    // is nothing but watchers, and "something you place" when it says `subchart`. This is a file parse
    // per saved chart per scan, which is why the scan is throttled to BROWSER_SCAN_INTERVAL - the same
    // reasoning as the directory listing itself (see the note at the top of this file).
    if doc, ok := bhv_open(s); ok {
      delete(row.blurb)
      row.blurb = strings.clone(doc.desc)
      row.subchart = doc.is_subchart
      if row.subchart {
        row.signature = strings.clone(subchart_signature(s, subchart_params(&doc)))
      }
      // A block is placed, never armed - so the watchers-only test does not get to reclassify one.
      row.interrupt = !row.subchart && script_doc_is_watchers_only(&doc)
      if row.interrupt {
        n := 0
        b := strings.builder_make(context.temp_allocator)
        for st in doc.steps {
          if st.op != .On || st.goto_id == 0 {
            continue
          }
          if n > 0 {
            strings.write_string(&b, ", ")
          }
          script_write_event(&b, st.condition)
          n += 1
        }
        row.trigger = strings.clone(strings.to_string(b))
      }
      behaviour_doc_free(&doc)
    }
    if row.trigger == "" {
      row.trigger = strings.clone("")
    }
    if row.signature == "" {
      row.signature = strings.clone("")
    }
    append(&ps.browser_rows, row)
  }
  ps.browser_scan_at = rl.GetTime()
  ps.browser_rescan = false
}

// ===========================================================================
// Behaviour dock (bottom-centre, over the map)
// ===========================================================================

DOCK_LOAD_H :: f32(38) // the idle Load button: the only thing down there, so it gets to be big
DOCK_NAME_H :: f32(28) // once a chart is loaded the same button shrinks and yields the middle to the transport
DOCK_GAP :: f32(6)

// The behaviour surface's one permanent control, anchored bottom-centre rather than parked in the
// top-left toolbar: "which chart is loaded" and "pause it" are a single thought, so they are a single
// row, and that row belongs under the map next to nothing else.
//
// Idle it is one wide Load button. Running, the button shrinks to the chart's NAME and steps aside to
// the left of the transport - the media controls take the middle, which is where the eye goes for them.
// The row is centred by hand (measure everything, then indent) because ImGui has no "centre this row"
// and an auto-resized window only centres itself, not its contents.
gui_behaviour_dock :: proc(ps: ^Panel_State, f: ^Gui_Frame) {
  vp := imgui.GetMainViewport()
  imgui.SetNextWindowPos(
    {vp.Pos.x + vp.Size.x * 0.5, vp.Pos.y + vp.Size.y - px(TOOLBAR_PAD)},
    .Always,
    {0.5, 1}, // pivot: bottom-centre of the window onto the bottom-centre of the viewport
  )
  // The controls ARE the dock - no panel behind them, same as the recenter puck. A surface under a row
  // of pills reads as a box inside a box, and the map is the thing the box would be covering.
  imgui.PushStyleVarImVec2(.WindowPadding, {0, 0})
  imgui.PushStyleVar(.WindowBorderSize, 0)
  imgui.PushStyleColorImVec4(.WindowBg, {0, 0, 0, 0})
  defer imgui.PopStyleColor(1)
  defer imgui.PopStyleVar(2)
  defer imgui.End()
  if !imgui.Begin("##bhvdock", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoSavedSettings, .AlwaysAutoResize, .NoNavInputs, .NoDocking}) {
    return
  }

  if !f.script_active {
    if gui_text_button("dockload", "Load", DOCK_LOAD_H, 30, true, "Behaviour charts - pick one to run  ('script list')") {
      ps.browser_open = true
      ps.browser_rescan = true
    }
    return
  }

  // --- running: measure the whole row first, then place it
  name := fmt.ctprintf("%s", gui_ellipsize(f.script_name, 22))
  name_w := gui_text_button_w(name, 14)
  gap := px(DOCK_GAP)
  row_w := name_w + 4 * (gap + px(ICON_BTN))

  // The step readout, above the controls: position plus the block actually executing right now.
  line := f.script_line
  col := COL_ACCENT
  if f.script_in_watcher {
    // Worth calling out loudly: the step counter is frozen on the SUSPENDED step while a region runs,
    // so without this the dock looks stuck.
    line = fmt.tprintf("interrupt: %s", line)
    col = COL_WARN
  } else if f.script_paused {
    col = COL_TEXT_DIM
  }
  status := fmt.ctprintf("step %d/%d   %s", f.script_pc, f.script_len, line == "" ? "(starting)" : line)
  status_w := imgui.CalcTextSize(status).x

  // What is WATCHING, above the step line. An armed watcher used to be invisible until the instant it
  // fired, and then only as the word "interrupt" in front of the step line - so "is my escape actually
  // on?" had no answer short of running `interrupt list` in the REPL. One chip each, lit while it has
  // control, with its fire tally.
  watch_line := ""
  if f.watcher_count > 0 {
    b := strings.builder_make(context.temp_allocator)
    for i in 0 ..< f.watcher_count {
      if i > 0 {
        strings.write_string(&b, "   ")
      }
      row := f.watchers[i]
      strings.write_string(&b, row.live ? "> " : "- ")
      strings.write_string(&b, gui_ellipsize(row.label, 28))
      if row.fires > 0 {
        fmt.sbprintf(&b, " x%d", row.fires)
      }
    }
    watch_line = strings.to_string(b)
  }
  watch_c := fmt.ctprintf("%s", watch_line)
  watch_w := watch_line == "" ? f32(0) : imgui.CalcTextSize(watch_c).x

  w := max(row_w, status_w, watch_w)
  x0 := imgui.GetCursorPosX()

  if watch_line != "" {
    imgui.SetCursorPosX(x0 + (w - watch_w) * 0.5)
    wp := imgui.GetCursorScreenPos()
    imgui.Dummy({watch_w, imgui.GetTextLineHeight()})
    wdl := imgui.GetWindowDrawList()
    imgui.DrawList_AddText(wdl, {wp.x + 1, wp.y + 1}, u32_of({0, 0, 0, 0.75}), watch_c)
    imgui.DrawList_AddText(wdl, wp, u32_of(f.script_in_watcher ? COL_WARN : tint(COL_TEXT_DIM, 0.95)), watch_c)
    if imgui.IsItemHovered() {
      imgui.SetTooltip("Watchers armed for this run - its own, any it borrows, and anything set to always watch. Checked before every step, first match wins.")
    }
  }

  // Drawn by hand with a 1px near-black shadow (same reasoning as the gauges' inline value): this line
  // sits directly on the map, and the map is whatever colour the terrain happens to be.
  imgui.SetCursorPosX(x0 + (w - status_w) * 0.5)
  sp := imgui.GetCursorScreenPos()
  imgui.Dummy({status_w, imgui.GetTextLineHeight()})
  dl := imgui.GetWindowDrawList()
  imgui.DrawList_AddText(dl, {sp.x + 1, sp.y + 1}, u32_of({0, 0, 0, 0.75}), status)
  imgui.DrawList_AddText(dl, sp, u32_of(col), status)

  imgui.SetCursorPosX(x0 + (w - row_w) * 0.5)
  if gui_text_button("dockname", name, DOCK_NAME_H, 14, false, fmt.ctprintf("Running '%s' - click for the chart browser", f.script_name)) {
    ps.browser_open = true
    ps.browser_rescan = true
  }
  imgui.SameLine(0, gap)

  // One button that is play OR pause, never both - the control shows what pressing it will do.
  if f.script_paused {
    if gui_icon_button("tp_play", ICON_PLAY, true, "Resume  ('script resume')", COL_OK) {
      panel_enqueue(ps, "script resume")
    }
  } else {
    if gui_icon_button("tp_pause", ICON_PAUSE, false, "Pause - freezes the whole machine, interrupts included  ('script pause')") {
      panel_enqueue(ps, "script pause")
    }
  }
  imgui.SameLine(0, gap)
  if gui_icon_button("tp_reset", ICON_REPLAY, false, "Rewind to the start node  ('script reset')") {
    panel_enqueue(ps, "script reset")
  }
  imgui.SameLine(0, gap)
  if gui_icon_button("tp_step", ICON_STEP, f.script_step, f.script_step ? "Execute one block  ('script step', 'script step off' to resume)" : "Single-step: freeze the walker and run one block at a time  ('script step')") {
    panel_enqueue(ps, "script step")
  }
  imgui.SameLine(0, gap)
  if gui_icon_button("tp_stop", ICON_STOP, false, "Stop - anything in flight is torn down  ('script stop')", COL_BAD) {
    panel_enqueue(ps, "script stop")
  }
}

// ===========================================================================
// Behaviour browser
// ===========================================================================

gui_behaviour_browser :: proc(ps: ^Panel_State, f: ^Gui_Frame) {
  if ps.browser_rescan || rl.GetTime() - ps.browser_scan_at > BROWSER_SCAN_INTERVAL {
    gui_scan_behaviours(ps)
  }
  gui_browser_window(ps, f)
  // The name prompts are drawn AFTER the browser's End, not nested inside it: a window begun while
  // another is open is still a sibling, but it would be ordered behind it and the backdrop dim would be
  // applied twice.
  gui_bhv_name_prompt(ps, &ps.rename_from, ps.rename_buf[:], "Rename", "rename")
  gui_bhv_name_prompt(ps, &ps.dup_from, ps.dup_buf[:], "Duplicate", "duplicate")
}

@(private = "file")
gui_browser_window :: proc(ps: ^Panel_State, f: ^Gui_Frame) {
  // Taller than the tile grid needs: the interrupt checklist lives under it in the same scroll region,
  // and a section you have to scroll to find is a section nobody knows exists.
  if !gui_begin_dialog("Behaviours", 640, 660, &ps.browser_open) {
    imgui.End()
    return
  }
  defer imgui.End()

  // Full width, and with no sentence beside it: the search is the only thing on this line, so anything
  // sharing the row was just narrowing it. What a click does is on the tiles' own tooltips.
  imgui.SetNextItemWidth(-1)
  imgui.InputTextWithHint("##bhvfilter", "search behaviours", cstring(raw_data(ps.browser_filter[:])), len(ps.browser_filter))
  filter := strings.to_lower(strings.trim_space(panel_buf_str(ps.browser_filter[:])), context.temp_allocator)

  imgui.Dummy({0, 2})

  // THREE KINDS OF DOCUMENT, THREE TABS. They were one scroll region, which put the answer to three
  // different questions - what can I run, what can I place, what is watching - in one list you had to
  // read past. The SEARCH stays above the bar so it filters whichever tab is open; a per-tab search box
  // would be three boxes to remember you had typed in.
  //
  // Counts in the labels, the same trick the editor's Problems tab uses: the tab itself is then the
  // answer to "is there anything in there", so you do not have to open one to find out it is empty.
  charts, blocks, watchers := 0, 0, 0
  for r in ps.browser_rows {
    if r.interrupt {
      watchers += 1
    } else if r.subchart {
      blocks += 1
    } else {
      charts += 1
    }
  }
  // The list stops short of the bottom so the footer has a line; without the reservation the child
  // takes the whole remaining height and the footer lands outside the window.
  footer := imgui.GetTextLineHeightWithSpacing()
  if imgui.BeginChild("##bhvgrid", {0, -footer}, {}) {
    if imgui.BeginTabBar("##bhvtabs") {
      if imgui.BeginTabItem(charts == 0 ? "Charts" : fmt.ctprintf("Charts (%d)", charts)) {
        gui_bhv_tile_section(ps, f, filter, subchart = false)
        imgui.EndTabItem()
      }
      if imgui.BeginTabItem(blocks == 0 ? "Your blocks" : fmt.ctprintf("Your blocks (%d)", blocks)) {
        imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
        imgui.TextWrapped("These are charts you turned into BLOCKS. You do not run one - you place it in another chart from the palette, and it becomes a single node there.")
        imgui.PopStyleColor(1)
        gui_bhv_tile_section(ps, f, filter, subchart = true)
        imgui.EndTabItem()
      }
      if imgui.BeginTabItem(watchers == 0 ? "Interrupts" : fmt.ctprintf("Interrupts (%d)", watchers)) {
        gui_bhv_irq_section(ps, f, filter)
        imgui.EndTabItem()
      }
      imgui.EndTabBar()
    }
  }
  imgui.EndChild()

  // Where the files are, trimmed from the LEFT: a long absolute path's informative half is its tail.
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted(gui_fit_right(bhv_dir_path(), imgui.GetContentRegionAvail().x))
  imgui.PopStyleColor(1)
}

// Shorten <s> from the BACK until it fits <avail> pixels, suffixed with an ellipsis. The ordinary
// direction, for a name or a blurb whose informative half is its head.
//
// Package-visible rather than file-private: every hand-drawn row in this UI has to fit strings into a
// width it computed, so the leaderboard rows use both of these too. Nothing about them is behaviour-
// specific.
gui_fit :: proc(s: string, avail: f32) -> cstring {
  out := fmt.ctprintf("%s", s)
  if avail <= 0 {
    return ""
  }
  if imgui.CalcTextSize(out).x <= avail {
    return out
  }
  for n := len(s) - 1; n > 0; n -= 1 {
    out = fmt.ctprintf("%s...", s[:n])
    if imgui.CalcTextSize(out).x <= avail {
      return out
    }
  }
  return ""
}

// Shorten <s> from the front until it fits <avail> pixels, prefixed with an ellipsis.
gui_fit_right :: proc(s: string, avail: f32) -> cstring {
  out := fmt.ctprintf("%s", s)
  if imgui.CalcTextSize(out).x <= avail {
    return out
  }
  for i := 1; i < len(s); i += 1 {
    out = fmt.ctprintf("...%s", s[i:])
    if imgui.CalcTextSize(out).x <= avail {
      return out
    }
  }
  return "..."
}

// One tab's worth of tiles. The two tile tabs differ only in which rows they take and what the New
// button makes, so they share this rather than being written twice - the tile itself already knows how
// to draw a block (see gui_bhv_tile).
@(private = "file")
gui_bhv_tile_section :: proc(ps: ^Panel_State, f: ^Gui_Frame, filter: string, subchart: bool) {
  // The New tile is first and is never filtered out: it is the way IN to the editor, and hiding it
  // behind a search that happens to match nothing is the moment you most want to make one.
  gui_bhv_new_tile(ps, subchart)
  matched := 0
  for &r in ps.browser_rows {
    if r.interrupt || r.subchart != subchart {
      continue
    }
    if filter != "" && !strings.contains(strings.to_lower(r.name, context.temp_allocator), filter) {
      continue
    }
    matched += 1
    gui_bhv_tile(ps, f, &r)
  }
  if matched == 0 {
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    if filter != "" {
      imgui.TextUnformatted("Nothing matches that.")
    } else if subchart {
      imgui.TextWrapped("No blocks yet. Make one with the + tile, or open a chart you already have and tick 'Use as a block' in its options.")
    } else {
      imgui.TextUnformatted("No charts yet - the + tile starts one.")
    }
    imgui.PopStyleColor(1)
  }
}

// Watcher-only documents, as a checklist rather than a tile grid. A tile invites a click that runs the
// thing, and running one of these is not what you want from it - you want it ARMED, which is a state,
// and a checkbox is the control for a state. Each row is one `interrupt on|off` away from the console.
//
// A document lands in this section because it is NOTHING BUT WATCHERS, not because a header said so:
// there is one kind of document now, and "something you arm" is a shape it can have.
@(private = "file")
gui_bhv_irq_section :: proc(ps: ^Panel_State, f: ^Gui_Frame, filter: string) {
  any := false
  for r in ps.browser_rows {
    if r.interrupt {
      any = true
      break
    }
  }
  imgui.Dummy({0, px(8)})
  imgui.SeparatorText("Always watching - armed, not run")
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextWrapped("These are watchers, not charts. Ticked, one is checked whatever else is happening and takes over when it fires. A single chart can borrow one instead, from its options tab.")
  imgui.PopStyleColor(1)
  // The EMPTY STATE is not optional now that this is a tab rather than a trailing section. As a
  // section, having nothing to say meant drawing nothing and letting the charts above it fill the
  // window; as a tab, drawing nothing is a blank panel that reads as a broken feature. It also has to
  // say WHY the list is empty, because "a watcher-only document" is not a thing you would guess you
  // needed to make.
  if !any && f.armed_watcher_count == 0 {
    imgui.Dummy({0, px(6)})
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextWrapped("Nothing here yet. A document shows up in this list when it is NOTHING BUT watchers - an 'on' node wired to the steps it should run, and no start node of its own.")
    imgui.Dummy({0, px(4)})
    imgui.TextWrapped("Make one from the Charts tab: + New chart, add an 'on' node, wire it to a body, and save. An 'on' node inside an ordinary chart is not this - it belongs to that chart and arms only while it runs.")
    imgui.PopStyleColor(1)
    return
  }

  for &r in ps.browser_rows {
    if !r.interrupt {
      continue
    }
    if filter != "" && !strings.contains(strings.to_lower(r.name, context.temp_allocator), filter) {
      continue
    }
    on := false
    bad := ""
    for i in 0 ..< f.armed_watcher_count {
      if f.armed[i].name == r.name {
        on = true
        if !f.armed[i].ok {
          bad = f.armed[i].why
        }
        break
      }
    }
    imgui.PushID(fmt.ctprintf("irq%s", r.name))
    want := on
    if imgui.Checkbox(fmt.ctprintf("%s", r.name), &want) {
      panel_enqueue(ps, fmt.tprintf("interrupt %s %s", want ? "on" : "off", r.name))
    }
    // The WHOLE row is the right-click target, not just whichever half happens to be the last item.
    // BeginPopupContextItem would bind to the trigger text alone, so right-clicking the name - which
    // is the obvious thing to aim at - would do nothing.
    row_hovered := imgui.IsItemHovered()
    imgui.SameLine(0, px(10))
    imgui.PushStyleColorImVec4(.Text, bad != "" ? COL_BAD : (on ? COL_WARN : COL_TEXT_DIM))
    imgui.TextUnformatted(fmt.ctprintf("%s", bad != "" ? bad : fmt.tprintf("takes over on %s", r.trigger)))
    imgui.PopStyleColor(1)
    row_hovered ||= imgui.IsItemHovered()
    if row_hovered && imgui.IsMouseClicked(.Right) {
      imgui.OpenPopup("##irqctx")
    }
    if imgui.BeginPopup("##irqctx") {
      if imgui.Selectable("Open in editor") {
        name := strings.clone(r.name, context.temp_allocator)
        ps.browser_open = false
        gui_editor_open(ps, name)
      }
      if imgui.Selectable("Test it now (ignores the trigger)") {
        panel_enqueue(ps, fmt.tprintf("interrupt test %s", r.name))
        ps.browser_open = false
      }
      if imgui.Selectable("Delete") {
        panel_enqueue(ps, fmt.tprintf("interrupt off %s", r.name))
        panel_enqueue(ps, fmt.tprintf("script delete %s", r.name))
        ps.browser_rescan = true
      }
      imgui.EndPopup()
    }
    imgui.PopID()
  }

  // An enabled name whose file is gone still occupies a slot and still says so in `status`, so it has
  // to be visible here too - otherwise the only way to clear it is the console.
  for i in 0 ..< f.armed_watcher_count {
    seen := false
    for r in ps.browser_rows {
      if r.name == f.armed[i].name {
        seen = true
        break
      }
    }
    if seen {
      continue
    }
    imgui.PushID(fmt.ctprintf("irqm%s", f.armed[i].name))
    want := true
    if imgui.Checkbox(fmt.ctprintf("%s", f.armed[i].name), &want) {
      panel_enqueue(ps, fmt.tprintf("interrupt off %s", f.armed[i].name))
    }
    imgui.SameLine(0, px(10))
    imgui.PushStyleColorImVec4(.Text, COL_BAD)
    imgui.TextUnformatted("its file is gone - untick to forget it")
    imgui.PopStyleColor(1)
    imgui.PopID()
  }
}

// What one tile says, independent of how it is drawn. Both kinds of tile fill this and hand it to
// gui_bhv_tile_body, so their layouts cannot drift apart - there is only one layout.
@(private = "file")
Bhv_Tile_Text :: struct {
  icon:      rune,
  icon_col:  imgui.Vec4,
  title:     string,
  title_col: imgui.Vec4,
  tag:       string, // the status word: first thing on the second line
  tag_col:   imgui.Vec4,
  sub:       string, // the blurb, after the tag; always dim
  tail:      string, // right-aligned badge on the TITLE line ("" = none)
}

// A tile's height: whatever two lines of text plus the padding come to. Not a constant, because the font
// is rasterized at ui_scale and a hardcoded height would clip at the large end.
@(private = "file")
gui_bhv_tile_h :: proc() -> f32 {
  return px(TILE_PAD) * 2 + imgui.GetTextLineHeight() * 2 + px(TILE_LINE_GAP)
}

// Draw a tile's contents over its button frame (same trick as gui_icon_button - a Selectable would give
// none of this layout control). THE only place tile text is positioned:
//
//   pad |icon| text column ................................. [tail] | pad
//   pad |    | tag  sub .................................           | pad
//
// Both lines share one left edge, the tail is right-aligned on the title's baseline rather than floated
// near the corner, and every string is fitted to the room actually left over.
@(private = "file")
gui_bhv_tile_body :: proc(rmin, rmax: imgui.Vec2, t: Bhv_Tile_Text) {
  dl := imgui.GetWindowDrawList()
  pad := px(TILE_PAD)
  lh := imgui.GetTextLineHeight()
  tx := rmin.x + pad + px(TILE_GUTTER)
  y0 := rmin.y + pad
  y1 := y0 + lh + px(TILE_LINE_GAP)
  right := rmax.x - pad

  gui_draw_icon(dl, rmin.x + pad + px(TILE_GUTTER) * 0.5, (rmin.y + rmax.y) * 0.5, t.icon, t.icon_col)

  // --- title line, with the badge claiming its width first
  title_room := right - tx
  if t.tail != "" {
    tail := fmt.ctprintf("%s", t.tail)
    tw := imgui.CalcTextSize(tail).x
    imgui.DrawList_AddText(dl, {right - tw, y0}, u32_of(COL_TEXT_DIM), tail)
    title_room -= tw + px(12)
  }
  imgui.DrawList_AddText(dl, {tx, y0}, u32_of(t.title_col), gui_fit(t.title, title_room))

  // --- second line: the status word, then the blurb in whatever is left
  x := tx
  if t.tag != "" {
    tag := gui_fit(t.tag, right - x)
    imgui.DrawList_AddText(dl, {x, y1}, u32_of(t.tag_col), tag)
    x += imgui.CalcTextSize(tag).x + px(10)
  }
  if t.sub != "" && x < right {
    imgui.DrawList_AddText(dl, {x, y1}, u32_of(tint(COL_TEXT_DIM, 0.9)), gui_fit(t.sub, right - x))
  }
}

// The first tile: start a blank chart in the node editor. Drawn as an outline rather than a filled
// button so it reads as "the empty slot", not as another behaviour that happens to be called New.
@(private = "file")
gui_bhv_new_tile :: proc(ps: ^Panel_State, subchart := false) {
  imgui.PushID("##newtile")
  defer imgui.PopID()
  imgui.PushStyleColorImVec4(.Button, tint(COL_ACCENT, 0.10))
  imgui.PushStyleColorImVec4(.ButtonHovered, tint(COL_ACCENT, 0.22))
  imgui.PushStyleColorImVec4(.ButtonActive, tint(COL_ACCENT, 0.32))
  imgui.PushStyleColorImVec4(.Border, tint(COL_ACCENT, 0.55))
  clicked := imgui.Button("##new", {imgui.GetContentRegionAvail().x, gui_bhv_tile_h()})
  imgui.PopStyleColor(4)

  gui_bhv_tile_body(
    imgui.GetItemRectMin(),
    imgui.GetItemRectMax(),
    {
      icon = ICON_ADD,
      icon_col = COL_ACCENT,
      title = subchart ? "New block" : "New chart",
      title_col = COL_TEXT,
      tag = "open the node editor",
      tag_col = COL_TEXT_DIM,
    },
  )
  if imgui.IsItemHovered() {
    imgui.SetTooltip(
      "%s",
      subchart \
      ? cstring("Draw a chart that other charts can place as one block. It runs once, takes settings you declare, and cannot have watchers of its own.") \
      : cstring("Draw a behaviour as a node graph. It is saved to a .bhv file when you hit Save."),
    )
  }
  if clicked {
    ps.browser_open = false
    gui_editor_new(ps, subchart)
  }
}

// One chart, as a tile. **Load** runs it and closes the browser; clicking the tile itself opens it in
// the editor; right-click is the menu of everything else.
//
// Running used to be the whole-tile click, which meant a stray click anywhere on a row launched a
// behaviour at a live character. Starting something is the one action here worth aiming at, so it got
// its own button, and the tile kept a click that cannot cost you anything.
@(private = "file")
gui_bhv_tile :: proc(ps: ^Panel_State, f: ^Gui_Frame, r: ^Gui_Bhv_Row) {
  running := f.script_active && f.script_name == r.name
  // A shadowed built-in is not the behaviour that would run under its own name, so it is drawn as the
  // inert thing it is rather than as a button that lies about what it does.
  inert := r.builtin && r.shadowed

  // ctprintf, not raw_data(r.name): an Odin string is not NUL-terminated, so handing its bytes to a
  // cstring parameter reads past the end.
  imgui.PushID(fmt.ctprintf("%s", r.name))
  defer imgui.PopID()

  if running {
    imgui.PushStyleColorImVec4(.Button, tint(COL_OK, 0.22))
    imgui.PushStyleColorImVec4(.ButtonHovered, tint(COL_OK, 0.34))
    imgui.PushStyleColorImVec4(.ButtonActive, tint(COL_OK, 0.46))
    imgui.PushStyleColorImVec4(.Border, tint(COL_OK, 0.8))
  } else {
    imgui.PushStyleColorImVec4(.Button, tint(COL_TRACK, 0.85))
    imgui.PushStyleColorImVec4(.ButtonHovered, {0.184, 0.239, 0.310, 1.0})
    imgui.PushStyleColorImVec4(.ButtonActive, {0.235, 0.310, 0.400, 1.0})
    imgui.PushStyleColorImVec4(.Border, COL_BORDER)
  }
  // The Load button sits INSIDE the tile, right-aligned against its padding. The tile is submitted
  // with SetNextItemAllowOverlap so the button - drawn after it, therefore on top - can take the hover
  // and the click off it. An AllowOverlap item only counts as hovered if it was ALREADY the hovered
  // item on the previous frame, which is exactly what hands the pointer over when it crosses onto the
  // button, and what stops a click on Load from also opening the editor.
  //
  // Two things that are NOT the way to do this, both tried:
  //   - Narrowing the tile and putting the button beside it. That is what this replaced: it reads as
  //     two controls in a row rather than as one row with an action on it.
  //   - Placing the button with SetCursorScreenPos and then putting the cursor back. A cursor move
  //     that no item follows is what EndChild asserts on ("Code uses SetCursorPos() to extend
  //     window/parent boundaries"), and it fired on whichever tile happened to be drawn last.
  // Ordinary flow - SameLine, then cursor moves an item immediately follows - has no such hazard.
  tile_h := gui_bhv_tile_h()
  load_label: cstring = running ? "Restart" : "Load"
  load_w := gui_text_button_w(load_label, 16)
  load_h := f32(24)
  row_x := imgui.GetCursorPosX()
  row_y := imgui.GetCursorPosY()
  tile_w := imgui.GetContentRegionAvail().x
  imgui.SetNextItemAllowOverlap()
  clicked := imgui.Button("##tile", {tile_w, tile_h})
  imgui.PopStyleColor(4)
  hovered := imgui.IsItemHovered()
  tile_min := imgui.GetItemRectMin()
  tile_max := imgui.GetItemRectMax()

  icon_col := r.builtin ? COL_TEXT_DIM : COL_ACCENT
  if inert {
    icon_col = tint(COL_TEXT_DIM, 0.5)
  }
  tag := r.builtin ? (r.shadowed ? "Odin (shadowed)" : "Odin") : "saved"
  tag_col := COL_TEXT_DIM
  if running {
    tag = f.script_paused ? "PAUSED" : "running"
    tag_col = f.script_paused ? COL_WARN : COL_OK
  } else if r.subchart {
    // Its SIGNATURE where a chart shows its status, because that is the thing you need from a block:
    // what it is called and what you have to fill in. It has no run state to report - it never runs on
    // its own.
    tag = r.signature
    tag_col = ed_cat_color(.Sub)
  }
  // The text stops where the button starts. Handing gui_bhv_tile_body a narrower rect is all it takes:
  // it fits the title and right-aligns the badge against whatever rect it is given, so the button's
  // width comes off the box rather than being special-cased inside the one layout proc.
  text_max := tile_max
  if !inert && !r.subchart {
    text_max.x -= load_w + px(TILE_PAD)
  }
  gui_bhv_tile_body(
    tile_min,
    text_max,
    {
      icon = r.subchart ? ICON_CAT_SUB : (r.builtin ? ICON_CODE : ICON_FILE),
      icon_col = r.subchart ? ed_cat_color(.Sub) : icon_col,
      title = r.name,
      title_col = inert ? COL_TEXT_DIM : COL_TEXT,
      tag = tag,
      tag_col = tag_col,
      sub = r.blurb,
      tail = r.test ? "test" : "",
    },
  )

  if hovered {
    if r.blurb != "" {
      imgui.SetTooltip("%s", fmt.ctprintf("%s\n\nClick to open it in the editor.  Right-click: more.", r.blurb))
    } else {
      imgui.SetTooltip("Click to open it in the editor.  Right-click: more.")
    }
  }
  // The tile itself opens the editor - the one click on this row that cannot start anything.
  if clicked && !inert {
    name := strings.clone(r.name, context.temp_allocator)
    ps.browser_open = false
    gui_editor_open(ps, name)
  }

  // The right-click menu binds to the LAST ITEM, so it has to be claimed here while that is still the
  // tile - after the Load button it would bind to the button and the tile would stop answering.
  if imgui.BeginPopupContextItem("##ctx") {
    // A BLOCK offers neither. Running one starts and stops in the same breath - it is a fragment of a
    // chart, and `script run` refuses it - so the menu offers the thing you actually want instead:
    // stop being a block, and go back to being a chart you can run.
    if r.subchart {
      if imgui.Selectable("Make it a chart again") {
        panel_enqueue(ps, fmt.tprintf("script subchart %s off", r.name))
      }
      if imgui.IsItemHovered() {
        imgui.SetTooltip("It stops appearing in the palette, and can be run on its own again. Charts that place it will say the block is missing.")
      }
      imgui.Separator()
    } else {
      if !inert && imgui.Selectable("Run") {
        panel_enqueue(ps, fmt.tprintf("script run %s", r.name))
      }
      if running {
        if imgui.Selectable("Stop") {
          panel_enqueue(ps, "script stop")
        }
      }
      // The other direction. Only for a SAVED chart: a built-in has no file to flag, and `script
      // subchart` says so rather than doing something surprising.
      if !r.builtin && imgui.Selectable("Use as a block") {
        panel_enqueue(ps, fmt.tprintf("script subchart %s on", r.name))
      }
      if !r.builtin && imgui.IsItemHovered() {
        imgui.SetTooltip("It moves to 'Your blocks' and appears in every chart's palette. It runs once, and cannot have watchers of its own.")
      }
    }
    // Opening a built-in is allowed and is how you make one editable: the editor loads the built
    // program and saving it writes a file that shadows the Odin original (which the editor says out
    // loud). Deleting that file gets the original back - the same deal `script export` documents.
    // Two doors into the same editor. "Configure" lands on the settings tab and is the one you want
    // nine times out of ten - you are retuning a chart, not rewiring it - so it goes first.
    if imgui.Selectable("Configure...") {
      name := strings.clone(r.name, context.temp_allocator)
      ps.browser_open = false
      gui_editor_open(ps, name, true)
    }
    // Opening a built-in is allowed and is how you make one editable: the editor loads the built
    // program and saving it writes a file that shadows the Odin original (which the editor says out
    // loud). Deleting that file gets the original back - the same deal `script export` documents.
    if imgui.Selectable("Open in editor") {
      name := strings.clone(r.name, context.temp_allocator)
      ps.browser_open = false
      gui_editor_open(ps, name)
    }
    imgui.Separator()
    if imgui.Selectable("Duplicate...") {
      delete(ps.dup_from)
      ps.dup_from = strings.clone(r.name)
      panel_buf_set(ps.dup_buf[:], fmt.tprintf("%s_copy", r.name))
    }
    if !r.builtin {
      if imgui.Selectable("Rename...") {
        delete(ps.rename_from)
        ps.rename_from = strings.clone(r.name)
        panel_buf_set(ps.rename_buf[:], r.name)
      }
      if imgui.Selectable("Delete") {
        panel_enqueue(ps, fmt.tprintf("script delete %s", r.name))
        ps.browser_rescan = true
      }
    }
    imgui.EndPopup()
  }

  // --- Load, back on the tile's line and inside its right-hand padding.
  //
  // SameLine rejoins the row first, so ItemSize measures the button against the tile's line height
  // rather than starting a new one; the cursor moves are window-local (SetCursorPosX/Y are the exact
  // inverses of the GetCursorPosX/Y read above the tile, groups and scroll included) and are followed
  // immediately by an item, which is the condition ImGui asks for. Because the button is shorter than
  // the tile and centred in it, the row still advances by the tile's height and the grid is unchanged.
  //
  // A BLOCK has no Load: there is nothing to start. Its tile is a click that opens the editor and a
  // right-click menu, which is the whole set of things you can do to one.
  if !inert && !r.subchart {
    imgui.SameLine(0, 0)
    imgui.SetCursorPosX(row_x + tile_w - load_w - px(TILE_PAD))
    imgui.SetCursorPosY(row_y + (tile_h - px(load_h)) * 0.5)
    if gui_text_button(
      "tileload",
      load_label,
      load_h,
      16,
      true,
      running ? "Start this chart again from the top" : "Run this chart now, and close this window",
      COL_OK,
    ) {
      panel_enqueue(ps, fmt.tprintf("script run %s", r.name))
      ps.browser_open = false // you asked for it to run; the list has done its job
    }
  }
}

// The rename / duplicate prompt. One proc for both because they differ only in which command they emit:
// a duplicate is `script export` (build the source and write it under a new name) and a rename is
// `script rename`. Shared so the name-rule feedback can never drift between them.
@(private = "file")
gui_bhv_name_prompt :: proc(ps: ^Panel_State, from: ^string, buf: []u8, title: cstring, verb: string) {
  if from^ == "" {
    return
  }
  open := true
  if gui_begin_dialog(title, 380, 170, &open) {
    imgui.TextUnformatted(fmt.ctprintf("%s '%s' as:", verb == "rename" ? "Rename" : "Copy", from^))
    imgui.SetNextItemWidth(px(300))
    imgui.InputText("##newname", cstring(raw_data(buf)), len(buf))
    name := strings.trim_space(panel_buf_str(buf))
    ok := bhv_name_ok(name) && name != from^
    if !ok {
      imgui.PushStyleColorImVec4(.Text, name == "" ? COL_TEXT_DIM : COL_BAD)
      imgui.TextUnformatted(name == from^ ? "That is the name it already has." : BHV_NAME_RULE)
      imgui.PopStyleColor(1)
    } else if bhv_exists(name) {
      imgui.PushStyleColorImVec4(.Text, COL_BAD)
      imgui.TextUnformatted("A chart with that name already exists.")
      imgui.PopStyleColor(1)
      ok = false
    } else {
      imgui.Dummy({0, imgui.GetTextLineHeight()})
    }
    if !ok {
      imgui.BeginDisabled()
    }
    if imgui.Button(title, {px(120), 0}) {
      if verb == "rename" {
        panel_enqueue(ps, fmt.tprintf("script rename %s %s", from^, name))
      } else {
        panel_enqueue(ps, fmt.tprintf("script export %s as %s", from^, name))
      }
      ps.browser_rescan = true
      open = false
    }
    if !ok {
      imgui.EndDisabled()
    }
  }
  imgui.End()
  if !open {
    delete(from^)
    from^ = ""
  }
}

// Trim a string to <n> characters with an ellipsis, temp-allocated. Tiles have a fixed width and a
// blurb is a sentence, so something has to give.
@(private = "file")
gui_ellipsize :: proc(s: string, n: int) -> string {
  if len(s) <= n {
    return s
  }
  return fmt.tprintf("%s...", s[:max(0, n - 3)])
}
