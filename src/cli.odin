package main

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import win "core:sys/windows"
import "core:time"

run_cli :: proc(session: ^Session) {
  fmt.println("memscan - type 'help' for commands, 'quit' to exit.")
  line_buf: [1024]byte
  for {
    fmt.print("memscan> ")
    line, ok := cli_read_line(line_buf[:])
    if !ok {
      break // EOF
    }
    line = strings.trim_space(line)
    if line == "" {
      continue
    }
    // Serialize with the hotkey watcher thread (see hotkey.odin).
    sync.mutex_lock(&session.exec_mutex)
    quit := cli_execute_line(session, line)
    sync.mutex_unlock(&session.exec_mutex)
    if quit {
      break
    }
  }
  fmt.println("bye.")
}

// Run one input line (possibly several commands chained with ';' or '&&', which run
// sequentially without short-circuiting). Shared by the REPL and the hotkey watcher;
// callers must hold session.exec_mutex. Returns true if a 'quit' command ran.
cli_execute_line :: proc(session: ^Session, line: string) -> (quit: bool) {
  normalized, _ := strings.replace_all(line, "&&", ";", context.temp_allocator)
  segments := strings.split(normalized, ";", context.temp_allocator)
  for seg in segments {
    s := strings.trim_space(seg)
    if s == "" {
      continue
    }
    args := strings.fields(s, context.temp_allocator)
    if len(args) == 0 {
      continue
    }
    if cli_dispatch(session, args[0], args[1:]) {
      quit = true
      break
    }
  }
  free_all(context.temp_allocator)
  return
}

cli_read_line :: proc(buf: []byte) -> (line: string, ok: bool) {
  i := 0
  one: [1]byte
  for i < len(buf) {
    n, _ := os.read(os.stdin, one[:])
    if n <= 0 {
      if i == 0 {
        return "", false
      }
      break
    }
    if one[0] == '\n' {
      break
    }
    if one[0] != '\r' {
      buf[i] = one[0]
      i += 1
    }
  }
  return string(buf[:i]), true
}

cli_dispatch :: proc(session: ^Session, cmd: string, args: []string) -> (quit: bool) {
  switch cmd {
  case "help", "?":
    cli_help()
  case "quit", "exit", "q":
    return true
  case "ps":
    cli_ps(args)
  case "attach":
    cli_attach(session, args)
  case "detach":
    cli_detach(session)
  case "info":
    cli_info(session)
  case "vtype", "type":
    cli_vtype(session, args)
  case "ptrsize":
    cli_ptrsize(session, args)
  case "scan", "s":
    cli_scan(session, args)
  case "snapshot", "snap":
    cli_snapshot(session, args)
  case "next", "n":
    cli_next(session, args)
  case "list", "ls":
    cli_list(session, args)
  case "count":
    cli_count(session)
  case "pointers", "ptr":
    cli_pointers(session)
  case "clearmatches", "cm":
    session_clear_matches(session)
    fmt.println("matches cleared (snapshot kept).")
  case "reset":
    session_reset_scan(session)
    fmt.println("scan state reset.")
  case "read", "r":
    cli_read(session, args)
  case "write", "w":
    cli_write(session, args)
  case "peek":
    cli_peek(session, args)
  case "poke":
    cli_poke(session, args)
  case "deref", "d":
    cli_deref(session, args)
  case "dump", "x":
    cli_dump(session, args)
  case "dist":
    cli_dist(session, args)
  case "nearest", "near":
    cli_nearest(session, args)
  case "target", "tgt":
    cli_target(session, args)
  case "find":
    cli_find(session, args)
  case "target_closest", "tc", "get":
    cli_target_closest(session, args)
  case "hotkey", "hk":
    cli_hotkey(session, args)
  case "deathscan":
    cli_deathscan(session, args)
  case "objscan":
    cli_objscan(session, args)
  case "mobs":
    cli_mobs(session, args)
  case:
    fmt.eprintfln("unknown command: %s (try 'help')", cmd)
  }
  return false
}

cli_help :: proc() {
  fmt.println(`commands:
  ps [filter]                list processes (optionally filtered by name)
  attach <name|pid>          open a process for read/write
  detach                     close the attached process handle
  info                       show attached process details
  vtype <t>                  set default value type (u8 i8 u16 i16 u32 i32 u64 i64 f32 f64)
  ptrsize <4|8>              pointer width used by 'deref'
  scan [t] <value>           exact-value scan, replaces match set
  snapshot [t]               capture memory for an unknown-initial search
  next <op> [value]          refine matches/snapshot; op = eq ne gt lt changed unchanged inc dec
  list [n]                   show first n matches (default 20)
  count                      show number of matches
  pointers                   keep only matches whose value is a valid heap pointer
  clearmatches               drop matches but keep snapshot
  reset                      clear all scan state
  read  <addr> [t]           read a value at an absolute address
  write <addr> <value> [t]   write a value at an absolute address
  peek  [i]                  read match #i live (default 0)
  poke  [i] <value>          write <value> to match #i (default i=0)
  deref <addr> [off ...]     follow a pointer chain, show the final address+value
  dump  <addr|[i]> [len]      hex dump len bytes (default 128) with an f32 column
  dist  <a|[i]> <b|[j]>       distance between two vec3 (3x f32) positions
  nearest list    <start|[i]> <next_off> <pos_off> <player> [max]
  nearest array   <base|[i]> <count> <stride> <pos_off> <player>
  nearest matches <field_off> <pos_off> <player>   (each match = obj+field_off)
                             enumerate entities ranked by distance to player;
                             <player> = address | [i] | literal x,y,z (no spaces)
  target <focus|[i]> <rank>  write nearest[rank]'s obj ptr into the focus address
  find  <text>               search readable memory for a string (ASCII + UTF-16)
  target_closest <name>      select the nearest mover named <name> (Flyff; one-shot).
                             repeat to toggle the two closest: #1 <-> #2
  hotkey <command>           press a key when prompted to bind it to <command>; fires
                             globally even while memscan is backgrounded.
                             also: 'hotkey list', 'hotkey clear'
  quit                       exit

chain multiple commands on one line with ';' or '&&', e.g.
  write 0x18D0E04 0x1EDCF820 u32; write 0x1A828B48 0x1EDCF820 u32`)
}

cli_ps :: proc(args: []string) {
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

cli_attach :: proc(session: ^Session, args: []string) {
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
      fmt.printfln("%d processes match '%s' — pick one by pid:", len(results), args[0])
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
}

cli_detach :: proc(session: ^Session) {
  if !session.attached {
    fmt.println("not attached.")
    return
  }
  pid := session.proc_info.pid
  win.CloseHandle(session.proc_info.handle)
  session_reset_scan(session)
  session.attached = false
  session.proc_info = {}
  fmt.printfln("detached from pid %d.", pid)
}

cli_info :: proc(session: ^Session) {
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

cli_vtype :: proc(session: ^Session, args: []string) {
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

cli_ptrsize :: proc(session: ^Session, args: []string) {
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

cli_scan :: proc(session: ^Session, args: []string) {
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

cli_snapshot :: proc(session: ^Session, args: []string) {
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

cli_next :: proc(session: ^Session, args: []string) {
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
    fmt.eprintln("nothing to refine — run 'scan' or 'snapshot' first.")
    return
  }
  session.matches = new_set
  session.has_matches = true
  fmt.printfln("next(%s): %d match(es)", args[0], len(new_set.matches))
}

cli_list :: proc(session: ^Session, args: []string) {
  if !session.has_matches {
    fmt.eprintln("no matches — run 'scan' or 'snapshot'+'next' first.")
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

cli_pointers :: proc(session: ^Session) {
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

cli_count :: proc(session: ^Session) {
  if !session.has_matches {
    fmt.println("0 matches.")
    return
  }
  fmt.printfln("%d match(es)", len(session.matches.matches))
}

cli_read :: proc(session: ^Session, args: []string) {
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

cli_write :: proc(session: ^Session, args: []string) {
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

cli_peek :: proc(session: ^Session, args: []string) {
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

cli_poke :: proc(session: ^Session, args: []string) {
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

cli_deref :: proc(session: ^Session, args: []string) {
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

cli_dump :: proc(session: ^Session, args: []string) {
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

cli_dist :: proc(session: ^Session, args: []string) {
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

cli_nearest :: proc(session: ^Session, args: []string) {
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
      fmt.eprintln("no matches — run e.g. 'scan u32 <world_ptr>' first.")
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

cli_target :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(session.targets) == 0 {
    fmt.eprintln("no targets — run 'nearest' first.")
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
    fmt.eprintfln("refusing: obj 0x%X is no longer a live object — re-run 'nearest' for fresh pointers.", obj)
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

cli_find :: proc(session: ^Session, args: []string) {
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

TC_Cand :: struct {
  obj: uintptr,
  d:   f32,
}

// A mob target_closest recently selected. We skip these for TC_RECENT_NS so a just-killed
// mob (which keeps reading as alive while it plays its death/despawn animation) isn't
// immediately re-selected. See the crash/death notes: there's no reliable in-memory "dead"
// flag we can read, so we avoid re-picking what we just picked instead.
TC_Recent :: struct {
  obj: uintptr,
  t:   i64, // time.now()._nsec when picked
}
TC_RECENT_NS :: i64(6_000_000_000) // ~6s, a bit longer than the corpse despawn delay

tc_seen_recently :: proc(session: ^Session, obj: uintptr, now: i64) -> bool {
  for r in session.tc_recent {
    if r.obj == obj && now - r.t < TC_RECENT_NS {
      return true
    }
  }
  return false
}

tc_mark_recent :: proc(session: ^Session, obj: uintptr, now: i64) {
  i := 0
  for i < len(session.tc_recent) {
    r := session.tc_recent[i]
    if r.obj == obj || now - r.t >= TC_RECENT_NS {
      unordered_remove(&session.tc_recent, i) // drop the old entry for obj + any expired
    } else {
      i += 1
    }
  }
  append(&session.tc_recent, TC_Recent{obj = obj, t = now})
}

// Debug: append everything we know about the object we're about to select to
// tc_targets.log (in the cwd), flushed before the focus write. The GAME crashes on a
// bad selection, not memscan, so memscan survives and the LAST entry in the log is
// whatever we targeted right before the crash. Remove once the crash is understood.
log_target :: proc(session: ^Session, obj: uintptr, world: uintptr, sel, total: int) {
  handle := session.proc_info.handle
  pt := Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  rdp :: proc(handle: win.HANDLE, addr: uintptr, pt: Value_Type) -> uintptr {
    v, ok := read_value(handle, addr, pt)
    return ok ? uintptr(value_as_u64(pt, v)) : 0
  }
  rdi :: proc(handle: win.HANDLE, addr: uintptr) -> i32 {
    v, ok := read_value(handle, addr, .U32)
    return ok ? i32(u32(value_as_u64(.U32, v))) : -1
  }
  dumprow :: proc(sb: ^strings.Builder, handle: win.HANDLE, addr: uintptr, off: uintptr, n: int) {
    b := make([]byte, n, context.temp_allocator)
    rn, ok := read_into(handle, addr + off, b)
    fmt.sbprintf(sb, "  +0x%04X:", off)
    if ok {
      for i in 0 ..< int(rn) {
        fmt.sbprintf(sb, " %02X", b[i])
      }
    } else {
      fmt.sbprint(sb, " <read failed>")
    }
    fmt.sbprint(sb, "\n")
  }

  name, _ := read_obj_name(handle, session.ptr_size, obj, FLYFF_NAME_OFF)
  pos, _ := read_vec3(handle, obj + FLYFF_POS_OFF)
  mpw := rdp(handle, obj + FLYFF_FIELD_OFF, pt)
  prev := rdp(handle, world + FLYFF_FOCUS_OFF, pt)

  sb := strings.builder_make(context.temp_allocator)
  fmt.sbprintfln(&sb, "--- target obj=0x%X '%s' #%d/%d (prevFocus=0x%X) ---", obj, name, sel + 1, total, prev)
  fmt.sbprintfln(
    &sb,
    "  type=%d vtable=0x%X mpWorld=0x%X(want 0x%X%s) hp=%d max=%d pos=%.1f,%.1f,%.1f",
    read_obj_type(handle, obj, FLYFF_POS_OFF),
    rdp(handle, obj, pt),
    mpw,
    world,
    mpw == world ? "" : " MISMATCH",
    rdi(handle, obj + FLYFF_HP_OFF),
    rdi(handle, obj + 0x814),
    pos[0],
    pos[1],
    pos[2],
  )
  dumprow(&sb, handle, obj, 0x0, 0x30) // vtable + early pointers
  dumprow(&sb, handle, obj, 0x160, 0x20) // pos/world/type/index/model
  dumprow(&sb, handle, obj, 0x800, 0x20) // maxHP region
  dumprow(&sb, handle, obj, 0x2800, 0x140) // currentHP (+0x281C) + despawn-timer region

  fd, err := os.open("tc_targets.log", os.O_WRONLY | os.O_CREATE | os.O_APPEND)
  if err == os.ERROR_NONE {
    os.write_string(fd, strings.to_string(sb))
    os.close(fd)
  }
}

// Scan for objects and return the selectable (alive + rendered) movers named <name>,
// nearest first. Enumerates ALL writable regions fresh every call — complete regardless
// of spawns/zoning (the old region cache went stale and missed most of a big spawn). A
// candidate must be a live object (vtable in module), a mover (type 5), name-match, have
// currentHP > 0, and a mapped m_pModel (a model-less mob crashes the client on select).
tc_collect_cands :: proc(
  session: ^Session,
  name: string,
  world: uintptr,
  player_pos: [3]f32,
) -> [dynamic]TC_Cand {
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  pt := Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wval := ptr_to_value(world, session.ptr_size)
  regions := collect_regions(handle, true) // all writable — complete, no stale cache
  defer delete(regions)
  set := scan_exact_parallel(handle, pt, wval, regions[:], context.temp_allocator) // multithreaded

  cands := make([dynamic]TC_Cand, context.temp_allocator)
  for m in set.matches {
    obj := uintptr(i64(m.addr) - FLYFF_FIELD_OFF)
    vt, vok := read_value(handle, obj, pt)
    if !vok {
      continue
    }
    vtable := uintptr(value_as_u64(pt, vt))
    if vtable < base || vtable >= mod_end {
      continue // not a live object
    }
    if read_obj_type(handle, obj, FLYFF_POS_OFF) != FLYFF_MOVER_TYPE {
      continue // movers only
    }
    nm, nok := read_obj_name(handle, session.ptr_size, obj, FLYFF_NAME_OFF)
    if !nok || !strings.equal_fold(nm, name) {
      continue
    }
    pos, posok := read_vec3(handle, obj + FLYFF_POS_OFF)
    if !posok {
      continue
    }
    // skip dying-but-not-despawned mobs (currentHP <= 0)
    if hpv, hok := read_value(handle, obj + FLYFF_HP_OFF, .U32); hok {
      if i32(u32(value_as_u64(.U32, hpv))) <= 0 {
        continue
      }
    }
    // require a live, mapped model — selecting a model-less mob crashes the client
    model: uintptr = 0
    if mv, mok := read_value(handle, obj + FLYFF_MODEL_OFF, pt); mok {
      model = uintptr(value_as_u64(pt, mv))
    }
    if model < 0x10000 {
      continue
    }
    if _, mok2 := read_value(handle, model, pt); !mok2 {
      continue
    }
    append(&cands, TC_Cand{obj = obj, d = dist_3d(pos, player_pos)})
  }
  slice.sort_by(cands[:], proc(a, b: TC_Cand) -> bool {return a.d < b.d})
  return cands
}

// One-shot: enumerate live objects, keep movers whose inline name matches <name>,
// rank them by distance, and write one into m_pObjFocus — atomically, so the pick
// can't go stale between ranking and selecting. Toggles between the two closest: if
// the closest is already selected, pick the second-closest; otherwise pick the
// closest. So repeated presses alternate #1 <-> #2. All anchors/offsets are baked
// Flyff constants, so it needs no setup: `target_closest Mutant Yetti`.
cli_target_closest :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: target_closest <name>")
    return
  }
  name := strings.trim(strings.join(args, " ", context.temp_allocator), "'\"")
  if len(name) == 0 {
    fmt.eprintln("usage: target_closest <name>")
    return
  }

  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }

  // Resolve world + player from the static anchors.
  wv, wok := read_value(handle, base + FLYFF_WORLD_RVA, pt)
  pv, pok := read_value(handle, base + FLYFF_PLAYER_RVA, pt)
  if !wok || !pok {
    fmt.eprintln("could not read world/player anchors (wrong build or not in-game?).")
    return
  }
  world := uintptr(value_as_u64(pt, wv))
  player := uintptr(value_as_u64(pt, pv))
  focus_addr := world + FLYFF_FOCUS_OFF
  player_pos, ppok := read_vec3(handle, player + FLYFF_POS_OFF)
  if !ppok {
    fmt.eprintln("could not read player position.")
    return
  }

  // Collect selectable (alive + rendered) movers named <name>, nearest first.
  cands := tc_collect_cands(session, name, world, player_pos)
  if len(cands) == 0 {
    fmt.printfln("no '%s' found.", name)
    return
  }

  // Pick the nearest mob we haven't targeted in the last few seconds. A just-killed mob
  // can keep reading as alive (HP unchanged, model still valid) while it plays its death
  // animation, so picking the strict closest would re-select the corpse. Skipping recent
  // picks advances to the next mob after each kill; fall back to the closest if every
  // nearby mob is on cooldown.
  now := time.now()._nsec
  chosen := cands[0]
  sel := 0
  for c, i in cands {
    if !tc_seen_recently(session, c.obj, now) {
      chosen = c
      sel = i
      break
    }
  }
  tc_mark_recent(session, chosen.obj, now)

  log_target(session, chosen.obj, world, sel, len(cands))
  if write_value(handle, focus_addr, pt, ptr_to_value(chosen.obj, session.ptr_size)) {
    fmt.printfln(
      "targeted '%s' #%d/%d obj=0x%X at d=%.1f.",
      name,
      sel + 1,
      len(cands),
      chosen.obj,
      chosen.d,
    )
  } else {
    fmt.eprintfln("write failed at focus 0x%X (error %d)", focus_addr, win.GetLastError())
  }
}

// Read-only: list movers named <name> by distance with HP and model-pointer validity.
// Never writes focus. Handy to see what target_closest will/won't consider selectable.
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
  pt := Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wv, wok := read_value(handle, base + FLYFF_WORLD_RVA, pt)
  pv, pok := read_value(handle, base + FLYFF_PLAYER_RVA, pt)
  if !wok || !pok {
    fmt.eprintln("could not read world/player anchors.")
    return
  }
  world := uintptr(value_as_u64(pt, wv))
  player := uintptr(value_as_u64(pt, pv))
  player_pos, _ := read_vec3(handle, player + FLYFF_POS_OFF)
  wval := ptr_to_value(world, session.ptr_size)
  all := collect_regions(handle, true)
  defer delete(all)
  set := scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)

  Row :: struct {
    obj:      uintptr,
    d:        f32,
    hp:       i32,
    model:    uintptr,
    model_ok: bool,
  }
  rows := make([dynamic]Row, context.temp_allocator)
  for m in set.matches {
    obj := uintptr(i64(m.addr) - FLYFF_FIELD_OFF)
    vt, vok := read_value(handle, obj, pt)
    if !vok {
      continue
    }
    vtable := uintptr(value_as_u64(pt, vt))
    if vtable < base || vtable >= mod_end {
      continue
    }
    if read_obj_type(handle, obj, FLYFF_POS_OFF) != FLYFF_MOVER_TYPE {
      continue
    }
    nm, nok := read_obj_name(handle, session.ptr_size, obj, FLYFF_NAME_OFF)
    if !nok || !strings.contains(nm, name) {
      continue
    }
    pos, posok := read_vec3(handle, obj + FLYFF_POS_OFF)
    if !posok {
      continue
    }
    hp: i32 = -1
    if hv, hok := read_value(handle, obj + FLYFF_HP_OFF, .U32); hok {
      hp = i32(u32(value_as_u64(.U32, hv)))
    }
    model: uintptr = 0
    if mv, mok := read_value(handle, obj + FLYFF_MODEL_OFF, pt); mok {
      model = uintptr(value_as_u64(pt, mv))
    }
    model_ok := false
    if model >= 0x10000 {
      if _, r := read_value(handle, model, pt); r {
        model_ok = true
      }
    }
    append(&rows, Row{obj = obj, d = dist_3d(pos, player_pos), hp = hp, model = model, model_ok = model_ok})
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
// the field offsets that DECREMENT for some movers while staying 0 for the rest — i.e.
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
  pt := Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wv, wok := read_value(handle, base + FLYFF_WORLD_RVA, pt)
  if !wok {
    fmt.eprintln("could not read world anchor.")
    return
  }
  world := uintptr(value_as_u64(pt, wv))
  wval := ptr_to_value(world, session.ptr_size)

  all := collect_regions(handle, true)
  defer delete(all)
  set := scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)
  objs := make([dynamic]uintptr, context.temp_allocator)
  for m in set.matches {
    obj := uintptr(i64(m.addr) - FLYFF_FIELD_OFF)
    vt, vok := read_value(handle, obj, pt)
    if !vok {
      continue
    }
    vtable := uintptr(value_as_u64(pt, vt))
    if vtable < base || vtable >= mod_end {
      continue
    }
    if read_obj_type(handle, obj, FLYFF_POS_OFF) != FLYFF_MOVER_TYPE {
      continue
    }
    nm, nok := read_obj_name(handle, session.ptr_size, obj, FLYFF_NAME_OFF)
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
      read_into(handle, o, b)
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
        if u32at(snaps[s][i], FLYFF_FIELD_OFF) != worldv {
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
          if u32at(snaps[s][i], FLYFF_FIELD_OFF) != worldv {
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
// at least 2 of them hold <value> — used to locate a known stat (e.g. a full mob's HP)
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
  pt := Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wv, wok := read_value(handle, base + FLYFF_WORLD_RVA, pt)
  if !wok {
    fmt.eprintln("could not read world anchor.")
    return
  }
  world := uintptr(value_as_u64(pt, wv))
  wval := ptr_to_value(world, session.ptr_size)
  all := collect_regions(handle, true)
  defer delete(all)
  set := scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)
  bufs := make([dynamic][]byte, context.temp_allocator)
  for m in set.matches {
    obj := uintptr(i64(m.addr) - FLYFF_FIELD_OFF)
    vt, vok := read_value(handle, obj, pt)
    if !vok {
      continue
    }
    vtable := uintptr(value_as_u64(pt, vt))
    if vtable < base || vtable >= mod_end {
      continue
    }
    if read_obj_type(handle, obj, FLYFF_POS_OFF) != FLYFF_MOVER_TYPE {
      continue
    }
    nm, nok := read_obj_name(handle, session.ptr_size, obj, FLYFF_NAME_OFF)
    if !nok || !strings.contains(nm, name) {
      continue
    }
    b := make([]byte, LEN, context.temp_allocator)
    read_into(handle, obj, b)
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
resolve_operand :: proc(session: ^Session, s: string) -> (addr: uintptr, ok: bool) {
  if strings.has_prefix(s, "[") && strings.has_suffix(s, "]") {
    idx, iok := strconv.parse_int(s[1:len(s) - 1])
    if !iok || !session.has_matches || idx < 0 || idx >= len(session.matches.matches) {
      return 0, false
    }
    return session.matches.matches[idx].addr, true
  }
  return parse_addr(s)
}

// Resolve a player-position operand: a literal "x,y,z" (comma-separated, no spaces —
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

parse_addr :: proc(s: string) -> (uintptr, bool) {
  if strings.has_prefix(s, "0x") || strings.has_prefix(s, "0X") {
    v, ok := strconv.parse_u64_of_base(s[2:], 16)
    return uintptr(v), ok
  }
  if v, ok := strconv.parse_u64_of_base(s, 10); ok {
    return uintptr(v), true
  }
  v, ok := strconv.parse_u64_of_base(s, 16)
  return uintptr(v), ok
}

parse_offset :: proc(s: string) -> (i64, bool) {
  ss := s
  if strings.has_prefix(ss, "+") {
    ss = ss[1:]
  }
  neg := false
  if strings.has_prefix(ss, "-") {
    neg = true
    ss = ss[1:]
  }
  v: u64
  ok: bool
  if strings.has_prefix(ss, "0x") || strings.has_prefix(ss, "0X") {
    v, ok = strconv.parse_u64_of_base(ss[2:], 16)
  } else {
    v, ok = strconv.parse_u64_of_base(ss, 10)
  }
  if !ok {
    return 0, false
  }
  r := i64(v)
  if neg {
    r = -r
  }
  return r, true
}
