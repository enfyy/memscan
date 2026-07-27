package flyff

import "core:fmt"
import "core:sync"
import "core:time"
import win "core:sys/windows"

import "../engine"

// ===========================================================================
// `test` - live verification, one command per check.
//
// Everything in the behaviour system was built and verified DETACHED. These are the checks that need
// a real client, packaged so running one is a single command and the tool decides pass/fail itself
// wherever the game's own memory can answer the question.
//
// SELF-VERIFYING WHERE POSSIBLE. Most of these need no human eyes:
//   - did the character actually stop?      -> sample position before and after
//   - did the keystroke arrive?             -> press the pet key and watch m_dwPetId flip
//   - did the farm hand steering back?      -> read auto_on around it
// Only a couple genuinely need you to look at the screen, and those say so.
//
// YIELDING IS MANDATORY. These run on the REPL thread, which holds exec_mutex - and the behaviour
// walker only advances on the WATCHER tick, which needs that same lock. So every wait here releases
// the mutex in slices (test_wait). Sleeping while holding it would deadlock the very thing under
// test into doing nothing, and the test would "fail" for entirely the wrong reason.
// ===========================================================================

Live_Test :: struct {
  name:  string,
  blurb: string,
  moves: bool, // moves the character - called out in the listing so nothing is a surprise
  run:   proc(session: ^Session, arg: string) -> (pass: bool, detail: string),
}

LIVE_TESTS := [?]Live_Test {
  {"window", "find the game window keystrokes are posted to", false, test_window},
  {"key", "press one key and ask you to confirm    (test key <name>)", false, test_key},
  {"pet", "press your pet hotkey and watch m_dwPetId flip - PROVES keys arrive    (test pet <key>)", false, test_pet},
  {"senses", "one sense pass: what the machine can see right now", false, test_senses},
  {"target", "select the nearest monster and confirm the focus took", false, test_target},
  {"walkarrive", "walk ~20 units and confirm arrival", true, test_walk_arrive},
  {"walkstop", "THE BIG ONE: stop a script mid-walk and prove the character halts", true, test_walk_stop},
  {"farm", "hand steering to the auto-brain and confirm it is handed back", true, test_farm},
}

// --- helpers -----------------------------------------------------------------------------------

// Wait <ms>, releasing exec_mutex in slices so the watcher can actually tick (see the header).
test_wait :: proc(session: ^Session, ms: int) {
  left := ms
  for left > 0 {
    sync.mutex_unlock(&session.exec_mutex)
    win.Sleep(20)
    sync.mutex_lock(&session.exec_mutex)
    left -= 20
  }
}

@(private = "file")
player_pos_or :: proc(session: ^Session) -> [3]f32 {
  p, _ := read_player_pos(session)
  return p
}

// Build and start a one-off behaviour from a proc, without touching the registry.
@(private = "file")
run_adhoc :: proc(session: ^Session, name: string, build: proc(b: ^Builder, ctx: rawptr), ctx: rawptr) -> bool {
  b := builder_begin(name, .Once)
  build(b, ctx)
  steps, mode, errs := builder_end(b)
  if len(errs) > 0 {
    for e in errs {
      fmt.eprintfln("  build error: %s", e)
    }
    script_steps_free(&steps)
    return false
  }
  if problems := script_check_avail(session, steps[:]); len(problems) > 0 {
    for p in problems {
      fmt.eprintfln("  unavailable: %s", p)
    }
    script_steps_free(&steps)
    return false
  }
  script_begin(session, name, steps, mode)
  return session.script.active
}

// --- the tests ---------------------------------------------------------------------------------

test_window :: proc(session: ^Session, arg: string) -> (bool, string) {
  hwnd, ok := game_window(session)
  if !ok {
    return false, "no visible, titled, unowned window found for this pid - is the client minimised to tray?"
  }
  buf: [128]u16
  n := win.GetWindowTextW(hwnd, raw_data(&buf), 128)
  title, _ := win.wstring_to_utf8(win.wstring(raw_data(buf[:])), int(n), context.temp_allocator)
  return true, fmt.tprintf("hwnd 0x%X  \"%s\"", uintptr(hwnd), title)
}

test_key :: proc(session: ^Session, arg: string) -> (bool, string) {
  k := arg
  if k == "" {
    k = "1"
  }
  vk, ok := vk_from_name(k)
  if !ok {
    return false, fmt.tprintf("'%s' is not a key name", k)
  }
  if !key_post(session, vk, true) {
    return false, "PostMessage failed (key-down)"
  }
  win.Sleep(KEY_HOLD_MS)
  key_post(session, vk, false)
  return true, fmt.tprintf("posted '%s' - LOOK AT THE GAME: did slot '%s' fire? if not, try again with the game focused", k, k)
}

// The keystroke test that needs no eyes: the pet hotkey has an observable memory effect, so we can
// prove end to end that a posted key reached the client. Toggles back afterwards.
test_pet :: proc(session: ^Session, arg: string) -> (bool, string) {
  k := arg
  if k == "" {
    if v, ok := engine.session_var_get(&session.eng, "pet_key"); ok {
      k = v
    }
  }
  if k == "" {
    return false, "which key summons your pet? run 'test pet 9' (or 'var pet_key 9' once)"
  }
  if session.layout.petid_off == 0 {
    return false, "petid_off is unset - 'set petid_off 0x15E0'"
  }
  vk, ok := vk_from_name(k)
  if !ok {
    return false, fmt.tprintf("'%s' is not a key name", k)
  }
  before := read_pet_id(session)
  key_post(session, vk, true)
  win.Sleep(KEY_HOLD_MS)
  key_post(session, vk, false)
  test_wait(session, 1500)
  after := read_pet_id(session)
  if before == after {
    return false, fmt.tprintf(
      "m_dwPetId did not change (still 0x%X). either the key never arrived, or '%s' is not the pet hotkey",
      before, k,
    )
  }
  // Put it back the way we found it.
  key_post(session, vk, true)
  win.Sleep(KEY_HOLD_MS)
  key_post(session, vk, false)
  test_wait(session, 1200)
  return true, fmt.tprintf("m_dwPetId 0x%X -> 0x%X. the posted key REACHED the client (and was toggled back)", before, after)
}

read_pet_id :: proc(session: ^Session) -> u32 {
  player := read_ptr_at(session.proc_info.handle, session.proc_info.base + session.layout.player_rva, engine.Value_Type.U32)
  if player == 0 {
    return 0
  }
  v, ok := engine.read_value(session.proc_info.handle, player + uintptr(session.layout.petid_off), .U32)
  if !ok {
    return 0
  }
  return u32(engine.value_as_u64(.U32, v))
}

test_senses :: proc(session: ^Session, arg: string) -> (bool, string) {
  ctx := Behaviour_Context {
    session = session,
    now     = time.now()._nsec,
    board   = &session.bh_board,
  }
  behaviour_sense_pass(&ctx)
  fired := 0
  for e in Behaviour_Event {
    if engine.board_has(&session.bh_board, e) {
      fired += 1
    }
  }
  return true, fmt.tprintf("%d sense(s) firing this pass - 'sense' shows which", fired)
}

test_target :: proc(session: ^Session, arg: string) -> (bool, string) {
  names := parse_target_names(arg)
  res, obj, d, _, total := tc_select(session, names[:], false)
  if res != .Picked {
    return false, fmt.tprintf("tc_select returned %v (%d candidates seen) - stand near some monsters", res, total)
  }
  focus, _ := read_focus_ptr(session)
  if focus != obj {
    return false, fmt.tprintf("picked 0x%X but m_pObjFocus reads 0x%X", obj, focus)
  }
  nm, _ := read_mover_name(session, obj)
  return true, fmt.tprintf("selected '%s' at %.1f units, focus confirms", nm, d)
}

// --- movement tests ------------------------------------------------------------------------------

@(private = "file")
Walk_Ctx :: struct {
  dest: [3]f32,
}

@(private = "file")
build_walk :: proc(b: ^Builder, ctx: rawptr) {
  wc := cast(^Walk_Ctx)ctx
  s := seq(b)
  walk(&s, wc.dest)
}

// Pick a destination <dist> away that the reach oracle says is actually walkable, trying the compass
// points. Without this the test measures your local terrain as much as the walk: a blindly-chosen
// point can sit inside a rock or behind a wall, the character slides off-axis, the progress watchdog
// correctly gives up, and a perfectly good walk_to reads as a failure.
// ok=false means every direction was blocked - stand somewhere more open.
test_pick_open_dest :: proc(session: ^Session, start: [3]f32, dist: f32) -> (dest: [3]f32, dir: string, ok: bool) {
  world, _, _, aok := tc_resolve_anchors(session)
  offsets := [4][2]f32{{dist, 0}, {-dist, 0}, {0, dist}, {0, -dist}}
  names := [4]string{"+X", "-X", "+Z", "-Z"}
  for off, i in offsets {
    cand := [3]f32{start[0] + off[0], start[1], start[2] + off[1]}
    if !aok || world == 0 {
      return cand, names[i], true // terrain unpinned - can't judge, so take the first and hope
    }
    r := compute_reach(session, world, start[0], start[1], start[2], cand[0], cand[2])
    if r.status == .Clear {
      return cand, names[i], true
    }
  }
  return {}, "", false
}

test_walk_arrive :: proc(session: ^Session, arg: string) -> (bool, string) {
  start, ok := read_player_pos(session)
  if !ok {
    return false, "cannot read player position"
  }
  dest, dir, dok := test_pick_open_dest(session, start, 20)
  if !dok {
    return false, "every direction within 20 units is blocked - stand somewhere more open"
  }
  fmt.printfln("  walking %s (the reach oracle says that line is clear)", dir)
  wc := Walk_Ctx{dest = dest}
  if !run_adhoc(session, "t_walk", build_walk, &wc) {
    return false, "could not start the walk behaviour"
  }
  test_wait(session, 8000)
  here := player_pos_or(session)
  moved := engine.dist_horizontal(start, here)
  left := engine.dist_horizontal(here, wc.dest)
  script_stop(session)
  if left <= 3 {
    return true, fmt.tprintf("walked %.1f units, arrived within %.1f of the target", moved, left)
  }
  return false, fmt.tprintf("moved %.1f units but stopped %.1f short of the target", moved, left)
}

// THE critical one. Starts a long walk, lets it get going, then stops the script exactly the way the
// CLI does - and measures whether the character actually halted. If Exit-phase teardown is broken the
// character keeps walking to the waypoint, and this catches it without you watching the screen.
test_walk_stop :: proc(session: ^Session, arg: string) -> (bool, string) {
  start, ok := read_player_pos(session)
  if !ok {
    return false, "cannot read player position"
  }
  dest, dir, dok := test_pick_open_dest(session, start, 120)
  if !dok {
    return false, "every direction within 120 units is blocked - stand somewhere more open"
  }
  fmt.printfln("  walking %s (the reach oracle says that line is clear)", dir)
  wc := Walk_Ctx{dest = dest}
  if !run_adhoc(session, "t_walkstop", build_walk, &wc) {
    return false, "could not start the walk behaviour"
  }
  test_wait(session, 1800)
  moving_from := player_pos_or(session)
  travelled := engine.dist_horizontal(start, moving_from)
  if travelled < 2 {
    script_stop(session)
    return false, fmt.tprintf("the character never started moving (%.1f units) - fix walking before testing the stop", travelled)
  }

  script_stop(session) // exactly what `script stop` does: state machine Exit -> act_walk_exit -> move_stop
  at_stop := player_pos_or(session)
  test_wait(session, 2000)
  after := player_pos_or(session)
  drift := engine.dist_horizontal(at_stop, after)
  if drift <= 1.5 {
    return true, fmt.tprintf("walked %.1f units, then drifted only %.1f after the stop - Exit teardown HALTED it", travelled, drift)
  }
  return false, fmt.tprintf(
    "walked %.1f units, but kept going %.1f units AFTER the stop - the Exit phase is not halting the walk",
    travelled, drift,
  )
}

@(private = "file")
build_farm :: proc(b: ^Builder, ctx: rawptr) {
  s := seq(b)
  farm(&s, "")
  until(&s, killed(1))
}

test_farm :: proc(session: ^Session, arg: string) -> (bool, string) {
  if session.auto_on {
    return false, "auto is already on - 'auto off' first, so the handover is what's being measured"
  }
  if !run_adhoc(session, "t_farm", build_farm, nil) {
    return false, "could not start the farm behaviour"
  }
  test_wait(session, 2000)
  engaged := session.auto_on
  script_stop(session)
  test_wait(session, 400)
  released := !session.auto_on
  if engaged && released {
    return true, "auto turned ON while the farm block ran, and OFF again when the script stopped"
  }
  if !engaged {
    return false, "the farm block did not turn auto on"
  }
  return false, "auto was left ON after the script stopped - act_farm_exit is not restoring it"
}

// --- CLI ---------------------------------------------------------------------------------------

cli_test :: proc(session: ^Session, args: []string) {
  if len(args) == 0 {
    fmt.println("live tests - each one is a single command. run them roughly in this order:")
    for t in LIVE_TESTS {
      fmt.printfln("  %-11s %s%s", t.name, t.blurb, t.moves ? "   [MOVES YOU]" : "")
    }
    fmt.println("  test <name> [arg]     run one          test all     run every non-moving test")
    fmt.println("  [MOVES YOU] tests walk the character up to ~120 units - stand somewhere open.")
    return
  }
  if !session.attached {
    fmt.eprintln("not attached. attach a Neuz first.")
    return
  }
  engine.ensure_hotkey_thread(&session.eng) // the behaviour walker only advances on the watcher tick

  if args[0] == "all" {
    pass, fail := 0, 0
    for t in LIVE_TESTS {
      if t.moves {
        continue
      }
      if test_one(session, t, "") {
        pass += 1
      } else {
        fail += 1
      }
    }
    fmt.printfln("\n%d passed, %d failed. the [MOVES YOU] tests are not included - run those by name:", pass, fail)
    for t in LIVE_TESTS {
      if t.moves {
        fmt.printfln("  test %s", t.name)
      }
    }
    return
  }
  for t in LIVE_TESTS {
    if t.name == args[0] {
      arg := len(args) >= 2 ? args[1] : ""
      test_one(session, t, arg)
      return
    }
  }
  fmt.eprintfln("no test named '%s'. bare 'test' lists them.", args[0])
}

@(private = "file")
test_one :: proc(session: ^Session, t: Live_Test, arg: string) -> bool {
  fmt.printfln("\n=== test: %s ===", t.name)
  pass, detail := t.run(session, arg)
  if pass {
    fmt.printfln("  [PASS] %s", detail)
  } else {
    fmt.printfln("  [FAIL] %s", detail)
  }
  return pass
}
