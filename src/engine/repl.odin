package engine

import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"

// ===========================================================================
// The REPL host. Reads a line, dispatches generic commands, and falls through
// to the active module's command set (session.module_dispatch) for anything it
// doesn't own. A module plugs in by registering its hooks on the session before
// run_repl is called (see flyff.flyff_register / main).
// ===========================================================================

run_repl :: proc(session: ^Session) {
  fmt.println("memscan - type 'help' for commands, 'quit' to exit.")
  line_buf: [1024]byte
  for {
    fmt.print("memscan> ")
    line, ok := read_line(line_buf[:])
    if !ok {
      break // EOF
    }
    line = strings.trim_space(line)
    if line == "" {
      continue
    }
    // Serialize with the hotkey watcher thread (see hotkey.odin).
    sync.mutex_lock(&session.exec_mutex)
    quit := execute_line(session, line)
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
execute_line :: proc(session: ^Session, line: string) -> (quit: bool) {
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
    if dispatch(session, args[0], args[1:]) {
      quit = true
      break
    }
  }
  free_all(context.temp_allocator)
  return
}

read_line :: proc(buf: []byte) -> (line: string, ok: bool) {
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

// Generic command dispatch. Unknown commands fall through to the active module's dispatcher
// (e.g. flyff), and only if that also declines do we report "unknown command".
dispatch :: proc(session: ^Session, cmd: string, args: []string) -> (quit: bool) {
  switch cmd {
  case "help", "?":
    cmd_help(session)
  case "quit", "exit", "q":
    return true
  case "version", "ver":
    cmd_version(session)
  case "module":
    cmd_module(session, args)
  case "ps":
    cmd_ps(args)
  case "attach":
    cmd_attach(session, args)
  case "detach":
    cmd_detach(session)
  case "info":
    cmd_info(session)
  case "vtype", "type":
    cmd_vtype(session, args)
  case "ptrsize":
    cmd_ptrsize(session, args)
  case "scan", "s":
    cmd_scan(session, args)
  case "snapshot", "snap":
    cmd_snapshot(session, args)
  case "next", "n":
    cmd_next(session, args)
  case "list", "ls":
    cmd_list(session, args)
  case "count":
    cmd_count(session)
  case "pointers", "ptr":
    cmd_pointers(session)
  case "clearmatches", "cm":
    session_clear_matches(session)
    fmt.println("matches cleared (snapshot kept).")
  case "reset":
    session_reset_scan(session)
    fmt.println("scan state reset.")
  case "read", "r":
    cmd_read(session, args)
  case "write", "w":
    cmd_write(session, args)
  case "peek":
    cmd_peek(session, args)
  case "poke":
    cmd_poke(session, args)
  case "deref", "d":
    cmd_deref(session, args)
  case "dump", "x":
    cmd_dump(session, args)
  case "dist":
    cmd_dist(session, args)
  case "nearest", "near":
    cmd_nearest(session, args)
  case "target", "tgt":
    cmd_target(session, args)
  case "find":
    cmd_find(session, args)
  case "disasm", "u":
    cmd_disasm(session, args)
  case "func":
    cmd_func(session, args)
  case "disasmtest":
    cmd_disasmtest()
  case "codescan":
    cmd_codescan(session, args)
  case "hotkey", "hk":
    cmd_hotkey(session, args)
  case:
    if session.module_active && session.module_dispatch != nil && session.module_dispatch(session, cmd, args) {
      return false
    }
    fmt.eprintfln("unknown command: %s (try 'help')", cmd)
  }
  return false
}

// module            -> show the active module (if any)
// module <name>     -> activate/confirm a module (Phase 3: opens its UI window)
cmd_module :: proc(session: ^Session, args: []string) {
  if len(args) == 0 {
    if session.module_active {
      fmt.printfln("active module: %s", session.module_name)
    } else {
      fmt.println("no module active.")
    }
    return
  }
  name := args[0]
  if session.module_active && session.module_name == name {
    fmt.printfln("module '%s' is active.", name)
    return
  }
  fmt.eprintfln("unknown module '%s' (available: %s)", name, session.module_active ? session.module_name : "none")
}

// help output = engine general section + the active module's section + the generic footer.
// The three chunks concatenate to exactly the pre-split help text (verified byte-for-byte).
cmd_help :: proc(session: ^Session) {
  fmt.println(HELP_GENERAL)
  if session.module_active && session.module_help != nil {
    session.module_help()
  }
  fmt.println(HELP_FOOTER)
}

@(private = "file")
HELP_GENERAL :: `memscan - cross-process memory scanner with Flyff (Neuz.exe) automation on top.
(aliases in parens; run any command with wrong args to see its usage)

============================ GENERAL (any process) ============================

process & session
  ps [filter]                list processes (optionally filter by name)
  attach <name|pid>          open a process for read/write
  detach                     close the attached process
  info                       show attached process details
  vtype <t>          (type)  default value type: u8 i8 u16 i16 u32 i32 u64 i64 f32 f64
  ptrsize <4|8>              pointer width for deref (auto-set on attach)

scan for a value
  scan [t] <value>     (s)   exact-value scan (starts/replaces the match set)
  snapshot [t]      (snap)   capture memory for an unknown-value search
  next <op> [value]    (n)   refine matches: eq ne gt lt changed unchanged inc dec
  list [n]            (ls)   show first n matches (default 20)
  count                      how many matches
  pointers           (ptr)   keep only matches that are valid heap pointers
  clearmatches        (cm)   drop matches, keep the snapshot
  reset                      clear all scan state

read / write / inspect
  read  <addr> [t]     (r)   read a value at an address
  write <addr> <val> [t] (w) write a value at an address
  peek  [i]                  read match #i live (default 0)
  poke  [i] <value>          write to match #i (default 0)
  deref <addr> [off ...] (d) follow a pointer chain to the final address+value
  dump  <addr|[i]> [len] (x) hex dump (default 128 bytes) with an f32 column
  find  <text>               search memory for a string (ASCII + UTF-16)
  dist  <a> <b>              distance between two vec3 (3x f32) positions
  nearest <mode> ...  (near) enumerate entities by distance to player;
                             modes: list | array | matches (run for the exact args)
  target <focus|[i]> <rank>  write nearest[rank]'s pointer into a focus address

disassembly / code recon
  disasm <addr> [count] (u)  disassemble count instructions (default 24)
  func <addr>                disassemble the whole enclosing function
  codescan <u32>             find a 4-byte immediate in executable pages
  codescan call <addr>       find direct CALL sites targeting <addr>
  codescan xref <rva>        find code referencing a base-relative global

automation
  hotkey <command>    (hk)   bind a key (when prompted) to run <command>, even backgrounded;
                             also: hotkey list | hotkey clear`

@(private = "file")
HELP_FOOTER :: `
============================================================================
  version (ver)  print the version + build hash (compare the hash to the one build.bat
                 printed to catch a stale build)
  help (?)   this list         quit (q)   exit

chain commands on one line with ';' or '&&':
  calibrate 253,100,243 MyChar 1234 ; auto any`
