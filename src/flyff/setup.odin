package flyff

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:sync"

import "../engine"

// ===========================================================================
// setup - one-command field setup for `auto`.
//
// The whole layout (offsets/RVAs in flyff.cfg) is per-BUILD, so this is a one-time ritual per patch -
// but it used to mean remembering a scavenger hunt of finder commands, each needing a different in-game
// condition. `setup <name> [hp]` collapses it: it anchors on your character NAME (via find_player_by_name
// - no long /position to type; see layout.odin) and then runs the whole pipeline from your current spot,
// finishing with a prescriptive checklist that tells you exactly what (if anything) still needs a
// different condition. Re-runnable/idempotent - pin what you can now, fix the named condition, run again.
//
// Ideal spot: standing in a field, on the ground, with a few DISTINCT monster species on screen. That one
// state satisfies core (name anchor), prop-gate (monster species variety), terrain (ground), and the
// collision filter (props on screen) all at once. No target needs to be selected.
// ===========================================================================

// Human-readable label per pipeline step, indexed by Session.setup_step - 1. Drawn by the radar panel
// while a setup runs (see the async progress notes on cli_setup). A global (not a constant) so it can
// be indexed with the runtime step value.
@(rodata)
SETUP_STEP_LABELS := [9]string {
  "core + srvsync + focus",
  "attackable-monster prop gate",
  "walk-through-prop filter",
  "terrain reachability",
  "character control (moveto/jump)",
  "render camera",
  "mesh-reach function",
  "attack range",
  "inventory-full detector",
}

// Briefly release exec_mutex so other threads (the radar frame pump, the watcher) can run between two
// setup steps. cli_setup is always entered WITH the lock held (REPL dispatch or the panel's async
// worker), so a matched unlock/relock is safe - the same discipline cli_radar uses per frame.
setup_yield :: proc(session: ^Session) {
  sync.mutex_unlock(&session.exec_mutex)
  sync.mutex_lock(&session.exec_mutex)
}

// Publish "step <n> is about to run" for the radar's progress display, then yield once so an open
// radar window actually gets a frame in to draw it.
setup_step_mark :: proc(session: ^Session, n: int) {
  session.setup_step = n
  setup_yield(session)
}

cli_setup :: proc(session: ^Session, args: []string) {
  if session.setup_running {
    fmt.eprintln("setup is already running - wait for it to finish.")
    return
  }
  if !session.attached {
    fmt.eprintln("not attached. attach a 32-bit Neuz first, then: setup <name> [hp]")
    return
  }
  if session.ptr_size != 4 {
    fmt.eprintln("setup: Flyff automation targets the 32-bit Neuz.exe.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: setup <name> [hp]   (your character name; optional current HP)")
    fmt.eprintln("  stand in a field on the ground with a few distinct monsters on screen, then run it.")
    return
  }
  name := strings.trim(args[0], "'\"")
  has_hp := false
  hp: i64 = 0
  if len(args) >= 2 {
    if h, hok := strconv.parse_i64(args[1]); hok {
      hp = h
      has_hp = true
    }
  }

  // Progress state for the radar panel (drawn between the setup_step_mark yields). One run at a time -
  // the guard above rejects a concurrent REPL/panel invocation instead of blocking it forever.
  session.setup_running = true
  defer {
    session.setup_running = false
    session.setup_step = 0
  }

  fmt.println("=== setup ===")

  // [1] Core + srvsync + focus - anchor by name (position-free), then derive everything downstream.
  setup_step_mark(session, 1)
  fmt.printfln("[1/9] core + srvsync + focus  (anchoring on '%s')", name)
  player, noff, ok := find_player_by_name(session, name)
  if !ok {
    fmt.eprintfln("  could not find a mover named '%s' - are you FULLY in-game (not at a loading screen) and is the name exact (case-sensitive)?", name)
    return
  }
  calibrate_derive(session, player, session.layout.pos_off, noff, has_hp, hp)

  // [2] Attackable-monster prop gate - just needs a few distinct monster species on screen (no target).
  setup_step_mark(session, 2)
  fmt.println("\n[2/9] attackable-monster prop gate (findprop - a few distinct monsters on screen)")
  cli_findprop(session, {})

  // [3] Decorative (walk-through) prop filter - full-scan, so all nearby props feed the consensus.
  setup_step_mark(session, 3)
  fmt.println("\n[3/9] walk-through-prop collision filter (collscan)")
  cli_collscan(session, {})

  // [4] Terrain reachability - best effort; wants flat solid ground.
  setup_step_mark(session, 4)
  fmt.println("\n[4/9] terrain reachability (worldscan - stand on flat ground; may need a 2nd sample)")
  cli_worldscan(session, {})

  // [5] Character control (moveto / jump) - derives the dest-field offsets + SendActMsg RVA + jump_msg.
  setup_step_mark(session, 5)
  fmt.println("\n[5/9] character control (findmove - moveto + jump)")
  cli_findmove(session, {})

  // [6] Render camera - enables the tdbg cull-cone overlay + the radar's camera frustum (F). Read-only scan.
  setup_step_mark(session, 6)
  fmt.println("\n[6/9] render camera (findcam)")
  cli_findcam(session, {})

  // [7] Mesh-reach RVA - pins IntersectObjLine so `meshreach`/`objline`/`reachcmp` work. Read-only scan.
  setup_step_mark(session, 7)
  fmt.println("\n[7/9] mesh-reach function (findobjline)")
  cli_findobjline(session, {})

  // [8] Attack range - drives the picker's engage/melee ranges.
  setup_step_mark(session, 8)
  fmt.println("\n[8/9] attack range")
  if session.layout.attack_range <= 0 {
    session.layout.attack_range = 1.75 // melee default; the user should set their real reach
    flyff_save_cfg(session.layout, flyff_cfg_path())
    fmt.println("  attack_range was unset -> defaulted to 1.75 (melee). Set your real reach: set attack_range <n>")
  } else {
    fmt.printfln("  attack_range = %v. Change with: set attack_range <n>", session.layout.attack_range)
  }

  // [9] Inventory-full detector - auto-locate m_Inventory header + element stride. Read-only scan.
  setup_step_mark(session, 9)
  fmt.println("\n[9/9] inventory-full detector (findinv)")
  cli_findinv(session, {})

  setup_report(session)
}

// One setup group for the shared checklist: whether it's pinned, its label, and the in-game condition to
// fix it. `required` groups (core/srvsync/prop) must be pinned for auto; the rest just improve reliability.
Setup_Group :: struct {
  ok:       bool,
  required: bool,
  label:    string,
  need:     string,
}

// The live setup checklist - shared by the `setup` summary and the `status` babysitter top-line, so they
// never drift. Reads the live layout (each finder auto-pins its fields) + resolves the anchors.
setup_groups :: proc(session: ^Session) -> [10]Setup_Group {
  L := session.layout
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := engine.Value_Type.U32
  core_ok := session.attached && read_ptr_at(handle, base + L.world_rva, pt) != 0 && read_ptr_at(handle, base + L.player_rva, pt) != 0
  char_ctrl_ok :=
    L.destpos_off != 0 && L.iddest_off != 0 && L.forward_off != 0 && // moveto (field-write)
    sendactmsg_rva_sane(session) && L.actmover_off != 0 && L.jump_msg != 0 // jump (SendActMsg call)
  return [10]Setup_Group {
    {core_ok, true, "core (see/select targets)", "be fully in-game, then `setup <name>`"},
    {L.objid_off != 0 && L.sendsettarget_rva != 0, true, "srvsync (anti-disconnect)", "select a mob and re-run `setup` (or `findsettarget`)"},
    {prop_gate_live_ok(session), true, "attackable-monster gate", "get a few distinct monsters on screen, re-run `setup` (or `findprop`)"},
    {L.coll_obj3d_off != 0 && L.coll_type_off != 0, false, "walk-through-prop filter", "stand where props are on screen, re-run `setup`"},
    {terrain_ready(session), false, "terrain reachability", "stand on flat solid ground, re-run `setup` (or `worldscan`)"},
    {char_ctrl_ok, false, "character control (moveto/jump)", "be in-game, re-run `setup` (or `findmove`)"},
    {L.attack_range > 0, false, "attack range", "`set attack_range <n>` to your reach"},
    {L.camera_rva != 0, false, "camera / tdbg cull-cone", "be in-game, re-run `setup` (or `findcam`)"},
    {intersectobjline_rva_sane(session), false, "mesh-reach function (objline)", "re-run `setup` (or `findobjline`)"},
    {L.inv_off != 0 && L.item_stride != 0, false, "inventory-full detector", "be in-game, re-run `setup` (or `findinv`)"},
  }
}

// Optional layout pins that `setup` does NOT cover - each just enables an extra feature and is pinned by
// its own finder (re-pin after a game patch). None is required for `auto`; surfaced under `status` so
// they're discoverable. Reuses Setup_Group: `label` = the feature, `need` = the finder that pins it.
optional_pins :: proc(session: ^Session) -> [3]Setup_Group {
  L := session.layout
  return [3]Setup_Group {
    {L.particlemng_rva != 0 && L.createparticle_rva != 0, false, "in-world markers / mark / ring", "findparticle"},
    {L.penya_off != 0, false, "penya pop (radar juice)", "findpenya <current-penya>"},
    {L.leaderboard_url != "", false, "leaderboard backend", "set leaderboard_url <url>"},
  }
}

// Compact one-liner for `status`: SETUP n/m + the single next action (first unpinned group).
setup_status_line :: proc(session: ^Session) -> string {
  groups := setup_groups(session)
  done := 0
  next := ""
  for g in groups {
    if g.ok {
      done += 1
    } else if next == "" {
      next = fmt.tprintf("%s -> %s", g.label, g.need)
    }
  }
  if done == len(groups) {
    return fmt.tprintf("SETUP %d/%d COMPLETE", done, len(groups))
  }
  return fmt.tprintf("SETUP %d/%d - NEXT: %s", done, len(groups), next)
}

// Prescriptive per-group verdict printed at the end of setup: [OK] / [NEEDS <condition>] per group, then
// an overall readiness line. Uses the shared checklist so it matches `status` exactly.
setup_report :: proc(session: ^Session) {
  groups := setup_groups(session)
  fmt.println("\n=== setup summary ===")
  done := 0
  required_ok := true
  for g in groups {
    if g.ok {
      fmt.printfln("  [OK]    %s", g.label)
      done += 1
    } else {
      fmt.printfln("  [NEEDS] %-27s -> %s", g.label, g.need)
      if g.required {
        required_ok = false
      }
    }
  }
  switch {
  case done == len(groups):
    fmt.println("  => SETUP COMPLETE - run `auto` to farm.")
  case required_ok:
    fmt.println("  => READY for `auto` (required pinned). The [NEEDS] items above just improve reliability.")
  case:
    fmt.println("  => NOT ready - fix the [NEEDS] items above and re-run `setup <name>`.")
  }
}
