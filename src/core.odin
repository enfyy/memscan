package main

import "core:fmt"
import "core:os"
import "core:strings"
import "core:mem"
import win "core:sys/windows"
import "base:runtime"
import "core:strconv"

Process_Search_Result :: struct {
  process_id:   u32,
  process_name: string,
  window_title: string,
}

Scan_Result :: struct {
  addresses:      [dynamic]^win.BYTE,
  count:          uint,
  searched_value: cstring,
  searched_type:  typeid,
}

Initial_Scan_Type :: enum {
  Equal,
  Greater_Than,
  Less_Than,
  In_Range,
  Unknown,
}

Scan_Type :: enum {
  Equal,
  Greater_Than,
  Less_Than,
  In_Range,
  Unknown,
  Decreased,
  Increased,
  Decreased_By,
  Increased_By,
  Unchanged_Value,
  Changed_Value,
}

initial_scan :: proc(
  $T: typeid,
  process_handle: win.HANDLE,
  start_address: ^win.BYTE,
  end_address: ^win.BYTE,
  scan_buffer: ^[4096]byte,
  value_target: T,
  allocator: runtime.Allocator = context.allocator,
  writeable_only: bool = true,
) -> (
  result: Scan_Result,
) {
  results_count: uint = 0
  result.searched_type = T
  search_value_size: uint = size_of(T)
  when T == string {
    search_value_size = len(value_target)
  }
  current_region_address: ^win.BYTE
  mem_info: win.MEMORY_BASIC_INFORMATION
  mem_info_size: uint = size_of(mem_info)

  result.searched_value = fmt.caprint(value_target, allocator = allocator)
  result.addresses = make([dynamic]^win.BYTE, allocator)
  result.count = 0

  fmt.println("Performing initial scan...")
  fmt.printfln("Searching for type: %v (size: %d bytes)", typeid_of(T), size_of(T))
  fmt.printfln("Target value: %v", value_target)

  for ; win.VirtualQueryEx(process_handle, current_region_address, &mem_info, mem_info_size) == mem_info_size;
      current_region_address = mem.ptr_offset(current_region_address, mem_info.RegionSize) {

    region_scan_end := mem.ptr_offset(current_region_address, mem_info.RegionSize)
    debugptr := uintptr(0x7FF74E15B0A8)
    debug_region: bool
    if uintptr(region_scan_end) < debugptr && uintptr(region_scan_end) > debugptr {
      fmt.printfln("addr: %X | debug: %X", region_scan_end, debugptr)
      debug_region = true
    }

    memory_region_is_readable :=
      mem_info.State == win.MEM_COMMIT &&
      (mem_info.Protect & win.PAGE_GUARD == 0) &&
      (mem_info.Protect & win.PAGE_NOACCESS == 0)

    if !memory_region_is_readable {
      fmt.printfln("Skipping memory region %#v because it is not read-able", current_region_address)
      if debug_region {
        fmt.println("i flubbed it")
      }
      continue
    }

    memory_region_is_writable :=
      (mem_info.Protect & win.PAGE_READWRITE != 0) ||
      (mem_info.Protect & win.PAGE_WRITECOPY != 0) ||
      (mem_info.Protect & win.PAGE_EXECUTE_READWRITE != 0) ||
      (mem_info.Protect & win.PAGE_EXECUTE_WRITECOPY != 0)

    if writeable_only && !memory_region_is_writable {
      fmt.printfln("Skipping memory region %#v because it is not write-able", current_region_address)
      continue
    }

    region_offset: uint
    size_read: uint
    current_address := mem.ptr_offset(current_region_address, 4096)
    bytes_to_read: uint = min(4096, uint(mem.ptr_sub(region_scan_end, current_region_address)))
    read_ok := win.ReadProcessMemory(process_handle, current_address, raw_data(scan_buffer), bytes_to_read, &size_read)

    for ; read_ok && mem.ptr_offset(current_address, bytes_to_read) < region_scan_end;
        read_ok = win.ReadProcessMemory(
          process_handle,
          current_address,
          raw_data(scan_buffer),
          bytes_to_read,
          &size_read,
        ) {

      fmt.printfln(
        "Scanning memory region %#v+%X (%d bytes) (Region Size:%d)",
        region_offset,
        current_address,
        bytes_to_read,
        mem_info.RegionSize,
      )

      for offset: uint = 0; offset <= size_read - search_value_size; offset += 1 {
        when T != string && T == [dynamic]u8 {
          if offset % align_of(T) != 0 {
            continue
          }
        }

        when T == [dynamic]u8 {
          value := scan_buffer[offset:offset + search_value_size]
          if mem.compare(value, value_target[:]) == 0 {
            addr := mem.ptr_offset(current_address, offset)
            append(&result.addresses, addr)
            results_count += 1
          }
        } else when T == string {
          if debug_region {
            fmt.println("DEBUG:", offset)
          }
          addr := mem.ptr_offset(current_address, offset)
          if uintptr(addr) == debugptr {
            fmt.printfln("addr: %X | debug: %X", addr, debugptr)
            continue
          }
          value := scan_buffer[offset:offset + search_value_size]
          if mem.compare(value, transmute([]u8)value_target) == 0 {
            append(&result.addresses, addr)
            results_count += 1
          }

        } else {
          value: T
          mem.copy(&value, &scan_buffer[offset], int(search_value_size))
          addr := mem.ptr_offset(current_address, offset)
          if value == value_target {
            append(&result.addresses, addr)
            results_count += 1
          }
        }
      } // each byte

      current_address = mem.ptr_offset(current_address, bytes_to_read)
      bytes_to_read = min(4096, uint(mem.ptr_sub(current_address, region_scan_end)))
    } // each page

  } // each region

  result.count = results_count
  return result
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
      title, _ = win.wstring_to_utf8(raw_data(&buf), int(length), allocator)
      ok = true
      return
    }
  }

  return
}
