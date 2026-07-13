package engine

import "core:fmt"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"

// ===========================================================================
// Generic CLI commands (any process). These operate purely on engine.Session's
// generic state; the Flyff-specific commands live in the flyff module and are
// reached through session.module_dispatch (see engine/repl.odin).
//
// attach/detach are the one place generic commands touch module state: they do
// the Win32 work themselves and route the module's per-process setup/teardown
// through the on_attach / on_detach hooks (the engine never imports flyff).
// ===========================================================================

cmd_ps :: proc(args: []string) {
  filter := ""
  if len(args) > 0 {
    filter = args[0]
  }
  results := find_process_id_by_name(filter, context.temp_allocator)
  fmt.printfln("%d process(es):", len(results))
  for r in results {
    fmt.printfln("  pid=%-6d  %-28s  %s", r.process_id, r.process_name, r.window_title)
  }
}

cmd_attach :: proc(session: ^Session, args: []string) {
  if len(args) < 1 {
    fmt.eprintln("usage: attach <name|pid>")
    return
  }

  pid: u32 = 0
  name := ""
  if is_all_digits(args[0]) {
    v, _ := strconv.parse_u64(args[0])
    pid = u32(v)
  } else {
    results := find_process_id_by_name(args[0], context.temp_allocator)
    if len(results) == 0 {
      fmt.eprintfln("no process matching '%s'", args[0])
      return
    }
    if len(results) > 1 {
      fmt.printfln("%d processes match '%s' - pick one by pid:", len(results), args[0])
      for r in results {
        fmt.printfln("  pid=%d  %s  %s", r.process_id, r.process_name, r.window_title)
      }
      return
    }
    pid = results[0].process_id
    name = results[0].process_name
  }

  access := win.PROCESS_VM_READ | win.PROCESS_VM_WRITE | win.PROCESS_VM_OPERATION | win.PROCESS_QUERY_INFORMATION
  handle := win.OpenProcess(u32(access), win.FALSE, pid)
  if handle == nil {
    fmt.eprintfln("OpenProcess failed for pid %d (error %d). Try running as administrator.", pid, win.GetLastError())
    return
  }

  base, size, mok := get_process_module_info(pid)
  if !mok {
    fmt.eprintfln("warning: could not read main module info for pid %d", pid)
  }

  is_wow: win.BOOL
  win.IsWow64Process(handle, &is_wow)

  if session.attached {
    // Let the module free the OLD process's resources on the still-open handle, then close it.
    if session.on_detach != nil {
      session.on_detach(session)
    }
    win.CloseHandle(session.proc_info.handle)
  }
  session_reset_scan(session)

  session.attached = true
  session.proc_info = Attached_Process {
    pid         = pid,
    name        = strings.clone(name),
    handle      = handle,
    base        = uintptr(base),
    module_size = size,
    is_wow64    = is_wow != win.FALSE,
  }
  if is_wow != win.FALSE {
    session.ptr_size = 4
  } else {
    session.ptr_size = 8
  }

  fmt.printfln(
    "attached pid=%d%s base=0x%X size=%d %s (ptr_size=%d)",
    pid,
    name != "" ? fmt.tprintf(" (%s)", name) : "",
    session.proc_info.base,
    size,
    is_wow != win.FALSE ? "WOW64/32-bit" : "64-bit",
    session.ptr_size,
  )

  // Module per-process setup (flyff: load flyff.cfg into the layout, srvsync default).
  if session.on_attach != nil {
    session.on_attach(session)
  }
}

cmd_detach :: proc(session: ^Session) {
  if !session.attached {
    fmt.println("not attached.")
    return
  }
  pid := session.proc_info.pid
  if session.on_detach != nil {
    session.on_detach(session) // module teardown (stop auto, free remote pages) on the live handle
  }
  win.CloseHandle(session.proc_info.handle)
  session_reset_scan(session)
  session.attached = false
  session.proc_info = {}
  fmt.printfln("detached from pid %d.", pid)
}

cmd_info :: proc(session: ^Session) {
  if !session.attached {
    fmt.println("not attached.")
    return
  }
  p := session.proc_info
  fmt.printfln("pid          : %d", p.pid)
  fmt.printfln("name         : %s", p.name)
  fmt.printfln("module base  : 0x%X", p.base)
  fmt.printfln("module size  : %d", p.module_size)
  fmt.printfln("bitness      : %s (ptr_size=%d)", p.is_wow64 ? "32-bit (WOW64)" : "64-bit", session.ptr_size)
  fmt.printfln("default type : %s", value_type_name(session.vtype))
  fmt.printfln("has snapshot : %v", session.has_snapshot)
  fmt.printfln("matches      : %v", session.has_matches ? len(session.matches.matches) : 0)
}

cmd_vtype :: proc(session: ^Session, args: []string) {
  if len(args) < 1 {
    fmt.printfln("current type: %s", value_type_name(session.vtype))
    return
  }
  if t, ok := parse_vtype(args[0]); ok {
    session.vtype = t
    fmt.printfln("type = %s", value_type_name(t))
  } else {
    fmt.eprintfln("unknown type '%s' (u8 i8 u16 i16 u32 i32 u64 i64 f32 f64)", args[0])
  }
}

cmd_ptrsize :: proc(session: ^Session, args: []string) {
  if len(args) < 1 {
    fmt.printfln("ptr_size = %d", session.ptr_size)
    return
  }
  if args[0] == "4" {
    session.ptr_size = 4
  } else if args[0] == "8" {
    session.ptr_size = 8
  } else {
    fmt.eprintln("usage: ptrsize <4|8>")
    return
  }
  fmt.printfln("ptr_size = %d", session.ptr_size)
}

cmd_scan :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: scan [type] <value>")
    return
  }
  t := session.vtype
  val_str := args[0]
  if len(args) >= 2 {
    if tt, ok := parse_vtype(args[0]); ok {
      t = tt
      val_str = args[1]
    }
  }
  target, ok := parse_value(t, val_str)
  if !ok {
    fmt.eprintfln("invalid %s value: %s", value_type_name(t), val_str)
    return
  }

  session_reset_scan(session)
  set := scan_exact(session.proc_info.handle, t, target, session.writable_only, session_scan_allocator(session))
  session.matches = set
  session.has_matches = true
  session.vtype = t
  fmt.printfln("scan(%s == %s): %d match(es)", value_type_name(t), val_str, len(set.matches))
}

cmd_snapshot :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  t := session.vtype
  if len(args) >= 1 {
    if tt, ok := parse_vtype(args[0]); ok {
      t = tt
    }
  }
  // Keep any existing match set alive (old snapshot, if any, is left in the arena).
  snap := take_snapshot(session.proc_info.handle, t, session.writable_only, session_scan_allocator(session))
  session.snapshot = snap
  session.has_snapshot = true
  session.vtype = t
  fmt.printfln(
    "snapshot(%s): %d region(s), %.1f MB. Change the value, then 'next changed'.",
    value_type_name(t),
    len(snap.regions),
    f64(snapshot_total_bytes(snap)) / (1024 * 1024),
  )
}

cmd_next :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: next <eq|ne|gt|lt|changed|unchanged|inc|dec> [value]")
    return
  }
  op, needs_val, ok := parse_op(args[0])
  if !ok {
    fmt.eprintfln("unknown comparator '%s'", args[0])
    return
  }

  target: Value
  has_target := false
  if needs_val {
    if len(args) < 2 {
      fmt.eprintfln("comparator '%s' needs a value", args[0])
      return
    }
    tv, vok := parse_value(session.vtype, args[1])
    if !vok {
      fmt.eprintfln("invalid value: %s", args[1])
      return
    }
    target = tv
    has_target = true
  }

  alloc := session_scan_allocator(session)
  new_set: Match_Set
  if session.has_matches {
    new_set = refine_matches(session.proc_info.handle, session.matches, op, target, has_target, alloc)
  } else if session.has_snapshot {
    new_set = refine_from_snapshot(session.proc_info.handle, session.snapshot, op, target, has_target, alloc)
  } else {
    fmt.eprintln("nothing to refine - run 'scan' or 'snapshot' first.")
    return
  }
  session.matches = new_set
  session.has_matches = true
  fmt.printfln("next(%s): %d match(es)", args[0], len(new_set.matches))
}

cmd_list :: proc(session: ^Session, args: []string) {
  if !session.has_matches {
    fmt.eprintln("no matches - run 'scan' or 'snapshot'+'next' first.")
    return
  }
  n := 20
  if len(args) >= 1 {
    if v, ok := strconv.parse_int(args[0]); ok {
      n = v
    }
  }
  m := session.matches
  count := len(m.matches)
  limit := min(n, count)
  fmt.printfln("%d match(es), showing %d:", count, limit)
  for i in 0 ..< limit {
    e := m.matches[i]
    fmt.printfln("  [%d] 0x%X = %s", i, e.addr, format_value(m.vtype, e.value))
  }
}

cmd_pointers :: proc(session: ^Session) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if !session.has_matches {
    fmt.eprintln("no matches.")
    return
  }
  before := len(session.matches.matches)
  set := filter_pointers(session.proc_info.handle, session.matches, session.ptr_size, session_scan_allocator(session))
  session.matches = set
  fmt.printfln("pointers: %d -> %d match(es)", before, len(set.matches))
}

cmd_count :: proc(session: ^Session) {
  if !session.has_matches {
    fmt.println("0 matches.")
    return
  }
  fmt.printfln("%d match(es)", len(session.matches.matches))
}

cmd_read :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: read <addr> [type]")
    return
  }
  addr, ok := parse_addr(args[0])
  if !ok {
    fmt.eprintfln("invalid address: %s", args[0])
    return
  }
  t := session.vtype
  if len(args) >= 2 {
    if tt, tok := parse_vtype(args[1]); tok {
      t = tt
    }
  }
  v, rok := read_value(session.proc_info.handle, addr, t)
  if !rok {
    fmt.eprintfln("read failed at 0x%X", addr)
    return
  }
  fmt.printfln("0x%X = %s", addr, format_value(t, v))
}

cmd_write :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 2 {
    fmt.eprintln("usage: write <addr> <value> [type]")
    return
  }
  addr, ok := parse_addr(args[0])
  if !ok {
    fmt.eprintfln("invalid address: %s", args[0])
    return
  }
  t := session.vtype
  if len(args) >= 3 {
    if tt, tok := parse_vtype(args[2]); tok {
      t = tt
    }
  }
  val, vok := parse_value(t, args[1])
  if !vok {
    fmt.eprintfln("invalid %s value: %s", value_type_name(t), args[1])
    return
  }
  if write_value(session.proc_info.handle, addr, t, val) {
    fmt.printfln("wrote 0x%X = %s", addr, format_value(t, val))
  } else {
    fmt.eprintfln("write failed at 0x%X (error %d)", addr, win.GetLastError())
  }
}

cmd_peek :: proc(session: ^Session, args: []string) {
  if !session.has_matches {
    fmt.eprintln("no matches.")
    return
  }
  idx := 0
  if len(args) >= 1 {
    if v, ok := strconv.parse_int(args[0]); ok {
      idx = v
    }
  }
  if idx < 0 || idx >= len(session.matches.matches) {
    fmt.eprintfln("index %d out of range (0..%d)", idx, len(session.matches.matches) - 1)
    return
  }
  m := session.matches.matches[idx]
  v, rok := read_value(session.proc_info.handle, m.addr, session.matches.vtype)
  if !rok {
    fmt.eprintfln("read failed at 0x%X", m.addr)
    return
  }
  fmt.printfln("[%d] 0x%X = %s", idx, m.addr, format_value(session.matches.vtype, v))
}

cmd_poke :: proc(session: ^Session, args: []string) {
  if !session.has_matches {
    fmt.eprintln("no matches.")
    return
  }
  // forms: 'poke <value>'  or  'poke <index> <value>'
  idx := 0
  val_str := ""
  if len(args) == 1 {
    val_str = args[0]
  } else if len(args) >= 2 {
    if v, ok := strconv.parse_int(args[0]); ok {
      idx = v
    }
    val_str = args[1]
  } else {
    fmt.eprintln("usage: poke [index] <value>")
    return
  }
  if idx < 0 || idx >= len(session.matches.matches) {
    fmt.eprintfln("index %d out of range (0..%d)", idx, len(session.matches.matches) - 1)
    return
  }
  t := session.matches.vtype
  val, vok := parse_value(t, val_str)
  if !vok {
    fmt.eprintfln("invalid %s value: %s", value_type_name(t), val_str)
    return
  }
  addr := session.matches.matches[idx].addr
  if write_value(session.proc_info.handle, addr, t, val) {
    fmt.printfln("poked [%d] 0x%X = %s", idx, addr, format_value(t, val))
  } else {
    fmt.eprintfln("write failed at 0x%X (error %d)", addr, win.GetLastError())
  }
}

cmd_deref :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: deref <addr> [offset ...]")
    return
  }
  base, ok := parse_addr(args[0])
  if !ok {
    fmt.eprintfln("invalid address: %s", args[0])
    return
  }
  offsets := make([dynamic]i64, context.temp_allocator)
  for i in 1 ..< len(args) {
    off, ook := parse_offset(args[i])
    if !ook {
      fmt.eprintfln("invalid offset: %s", args[i])
      return
    }
    append(&offsets, off)
  }
  addr, dok := deref_chain(session.proc_info.handle, base, offsets[:], session.ptr_size)
  if !dok {
    fmt.eprintfln("deref failed (stopped at 0x%X)", addr)
    return
  }
  fmt.printfln("-> 0x%X", addr)
  if v, rok := read_value(session.proc_info.handle, addr, session.vtype); rok {
    fmt.printfln("   [%s] = %s", value_type_name(session.vtype), format_value(session.vtype, v))
  }
}

cmd_dump :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: dump <addr|[i]> [len]")
    return
  }
  addr, ok := resolve_operand(session, args[0])
  if !ok {
    fmt.eprintfln("invalid address/index: %s", args[0])
    return
  }
  length := 128
  if len(args) >= 2 {
    if v, vok := strconv.parse_int(args[1]); vok && v > 0 {
      length = v
    }
  }
  buf := make([]byte, length, context.temp_allocator)
  n, rok := read_into(session.proc_info.handle, addr, buf)
  if !rok || n == 0 {
    fmt.eprintfln("read failed at 0x%X", addr)
    return
  }
  fmt.printfln("0x%X (%d bytes):", addr, n)
  rows := (int(n) + 15) / 16
  for row in 0 ..< rows {
    off := row * 16
    b := strings.builder_make(context.temp_allocator)
    fmt.sbprintf(&b, "  +0x%03X ", off)
    for c in 0 ..< 16 {
      if off + c < int(n) {
        fmt.sbprintf(&b, "%02X ", buf[off + c])
      } else {
        fmt.sbprint(&b, "   ")
      }
      if c == 7 {
        fmt.sbprint(&b, " ")
      }
    }
    fmt.sbprint(&b, "| f32:")
    for c := 0; c + 4 <= 16; c += 4 {
      if off + c + 4 <= int(n) {
        u :=
          u32(buf[off + c]) |
          u32(buf[off + c + 1]) << 8 |
          u32(buf[off + c + 2]) << 16 |
          u32(buf[off + c + 3]) << 24
        // Right-align in a fixed column with spaces ('%11.3f' zero-pads in Odin).
        fs := fmt.tprintf("%.3f", transmute(f32)u)
        for _ in len(fs) ..< 12 {
          fmt.sbprint(&b, " ")
        }
        fmt.sbprintf(&b, "%s", fs)
      }
    }
    fmt.println(strings.to_string(b))
  }
}

cmd_dist :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 2 {
    fmt.eprintln("usage: dist <addrA|[i]> <addrB|[j]>")
    return
  }
  a, aok := resolve_operand(session, args[0])
  b, bok := resolve_operand(session, args[1])
  if !aok || !bok {
    fmt.eprintln("invalid address/index")
    return
  }
  va, vaok := read_vec3(session.proc_info.handle, a)
  vb, vbok := read_vec3(session.proc_info.handle, b)
  if !vaok || !vbok {
    fmt.eprintln("read failed")
    return
  }
  fmt.printfln("A 0x%X = (%.3f, %.3f, %.3f)", a, va[0], va[1], va[2])
  fmt.printfln("B 0x%X = (%.3f, %.3f, %.3f)", b, vb[0], vb[1], vb[2])
  fmt.printfln("d(x,z) = %.3f   d(3d) = %.3f", dist_horizontal(va, vb), dist_3d(va, vb))
}

cmd_nearest :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: nearest list    <start|[i]> <next_off> <pos_off> <player> [max]")
    fmt.eprintln("       nearest array   <base|[i]> <count> <stride> <pos_off> <player>")
    fmt.eprintln("       nearest matches <field_off> <pos_off> <player>")
    fmt.eprintln("  <player> = address | [i] | literal x,y,z (no spaces)")
    return
  }
  handle := session.proc_info.handle
  rest := args[1:]
  entries: [dynamic]Nearest_Entry

  switch args[0] {
  case "list":
    if len(rest) < 4 {
      fmt.eprintln("usage: nearest list <start|[i]> <next_off> <pos_off> <player|[j]> [max]")
      return
    }
    start, sok := resolve_operand(session, rest[0])
    next_off, nok := parse_offset(rest[1])
    pos_off, pok := parse_offset(rest[2])
    player_pos, plok := resolve_player_pos(session, rest[3])
    if !sok || !nok || !pok || !plok {
      fmt.eprintln("invalid argument")
      return
    }
    max_nodes := 512
    if len(rest) >= 5 {
      if v, vok := strconv.parse_int(rest[4]); vok && v > 0 {
        max_nodes = v
      }
    }
    entries = enumerate_nearest(
      handle,
      session.ptr_size,
      .List,
      start,
      pos_off,
      player_pos,
      next_off,
      max_nodes,
      0,
      0,
    )
  case "array":
    if len(rest) < 5 {
      fmt.eprintln("usage: nearest array <base|[i]> <count> <stride> <pos_off> <player|[j]>")
      return
    }
    base, bok := resolve_operand(session, rest[0])
    count, cok := strconv.parse_int(rest[1])
    stride, stok := parse_offset(rest[2])
    pos_off, pok := parse_offset(rest[3])
    player_pos, plok := resolve_player_pos(session, rest[4])
    if !bok || !cok || !stok || !pok || !plok {
      fmt.eprintln("invalid argument")
      return
    }
    entries = enumerate_nearest(
      handle,
      session.ptr_size,
      .Array,
      base,
      pos_off,
      player_pos,
      0,
      0,
      count,
      stride,
    )
  case "matches":
    if !session.has_matches {
      fmt.eprintln("no matches - run e.g. 'scan u32 <world_ptr>' first.")
      return
    }
    if len(rest) < 3 {
      fmt.eprintln("usage: nearest matches <field_off> <pos_off> <player|[j]>")
      return
    }
    field_off, fok := parse_offset(rest[0])
    pos_off, pok := parse_offset(rest[1])
    player_pos, plok := resolve_player_pos(session, rest[2])
    if !fok || !pok || !plok {
      fmt.eprintln("invalid argument")
      return
    }
    entries = rank_object_matches(
      handle,
      session.ptr_size,
      session.matches.matches[:],
      field_off,
      pos_off,
      player_pos,
      session.proc_info.base,
      session.proc_info.module_size,
    )
  case:
    fmt.eprintfln("unknown nearest mode '%s' (list|array|matches)", args[0])
    return
  }

  delete(session.targets)
  session.targets = entries

  fmt.printfln("%d entit(ies), nearest first:", len(entries))
  limit := min(len(entries), 20)
  for i in 0 ..< limit {
    e := entries[i]
    fmt.printfln(
      "  [%d] obj=0x%X type=%d pos=(%.1f, %.1f, %.1f) d=%.2f (h=%.2f)",
      i,
      e.obj_ptr,
      e.dtype,
      e.pos[0],
      e.pos[1],
      e.pos[2],
      e.dist,
      e.dist_h,
    )
  }
}

cmd_target :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(session.targets) == 0 {
    fmt.eprintln("no targets - run 'nearest' first.")
    return
  }
  if len(args) < 2 {
    fmt.eprintln("usage: target <focus_addr|[i]> <rank>")
    return
  }
  focus, fok := resolve_operand(session, args[0])
  if !fok {
    fmt.eprintfln("invalid focus address/index: %s", args[0])
    return
  }
  rank, rok := strconv.parse_int(args[1])
  if !rok || rank < 0 || rank >= len(session.targets) {
    fmt.eprintfln("invalid rank (0..%d)", len(session.targets) - 1)
    return
  }
  obj := session.targets[rank].obj_ptr
  t := Value_Type.U64
  if session.ptr_size == 4 {
    t = .U32
  }
  // Liveness re-check: a pointer that was valid when 'nearest' ran may have been
  // freed since. Handing a dead pointer to the game as a target crashes the client,
  // so verify the object still starts with a module-range vtable before writing.
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  vt, vok := read_value(session.proc_info.handle, obj, t)
  vtable := uintptr(value_as_u64(t, vt))
  if !vok || vtable < base || vtable >= mod_end {
    fmt.eprintfln("refusing: obj 0x%X is no longer a live object - re-run 'nearest' for fresh pointers.", obj)
    return
  }
  val: Value
  u := u64(obj)
  for i in 0 ..< value_size(t) {
    val[i] = byte(u >> uint(8 * i))
  }
  if write_value(session.proc_info.handle, focus, t, val) {
    fmt.printfln("selected rank %d obj=0x%X (type=%d) -> focus 0x%X", rank, obj, session.targets[rank].dtype, focus)
  } else {
    fmt.eprintfln("write failed at 0x%X (error %d)", focus, win.GetLastError())
  }
}

cmd_find :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: find <text>")
    return
  }
  text := strings.trim(strings.join(args, " ", context.temp_allocator), "'\"")
  if len(text) == 0 {
    fmt.eprintln("usage: find <text>")
    return
  }
  asc := make([]byte, len(text), context.temp_allocator)
  copy(asc, text)
  wide := make([]byte, len(text) * 2, context.temp_allocator)
  for i in 0 ..< len(text) {
    wide[i * 2] = text[i]
  }
  ha := scan_bytes(session.proc_info.handle, asc, context.temp_allocator)
  hw := scan_bytes(session.proc_info.handle, wide, context.temp_allocator)
  fmt.printfln("find %q: %d ascii, %d utf-16 hit(s)", text, len(ha), len(hw))
  for h, i in ha {
    if i >= 200 {
      break
    }
    fmt.printfln("  ascii 0x%X", h)
  }
  for h, i in hw {
    if i >= 20 {
      break
    }
    fmt.printfln("  utf16 0x%X", h)
  }
}

cmd_version :: proc(session: ^Session) {
  fmt.printfln("memscan v%s (build %s)", session.app_version, session.app_build_hash)
}

// ===========================================================================
// Operand / argument parsing helpers (shared by the generic commands)
// ===========================================================================

resolve_operand :: proc(session: ^Session, s: string) -> (addr: uintptr, ok: bool) {
  if strings.has_prefix(s, "[") && strings.has_suffix(s, "]") {
    idx, iok := strconv.parse_int(s[1:len(s) - 1])
    if !iok || !session.has_matches || idx < 0 || idx >= len(session.matches.matches) {
      return 0, false
    }
    return session.matches.matches[idx].addr, true
  }
  // `+<rva>` is base-relative (module base + rva) - stays valid across re-attaches/rebases, so
  // addresses from codescan's `Neuz.exe+0xRVA` labels can be reused directly as `+0xRVA`.
  if strings.has_prefix(s, "+") {
    if !session.attached {
      return 0, false
    }
    v, vok := parse_addr(s[1:])
    if !vok {
      return 0, false
    }
    return session.proc_info.base + uintptr(v), true
  }
  return parse_addr(s)
}

// Resolve a player-position operand: a literal "x,y,z" (comma-separated, no spaces -
// handy with the in-game /position readout), or an address/[i] whose 3 f32 are read live.
resolve_player_pos :: proc(session: ^Session, s: string) -> (pos: [3]f32, ok: bool) {
  if strings.contains(s, ",") {
    parts := strings.split(s, ",", context.temp_allocator)
    if len(parts) != 3 {
      return {}, false
    }
    for p, i in parts {
      v, vok := strconv.parse_f64(strings.trim_space(p))
      if !vok {
        return {}, false
      }
      pos[i] = f32(v)
    }
    return pos, true
  }
  addr, aok := resolve_operand(session, s)
  if !aok {
    return {}, false
  }
  return read_vec3(session.proc_info.handle, addr)
}

is_all_digits :: proc(s: string) -> bool {
  if len(s) == 0 {
    return false
  }
  for c in s {
    if c < '0' || c > '9' {
      return false
    }
  }
  return true
}

parse_vtype :: proc(s: string) -> (Value_Type, bool) {
  switch s {
  case "u8":
    return .U8, true
  case "i8":
    return .I8, true
  case "u16":
    return .U16, true
  case "i16":
    return .I16, true
  case "u32":
    return .U32, true
  case "i32":
    return .I32, true
  case "u64":
    return .U64, true
  case "i64":
    return .I64, true
  case "f32":
    return .F32, true
  case "f64":
    return .F64, true
  }
  return .U32, false
}

parse_op :: proc(s: string) -> (op: Compare_Op, needs_value: bool, ok: bool) {
  switch s {
  case "eq", "==":
    return .Eq, true, true
  case "ne", "!=":
    return .Ne, true, true
  case "gt", ">":
    return .Gt, true, true
  case "lt", "<":
    return .Lt, true, true
  case "changed", "ch":
    return .Changed, false, true
  case "unchanged", "un":
    return .Unchanged, false, true
  case "inc", "increased", "+":
    return .Increased, false, true
  case "dec", "decreased", "-":
    return .Decreased, false, true
  }
  return .Eq, false, false
}
