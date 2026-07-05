package engine

import "core:fmt"
import "core:strings"
import win "core:sys/windows"

// ===========================================================================
// Process discovery / module info (Win32 toolhelp)
// ===========================================================================

Process_Search_Result :: struct {
  process_id:   u32,
  process_name: string,
  window_title: string,
}

get_process_module_info :: proc(process_id: u32) -> (base_address: ^win.BYTE, module_size: u32, ok: bool) {
  snapshot_handle := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPMODULE | win.TH32CS_SNAPMODULE32, process_id)
  defer win.CloseHandle(snapshot_handle)

  if snapshot_handle == win.INVALID_HANDLE_VALUE {
    fmt.println("Failed to create snapshot")
    return
  }

  module_entry: win.MODULEENTRY32W
  module_entry.dwSize = size_of(module_entry)

  first_ok := win.Module32FirstW(snapshot_handle, &module_entry)
  if !first_ok {
    fmt.println("Failed to get first module")
    return
  }

  base_address = module_entry.modBaseAddr
  module_size = module_entry.modBaseSize
  ok = true
  return
}

find_process_id_by_name :: proc(name: string, allocator := context.allocator) -> (result: []Process_Search_Result) {
  context.allocator = allocator
  lower_name := strings.trim_space(strings.to_lower(name, context.temp_allocator))
  snapshot_handle := win.CreateToolhelp32Snapshot(win.TH32CS_SNAPPROCESS, 0)
  defer win.CloseHandle(snapshot_handle)

  if snapshot_handle == win.INVALID_HANDLE_VALUE {
    fmt.println("Failed to create snapshot")
    return
  }

  process_entry: win.PROCESSENTRY32W
  process_entry.dwSize = size_of(process_entry)

  ok := win.Process32FirstW(snapshot_handle, &process_entry)
  if !ok {
    fmt.println("Failed to get first process")
    return
  }

  results: [dynamic]Process_Search_Result
  for ok {
    process_name, err := win.wstring_to_utf8(win.wstring(raw_data(process_entry.szExeFile[:])), -1)
    if err == nil {
      lower_process_name := strings.to_lower(process_name, context.temp_allocator)
      window_title, wok := find_window_title_by_process_id(process_entry.th32ProcessID)
      if !wok {
        window_title = ""
      }
      lower_title := strings.to_lower(window_title, context.temp_allocator)
      // Match on either the process name OR its window title, so a character name
      // like "BAFACO" picks the right Neuz.exe. Empty filter matches everything.
      if lower_name == "" ||
         strings.contains(lower_process_name, lower_name) ||
         strings.contains(lower_title, lower_name) {
        append(
          &results,
          Process_Search_Result {
            process_id = process_entry.th32ProcessID,
            process_name = process_name,
            window_title = window_title,
          },
        )
      }
    }

    ok = win.Process32NextW(snapshot_handle, &process_entry)
  }

  return results[:]
}

find_window_title_by_process_id :: proc(
  process_id: u32,
  allocator := context.temp_allocator,
) -> (
  title: string,
  ok: bool,
) {
  Window_Info :: struct {
    hwnd: win.HWND,
    pid:  u32,
  }

  enum_windows_cb :: proc(hwnd: win.HWND, lparam: win.LPARAM) -> win.BOOL {
    info := transmute(^Window_Info)lparam
    pid: u32
    win.GetWindowThreadProcessId(hwnd, &pid)
    if pid == info.pid {
      info.hwnd = hwnd
      return false
    } else {
      return true
    }
  }

  info := Window_Info {
    hwnd = nil,
    pid  = process_id,
  }

  enum_ok := win.EnumWindows(win.Window_Enum_Proc(enum_windows_cb), transmute(win.LPARAM)&info)
  if info.hwnd != nil {
    buf: [256]u16
    length := win.GetWindowTextW(info.hwnd, raw_data(&buf), 256)
    if length > 0 {
      title, _ = win.wstring_to_utf8(win.wstring(raw_data(&buf)), int(length), allocator)
      ok = true
      return
    }
  }

  return
}
