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
TILE_W :: f32(210)
TILE_H :: f32(76)

// One row in the browser. Both kinds of behaviour appear here: the ones compiled into the exe and the
// ones saved as files, because "which behaviours exist" is a single question with a single answer.
Gui_Bhv_Row :: struct {
  name:      string, // owned
  blurb:     string, // owned ("" for a saved chart - a file carries no description)
  builtin:   bool, // defined in Odin: read-only, duplicate it to edit
  shadowed:  bool, // a saved file of the same name wins over this built-in
  test:      bool, // runs with nothing attached (the verification set)
  interrupt: bool, // `kind interrupt`: armed, not run - it belongs in the other section
  trigger:   string, // owned; the interrupt's trigger as one line ("" for a chart)
}

gui_free_bhv_rows :: proc(ps: ^Panel_State) {
  for r in ps.browser_rows {
    delete(r.name)
    delete(r.blurb)
    delete(r.trigger)
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
      },
    )
  }
  for s in saved {
    row := Gui_Bhv_Row {
      name  = strings.clone(s),
      blurb = strings.clone(""),
    }
    // Read the header to find out which section it belongs in. This is a file parse per saved chart
    // per scan, which is why the scan is throttled to BROWSER_SCAN_INTERVAL - the same reasoning as
    // the directory listing itself (see the note at the top of this file).
    if doc, ok := bhv_open(s); ok {
      row.interrupt = doc.kind == .Interrupt
      if row.interrupt {
        b := strings.builder_make(context.temp_allocator)
        script_write_event(&b, doc.trigger)
        row.trigger = strings.clone(strings.to_string(b))
      }
      behaviour_doc_free(&doc)
    }
    if row.trigger == "" {
      row.trigger = strings.clone("")
    }
    append(&ps.browser_rows, row)
  }
  ps.browser_scan_at = rl.GetTime()
  ps.browser_rescan = false
}

// ===========================================================================
// Transport strip (top-centre, over the map)
// ===========================================================================

// Only exists while something is running. There is no greyed-out transport sitting there with nothing to
// transport, for the same reason the recenter puck does not exist while the camera is already centred.
gui_behaviour_transport :: proc(ps: ^Panel_State, f: ^Gui_Frame) {
  if !f.script_active {
    return
  }
  vp := imgui.GetMainViewport()
  imgui.SetNextWindowPos({vp.Pos.x + vp.Size.x * 0.5, vp.Pos.y + px(TOOLBAR_PAD)}, .Always, {0.5, 0})
  imgui.PushStyleVarImVec2(.WindowPadding, {px(10), px(8)})
  if imgui.Begin("##transport", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoSavedSettings, .AlwaysAutoResize, .NoNavInputs, .NoDocking}) {
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
    imgui.SameLine(0, px(6))
    if gui_icon_button("tp_reset", ICON_REPLAY, false, "Rewind to the start node  ('script reset')") {
      panel_enqueue(ps, "script reset")
    }
    imgui.SameLine(0, px(6))
    if gui_icon_button("tp_step", ICON_STEP, f.script_step, f.script_step ? "Execute one block  ('script step', 'script step off' to resume)" : "Single-step: freeze the walker and run one block at a time  ('script step')") {
      panel_enqueue(ps, "script step")
    }
    imgui.SameLine(0, px(6))
    if gui_icon_button("tp_stop", ICON_STOP, false, "Stop - anything in flight is torn down  ('script stop')", COL_BAD) {
      panel_enqueue(ps, "script stop")
    }

    // --- the step indicator: name, position, and the block actually executing right now
    imgui.SameLine(0, px(12))
    imgui.BeginGroup()
    imgui.TextUnformatted(fmt.ctprintf("%s", f.script_name))
    imgui.SameLine(0, px(8))
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextUnformatted(fmt.ctprintf("step %d/%d", f.script_pc, f.script_len))
    imgui.PopStyleColor(1)

    line := f.script_line
    col := COL_ACCENT
    if f.script_irq {
      // Worth calling out loudly: the step counter is frozen on the SUSPENDED step while a region runs,
      // so without this the strip looks stuck.
      line = fmt.tprintf("interrupt: %s", line)
      col = COL_WARN
    } else if f.script_paused {
      col = COL_TEXT_DIM
    }
    imgui.PushStyleColorImVec4(.Text, col)
    imgui.TextUnformatted(fmt.ctprintf("%s", line == "" ? "(starting)" : line))
    imgui.PopStyleColor(1)
    imgui.EndGroup()
  }
  imgui.End()
  imgui.PopStyleVar(1)
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

  imgui.SetNextItemWidth(px(240))
  imgui.InputTextWithHint("##bhvfilter", "search", cstring(raw_data(ps.browser_filter[:])), len(ps.browser_filter))
  filter := strings.to_lower(strings.trim_space(panel_buf_str(ps.browser_filter[:])), context.temp_allocator)
  imgui.SameLine(0, px(10))
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted("left-click runs, right-click for more")
  imgui.PopStyleColor(1)

  imgui.Dummy({0, 2})
  // The grid stops short of the bottom so the footer has a line; without the reservation the child
  // takes the whole remaining height and the footer lands outside the window.
  footer := imgui.GetTextLineHeightWithSpacing()
  if imgui.BeginChild("##bhvgrid", {0, -footer}, {}) {
    avail := imgui.GetContentRegionAvail().x
    per_row := max(1, int(avail / px(TILE_W + 8)))
    shown := 0
    // The New tile is first and is never filtered out: it is the way IN to the editor, and hiding it
    // behind a search that happens to match nothing is the moment you most want to make one.
    gui_bhv_new_tile(ps)
    shown += 1
    matched := 0 // grid position vs "did the filter find anything" - the New tile counts for one, not the other
    for &r in ps.browser_rows {
      if r.interrupt {
        continue // its own section below - it is armed, not run, so a Run tile would be a lie
      }
      if filter != "" && !strings.contains(strings.to_lower(r.name, context.temp_allocator), filter) {
        continue
      }
      if shown % per_row != 0 {
        imgui.SameLine(0, px(8))
      }
      shown += 1
      matched += 1
      gui_bhv_tile(ps, f, &r)
    }
    if matched == 0 {
      imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
      imgui.TextUnformatted(filter == "" ? "No behaviours yet - the + tile starts one." : "Nothing matches that.")
      imgui.PopStyleColor(1)
    }
    gui_bhv_irq_section(ps, f, filter)
  }
  imgui.EndChild()

  // Where the files are, trimmed from the LEFT: a long absolute path's informative half is its tail.
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted(gui_fit_right(bhv_dir_path(), imgui.GetContentRegionAvail().x))
  imgui.PopStyleColor(1)
}

// Shorten <s> from the front until it fits <avail> pixels, prefixed with an ellipsis.
@(private = "file")
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

// Interrupts, as a checklist rather than a tile grid. A tile invites a click that runs the thing, and
// running an interrupt is not what you want from it - you want it ARMED, which is a state, and a
// checkbox is the control for a state. Each row is one `interrupt on|off` away from the console.
@(private = "file")
gui_bhv_irq_section :: proc(ps: ^Panel_State, f: ^Gui_Frame, filter: string) {
  any := false
  for r in ps.browser_rows {
    if r.interrupt {
      any = true
      break
    }
  }
  if !any && f.irq_n == 0 {
    return
  }
  imgui.Dummy({0, px(8)})
  imgui.SeparatorText("Interrupts - armed, not run")
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted("An armed interrupt watches its trigger whatever else is happening, and takes over when it fires.")
  imgui.PopStyleColor(1)

  for &r in ps.browser_rows {
    if !r.interrupt {
      continue
    }
    if filter != "" && !strings.contains(strings.to_lower(r.name, context.temp_allocator), filter) {
      continue
    }
    on := false
    bad := ""
    for i in 0 ..< f.irq_n {
      if f.irq[i].name == r.name {
        on = true
        if !f.irq[i].ok {
          bad = f.irq[i].why
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
    imgui.TextUnformatted(fmt.ctprintf("%s", bad != "" ? bad : fmt.tprintf("fires when %s", r.trigger)))
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
  for i in 0 ..< f.irq_n {
    seen := false
    for r in ps.browser_rows {
      if r.name == f.irq[i].name {
        seen = true
        break
      }
    }
    if seen {
      continue
    }
    imgui.PushID(fmt.ctprintf("irqm%s", f.irq[i].name))
    want := true
    if imgui.Checkbox(fmt.ctprintf("%s", f.irq[i].name), &want) {
      panel_enqueue(ps, fmt.tprintf("interrupt off %s", f.irq[i].name))
    }
    imgui.SameLine(0, px(10))
    imgui.PushStyleColorImVec4(.Text, COL_BAD)
    imgui.TextUnformatted("its file is gone - untick to forget it")
    imgui.PopStyleColor(1)
    imgui.PopID()
  }
}

// The first tile: start a blank chart in the node editor. Drawn as an outline rather than a filled
// button so it reads as "the empty slot", not as another behaviour that happens to be called New.
@(private = "file")
gui_bhv_new_tile :: proc(ps: ^Panel_State) {
  imgui.PushID("##newtile")
  defer imgui.PopID()
  imgui.PushStyleColorImVec4(.Button, tint(COL_ACCENT, 0.10))
  imgui.PushStyleColorImVec4(.ButtonHovered, tint(COL_ACCENT, 0.22))
  imgui.PushStyleColorImVec4(.ButtonActive, tint(COL_ACCENT, 0.32))
  imgui.PushStyleColorImVec4(.Border, tint(COL_ACCENT, 0.55))
  clicked := imgui.Button("##new", {px(TILE_W), px(TILE_H)})
  imgui.PopStyleColor(4)

  rmin := imgui.GetItemRectMin()
  dl := imgui.GetWindowDrawList()
  gui_draw_icon(dl, rmin.x + px(20), rmin.y + px(22), ICON_ADD, COL_ACCENT)
  imgui.DrawList_AddText(dl, {rmin.x + px(38), rmin.y + px(13)}, u32_of(COL_TEXT), "New chart")
  imgui.DrawList_AddText(dl, {rmin.x + px(38), rmin.y + px(34)}, u32_of(COL_TEXT_DIM), "open the node editor")
  if imgui.IsItemHovered() {
    imgui.SetTooltip("Draw a behaviour as a node graph. It is saved to a .bhv file when you hit Save.")
  }
  if clicked {
    ps.browser_open = false
    gui_editor_new(ps)
  }
}

// One chart, as a tile. Left-click runs it (the thing you want 95% of the time); right-click is the
// menu of everything else.
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
  clicked := imgui.Button("##tile", {px(TILE_W), px(TILE_H)})
  imgui.PopStyleColor(4)

  rmin := imgui.GetItemRectMin()
  hovered := imgui.IsItemHovered()
  dl := imgui.GetWindowDrawList()

  // Contents, hand-drawn over the button frame (same trick as gui_icon_button): a kind glyph, the name,
  // and one status word. A Selectable would give none of that layout control.
  icon_col := r.builtin ? COL_TEXT_DIM : COL_ACCENT
  if inert {
    icon_col = tint(COL_TEXT_DIM, 0.5)
  }
  gui_draw_icon(dl, rmin.x + px(20), rmin.y + px(22), r.builtin ? ICON_CODE : ICON_FILE, icon_col)
  imgui.DrawList_AddText(dl, {rmin.x + px(38), rmin.y + px(13)}, u32_of(inert ? COL_TEXT_DIM : COL_TEXT), fmt.ctprintf("%s", r.name))

  tag := r.builtin ? (r.shadowed ? "Odin (shadowed)" : "Odin") : "saved"
  tag_col := COL_TEXT_DIM
  if running {
    tag = f.script_paused ? "PAUSED" : "running"
    tag_col = f.script_paused ? COL_WARN : COL_OK
  }
  imgui.DrawList_AddText(dl, {rmin.x + px(38), rmin.y + px(34)}, u32_of(tag_col), fmt.ctprintf("%s", tag))
  if r.test {
    imgui.DrawList_AddText(dl, {rmin.x + px(TILE_W) - px(28), rmin.y + px(34)}, u32_of(COL_TEXT_DIM), "test")
  }
  if r.blurb != "" {
    imgui.DrawList_AddText(
      dl,
      {rmin.x + px(12), rmin.y + px(54)},
      u32_of(tint(COL_TEXT_DIM, 0.9)),
      fmt.ctprintf("%s", gui_ellipsize(r.blurb, 30)),
    )
  }

  if hovered {
    if r.blurb != "" {
      imgui.SetTooltip("%s", fmt.ctprintf("%s\n\nLeft-click: run.  Right-click: more.", r.blurb))
    } else {
      imgui.SetTooltip("Left-click: run.  Right-click: more.")
    }
  }
  if clicked && !inert {
    panel_enqueue(ps, fmt.tprintf("script run %s", r.name))
  }

  if imgui.BeginPopupContextItem("##ctx") {
    if !inert && imgui.Selectable("Run") {
      panel_enqueue(ps, fmt.tprintf("script run %s", r.name))
    }
    if running {
      if imgui.Selectable("Stop") {
        panel_enqueue(ps, "script stop")
      }
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
