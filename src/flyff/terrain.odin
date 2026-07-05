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

  d := engine.dist_horizontal({ppos[0], 0, ppos[2]}, {tx, 0, tz})
  blocked, hit := reach_raycast(session, world, ppos[0], ppos[2], tx, tz)
  if blocked {
    fmt.printfln("BLOCKED -> %s (d=%.1f): first %s at tile %d cell %d.", label, d, hattr_name(hit.attr), hit.tile, hit.cell)
  } else {
    fmt.printfln("CLEAR -> %s (d=%.1f): straight path is walkable.", label, d)
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
