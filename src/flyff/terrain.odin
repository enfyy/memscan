package flyff
import "../engine"

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"

// ===========================================================================
// Terrain reachability oracle (obstacle avoidance spike).
//
// Flyff movement is straight-line only: under held-attack the client auto-runs the character
// straight at the focused mob and JAMS if a blocked cell is in the way (ActionMoverCollision.cpp).
// So "can I reach mob M" == "is every cell on the segment player->M walkable". The walkability grid
// is the game's own heightmap: CLandscape.m_pHeightMap is a 129x129 (MAP_SIZE+1) FLOAT* per tile;
// a cell whose height >= 1000 is a blocked-attribute marker (see flyff-terrain-collision memory):
//   >=4000 DIE, >=3000 NOMOVE, >=2000 NOFLY, >=1000 NOWALK, else normal walkable height.
// World coords index it via CWorld: x,z /= m_iMPU, tile = m_apLand[mX + mZ*m_nLandWidth], cell in
// the tile at stride 129. This mirrors CWorld::GetHeightAttribute / CLandscape::GetHeightAttribute.
//
// The four CWorld/CLandscape offsets are pinned live by `worldscan` (self-calibration against the
// player's own ground height). `attr` / `reach` are the debug readouts to validate the oracle
// against real walls before it drives target selection.
// ===========================================================================

MAP_SIZE :: 128 // cells per landscape tile side (compile-time constant in the client)
HMAP_STRIDE :: 129 // heightmap is a corner grid: (MAP_SIZE+1) per row
MPU_DEFAULT :: 4 // meters-per-unit fallback when mpu_off is unknown (classic Flyff maps use 4)

HGT_NOWALK :: f32(1000)
HGT_NOFLY :: f32(2000)
HGT_NOMOVE :: f32(3000)
HGT_DIE :: f32(4000)

HATTR_NONE :: 0
HATTR_NOWALK :: 1 // blocks walking (fly-only zone); a walker jams here
HATTR_NOFLY :: 2 // blocks flying only
HATTR_NOMOVE :: 3 // blocks walking and flying (solid wall)
HATTR_DIE :: 4 // instant-death cell (lava etc.)

hattr_name :: proc(attr: int) -> string {
  switch attr {
  case HATTR_NONE:
    return "NONE (walkable)"
  case HATTR_NOWALK:
    return "NOWALK (fly-only / blocks walk)"
  case HATTR_NOFLY:
    return "NOFLY"
  case HATTR_NOMOVE:
    return "NOMOVE (wall)"
  case HATTR_DIE:
    return "DIE (instant death)"
  }
  return "?"
}

// A walking mover is blocked at NOWALK, NOMOVE and DIE cells (DIE also kills). NOFLY is irrelevant
// on the ground. This is the predicate the pursuit collision uses for held-attack auto-run.
hattr_blocks_walk :: proc(attr: int) -> bool {
  return attr == HATTR_NOWALK || attr == HATTR_NOMOVE || attr == HATTR_DIE
}

// Decode a raw heightmap float into (attribute, true terrain height). Mirrors CLandscape::
// GetHeightMap: blocked cells store their real height plus a HGT_ offset.
decode_hgt :: proc(h: f32) -> (attr: int, height: f32) {
  if h >= HGT_DIE {
    return HATTR_DIE, h - HGT_DIE
  }
  if h >= HGT_NOMOVE {
    return HATTR_NOMOVE, h - HGT_NOMOVE
  }
  if h >= HGT_NOFLY {
    return HATTR_NOFLY, h - HGT_NOFLY
  }
  if h >= HGT_NOWALK {
    return HATTR_NOWALK, h - HGT_NOWALK
  }
  return HATTR_NONE, h
}

// Result of resolving one world (x,z) through the terrain grid.
World_Attr :: struct {
  attr:   int, // HATTR_*
  height: f32, // decoded true terrain height at the cell
  raw:    f32, // raw heightmap float (with any HGT_ offset)
  tile:   int, // landscape tile index (mX + mZ*land_width)
  cell:   int, // cell index within the tile (lx + lz*129)
  pland:  uintptr, // CLandscape* for the tile
  hmap:   uintptr, // m_pHeightMap for the tile
}

// terrain_ready reports whether the four terrain offsets are all pinned.
terrain_ready :: proc(session: ^Session) -> bool {
  L := session.layout
  return L.land_off != 0 && L.landwidth_off != 0 && L.hmap_off != 0
}

// Read the per-map MPU (meters-per-unit), falling back to the default when mpu_off is unset.
world_mpu :: proc(session: ^Session, world: uintptr) -> i32 {
  L := session.layout
  if L.mpu_off != 0 {
    m := read_i32_at(session.proc_info.handle, world + uintptr(L.mpu_off))
    if m == 2 || m == 4 || m == 8 {
      return m
    }
  }
  return MPU_DEFAULT
}

// Resolve a world (x,z) to its terrain attribute + height, following the exact CWorld ->
// m_apLand -> CLandscape -> m_pHeightMap chain. ok=false = out of world / unloaded tile / offsets
// not pinned / read failure (i.e. "can't judge this cell").
world_attr_at :: proc(session: ^Session, world: uintptr, wx, wz: f32) -> (wa: World_Attr, ok: bool) {
  handle := session.proc_info.handle
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  L := session.layout
  if world == 0 || L.land_off == 0 || L.landwidth_off == 0 || L.hmap_off == 0 {
    return {}, false
  }
  land_width := read_i32_at(handle, world + uintptr(L.landwidth_off))
  land_height := read_i32_at(handle, world + uintptr(L.landwidth_off + 4))
  if land_width <= 0 || land_height <= 0 || land_width > 256 || land_height > 256 {
    return {}, false
  }
  mpu := world_mpu(session, world)

  ux := wx / f32(mpu)
  uz := wz / f32(mpu)
  world_w := int(land_width) * MAP_SIZE
  world_h := int(land_height) * MAP_SIZE
  if ux < 0 || uz < 0 || ux >= f32(world_w) || uz >= f32(world_h) {
    return {}, false // outside the world (VecInWorld == FALSE)
  }
  r_x := int(ux)
  r_z := int(uz)
  m_x := r_x / MAP_SIZE
  m_z := r_z / MAP_SIZE
  tile := m_x + m_z * int(land_width)
  if tile < 0 || tile >= int(land_width) * int(land_height) {
    return {}, false
  }
  arr := read_ptr_at(handle, world + uintptr(L.land_off), pt) // m_apLand (CLandscape**)
  if !is_heap_ptr(session, arr) {
    return {}, false
  }
  pland := read_ptr_at(handle, arr + uintptr(tile * ps), pt)
  if !is_heap_ptr(session, pland) {
    return {}, false // unloaded / bad tile
  }
  hmap := read_ptr_at(handle, pland + uintptr(L.hmap_off), pt) // m_pHeightMap (float*)
  if !is_heap_ptr(session, hmap) {
    return {}, false
  }
  local_x := int(ux - f32(m_x * MAP_SIZE))
  local_z := int(uz - f32(m_z * MAP_SIZE))
  cell := local_x + local_z * HMAP_STRIDE
  raw, rok := read_f32_at(handle, hmap + uintptr(cell * 4))
  if !rok {
    return {}, false
  }
  attr, height := decode_hgt(raw)
  return World_Attr{attr, height, raw, tile, cell, pland, hmap}, true
}

// Raycast the straight segment (ax,az)->(bx,bz) at sub-cell resolution. Reports the first
// walk-blocking cell, matching the client's straight-line pursuit. Cells that can't be judged
// (out of world / unresolved) are skipped rather than treated as blocked.
reach_raycast :: proc(session: ^Session, world: uintptr, ax, az, bx, bz: f32) -> (blocked: bool, hit: World_Attr) {
  dx := bx - ax
  dz := bz - az
  dist := math.sqrt(dx * dx + dz * dz)
  step := f32(MPU_DEFAULT) * 0.5 // < one cell so we never step over a blocked cell
  n := int(dist / step) + 1
  for i in 0 ..= n {
    t := n == 0 ? f32(0) : f32(i) / f32(n)
    sx := ax + dx * t
    sz := az + dz * t
    wa, wok := world_attr_at(session, world, sx, sz)
    if !wok {
      continue
    }
    if hattr_blocks_walk(wa.attr) {
      return true, wa
    }
  }
  return false, {}
}

// ---------------------------------------------------------------------------
// worldscan - self-calibrate the four terrain offsets from the player's ground height
// ---------------------------------------------------------------------------

// One consistent terrain-offset hypothesis. Equality is by the structural offsets + mpu;
// land_width/land_height are implied by landwidth_off.
World_Cal_Cand :: struct {
  landwidth_off: i64,
  land_off:      i64,
  hmap_off:      i64,
  land_width:    i32,
  land_height:   i32,
  mpu:           i32,
}

cal_cand_same :: proc(a, b: World_Cal_Cand) -> bool {
  return a.landwidth_off == b.landwidth_off && a.land_off == b.land_off && a.hmap_off == b.hmap_off && a.mpu == b.mpu
}

// worldscan       -> sample the player's current spot; intersect with prior samples.
// worldscan reset -> forget accumulated candidates and start over.
// Stand on solid, flat ground and run it; if several hypotheses survive, walk to a spot with a
// clearly DIFFERENT ground height and run again. When one survives it's pinned + saved.
cli_worldscan :: proc(session: ^Session, args: []string) {
  if len(args) >= 1 && args[0] == "reset" {
    clear(&session.world_cal)
    fmt.println("worldscan: candidate set cleared.")
    return
  }
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  L := session.layout

  world := read_ptr_at(handle, base + L.world_rva, pt)
  player := read_ptr_at(handle, base + L.player_rva, pt)
  if world == 0 || player == 0 {
    fmt.eprintln("world/player not resolved - run 'calibrate' first.")
    return
  }
  ppos, pok := engine.read_vec3(handle, player + uintptr(L.pos_off))
  if !pok {
    fmt.eprintln("couldn't read player position.")
    return
  }
  px, py, pz := ppos[0], ppos[1], ppos[2]

  // Step 1: candidate landwidth_off - four consecutive ints (m_nLandWidth, m_nLandHeight,
  // WORLD_WIDTH, WORLD_HEIGHT) where WORLD_WIDTH == 128*width and WORLD_HEIGHT == 128*height.
  // This signature is very restrictive, so it usually pins the offset in one shot.
  Lw :: struct {
    off: i64,
    w:   i32,
    h:   i32,
  }
  lws := make([dynamic]Lw, context.temp_allocator)
  for o := i64(0); o <= 0x800; o += 4 {
    a := read_i32_at(handle, world + uintptr(o))
    b := read_i32_at(handle, world + uintptr(o + 4))
    c := read_i32_at(handle, world + uintptr(o + 8))
    d := read_i32_at(handle, world + uintptr(o + 12))
    if a >= 1 && a <= 64 && b >= 1 && b <= 64 && c == a * MAP_SIZE && d == b * MAP_SIZE {
      append(&lws, Lw{o, a, b})
    }
  }
  if len(lws) == 0 {
    fmt.eprintln(
      "worldscan: no (m_nLandWidth, WORLD_WIDTH) signature in CWorld. Are you fully in-game (not at a loading screen)?",
    )
    return
  }

  // Collect CWorld's heap-pointer fields once (m_apLand candidates).
  cw_ptrs := collect_heap_ptrs(session, world, 0x800)

  // Step 2+3: for each (landwidth, mpu), resolve the player's tile+cell and search
  // (m_apLand field) x (m_pHeightMap field) for the combo whose decoded height == the player's
  // Y and reads as walkable (the player stands on walkable ground).
  TOL :: f32(4.0) // player Y vs terrain corner height tolerance (interpolation / slope)
  fresh := make([dynamic]World_Cal_Cand, context.temp_allocator)
  mpus := [?]i32{MPU_DEFAULT, 8, 2}
  for lw in lws {
    world_w := int(lw.w) * MAP_SIZE
    world_h := int(lw.h) * MAP_SIZE
    for mpu in mpus {
      ux := px / f32(mpu)
      uz := pz / f32(mpu)
      if ux < 0 || uz < 0 || ux >= f32(world_w) || uz >= f32(world_h) {
        continue
      }
      m_x := int(ux) / MAP_SIZE
      m_z := int(uz) / MAP_SIZE
      tile := m_x + m_z * int(lw.w)
      if tile < 0 || tile >= int(lw.w) * int(lw.h) {
        continue
      }
      local_x := int(ux - f32(m_x * MAP_SIZE))
      local_z := int(uz - f32(m_z * MAP_SIZE))
      cell := local_x + local_z * HMAP_STRIDE
      for op in cw_ptrs {
        pland := read_ptr_at(handle, op.ptr + uintptr(tile * ps), pt)
        if !is_heap_ptr(session, pland) {
          continue
        }
        for ho := i64(0); ho < 0x40; ho += i64(ps) {
          hmap := read_ptr_at(handle, pland + uintptr(ho), pt)
          if !is_heap_ptr(session, hmap) {
            continue
          }
          raw, rok := read_f32_at(handle, hmap + uintptr(cell * 4))
          if !rok {
            continue
          }
          attr, height := decode_hgt(raw)
          if attr == HATTR_NONE && math.abs(height - py) <= TOL {
            append(&fresh, World_Cal_Cand{lw.off, op.off, ho, lw.w, lw.h, mpu})
          }
        }
      }
    }
  }

  if len(fresh) == 0 {
    fmt.eprintln(
      "worldscan: no offset combo reproduced your ground height. Stand still on SOLID flat ground (not mid-jump / on a bridge) and retry; 'worldscan reset' to start over.",
    )
    return
  }

  // Intersect with the accumulated set (or seed it on the first run).
  if len(session.world_cal) == 0 {
    for c in fresh {
      append(&session.world_cal, c)
    }
  } else {
    kept := make([dynamic]World_Cal_Cand, context.temp_allocator)
    for c in session.world_cal {
      for f in fresh {
        if cal_cand_same(c, f) {
          append(&kept, c)
          break
        }
      }
    }
    clear(&session.world_cal)
    for c in kept {
      append(&session.world_cal, c)
    }
  }

  n := len(session.world_cal)
  fmt.printfln(
    "worldscan @ (%.1f, %.1f, %.1f): %d fresh match(es), %d surviving hypothesis(es).",
    px,
    py,
    pz,
    len(fresh),
    n,
  )
  if n == 0 {
    fmt.println("  all prior hypotheses were killed - the ground truth conflicts. 'worldscan reset' and retry.")
    return
  }
  if n == 1 {
    c := session.world_cal[0]
    session.layout.land_off = c.land_off
    session.layout.landwidth_off = c.landwidth_off
    session.layout.hmap_off = c.hmap_off
    // mpu_off is best-effort: only record it if the pinned mpu isn't the default (else leave 0 =
    // "assume default", which is what most maps want and avoids a wrong per-map offset).
    fmt.println("  PINNED terrain offsets:")
    fmt.printfln("    land_off      = 0x%X", c.land_off)
    fmt.printfln("    landwidth_off = 0x%X   (land %dx%d tiles, mpu %d)", c.landwidth_off, c.land_width, c.land_height, c.mpu)
    fmt.printfln("    hmap_off      = 0x%X", c.hmap_off)
    if flyff_save_cfg(session.layout, flyff_cfg_path()) {
      fmt.println("  saved -> flyff.cfg. Validate with 'attr' at your feet, then 'attr <x,z>' on a known wall.")
    }
    clear(&session.world_cal)
    return
  }
  fmt.println("  still ambiguous. Walk to a spot with a CLEARLY different ground height and run 'worldscan' again:")
  shown := 0
  for c in session.world_cal {
    if shown >= 8 {
      fmt.printfln("    ... (%d more)", n - shown)
      break
    }
    fmt.printfln("    land_off=0x%X landwidth_off=0x%X hmap_off=0x%X (mpu %d)", c.land_off, c.landwidth_off, c.hmap_off, c.mpu)
    shown += 1
  }
}

// ---------------------------------------------------------------------------
// attr / reach - debug readouts to validate the oracle against real terrain
// ---------------------------------------------------------------------------

// attr           -> terrain attribute at the player's feet (should be NONE; height ~= player Y)
// attr <x,z>     -> attribute at a world point (x,y,z also accepted; Y ignored)
cli_attr :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if !terrain_ready(session) {
    fmt.eprintln("terrain not calibrated - run 'worldscan' first (stand on solid ground).")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  L := session.layout
  world := read_ptr_at(handle, base + L.world_rva, pt)
  if world == 0 {
    fmt.eprintln("world not resolved - run 'calibrate'.")
    return
  }

  wx, wz: f32
  at_player := len(args) < 1
  py: f32 = 0
  if at_player {
    player := read_ptr_at(handle, base + L.player_rva, pt)
    ppos, pok := engine.read_vec3(handle, player + uintptr(L.pos_off))
    if !pok {
      fmt.eprintln("couldn't read player position.")
      return
    }
    wx, py, wz = ppos[0], ppos[1], ppos[2]
  } else {
    x, z, ok := parse_xz(args[0])
    if !ok {
      fmt.eprintln("usage: attr [x,z]   (comma-separated, no spaces; x,y,z also ok)")
      return
    }
    wx, wz = x, z
  }

  wa, wok := world_attr_at(session, world, wx, wz)
  if !wok {
    fmt.printfln("(%.1f, %.1f): outside the world / unloaded tile / read failed.", wx, wz)
    return
  }
  fmt.printfln("(%.1f, %.1f): attr=%d %s", wx, wz, wa.attr, hattr_name(wa.attr))
  fmt.printfln("  height=%.2f  raw=%.2f  tile=%d cell=%d  pLand=0x%X hmap=0x%X", wa.height, wa.raw, wa.tile, wa.cell, wa.pland, wa.hmap)
  if at_player {
    fmt.printfln("  player Y=%.2f  (delta %.2f - should be small on flat ground)", py, wa.height - py)
  }
}

// reach          -> raycast player -> current selected target (test "mob across a wall")
// reach <x,z>    -> raycast player -> a world point
cli_reach :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if !terrain_ready(session) {
    fmt.eprintln("terrain not calibrated - run 'worldscan' first.")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  L := session.layout
  world := read_ptr_at(handle, base + L.world_rva, pt)
  player := read_ptr_at(handle, base + L.player_rva, pt)
  if world == 0 || player == 0 {
    fmt.eprintln("world/player not resolved - run 'calibrate'.")
    return
  }
  ppos, pok := engine.read_vec3(handle, player + uintptr(L.pos_off))
  if !pok {
    fmt.eprintln("couldn't read player position.")
    return
  }

  tx, tz: f32
  label := ""
  if len(args) >= 1 {
    x, z, ok := parse_xz(args[0])
    if !ok {
      fmt.eprintln("usage: reach [x,z]   (no arg = to the selected target)")
      return
    }
    tx, tz = x, z
    label = fmt.tprintf("point (%.1f, %.1f)", tx, tz)
  } else {
    focus := read_ptr_at(handle, world + uintptr(L.focus_off), pt)
    if focus == 0 || !in_module_range(read_ptr_at(handle, focus, pt), base, mod_end) {
      fmt.eprintln("no live target selected. Click a mob (keep it selected), or pass 'reach <x,z>'.")
      return
    }
    tpos, tok := engine.read_vec3(handle, focus + uintptr(L.pos_off))
    if !tok {
      fmt.eprintln("couldn't read target position.")
      return
    }
    tx, tz = tpos[0], tpos[2]
    nm, _ := engine.read_obj_name(handle, ps, focus, L.name_off)
    label = fmt.tprintf("target '%s' (%.1f, %.1f)", nm, tx, tz)
  }

  res := compute_reach(session, world, ppos[0], ppos[1], ppos[2], tx, tz)
  switch res.status {
  case .Blocked_Terrain:
    fmt.printfln("BLOCKED (terrain) -> %s (d=%.1f): first %s at tile %d cell %d.", label, res.d, hattr_name(res.thit.attr), res.thit.tile, res.thit.cell)
  case .Blocked_Object:
    fmt.printfln(
      "BLOCKED (object) -> %s (d=%.1f): OBB center (%.1f,%.1f,%.1f) half-extent (%.1f,%.1f,%.1f).",
      label, res.d, res.ohit.center[0], res.ohit.center[1], res.ohit.center[2], res.ohit.ext[0], res.ohit.ext[1], res.ohit.ext[2],
    )
  case .Clear:
    note := res.oscan ? "" : "  (object scan skipped: world unresolved)"
    fmt.printfln("CLEAR -> %s (d=%.1f): straight line to it is walkable (terrain + objects).%s", label, res.d, note)
  }
}

// attackable (canhit) - is the CURRENTLY SELECTED mob reachable to attack? Select a mob in-game, stand
// where you want, then run this: it reports ATTACKABLE if the straight approach to within attack_range
// is clear (terrain grid + placed-object OBBs), else why it's blocked. This is the exact gate that
// reach-filtered target selection will use, so it's the way to eyeball-verify the oracle: select a mob
// across a wall or behind a tree and it should say NOT attackable.
cli_attackable :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if !terrain_ready(session) {
    fmt.eprintln("terrain not calibrated - run 'worldscan' first.")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  L := session.layout
  world := read_ptr_at(handle, base + L.world_rva, pt)
  player := read_ptr_at(handle, base + L.player_rva, pt)
  if world == 0 || player == 0 {
    fmt.eprintln("world/player not resolved - run 'calibrate'.")
    return
  }
  focus := read_ptr_at(handle, world + uintptr(L.focus_off), pt)
  if focus == 0 || !in_module_range(read_ptr_at(handle, focus, pt), base, mod_end) {
    fmt.eprintln("no live mob selected. Click a monster in-game (keep it selected), then run 'attackable'.")
    return
  }
  ppos, pok := engine.read_vec3(handle, player + uintptr(L.pos_off))
  tpos, tok := engine.read_vec3(handle, focus + uintptr(L.pos_off))
  if !pok || !tok {
    fmt.eprintln("couldn't read player/target position.")
    return
  }
  nm, _ := engine.read_obj_name(handle, ps, focus, L.name_off)

  res := compute_reach(session, world, ppos[0], ppos[1], ppos[2], tpos[0], tpos[2])
  switch res.status {
  case .Clear:
    rng_note := res.in_range ? fmt.tprintf("in range (%d) - shoot now", L.attack_range) : "out of range - walk up first"
    fmt.printfln("ATTACKABLE: '%s' (d=%.1f) - straight line clear (terrain + objects); %s.", nm, res.d, rng_note)
  case .Blocked_Terrain:
    fmt.printfln("NOT attackable: '%s' (d=%.1f) - blocked by terrain (%s) at tile %d cell %d.", nm, res.d, hattr_name(res.thit.attr), res.thit.tile, res.thit.cell)
  case .Blocked_Object:
    fmt.printfln(
      "NOT attackable: '%s' (d=%.1f) - blocked by an object: OBB center (%.1f,%.1f,%.1f) half-extent (%.1f,%.1f,%.1f).",
      nm, res.d, res.ohit.center[0], res.ohit.center[1], res.ohit.center[2], res.ohit.ext[0], res.ohit.ext[1], res.ohit.ext[2],
    )
  }
}

// attrmap [radius] [step] - ASCII map of terrain attributes around the player, one char per cell.
// Reveals invisible walls (NOWALK/NOMOVE bands) that the point-probe 'attr' can't show at a glance.
//   '.' walkable(NONE)  'w' NOWALK  'f' NOFLY  '#' NOMOVE(wall)  'X' DIE  ' ' off-world  '@' you
// radius is in world units (default 40); step defaults to the map's mpu (one char == one grid cell).
cli_attrmap :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if !terrain_ready(session) {
    fmt.eprintln("terrain not calibrated - run 'worldscan' first.")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  L := session.layout
  world := read_ptr_at(handle, base + L.world_rva, pt)
  player := read_ptr_at(handle, base + L.player_rva, pt)
  if world == 0 || player == 0 {
    fmt.eprintln("world/player not resolved - run 'calibrate'.")
    return
  }
  ppos, pok := engine.read_vec3(handle, player + uintptr(L.pos_off))
  if !pok {
    fmt.eprintln("couldn't read player position.")
    return
  }

  radius := f32(40)
  if len(args) >= 1 {
    if r, ok := strconv.parse_f64(args[0]); ok && r > 0 {
      radius = f32(r)
    }
  }
  mpu := world_mpu(session, world)
  step := f32(mpu)
  if len(args) >= 2 {
    if s, ok := strconv.parse_f64(args[1]); ok && s > 0 {
      step = f32(s)
    }
  }
  half := int(radius / step)
  half = clamp(half, 1, 60) // keep the grid console-friendly

  counts: [5]int // indexed by HATTR_*
  unresolved := 0

  fmt.printfln(
    "attrmap centered on player (%.1f, %.1f, %.1f); %d cells/side, step %.1f (mpu %d).",
    ppos[0], ppos[1], ppos[2], half, step, mpu,
  )
  fmt.println("  legend: '.' walkable  'w' NOWALK  'f' NOFLY  '#' NOMOVE(wall)  'X' DIE  ' ' off-world  '@' you")
  fmt.println("  rows: +Z (north) at top -> -Z at bottom;  cols: -X (west) left -> +X (east) right")

  b := strings.builder_make(context.temp_allocator)
  for zi := half; zi >= -half; zi -= 1 { // top row = +Z
    strings.builder_reset(&b)
    wz := ppos[2] + f32(zi) * step
    for xi := -half; xi <= half; xi += 1 {
      wx := ppos[0] + f32(xi) * step
      ch: u8 = '.'
      if xi == 0 && zi == 0 {
        ch = '@'
      } else if wa, wok := world_attr_at(session, world, wx, wz); wok {
        counts[wa.attr] += 1
        switch wa.attr {
        case HATTR_NOWALK:
          ch = 'w'
        case HATTR_NOFLY:
          ch = 'f'
        case HATTR_NOMOVE:
          ch = '#'
        case HATTR_DIE:
          ch = 'X'
        case:
          ch = '.'
        }
      } else {
        ch = ' '
        unresolved += 1
      }
      strings.write_byte(&b, ch)
    }
    fmt.println(strings.to_string(b))
  }
  fmt.printfln(
    "  cells: NONE=%d NOWALK=%d NOFLY=%d NOMOVE=%d DIE=%d off-world=%d",
    counts[HATTR_NONE], counts[HATTR_NOWALK], counts[HATTR_NOFLY], counts[HATTR_NOMOVE], counts[HATTR_DIE], unresolved,
  )
  if counts[HATTR_NOWALK] == 0 && counts[HATTR_NOMOVE] == 0 && counts[HATTR_DIE] == 0 {
    fmt.println("  -> NO blocked terrain cells in view. So either open ground, OR the obstacle is an")
    fmt.println("     OBJECT (not in the attribute grid), OR worldscan mis-pinned the offsets.")
  }
}

// ---------------------------------------------------------------------------
// objects - enumerate nearby CObj (any type) + locate CObj::m_OBB, for the object-collision layer
// ---------------------------------------------------------------------------

// Classic Flyff CObj m_dwType enum (OT_MOVER=5 is confirmed = our mover_type).
ot_name :: proc(t: u32) -> string {
  switch t {
  case 0:
    return "OBJ"
  case 1:
    return "SFX"
  case 2:
    return "ITEM"
  case 3:
    return "CTRL"
  case 4:
    return "PATH"
  case 5:
    return "MOVER"
  case 6:
    return "REGION"
  }
  return "?"
}

Obj_Rec :: struct {
  obj:       uintptr,
  ty:        u32,
  idx:       u32,
  dist:      f32,
  pos:       [3]f32,
  center:    [3]f32,
  ext:       [3]f32,
  has_model: bool,
  obb_off:   i64,
  obb_ok:    bool,
}

// Locate CObj::m_OBB in one object by finding the vec3 (Center) in [pos_off-0x50, pos_off) whose xz
// matches the object's position AND whose following Axis[0] (at +0x18) is unit-length. The unit-axis
// test rejects m_matWorld's translation row (._41.._43), which also matches xz but isn't an OBB.
// BBOX layout (xUtil3D.h): Center(+0x0) Extent[3](+0xC) Axis[3](+0x18); sizeof 0x3C.
find_obb :: proc(session: ^Session, obj: uintptr, pos: [3]f32) -> (off: i64, center, ext: [3]f32, ok: bool) {
  handle := session.proc_info.handle
  pos_off := session.layout.pos_off
  WIN :: 0x50
  buf: [WIN]byte
  n, rok := engine.read_into(handle, obj + uintptr(pos_off - WIN), buf[:])
  if !rok {
    return
  }
  rf :: proc(b: []byte, k: int) -> f32 {return transmute(f32)rd_u32le(b, k)}
  best_err := f32(1e9)
  best_k := -1
  k := 0
  for k + 0x24 <= int(n) {
    cx, cy, cz := rf(buf[:], k), rf(buf[:], k + 4), rf(buf[:], k + 8)
    ax, ay, az := rf(buf[:], k + 0x18), rf(buf[:], k + 0x1C), rf(buf[:], k + 0x20)
    alen := math.sqrt(ax * ax + ay * ay + az * az)
    xz := math.abs(cx - pos[0]) + math.abs(cz - pos[2])
    _ = cy
    if xz < 2.0 && math.abs(alen - 1.0) < 0.1 && xz < best_err {
      best_err = xz
      best_k = k
    }
    k += 4
  }
  if best_k < 0 {
    return
  }
  off = pos_off - WIN + i64(best_k)
  center = {rf(buf[:], best_k), rf(buf[:], best_k + 4), rf(buf[:], best_k + 8)}
  ext = {rf(buf[:], best_k + 0xC), rf(buf[:], best_k + 0x10), rf(buf[:], best_k + 0x14)}
  ok = true
  return
}

// objects [radius] - enumerate nearby CObj of ANY type (not just movers) via the world-ptr scan, and
// auto-locate CObj::m_OBB per object. Static props (trees/rocks = OT_OBJ) that the terrain grid misses
// show up here; this is the recon that grounds the object-collision reach layer.
cli_objects :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if session.ptr_size != 4 {
    fmt.eprintln("objects: 32-bit Flyff client only.")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  ps := session.ptr_size
  pt := engine.Value_Type.U32
  L := session.layout

  radius := f32(30)
  if len(args) >= 1 {
    if r, ok := strconv.parse_f64(args[0]); ok && r > 0 {
      radius = f32(r)
    }
  }

  ppos, pok := read_player_pos(session)
  if !pok {
    fmt.eprintln("objects: couldn't read player position.")
    return
  }
  wv, wok := engine.read_value(handle, base + L.world_rva, pt)
  if !wok {
    fmt.eprintln("objects: world not resolved - run 'calibrate'.")
    return
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  wval := engine.ptr_to_value(world, ps)
  all := engine.collect_regions(handle, true)
  defer delete(all)
  set := engine.scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)

  recs := make([dynamic]Obj_Rec, context.temp_allocator)
  seen := make([dynamic]uintptr, context.temp_allocator)
  outer: for m in set.matches {
    obj := uintptr(i64(m.addr) - L.field_off)
    for s in seen {
      if s == obj {
        continue outer
      }
    }
    vt, vtok := engine.read_value(handle, obj, pt)
    if !vtok {
      continue
    }
    vtable := uintptr(engine.value_as_u64(pt, vt))
    if vtable < base || vtable >= mod_end {
      continue // no module vtable -> not a CObj
    }
    pos, posok := engine.read_vec3(handle, obj + uintptr(L.pos_off))
    if !posok {
      continue
    }
    dist := engine.dist_horizontal({ppos[0], 0, ppos[2]}, {pos[0], 0, pos[2]})
    if dist > radius {
      continue
    }
    append(&seen, obj)
    ty := u32(read_i32_at(handle, obj + uintptr(L.pos_off + 0x10)))
    idx := u32(read_i32_at(handle, obj + uintptr(L.pos_off + 0x14)))
    model := read_ptr_at(handle, obj + uintptr(L.model_off), pt)
    off, center, ext, obb_ok := find_obb(session, obj, pos)
    append(&recs, Obj_Rec{obj, ty, idx, dist, pos, center, ext, is_heap_ptr(session, model), off, obb_ok})
  }

  // sort by distance (selection sort; the near-set is small)
  for i in 0 ..< len(recs) {
    mn := i
    for j in i + 1 ..< len(recs) {
      if recs[j].dist < recs[mn].dist {
        mn = j
      }
    }
    recs[i], recs[mn] = recs[mn], recs[i]
  }

  fmt.printfln("objects within %.0f of player (%.1f, %.1f, %.1f): %d found.", radius, ppos[0], ppos[1], ppos[2], len(recs))
  fmt.println("  addr        type       idx   dist  model  m_OBB   center (x,y,z)            half-extent (x,y,z)")
  obb_votes := make(map[i64]int, 8, context.temp_allocator)
  for r in recs {
    obb := "  -  "
    if r.obb_ok {
      obb = fmt.tprintf("0x%X", r.obb_off)
      obb_votes[r.obb_off] += 1
    }
    fmt.printfln(
      "  0x%08X  %-6s(%d)  %-4d  %5.1f  %-4v  %-6s (%8.1f,%8.1f,%8.1f)  (%6.1f,%6.1f,%6.1f)",
      r.obj, ot_name(r.ty), r.ty, r.idx, r.dist, r.has_model, obb, r.center[0], r.center[1], r.center[2], r.ext[0], r.ext[1], r.ext[2],
    )
  }
  // Report the consensus m_OBB offset.
  best_off: i64 = 0
  best_votes := 0
  for off, v in obb_votes {
    if v > best_votes {
      best_votes = v
      best_off = off
    }
  }
  if best_votes > 0 {
    fmt.printfln("  => CObj::m_OBB offset = 0x%X  (%d/%d objects agree; expected 0x124).", best_off, best_votes, len(recs))
  } else {
    fmt.println("  => no OBB located (no object had a Center matching its position with a unit axis).")
  }
}

// ---------------------------------------------------------------------------
// object-collision reach: segment vs each nearby OBB (placed props the grid misses)
// ---------------------------------------------------------------------------

Obb :: struct {
  center: [3]f32,
  ext:    [3]f32, // HALF-extents
  axis:   [3][3]f32, // orthonormal box axes
}

// Read CObj::m_OBB (BBOX at pos_off-0x3C): Center(+0x0), Extent[3](+0xC), Axis[3][3](+0x18). sizeof 0x3C.
read_obb :: proc(session: ^Session, obj: uintptr) -> (o: Obb, ok: bool) {
  handle := session.proc_info.handle
  off := session.layout.pos_off - 0x3C
  buf: [0x3C]byte
  n, rok := engine.read_into(handle, obj + uintptr(off), buf[:])
  if !rok || n < 0x3C {
    return
  }
  rf :: proc(b: []byte, k: int) -> f32 {return transmute(f32)rd_u32le(b, k)}
  o.center = {rf(buf[:], 0), rf(buf[:], 4), rf(buf[:], 8)}
  o.ext = {rf(buf[:], 0xC), rf(buf[:], 0x10), rf(buf[:], 0x14)}
  o.axis[0] = {rf(buf[:], 0x18), rf(buf[:], 0x1C), rf(buf[:], 0x20)}
  o.axis[1] = {rf(buf[:], 0x24), rf(buf[:], 0x28), rf(buf[:], 0x2C)}
  o.axis[2] = {rf(buf[:], 0x30), rf(buf[:], 0x34), rf(buf[:], 0x38)}
  ok = true
  return
}

dot3 :: proc(a, b: [3]f32) -> f32 {return a[0] * b[0] + a[1] * b[1] + a[2] * b[2]}

// Is point p inside the OBB? Used to skip boxes we already stand within (e.g. under a tree's canopy -
// the OBB bounds the whole silhouette but the real collision is the small trunk mesh, so being inside
// the box is NOT being blocked). Keeps the loose OBB from flagging every direction as obstructed.
point_in_obb :: proc(p: [3]f32, o: Obb) -> bool {
  for i in 0 ..< 3 {
    if math.abs(dot3(p - o.center, o.axis[i])) > o.ext[i] {
      return false
    }
  }
  return true
}

// Segment (p0->p1) vs OBB via slab clip in the box's local frame. Mirrors IntrSegment3Box3_Test.
seg_vs_obb :: proc(p0, p1: [3]f32, o: Obb) -> bool {
  s0, d: [3]f32
  for i in 0 ..< 3 {
    s0[i] = dot3(p0 - o.center, o.axis[i])
    d[i] = dot3(p1 - o.center, o.axis[i]) - s0[i]
  }
  tmin := f32(0)
  tmax := f32(1)
  for i in 0 ..< 3 {
    if math.abs(d[i]) < 1e-6 {
      if s0[i] < -o.ext[i] || s0[i] > o.ext[i] {
        return false // segment parallel to this slab and outside it
      }
    } else {
      t1 := (-o.ext[i] - s0[i]) / d[i]
      t2 := (o.ext[i] - s0[i]) / d[i]
      if t1 > t2 {
        t1, t2 = t2, t1
      }
      if t1 > tmin {tmin = t1}
      if t2 < tmax {tmax = t2}
      if tmin > tmax {
        return false
      }
    }
  }
  return true
}

// Horizontal distance from point (px,pz) to segment (ax,az)-(bx,bz). Prune for the object scan.
seg_dist_2d :: proc(px, pz, ax, az, bx, bz: f32) -> f32 {
  dx := bx - ax
  dz := bz - az
  l2 := dx * dx + dz * dz
  t := f32(0)
  if l2 > 1e-6 {
    t = clamp(((px - ax) * dx + (pz - az) * dz) / l2, 0, 1)
  }
  cx := ax + t * dx
  cz := az + t * dz
  return math.sqrt((px - cx) * (px - cx) + (pz - cz) * (pz - cz))
}

// Test one CObj at `obj` against the knee-height segment. One windowed read covers vtable + m_OBB +
// m_vPos + m_dwType. is_cobj=false means `obj` has no in-module vtable (not a live CObj) - the cull
// walk uses that to stop at the end of the live prefix. Filters to OT_OBJ / OT_CTRL and prunes by
// distance to the line before the slab test.
obj_obb_blocks :: proc(session: ^Session, obj: uintptr, ax, az, bx, bz, knee: f32) -> (hit: bool, obb: Obb, is_cobj: bool) {
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  po := int(session.layout.pos_off)
  wlen := po + 0x1C
  if wlen > 512 {
    return // implausible pos_off
  }
  buf: [512]byte
  n, rok := engine.read_into(handle, obj, buf[:wlen])
  if !rok || int(n) < wlen {
    return
  }
  vt := uintptr(rd_u32le(buf[:], 0))
  if vt < base || vt >= mod_end {
    return // not a live CObj
  }
  is_cobj = true
  ty := rd_u32le(buf[:], po + 0x10)
  if ty != 0 && ty != 3 {
    return // OT_OBJ (trees/rocks/buildings) or OT_CTRL (walls/railings/housing) only
  }
  rf :: proc(b: []byte, k: int) -> f32 {return transmute(f32)rd_u32le(b, k)}
  px, pz := rf(buf[:], po), rf(buf[:], po + 8)
  if seg_dist_2d(px, pz, ax, az, bx, bz) > 48 {
    return // too far from the line (loose; seg_vs_obb is the exact test)
  }
  oo := po - 0x3C
  obb.center = {rf(buf[:], oo), rf(buf[:], oo + 4), rf(buf[:], oo + 8)}
  obb.ext = {rf(buf[:], oo + 0xC), rf(buf[:], oo + 0x10), rf(buf[:], oo + 0x14)}
  obb.axis[0] = {rf(buf[:], oo + 0x18), rf(buf[:], oo + 0x1C), rf(buf[:], oo + 0x20)}
  obb.axis[1] = {rf(buf[:], oo + 0x24), rf(buf[:], oo + 0x28), rf(buf[:], oo + 0x2C)}
  obb.axis[2] = {rf(buf[:], oo + 0x30), rf(buf[:], oo + 0x34), rf(buf[:], oo + 0x38)}
  if point_in_obb({ax, knee, az}, obb) {
    return // already inside it (under a canopy / standing at it) - not an approach blocker
  }
  hit = seg_vs_obb({ax, knee, az}, {bx, knee, bz}, obb)
  return
}

// Test the knee-height segment player(ax,ay,az)->(bx,_,bz) against nearby collidable props (OT_OBJ +
// OT_CTRL, the two sets ProcessCollision uses). FAST path: walk the game's on-screen display array
// m_aobjCull (aobjcull_rva) - a handful of reads, no memory scan. Fallback (aobjcull_rva==0): the full
// world-ptr scan. ok_scan=false => world anchor didn't resolve.
obj_segment_blocked :: proc(session: ^Session, ax, ay, az, bx, bz: f32) -> (blocked: bool, hit: Obb, ok_scan: bool) {
  if session.ptr_size != 4 {
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := engine.Value_Type.U32
  L := session.layout
  knee := ay + 0.4

  // FAST: read the on-screen display list and test each entry until the live prefix ends.
  if L.aobjcull_rva != 0 {
    ok_scan = true
    CAP :: 8192
    idx := make([]byte, CAP * 4, context.temp_allocator)
    n, _ := engine.read_into(handle, base + L.aobjcull_rva, idx)
    for k in 0 ..< int(n) / 4 {
      p := uintptr(rd_u32le(idx, k * 4))
      if p < 0x10000 {
        break // null slot = past the live entries
      }
      h, o, is_cobj := obj_obb_blocks(session, p, ax, az, bx, bz, knee)
      if !is_cobj {
        break // first non-CObj slot = end of the live cull prefix
      }
      if h {
        return true, o, true
      }
    }
    return false, {}, true
  }

  // SLOW fallback: scan all writable memory for CObj (each holds m_pWorld at field_off).
  wv, wok := engine.read_value(handle, base + L.world_rva, pt)
  if !wok {
    return
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  if world == 0 {
    return
  }
  ok_scan = true
  wval := engine.ptr_to_value(world, session.ptr_size)
  all := engine.collect_regions(handle, true)
  defer delete(all)
  set := engine.scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)
  seen := make([dynamic]uintptr, context.temp_allocator)
  outer: for m in set.matches {
    obj := uintptr(i64(m.addr) - L.field_off)
    for s in seen {
      if s == obj {
        continue outer
      }
    }
    append(&seen, obj)
    h, o, _ := obj_obb_blocks(session, obj, ax, az, bx, bz, knee)
    if h {
      return true, o, true
    }
  }
  return false, {}, true
}

Reach_Status :: enum {
  Clear, // straight line player->target is walkable (terrain + objects)
  Blocked_Terrain, // an invisible wall / cliff / water cell on the line
  Blocked_Object, // a placed prop (tree/rock/building) OBB on the line
}

Reach_Res :: struct {
  status:   Reach_Status,
  d:        f32, // horizontal player->target distance
  in_range: bool, // d <= attack_range - informational ONLY, never bypasses the obstruction test
  thit:     World_Attr, // set when Blocked_Terrain
  ohit:     Obb, // set when Blocked_Object
  oscan:    bool, // did the object scan run (world resolved)
}

// The one reachability check shared by `reach` and `attackable`. Tests the FULL straight line
// player->(tx,tz) for obstruction: terrain grid first, then placed-object OBBs. Being within
// attack_range does NOT skip the test (a mob can be close yet walled off) - it's returned as a flag.
// Matches the game: it runs you straight at the mob and shoots straight at it, so the whole line to the
// mob must be clear.
compute_reach :: proc(session: ^Session, world: uintptr, px, py, pz, tx, tz: f32) -> Reach_Res {
  L := session.layout
  d := engine.dist_horizontal({px, 0, pz}, {tx, 0, tz})
  in_range := L.attack_range > 0 && d <= f32(L.attack_range)
  if tblocked, thit := reach_raycast(session, world, px, pz, tx, tz); tblocked {
    return {status = .Blocked_Terrain, d = d, in_range = in_range, thit = thit, oscan = true}
  }
  oblocked, ohit, oscan := obj_segment_blocked(session, px, py, pz, tx, tz)
  if oblocked {
    return {status = .Blocked_Object, d = d, in_range = in_range, ohit = ohit, oscan = oscan}
  }
  return {status = .Clear, d = d, in_range = in_range, oscan = oscan}
}

// reachdbg - explain the object check for the SELECTED mob: list every nearby OT_OBJ/OT_CTRL with its
// OBB, distance-to-line, and which filter (type / prune / enclosing) accepted or rejected it, plus the
// slab-test result. This is how we find why a verdict is wrong. Read-only.
cli_reachdbg :: proc(session: ^Session, args: []string) {
  if !session.attached || session.ptr_size != 4 {
    fmt.eprintln("attach a 32-bit Neuz first.")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  ps := session.ptr_size
  pt := engine.Value_Type.U32
  L := session.layout
  world := read_ptr_at(handle, base + L.world_rva, pt)
  player := read_ptr_at(handle, base + L.player_rva, pt)
  if world == 0 || player == 0 {
    fmt.eprintln("world/player not resolved.")
    return
  }
  focus := read_ptr_at(handle, world + uintptr(L.focus_off), pt)
  if focus == 0 || !in_module_range(read_ptr_at(handle, focus, pt), base, mod_end) {
    fmt.eprintln("select a mob first (reachdbg explains the check for the selected target).")
    return
  }
  ppos, _ := engine.read_vec3(handle, player + uintptr(L.pos_off))
  tpos, _ := engine.read_vec3(handle, focus + uintptr(L.pos_off))
  nm, _ := engine.read_obj_name(handle, ps, focus, L.name_off)
  ax, ay, az := ppos[0], ppos[1], ppos[2]
  bx, bz := tpos[0], tpos[2]
  knee := ay + 0.4
  d := engine.dist_horizontal({ax, 0, az}, {bx, 0, bz})
  fmt.printfln("reachdbg -> '%s'  player (%.1f,%.1f,%.1f) -> target (%.1f,%.1f,%.1f)  d=%.1f", nm, ax, ay, az, bx, tpos[1], bz, d)

  tblocked, thit := reach_raycast(session, world, ax, az, bx, bz)
  fmt.printfln("  terrain: %s", tblocked ? fmt.tprintf("BLOCKED (%s tile %d cell %d)", hattr_name(thit.attr), thit.tile, thit.cell) : "clear")

  wval := engine.ptr_to_value(world, ps)
  all := engine.collect_regions(handle, true)
  defer delete(all)
  set := engine.scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)
  fmt.println("  nearby OT_OBJ/OT_CTRL vs the line (dseg=center dist to line; in=you inside it; HIT=slab hit):")
  fmt.println("    type       center (x,y,z)            half-ext (x,y,z)       dseg  in   knee-HIT")
  seen := make([dynamic]uintptr, context.temp_allocator)
  shown := 0
  outer: for m in set.matches {
    obj := uintptr(i64(m.addr) - L.field_off)
    for s in seen {
      if s == obj {continue outer}
    }
    vt := read_ptr_at(handle, obj, pt)
    if vt < base || vt >= mod_end {continue}
    ty := u32(read_i32_at(handle, obj + uintptr(L.pos_off + 0x10)))
    if ty != 0 && ty != 3 {continue} // OT_OBJ or OT_CTRL only
    pos, posok := engine.read_vec3(handle, obj + uintptr(L.pos_off))
    if !posok {continue}
    append(&seen, obj)
    dseg := seg_dist_2d(pos[0], pos[2], ax, az, bx, bz)
    if dseg > 80 {continue} // loose: only report objects plausibly near the line
    o, ook := read_obb(session, obj)
    if !ook {continue}
    in_start := point_in_obb({ax, knee, az}, o)
    hit := seg_vs_obb({ax, knee, az}, {bx, knee, bz}, o)
    fmt.printfln(
      "    %-6s(%d)  (%8.1f,%8.1f,%8.1f)  (%5.1f,%5.1f,%5.1f)  %5.1f  %-3v  %v",
      ot_name(ty), ty, o.center[0], o.center[1], o.center[2], o.ext[0], o.ext[1], o.ext[2], dseg, in_start, hit,
    )
    shown += 1
    if shown >= 30 {
      fmt.println("    ... (capped at 30)")
      break
    }
  }
  fmt.println("  a would-be blocker = a row with HIT=true and in=false. current obj_segment_blocked also")
  fmt.println("  requires type=OBJ and dseg<=16, so anything failing those is a candidate bug.")
}

// findcull - locate the static CObj* CWorld::m_aobjCull[] on-screen display array (the fast replacement
// for the full memory scan). Enumerate all loaded CObj once, then scan the module image for the longest
// run of contiguous pointers into that set - that run is m_aobjCull. Read-only recon.
cli_findcull :: proc(session: ^Session, args: []string) {
  if !session.attached || session.ptr_size != 4 {
    fmt.eprintln("attach a 32-bit Neuz first.")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  size := int(session.proc_info.module_size)
  mod_end := base + uintptr(size)
  pt := engine.Value_Type.U32
  L := session.layout
  world := read_ptr_at(handle, base + L.world_rva, pt)
  if world == 0 {
    fmt.eprintln("world not resolved.")
    return
  }
  wval := engine.ptr_to_value(world, session.ptr_size)
  all := engine.collect_regions(handle, true)
  set := engine.scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)
  delete(all)
  objset := make(map[uintptr]bool, 8192, context.temp_allocator)
  for m in set.matches {
    obj := uintptr(i64(m.addr) - L.field_off)
    vt := read_ptr_at(handle, obj, pt)
    if vt >= base && vt < mod_end {
      objset[obj] = true
    }
  }
  fmt.printfln("findcull: %d loaded CObj; scanning %d KB module image for the display array...", len(objset), size / 1024)
  img := make([]byte, size, context.temp_allocator)
  engine.read_into(handle, base, img)
  Run :: struct {
    off: int,
    len: int,
  }
  runs := make([dynamic]Run, context.temp_allocator)
  cur_off, cur_len := -1, 0
  i := 0
  for i + 4 <= size {
    v := uintptr(rd_u32le(img, i))
    if v in objset {
      if cur_len == 0 {cur_off = i}
      cur_len += 1
    } else {
      if cur_len >= 8 {append(&runs, Run{cur_off, cur_len})}
      cur_len = 0
    }
    i += 4
  }
  if cur_len >= 8 {append(&runs, Run{cur_off, cur_len})}
  if len(runs) == 0 {
    fmt.eprintln("findcull: no CObj*-array run found. Are you in-game with objects visible?")
    return
  }
  for a in 0 ..< len(runs) {
    mx := a
    for b in a + 1 ..< len(runs) {
      if runs[b].len > runs[mx].len {mx = b}
    }
    runs[a], runs[mx] = runs[mx], runs[a]
  }
  fmt.println("  candidate CObj* arrays (longest first); the on-screen display list is m_aobjCull:")
  for r, k in runs {
    if k >= 8 {break}
    e0 := uintptr(rd_u32le(img, r.off))
    ty := u32(read_i32_at(handle, e0 + uintptr(L.pos_off + 0x10)))
    fmt.printfln("    Neuz.exe+0x%X  len=%d  first-entry type=%s(%d)", uintptr(r.off), r.len, ot_name(ty), ty)
  }
  // Auto-save when the longest run clearly dominates (m_aobjCull is far bigger than incidental arrays).
  best := runs[0]
  if best.len >= 200 && (len(runs) == 1 || best.len >= 2 * runs[1].len) {
    session.layout.aobjcull_rva = uintptr(best.off)
    fmt.printfln("  => aobjcull_rva = 0x%X (fast object reach enabled).", best.off)
    if flyff_save_cfg(session.layout, flyff_cfg_path()) {
      fmt.println("  saved to flyff.cfg.")
    }
  } else {
    fmt.println("  => ambiguous (no dominant array). Pick the display list and 'set aobjcull_rva 0x<off>'.")
  }
}

// ---------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------

Off_Ptr :: struct {
  off: i64,
  ptr: uintptr,
}

// Collect pointer-aligned fields in [obj, obj+span) that hold a plausible heap pointer.
collect_heap_ptrs :: proc(session: ^Session, obj: uintptr, span: i64) -> [dynamic]Off_Ptr {
  handle := session.proc_info.handle
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  out := make([dynamic]Off_Ptr, context.temp_allocator)
  for o := i64(0); o < span; o += i64(ps) {
    p := read_ptr_at(handle, obj + uintptr(o), pt)
    if is_heap_ptr(session, p) {
      append(&out, Off_Ptr{o, p})
    }
  }
  return out
}

// Heuristic: p looks like a live heap allocation (non-null, above the null page, not inside the
// module image, and within the address space for the target's bitness).
is_heap_ptr :: proc(session: ^Session, p: uintptr) -> bool {
  if p < 0x10000 {
    return false
  }
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  if p >= base && p < mod_end {
    return false
  }
  if session.ptr_size == 4 && p >= 0x1_0000_0000 {
    return false
  }
  return true
}

read_i32_at :: proc(handle: win.HANDLE, addr: uintptr) -> i32 {
  if v, ok := engine.read_value(handle, addr, .U32); ok {
    return i32(u32(engine.value_as_u64(.U32, v)))
  }
  return 0
}

read_f32_at :: proc(handle: win.HANDLE, addr: uintptr) -> (f32, bool) {
  if v, ok := engine.read_value(handle, addr, .U32); ok {
    return transmute(f32)u32(engine.value_as_u64(.U32, v)), true
  }
  return 0, false
}

// Accept "x,z" or "x,y,z" (Y ignored) - the /position readout format.
parse_xz :: proc(s: string) -> (x, z: f32, ok: bool) {
  parts := strings.split(s, ",", context.temp_allocator)
  if len(parts) == 2 {
    a, aok := strconv.parse_f64(strings.trim_space(parts[0]))
    b, bok := strconv.parse_f64(strings.trim_space(parts[1]))
    return f32(a), f32(b), aok && bok
  }
  if len(parts) == 3 {
    a, aok := strconv.parse_f64(strings.trim_space(parts[0]))
    b, bok := strconv.parse_f64(strings.trim_space(parts[2]))
    return f32(a), f32(b), aok && bok
  }
  return 0, 0, false
}
