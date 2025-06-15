package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:mem"
import win "core:sys/windows"
import "base:runtime"
import "core:strconv"

MAX_SEARCH_RESULTS: uint = 10000

// main :: proc() {
//   PROCESS_NAME :: "Neuz.exe"

//   process_search_results := find_process_id_by_name(PROCESS_NAME, context.temp_allocator)
//   if len(process_search_results) == 0 {
//     fmt.println(PROCESS_NAME, "not found")
//     return
//   } else {
//     fmt.printfln("%s found: %#v", PROCESS_NAME, process_search_results)
//   }

//   neuz_process_id := process_search_results[0].process_id // Assuming we want the first one
//   fmt.println("Neuz process ID:", neuz_process_id)

//   neuz_process_handle := win.OpenProcess(win.PROCESS_VM_READ | win.PROCESS_QUERY_INFORMATION, false, neuz_process_id)
//   if neuz_process_handle == win.INVALID_HANDLE_VALUE {
//     fmt.println("Failed to open process")
//     return
//   }
//   defer win.CloseHandle(neuz_process_handle)

//   module_base_addr, module_size, get_module_ok := get_process_module_info(neuz_process_id)
//   if !get_module_ok {
//     fmt.println("Failed to get module info")
//     return
//   }

//   fmt.println("Module base address:", module_base_addr)
//   fmt.println("Module size:", module_size)
//   end_address := mem.ptr_offset(module_base_addr, module_size)

//   // search_type: typeid
//   // type_input_ok := false
//   // for search_type, type_input_ok = pick_type(); !type_input_ok; search_type, type_input_ok = pick_type() {}
//   // fmt.println("Selected search type:", search_type)

//   initial_scan(int, neuz_process_handle, module_base_addr, end_address, 66907012)
// }

initial_scan :: proc(
  $T: typeid,
  process_handle: win.HANDLE,
  start_address: ^win.BYTE,
  end_address: ^win.BYTE,
  value_target: T,
) {
  results_count: uint = 0
  search_value_size: uint = size_of(T)
  current_address := start_address
  mem_info: win.MEMORY_BASIC_INFORMATION
  mem_info_size: uint = size_of(mem_info)
  buffer := new([4096]byte)

  fmt.println("Performing initial scan...")
  for mem.ptr_sub(end_address, current_address) > 0 &&
      win.VirtualQueryEx(process_handle, current_address, &mem_info, mem_info_size) == mem_info_size {

    memory_region_is_readable :=
      mem_info.State == win.MEM_COMMIT &&
      (mem_info.Protect & win.PAGE_GUARD == 0) &&
      (mem_info.Protect & win.PAGE_NOACCESS == 0)

    if !memory_region_is_readable {
      fmt.println("Skipping unreadable memory region")
    } else {
      scan_end := mem.ptr_offset(current_address, mem_info.RegionSize)
      if scan_end > end_address do scan_end = end_address // clamp end address
      bytes_to_read: uint = min(4096, uint(mem.ptr_sub(scan_end, current_address))) // ensure we don't read past region boundary

      fmt.printfln("Scanning memory region %#v (%d bytes)", current_address, bytes_to_read)
      size_read: uint
      read_ok := win.ReadProcessMemory(process_handle, current_address, raw_data(buffer), bytes_to_read, &size_read)
      fmt.printfln("ReadProcessMemory: %v - READ %d bytes out of %d", read_ok, size_read, bytes_to_read)
      if !read_ok {
        fmt.println("Failed to read process memory. Error code:", win.GetLastError())
        return
      }

      for offset: uint = 0; offset < size_read - search_value_size && results_count < MAX_SEARCH_RESULTS; offset += 1 {
        if offset % align_of(T) != 0 {
          continue
        }

        // // Safely read the value
        // value: T
        // mem.copy(&value, &buffer[offset], size_of(T))

        // if value == value_target {
        //   fmt.printfln(
        //     "\n\nFound target value %v at address: %#v\n\n",
        //     value_target,
        //     mem.ptr_offset(current_address, offset),
        //   )
        //   results_count += 1
        // }
      }
    }
    current_address = mem.ptr_offset(current_address, mem_info.RegionSize)
  }
}

pick_type :: proc() -> (typ: typeid, ok: bool) {
  buf: [256]byte
  fmt.println("\nPick a type to search for:")
  fmt.println("1. Integer (4 bytes)")
  fmt.println("2. Float32 (4 bytes)")
  fmt.println("3. Float64 (8 bytes)")
  fmt.println("4. Byte (1 byte)")
  n, err := os.read(os.stdin, buf[:])
  if err != nil {
    fmt.eprintln("Error reading: ", err)
    return nil, false
  }

  input := string(buf[:n])
  choice, success := strconv.parse_int(strings.trim_space(input), 10)
  if success && choice >= 1 && choice <= 4 {
    switch choice {
    case 1:
      return int, true
    case 2:
      return f32, true
    case 3:
      return f64, true
    case:
      return byte, true
    }
  } else {
    fmt.println("invalid input, please try again\n\n")
    return nil, false
  }
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

Process_Search_Result :: struct {
  process_id:   u32,
  process_name: string,
  window_title: string,
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
    process_name, err := win.wstring_to_utf8(raw_data(process_entry.szExeFile[:]), -1)
    if err != nil {
      fmt.println("Failed to convert process name to UTF-8:", err)
      continue
    }
    lower_process_name := strings.to_lower(process_name, context.temp_allocator)

    if strings.contains(lower_process_name, lower_name) {
      found := Process_Search_Result {
        process_id   = process_entry.th32ProcessID,
        process_name = process_name,
      }
      window_title, ok := find_window_title_by_process_id(process_entry.th32ProcessID)
      if ok {
        found.window_title = window_title
      } else {
        found.window_title = ""
      }
      append(&results, found)
    }

    ok = win.Process32NextW(snapshot_handle, &process_entry)
  }

  return results[:]
}

find_window_title_by_process_id :: proc(process_id: u32) -> (title: string, ok: bool) {
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
      title, _ = win.wstring_to_utf8(raw_data(&buf), int(length)) //TODO: temp alloc
      ok = true
      return
    }
  }

  return
}
