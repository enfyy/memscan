package engine

import "core:math"
import "core:slice"
import win "core:sys/windows"

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

// Encode a pointer as `size` little-endian bytes for write_value/scan targets.
ptr_to_value :: proc(p: uintptr, size: int) -> (out: Value) {
  u := u64(p)
  for i in 0 ..< size {
    out[i] = byte(u >> uint(8 * i))
  }
  return
}
