package main
import "flyff"
import "engine"

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import win "core:sys/windows"
import "core:time"

run_cli :: proc(session: ^flyff.Session) {
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
cli_execute_line :: proc(session: ^flyff.Session, line: string) -> (quit: bool) {
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

cli_dispatch :: proc(session: ^flyff.Session, cmd: string, args: []string) -> (quit: bool) {
  switch cmd {
  case "help", "?":
    cli_help()
  case "quit", "exit", "q":
    return true
  case "version", "ver":
    cli_version()
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
    flyff.session_clear_matches(session)
    fmt.println("matches cleared (snapshot kept).")
  case "reset":
    flyff.session_reset_scan(session)
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
    flyff.cli_target_closest(session, args)
  case "tdbg", "tmap":
    flyff.cli_tdbg(session, args)
  case "auto":
    flyff.cli_auto(session, args)
  case "timer":
    flyff.cli_timer(session, args)
  case "kills":
    flyff.cli_kills(session, args)
  case "stuck":
    flyff.cli_stuck(session, args)
  case "reachgate":
    flyff.cli_reachgate(session, args)
  case "meshreach":
    flyff.cli_meshreach(session, args)
  case "pause":
    flyff.cli_pause(session, args)
  case "calibrate", "cal":
    flyff.cli_calibrate(session, args)
  case "calibrate_house", "calh":
    flyff.cli_calibrate_house(session, args)
  case "offsets", "layout":
    flyff.cli_offsets(session, args)
  case "status", "doctor", "diag":
    flyff.cli_status(session)
  case "set":
    flyff.cli_set(session, args)
  case "findpos":
    flyff.cli_findpos(session, args)
  case "findfocus":
    flyff.cli_findfocus(session, args)
  case "findhp":
    flyff.cli_findhp(session, args)
  case "hpwatch":
    flyff.cli_hpwatch(session, args)
  case "findpacket":
    flyff.cli_findpacket(session, args)
  case "packetwatch":
    flyff.cli_packetwatch(session, args)
  case "disasm", "u":
    cli_disasm(session, args)
  case "func":
    cli_func(session, args)
  case "disasmtest":
    cli_disasmtest()
  case "codescan":
    cli_codescan(session, args)
  case "idscan":
    flyff.cli_idscan(session, args)
  case "findsettarget":
    flyff.cli_findsettarget(session, args)
  case "findaii":
    flyff.cli_findaii(session, args)
  case "findprop":
    flyff.cli_findprop(session, args)
  case "srvsync":
    flyff.cli_srvsync(session, args)
  case "srvtest":
    flyff.cli_srvtest(session, args)
  case "hotkey", "hk":
    flyff.cli_hotkey(session, args)
  case "deathscan":
    flyff.cli_deathscan(session, args)
  case "objscan":
    flyff.cli_objscan(session, args)
  case "mobs":
    flyff.cli_mobs(session, args)
  case "mark":
    flyff.cli_mark(session, args)
  case "ring":
    flyff.cli_ring(session, args)
  case "draw_range", "drawrange":
    flyff.cli_draw_range(session, args)
  case "markmobs":
    flyff.cli_markmobs(session, args)
  case "findparticle":
    flyff.cli_findparticle(session, args)
  case "warmtype":
    flyff.cli_warmtype(session, args)
  case "worldscan":
    flyff.cli_worldscan(session, args)
  case "attr":
    flyff.cli_attr(session, args)
  case "attrmap":
    flyff.cli_attrmap(session, args)
  case "objects":
    flyff.cli_objects(session, args)
  case "collscan":
    flyff.cli_collscan(session, args)
  case "linkscan":
    flyff.cli_linkscan(session, args)
  case "reach":
    flyff.cli_reach(session, args)
  case "attackable", "canhit":
    flyff.cli_attackable(session, args)
  case "reachdbg":
    flyff.cli_reachdbg(session, args)
  case "objline":
    flyff.cli_objline(session, args)
  case "reachcmp":
    flyff.cli_reachcmp(session, args)
  case "findcull":
    flyff.cli_findcull(session, args)
  case "findcam":
    flyff.cli_findcam(session, args)
  case:
    fmt.eprintfln("unknown command: %s (try 'help')", cmd)
  }
  return false
}

cli_help :: proc() {
  fmt.println(`memscan - cross-process memory scanner with Flyff (Neuz.exe) automation on top.
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
                             also: hotkey list | hotkey clear

============ FLYFF (Neuz.exe - offsets live in flyff.cfg, loaded on attach) ============
typical use: attach Neuz -> auto -> hold your attack key.   after a patch: select a mob, calibrate.
check the setup anytime with 'status'.

farming (day to day)
  target_closest <name>... (tc)  select nearest mover named <name>; repeat to advance.
                             several names ok: tc 'Aibatt', 'Captain Aibatt'
  auto [name]...             hands-free farm: starts ARMED (paused) - kill the first mob to begin, then it
                             re-targets on each kill. no name = ANY monster; names comma-separated. 'auto off' stops
  pause                      toggle pause (default key: F10). killing the targeted mob resumes
  timer <minutes>            auto-disable 'auto' after N minutes (e.g. 'timer 60'); 'timer off' cancels
  kills <n>                  auto-disable 'auto' after N confirmed kills (e.g. 'kills 100'); 'kills off' cancels
  stuck [on|off]             toggle reactive obstacle skip-detection (on by default; 'stuck off' for ranged/standing)
  reachgate [on|off]         proactively skip mobs behind walls/trees/buildings when auto-picks a target
  meshreach [on|off]         confirm OBB-blocked mobs with the client's IntersectObjLine (default OFF; injects, crash-prone)
                             (on by default; needs 'worldscan' + 'findcull' once to take effect)
  mobs <name>                list nearby <name> movers by distance (hp, model, address)
  tdbg [label] [zoom] (tmap)  write a top-down radar map of the PREDICTED auto kill-order
                             (tc_map[_label].html) + a console factor table; diagnoses target order.
                             label tags the file ('tdbg cloakia' vs 'tdbg tower'); a trailing number is
                             the view radius in world units ('tdbg tower 30' to zoom in)
  ring [radius] [Ns]         draw your attack_range as a cyan circle on the ground (follows you, ~30s,
                             non-blocking); attack a mob to see if the ring reaches it. 'ring off' stops
  draw_range                 toggle a PERSISTENT range circle that live-tracks attack_range (so
                             'set attack_range 1.75' updates it instantly); run again to stop
  srvsync [on|off]           mirror each select to the server (stops the after-N-kills DC);
                             ON by default on attach
  srvtest                    fire one server SendSetTarget at the current target

setup & health (run once after a game patch)
  status              (doctor)  health-check: what's configured, what's missing, and how to fix it
  calibrate <x,y,z> <name> [hp]  (cal) re-derive the whole layout from /position + your
                             character name; also finds srvsync offsets, and focus_off if a mob
                             is selected. select a mob first for full setup. saves flyff.cfg
  calibrate_house <name> [hp]  (calh) same, from your house's fixed spawn (no /position; but no
                             mobs in the house, so focus_off is kept - pin it later in the field)
  offsets [save|load|reset] (layout)  no-arg = status; or persist/restore the layout
  set <field> <value>        set one layout field (see 'status'); auto-saves flyff.cfg

offset finders (one-time; each fills part of the layout)
  findfocus                  click a mob, then run: derives focus_off
  hpwatch                    target a mob and hit it: the field that drops is currentHP (hp_off)
  findsettarget              derive the srvsync offsets by signature (calibrate does this too)
  findprop                   target your PET (monsters on screen), then run: derives the any-monster gate
                             (species MoverProp array -> GetProp()->dwAI==AII_MONSTER). Excludes pets /
                             eggs / NPCs / players / bosses. One-time; re-run after a game patch.
  findaii                    diagnostic: dump a mover's AI-region fields / find pet tags (RE only)

terrain / obstacle reach oracle (one-time setup: worldscan + findcull)
  worldscan [reset]          pin the terrain-grid offsets from your ground height (stand on solid
                             ground; if ambiguous, walk to a different-height spot and re-run)
  findcull                   locate the on-screen object array (makes reach checks ~instant; re-run after a patch)
  findcam                    locate the render camera (CWorld::m_pCamera); lets tdbg draw the cull cone / blind spot
  attr [x,z]                 terrain attribute at your feet (or a world point): NONE/NOWALK/NOMOVE/DIE
  attrmap [radius] [step]    ASCII map of terrain attributes around you (reveals invisible walls)
  objects [radius]           list nearby CObj of any type + locate m_OBB (props the grid misses)
  collscan [radius]          per nearby prop: model .o3d filename + collision-mesh type (NORMAL vs ERROR)
  reach [x,z]                is the straight path player->point (or ->selected target) walkable?
  attackable          (canhit)  is the SELECTED mob reachable to attack? (terrain + object obstacles,
                             within attack_range). select a mob, stand behind cover, run it.
  objline [x,z]              client's own IntersectObjLine (mesh-accurate) vs our OBB oracle for one segment
  reachcmp [n]               compare OBB oracle vs client IntersectObjLine over the nearest n mobs (finds false blocks)

deep recon (rarely needed)
  findpos <x,y,z> [eps]      addresses whose 3 f32 match a position
  findhp <name>              guess hp_off statistically (prefer hpwatch)
  idscan <name>              find m_objid across <name> movers
  findpacket [objid]         scan for the outgoing SETTARGET packet id
  packetwatch                snapshot, click a mob, catch the fresh SETTARGET packet
  deathscan <name>           find a corpse despawn-countdown field
  objscan <value> <name>     find offsets holding <value> across <name> movers

============================================================================
  version (ver)  print the version + build hash (compare the hash to the one build.bat
                 printed to catch a stale build)
  help (?)   this list         quit (q)   exit

chain commands on one line with ';' or '&&':
  calibrate 253,100,243 MyChar 1234 ; auto any`)
}

cli_ps :: proc(args: []string) {
  filter := ""
  if len(args) > 0 {
    filter = args[0]
  }
  results := engine.find_process_id_by_name(filter, context.temp_allocator)
  fmt.printfln("%d process(es):", len(results))
  for r in results {
    fmt.printfln("  pid=%-6d  %-28s  %s", r.process_id, r.process_name, r.window_title)
  }
}

cli_attach :: proc(session: ^flyff.Session, args: []string) {
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
    results := engine.find_process_id_by_name(args[0], context.temp_allocator)
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

  base, size, mok := engine.get_process_module_info(pid)
  if !mok {
    fmt.eprintfln("warning: could not read main module info for pid %d", pid)
  }

  is_wow: win.BOOL
  win.IsWow64Process(handle, &is_wow)

  if session.attached {
    flyff.remote_free_shim(session) // release the old process's cached shim page before re-attaching
    flyff.remote_free_spawn_page(session)
    flyff.remote_free_objline_page(session)
    session.collider_cache_valid = false // stale across processes
    win.CloseHandle(session.proc_info.handle)
  }
  flyff.session_reset_scan(session)

  session.attached = true
  session.proc_info = flyff.Attached_Process {
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

  // Load the persisted Flyff layout (flyff.cfg next to memscan.exe) fresh over defaults, so a
  // patched build just needs 'calibrate' once. Absent file -> built-in defaults.
  session.layout = flyff.flyff_layout_default()
  cfg := flyff.flyff_cfg_path()
  if flyff.flyff_load_cfg(&session.layout, cfg) {
    fmt.printfln("layout: loaded %s", cfg)
  } else {
    fmt.println("layout: built-in defaults (run 'calibrate' if the game was patched).")
  }

  // srvsync defaults ON now that the anti-DC path is proven - it's always needed. It stays inert
  // (notify_server_target no-ops) until sendsettarget_rva/objid_off are set on a 32-bit client, so
  // enabling it unconditionally is safe. 'srvsync off' still disables it for the rest of the session.
  session.srvsync_on = true
  if session.ptr_size == 4 && session.layout.sendsettarget_rva != 0 && session.layout.objid_off != 0 {
    fmt.println("srvsync: ON (default). 'srvsync off' to disable.")
  } else {
    fmt.println("srvsync: ON (default) but inert until configured - run 'findsettarget' on the 32-bit Neuz.exe.")
  }
}

cli_detach :: proc(session: ^flyff.Session) {
  if !session.attached {
    fmt.println("not attached.")
    return
  }
  pid := session.proc_info.pid
  flyff.auto_stop(session) // stop auto-farm + clear its run state when the process goes away
  flyff.range_ring_stop(session) // stop the attack-range overlay
  session.srvsync_on = false
  flyff.remote_free_shim(session)
  flyff.remote_free_spawn_page(session)
  flyff.remote_free_objline_page(session)
  win.CloseHandle(session.proc_info.handle)
  flyff.session_reset_scan(session)
  session.attached = false
  session.proc_info = {}
  fmt.printfln("detached from pid %d.", pid)
}

cli_info :: proc(session: ^flyff.Session) {
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
  fmt.printfln("default type : %s", engine.value_type_name(session.vtype))
  fmt.printfln("has snapshot : %v", session.has_snapshot)
  fmt.printfln("matches      : %v", session.has_matches ? len(session.matches.matches) : 0)
}

cli_vtype :: proc(session: ^flyff.Session, args: []string) {
  if len(args) < 1 {
    fmt.printfln("current type: %s", engine.value_type_name(session.vtype))
    return
  }
  if t, ok := parse_vtype(args[0]); ok {
    session.vtype = t
    fmt.printfln("type = %s", engine.value_type_name(t))
  } else {
    fmt.eprintfln("unknown type '%s' (u8 i8 u16 i16 u32 i32 u64 i64 f32 f64)", args[0])
  }
}

cli_ptrsize :: proc(session: ^flyff.Session, args: []string) {
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

cli_scan :: proc(session: ^flyff.Session, args: []string) {
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
  target, ok := engine.parse_value(t, val_str)
  if !ok {
    fmt.eprintfln("invalid %s value: %s", engine.value_type_name(t), val_str)
    return
  }

  flyff.session_reset_scan(session)
  set := engine.scan_exact(session.proc_info.handle, t, target, session.writable_only, flyff.session_scan_allocator(session))
  session.matches = set
  session.has_matches = true
  session.vtype = t
  fmt.printfln("scan(%s == %s): %d match(es)", engine.value_type_name(t), val_str, len(set.matches))
}

cli_snapshot :: proc(session: ^flyff.Session, args: []string) {
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
  snap := engine.take_snapshot(session.proc_info.handle, t, session.writable_only, flyff.session_scan_allocator(session))
  session.snapshot = snap
  session.has_snapshot = true
  session.vtype = t
  fmt.printfln(
    "snapshot(%s): %d region(s), %.1f MB. Change the value, then 'next changed'.",
    engine.value_type_name(t),
    len(snap.regions),
    f64(engine.snapshot_total_bytes(snap)) / (1024 * 1024),
  )
}

cli_next :: proc(session: ^flyff.Session, args: []string) {
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

  target: engine.Value
  has_target := false
  if needs_val {
    if len(args) < 2 {
      fmt.eprintfln("comparator '%s' needs a value", args[0])
      return
    }
    tv, vok := engine.parse_value(session.vtype, args[1])
    if !vok {
      fmt.eprintfln("invalid value: %s", args[1])
      return
    }
    target = tv
    has_target = true
  }

  alloc := flyff.session_scan_allocator(session)
  new_set: engine.Match_Set
  if session.has_matches {
    new_set = engine.refine_matches(session.proc_info.handle, session.matches, op, target, has_target, alloc)
  } else if session.has_snapshot {
    new_set = engine.refine_from_snapshot(session.proc_info.handle, session.snapshot, op, target, has_target, alloc)
  } else {
    fmt.eprintln("nothing to refine - run 'scan' or 'snapshot' first.")
    return
  }
  session.matches = new_set
  session.has_matches = true
  fmt.printfln("next(%s): %d match(es)", args[0], len(new_set.matches))
}

cli_list :: proc(session: ^flyff.Session, args: []string) {
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
    fmt.printfln("  [%d] 0x%X = %s", i, e.addr, engine.format_value(m.vtype, e.value))
  }
}

cli_pointers :: proc(session: ^flyff.Session) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if !session.has_matches {
    fmt.eprintln("no matches.")
    return
  }
  before := len(session.matches.matches)
  set := engine.filter_pointers(session.proc_info.handle, session.matches, session.ptr_size, flyff.session_scan_allocator(session))
  session.matches = set
  fmt.printfln("pointers: %d -> %d match(es)", before, len(set.matches))
}

cli_count :: proc(session: ^flyff.Session) {
  if !session.has_matches {
    fmt.println("0 matches.")
    return
  }
  fmt.printfln("%d match(es)", len(session.matches.matches))
}

cli_read :: proc(session: ^flyff.Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: read <addr> [type]")
    return
  }
  addr, ok := engine.parse_addr(args[0])
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
  v, rok := engine.read_value(session.proc_info.handle, addr, t)
  if !rok {
    fmt.eprintfln("read failed at 0x%X", addr)
    return
  }
  fmt.printfln("0x%X = %s", addr, engine.format_value(t, v))
}

cli_write :: proc(session: ^flyff.Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 2 {
    fmt.eprintln("usage: write <addr> <value> [type]")
    return
  }
  addr, ok := engine.parse_addr(args[0])
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
  val, vok := engine.parse_value(t, args[1])
  if !vok {
    fmt.eprintfln("invalid %s value: %s", engine.value_type_name(t), args[1])
    return
  }
  if engine.write_value(session.proc_info.handle, addr, t, val) {
    fmt.printfln("wrote 0x%X = %s", addr, engine.format_value(t, val))
  } else {
    fmt.eprintfln("write failed at 0x%X (error %d)", addr, win.GetLastError())
  }
}

cli_peek :: proc(session: ^flyff.Session, args: []string) {
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
  v, rok := engine.read_value(session.proc_info.handle, m.addr, session.matches.vtype)
  if !rok {
    fmt.eprintfln("read failed at 0x%X", m.addr)
    return
  }
  fmt.printfln("[%d] 0x%X = %s", idx, m.addr, engine.format_value(session.matches.vtype, v))
}

cli_poke :: proc(session: ^flyff.Session, args: []string) {
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
  val, vok := engine.parse_value(t, val_str)
  if !vok {
    fmt.eprintfln("invalid %s value: %s", engine.value_type_name(t), val_str)
    return
  }
  addr := session.matches.matches[idx].addr
  if engine.write_value(session.proc_info.handle, addr, t, val) {
    fmt.printfln("poked [%d] 0x%X = %s", idx, addr, engine.format_value(t, val))
  } else {
    fmt.eprintfln("write failed at 0x%X (error %d)", addr, win.GetLastError())
  }
}

cli_deref :: proc(session: ^flyff.Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: deref <addr> [offset ...]")
    return
  }
  base, ok := engine.parse_addr(args[0])
  if !ok {
    fmt.eprintfln("invalid address: %s", args[0])
    return
  }
  offsets := make([dynamic]i64, context.temp_allocator)
  for i in 1 ..< len(args) {
    off, ook := engine.parse_offset(args[i])
    if !ook {
      fmt.eprintfln("invalid offset: %s", args[i])
      return
    }
    append(&offsets, off)
  }
  addr, dok := engine.deref_chain(session.proc_info.handle, base, offsets[:], session.ptr_size)
  if !dok {
    fmt.eprintfln("deref failed (stopped at 0x%X)", addr)
    return
  }
  fmt.printfln("-> 0x%X", addr)
  if v, rok := engine.read_value(session.proc_info.handle, addr, session.vtype); rok {
    fmt.printfln("   [%s] = %s", engine.value_type_name(session.vtype), engine.format_value(session.vtype, v))
  }
}

cli_dump :: proc(session: ^flyff.Session, args: []string) {
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
  n, rok := engine.read_into(session.proc_info.handle, addr, buf)
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

cli_dist :: proc(session: ^flyff.Session, args: []string) {
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
  va, vaok := engine.read_vec3(session.proc_info.handle, a)
  vb, vbok := engine.read_vec3(session.proc_info.handle, b)
  if !vaok || !vbok {
    fmt.eprintln("read failed")
    return
  }
  fmt.printfln("A 0x%X = (%.3f, %.3f, %.3f)", a, va[0], va[1], va[2])
  fmt.printfln("B 0x%X = (%.3f, %.3f, %.3f)", b, vb[0], vb[1], vb[2])
  fmt.printfln("d(x,z) = %.3f   d(3d) = %.3f", engine.dist_horizontal(va, vb), engine.dist_3d(va, vb))
}

cli_nearest :: proc(session: ^flyff.Session, args: []string) {
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
  entries: [dynamic]engine.Nearest_Entry

  switch args[0] {
  case "list":
    if len(rest) < 4 {
      fmt.eprintln("usage: nearest list <start|[i]> <next_off> <pos_off> <player|[j]> [max]")
      return
    }
    start, sok := resolve_operand(session, rest[0])
    next_off, nok := engine.parse_offset(rest[1])
    pos_off, pok := engine.parse_offset(rest[2])
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
    entries = engine.enumerate_nearest(
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
    stride, stok := engine.parse_offset(rest[2])
    pos_off, pok := engine.parse_offset(rest[3])
    player_pos, plok := resolve_player_pos(session, rest[4])
    if !bok || !cok || !stok || !pok || !plok {
      fmt.eprintln("invalid argument")
      return
    }
    entries = engine.enumerate_nearest(
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
    field_off, fok := engine.parse_offset(rest[0])
    pos_off, pok := engine.parse_offset(rest[1])
    player_pos, plok := resolve_player_pos(session, rest[2])
    if !fok || !pok || !plok {
      fmt.eprintln("invalid argument")
      return
    }
    entries = engine.rank_object_matches(
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

cli_target :: proc(session: ^flyff.Session, args: []string) {
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
  t := engine.Value_Type.U64
  if session.ptr_size == 4 {
    t = .U32
  }
  // Liveness re-check: a pointer that was valid when 'nearest' ran may have been
  // freed since. Handing a dead pointer to the game as a target crashes the client,
  // so verify the object still starts with a module-range vtable before writing.
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  vt, vok := engine.read_value(session.proc_info.handle, obj, t)
  vtable := uintptr(engine.value_as_u64(t, vt))
  if !vok || vtable < base || vtable >= mod_end {
    fmt.eprintfln("refusing: obj 0x%X is no longer a live object - re-run 'nearest' for fresh pointers.", obj)
    return
  }
  val: engine.Value
  u := u64(obj)
  for i in 0 ..< engine.value_size(t) {
    val[i] = byte(u >> uint(8 * i))
  }
  if engine.write_value(session.proc_info.handle, focus, t, val) {
    fmt.printfln("selected rank %d obj=0x%X (type=%d) -> focus 0x%X", rank, obj, session.targets[rank].dtype, focus)
  } else {
    fmt.eprintfln("write failed at 0x%X (error %d)", focus, win.GetLastError())
  }
}

cli_find :: proc(session: ^flyff.Session, args: []string) {
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
  ha := engine.scan_bytes(session.proc_info.handle, asc, context.temp_allocator)
  hw := engine.scan_bytes(session.proc_info.handle, wide, context.temp_allocator)
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

cli_codescan :: proc(session: ^flyff.Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: codescan <u32>   |   codescan call <addr>   |   codescan xref <rva>")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  hits: [dynamic]uintptr
  if args[0] == "call" {
    if len(args) < 2 {
      fmt.eprintln("usage: codescan call <addr>")
      return
    }
    dest, dok := engine.parse_addr(args[1])
    if !dok {
      fmt.eprintfln("invalid address: %s", args[1])
      return
    }
    hits = engine.codescan_calls(handle, dest, context.temp_allocator)
    fmt.printfln("codescan call 0x%X: %d site(s)", dest, len(hits))
  } else if args[0] == "xref" {
    // Find code that references a base-relative global (e.g. the world at world_rva). Resolves
    // base+rva at runtime so no manual base math even when the module rebases.
    if len(args) < 2 {
      fmt.eprintln("usage: codescan xref <rva>   (e.g. codescan xref 0x5888DC for the world global)")
      return
    }
    rva, rok := engine.parse_addr(args[1])
    if !rok {
      fmt.eprintfln("invalid rva: %s", args[1])
      return
    }
    target := base + rva
    hits = engine.codescan_u32(handle, u32(target), context.temp_allocator)
    fmt.printfln("codescan xref Neuz.exe+0x%X (abs 0x%X): %d hit(s)", rva, target, len(hits))
  } else {
    v, vok := engine.parse_addr(args[0])
    if !vok {
      fmt.eprintfln("invalid value: %s", args[0])
      return
    }
    hits = engine.codescan_u32(handle, u32(v), context.temp_allocator)
    fmt.printfln("codescan 0x%X: %d hit(s)", u32(v), len(hits))
  }
  shown := 0
  for h in hits {
    if shown >= 32 {
      fmt.printfln("  ... (%d more)", len(hits) - shown)
      break
    }
    wb: [20]byte
    rn, _ := engine.read_into(handle, h - 4, wb[:])
    sb := strings.builder_make(context.temp_allocator)
    for i in 0 ..< int(rn) {
      if i == 4 {
        fmt.sbprint(&sb, "| ") // marker: bytes at/after the hit
      }
      fmt.sbprintf(&sb, "%02X ", wb[i])
    }
    fmt.printfln("  0x%X (Neuz.exe+0x%X)  %s", h, h - base, strings.to_string(sb))
    shown += 1
  }
}

// Read-only recon to locate CObj.m_objid (net-package-targeting.md Phase 0). Enumerates movers
// named <name> and reports each 4-byte offset whose value is distinct across all of them and in
// a plausible id range [1, 0x00FFFFFF] (so pointers/vtables are excluded). m_objid is the field
// used as idTarget; it should be the offset where every mob has a small, unique value.
// Usage: idscan <name>
resolve_operand :: proc(session: ^flyff.Session, s: string) -> (addr: uintptr, ok: bool) {
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
    v, vok := engine.parse_addr(s[1:])
    if !vok {
      return 0, false
    }
    return session.proc_info.base + uintptr(v), true
  }
  return engine.parse_addr(s)
}

// Resolve a player-position operand: a literal "x,y,z" (comma-separated, no spaces -
// handy with the in-game /position readout), or an address/[i] whose 3 f32 are read live.
resolve_player_pos :: proc(session: ^flyff.Session, s: string) -> (pos: [3]f32, ok: bool) {
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
  return engine.read_vec3(session.proc_info.handle, addr)
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

parse_vtype :: proc(s: string) -> (engine.Value_Type, bool) {
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

parse_op :: proc(s: string) -> (op: engine.Compare_Op, needs_value: bool, ok: bool) {
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

