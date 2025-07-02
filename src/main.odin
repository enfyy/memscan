package main

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:strings"
import "core:strconv"
import win "core:sys/windows"

import rlimgui "../lib/imgui_impl_raylib"
import imgui "../lib/odin-imgui"
import rl "../lib/raylib"
import rb "../lib/collection"

@(rodata)
nil_search_result: Process_Search_Result

State :: struct {
  scan_results_arena:     virtual.Arena,
  scan_results:           rb.Ring_Buffer(Scan_Result),
  scan_buffer:            [4096]byte,
  process_search_arena:   virtual.Arena,
  process_search_results: []Process_Search_Result,
  attached_process:       Attached_Process,
  ui:                     UI_State,
}

Attached_Process :: struct {
  using search_result: ^Process_Search_Result,
  handle:              win.HANDLE,
  start_address:       ^win.BYTE,
  end_address:         ^win.BYTE,
  module_size:         u32,
}

main :: proc() {
  rl.SetConfigFlags({rl.ConfigFlag.WINDOW_RESIZABLE, rl.ConfigFlag.WINDOW_ALWAYS_RUN})
  rl.InitWindow(800, 600, "Flyff in 2025")
  defer rl.CloseWindow()

  imgui.CreateContext(nil);defer imgui.DestroyContext(nil)

  rlimgui.init();defer rlimgui.shutdown()
  rlimgui.build_font_atlas()

  state: State
  if !init_state(&state) do return

  for !rl.WindowShouldClose() {
    rl.BeginDrawing()
    rl.ClearBackground(rl.BLACK)
    rlimgui.begin()
    draw_ui(&state)
    rlimgui.end()
    rl.EndDrawing()
  }
  deinit_state(&state)
}

init_state :: proc(state: ^State) -> (ok: bool) {
  process_search_arena_err := virtual.arena_init_growing(&state.process_search_arena)
  if process_search_arena_err != .None {
    fmt.eprintln("failed to allocate arena for process search data")
    return false
  }

  scan_results_arena_err := virtual.arena_init_growing(&state.process_search_arena)
  if scan_results_arena_err != .None {
    fmt.eprintln("failed to allocate arena for scan result data")
    return false
  }
  state.scan_results = rb.ringbuffer_create(Scan_Result, 100, virtual.arena_allocator(&state.scan_results_arena))
  state.attached_process.search_result = &nil_search_result
  state.ui.panel_height = 50

  //DEBUG:
  str := "dummy"
  for i in 0 ..< len(str) {
    state.ui.attach_modal_filter_text_input_buffer[i] = str[i]
  }

  str = "stack string"
  for i in 0 ..< len(str) {
    state.ui.value_text_input_buffer[i] = str[i]
  }
  state.ui.button_group_value_type = 4

  return true
}

deinit_state :: proc(state: ^State) {
  free_all(virtual.arena_allocator(&state.process_search_arena))
  free_all(virtual.arena_allocator(&state.scan_results_arena))
  win.CloseHandle(state.attached_process.handle)
}

on_scan_button_pressed :: proc(state: ^State) {
  context.allocator = virtual.arena_allocator(&state.scan_results_arena)
  result: Scan_Result
  switch (state.ui.button_group_value_type) {
  case 0:
    search_value, valid_search_value := get_search_value(byte, state)
    if !valid_search_value {
      fmt.eprintf("invalid byte value")
    } else {
      result = initial_scan(
        byte,
        state.attached_process.handle,
        state.attached_process.start_address,
        state.attached_process.end_address,
        &state.scan_buffer,
        search_value,
        writeable_only = state.ui.include_readonly_memory,
      )
    }
  case 1:
    search_value, valid_search_value := get_search_value(i16, state)
    if !valid_search_value {
      fmt.eprintf("invalid i16 value")
    } else {
      result = initial_scan(
        i16,
        state.attached_process.handle,
        state.attached_process.start_address,
        state.attached_process.end_address,
        &state.scan_buffer,
        search_value,
        writeable_only = state.ui.include_readonly_memory,
      )
    }
  case 2:
    search_value, valid_search_value := get_search_value(i32, state)
    if !valid_search_value {
      fmt.eprintf("invalid i32 value")
    } else {
      result = initial_scan(
        i32,
        state.attached_process.handle,
        state.attached_process.start_address,
        state.attached_process.end_address,
        &state.scan_buffer,
        search_value,
        writeable_only = state.ui.include_readonly_memory,
      )
    }
  case 3:
    search_value, valid_search_value := get_search_value(i64, state)
    if !valid_search_value {
      fmt.eprintf("invalid i64 value")
    } else {
      result = initial_scan(
        i64,
        state.attached_process.handle,
        state.attached_process.start_address,
        state.attached_process.end_address,
        &state.scan_buffer,
        search_value,
        writeable_only = state.ui.include_readonly_memory,
      )
    }
  case 4:
    search_value, valid_search_value := get_search_value(string, state)
    if !valid_search_value {
      fmt.eprintf("invalid string value")
    } else {
      result = initial_scan(
        string,
        state.attached_process.handle,
        state.attached_process.start_address,
        state.attached_process.end_address,
        &state.scan_buffer,
        search_value,
        writeable_only = state.ui.include_readonly_memory,
      )
    }
  case:
    search_value, valid_search_value := get_search_value([dynamic]byte, state)
    if !valid_search_value {
      fmt.eprintf("invalid []byte value")
    } else {
      result = initial_scan(
        [dynamic]byte,
        state.attached_process.handle,
        state.attached_process.start_address,
        state.attached_process.end_address,
        &state.scan_buffer,
        search_value,
        writeable_only = state.ui.include_readonly_memory,
      )
    }
  }
  rb.ringbuffer_push(&state.scan_results, result)
}

on_clear_button_pressed :: proc(state: ^State) {
  free_all(virtual.arena_allocator(&state.scan_results_arena))
  state.scan_results = rb.ringbuffer_create(Scan_Result, 100, virtual.arena_allocator(&state.scan_results_arena))
}

on_attach_button_pressed :: proc(state: ^State) {
  alloc := virtual.arena_allocator(&state.process_search_arena)
  state.attached_process.search_result = &nil_search_result
  free_all(alloc)
  //TODO: maybe exclude itself as a process?
  state.process_search_results = find_process_id_by_name("", alloc)
}

get_search_value :: proc($T: typeid, state: ^State) -> (T, bool) {
  input_text := strings.clone_from_cstring(
    cstring(&state.ui.value_text_input_buffer[0]),
    allocator = context.temp_allocator,
  )

  when T == byte {
    //TODO:
    return 0, false
  } else when T == i16 {
    res, ok := strconv.parse_int(input_text)
    return i16(res), ok
  } else when T == i32 {
    res, ok := strconv.parse_int(input_text)
    return i32(res), ok
  } else when T == i64 {
    return strconv.parse_i64(input_text)
  } else when T == string {
    return input_text, true
  } else when T == [dynamic]byte {
    //TODO:
    return nil, false
  }

  return {}, false
}
