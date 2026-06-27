package main

import "core:fmt"
import "core:math"
import "core:mem"
import "core:slice"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"
import "core:thread"

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

// `private_only` keeps only MEM_PRIVATE (heap) regions — where the game's CObj
// instances live — skipping mapped files / image sections. Used for object
// enumeration so it stays complete (no stale region cache) yet fast.
collect_regions :: proc(
  handle: win.HANDLE,
  writable_only: bool,
  private_only := false,
  allocator := context.allocator,
) -> [dynamic]Region {
  regions := make([dynamic]Region, allocator)
  mbi: win.MEMORY_BASIC_INFORMATION
  mbi_size := uint(size_of(mbi))
  addr: uintptr = 0
  for win.VirtualQueryEx(handle, rawptr(addr), &mbi, mbi_size) == mbi_size {
    base := uintptr(mbi.BaseAddress)
    size := uint(mbi.RegionSize)
    next := base + uintptr(size)
    if region_is_readable(mbi) &&
       (!writable_only || region_is_writable(mbi)) &&
       (!private_only || mbi.Type == win.MEM_PRIVATE) {
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
  regions := collect_regions(handle, writable_only)
  defer delete(regions)
  return scan_exact_regions(handle, t, target, regions[:], nil, allocator)
}

// Exact-value scan over an explicit list of regions. When `hit_regions` is non-nil,
// every region producing >=1 match is appended to it — used to build the
// target_closest enumeration cache so later scans re-read only object-bearing heaps.
scan_exact_regions :: proc(
  handle: win.HANDLE,
  t: Value_Type,
  target: Value,
  regions: []Region,
  hit_regions: ^[dynamic]Region,
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
  for r in regions {
    buf := make([]byte, r.size)
    n, ok := read_into(handle, r.base, buf)
    if ok {
      had := false
      off := 0
      for off + size <= int(n) {
        if mem.compare(buf[off:off + size], tgt[:size]) == 0 {
          append(&set.matches, Match{addr = r.base + uintptr(off), value = bytes_to_value(buf[off:off + size])})
          had = true
        }
        off += size
      }
      if had && hit_regions != nil {
        append(hit_regions, r)
      }
    }
    delete(buf)
  }
  return
}

// Per-worker state for scan_exact_parallel.
Scan_Worker :: struct {
  handle:  win.HANDLE,
  size:    int,
  tv32:    u32,
  tv64:    u64,
  target:  Value,
  regions: []Region,
  matches: [dynamic]Match,
}

scan_worker_proc :: proc(data: rawptr) {
  w := cast(^Scan_Worker)data
  w.matches = make([dynamic]Match)
  buf: []byte
  defer delete(buf)
  for r in w.regions {
    if len(buf) < int(r.size) {
      delete(buf)
      buf = make([]byte, r.size)
    }
    n, ok := read_into(w.handle, r.base, buf[:r.size])
    if !ok {
      continue
    }
    nn := int(n)
    off := 0
    switch w.size {
    case 4:
      // typed compare — far faster than mem.compare per offset; off stays 4-aligned
      for off + 4 <= nn {
        if (cast(^u32)(&buf[off]))^ == w.tv32 {
          append(&w.matches, Match{addr = r.base + uintptr(off), value = bytes_to_value(buf[off:off + 4])})
        }
        off += 4
      }
    case 8:
      for off + 8 <= nn {
        if (cast(^u64)(&buf[off]))^ == w.tv64 {
          append(&w.matches, Match{addr = r.base + uintptr(off), value = bytes_to_value(buf[off:off + 8])})
        }
        off += 8
      }
    case:
      for off + w.size <= nn {
        if mem.compare(buf[off:off + w.size], w.target[:w.size]) == 0 {
          append(&w.matches, Match{addr = r.base + uintptr(off), value = bytes_to_value(buf[off:off + w.size])})
        }
        off += w.size
      }
    }
  }
}

// Multithreaded exact-value scan over an explicit region list: regions are byte-balanced
// across worker threads, each scanning with a typed compare. Used by target_closest so a
// complete (uncached) scan stays fast. Matches are merged in arbitrary order.
scan_exact_parallel :: proc(
  handle: win.HANDLE,
  t: Value_Type,
  target: Value,
  regions: []Region,
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
  NW :: 8

  // distribute regions largest-first onto the least-loaded worker (balance by bytes)
  rs := make([]Region, len(regions), context.temp_allocator)
  copy(rs, regions)
  slice.sort_by(rs, proc(a, b: Region) -> bool {return a.size > b.size})
  wregions: [NW][dynamic]Region
  for i in 0 ..< NW {
    wregions[i] = make([dynamic]Region, context.temp_allocator)
  }
  loads: [NW]u64
  for r in rs {
    mi := 0
    for i in 1 ..< NW {
      if loads[i] < loads[mi] {
        mi = i
      }
    }
    append(&wregions[mi], r)
    loads[mi] += u64(r.size)
  }

  workers: [NW]Scan_Worker
  threads: [NW]^thread.Thread
  tv32 := u32(value_as_u64(t, target))
  tv64 := value_as_u64(t, target)
  for i in 0 ..< NW {
    workers[i] = Scan_Worker {
      handle  = handle,
      size    = size,
      tv32    = tv32,
      tv64    = tv64,
      target  = target,
      regions = wregions[i][:],
    }
    threads[i] = thread.create_and_start_with_data(&workers[i], scan_worker_proc)
  }
  for i in 0 ..< NW {
    thread.join(threads[i])
  }
  for i in 0 ..< NW {
    for m in workers[i].matches {
      append(&set.matches, m)
    }
    delete(workers[i].matches)
    thread.destroy(threads[i])
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
// Positions / nearest-entity enumeration
// ===========================================================================

// Read a D3DXVECTOR3 (3 contiguous little-endian f32: x, y, z) at `addr`.
read_vec3 :: proc(handle: win.HANDLE, addr: uintptr) -> (v: [3]f32, ok: bool) {
  buf: [12]byte
  n, rok := read_into(handle, addr, buf[:])
  if !rok || n < 12 {
    return {}, false
  }
  return transmute([3]f32)buf, true
}

// Horizontal distance between two points (ignores the vertical Y axis). Flyff
// targeting/range is effectively ground-plane, so this is the friendlier metric.
dist_horizontal :: proc(a, b: [3]f32) -> f32 {
  dx := a[0] - b[0]
  dz := a[2] - b[2]
  return math.sqrt(dx * dx + dz * dz)
}

// Full 3D distance between two points; used as the sort key for `nearest`.
dist_3d :: proc(a, b: [3]f32) -> f32 {
  dx := a[0] - b[0]
  dy := a[1] - b[1]
  dz := a[2] - b[2]
  return math.sqrt(dx * dx + dy * dy + dz * dz)
}

Nearest_Mode :: enum {
  List, // walk the CObj m_pNext linked list from a known object pointer
  Array, // read a static array of CObj* (e.g. m_amvrSelect / m_aobjCull)
}

Nearest_Entry :: struct {
  obj_ptr: uintptr, // CObj* base
  pos:     [3]f32,
  dtype:   u32, // m_dwType (at pos_off+0x10): distinguishes movers/mobs from props/NPCs
  dist:    f32, // 3D distance to player (sort key)
  dist_h:  f32, // horizontal distance to player
}

// Read m_dwType, which sits 0x10 past m_vPos in CObj (m_vPos, m_pWorld, m_dwType).
read_obj_type :: proc(handle: win.HANDLE, obj: uintptr, pos_off: i64) -> u32 {
  if tv, ok := read_value(handle, uintptr(i64(obj) + pos_off + 0x10), .U32); ok {
    return u32(value_as_u64(.U32, tv))
  }
  return 0
}

// Enumerate nearby entities and rank them by distance to `player_pos` (ascending).
// In .List mode, `start` is a known CObj* and we follow `+next_off` up to `max_nodes`
// nodes, validating each pointer against committed writable regions (with cycle
// detection). In .Array mode, `start` is the array base and we read `count` pointer-
// sized entries `stride` apart. Each entity's position is read at `obj + pos_off`.
enumerate_nearest :: proc(
  handle: win.HANDLE,
  ptr_size: int,
  mode: Nearest_Mode,
  start: uintptr,
  pos_off: i64,
  player_pos: [3]f32,
  next_off: i64,
  max_nodes: int,
  count: int,
  stride: i64,
  allocator := context.allocator,
) -> (
  out: [dynamic]Nearest_Entry,
) {
  out = make([dynamic]Nearest_Entry, allocator)

  regions := collect_regions(handle, true)
  defer delete(regions)
  slice.sort_by(regions[:], proc(a, b: Region) -> bool {
    return a.base < b.base
  })

  pt := Value_Type.U64
  if ptr_size == 4 {
    pt = .U32
  }

  objs := make([dynamic]uintptr, context.temp_allocator)
  switch mode {
  case .List:
    cur := start
    for _ in 0 ..< max_nodes {
      if cur == 0 || !region_contains(regions[:], cur) {
        break
      }
      seen := false
      for o in objs {
        if o == cur {
          seen = true
          break
        }
      }
      if seen {
        break // cycle
      }
      append(&objs, cur)
      nv, nok := read_value(handle, uintptr(i64(cur) + next_off), pt)
      if !nok {
        break
      }
      cur = uintptr(value_as_u64(pt, nv))
    }
  case .Array:
    for i in 0 ..< count {
      slot := uintptr(i64(start) + i64(i) * stride)
      sv, sok := read_value(handle, slot, pt)
      if !sok {
        continue
      }
      p := uintptr(value_as_u64(pt, sv))
      if p == 0 || !region_contains(regions[:], p) {
        continue
      }
      append(&objs, p)
    }
  }

  for obj in objs {
    pos, pok := read_vec3(handle, uintptr(i64(obj) + pos_off))
    if !pok {
      continue
    }
    append(
      &out,
      Nearest_Entry {
        obj_ptr = obj,
        pos = pos,
        dtype = read_obj_type(handle, obj, pos_off),
        dist = dist_3d(pos, player_pos),
        dist_h = dist_horizontal(pos, player_pos),
      },
    )
  }

  slice.sort_by(out[:], proc(a, b: Nearest_Entry) -> bool {
    return a.dist < b.dist
  })
  return
}

// Rank entities sourced from a scan match set. Each match address is treated as a
// pointer-field inside a CObj (e.g. m_pWorld), so the object base is `addr-field_off`
// and its position is read at `base+pos_off`. Objects whose base doesn't start with a
// module-range pointer (a vtable) are skipped, which filters stray hits of the scanned
// value that aren't real objects. Sorted ascending by 3D distance to `player_pos`.
rank_object_matches :: proc(
  handle: win.HANDLE,
  ptr_size: int,
  matches: []Match,
  field_off: i64,
  pos_off: i64,
  player_pos: [3]f32,
  module_base: uintptr,
  module_size: u32,
  allocator := context.allocator,
) -> (
  out: [dynamic]Nearest_Entry,
) {
  out = make([dynamic]Nearest_Entry, allocator)
  pt := Value_Type.U64
  if ptr_size == 4 {
    pt = .U32
  }
  mod_end := module_base + uintptr(module_size)
  for m in matches {
    obj := uintptr(i64(m.addr) - field_off)
    vt, vok := read_value(handle, obj, pt)
    if !vok {
      continue
    }
    p := uintptr(value_as_u64(pt, vt))
    if p < module_base || p >= mod_end {
      continue // no module-range vtable at base -> not a CObj, skip
    }
    pos, pok := read_vec3(handle, uintptr(i64(obj) + pos_off))
    if !pok {
      continue
    }
    append(
      &out,
      Nearest_Entry {
        obj_ptr = obj,
        pos = pos,
        dtype = read_obj_type(handle, obj, pos_off),
        dist = dist_3d(pos, player_pos),
        dist_h = dist_horizontal(pos, player_pos),
      },
    )
  }
  slice.sort_by(out[:], proc(a, b: Nearest_Entry) -> bool {
    return a.dist < b.dist
  })
  return
}

// Search committed readable memory for an exact byte pattern; returns match
// addresses. Used by 'find' to locate strings (ASCII or UTF-16LE) in the target.
scan_bytes :: proc(
  handle: win.HANDLE,
  pattern: []byte,
  allocator := context.allocator,
) -> (
  out: [dynamic]uintptr,
) {
  out = make([dynamic]uintptr, allocator)
  if len(pattern) == 0 {
    return
  }
  regions := collect_regions(handle, false)
  defer delete(regions)
  first := pattern[0]
  for r in regions {
    buf := make([]byte, r.size)
    n, ok := read_into(handle, r.base, buf)
    if ok {
      limit := int(n) - len(pattern)
      i := 0
      for i <= limit {
        if buf[i] == first && mem.compare(buf[i:i + len(pattern)], pattern) == 0 {
          append(&out, r.base + uintptr(i))
          i += len(pattern)
        } else {
          i += 1
        }
      }
    }
    delete(buf)
  }
  return
}

// Read a NUL-terminated ASCII string (max `max` bytes). Returns ok only if it is
// non-empty and entirely printable ASCII — so callers can probe an address and
// reject non-string memory.
read_cstring :: proc(
  handle: win.HANDLE,
  addr: uintptr,
  max := 48,
  allocator := context.temp_allocator,
) -> (
  s: string,
  ok: bool,
) {
  buf := make([]byte, max, allocator)
  n, rok := read_into(handle, addr, buf)
  if !rok || n == 0 {
    return "", false
  }
  end := 0
  for end < int(n) && buf[end] != 0 {
    if buf[end] < 0x20 || buf[end] > 0x7E {
      return "", false // non-printable -> not a name
    }
    end += 1
  }
  if end == 0 {
    return "", false
  }
  return string(buf[:end]), true
}

// Read an object's name at obj+name_off, auto-detecting whether the field is a
// pointer-to-string or an inline char buffer.
read_obj_name :: proc(
  handle: win.HANDLE,
  ptr_size: int,
  obj: uintptr,
  name_off: i64,
) -> (
  string,
  bool,
) {
  pt := Value_Type.U64
  if ptr_size == 4 {
    pt = .U32
  }
  field := uintptr(i64(obj) + name_off)
  if v, ok := read_value(handle, field, pt); ok {
    p := uintptr(value_as_u64(pt, v))
    if p != 0 {
      if s, sok := read_cstring(handle, p); sok {
        return s, true
      }
    }
  }
  return read_cstring(handle, field) // inline buffer fallback
}

// ---------------------------------------------------------------------------
// Flyff (modded Neuz.exe) layout, found at runtime. Slots are module-base-relative
// RVAs (base is fixed at 0x930000 but we add the live base so a rebase still works).
// ---------------------------------------------------------------------------
FLYFF_WORLD_RVA :: 0x5837CC // static global CWorld* ; m_pObjFocus = [base+RVA] + 0x20
FLYFF_PLAYER_RVA :: 0x571DE8 // static global player CMover*
FLYFF_FOCUS_OFF :: 0x20 // m_pObjFocus offset inside CWorld
FLYFF_FIELD_OFF :: 0x16C // CObj.m_pWorld (every object holds it; our enumeration anchor)
FLYFF_POS_OFF :: 0x160 // CObj.m_vPos (3x f32)
FLYFF_TYPE_REL :: 0x10 // m_dwType, relative to m_vPos (so POS_OFF+0x10)
FLYFF_NAME_OFF :: 0x1DB8 // CMover inline name char buffer
FLYFF_MOVER_TYPE :: 5 // m_dwType for movers (players, pets, NPCs, monsters)
FLYFF_HP_OFF :: 0x281C // CMover current HP (LONG); 0 => dead/despawning (don't target)
FLYFF_MODEL_OFF :: 0x178 // CObj.m_pModel; NULL => not rendered/selectable (crashes on select)

// Encode a pointer as `size` little-endian bytes for write_value/scan targets.
ptr_to_value :: proc(p: uintptr, size: int) -> (out: Value) {
  u := u64(p)
  for i in 0 ..< size {
    out[i] = byte(u >> uint(8 * i))
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
