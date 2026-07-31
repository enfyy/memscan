package flyff

import "core:fmt"
import "core:strings"

import imgui "../../lib/odin-imgui"

// ===========================================================================
// The waypoint route surface: the mode panel under the toolbar, and the per-flag context menu.
//
// Same contract as the rest of the UI (see the header of gui.odin) - this runs in cli_radar's
// exec_mutex-UNLOCKED draw phase, so it reads the Gui_Frame snapshot and issues every action as a CLI
// command through panel_enqueue. There is nothing in either panel you could not type: the name box is
// `waypoints rename <n> <name>`, the order box is `waypoints move <n> <to>`, Delete is
// `waypoints delete <n>`, and Undo/Redo/Clear/Save are the commands of those names.
//
// The one thing that does NOT go through a command is placing and dragging a flag, which happens in
// radar.odin's locked input phase: it has to land on the same frame as the click or the flag lags the
// cursor, and a deferred command is by definition a frame late.
//
// See waypoints.odin for the data model and why order is array position.
// ===========================================================================

// ===========================================================================
// Mode panel (top-left, under the toolbar; Waypoint mode only)
// ===========================================================================

gui_waypoint_menu :: proc(ps: ^Panel_State, f: ^Gui_Frame) {
  viewport := imgui.GetMainViewport()
  imgui.SetNextWindowPos({viewport.Pos.x + TOOLBAR_PAD, viewport.Pos.y + TOOLBAR_PAD + ICON_BTN + 26}, .Always)
  imgui.PushStyleVarImVec2(.WindowPadding, {px(10), px(10)})
  if imgui.Begin("##waypoints", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoSavedSettings, .AlwaysAutoResize, .NoNavInputs, .NoDocking}) {
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    set_name := f.waypoint_set_name == "" ? "unsaved" : f.waypoint_set_name
    imgui.TextUnformatted(fmt.ctprintf("WAYPOINTS  %s  -  %d point%s", set_name, f.waypoint_count, f.waypoint_count == 1 ? "" : "s"))
    imgui.PopStyleColor(1)

    // The map warning. Coordinates from another map are not wrong so much as meaningless, and the only
    // moment that is cheap to notice is before you walk the route rather than after.
    if f.waypoint_map_known && !f.waypoint_map_here {
      imgui.PushStyleColorImVec4(.Text, COL_WARN)
      imgui.TextUnformatted("drawn on another map")
      imgui.PopStyleColor(1)
    }

    if !f.waypoint_can_undo {
      imgui.BeginDisabled()
    }
    if imgui.Button("Undo", {px(66), 0}) {
      panel_enqueue(ps, "waypoints undo")
    }
    if !f.waypoint_can_undo {
      imgui.EndDisabled()
    }
    imgui.SameLine(0, px(6))
    if !f.waypoint_can_redo {
      imgui.BeginDisabled()
    }
    if imgui.Button("Redo", {px(66), 0}) {
      panel_enqueue(ps, "waypoints redo")
    }
    if !f.waypoint_can_redo {
      imgui.EndDisabled()
    }
    imgui.SameLine(0, px(6))
    if f.waypoint_count == 0 {
      imgui.BeginDisabled()
    }
    if imgui.Button("Clear", {px(68), 0}) {
      panel_enqueue(ps, "waypoints clear") // undoable, so it needs no confirmation
    }
    imgui.SameLine(0, px(6))
    if imgui.Button("Save...", {px(78), 0}) {
      ps.waypoint_save_open = true
      panel_buf_set(ps.waypoint_save_name[:], f.waypoint_set_name)
    }
    if f.waypoint_count == 0 {
      imgui.EndDisabled()
    }

    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextUnformatted("click places   drag moves   right-click a flag")
    imgui.PopStyleColor(1)
  }
  imgui.End()
  imgui.PopStyleVar(1)

  gui_waypoint_save_prompt(ps, f)
}

// ===========================================================================
// Save prompt
// ===========================================================================

@(private = "file")
gui_waypoint_save_prompt :: proc(ps: ^Panel_State, f: ^Gui_Frame) {
  if !ps.waypoint_save_open {
    return
  }
  open := true
  if gui_begin_dialog("Save waypoints", 380, 190, &open) {
    imgui.TextUnformatted(fmt.ctprintf("Save these %d point(s) as:", f.waypoint_count))
    imgui.SetNextItemWidth(px(300))
    imgui.InputText("##waypointsavename", cstring(raw_data(ps.waypoint_save_name[:])), len(ps.waypoint_save_name))
    name := strings.trim_space(panel_buf_str(ps.waypoint_save_name[:]))
    // Same rule as a chart name, and for the same reason: it is a filename AND a command argument.
    usable := bhv_name_ok(name)
    if !usable {
      imgui.PushStyleColorImVec4(.Text, name == "" ? COL_TEXT_DIM : COL_BAD)
      imgui.TextUnformatted(BHV_NAME_RULE)
      imgui.PopStyleColor(1)
    } else if waypoint_exists(name) && name != f.waypoint_set_name {
      imgui.PushStyleColorImVec4(.Text, COL_WARN)
      imgui.TextUnformatted("A set with that name exists - saving replaces it.")
      imgui.PopStyleColor(1)
    } else {
      imgui.Dummy({0, imgui.GetTextLineHeight()})
    }
    if !usable {
      imgui.BeginDisabled()
    }
    if imgui.Button("Save", {px(120), 0}) {
      panel_enqueue(ps, fmt.tprintf("waypoints save %s", name))
      open = false
    }
    if !usable {
      imgui.EndDisabled()
    }
  }
  imgui.End()
  if !open {
    ps.waypoint_save_open = false
  }
}

// ===========================================================================
// Per-flag context menu
//
// A real ImGui popup rather than a gui_begin_dialog "modal": this is an EVENT (you right-clicked that
// flag) and it should close the moment you click elsewhere, which is exactly what the popup stack does
// and what the hand-rolled dialogs deliberately do not.
//
// BeginPopupContextItem is not available here - the flags are drawn by raylib straight onto the map, so
// there is no ImGui item under the cursor to bind to. Hence the manual latch-then-OpenPopup dance the
// node canvas uses for its own right-clicks.
// ===========================================================================

gui_waypoint_context_menu :: proc(ps: ^Panel_State, f: ^Gui_Frame) {
  if ps.waypoint_context_open {
    ps.waypoint_context_open = false
    imgui.OpenPopup("##waypointctx")
  }
  if !imgui.BeginPopup("##waypointctx") {
    return
  }
  defer imgui.EndPopup()

  // The latched index can go stale: undo, a delete from the command line, or a `waypoints clear` all
  // shrink the list under an open menu. Close rather than edit whatever moved into that slot.
  index := ps.waypoint_context
  if index < 0 || index >= len(f.waypoint_rows) {
    imgui.CloseCurrentPopup()
    return
  }
  row := f.waypoint_rows[index]

  // One-shot seed: after this the boxes are the user's, and re-seeding every frame would fight typing.
  if !ps.waypoint_context_seeded {
    panel_buf_set(ps.waypoint_name[:], row.name)
    ps.waypoint_order = i32(index + 1)
    ps.waypoint_context_seeded = true
  }

  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted(fmt.ctprintf("WAYPOINT %d  (%.1f, %.1f)", index + 1, row.position[0], row.position[1]))
  imgui.PopStyleColor(1)
  imgui.Separator()

  imgui.TextUnformatted("Name")
  imgui.SetNextItemWidth(px(220))
  // EnterReturnsTrue so Enter commits: the menu is a two-field form and reaching for the mouse to
  // confirm a name you just typed is the slow path.
  name_committed := imgui.InputText("##waypointname", cstring(raw_data(ps.waypoint_name[:])), len(ps.waypoint_name), {.EnterReturnsTrue})
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted("names the chart section on import")
  imgui.PopStyleColor(1)

  imgui.TextUnformatted("Position in the route")
  imgui.SetNextItemWidth(px(120))
  order_committed := imgui.InputInt("##waypointorder", &ps.waypoint_order)
  ps.waypoint_order = clamp(ps.waypoint_order, 1, i32(len(f.waypoint_rows)))

  imgui.Separator()

  apply := imgui.Button("Apply", {px(96), 0})
  imgui.SameLine(0, px(6))
  imgui.PushStyleColorImVec4(.Text, COL_BAD)
  delete_it := imgui.Button("Delete", {px(96), 0})
  imgui.PopStyleColor(1)

  if delete_it {
    // The gap closes itself - order is array position, so there are no indices to renumber after this.
    panel_enqueue(ps, fmt.tprintf("waypoints delete %d", index + 1))
    imgui.CloseCurrentPopup()
    return
  }

  if apply || name_committed || order_committed {
    typed := strings.trim_space(panel_buf_str(ps.waypoint_name[:]))
    if typed != row.name {
      // An empty box means "unnamed", which `waypoints rename <n>` with no name spells.
      panel_enqueue(ps, fmt.tprintf("waypoints rename %d %s", index + 1, typed))
    }
    // Order LAST: renaming addresses the waypoint by index, so moving it first would rename whatever
    // landed in the old slot instead.
    if int(ps.waypoint_order) != index + 1 {
      panel_enqueue(ps, fmt.tprintf("waypoints move %d %d", index + 1, ps.waypoint_order))
    }
    if apply || order_committed {
      imgui.CloseCurrentPopup()
    }
  }
}
