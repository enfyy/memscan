package flyff
import "../engine"

import "core:fmt"
import "core:mem"
import "core:os"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"

// ===========================================================================
// Runtime Flyff layout: config file + calibration.
//
// Offsets/RVAs live in Session.layout (core.odin Flyff_Layout), seeded from
// flyff_layout_default(), overwritten by flyff.cfg on attach, re-derived by `calibrate`,
// and persisted back. A game patch shifts them; re-running `calibrate` fixes everything
// with no rebuild. See net-package-targeting.md.
// ===========================================================================

// Path of flyff.cfg, next to the memscan executable.
flyff_cfg_path :: proc(allocator := context.temp_allocator) -> string {
  exe := os.args[0]
  slash := strings.last_index_any(exe, "\\/")
  dir := slash >= 0 ? exe[:slash] : "."
  return fmt.aprintf("%s/flyff.cfg", dir, allocator = allocator)
}

// Assign one layout field by name. Shared by the config loader and `set`. Unknown key -> false.
layout_set_field :: proc(layout: ^Flyff_Layout, key: string, v: u64) -> bool {
  switch key {
  case "world_rva":
    layout.world_rva = uintptr(v)
  case "player_rva":
    layout.player_rva = uintptr(v)
  case "focus_off":
    layout.focus_off = i64(v)
  case "pos_off":
    layout.pos_off = i64(v)
  case "field_off":
    layout.field_off = i64(v)
  case "name_off":
    layout.name_off = i64(v)
  case "hp_off":
    layout.hp_off = i64(v)
  case "model_off":
    layout.model_off = i64(v)
  case "angle_off":
    layout.angle_off = i64(v)
  case "mover_type":
    layout.mover_type = u32(v)
  case "objid_off":
    layout.objid_off = i64(v)
  case "propmover_rva":
    layout.propmover_rva = uintptr(v)
  case "moverprop_stride":
    layout.moverprop_stride = i64(v)
  case "moverprop_ai_off":
    layout.moverprop_ai_off = i64(v)
  case "sendsettarget_rva":
    layout.sendsettarget_rva = uintptr(v)
  case "gdplay_rva":
    layout.gdplay_rva = uintptr(v)
  case "particlemng_rva":
    layout.particlemng_rva = uintptr(v)
  case "createparticle_rva":
    layout.createparticle_rva = uintptr(v)
  case "land_off":
    layout.land_off = i64(v)
  case "landwidth_off":
    layout.landwidth_off = i64(v)
  case "mpu_off":
    layout.mpu_off = i64(v)
  case "hmap_off":
    layout.hmap_off = i64(v)
  case "attack_range":
    layout.attack_range = f32(v) // integer fallback; cli_set / flyff_load_cfg parse it as a float first
  case "aobjcull_rva":
    layout.aobjcull_rva = uintptr(v)
  case "camera_rva":
    layout.camera_rva = uintptr(v)
  case "coll_obj3d_off":
    layout.coll_obj3d_off = i64(v)
  case "coll_type_off":
    layout.coll_type_off = i64(v)
  case "intersectobjline_rva":
    layout.intersectobjline_rva = uintptr(v)
  case "landobj_off":
    layout.landobj_off = i64(v)
  case:
    return false
  }
  return true
}

flyff_save_cfg :: proc(layout: Flyff_Layout, path: string) -> bool {
  b := strings.builder_make(context.temp_allocator)
  fmt.sbprintln(&b, "# memscan Flyff layout - auto-written by 'calibrate' / 'set' / 'offsets save'.")
  fmt.sbprintln(&b, "# Values may be hex (0x..) or decimal. Re-run 'calibrate' after a game patch.")
  fmt.sbprintfln(&b, "world_rva=0x%X", layout.world_rva)
  fmt.sbprintfln(&b, "player_rva=0x%X", layout.player_rva)
  fmt.sbprintfln(&b, "focus_off=0x%X", layout.focus_off)
  fmt.sbprintfln(&b, "pos_off=0x%X", layout.pos_off)
  fmt.sbprintfln(&b, "field_off=0x%X", layout.field_off)
  fmt.sbprintfln(&b, "name_off=0x%X", layout.name_off)
  fmt.sbprintfln(&b, "hp_off=0x%X", layout.hp_off)
  fmt.sbprintfln(&b, "model_off=0x%X", layout.model_off)
  fmt.sbprintfln(&b, "angle_off=0x%X", layout.angle_off)
  fmt.sbprintfln(&b, "mover_type=%d", layout.mover_type)
  fmt.sbprintfln(&b, "objid_off=0x%X", layout.objid_off)
  fmt.sbprintfln(&b, "propmover_rva=0x%X", layout.propmover_rva)
  fmt.sbprintfln(&b, "moverprop_stride=0x%X", layout.moverprop_stride)
  fmt.sbprintfln(&b, "moverprop_ai_off=0x%X", layout.moverprop_ai_off)
  fmt.sbprintfln(&b, "sendsettarget_rva=0x%X", layout.sendsettarget_rva)
  fmt.sbprintfln(&b, "gdplay_rva=0x%X", layout.gdplay_rva)
  fmt.sbprintfln(&b, "particlemng_rva=0x%X", layout.particlemng_rva)
  fmt.sbprintfln(&b, "createparticle_rva=0x%X", layout.createparticle_rva)
  fmt.sbprintfln(&b, "land_off=0x%X", layout.land_off)
  fmt.sbprintfln(&b, "landwidth_off=0x%X", layout.landwidth_off)
  fmt.sbprintfln(&b, "mpu_off=0x%X", layout.mpu_off)
  fmt.sbprintfln(&b, "hmap_off=0x%X", layout.hmap_off)
  fmt.sbprintfln(&b, "attack_range=%v", layout.attack_range)
  fmt.sbprintfln(&b, "aobjcull_rva=0x%X", layout.aobjcull_rva)
  fmt.sbprintfln(&b, "camera_rva=0x%X", layout.camera_rva)
  fmt.sbprintfln(&b, "coll_obj3d_off=0x%X", layout.coll_obj3d_off)
  fmt.sbprintfln(&b, "coll_type_off=0x%X", layout.coll_type_off)
  fmt.sbprintfln(&b, "intersectobjline_rva=0x%X", layout.intersectobjline_rva)
  fmt.sbprintfln(&b, "landobj_off=0x%X", layout.landobj_off)
  err := os.write_entire_file(path, transmute([]byte)strings.to_string(b))
  return err == nil
}

flyff_load_cfg :: proc(layout: ^Flyff_Layout, path: string) -> bool {
  data, err := os.read_entire_file(path, context.temp_allocator)
  if err != nil {
    return false
  }
  content := string(data)
  lines := strings.split(content, "\n", context.temp_allocator)
  for raw in lines {
    line := strings.trim_space(raw)
    if line == "" || strings.has_prefix(line, "#") {
      continue
    }
    eq := strings.index_byte(line, '=')
    if eq < 0 {
      continue
    }
    key := strings.trim_space(line[:eq])
    val := strings.trim_space(line[eq + 1:])
    if key == "attack_range" {
      if fv, ok := strconv.parse_f64(val); ok {
        layout.attack_range = f32(fv) // the one fractional field (e.g. 1.75 melee)
      }
      continue
    }
    v, vok := engine.parse_addr(val)
    if !vok {
      continue
    }
    layout_set_field(layout, key, u64(v))
  }
  return true
}

// ---------------------------------------------------------------------------
// status / offsets / set / findpos commands
// ---------------------------------------------------------------------------

// status -> compact glance: one line per setup step, [OK] / [MISSING] (+ the command to fix a miss).
// `status full` (or `offsets`) dumps the raw offsets + live-probe detail. Both read the same shared
// setup_groups checklist, so the glance and the detail never disagree.
cli_status :: proc(session: ^Session, args: []string) {
  if len(args) >= 1 {
    switch args[0] {
    case "full", "-v", "verbose", "all", "detail", "offsets":
      cli_status_full(session)
      return
    }
  }
  fmt.println("=== memscan status ===")
  if !session.attached {
    fmt.println("process : NOT attached   fix: attach <Neuz|pid>")
    return
  }
  pname := session.proc_info.name == "" ? "Neuz" : session.proc_info.name
  fmt.printfln(
    "process : %s pid %d (%s)",
    pname, session.proc_info.pid, session.ptr_size == 4 ? "32-bit" : "64-bit - WRONG, need 32-bit Neuz",
  )
  fmt.printfln("%s", setup_status_line(session))
  for g in setup_groups(session) {
    if g.ok {
      fmt.printfln("  [OK]      %s", g.label)
    } else {
      fmt.printfln("  [MISSING] %-24s -> %s", g.label, g.need)
    }
  }
  if L := session.layout; L.objid_off != 0 && L.sendsettarget_rva != 0 && !session.srvsync_on {
    fmt.println("  note: srvsync is OFF right now - `srvsync on` (defaults on at attach)")
  }
  fmt.println("optional extras (not part of `setup` - pin only if you want the feature):")
  for o in optional_pins(session) {
    fmt.printfln("  %-5s %-32s %s", o.ok ? "[OK]" : "[--]", o.label, o.need)
  }
  fmt.println("more detail: `status full`")
}

// status full / doctor -> health-check of the live setup: what's configured, what's missing, what each
// thing means, and the command to fix it. Groups the layout by role (core / srvsync / pet exclusion)
// and does light live probes (attached, 32-bit, world/player resolve). Supersedes the raw dump.
cli_status_full :: proc(session: ^Session) {
  L := session.layout
  fmt.println("=== memscan status ===")

  if !session.attached {
    fmt.println("process : NOT attached")
    fmt.println("  the layout only becomes live once you attach (that's when flyff.cfg loads).")
    fmt.println("  fix     : attach <Neuz|pid>   then run 'status' again")
    return
  }

  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  pt := session.ptr_size == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  fmt.printfln("process : %s (pid %d), %s", session.proc_info.name, session.proc_info.pid, session.ptr_size == 4 ? "32-bit WOW64" : "64-bit")
  if session.ptr_size != 4 {
    fmt.println("  WARNING : Flyff automation targets the 32-bit Neuz.exe - this process is 64-bit.")
  }

  // Prescriptive top-line: how far setup is + the single next action (the detail sections below are why).
  fmt.printfln(">> %s", setup_status_line(session))

  // --- Core layout (calibrate) ---
  world := read_ptr_at(handle, base + L.world_rva, pt)
  player := read_ptr_at(handle, base + L.player_rva, pt)
  player_vt_ok := player != 0 && in_module_range(read_ptr_at(handle, player, pt), base, mod_end)
  fmt.println("")
  fmt.println("CORE LAYOUT (from 'calibrate') - needed to see & select targets:")
  fmt.printfln("  world_rva=0x%X player_rva=0x%X focus_off=0x%X pos_off=0x%X", L.world_rva, L.player_rva, L.focus_off, L.pos_off)
  fmt.printfln("  field_off=0x%X name_off=0x%X model_off=0x%X hp_off=0x%X", L.field_off, L.name_off, L.model_off, L.hp_off)
  if world != 0 && player_vt_ok {
    fmt.println("  [OK] anchors resolve to live objects - 'mobs' / 'target_closest' / 'auto' should work.")
  } else {
    fmt.println("  [BROKEN] world/player anchor doesn't resolve - enumeration will fail or crash.")
    fmt.println("    fix: are you fully in-game? then select a mob and run:")
    fmt.println("         calibrate <x,y,z> <name> <hp>   (x,y,z from /position)")
  }

  // --- srvsync / anti-DC ---
  srv_cfg := L.objid_off != 0 && L.sendsettarget_rva != 0 && session.ptr_size == 4
  fmt.println("")
  fmt.println("SRVSYNC / anti-disconnect (from 'calibrate' or 'findsettarget'):")
  fmt.printfln("  objid_off=0x%X  sendsettarget_rva=0x%X", L.objid_off, L.sendsettarget_rva)
  if srv_cfg {
    fmt.printfln("  [OK] configured; srvsync is %s. Each select is mirrored to the server, so you", session.srvsync_on ? "ON" : "OFF")
    fmt.println("       won't disconnect after farming a while.")
    if !session.srvsync_on {
      fmt.println("       note: it's OFF right now - 'srvsync on' to enable (it defaults on at attach).")
    }
  } else {
    fmt.println("  [MISSING] srvsync is INERT -> you WILL disconnect after farming a while.")
    fmt.println("    fix: findsettarget    (or just re-run 'calibrate' - it derives these too)")
  }

  // --- Species prop-table gate for no-name auto ---
  fmt.println("")
  fmt.println("ATTACKABLE-MONSTER gate for no-name 'auto' (any-monster mode) - species GetProp()->dwAI == AII_MONSTER:")
  fmt.printfln("  propmover_rva=0x%X moverprop_stride=0x%X moverprop_ai_off=0x%X", L.propmover_rva, L.moverprop_stride, L.moverprop_ai_off)
  if L.propmover_rva != 0 && L.moverprop_stride != 0 {
    pb := read_ptr_at(handle, base + L.propmover_rva, pt)
    if pb != 0 {
      fmt.println("  [OK] 'auto any' targets only AII_MONSTER species; pets / eggs / NPCs / other players / bosses are skipped.")
    } else {
      fmt.println("  [BROKEN] prop offsets set but the array pointer doesn't resolve - re-run 'findprop' in-game.")
    }
  } else {
    fmt.println("  [OFF] not configured - 'auto any' can target your pet / other pets / NPCs.")
    fmt.println("    fix: target your PET (with monsters on screen) and run 'findprop' once.")
    fmt.println("    only matters if you use 'auto' with NO name; farming by name is unaffected.")
  }

  // --- Terrain reachability oracle (worldscan) ---
  fmt.println("")
  fmt.println("TERRAIN reachability oracle (from 'worldscan') - reach-gated target selection - OPTIONAL:")
  fmt.printfln("  land_off=0x%X landwidth_off=0x%X hmap_off=0x%X mpu_off=0x%X", L.land_off, L.landwidth_off, L.hmap_off, L.mpu_off)
  fmt.printfln("  attack_range=%v  <- your reach; drives target selection (the picker's engage range) AND 'reach'. 'set attack_range <n>' (floats ok, e.g. 1.75).", L.attack_range)
  fmt.printfln(
    "  object reach: cached full-scan (finds every collidable prop; no findcull needed)   auto reach-gate: %s",
    session.reach_gate_on ? (world != 0 ? "ON" : "on (activates once in-game)") : "OFF",
  )
  coll_set := L.coll_obj3d_off != 0 && L.coll_type_off != 0
  fmt.printfln(
    "  coll_obj3d_off=0x%X coll_type_off=0x%X  decorative-prop filter: %s",
    L.coll_obj3d_off, L.coll_type_off,
    coll_set ? "ON (skips no-mesh OT_OBJ)" : "OFF (run 'collscan' to pin)",
  )
  if coll_set && player != 0 {
    // Live probe: the player is a mover with a model, so chasing the pinned coll chain should decode a
    // valid GMTYPE. Garbage here = the offsets shifted (a patch); re-run 'collscan' to re-pin.
    if t, tok := obj_coll_type(session, player); tok && t >= GMT_ERROR && t <= GMT_BONE {
      fmt.printfln("    [OK] player model coll type reads %s - coll offsets valid.", gmt_name(t))
    } else {
      fmt.println("    [SUSPECT] player model coll type won't decode - re-run 'collscan' (a patch shifted the offsets).")
    }
  }
  meshreach_inert := !intersectobjline_rva_sane(session)
  fmt.printfln(
    "  intersectobjline_rva=0x%X  mesh-reach confirm: %s",
    L.intersectobjline_rva,
    session.mesh_reach_on ? (meshreach_inert ? "on but inert (RVA unset / prologue mismatch)" : "ON (injects; crash-prone)") : "OFF (default; safe - decorative filter above needs no injection)",
  )
  if L.intersectobjline_rva != 0 && !meshreach_inert {
    fmt.println("    [OK] IntersectObjLine prologue verified - safe to CALL, but the injection races the game's world lists; leave OFF for farming.")
  } else if L.intersectobjline_rva != 0 {
    fmt.println("    [note] IntersectObjLine prologue doesn't match - a patch moved it; run 'findobjline' to re-pin it before 'meshreach on'.")
  }
  // Camera-independent obstacle source (CLandscape.m_apObject flat arrays). Live-probe the player tile's
  // OT_OBJ count; a plausible value confirms landobj_off. This is what makes reach see off-camera props.
  camindep := L.landobj_off != 0 && L.land_off != 0 && L.landwidth_off != 0
  fmt.printfln(
    "  landobj_off=0x%X  reach object source: %s",
    L.landobj_off,
    camindep ? "CAMERA-INDEPENDENT (tile object arrays - sees off-screen props)" : "camera-culled (m_aobjCull only) - run 'worldscan'",
  )
  if camindep && world != 0 {
    mpu := f32(world_mpu(session, world))
    lw := read_i32_at(handle, world + uintptr(L.landwidth_off))
    arr := read_ptr_at(handle, world + uintptr(L.land_off), pt)
    if lw > 0 && is_heap_ptr(session, arr) {
      ppos, pok2 := engine.read_vec3(handle, player + uintptr(L.pos_off))
      if pok2 {
        m_x := int(ppos[0] / mpu) / MAP_SIZE
        m_z := int(ppos[2] / mpu) / MAP_SIZE
        pland := read_ptr_at(handle, arr + uintptr((m_x + m_z * int(lw)) * session.ptr_size), pt)
        cnt := read_i32_at(handle, pland + uintptr(L.landobj_off + LANDOBJ_MAX_ARRAY * 4)) // m_adwObjNum[OT_OBJ]
        if is_heap_ptr(session, pland) && cnt > 0 && cnt < 200000 {
          fmt.printfln("    [OK] your tile lists %d static objects (m_apObject[OT_OBJ]) - landobj_off valid.", cnt)
        } else {
          fmt.println("    [SUSPECT] tile object count won't decode - landobj_off may have shifted (a patch).")
        }
      }
    }
  }
  if !terrain_ready(session) {
    fmt.println("  [OFF] terrain grid not calibrated - 'attr' / 'reach' are inert.")
    fmt.println("    fix: stand on solid flat ground and run 'worldscan' (repeat at a clearly")
    fmt.println("         different ground height until it PINS to one hypothesis).")
  } else if world == 0 {
    fmt.println("  [BROKEN] terrain offsets pinned but world doesn't resolve - run 'calibrate'.")
  } else {
    // Live probe: the player stands on walkable ground, so their own cell should decode as
    // NONE at ~their Y. A mismatch means the pinned offsets are wrong (e.g. a coincidental
    // single-sample worldscan) - re-run worldscan at a second ground height.
    ppos, pok := engine.read_vec3(handle, player + uintptr(L.pos_off))
    wa, wok := world_attr_at(session, world, ppos[0], ppos[2])
    if pok && wok {
      d := wa.height - ppos[1]
      if wa.attr == HATTR_NONE && d >= -8 && d <= 8 {
        fmt.printfln("  [OK] feet read NONE (walkable), height delta %.1f - 'reach' verdicts should be trustworthy.", d)
      } else {
        fmt.printfln("  [SUSPECT] feet read %s, height delta %.1f - re-run 'worldscan' on flat ground.", hattr_name(wa.attr), d)
      }
    } else {
      fmt.println("  [SUSPECT] offsets pinned but the player's own cell won't resolve - re-run 'worldscan'.")
    }
  }

  fmt.println("")
  fmt.println("SETUP - the whole thing is one command (re-run after a game patch):")
  fmt.println("  setup <name> [hp]            stand in a field on the ground, target your PET with monsters on screen, then")
  fmt.println("                               run it. Anchors on your character NAME (no /position) and pins EVERYTHING:")
  fmt.println("                               core + srvsync + focus + prop-gate + coll-filter + terrain. Re-runnable.")
  fmt.println("  the finish checklist (above / the >> line) tells you exactly what still needs a different spot.")
  fmt.println("")
  fmt.println("manual / advanced pins (setup runs these for you; use standalone if something needs a specific spot):")
  fmt.println("  calibrate <pos> <name> [hp]  core + srvsync from /position (name-anchor fallback for a recompiled client)")
  fmt.println("  findprop / collscan / worldscan   the prop-gate / walk-through filter / terrain pins individually")
  fmt.println("  findcam / findobjline        optional: render camera (tdbg cone) / mesh-reach RVA (only for 'meshreach on')")
  fmt.println("")
  fmt.println("edit any field with 'set <field> <value>' (auto-saves flyff.cfg). 'setup'/'calibrate' preserve every non-core pin.")
}

// offsets              -> show the health-check ('status')
// offsets save [path]  -> write the layout to flyff.cfg (or <path>)
// offsets load [path]  -> read it back
// offsets reset        -> restore built-in defaults (in memory; 'offsets save' to persist)
cli_offsets :: proc(session: ^Session, args: []string) {
  if len(args) >= 1 {
    switch args[0] {
    case "save":
      if !session.attached {
        fmt.eprintln(
          "attach first - the live layout is the built-in defaults until you attach (which loads flyff.cfg); saving now would overwrite flyff.cfg with defaults.",
        )
        return
      }
      path := len(args) >= 2 ? args[1] : flyff_cfg_path()
      if flyff_save_cfg(session.layout, path) {
        fmt.printfln("saved layout -> %s", path)
      } else {
        fmt.eprintfln("failed to write %s", path)
      }
      return
    case "load":
      path := len(args) >= 2 ? args[1] : flyff_cfg_path()
      if flyff_load_cfg(&session.layout, path) {
        fmt.printfln("loaded layout <- %s", path)
      } else {
        fmt.eprintfln("no config at %s (keeping current).", path)
      }
      return
    case "reset":
      session.layout = flyff_layout_default()
      fmt.println("layout reset to built-in defaults (not saved; 'offsets save' to persist).")
      return
    }
  }
  cli_status_full(session)
}

// set <field> <value> -> set one layout field and auto-save flyff.cfg.
cli_set :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln(
      "attach first - the live layout is the built-in defaults until you attach (which loads flyff.cfg). Setting now would auto-save those defaults over your flyff.cfg.",
    )
    return
  }
  if len(args) < 2 {
    fmt.eprintln("usage: set <field> <value>   (field names: see 'offsets')")
    return
  }
  // attack_range is the one fractional field (e.g. 1.75 melee) - parse it as a float, not an integer.
  if args[0] == "attack_range" {
    fv, ok := strconv.parse_f64(args[1])
    if !ok || fv < 0 {
      fmt.eprintfln("invalid value: %s (want a number >= 0, e.g. 1.75)", args[1])
      return
    }
    session.layout.attack_range = f32(fv)
    fmt.printfln("set attack_range = %v", session.layout.attack_range)
    if flyff_save_cfg(session.layout, flyff_cfg_path()) {
      fmt.printfln("saved -> %s", flyff_cfg_path())
    }
    return
  }
  v, vok := engine.parse_addr(args[1])
  if !vok {
    fmt.eprintfln("invalid value: %s", args[1])
    return
  }
  if !layout_set_field(&session.layout, args[0], u64(v)) {
    fmt.eprintfln("unknown field '%s' (run 'offsets' for the field names).", args[0])
    return
  }
  fmt.printfln("set %s = 0x%X", args[0], v)
  path := flyff_cfg_path()
  if flyff_save_cfg(session.layout, path) {
    fmt.printfln("saved -> %s", path)
  }
}

// findpos <x,y,z> [eps] -> addresses whose 3 contiguous f32 match the position (recon primitive).
cli_findpos :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: findpos <x,y,z> [eps]   (x,y,z from /position; eps default 1.0)")
    return
  }
  pos, pok := parse_vec3_literal(args[0])
  if !pok {
    fmt.eprintln("expected x,y,z (commas, no spaces).")
    return
  }
  eps: f32 = 1.0
  if len(args) >= 2 {
    if e, eok := strconv.parse_f64(args[1]); eok {
      eps = f32(e)
    }
  }
  hits := engine.scan_vec3(session.proc_info.handle, pos, eps, context.temp_allocator)
  fmt.printfln("findpos (%.1f, %.1f, %.1f) eps %.2f: %d hit(s)", pos[0], pos[1], pos[2], eps, len(hits))
  for h, i in hits {
    if i >= 40 {
      fmt.printfln("  ... (%d more)", len(hits) - i)
      break
    }
    fmt.printfln("  0x%X", h)
  }
}

// findplayer <name> -> locate the player object by NAME (the position-free anchor `setup` uses). Prints
// the resolved object + name_off + position and cross-checks it against [base+player_rva] so you can see
// they agree. Read-only; validation aid for the name-anchored setup.
cli_findplayer :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: findplayer <name>")
    return
  }
  name := strings.trim(strings.join(args, " ", context.temp_allocator), "'\"")
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := session.ptr_size == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  obj, noff, ok := find_player_by_name(session, name)
  if !ok {
    fmt.eprintfln("findplayer: no mover named '%s' resolved (struct offsets may have moved - use 'calibrate <pos> <name>').", name)
    return
  }
  pos, _ := engine.read_vec3(handle, obj + uintptr(session.layout.pos_off))
  nm, _ := engine.read_obj_name(handle, session.ptr_size, obj, noff)
  fmt.printfln("findplayer '%s' -> obj=0x%X name_off=0x%X pos=(%.1f, %.1f, %.1f) readback='%s'", name, obj, noff, pos[0], pos[1], pos[2], nm)
  rva_player := read_ptr_at(handle, base + session.layout.player_rva, pt)
  if rva_player == obj {
    fmt.printfln("  [OK] matches [base+player_rva]=0x%X - name-anchor agrees with the known player pointer.", rva_player)
  } else {
    fmt.printfln("  [note] [base+player_rva]=0x%X differs (rva stale/patched or ambiguous name); the name-anchor stands on its own.", rva_player)
  }
}

// ---------------------------------------------------------------------------
// calibrate - re-derive the core targeting layout from in-game facts
// ---------------------------------------------------------------------------

// calibrate <x,y,z> <name> [hp]
// One-command layout setup/recovery from facts you can read in-game: <x,y,z> your character
// position (type /position), <name> your character name, [hp] your current HP (optional; pins
// hp_off). Finds pos_off/field_off/model_off/name_off + world_rva/player_rva (+hp_off); on the 32-bit
// client also re-derives the srvsync offsets (sendsettarget_rva + objid_off); and if a mob is SELECTED
// when you run it, also pins focus_off (folds in findfocus). Saves flyff.cfg. So the core setup is one
// command: select a mob, then `calibrate <pos> <name> [hp]`. (The any-monster gate is separate: target
// your pet with monsters on screen and run `findprop` once.)
cli_calibrate :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 2 {
    fmt.eprintln("usage: calibrate <x,y,z> <name> [hp]   (x,y,z from /position; name = your character)")
    return
  }
  pos, pok := parse_vec3_literal(args[0])
  if !pok {
    fmt.eprintln("bad position - use the x,y,z /position shows (commas, no spaces).")
    return
  }
  name := args[1]
  has_hp := false
  hp: i64 = 0
  if len(args) >= 3 {
    if h, hok := strconv.parse_i64(args[2]); hok {
      hp = h
      has_hp = true
    }
  }
  run_calibrate(session, pos, name, has_hp, hp, 1.0)
}

// calibrate_house <name> [hp]
// Convenience wrapper: in your personal house you always spawn at exactly (253, 100, 243) if you
// don't move, so you only supply your character name (and optional HP) - no /position needed. Same
// as `calibrate 253,100,243 <name> [hp]` with a slightly wider position tolerance.
cli_calibrate_house :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: calibrate_house <name> [hp]   (stand still in your house first)")
    return
  }
  name := args[0]
  has_hp := false
  hp: i64 = 0
  if len(args) >= 2 {
    if h, hok := strconv.parse_i64(args[1]); hok {
      hp = h
      has_hp = true
    }
  }
  fmt.println("calibrate_house: using the fixed house spawn (253, 100, 243) - make sure you haven't moved.")
  run_calibrate(session, {253, 100, 243}, name, has_hp, hp, 2.0)
}

// Shared calibration core: derive the layout from a known player position + name (+ optional HP).
// `eps` is the position match tolerance (house spawn is a remembered constant, so it uses more).
run_calibrate :: proc(session: ^Session, pos: [3]f32, name: string, has_hp: bool, hp: i64, eps: f32) {
  handle := session.proc_info.handle
  base := session.proc_info.base
  size := session.proc_info.module_size
  mod_end := base + uintptr(size)
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  L := session.layout

  // 1. Candidate m_vPos addresses at the player's position.
  cands := engine.scan_vec3(handle, pos, eps, context.temp_allocator)
  if len(cands) == 0 {
    fmt.eprintln("no memory matches that position. Type the EXACT values /position shows, then retry.")
    return
  }

  // 2. Identify the player object: for each candidate, try pos_off (current first, then a sweep)
  //    until base = P - pos_off has a module vtable, m_dwType == mover, and holds our name.
  cand_offs := make([dynamic]i64, context.temp_allocator)
  append(&cand_offs, L.pos_off)
  for po := i64(0x40); po <= 0x400; po += 4 {
    if po != L.pos_off {
      append(&cand_offs, po)
    }
  }
  player: uintptr = 0
  pos_off: i64 = 0
  name_off: i64 = 0
  found := false
  outer: for P in cands {
    for po in cand_offs {
      if uintptr(po) > P {
        continue
      }
      obj := P - uintptr(po)
      if !in_module_range(read_ptr_at(handle, obj, pt), base, mod_end) {
        continue // no module vtable at obj -> wrong pos_off / not an object
      }
      ty, tok := engine.read_value(handle, obj + uintptr(po) + 0x10, .U32)
      if !tok || u32(engine.value_as_u64(.U32, ty)) != L.mover_type {
        continue
      }
      noff, nok := find_name_offset(handle, obj, name, 0x4000)
      if !nok {
        continue
      }
      player = obj
      pos_off = po
      name_off = noff
      found = true
      break outer
    }
  }
  if !found {
    fmt.eprintfln(
      "%d position match(es) but none is a mover named '%s'. Check the name and that you're in-game.",
      len(cands),
      name,
    )
    return
  }

  calibrate_derive(session, player, pos_off, name_off, has_hp, hp)
}

// Derive & save the full layout from an already-found player object: field_off/world/world_rva,
// player_rva, hp_off, focus_off (if a mob is selected), and srvsync. Position-INDEPENDENT - shared by the
// position-anchored `run_calibrate` and the name-anchored `setup`. Prints the report + writes flyff.cfg.
// Returns the resolved world (0 if unresolved) so a caller can gate follow-on steps that need it.
calibrate_derive :: proc(session: ^Session, player: uintptr, pos_off, name_off: i64, has_hp: bool, hp: i64) -> (world: uintptr, world_ok: bool) {
  handle := session.proc_info.handle
  base := session.proc_info.base
  size := session.proc_info.module_size
  mod_end := base + uintptr(size)
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  L := session.layout

  // 3. Derive m_pWorld / world / world_rva together. The world is the object field whose pointer
  //    is ALSO held by a static global in the image - unlike per-instance pointers such as
  //    m_pModel, and regardless of whether CWorld starts with a vtable (it doesn't in this build).
  //    Try the contiguous default (pos_off+0xC) first, then sweep, so it survives the field moving.
  model_off := pos_off + 0x18
  field_off := pos_off + 0xC
  world_rva := L.world_rva

  fos := make([dynamic]i64, context.temp_allocator)
  append(&fos, pos_off + 0xC)
  for fo := i64(0); fo <= 0x400; fo += i64(ps) {
    if fo != pos_off + 0xC {
      append(&fos, fo)
    }
  }
  for fo in fos {
    W := read_ptr_at(handle, player + uintptr(fo), pt)
    if W == 0 || in_module_range(W, base, mod_end) {
      continue // 0, or a module/const field - not a heap object pointer
    }
    hits := engine.scan_image_for_ptr(handle, base, size, W, ps, context.temp_allocator)
    if len(hits) > 0 {
      field_off = fo
      world = W
      world_rva = hits[0] - base
      world_ok = true
      break
    }
  }

  // 4. player_rva: the static global holding the player object.
  pr := engine.scan_image_for_ptr(handle, base, size, player, ps, context.temp_allocator)
  player_rva := len(pr) > 0 ? pr[0] - base : L.player_rva

  // 5. hp_off: confirm the current one, else search the object for the HP value.
  hp_off := L.hp_off
  if has_hp {
    cur, cok := engine.read_value(handle, player + uintptr(L.hp_off), .U32)
    if cok && i64(u32(engine.value_as_u64(.U32, cur))) == hp {
      hp_off = L.hp_off
    } else if ho, hok := find_u32_offset(handle, player, u32(hp), 0x4000, L.hp_off); hok {
      hp_off = ho
    }
  }

  // 6. Apply + report + save. focus_off is left as-is (very stable); we just validate it.
  N := L
  N.pos_off = pos_off
  N.field_off = field_off
  N.model_off = model_off
  N.name_off = name_off
  N.world_rva = world_rva
  N.player_rva = player_rva
  N.hp_off = hp_off

  fmt.printfln("calibrated from player obj=0x%X world=0x%X:", player, world)
  report_off("pos_off", L.pos_off, N.pos_off)
  report_off("field_off", L.field_off, N.field_off)
  report_off("model_off", L.model_off, N.model_off)
  report_off("name_off", L.name_off, N.name_off)
  report_off("hp_off", L.hp_off, N.hp_off)
  report_off("world_rva", i64(L.world_rva), i64(N.world_rva))
  report_off("player_rva", i64(L.player_rva), i64(N.player_rva))
  // focus_off: if a mob is selected right now, derive it (folds in findfocus) so a single calibrate
  // covers it too; otherwise keep the (very stable) current value.
  if world_ok {
    fcands := scan_focus_cands(session, world, player)
    if foff, fok := focus_pick(fcands[:], N.focus_off); fok {
      report_off("focus_off", N.focus_off, foff)
      N.focus_off = foff
    } else if len(fcands) > 1 {
      fmt.printfln("  focus_off         0x%X   (kept; %d targets in view - select ONE mob and re-run to pin it)", N.focus_off, len(fcands))
    } else {
      fmt.printfln("  focus_off         0x%X   (kept; no target selected - select a mob and re-run to pin it)", N.focus_off)
    }
  } else {
    fmt.printfln("  focus_off         0x%X   (kept; world unresolved)", N.focus_off)
  }
  if !world_ok {
    fmt.println(
      "  NOTE: couldn't find the world pointer in any static global - world_rva/field_off kept as-is; 'mobs' may fail. Are you fully in-game (not at a loading screen)?",
    )
  }

  // 7. srvsync packet offsets (32-bit client): re-derive sendsettarget_rva + objid_off from the
  //    SendSetTarget signature so a post-patch calibrate fixes them too. Only overwrite on a
  //    confident single hit; otherwise keep what's configured and point at findsettarget.
  if session.ptr_size == 4 {
    st := rank_settarget_cands(session)
    if settarget_confident(st[:]) {
      N.sendsettarget_rva = st[0].target - base
      N.objid_off = st[0].disp
      report_off("sendsettarget_rva", i64(L.sendsettarget_rva), i64(N.sendsettarget_rva))
      report_off("objid_off", L.objid_off, N.objid_off)
    } else if N.sendsettarget_rva == 0 || N.objid_off == 0 {
      fmt.println("  srvsync offsets NOT auto-derived (no confident SendSetTarget signature) - run 'findsettarget'.")
    }
  }

  session.layout = N
  path := flyff_cfg_path()
  if flyff_save_cfg(N, path) {
    fmt.printfln("saved -> %s   (auto-loaded on next attach)", path)
  } else {
    fmt.eprintfln("WARNING: could not write %s (offsets applied in memory only).", path)
  }
  fmt.println("confirm with 'mobs <a nearby mob name>', then use 'target_closest' / 'auto' as usual.")
  return
}

// Candidate for focus_off: a CWorld slot pointing at a live non-player mover (the selected target).
Focus_Cand :: struct {
  off:  i64,
  obj:  uintptr,
  name: string,
  d:    f32,
}

// Scan the CWorld object (first 0x400 bytes) for slots pointing at a live non-player mover - i.e.
// whatever target is selected in-game right now. Shared by findfocus and calibrate.
scan_focus_cands :: proc(session: ^Session, world, player: uintptr) -> [dynamic]Focus_Cand {
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  L := session.layout
  player_pos, _ := engine.read_vec3(handle, player + uintptr(L.pos_off))
  cands := make([dynamic]Focus_Cand, context.temp_allocator)
  for o := i64(0); o <= 0x400; o += i64(ps) {
    W := read_ptr_at(handle, world + uintptr(o), pt)
    if W == 0 || W == player {
      continue
    }
    if !in_module_range(read_ptr_at(handle, W, pt), base, mod_end) {
      continue // target of this slot has no module vtable - not a live object
    }
    if engine.read_obj_type(handle, W, L.pos_off) != L.mover_type {
      continue
    }
    nm, _ := engine.read_obj_name(handle, ps, W, L.name_off)
    pos, _ := engine.read_vec3(handle, W + uintptr(L.pos_off))
    append(&cands, Focus_Cand{o, W, nm, engine.dist_3d(pos, player_pos)})
  }
  return cands
}

// Choose focus_off from the candidates: the sole hit, or (if several targets are in view) the slot
// already at `cur` if it still qualifies. ok=false => none selected or ambiguous.
focus_pick :: proc(cands: []Focus_Cand, cur: i64) -> (off: i64, ok: bool) {
  if len(cands) == 0 {
    return 0, false
  }
  if len(cands) == 1 {
    return cands[0].off, true
  }
  for c in cands {
    if c.off == cur {
      return c.off, true
    }
  }
  return 0, false
}

// findfocus -> derive focus_off (m_pObjFocus in CWorld). CLICK a monster in-game first, then run it:
// it finds the world slot pointing at the selected target and auto-saves focus_off on a single clear
// hit, else lists candidates. calibrate now does this too when a mob is selected, so you usually
// don't need findfocus separately.
cli_findfocus :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  world := read_ptr_at(handle, base + session.layout.world_rva, pt)
  player := read_ptr_at(handle, base + session.layout.player_rva, pt)
  if world == 0 {
    fmt.eprintln("world not resolved - run calibrate / calibrate_house first.")
    return
  }
  cands := scan_focus_cands(session, world, player)
  if len(cands) == 0 {
    fmt.eprintln("no selected target found in the world object. Click a monster in-game, then re-run findfocus.")
    return
  }
  fmt.printfln("%d world slot(s) point at a live non-player mover:", len(cands))
  for c in cands {
    fmt.printfln("  +0x%X -> obj=0x%X '%s' d=%.1f", c.off, c.obj, c.name, c.d)
  }
  off, ok := focus_pick(cands[:], session.layout.focus_off)
  if !ok {
    fmt.println("multiple candidates - pick the one pointing at the monster you clicked and run 'set focus_off 0x..'.")
    return
  }
  session.layout.focus_off = off
  fmt.printfln("focus_off = 0x%X", off)
  if flyff_save_cfg(session.layout, flyff_cfg_path()) {
    fmt.println("saved to flyff.cfg.")
  }
}

// findhp <name> -> derive hp_off (currentHP). Enumerates movers named <name> and finds the 4-byte
// field that stays within each mob's max HP and varies across them - i.e. current HP. DAMAGE a few
// (don't kill) first so current != max, else current is indistinguishable from max. Auto-sets hp_off.
cli_findhp :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: findhp <name>   (damage a few of them first so they're not all full HP)")
    return
  }
  name := strings.trim(strings.join(args, " ", context.temp_allocator), "'\"")
  LEN :: 0x8000

  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  L := session.layout
  wv, wok := engine.read_value(handle, base + L.world_rva, pt)
  if !wok {
    fmt.eprintln("could not read world anchor - run calibrate first.")
    return
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  wval := engine.ptr_to_value(world, ps)
  all := engine.collect_regions(handle, true)
  defer delete(all)
  set := engine.scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)
  bufs := make([dynamic][]byte, context.temp_allocator)
  for m in set.matches {
    obj := uintptr(i64(m.addr) - L.field_off)
    vt, vok := engine.read_value(handle, obj, pt)
    if !vok || !in_module_range(uintptr(engine.value_as_u64(pt, vt)), base, mod_end) {
      continue
    }
    if engine.read_obj_type(handle, obj, L.pos_off) != L.mover_type {
      continue
    }
    nm, nok := engine.read_obj_name(handle, ps, obj, L.name_off)
    if !nok || !strings.contains(nm, name) {
      continue
    }
    b := make([]byte, LEN, context.temp_allocator)
    engine.read_into(handle, obj, b)
    append(&bufs, b)
  }
  n := len(bufs)
  fmt.printfln("findhp '%s': %d movers.", name, n)
  if n < 2 {
    fmt.println("need >=2 of them on screen. get more into view and retry.")
    return
  }

  // maxHP candidates: fields where a majority of mobs share a plausible value (maxHP is constant
  // per species even on damaged mobs; a few transient/just-spawned mobs may differ). We try each.
  MaxCand :: struct {
    off: int,
    val: u32,
    cnt: int,
  }
  maxc := make([dynamic]MaxCand, context.temp_allocator)
  mo := 0
  for mo + 4 <= LEN {
    v, c := hp_modal(bufs, mo)
    if v >= 40 && v <= 1_000_000 && c * 100 >= n * 55 {
      append(&maxc, MaxCand{mo, v, c})
    }
    mo += 4
  }
  if len(maxc) == 0 {
    fmt.println("no stable per-species field to anchor maxHP on. Mixed species/levels? Try a more specific name.")
    return
  }
  anchor := maxc[0] // highest-agreement candidate, for the failure diagnostic
  for mc in maxc {
    if mc.cnt > anchor.cnt || (mc.cnt == anchor.cnt && mc.val > anchor.val) {
      anchor = mc
    }
  }

  // currentHP: for normal mobs (max field == mc.val) values are in [0,max], most alive (cur>0),
  // with some full (==max) and some damaged (0<cur<max). Tolerate a few outliers; rank by full.
  best_co, best_mo, best_full, best_dmg := -1, -1, -1, -1
  best_maxval: u32 = 0
  for mc in maxc {
    co := 0
    for co + 4 <= LEN {
      if co != mc.off {
        norm, alive, full, dmg, over := 0, 0, 0, 0, 0
        for i in 0 ..< n {
          if rd_u32le(bufs[i], mc.off) != mc.val {
            continue
          }
          norm += 1
          cur := rd_u32le(bufs[i], co)
          if cur > mc.val {
            over += 1
          } else if cur > 0 {
            alive += 1
            if cur == mc.val {
              full += 1
            } else {
              dmg += 1
            }
          }
        }
        if over <= max(2, norm / 8) && full >= 1 && dmg >= 1 && alive * 5 >= norm * 2 && full > best_full {
          best_co, best_mo, best_full, best_dmg, best_maxval = co, mc.off, full, dmg, mc.val
        }
      }
      co += 4
    }
  }

  if best_co >= 0 {
    session.layout.hp_off = i64(best_co)
    fmt.printfln(
      "hp_off = 0x%X (currentHP; maxHP %d at +0x%X; %d full, %d damaged of %d sampled).",
      best_co,
      best_maxval,
      best_mo,
      best_full,
      best_dmg,
      n,
    )
    fmt.print("  sample currentHP values:")
    for i in 0 ..< min(n, 14) {
      fmt.printf(" %d", rd_u32le(bufs[i], best_co))
    }
    fmt.println("")
    if flyff_save_cfg(session.layout, flyff_cfg_path()) {
      fmt.println("saved to flyff.cfg.")
    }
    return
  }

  // No clean match - dump diagnostics so currentHP can be picked by eye, then 'set hp_off 0x..'.
  fmt.print("no clean currentHP match. maxHP candidates:")
  for mc, i in maxc {
    if i >= 6 {
      break
    }
    fmt.printf("  +0x%X=%d x%d", mc.off, mc.val, mc.cnt)
  }
  fmt.println("")
  fmt.printfln("fields that vary within [0, %d] (anchor +0x%X, %d/%d mobs):", anchor.val, anchor.off, anchor.cnt, n)
  shown := 0
  dco := 0
  for dco + 4 <= LEN {
    if dco != anchor.off {
      over, dmg, full := 0, 0, 0
      for i in 0 ..< n {
        if rd_u32le(bufs[i], anchor.off) != anchor.val {
          continue
        }
        cur := rd_u32le(bufs[i], dco)
        if cur > anchor.val {
          over += 1
        } else if cur == anchor.val {
          full += 1
        } else if cur > 0 {
          dmg += 1
        }
      }
      if over == 0 && dmg >= 1 && full >= 1 && shown < 16 {
        sb := strings.builder_make(context.temp_allocator)
        fmt.sbprintf(&sb, "  +0x%X full=%d dmg=%d :", dco, full, dmg)
        c2 := 0
        for i in 0 ..< n {
          if c2 >= 10 {
            break
          }
          fmt.sbprintf(&sb, " %d", rd_u32le(bufs[i], dco))
          c2 += 1
        }
        fmt.println(strings.to_string(sb))
        shown += 1
      }
    }
    dco += 4
  }
  if shown == 0 {
    fmt.println("  (none in range - currentHP is likely past the scan window; tell me and I'll widen it)")
  }
}

// hpwatch -> Deterministic currentHP finder (use this when findhp guesses wrong). Click ONE mob to
// target it and keep it selected, run this, then HIT it during the ~3s window. It diffs the mob's
// memory and reports every 4-byte field that DROPPED - currentHP is the one that fell by your hit's
// damage. Auto-sets hp_off if exactly one HP-like field drops.
cli_hpwatch :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  L := session.layout
  world := read_ptr_at(handle, base + L.world_rva, pt)
  if world == 0 {
    fmt.eprintln("world not resolved - run calibrate first.")
    return
  }
  focus := read_ptr_at(handle, world + uintptr(L.focus_off), pt)
  if focus == 0 || !in_module_range(read_ptr_at(handle, focus, pt), base, mod_end) {
    fmt.eprintln("no live mob targeted. Click a monster in-game (keep it selected), then run hpwatch.")
    return
  }
  LEN :: 0x8000
  s1 := make([]byte, LEN, context.temp_allocator)
  n1, _ := engine.read_into(handle, focus, s1)
  fmt.println("HIT the targeted mob NOW - watching ~3s...")
  win.Sleep(3000)
  if !in_module_range(read_ptr_at(handle, focus, pt), base, mod_end) {
    fmt.eprintln("the mob despawned / was freed during the window - retry on a tankier one.")
    return
  }
  s2 := make([]byte, LEN, context.temp_allocator)
  n2, _ := engine.read_into(handle, focus, s2)
  lim := min(int(n1), int(n2))

  Drop :: struct {
    off:    int,
    v1, v2: u32,
  }
  drops := make([dynamic]Drop, context.temp_allocator)
  off := 0
  for off + 4 <= lim {
    v1 := rd_u32le(s1, off)
    v2 := rd_u32le(s2, off)
    if v2 < v1 && v1 <= 2_000_000 && v1 - v2 <= 1_000_000 {
      append(&drops, Drop{off, v1, v2})
    }
    off += 4
  }
  if len(drops) == 0 {
    fmt.println("no field dropped. Did the hit land (mob still alive)? Retry.")
    return
  }
  fmt.printfln("%d field(s) dropped:", len(drops))
  for d in drops {
    fmt.printfln("  +0x%X: %d -> %d  (drop %d)", d.off, d.v1, d.v2, d.v1 - d.v2)
  }
  if len(drops) == 1 {
    session.layout.hp_off = i64(drops[0].off)
    fmt.printfln("hp_off = 0x%X (auto-set: only field that dropped).", drops[0].off)
    if flyff_save_cfg(session.layout, flyff_cfg_path()) {
      fmt.println("saved to flyff.cfg.")
    }
  } else {
    fmt.println("multiple dropped - currentHP is the one that fell by your hit's damage; run 'set hp_off 0x..'.")
  }
}

// findpacket [objid] -> Confirm objid_off AND reveal the renumbered SETTARGET packet id. Target a
// mob and keep it selected, then run this: it reads the mob's objid ([focus+objid_off], or the arg
// if given) and scans memory for that value immediately followed by a 0x02/0x01 (bClear). The
// client's outgoing SendSetTarget packet is [type:4][objid:4][bClear:1], so the 4 bytes in front of
// such a hit ARE the packet id. Click the mob right before running so the send buffer is fresh.
cli_findpacket :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  L := session.layout

  objid: u32 = 0
  if len(args) >= 1 {
    if v, ok := engine.parse_addr(args[0]); ok {
      objid = u32(v)
    }
  }
  if objid == 0 {
    if L.objid_off == 0 {
      fmt.eprintln("objid_off not set. Run 'set objid_off 0x22F8' first, or pass an objid: findpacket <id>.")
      return
    }
    world := read_ptr_at(handle, base + L.world_rva, pt)
    focus := read_ptr_at(handle, world + uintptr(L.focus_off), pt)
    if focus == 0 || !in_module_range(read_ptr_at(handle, focus, pt), base, mod_end) {
      fmt.eprintln("no live mob targeted. Click a monster in-game (keep it selected), then run findpacket.")
      return
    }
    idv, idok := engine.read_value(handle, focus + uintptr(L.objid_off), .U32)
    if !idok {
      fmt.eprintln("couldn't read objid from the target.")
      return
    }
    objid = u32(engine.value_as_u64(.U32, idv))
  }
  if objid == 0 {
    fmt.eprintln("objid is 0 - target a mob first.")
    return
  }

  fmt.printfln("targeted objid = %d (0x%X); scanning memory for [objid][02] packets...", objid, objid)
  pat := [4]byte{byte(objid), byte(objid >> 8), byte(objid >> 16), byte(objid >> 24)}
  hits := engine.scan_bytes(handle, pat[:], context.temp_allocator)

  shown := 0
  for h in hits {
    wb: [16]byte
    rn, _ := engine.read_into(handle, h - 4, wb[:])
    if int(rn) < 9 {
      continue
    }
    // wb[0..3] = 4 bytes before objid (candidate packet type); wb[8] = byte after objid (bClear)
    if wb[8] == 0x02 || wb[8] == 0x01 {
      typ := u32(wb[0]) | u32(wb[1]) << 8 | u32(wb[2]) << 16 | u32(wb[3]) << 24
      fmt.printfln("  0x%X: type=0x%X (objid=%d, bClear=%d)", h, typ, objid, wb[8])
      shown += 1
      if shown >= 20 {
        break
      }
    }
  }
  fmt.printfln("(%d total occurrences of the objid; %d look like SETTARGET packets)", len(hits), shown)
  if shown == 0 {
    fmt.println(
      "no [objid][02] found. Click the mob again right before running (buffer may have flushed); if it never appears the wire is likely encrypted.",
    )
  } else {
    fmt.println("that 'type' is the renumbered PACKETTYPE_SETTARGET - next: codescan 0x<type> to find SendSetTarget.")
  }
}

// packetwatch -> Deterministic SETTARGET-packet finder (use when findpacket only shows coincidental
// hits). Target a mob, run this, then CLICK A DIFFERENT MOB during the window. It snapshots writable
// memory first, then reports only [objid][02] that FRESHLY appeared (bytes changed since the
// snapshot) - stripping every coincidental static match, leaving the actual outgoing packet. The 4
// bytes before it are the renumbered packet id.
cli_packetwatch :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  L := session.layout
  if L.objid_off == 0 {
    fmt.eprintln("objid_off not set. Run 'set objid_off 0x22F8' first.")
    return
  }
  world := read_ptr_at(handle, base + L.world_rva, pt)
  if world == 0 {
    fmt.eprintln("world not resolved - run calibrate first.")
    return
  }
  snap := engine.take_snapshot(handle, .U32, true, context.temp_allocator)
  fmt.printfln(
    "baseline captured (%d regions). Now CLICK A DIFFERENT MOB in-game to send a fresh SETTARGET... (~3s)",
    len(snap.regions),
  )
  win.Sleep(3000)
  focus := read_ptr_at(handle, world + uintptr(L.focus_off), pt)
  if focus == 0 || !in_module_range(read_ptr_at(handle, focus, pt), base, mod_end) {
    fmt.eprintln("no mob targeted after the click - retry and make sure you click a mob.")
    return
  }
  idv, idok := engine.read_value(handle, focus + uintptr(L.objid_off), .U32)
  if !idok {
    fmt.eprintln("couldn't read the new objid.")
    return
  }
  objid := u32(engine.value_as_u64(.U32, idv))
  idb := [4]byte{byte(objid), byte(objid >> 8), byte(objid >> 16), byte(objid >> 24)}
  fmt.printfln("new target objid = %d (0x%X); scanning for freshly-written [objid][02]...", objid, objid)

  found := 0
  outer: for rc in snap.regions {
    cur := make([]byte, len(rc.data), context.temp_allocator)
    n, ok := engine.read_into(handle, rc.base, cur)
    if !ok {
      continue
    }
    lim := min(int(n), len(rc.data))
    off := 4
    for off + 5 <= lim {
      if cur[off] == idb[0] &&
         cur[off + 1] == idb[1] &&
         cur[off + 2] == idb[2] &&
         cur[off + 3] == idb[3] &&
         cur[off + 4] == 0x02 {
        changed := false
        for k in 0 ..< 5 {
          if cur[off + k] != rc.data[off + k] {
            changed = true
            break
          }
        }
        if changed {
          typ := u32(cur[off - 4]) | u32(cur[off - 3]) << 8 | u32(cur[off - 2]) << 16 | u32(cur[off - 1]) << 24
          fmt.printfln("  0x%X: type=0x%X (freshly written)", rc.base + uintptr(off), typ)
          found += 1
          if found >= 20 {
            break outer
          }
        }
      }
      off += 1
    }
  }
  fmt.printfln("(%d freshly-written SETTARGET packet(s))", found)
  if found == 0 {
    fmt.println(
      "nothing new appeared. Either you didn't click a different mob in the window, or the packet is encrypted before reaching a readable buffer. Retry once; if still nothing, it's encryption.",
    )
  } else {
    fmt.println("that NEW type is PACKETTYPE_SETTARGET - run 'codescan 0x<type>' to find SendSetTarget.")
  }
}

// ---------------------------------------------------------------------------
// calibrate helpers (file-scope to avoid shadowing under -vet-shadowing)
// ---------------------------------------------------------------------------

read_ptr_at :: proc(handle: win.HANDLE, addr: uintptr, pt: engine.Value_Type) -> uintptr {
  v, ok := engine.read_value(handle, addr, pt)
  return ok ? uintptr(engine.value_as_u64(pt, v)) : 0
}

in_module_range :: proc(p, base, mod_end: uintptr) -> bool {
  return p >= base && p < mod_end
}

report_off :: proc(field: string, old, new: i64) {
  if old == new {
    fmt.printfln("  %-16s 0x%X", field, new)
  } else {
    fmt.printfln("  %-16s 0x%X   (was 0x%X)", field, new, old)
  }
}

// Find the offset within [obj, obj+span) where `name` appears as an ASCII (NUL/ctrl-terminated)
// or UTF-16LE string. Returns the byte offset. Used to locate the inline name buffer.
find_name_offset :: proc(handle: win.HANDLE, obj: uintptr, name: string, span: int) -> (off: i64, ok: bool) {
  buf := make([]byte, span, context.temp_allocator)
  n, rok := engine.read_into(handle, obj, buf)
  if !rok {
    return 0, false
  }
  nb := transmute([]byte)name
  if len(nb) == 0 {
    return 0, false
  }
  // ASCII, requiring a terminator so we match the whole field, not a longer name's prefix.
  limit := int(n) - len(nb)
  i := 0
  for i <= limit {
    if buf[i] == nb[0] && mem.compare(buf[i:i + len(nb)], nb) == 0 {
      if i + len(nb) >= int(n) {
        return i64(i), true
      }
      end := buf[i + len(nb)]
      if end == 0 || end < 0x20 {
        return i64(i), true
      }
    }
    i += 1
  }
  // UTF-16LE
  wlimit := int(n) - len(nb) * 2
  i = 0
  for i <= wlimit {
    match := true
    for k in 0 ..< len(nb) {
      if buf[i + k * 2] != nb[k] || buf[i + k * 2 + 1] != 0 {
        match = false
        break
      }
    }
    if match {
      return i64(i), true
    }
    i += 1
  }
  return 0, false
}

// Find the offset within [obj, obj+span) whose u32 equals `val`, preferring the one nearest
// `prefer` (so a known-good default wins ties). 4-aligned. Used to pin hp_off.
find_u32_offset :: proc(handle: win.HANDLE, obj: uintptr, val: u32, span: int, prefer: i64) -> (off: i64, ok: bool) {
  buf := make([]byte, span, context.temp_allocator)
  n, rok := engine.read_into(handle, obj, buf)
  if !rok {
    return 0, false
  }
  best: i64 = -1
  o := 0
  for o + 4 <= int(n) {
    v := u32(buf[o]) | u32(buf[o + 1]) << 8 | u32(buf[o + 2]) << 16 | u32(buf[o + 3]) << 24
    if v == val {
      if best < 0 || abs_i64(i64(o) - prefer) < abs_i64(best - prefer) {
        best = i64(o)
      }
    }
    o += 4
  }
  if best < 0 {
    return 0, false
  }
  return best, true
}

// Plausible world position: finite coords in a sane Flyff range. Sanity-gates a name-anchored object
// before we trust the assumed pos_off (a wrong base rarely has 3 plausible position floats at +pos_off).
plausible_world_pos :: proc(p: [3]f32) -> bool {
  for c in p {
    if c != c || c > 1e7 || c < -1e7 { // NaN or absurd magnitude
      return false
    }
  }
  return p[0] >= 0 && p[2] >= 0 && p[0] < 1e6 && p[2] < 1e6 && p[1] > -1e5 && p[1] < 1e5
}

// find_player_by_name - locate the player CMover by scanning memory for the character NAME (ASCII or
// UTF-16LE) and resolving the enclosing mover object. Position-free anchor for `setup`: in run_calibrate
// only object-FINDING needs the typed /position; the name is short to type and everything downstream is
// position-independent. Uses the CURRENT pos_off (stable across config patches) for the mover-type check;
// name_off is re-derived canonically via find_name_offset (matches calibrate). Among matches, prefers the
// one a static global points at (the true player). ok=false => nothing resolved (struct offsets likely
// moved: fall back to `calibrate <pos> <name>`).
find_player_by_name :: proc(session: ^Session, name: string) -> (player: uintptr, name_off: i64, ok: bool) {
  handle := session.proc_info.handle
  base := session.proc_info.base
  size := session.proc_info.module_size
  mod_end := base + uintptr(size)
  ps := session.ptr_size
  L := session.layout
  nb := transmute([]byte)name
  if len(nb) == 0 || ps != 4 {
    return
  }

  // Candidate name-string addresses: ASCII, then UTF-16LE.
  hits := make([dynamic]uintptr, context.temp_allocator)
  for h in engine.scan_bytes(handle, nb, context.temp_allocator) {append(&hits, h)}
  wbytes := make([]byte, len(nb) * 2, context.temp_allocator)
  for i in 0 ..< len(nb) {
    wbytes[i * 2] = nb[i]
  }
  for h in engine.scan_bytes(handle, wbytes, context.temp_allocator) {append(&hits, h)}

  WINDOW :: 0x4000 // max name_off (name buffer sits within this of the object base)
  seen := make(map[uintptr]bool, 256, context.temp_allocator)
  cands := make([dynamic]uintptr, context.temp_allocator)
  noffs := make([dynamic]i64, context.temp_allocator)
  processed := 0
  for N in hits {
    processed += 1
    if processed > 400 {
      break // bound the work; the real object is among the near hits
    }
    lo := N > uintptr(WINDOW) ? N - uintptr(WINDOW) : uintptr(0)
    wlen := int(N - lo)
    if wlen < 4 {
      continue
    }
    buf := make([]byte, wlen, context.temp_allocator)
    rn, _ := engine.read_into(handle, lo, buf)
    if int(rn) < 4 {
      continue
    }
    // Scan backward from the name for the nearest preceding module-vtable that begins a named mover.
    for off := ((int(rn) - 4) / 4) * 4; off >= 0; off -= 4 {
      v := uintptr(rd_u32le(buf, off))
      if v < base || v >= mod_end {
        continue // not an in-module vtable
      }
      B := lo + uintptr(off)
      if u32(read_i32_at(handle, B + uintptr(L.pos_off + 0x10))) != L.mover_type {
        continue // m_dwType != mover
      }
      pos, pok := engine.read_vec3(handle, B + uintptr(L.pos_off))
      if !pok || !plausible_world_pos(pos) {
        continue
      }
      noff, nok := find_name_offset(handle, B, name, 0x4000)
      if !nok {
        continue
      }
      if !seen[B] {
        seen[B] = true
        append(&cands, B)
        append(&noffs, noff)
      }
      break // nearest containing mover for this name hit
    }
  }
  if len(cands) == 0 {
    return
  }
  // Disambiguate: the true player is held by a static global (like player_rva). Prefer such a candidate.
  chosen := 0
  for c, i in cands {
    if len(engine.scan_image_for_ptr(handle, base, size, c, ps, context.temp_allocator)) > 0 {
      chosen = i
      break
    }
  }
  return cands[chosen], noffs[chosen], true
}

parse_vec3_literal :: proc(s: string) -> (pos: [3]f32, ok: bool) {
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

abs_i64 :: proc(x: i64) -> i64 {
  return x < 0 ? -x : x
}

rd_u32le :: proc(b: []byte, off: int) -> u32 {
  return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24
}

// Most common u32 value at byte offset `off` across all sampled mobs, and how many share it.
// Used by findhp to anchor maxHP tolerantly (a few transient mobs won't match the majority).
hp_modal :: proc(bufs: [dynamic][]byte, off: int) -> (val: u32, cnt: int) {
  for k in 0 ..< len(bufs) {
    v := rd_u32le(bufs[k], off)
    c := 0
    for i in 0 ..< len(bufs) {
      if rd_u32le(bufs[i], off) == v {
        c += 1
      }
    }
    if c > cnt {
      cnt = c
      val = v
    }
  }
  return
}
