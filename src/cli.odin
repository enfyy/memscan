package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"

run_cli :: proc(session: ^Session) {
  fmt.println("memscan CLI — type 'help' for commands, 'quit' to exit.")
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
    args := strings.fields(line, context.temp_allocator)
    quit := false
    if len(args) > 0 {
      quit = cli_dispatch(session, args[0], args[1:])
    }
    free_all(context.temp_allocator)
    if quit {
      break
    }
  }
  fmt.println("bye.")
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
  case:
    fmt.eprintfln("unknown command: %s (try 'help')", cmd)
  }
  return false
}

cli_help :: proc() {
  fmt.println(`commands:
  ps [filter]                list processes (optionally filtered by name)
  attach <name|pid>          open a process for read/write
  info                       show attached process details
  vtype <t>                  set default value type (u8 i8 u16 i16 u32 i32 u64 i64 f32 f64)
  ptrsize <4|8>              pointer width used by 'deref'
  scan [t] <value>           exact-value scan, replaces match set
  snapshot [t]               capture memory for an unknown-initial search
  next <op> [value]          refine matches/snapshot; op = eq ne gt lt changed unchanged inc dec
  list [n]                   show first n matches (default 20)
  count                      show number of matches
  clearmatches               drop matches but keep snapshot
  reset                      clear all scan state
  read  <addr> [t]           read a value at an absolute address
  write <addr> <value> [t]   write a value at an absolute address
  peek  [i]                  read match #i live (default 0)
  poke  [i] <value>          write <value> to match #i (default i=0)
  deref <addr> [off ...]     follow a pointer chain, show the final address+value
  quit                       exit`)
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
      fmt.printfln("%d matches, attaching to the first:", len(results))
      for r in results {
        fmt.printfln("  pid=%-6d %s", r.process_id, r.process_name)
      }
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

// ---------------------------------------------------------------------------
// Parsing helpers
// ---------------------------------------------------------------------------

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
