package main

import "core:fmt"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"

// ===========================================================================
// Value types
// ===========================================================================

Value_Type :: enum u8 {
  U8,
  I8,
  U16,
  I16,
  U32,
  I32,
  U64,
  I64,
  F32,
  F64,
}

// A value is stored as up to 8 raw little-endian bytes.
Value :: [8]byte

value_size :: proc(t: Value_Type) -> int {
  switch t {
  case .U8, .I8:
    return 1
  case .U16, .I16:
    return 2
  case .U32, .I32, .F32:
    return 4
  case .U64, .I64, .F64:
    return 8
  }
  return 0
}

value_type_name :: proc(t: Value_Type) -> string {
  switch t {
  case .U8:
    return "u8"
  case .I8:
    return "i8"
  case .U16:
    return "u16"
  case .I16:
    return "i16"
  case .U32:
    return "u32"
  case .I32:
    return "i32"
  case .U64:
    return "u64"
  case .I64:
    return "i64"
  case .F32:
    return "f32"
  case .F64:
    return "f64"
  }
  return "?"
}

is_float :: proc(t: Value_Type) -> bool {
  return t == .F32 || t == .F64
}

is_signed :: proc(t: Value_Type) -> bool {
  return t == .I8 || t == .I16 || t == .I32 || t == .I64
}

bytes_to_value :: proc(b: []byte) -> (out: Value) {
  n := min(len(b), 8)
  copy(out[:n], b[:n])
  return
}

value_as_u64 :: proc(t: Value_Type, v: Value) -> u64 {
  n := value_size(t)
  out: u64 = 0
  for i in 0 ..< n {
    out |= u64(v[i]) << uint(8 * i)
  }
  return out
}

value_as_i64 :: proc(t: Value_Type, v: Value) -> i64 {
  n := value_size(t)
  u := value_as_u64(t, v)
  shift := uint(64 - 8 * n)
  return i64(u << shift) >> shift
}

value_as_f64 :: proc(t: Value_Type, v: Value) -> f64 {
  if t == .F32 {
    return f64(transmute(f32)u32(value_as_u64(t, v)))
  }
  return transmute(f64)value_as_u64(t, v)
}

// Parse a textual value of the given type into raw little-endian bytes.
// Integers accept decimal or 0x / 0o / 0b prefixes (and a leading '-').
parse_value :: proc(t: Value_Type, s: string) -> (out: Value, ok: bool) {
  if is_float(t) {
    f := strconv.parse_f64(s) or_return
    if t == .F32 {
      u := transmute(u32)f32(f)
      for i in 0 ..< 4 {
        out[i] = byte(u >> uint(8 * i))
      }
    } else {
      u := transmute(u64)f
      for i in 0 ..< 8 {
        out[i] = byte(u >> uint(8 * i))
      }
    }
    return out, true
  }
  i := strconv.parse_i64(s) or_return
  u := u64(i)
  n := value_size(t)
  for k in 0 ..< n {
    out[k] = byte(u >> uint(8 * k))
  }
  return out, true
}

format_value :: proc(t: Value_Type, v: Value) -> string {
  if is_float(t) {
    return fmt.tprintf("%v", value_as_f64(t, v))
  } else if is_signed(t) {
    return fmt.tprintf("%d (0x%X)", value_as_i64(t, v), value_as_u64(t, v))
  }
  uv := value_as_u64(t, v)
  return fmt.tprintf("%d (0x%X)", uv, uv)
}

// ===========================================================================
// Comparison
// ===========================================================================

Compare_Op :: enum {
  Eq,
  Ne,
  Gt,
  Lt,
  Changed,
  Unchanged,
  Increased,
  Decreased,
}

// Compares a freshly-read value `new_v` against a reference `ref_v`. For Eq/Ne/
// Gt/Lt the reference is a user-supplied target; for Changed/Unchanged/Increased/
// Decreased it is the value from the previous scan.
compare_values :: proc(t: Value_Type, new_v, ref_v: Value, op: Compare_Op) -> bool {
  size := value_size(t)
  a := new_v
  b := ref_v
  switch op {
  case .Eq, .Unchanged:
    return mem.compare(a[:size], b[:size]) == 0
  case .Ne, .Changed:
    return mem.compare(a[:size], b[:size]) != 0
  case .Gt, .Lt, .Increased, .Decreased:
    if is_float(t) {
      a := value_as_f64(t, new_v)
      b := value_as_f64(t, ref_v)
      #partial switch op {
      case .Gt, .Increased:
        return a > b
      case .Lt, .Decreased:
        return a < b
      }
    } else if is_signed(t) {
      a := value_as_i64(t, new_v)
      b := value_as_i64(t, ref_v)
      #partial switch op {
      case .Gt, .Increased:
        return a > b
      case .Lt, .Decreased:
        return a < b
      }
    } else {
      a := value_as_u64(t, new_v)
      b := value_as_u64(t, ref_v)
      #partial switch op {
      case .Gt, .Increased:
        return a > b
      case .Lt, .Decreased:
        return a < b
      }
    }
  }
  return false
}

// ===========================================================================
// Process memory read / write
// ===========================================================================

read_into :: proc(handle: win.HANDLE, addr: uintptr, buf: []byte) -> (n: uint, ok: bool) {
  read: uint
  res := win.ReadProcessMemory(handle, rawptr(addr), raw_data(buf), uint(len(buf)), &read)
  return read, res != win.FALSE
}

read_value :: proc(handle: win.HANDLE, addr: uintptr, t: Value_Type) -> (out: Value, ok: bool) {
  size := value_size(t)
  read: uint
  res := win.ReadProcessMemory(handle, rawptr(addr), raw_data(out[:size]), uint(size), &read)
  ok = res != win.FALSE && read == uint(size)
  return
}

write_value :: proc(handle: win.HANDLE, addr: uintptr, t: Value_Type, v: Value) -> bool {
  size := value_size(t)
  b := v
  written: uint
  res := win.WriteProcessMemory(handle, rawptr(addr), raw_data(b[:size]), uint(size), &written)
  return res != win.FALSE && written == uint(size)
}

// Follow a pointer chain. Reads a pointer-sized value at `base`, then for each
// offset adds it and dereferences again, EXCEPT the final offset is added without
// a trailing dereference. With no offsets it simply returns the pointer at `base`.
deref_chain :: proc(handle: win.HANDLE, base: uintptr, offsets: []i64, ptr_size: int) -> (addr: uintptr, ok: bool) {
  pt := Value_Type.U64
  if ptr_size == 4 {
    pt = .U32
  }
  v, rok := read_value(handle, base, pt)
  if !rok {
    return base, false
  }
  addr = uintptr(value_as_u64(pt, v))
  for off, i in offsets {
    addr += uintptr(off)
    if i < len(offsets) - 1 {
      v2, rok2 := read_value(handle, addr, pt)
      if !rok2 {
        return addr, false
      }
      addr = uintptr(value_as_u64(pt, v2))
    }
  }
  return addr, true
}

// ===========================================================================
// Memory regions
// ===========================================================================

Region :: struct {
  base:    uintptr,
  size:    uint,
  protect: u32,
}

region_is_readable :: proc(mbi: win.MEMORY_BASIC_INFORMATION) -> bool {
  return(
    mbi.State == win.MEM_COMMIT &&
    (mbi.Protect & win.PAGE_GUARD) == 0 &&
    (mbi.Protect & win.PAGE_NOACCESS) == 0 \
  )
}

region_is_writable :: proc(mbi: win.MEMORY_BASIC_INFORMATION) -> bool {
  return(
    mbi.Protect &
        (win.PAGE_READWRITE |
                win.PAGE_WRITECOPY |
                win.PAGE_EXECUTE_READWRITE |
                win.PAGE_EXECUTE_WRITECOPY) !=
    0 \
  )
}

collect_regions :: proc(handle: win.HANDLE, writable_only: bool, allocator := context.allocator) -> [dynamic]Region {
  regions := make([dynamic]Region, allocator)
  mbi: win.MEMORY_BASIC_INFORMATION
  mbi_size := uint(size_of(mbi))
  addr: uintptr = 0
  for win.VirtualQueryEx(handle, rawptr(addr), &mbi, mbi_size) == mbi_size {
    base := uintptr(mbi.BaseAddress)
    size := uint(mbi.RegionSize)
    next := base + uintptr(size)
    if region_is_readable(mbi) && (!writable_only || region_is_writable(mbi)) {
      append(&regions, Region{base = base, size = size, protect = u32(mbi.Protect)})
    }
    if next <= addr {
      break
    }
    addr = next
  }
  return regions
}

// ===========================================================================
// Scanning
// ===========================================================================

Match :: struct {
  addr:  uintptr,
  value: Value,
}

Match_Set :: struct {
  vtype:   Value_Type,
  matches: [dynamic]Match,
}

Region_Capture :: struct {
  base: uintptr,
  data: []byte,
}

Mem_Snapshot :: struct {
  vtype:   Value_Type,
  regions: [dynamic]Region_Capture,
}

snapshot_total_bytes :: proc(snap: Mem_Snapshot) -> (total: int) {
  for rc in snap.regions {
    total += len(rc.data)
  }
  return
}

// Exact-value scan over the target's committed memory. Candidates are aligned to
// the value size. `allocator` owns the resulting matches; scratch buffers use the
// ambient context.allocator and are freed here.
scan_exact :: proc(
  handle: win.HANDLE,
  t: Value_Type,
  target: Value,
  writable_only: bool,
  allocator := context.allocator,
) -> (
  set: Match_Set,
) {
  set.vtype = t
  set.matches = make([dynamic]Match, allocator)
  size := value_size(t)
  if size == 0 {
    return
  }

  tgt := target
  regions := collect_regions(handle, writable_only)
  defer delete(regions)

  for r in regions {
    buf := make([]byte, r.size)
    n, ok := read_into(handle, r.base, buf)
    if ok {
      off := 0
      for off + size <= int(n) {
        if mem.compare(buf[off:off + size], tgt[:size]) == 0 {
          append(&set.matches, Match{addr = r.base + uintptr(off), value = bytes_to_value(buf[off:off + size])})
        }
        off += size
      }
    }
    delete(buf)
  }
  return
}

// Capture the current bytes of every scanned region (unknown-initial value scan).
take_snapshot :: proc(
  handle: win.HANDLE,
  t: Value_Type,
  writable_only: bool,
  allocator := context.allocator,
) -> (
  snap: Mem_Snapshot,
) {
  snap.vtype = t
  snap.regions = make([dynamic]Region_Capture, allocator)
  regions := collect_regions(handle, writable_only)
  defer delete(regions)

  for r in regions {
    buf := make([]byte, r.size, allocator)
    n, ok := read_into(handle, r.base, buf)
    if !ok || n == 0 {
      delete(buf, allocator)
      continue
    }
    append(&snap.regions, Region_Capture{base = r.base, data = buf[:n]})
  }
  return
}

// First refine after a snapshot: re-read each region and keep the addresses whose
// (aligned) value satisfies the comparator against the snapshot (or a target).
refine_from_snapshot :: proc(
  handle: win.HANDLE,
  snap: Mem_Snapshot,
  op: Compare_Op,
  target: Value,
  has_target: bool,
  allocator := context.allocator,
) -> (
  set: Match_Set,
) {
  set.vtype = snap.vtype
  set.matches = make([dynamic]Match, allocator)
  size := value_size(snap.vtype)
  if size == 0 {
    return
  }

  for rc in snap.regions {
    buf := make([]byte, len(rc.data))
    n, ok := read_into(handle, rc.base, buf)
    if ok {
      limit := min(int(n), len(rc.data))
      off := 0
      for off + size <= limit {
        new_v := bytes_to_value(buf[off:off + size])
        ref_v: Value
        if has_target {
          ref_v = target
        } else {
          ref_v = bytes_to_value(rc.data[off:off + size])
        }
        if compare_values(snap.vtype, new_v, ref_v, op) {
          append(&set.matches, Match{addr = rc.base + uintptr(off), value = new_v})
        }
        off += size
      }
    }
    delete(buf)
  }
  return
}

// Subsequent refine: re-read each existing candidate and keep those that satisfy
// the comparator against their previously-stored value (or a target).
refine_matches :: proc(
  handle: win.HANDLE,
  prev: Match_Set,
  op: Compare_Op,
  target: Value,
  has_target: bool,
  allocator := context.allocator,
) -> (
  set: Match_Set,
) {
  set.vtype = prev.vtype
  set.matches = make([dynamic]Match, allocator)
  for m in prev.matches {
    new_v, ok := read_value(handle, m.addr, prev.vtype)
    if !ok {
      continue
    }
    ref_v := m.value
    if has_target {
      ref_v = target
    }
    if compare_values(prev.vtype, new_v, ref_v, op) {
      append(&set.matches, Match{addr = m.addr, value = new_v})
    }
  }
  return
}

// Returns true if `p` lies inside one of `regions`, which MUST be sorted ascending
// by base address.
region_contains :: proc(regions: []Region, p: uintptr) -> bool {
  lo := 0
  hi := len(regions)
  for lo < hi {
    mid := (lo + hi) / 2
    if regions[mid].base <= p {
      lo = mid + 1
    } else {
      hi = mid
    }
  }
  idx := lo - 1
  if idx < 0 {
    return false
  }
  r := regions[idx]
  return p >= r.base && p < r.base + uintptr(r.size)
}

// Keep only matches whose current value, read as a pointer, is non-zero and points
// into a committed writable region of the target (i.e. looks like a heap pointer).
// This is the decisive filter when hunting a value we know is a pointer.
filter_pointers :: proc(
  handle: win.HANDLE,
  prev: Match_Set,
  ptr_size: int,
  allocator := context.allocator,
) -> (
  set: Match_Set,
) {
  set.vtype = prev.vtype
  set.matches = make([dynamic]Match, allocator)

  regions := collect_regions(handle, true)
  defer delete(regions)
  slice.sort_by(regions[:], proc(a, b: Region) -> bool {
    return a.base < b.base
  })

  pt := Value_Type.U64
  if ptr_size == 4 {
    pt = .U32
  }
  for m in prev.matches {
    v, ok := read_value(handle, m.addr, pt)
    if !ok {
      continue
    }
    p := uintptr(value_as_u64(pt, v))
    if p == 0 {
      continue
    }
    if region_contains(regions[:], p) {
      append(&set.matches, Match{addr = m.addr, value = v})
    }
  }
  return
}

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
      title, _ = win.wstring_to_utf8(win.wstring(raw_data(&buf)), int(length), allocator)
      ok = true
      return
    }
  }

  return
}
