package engine

import win "core:sys/windows"

// ===========================================================================
// Process memory read / write
// ===========================================================================

read_into :: proc(handle: win.HANDLE, addr: uintptr, buf: []byte) -> (n: uint, ok: bool) {
  read: uint
  res := win.ReadProcessMemory(handle, rawptr(addr), raw_data(buf), uint(len(buf)), &read)
  return read, res != win.FALSE
}

// Best-effort read: fill as much of buf as is mapped, page by page, stopping at the first unreadable
// page. ReadProcessMemory fails the WHOLE call (reads 0) if any byte of the range is unmapped, so a
// single big read of an object near the end of its region returns nothing; this captures the valid
// prefix instead. Returns bytes read; the unread tail is left untouched (callers pass a zeroed buf).
read_into_partial :: proc(handle: win.HANDLE, addr: uintptr, buf: []byte) -> (n: uint) {
  if got, ok := read_into(handle, addr, buf); ok {
    return got // fast path: whole range mapped
  }
  total := uint(len(buf))
  off: uint = 0
  for off < total {
    cur := addr + uintptr(off)
    to_boundary := uint(0x1000) - (uint(cur) & 0xFFF) // read up to the next page boundary
    chunk := min(to_boundary, total - off)
    got, ok := read_into(handle, cur, buf[off:off + chunk])
    off += got
    if !ok || got < chunk {
      break // hit an unmapped page - stop at the valid prefix
    }
  }
  return off
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

// `private_only` keeps only MEM_PRIVATE (heap) regions - where the game's CObj
// instances live - skipping mapped files / image sections. Used for object
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
