package engine

import "core:math"
import "core:mem"
import "core:slice"
import "core:thread"
import win "core:sys/windows"


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
// every region producing >=1 match is appended to it - used to build the
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
      // typed compare - far faster than mem.compare per offset; off stays 4-aligned
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

// Scan the target's EXECUTABLE image pages (protect has an execute bit) for a 4-byte
// immediate, unaligned (code constants aren't 4-aligned). Returns hit addresses. Used to
// locate a function by a distinctive constant it embeds - e.g. the SETTARGET packet id
// 0x00ff0023 inside SendSetTarget. Read-only.
codescan_u32 :: proc(
  handle: win.HANDLE,
  needle: u32,
  allocator := context.allocator,
) -> (
  out: [dynamic]uintptr,
) {
  out = make([dynamic]uintptr, allocator)
  p0 := byte(needle)
  p1 := byte(needle >> 8)
  p2 := byte(needle >> 16)
  p3 := byte(needle >> 24)
  regions := collect_regions(handle, false)
  defer delete(regions)
  for r in regions {
    if r.protect & 0xF0 == 0 {
      continue // PAGE_EXECUTE* are the high nibble (0x10..0x80); skip non-exec pages
    }
    buf := make([]byte, r.size)
    n, ok := read_into(handle, r.base, buf)
    if ok {
      limit := int(n) - 4
      i := 0
      for i <= limit {
        if buf[i] == p0 && buf[i + 1] == p1 && buf[i + 2] == p2 && buf[i + 3] == p3 {
          append(&out, r.base + uintptr(i))
        }
        i += 1
      }
    }
    delete(buf)
  }
  return
}

// Scan executable pages for a direct near CALL (E8 rel32) whose computed target equals
// `dest` (a call at address A targets A+5+rel32). Returns the call-site addresses. Used to
// find callers of a known function so we can read the `mov ecx, imm32` (=&g_DPlay) preceding
// a g_DPlay.SendXxx call. Read-only.
codescan_calls :: proc(
  handle: win.HANDLE,
  dest: uintptr,
  allocator := context.allocator,
) -> (
  out: [dynamic]uintptr,
) {
  out = make([dynamic]uintptr, allocator)
  regions := collect_regions(handle, false)
  defer delete(regions)
  for r in regions {
    if r.protect & 0xF0 == 0 {
      continue
    }
    buf := make([]byte, r.size)
    n, ok := read_into(handle, r.base, buf)
    if ok {
      limit := int(n) - 5
      i := 0
      for i <= limit {
        if buf[i] == 0xE8 {
          rel := i32(u32(buf[i + 1]) | u32(buf[i + 2]) << 8 | u32(buf[i + 3]) << 16 | u32(buf[i + 4]) << 24)
          site := r.base + uintptr(i)
          target := uintptr(i64(site) + 5 + i64(rel))
          if target == dest {
            append(&out, site)
          }
        }
        i += 1
      }
    }
    delete(buf)
  }
  return
}

// Scan writable heap memory for 3 contiguous little-endian f32 within `eps` of target
// x/y/z. Returns the address of the first float (a candidate m_vPos). Used by calibrate /
// findpos to locate an object by its known world position. Floats are 4-aligned in the
// struct, so candidates are stepped by 4.
scan_vec3 :: proc(
  handle: win.HANDLE,
  target: [3]f32,
  eps: f32,
  allocator := context.allocator,
) -> (
  out: [dynamic]uintptr,
) {
  out = make([dynamic]uintptr, allocator)
  regions := collect_regions(handle, true)
  defer delete(regions)
  for r in regions {
    buf := make([]byte, r.size)
    n, ok := read_into(handle, r.base, buf)
    if ok {
      off := 0
      for off + 12 <= int(n) {
        x := transmute(f32)(u32(buf[off]) | u32(buf[off + 1]) << 8 | u32(buf[off + 2]) << 16 | u32(buf[off + 3]) << 24)
        y := transmute(f32)(u32(buf[off + 4]) | u32(buf[off + 5]) << 8 | u32(buf[off + 6]) << 16 | u32(buf[off + 7]) << 24)
        z := transmute(f32)(u32(buf[off + 8]) | u32(buf[off + 9]) << 8 | u32(buf[off + 10]) << 16 | u32(buf[off + 11]) << 24)
        if math.abs(x - target[0]) <= eps && math.abs(y - target[1]) <= eps && math.abs(z - target[2]) <= eps {
          append(&out, r.base + uintptr(off))
        }
        off += 4
      }
    }
    delete(buf)
  }
  return
}

// Scan the module image range [base, base+size) for a pointer-aligned slot whose value
// equals `needle`. Used by calibrate to turn a known heap object (world / player) into the
// static global RVA that holds it. Returns absolute slot addresses.
scan_image_for_ptr :: proc(
  handle: win.HANDLE,
  base: uintptr,
  size: u32,
  needle: uintptr,
  ptr_size: int,
  allocator := context.allocator,
) -> (
  out: [dynamic]uintptr,
) {
  out = make([dynamic]uintptr, allocator)
  mod_end := base + uintptr(size)
  regions := collect_regions(handle, false)
  defer delete(regions)
  for r in regions {
    rs := max(r.base, base)
    re := min(r.base + uintptr(r.size), mod_end)
    if rs >= re {
      continue
    }
    length := int(re - rs)
    buf := make([]byte, length)
    n, ok := read_into(handle, rs, buf)
    if ok {
      off := 0
      for off + ptr_size <= int(n) {
        v: uintptr
        if ptr_size == 4 {
          v = uintptr(u32(buf[off]) | u32(buf[off + 1]) << 8 | u32(buf[off + 2]) << 16 | u32(buf[off + 3]) << 24)
        } else {
          lo := u64(u32(buf[off]) | u32(buf[off + 1]) << 8 | u32(buf[off + 2]) << 16 | u32(buf[off + 3]) << 24)
          hi := u64(u32(buf[off + 4]) | u32(buf[off + 5]) << 8 | u32(buf[off + 6]) << 16 | u32(buf[off + 7]) << 24)
          v = uintptr(lo | hi << 32)
        }
        if v == needle {
          append(&out, rs + uintptr(off))
        }
        off += ptr_size
      }
    }
    delete(buf)
  }
  return
}

// Read a NUL-terminated ASCII string (max `max` bytes). Returns ok only if it is
// non-empty and entirely printable ASCII - so callers can probe an address and
