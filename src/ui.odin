package main

import "core:fmt"
import "core:mem"
import "core:strings"
import "core:mem/virtual"
import win "core:sys/windows"

import rb "../lib/collection"
import imgui "../lib/odin-imgui"

MODAL_ID_ATTACH: cstring : "Modal_Attach"
MODAL_ID_PROCESS_INFO: cstring : "Modal_Process_Info"

UI_State :: struct {
  show_attach_modal:                     bool,
  show_process_info_modal:               bool,
  value_text_input_buffer:               [256]byte,
  attach_modal_filter_text_input_buffer: [256]byte,
  panel_height:                          f32,
  is_resizing_panel:                     bool,
  button_group_scan_type:                int,
  button_group_value_type:               int,
  displayed_scan_result_offset:          int, //offset for the ringbuffer
  include_readonly_memory:               bool,
}

draw_modal_process_info :: proc(state: ^State) {
  if imgui.BeginPopupModal(
    MODAL_ID_PROCESS_INFO,
    &state.ui.show_process_info_modal,
    {.NoMove, .NoResize, .NoTitleBar},
  ) {
    window_size := imgui.GetWindowSize()

    imgui.SetCursorPos({10, 5})
    imgui.Text("Process Info")

    imgui.SetCursorPos({window_size.x - 25, 5})
    if imgui.Button("X") {
      imgui.CloseCurrentPopup()
      state.ui.show_process_info_modal = false
    }

    if imgui.BeginTable("processInfoTable", 2) {
      imgui.TableNextRow()
      imgui.TableSetColumnIndex(0)

      imgui.Text("Name")
      imgui.Text("PID")
      if len(state.attached_process.window_title) > 0 {
        imgui.Text("Window title")
      }
      imgui.Text("Module size")
      imgui.Text("Base address")

      imgui.TableSetColumnIndex(1)
      imgui.Text(fmt.ctprint(state.attached_process.process_name))
      imgui.Text(fmt.ctprint(state.attached_process.process_id))
      if len(state.attached_process.window_title) > 0 {
        imgui.Text(fmt.ctprint(state.attached_process.window_title))
      }
      imgui.Text(fmt.ctprint(fmt.tprintf("%.3f", f32(state.attached_process.module_size) / f32(mem.Megabyte)), "MB"))
      imgui.Text(fmt.ctprint(state.attached_process.start_address))

      imgui.EndTable()
    }

    imgui.Spacing()
    button_width: f32 = 120
    button_height: f32 = 30
    window_width := imgui.GetWindowSize().x
    imgui.SetCursorPos({(window_width - button_width) * 0.5, imgui.GetWindowSize().y - button_height - 10})

    if imgui.Button("Detach process", {button_width, button_height}) {
      state.attached_process = {}
      state.attached_process.search_result = &nil_search_result
      state.ui.show_process_info_modal = false
    }

    imgui.EndPopup()
  }
}

draw_modal_attach :: proc(state: ^State) {
  @(static) selected_process: ^Process_Search_Result

  if imgui.BeginPopupModal(MODAL_ID_ATTACH, &state.ui.show_attach_modal, {.NoMove, .NoResize, .NoTitleBar}) {
    window_size := imgui.GetWindowSize()

    imgui.SetCursorPos({10, 5})
    imgui.Text("Select process")
    imgui.SameLine()
    if imgui.Button("Refresh") {
      on_attach_button_pressed(state)
    }

    imgui.SetCursorPos({window_size.x - 25, 5})
    if imgui.Button("X") {
      imgui.CloseCurrentPopup()
      state.ui.show_attach_modal = false
    }

    imgui.PushItemWidth(-1)
    imgui.InputText(
      "##hidden", // ## hides the label
      cstring(raw_data(&state.ui.attach_modal_filter_text_input_buffer)),
      len(state.ui.attach_modal_filter_text_input_buffer),
      {},
    )
    imgui.PopItemWidth()
    input_text := strings.trim_space(
      strings.to_lower(
        strings.clone_from_cstring(
          cstring(&state.ui.attach_modal_filter_text_input_buffer[0]),
          allocator = context.temp_allocator,
        ),
        allocator = context.allocator,
      ),
    )

    imgui.Spacing()

    // process name list 
    child_height := imgui.GetWindowSize().y - 120
    if imgui.BeginChild("ScrollingRegion", {-1, child_height}, {}, {.AlwaysVerticalScrollbar}) {
      for item, i in state.process_search_results {
        lower_process_name := strings.to_lower(item.process_name, context.temp_allocator)
        process_name: cstring
        if len(item.window_title) > 0 {
          process_name = fmt.ctprintf("%s (PID: %d) - %s", item.process_name, item.process_id, item.window_title)
        } else {
          process_name = fmt.ctprintf("%s (PID: %d)", item.process_name, item.process_id)
        }
        if !strings.contains(lower_process_name, input_text) do continue

        if imgui.Selectable(process_name, selected_process == &state.process_search_results[i]) {
          selected_process = &state.process_search_results[i]
          fmt.printf("Selected: %s (PID: %d)\n", item.process_name, item.process_id)
        }
        imgui.Separator()
      }
      imgui.EndChild()
    }

    imgui.Spacing()
    button_width: f32 = 120 // Width of the button in pixels
    button_height: f32 = 30 // Height of the button
    window_width := imgui.GetWindowSize().x
    imgui.SetCursorPos({(window_width - button_width) * 0.5, imgui.GetWindowSize().y - button_height - 10})

    imgui.BeginDisabled(selected_process == nil)
    if imgui.Button("Open", {button_width, button_height}) {
      imgui.CloseCurrentPopup()
      state.ui.show_attach_modal = false
      state.attached_process.search_result = selected_process
      selected_process = nil
      state.attached_process.handle = win.OpenProcess(
        win.PROCESS_VM_READ | win.PROCESS_QUERY_INFORMATION,
        false,
        state.attached_process.process_id,
      )
      if state.attached_process.handle == win.INVALID_HANDLE_VALUE {
        fmt.eprint("failed to open selected process")
        state.attached_process.search_result = &nil_search_result
      } else {
        module_base_addr, module_size, get_module_ok := get_process_module_info(state.attached_process.process_id)
        if !get_module_ok {
          fmt.println("Failed to get module info")
          state.attached_process.search_result = &nil_search_result
        }

        state.attached_process.module_size = module_size
        state.attached_process.start_address = module_base_addr
        fmt.println("Module base address:", module_base_addr)
        fmt.println("Module size:", module_size)
        state.attached_process.end_address = mem.ptr_offset(module_base_addr, module_size)
      }

    }
    imgui.EndDisabled()
    imgui.EndPopup()
  }
}

draw_ui :: proc(state: ^State) {
  viewport := imgui.GetMainViewport()
  imgui.SetNextWindowPos(viewport.WorkPos)
  imgui.SetNextWindowSize(viewport.WorkSize)
  imgui.SetNextWindowViewport(viewport.ID_)

  draw_main_menu: bool = true
  imgui.Begin(
    "MainView",
    &draw_main_menu,
    {.NoTitleBar, .NoMove, .NoCollapse, .NoResize, .NoBringToFrontOnFocus, .NoNavFocus, .NoScrollbar},
  )
  if state.attached_process.search_result == &nil_search_result {
    if imgui.Button("Attach process") {
      state.ui.show_attach_modal = true
      on_attach_button_pressed(state)
    }
  } else {
    imgui.PushStyleColorImVec4(.Button, {1, 0, 0, 1})
    if imgui.Button(fmt.ctprint("Attached:", state.attached_process.process_name)) {
      state.ui.show_process_info_modal = true
    }
    imgui.PopStyleColor()

    imgui.SameLine()
    // imgui.SetCursorPosX()
  }
  imgui.Spacing()

  imgui.PushStyleVar(.DisabledAlpha, 0.2)
  imgui.BeginDisabled(state.attached_process.search_result == &nil_search_result)

  BUTTON_ROW_COUNT :: 5
  spacing := imgui.GetStyle().ItemSpacing.x
  button_dimensions: imgui.Vec2 = {
    (imgui.GetWindowSize().x / BUTTON_ROW_COUNT) - (spacing + (spacing / BUTTON_ROW_COUNT)),
    0,
  }
  active_button_color := imgui.GetStyleColorVec4(.ButtonActive)^

  imgui.SeparatorText("Scan types")
  new_group_value: int
  clicked: bool
  button_group_labels_scan_type: [BUTTON_ROW_COUNT]cstring = {"==", ">=", "<=", "[..]", "?"}
  for label, i in button_group_labels_scan_type {
    new_group_value, clicked = draw_toggle_button(label, state.ui.button_group_scan_type, i, button_dimensions)
    if clicked do state.ui.button_group_scan_type = new_group_value
    if i != len(button_group_labels_scan_type) - 1 do imgui.SameLine()
  }

  imgui.SeparatorText("Value types")
  new_group_value_type: int
  button_group_labels_value_type: [BUTTON_ROW_COUNT]cstring = {"1 Byte", "2 Byte", "4 Byte", "8 Byte", "String"}
  for label, i in button_group_labels_value_type {
    new_group_value_type, clicked = draw_toggle_button(label, state.ui.button_group_value_type, i, button_dimensions)
    if clicked do state.ui.button_group_value_type = new_group_value_type
    if i != len(button_group_labels_scan_type) - 1 do imgui.SameLine()
  }
  imgui.SeparatorText("Value")
  imgui.PushItemWidth(-1)
  imgui.InputText(
    "##hidden", // ## hides the label
    cstring(raw_data(&state.ui.value_text_input_buffer)),
    len(state.ui.value_text_input_buffer),
    {},
  )
  imgui.PopItemWidth()
  imgui.SeparatorText("Settings")
  imgui.Checkbox("Only writeable", &state.ui.include_readonly_memory)

  imgui.Spacing()
  imgui.Separator()
  imgui.Spacing()
  if imgui.Button("<- Undo", button_dimensions) {

  }
  imgui.SameLine()

  initial_scan_button_dimensions: imgui.Vec2 : {260, 0}
  imgui.SetCursorPosX((imgui.GetWindowSize().x / 2) - (initial_scan_button_dimensions.x / 2))

  if state.scan_results.count == 0 {
    if imgui.Button("Initial scan", initial_scan_button_dimensions) {
      on_scan_button_pressed(state)
    }
  } else {
    if imgui.Button("New scan", initial_scan_button_dimensions) {
      on_clear_button_pressed(state)
      on_scan_button_pressed(state)
    }
  }

  imgui.SameLine()
  imgui.SetCursorPosX(imgui.GetWindowSize().x - button_dimensions.x - imgui.GetStyle().WindowPadding.x)

  if imgui.Button("Next ->", button_dimensions) {

  }

  // // resizable space:
  // max_panel_height := imgui.GetContentRegionAvail().y - 50
  // imgui.SetCursorPosY(imgui.GetCursorPosY() + state.ui.panel_height)
  // if !rl.IsMouseButtonDown(.LEFT) do state.ui.is_resizing_panel = false
  // imgui.PushStyleVarImVec2(.ItemSpacing, {0, 0})
  // if imgui.InvisibleButton("InvisTableResizeButton", {-1, 20}) {}
  // imgui.PopStyleVar()
  // if imgui.IsItemHovered() {
  //   imgui.SetMouseCursor(.ResizeNS)
  //   if rl.IsMouseButtonDown(.LEFT) do state.ui.is_resizing_panel = true
  // }
  // if state.ui.is_resizing_panel {
  //   state.ui.panel_height += rl.GetMouseDelta().y
  //   state.ui.panel_height = clamp(state.ui.panel_height, 0, max_panel_height)
  // }
  // imgui.SetCursorPosY(imgui.GetCursorPosY() - 10) // move up half of invis button height

  //info:
  current_scan, ok := rb.ringbuffer_get(state.scan_results, state.ui.displayed_scan_result_offset)
  if state.scan_results.count == 0 || !ok {
    imgui.Text("Results: -")
  } else {
    imgui.Text(fmt.ctprintf("Results: %d", current_scan.count))
  }

  // table:
  table_flags: imgui.TableFlags =
    imgui.TableFlags_Resizable |
    imgui.TableFlags_BordersOuter |
    imgui.TableFlags_BordersV |
    imgui.TableFlags_RowBg |
    imgui.TableFlags_Reorderable |
    imgui.TableFlags_Hideable

  if imgui.BeginTable("ProcessMemoryTable", 3, table_flags, imgui.GetContentRegionAvail()) {
    imgui.TableSetupColumn("Address")
    imgui.TableSetupColumn("Type")
    imgui.TableSetupColumn("Value")
    imgui.TableHeadersRow()

    scan_result := rb.ringbuffer_get(state.scan_results, state.ui.displayed_scan_result_offset)

    for i := 0; i < int(scan_result.count); i += 1 {
      imgui.TableNextRow()
      imgui.TableNextColumn();imgui.Text(fmt.ctprintf("%p", scan_result.addresses[i]))
      imgui.TableNextColumn();imgui.Text(fmt.ctprint(scan_result.searched_type))
      imgui.TableNextColumn();imgui.Text(scan_result.searched_value)
    }

    imgui.EndTable()
  }

  imgui.PopStyleVar()
  imgui.EndDisabled()
  imgui.End()

  // -------- MODALS: 
  imgui.PushStyleColorImVec4(.ModalWindowDimBg, {0, 0, 0, .8})
  if state.ui.show_attach_modal {
    center := imgui.Viewport_GetCenter(viewport)
    imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
    imgui.SetNextWindowSize({viewport.Size.x - 50, 300}, .Appearing)
    imgui.OpenPopup(MODAL_ID_ATTACH)
  }
  draw_modal_attach(state)

  if state.ui.show_process_info_modal {
    center := imgui.Viewport_GetCenter(viewport)
    imgui.SetNextWindowPos(center, .Appearing, {0.5, 0.5})
    imgui.SetNextWindowSize({viewport.Size.x - 50, 300}, .Appearing)
    imgui.OpenPopup(MODAL_ID_PROCESS_INFO)
  }
  draw_modal_process_info(state)
  imgui.PopStyleColor()
}

draw_toggle_button :: proc(
  label: cstring,
  group_value: int,
  button_idx: int,
  dimensions: imgui.Vec2,
) -> (
  new_val: int,
  clicked: bool,
) {
  new_val = group_value
  if group_value == button_idx {
    imgui.PushStyleColorImVec4(.Button, imgui.GetStyleColorVec4(.ButtonActive)^)
  }
  defer if group_value == button_idx do imgui.PopStyleColor()

  clicked = imgui.Button(label, dimensions)
  if clicked {
    new_val = button_idx
  }
  return
}
