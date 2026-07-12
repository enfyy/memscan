package flyff

import "core:fmt"
import "core:strconv"
import "core:strings"

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
// Ideal spot: standing in a field, on the ground, with your PET targeted and monsters on screen. That one
// state satisfies core (name anchor), focus_off + prop-gate (pet + monsters), terrain (ground), and the
// collision filter (props on screen) all at once.
// ===========================================================================

cli_setup :: proc(session: ^Session, args: []string) {
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
    fmt.eprintln("  stand in a field on the ground, target your PET with monsters on screen, then run it.")
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

  fmt.println("=== setup ===")

  // [1] Core + srvsync + focus - anchor by name (position-free), then derive everything downstream.
  fmt.printfln("[1/5] core + srvsync + focus  (anchoring on '%s')", name)
  player, noff, ok := find_player_by_name(session, name)
  if !ok {
    fmt.eprintfln("  could not find a mover named '%s' - are you in-game and is the name exact?", name)
    fmt.eprintln("  if the client was recompiled (struct moved), fall back to: calibrate <x,y,z> <name> [hp]")
    return
  }
  calibrate_derive(session, player, session.layout.pos_off, noff, has_hp, hp)

  // [2] Attackable-monster prop gate - needs your PET targeted with monsters on screen.
  fmt.println("\n[2/5] attackable-monster prop gate (findprop - target your PET, monsters on screen)")
  cli_findprop(session, {})

  // [3] Decorative (walk-through) prop filter - full-scan, so all nearby props feed the consensus.
  fmt.println("\n[3/5] walk-through-prop collision filter (collscan)")
  cli_collscan(session, {})

  // [4] Terrain reachability - best effort; wants flat solid ground.
  fmt.println("\n[4/5] terrain reachability (worldscan - stand on flat ground; may need a 2nd sample)")
  cli_worldscan(session, {})

  // [5] Attack range - drives the picker's engage/melee ranges.
  fmt.println("\n[5/5] attack range")
  if session.layout.attack_range <= 0 {
    session.layout.attack_range = 1.75 // melee default; the user should set their real reach
    flyff_save_cfg(session.layout, flyff_cfg_path())
    fmt.println("  attack_range was unset -> defaulted to 1.75 (melee). Set your real reach: set attack_range <n>")
  } else {
    fmt.printfln("  attack_range = %v. Change with: set attack_range <n>", session.layout.attack_range)
  }

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
setup_groups :: proc(session: ^Session) -> [6]Setup_Group {
  L := session.layout
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := engine.Value_Type.U32
  core_ok := session.attached && read_ptr_at(handle, base + L.world_rva, pt) != 0 && read_ptr_at(handle, base + L.player_rva, pt) != 0
  return [6]Setup_Group {
    {core_ok, true, "core (see/select targets)", "be fully in-game, then `setup <name>` (else `calibrate <pos> <name>`)"},
    {L.objid_off != 0 && L.sendsettarget_rva != 0, true, "srvsync (anti-disconnect)", "select a mob and re-run `setup` (or `findsettarget`)"},
    {prop_gate_ready(session), true, "attackable-monster gate", "target your PET with monsters on screen, re-run `setup`"},
    {L.coll_obj3d_off != 0 && L.coll_type_off != 0, false, "walk-through-prop filter", "stand where props are on screen, re-run `setup`"},
    {terrain_ready(session), false, "terrain reachability", "stand on flat solid ground, re-run `setup` (or `worldscan`)"},
    {L.attack_range > 0, false, "attack range", "`set attack_range <n>` to your reach"},
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
    return fmt.tprintf("SETUP %d/%d COMPLETE - run `auto` to farm.", done, len(groups))
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
