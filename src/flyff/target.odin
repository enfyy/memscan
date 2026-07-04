package flyff

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "../engine"

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
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  rdp :: proc(handle: win.HANDLE, addr: uintptr, pt: engine.Value_Type) -> uintptr {
    v, ok := engine.read_value(handle, addr, pt)
    return ok ? uintptr(engine.value_as_u64(pt, v)) : 0
  }
  rdi :: proc(handle: win.HANDLE, addr: uintptr) -> i32 {
    v, ok := engine.read_value(handle, addr, .U32)
    return ok ? i32(u32(engine.value_as_u64(.U32, v))) : -1
  }
  dumprow :: proc(sb: ^strings.Builder, handle: win.HANDLE, addr: uintptr, off: uintptr, n: int) {
    b := make([]byte, n, context.temp_allocator)
    rn, ok := engine.read_into(handle, addr + off, b)
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

  name, _ := engine.read_obj_name(handle, session.ptr_size, obj, session.layout.name_off)
  pos, _ := engine.read_vec3(handle, obj + uintptr(session.layout.pos_off))
  mpw := rdp(handle, obj + uintptr(session.layout.field_off), pt)
  prev := rdp(handle, world + uintptr(session.layout.focus_off), pt)

  sb := strings.builder_make(context.temp_allocator)
  fmt.sbprintfln(&sb, "--- target obj=0x%X '%s' #%d/%d (prevFocus=0x%X) ---", obj, name, sel + 1, total, prev)
  fmt.sbprintfln(
    &sb,
    "  type=%d vtable=0x%X mpWorld=0x%X(want 0x%X%s) hp=%d max=%d pos=%.1f,%.1f,%.1f",
    engine.read_obj_type(handle, obj, session.layout.pos_off),
    rdp(handle, obj, pt),
    mpw,
    world,
    mpw == world ? "" : " MISMATCH",
    rdi(handle, obj + uintptr(session.layout.hp_off)),
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

// True if <obj> is a safe, correct focus target: a live object (vtable in module), a mover
// (type 5), name-matches <name>, has currentHP > 0, and a mapped m_pModel. Selecting a
// model-less / freed object crashes the client (it derefs the focused object's model to
// draw the selection), so this is used BOTH as the enumeration filter AND as the re-check
// done immediately before the focus write - objects can be freed/reallocated in between.
obj_is_selectable :: proc(session: ^Session, obj: uintptr, name: string) -> bool {
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  vt, vok := engine.read_value(handle, obj, pt)
  if !vok {
    return false
  }
  vtable := uintptr(engine.value_as_u64(pt, vt))
  if vtable < base || vtable >= mod_end {
    return false // not a live object
  }
  if engine.read_obj_type(handle, obj, session.layout.pos_off) != session.layout.mover_type {
    return false // movers only
  }
  nm, nok := engine.read_obj_name(handle, session.ptr_size, obj, session.layout.name_off)
  if !nok || !strings.equal_fold(nm, name) {
    return false
  }
  // skip dying-but-not-despawned mobs (currentHP <= 0); a failed read leaves it eligible
  if hpv, hok := engine.read_value(handle, obj + uintptr(session.layout.hp_off), .U32); hok {
    if i32(u32(engine.value_as_u64(.U32, hpv))) <= 0 {
      return false
    }
  }
  // require a live, mapped model - selecting a model-less mob crashes the client
  model: uintptr = 0
  if mv, mok := engine.read_value(handle, obj + uintptr(session.layout.model_off), pt); mok {
    model = uintptr(engine.value_as_u64(pt, mv))
  }
  if model < 0x10000 {
    return false
  }
  if _, mok2 := engine.read_value(handle, model, pt); !mok2 {
    return false
  }
  return true
}

// Scan for objects and return the selectable movers named <name>, nearest first. Enumerates
// ALL writable regions fresh every call - complete regardless of spawns/zoning (the old
// region cache went stale and missed most of a big spawn). Each world-ptr hit is gated by
// obj_is_selectable (live object, mover, name, HP, model).
tc_collect_cands :: proc(
  session: ^Session,
  name: string,
  world: uintptr,
  player_pos: [3]f32,
) -> [dynamic]TC_Cand {
  handle := session.proc_info.handle
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wval := engine.ptr_to_value(world, session.ptr_size)
  regions := engine.collect_regions(handle, true) // all writable - complete, no stale cache
  defer delete(regions)
  set := engine.scan_exact_parallel(handle, pt, wval, regions[:], context.temp_allocator) // multithreaded

  cands := make([dynamic]TC_Cand, context.temp_allocator)
  for m in set.matches {
    obj := uintptr(i64(m.addr) - session.layout.field_off)
    if !obj_is_selectable(session, obj, name) {
      continue
    }
    pos, posok := engine.read_vec3(handle, obj + uintptr(session.layout.pos_off))
    if !posok {
      continue
    }
    append(&cands, TC_Cand{obj = obj, d = engine.dist_3d(pos, player_pos)})
  }
  slice.sort_by(cands[:], proc(a, b: TC_Cand) -> bool {return a.d < b.d})
  return cands
}

TC_Result :: enum {
  Picked, // wrote a mob into m_pObjFocus; obj/d/sel/total are set
  NoCandidates, // no selectable mover named <name> nearby
  AllOnCooldown, // candidates exist but all recently targeted (only when require_fresh)
  WentStale, // chosen obj was freed/reallocated between enumeration and the write
  AnchorFail, // couldn't read the world/player anchors (not in-game / wrong build)
  WriteFail, // the focus write failed (message already printed)
}

// Resolve the Flyff world/player anchors, enumerate selectable movers named <name>, pick
// one by distance, and write it into m_pObjFocus - atomically, so the pick can't go stale
// between ranking and selecting. Shared by manual `target_closest` and the auto-farm loop.
// All the crash guards live in tc_collect_cands (vtable-in-module, type 5, HP>0, mapped
// model), so this never writes a dead/model-less mob.
//   require_fresh=false (manual): when every candidate is on the recently-targeted cooldown,
//     fall back to the closest - the #1<->#2 / next-fresh cycle of repeated presses.
//   require_fresh=true (auto): return AllOnCooldown instead, so a lone just-killed mob isn't
//     re-selected while it's still a fresh-looking corpse.
tc_select :: proc(
  session: ^Session,
  name: string,
  require_fresh: bool,
) -> (
  res: TC_Result,
  obj: uintptr,
  d: f32,
  sel: int,
  total: int,
) {
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }

  // Resolve world + player from the static anchors.
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  pv, pok := engine.read_value(handle, base + session.layout.player_rva, pt)
  if !wok || !pok {
    return .AnchorFail, 0, 0, 0, 0
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  player := uintptr(engine.value_as_u64(pt, pv))
  focus_addr := world + uintptr(session.layout.focus_off)
  player_pos, ppok := engine.read_vec3(handle, player + uintptr(session.layout.pos_off))
  if !ppok {
    return .AnchorFail, 0, 0, 0, 0
  }

  // Collect selectable (alive + rendered) movers named <name>, nearest first.
  cands := tc_collect_cands(session, name, world, player_pos)
  total = len(cands)
  if total == 0 {
    return .NoCandidates, 0, 0, 0, 0
  }

  // Pick the nearest mob we haven't targeted in the last few seconds. A just-killed mob
  // can keep reading as alive (HP unchanged, model still valid) while it plays its death
  // animation, so picking the strict closest would re-select the corpse. Skipping recent
  // picks advances to the next mob after each kill.
  now := time.now()._nsec
  chosen := cands[0]
  sel = 0
  found := false
  for c, i in cands {
    if !tc_seen_recently(session, c.obj, now) {
      chosen = c
      sel = i
      found = true
      break
    }
  }
  if !found {
    if require_fresh {
      return .AllOnCooldown, 0, 0, 0, total // don't re-lock a fresh corpse (auto)
    }
    chosen = cands[0] // manual: fall back to the closest
    sel = 0
  }
  // Re-validate immediately before the write. The object can be freed/reallocated between
  // enumeration and now; writing a stale pointer whose m_pModel has gone NULL crashes the
  // client. This shrinks the TOCTOU window from ~ms (the sort/pick above) to ~µs.
  if !obj_is_selectable(session, chosen.obj, name) {
    return .WentStale, 0, 0, 0, total
  }
  tc_mark_recent(session, chosen.obj, now)

  when ODIN_DEBUG {
    log_target(session, chosen.obj, world, sel, total)
  }
  if !engine.write_value(handle, focus_addr, pt, engine.ptr_to_value(chosen.obj, session.ptr_size)) {
    fmt.eprintfln("write failed at focus 0x%X (error %d)", focus_addr, win.GetLastError())
    return .WriteFail, chosen.obj, chosen.d, sel, total
  }
  // Server sync: also make the client emit its own SendSetTarget so the server registers the
  // same target (stops the after-N-kills DC). Inert unless 'srvsync on' and Phase-0 configured.
  if session.srvsync_on {
    notify_server_target(session, chosen.obj)
  }
  return .Picked, chosen.obj, chosen.d, sel, total
}

// One-shot: select the nearest selectable mover named <name> by writing it into
// m_pObjFocus. Repeated presses advance through the nearby mobs (the recently-targeted
// cooldown skips a just-killed corpse). All anchors/offsets are baked Flyff constants, so
// it needs no setup: `target_closest Mutant Yetti`.
cli_target_closest :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  name := strings.trim(strings.join(args, " ", context.temp_allocator), "'\"")
  if len(name) == 0 {
    fmt.eprintln("usage: target_closest <name>")
    return
  }

  res, obj, d, sel, total := tc_select(session, name, false)
  switch res {
  case .Picked:
    fmt.printfln("targeted '%s' #%d/%d obj=0x%X at d=%.1f.", name, sel + 1, total, obj, d)
  case .NoCandidates:
    fmt.printfln("no '%s' found.", name)
  case .AnchorFail:
    fmt.eprintln("could not read world/player anchors (wrong build or not in-game?).")
  case .AllOnCooldown:
    fmt.printfln("no fresh '%s' available.", name) // unreachable with require_fresh=false
  case .WentStale:
    fmt.printfln("'%s' just died/despawned - try again.", name)
  case .WriteFail: // tc_select already printed the specific error
  }
}

AUTO_MIN_INTERVAL_NS :: i64(300_000_000) // ~300ms between advance attempts (caps idle rescans)

// Read m_pObjFocus: world = [base+world_rva], then the CObj* at world+focus_off.
read_focus_ptr :: proc(session: ^Session) -> (focus: uintptr, ok: bool) {
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  if !wok {
    return 0, false
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  if world == 0 {
    return 0, false
  }
  fv, fok := engine.read_value(handle, world + uintptr(session.layout.focus_off), pt)
  if !fok {
    return 0, false
  }
  return uintptr(engine.value_as_u64(pt, fv)), true
}

// True if <obj> looks like a live object: its vtable points back into the game module.
// Cheap insurance so a non-zero-but-freed focus (e.g. after zoning) still triggers an
// advance; the primary auto trigger remains focus == 0 (game clears it on kill).
focus_obj_live :: proc(session: ^Session, obj: uintptr) -> bool {
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  vt, ok := engine.read_value(handle, obj, pt)
  if !ok {
    return false
  }
  vtable := uintptr(engine.value_as_u64(pt, vt))
  return vtable >= base && vtable < mod_end
}

// Auto-farm tick: called every ~20ms by the watcher thread while auto_on. When no live
// target is selected (m_pObjFocus cleared on kill, or pointing at a freed object), advance
// the focus to the next fresh mob named auto_name. F2-held then keeps attacking it.
auto_tick :: proc(session: ^Session) {
  if !session.auto_on || !session.attached {
    return
  }
  now := time.now()._nsec
  if now - session.auto_last < AUTO_MIN_INTERVAL_NS {
    return
  }
  // Busy check: a live target is still selected -> nothing to do.
  if focus, fok := read_focus_ptr(session); fok && focus != 0 && focus_obj_live(session, focus) {
    return
  }
  // Focus cleared (kill) or focused obj freed -> advance to the next fresh mob.
  res, obj, d, sel, total := tc_select(session, session.auto_name, true)
  session.auto_last = now
  if res == .Picked {
    fmt.printf(
      "\n[auto] '%s' -> #%d/%d obj=0x%X d=%.1f\n",
      session.auto_name,
      sel + 1,
      total,
      obj,
      d,
    )
    fmt.print("memscan> ")
  }
  // NoCandidates / AllOnCooldown / AnchorFail / WriteFail: stay quiet (no idle spam).
}

// auto                 -> show status
// auto off | auto stop -> turn auto-farm off
// auto <name>          -> toggle on/off for <name> (same name toggles; a different name
//                         while on switches target). Good to bind to a single hotkey.
cli_auto :: proc(session: ^Session, args: []string) {
  if len(args) == 0 {
    if session.auto_on {
      fmt.printfln("auto-farm ON: '%s'.", session.auto_name)
    } else {
      fmt.println("auto-farm OFF. usage: auto <name>  (toggle)  |  auto off")
    }
    return
  }

  if len(args) == 1 && (args[0] == "off" || args[0] == "stop") {
    if session.auto_on {
      session.auto_on = false
      fmt.println("auto-farm OFF.")
    } else {
      fmt.println("auto-farm already off.")
    }
    return
  }

  name := strings.trim(strings.join(args, " ", context.temp_allocator), "'\"")
  if len(name) == 0 {
    fmt.eprintln("usage: auto <name>")
    return
  }

  if session.auto_on {
    if strings.equal_fold(name, session.auto_name) {
      session.auto_on = false // same name -> toggle off
      fmt.println("auto-farm OFF.")
      return
    }
    delete(session.auto_name) // different name -> switch target, stay on
    session.auto_name = strings.clone(name)
    session.auto_last = 0
    fmt.printfln("auto-farm target -> '%s'.", name)
    return
  }

  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  delete(session.auto_name)
  session.auto_name = strings.clone(name)
  session.auto_last = 0
  session.auto_on = true
  ensure_hotkey_thread(session)
  fmt.printfln(
    "auto-farm ON: '%s'. hold F2; advances to the next mob on each kill. 'auto %s' or 'auto off' to stop.",
    name,
    name,
  )
}

REFOCUS_INTERVAL_NS :: i64(200_000_000) // ~200ms between consistent write-backs

// Detection experiment: every ~200ms, read m_pObjFocus and write the SAME bytes back. This
// generates external WriteProcessMemory traffic to the focus field whose value always equals
// what the client itself set (via your clicks) - focus == the client's input "shadow". If the
// anti-cheat disconnects under this, it detects the raw cross-process write; if it does NOT,
// the ~5-min DC is the focus-vs-input mismatch and only *inconsistent* writes are the tell.
refocus_tick :: proc(session: ^Session) {
  if !session.refocus_on || !session.attached {
    return
  }
  now := time.now()._nsec
  if now - session.refocus_last < REFOCUS_INTERVAL_NS {
    return
  }
  session.refocus_last = now
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  if !wok {
    return
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  if world == 0 {
    return
  }
  focus_addr := world + uintptr(session.layout.focus_off)
  fv, fok := engine.read_value(handle, focus_addr, pt)
  if !fok {
    return
  }
  engine.write_value(handle, focus_addr, pt, fv) // write the exact same bytes back (no value change)
}

// refocus | refocus off  -> toggle the consistent-write experiment (see refocus_tick).
cli_refocus :: proc(session: ^Session, args: []string) {
  if session.refocus_on || (len(args) == 1 && (args[0] == "off" || args[0] == "stop")) {
    session.refocus_on = false
    fmt.println("refocus OFF.")
    return
  }
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  session.auto_on = false // mutually exclusive experiment
  session.refocus_last = 0
  session.refocus_on = true
  ensure_hotkey_thread(session)
  fmt.println(
    "refocus ON: writing the current focus value back every ~200ms. Play normally (click your own targets) and see if you still DC at ~5 min. 'refocus off' to stop.",
  )
}

// Read-only code recon (net-package-targeting.md Phase 0). Two forms:
//   codescan <u32>        find a 4-byte immediate in executable pages (e.g. 0xff0023, the
//                         SETTARGET packet id embedded in SendSetTarget)
//   codescan call <addr>  find direct CALL sites targeting <addr> (to read the preceding
//                         `mov ecx, imm32` = &g_DPlay)
// Each hit prints as absolute + Neuz.exe+RVA with a 20-byte window from 4 bytes before the
// hit, so the opcode / prologue / `mov ecx` is visible.
