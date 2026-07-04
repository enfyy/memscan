package flyff

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:strconv"
import win "core:sys/windows"
import "../engine"

cli_idscan :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: idscan <name>")
    return
  }
  name := strings.trim(strings.join(args, " ", context.temp_allocator), "'\"")
  LEN :: 0x4200

  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  if !wok {
    fmt.eprintln("could not read world anchor.")
    return
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  wval := engine.ptr_to_value(world, session.ptr_size)
  all := engine.collect_regions(handle, true)
  defer delete(all)
  set := engine.scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)

  bufs := make([dynamic][]byte, context.temp_allocator)
  objs := make([dynamic]uintptr, context.temp_allocator)
  for m in set.matches {
    obj := uintptr(i64(m.addr) - session.layout.field_off)
    vt, vok := engine.read_value(handle, obj, pt)
    if !vok {
      continue
    }
    vtable := uintptr(engine.value_as_u64(pt, vt))
    if vtable < base || vtable >= mod_end {
      continue
    }
    if engine.read_obj_type(handle, obj, session.layout.pos_off) != session.layout.mover_type {
      continue
    }
    nm, nok := engine.read_obj_name(handle, session.ptr_size, obj, session.layout.name_off)
    if !nok || !strings.contains(nm, name) {
      continue
    }
    b := make([]byte, LEN, context.temp_allocator)
    engine.read_into(handle, obj, b)
    append(&bufs, b)
    append(&objs, obj)
  }
  n := len(bufs)
  fmt.printfln("idscan '%s': %d movers; distinct in-range 4-byte fields:", name, n)
  if n < 2 {
    fmt.println("need >=2 movers named that; get more on screen and retry.")
    return
  }

  u32at :: proc(b: []byte, off: int) -> u32 {
    return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24
  }

  // Re-read the SAME objects after a pause. m_objid is unique per mob AND never changes, so it is
  // both UNIQUE and STABLE; positions vary (mobs move) and drop out. We also test each value as a
  // pointer: real pointer fields (m_pModel etc.) resolve into committed memory, a plain objid does
  // not, so the ptr fraction separates objid from pointer fields regardless of its magnitude.
  fmt.println("sampling ~2.5s (let the mobs move / fight a little)...")
  win.Sleep(2500)
  bufs2 := make([][]byte, n, context.temp_allocator)
  dead := make([]bool, n, context.temp_allocator)
  for obj, i in objs {
    b := make([]byte, LEN, context.temp_allocator)
    engine.read_into(handle, obj, b)
    bufs2[i] = b
    vt, vok := engine.read_value(handle, obj, pt)
    if !vok || !in_module_range(uintptr(engine.value_as_u64(pt, vt)), base, mod_end) {
      dead[i] = true // freed/despawned during the window
    }
  }
  regions := engine.collect_regions(handle, false)
  defer delete(regions)
  slice.sort_by(regions[:], proc(a, b: engine.Region) -> bool {return a.base < b.base})

  shown := 0
  off := 0
  for off <= LEN - 4 {
    uniq := 0
    for i in 0 ..< n {
      v := u32at(bufs[i], off)
      if v == 0 {
        continue
      }
      dup := false
      for j in 0 ..< i {
        if u32at(bufs[j], off) == v {
          dup = true
          break
        }
      }
      if !dup {
        uniq += 1
      }
    }
    if uniq * 10 >= n * 8 {
      alive, stable, ptrs := 0, 0, 0
      for i in 0 ..< n {
        if dead[i] {
          continue
        }
        alive += 1
        if u32at(bufs[i], off) == u32at(bufs2[i], off) {
          stable += 1
        }
        if engine.region_contains(regions[:], uintptr(u32at(bufs[i], off))) {
          ptrs += 1
        }
      }
      if alive > 0 && stable * 10 >= alive * 9 && ptrs * 10 <= alive * 3 && shown < 24 {
        sb := strings.builder_make(context.temp_allocator)
        fmt.sbprintf(&sb, "  +0x%X uniq=%d ptr=%d/%d :", off, uniq, ptrs, alive)
        for i in 0 ..< min(n, 8) {
          fmt.sbprintf(&sb, " %d", u32at(bufs[i], off))
        }
        fmt.println(strings.to_string(sb))
        shown += 1
      }
    }
    off += 4
  }
  if shown == 0 {
    fmt.println("  (no unique+stable field found; objid may be past +0x1000 - tell me and I'll widen it)")
  } else {
    fmt.println("(m_objid = unique + stable + LOW ptr. pointer fields show ptr ~= alive; objid ~0.)")
  }
}

// srvsync           -> status
// srvsync on|off    -> toggle: after each focus select, also fire the client's own
//                      SendSetTarget(objid, 2) so the server registers our target.
cli_mobs :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: mobs <name>")
    return
  }
  name := strings.trim(strings.join(args, " ", context.temp_allocator), "'\"")
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  pv, pok := engine.read_value(handle, base + session.layout.player_rva, pt)
  if !wok || !pok {
    fmt.eprintln("could not read world/player anchors.")
    return
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  player := uintptr(engine.value_as_u64(pt, pv))
  player_pos, _ := engine.read_vec3(handle, player + uintptr(session.layout.pos_off))
  wval := engine.ptr_to_value(world, session.ptr_size)
  all := engine.collect_regions(handle, true)
  defer delete(all)
  set := engine.scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)

  Row :: struct {
    obj:      uintptr,
    d:        f32,
    hp:       i32,
    model:    uintptr,
    model_ok: bool,
  }
  rows := make([dynamic]Row, context.temp_allocator)
  for m in set.matches {
    obj := uintptr(i64(m.addr) - session.layout.field_off)
    vt, vok := engine.read_value(handle, obj, pt)
    if !vok {
      continue
    }
    vtable := uintptr(engine.value_as_u64(pt, vt))
    if vtable < base || vtable >= mod_end {
      continue
    }
    if engine.read_obj_type(handle, obj, session.layout.pos_off) != session.layout.mover_type {
      continue
    }
    nm, nok := engine.read_obj_name(handle, session.ptr_size, obj, session.layout.name_off)
    if !nok || !strings.contains(nm, name) {
      continue
    }
    pos, posok := engine.read_vec3(handle, obj + uintptr(session.layout.pos_off))
    if !posok {
      continue
    }
    hp: i32 = -1
    if hv, hok := engine.read_value(handle, obj + uintptr(session.layout.hp_off), .U32); hok {
      hp = i32(u32(engine.value_as_u64(.U32, hv)))
    }
    model: uintptr = 0
    if mv, mok := engine.read_value(handle, obj + uintptr(session.layout.model_off), pt); mok {
      model = uintptr(engine.value_as_u64(pt, mv))
    }
    model_ok := false
    if model >= 0x10000 {
      if _, r := engine.read_value(handle, model, pt); r {
        model_ok = true
      }
    }
    append(&rows, Row{obj = obj, d = engine.dist_3d(pos, player_pos), hp = hp, model = model, model_ok = model_ok})
  }
  slice.sort_by(rows[:], proc(a, b: Row) -> bool {return a.d < b.d})
  ok_count := 0
  for r in rows {
    if r.model_ok {
      ok_count += 1
    }
  }
  fmt.printfln("%d '%s' movers (%d selectable), by distance:", len(rows), name, ok_count)
  for r, i in rows {
    if i >= 30 {
      break
    }
    fmt.printfln(
      "  #%d d=%.1f obj=0x%X hp=%d model=0x%X %s",
      i + 1,
      r.d,
      r.obj,
      r.hp,
      r.model,
      r.model_ok ? "OK" : "BAD",
    )
  }
}

// Read-only recon: enumerate movers named <name> (same way target_closest does, but
// it NEVER writes focus), snapshot LEN bytes of each, wait ~2.5s, re-read, and report
// the field offsets that DECREMENT for some movers while staying 0 for the rest - i.e.
// a per-corpse death/despawn countdown. Used to find the "don't target" flag without
// touching the game. Usage: deathscan <name>
cli_deathscan :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: deathscan <name>")
    return
  }
  name := strings.trim(strings.join(args, " ", context.temp_allocator), "'\"")
  LEN :: 0x4000

  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  if !wok {
    fmt.eprintln("could not read world anchor.")
    return
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  wval := engine.ptr_to_value(world, session.ptr_size)

  all := engine.collect_regions(handle, true)
  defer delete(all)
  set := engine.scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)
  objs := make([dynamic]uintptr, context.temp_allocator)
  for m in set.matches {
    obj := uintptr(i64(m.addr) - session.layout.field_off)
    vt, vok := engine.read_value(handle, obj, pt)
    if !vok {
      continue
    }
    vtable := uintptr(engine.value_as_u64(pt, vt))
    if vtable < base || vtable >= mod_end {
      continue
    }
    if engine.read_obj_type(handle, obj, session.layout.pos_off) != session.layout.mover_type {
      continue
    }
    nm, nok := engine.read_obj_name(handle, session.ptr_size, obj, session.layout.name_off)
    if !nok || !strings.contains(nm, name) {
      continue
    }
    append(&objs, obj)
  }
  n := len(objs)
  fmt.printfln("deathscan '%s': %d movers; sampling...", name, n)
  if n < 3 {
    fmt.println("need >=3 movers (some alive, some fresh corpses). kill a few and retry.")
    return
  }

  read_snap :: proc(handle: win.HANDLE, objs: [dynamic]uintptr) -> [][]byte {
    bufs := make([][]byte, len(objs), context.temp_allocator)
    for o, i in objs {
      b := make([]byte, LEN, context.temp_allocator)
      engine.read_into(handle, o, b)
      bufs[i] = b
    }
    return bufs
  }
  u32at :: proc(b: []byte, off: int) -> i64 {
    if off + 4 > len(b) {
      return -1
    }
    return i64(u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24)
  }

  worldv := i64(u32(world))
  SNAPS :: 6
  snaps := make([][][]byte, SNAPS, context.temp_allocator)
  for s in 0 ..< SNAPS {
    snaps[s] = read_snap(handle, objs)
    if s < SNAPS - 1 {
      win.Sleep(1000)
    }
  }

  // A despawn countdown is 0 for every live mover and, for a fresh corpse, strictly
  // counts DOWN over the ~5s window (then the object frees). Require: per-mover values
  // monotonically non-increasing with at least one drop, 0 for the rest, no oscillators.
  fmt.println("=== fields counting monotonically DOWN for some movers (despawn timer) ===")
  off := 0
  for off <= LEN - 4 {
    mono, allz, oth := 0, 0, 0
    for i in 0 ..< n {
      cnt, prev, first := 0, i64(0), true
      ismono, anydec, allzero, startpos := true, false, true, false
      for s in 0 ..< SNAPS {
        if u32at(snaps[s][i], int(session.layout.field_off)) != worldv {
          continue // skip snapshots where this slot isn't a live object
        }
        v := u32at(snaps[s][i], off)
        cnt += 1
        if v != 0 {allzero = false}
        if v < 0 || v >= 100000 {ismono = false}
        if first {
          prev, startpos, first = v, v > 0, false
        } else {
          if v > prev {ismono = false}
          if v < prev {anydec = true}
          prev = v
        }
      }
      if cnt < 2 {
        continue
      }
      if allzero {
        allz += 1
      } else if ismono && anydec && startpos {
        mono += 1
      } else {
        oth += 1
      }
    }
    if mono >= 1 && oth <= 2 && allz >= (n * 6) / 10 {
      fmt.printfln("  +0x%X: mono=%d zero=%d other=%d", off, mono, allz, oth)
      shown := 0
      for i in 0 ..< n {
        sb := strings.builder_make(context.temp_allocator)
        valid, nonzero := 0, false
        for s in 0 ..< SNAPS {
          if u32at(snaps[s][i], int(session.layout.field_off)) != worldv {
            continue
          }
          v := u32at(snaps[s][i], off)
          if v != 0 {nonzero = true}
          fmt.sbprintf(&sb, "%d ", v)
          valid += 1
        }
        if nonzero && valid >= 2 {
          fmt.printfln("      obj=0x%X: %s", objs[i], strings.to_string(sb))
          shown += 1
          if shown >= 10 {
            break
          }
        }
      }
    }
    off += 4
  }
  fmt.println("(done)")
}

// Read-only recon: enumerate movers named <name> and report every field offset where
// at least 2 of them hold <value> - used to locate a known stat (e.g. a full mob's HP)
// by its value. Usage: objscan <value> <name>
cli_objscan :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 2 {
    fmt.eprintln("usage: objscan <value> <name>")
    return
  }
  val, valok := strconv.parse_i64(args[0])
  if !valok {
    fmt.eprintln("bad value.")
    return
  }
  name := strings.trim(strings.join(args[1:], " ", context.temp_allocator), "'\"")
  LEN :: 0x4000

  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  if !wok {
    fmt.eprintln("could not read world anchor.")
    return
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  wval := engine.ptr_to_value(world, session.ptr_size)
  all := engine.collect_regions(handle, true)
  defer delete(all)
  set := engine.scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)
  bufs := make([dynamic][]byte, context.temp_allocator)
  for m in set.matches {
    obj := uintptr(i64(m.addr) - session.layout.field_off)
    vt, vok := engine.read_value(handle, obj, pt)
    if !vok {
      continue
    }
    vtable := uintptr(engine.value_as_u64(pt, vt))
    if vtable < base || vtable >= mod_end {
      continue
    }
    if engine.read_obj_type(handle, obj, session.layout.pos_off) != session.layout.mover_type {
      continue
    }
    nm, nok := engine.read_obj_name(handle, session.ptr_size, obj, session.layout.name_off)
    if !nok || !strings.contains(nm, name) {
      continue
    }
    b := make([]byte, LEN, context.temp_allocator)
    engine.read_into(handle, obj, b)
    append(&bufs, b)
  }
  fmt.printfln("objscan %d in '%s': %d movers", val, name, len(bufs))
  target := u32(val)
  off := 0
  for off <= LEN - 4 {
    c := 0
    for b in bufs {
      if off + 4 <= len(b) {
        v := u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24
        if v == target {
          c += 1
        }
      }
    }
    if c >= 2 {
      // also show how many movers have it in [1, val] (HP-like) vs == 0
      hp_like, zero := 0, 0
      for b in bufs {
        if off + 4 <= len(b) {
          v := i64(u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24)
          if v == 0 {
            zero += 1
          } else if v > 0 && v <= val {
            hp_like += 1
          }
        }
      }
      fmt.printfln("  +0x%X: %d ==%d  (%d in 1..%d, %d ==0)", off, c, val, hp_like, val, zero)
    }
    off += 4
  }
  fmt.println("(done)")
}

// ---------------------------------------------------------------------------
// Parsing helpers
// ---------------------------------------------------------------------------

// Resolve a command operand to an absolute address. `[i]` refers to match #i (like
// 'peek'); anything else is parsed as an address (decimal or 0x-hex).
