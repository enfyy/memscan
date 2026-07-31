package flyff
import "../engine"

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import win "core:sys/windows"

import tracy "../../lib/odin-tracy"

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
    fmt.eprintln("world/player not resolved - run 'setup <name>' first.")
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
    fmt.eprintln("world/player not resolved - run 'setup <name>'.")
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
    fmt.eprintln("world/player not resolved - run 'setup <name>'.")
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
    rng_note := res.in_range ? fmt.tprintf("in range (%.1f) - shoot now", L.attack_range) : "out of range - walk up first"
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
    fmt.eprintln("objects: world not resolved - run 'setup <name>'.")
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

// The two collidable CObj types, by m_dwType (see ot_name). Worth naming: the distinction is load-bearing
// for anything that asks "can I WALK here" rather than "is the sightline clear" - OT_CTRL boxes (walls,
// housing, railings) are solid all the way down, while an OT_OBJ prop's box is the whole model silhouette,
// so a tree's canopy makes its OBB far wider than the trunk you actually bump into. See sweep_obj_block.
OT_OBJ :: u32(0) // static props: trees, rocks, bushes
OT_CTRL :: u32(3) // walls, housing, railings (plus ground drops / effect zones, filtered by CTRL_DROP_MAX_*)

Obb :: struct {
  center:     [3]f32,
  ext:        [3]f32, // HALF-extents
  axis:       [3][3]f32, // orthonormal box axes
  ty:         u32, // m_dwType: OT_OBJ / OT_CTRL (the only two collected). See the note above.
  idx:        u32, // m_dwIndex: which prop of that type (the "kind" half of the collignore key). Kept on the
  // box rather than re-read through obj, because a REMEMBERED box (collider_memory) can outlive the client's
  // residency for its CObj - the inspector and collider_ignore_toggle still need its identity then.
  decorative: bool, // OT_OBJ with no dedicated collision mesh (GMT_ERROR) - walk-through, not a real blocker
  obj:        uintptr, // the live CObj* this box came from (0 = unknown). Set by obj_to_obb so the radar's
  // inspect mode can trace a clicked box back to its object and re-read identity. Reach math never uses it.
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

// Is world point (wx,wz) inside the OBB's xz FOOTPRINT? The vertical axis is ignored (a mouse pick on the
// top-down radar has no world Y), so this projects onto axis[0]/axis[2] only - the same footprint
// radar_draw_obb renders. Used by the radar inspect mode to map a click to the box under the cursor.
point_in_obb_xz :: proc(wx, wz: f32, o: Obb) -> bool {
  dx := wx - o.center[0]
  dz := wz - o.center[2]
  u := dx * o.axis[0][0] + dz * o.axis[0][2] // project onto axis[0]'s xz
  v := dx * o.axis[2][0] + dz * o.axis[2][2] // project onto axis[2]'s xz
  return math.abs(u) <= o.ext[0] && math.abs(v) <= o.ext[2]
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

// Does one collider box obstruct the horizontal segment (ax,ay,az)->(bx,ay,bz)? The per-box half of the
// object oracle, factored out so every caller applies the SAME four rules: walk-through props don't
// count, far boxes are pruned, standing inside a box (a loose canopy we're already under) is not an
// approach blocker, and the rest is a slab clip. Shared by obj_segment_blocked (the reach oracle) and
// sweep_obj_block (which classifies the hit by type instead of just returning "blocked").
obb_blocks_segment :: proc(o: Obb, ax, ay, az, bx, bz: f32) -> bool {
  if o.decorative {
    return false // no dedicated collision mesh -> the game walks straight through it (bush/grass)
  }
  if seg_dist_2d(o.center[0], o.center[2], ax, az, bx, bz) > 48 {
    return false
  }
  if point_in_obb({ax, ay, az}, o) {
    return false
  }
  return seg_vs_obb({ax, ay, az}, {bx, ay, bz}, o)
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
  if collider_denied(session, ty, rd_u32le(buf[:], po + 0x14)) {
    return // ignore-listed kind - never blocks (mirrors obj_to_obb's drop for the cached path)
  }
  rf :: proc(b: []byte, k: int) -> f32 {return transmute(f32)rd_u32le(b, k)}
  px, pz := rf(buf[:], po), rf(buf[:], po + 8)
  if seg_dist_2d(px, pz, ax, az, bx, bz) > 48 {
    return // too far from the line (loose; seg_vs_obb is the exact test)
  }
  if obj_is_decorative(session, obj, ty) {
    return // no dedicated collision mesh -> the game's pursuit walks through it (bush/grass/etc.)
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
obj_segment_blocked :: proc(session: ^Session, ax, ay, az, bx, bz: f32, allow_async := false) -> (blocked: bool, hit: Obb, ok_scan: bool) {
  if session.ptr_size != 4 {
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := engine.Value_Type.U32
  L := session.layout
  knee := ay + 0.4

  // CAMERA-INDEPENDENT (preferred): test the segment against the cached tile-object colliders (all props
  // on the nearby tiles, not just the on-screen cull list). Same OBB logic obj_obb_blocks uses.
  if L.landobj_off != 0 && L.land_off != 0 && L.landwidth_off != 0 {
    world := read_ptr_at(handle, base + L.world_rva, pt)
    if world != 0 {
      obbs := collect_area_colliders(session, world, ax, az, allow_async)
      ok_scan = true
      for o in obbs {
        if obb_blocks_segment(o, ax, knee, az, bx, bz) {
          return true, o, true
        }
      }
      return false, {}, true
    }
  }

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

// --- obstacle enumeration for the tdbg overlay (draw the same walls/boxes reach uses) --------------

Wall_Cell :: struct {
  pos:  [2]f32, // world x,z
  attr: int, // HATTR_*
}

// Blocked terrain cells (NOWALK/NOMOVE/DIE) within `radius` of (cx,cz), sampled at grid (MPU) resolution -
// the invisible walls tdbg draws. Empty when terrain isn't calibrated. Temp-allocated (capped).
collect_wall_cells :: proc(session: ^Session, world: uintptr, cx, cz, radius: f32) -> [dynamic]Wall_Cell {
  out := make([dynamic]Wall_Cell, context.temp_allocator)
  if world == 0 || !terrain_ready(session) {
    return out
  }
  step := f32(world_mpu(session, world))
  if step <= 0 {
    step = f32(MPU_DEFAULT)
  }
  MAXCELLS :: 1500
  for wz := cz - radius; wz <= cz + radius; wz += step {
    for wx := cx - radius; wx <= cx + radius; wx += step {
      dx := wx - cx
      dz := wz - cz
      if dx * dx + dz * dz > radius * radius {
        continue
      }
      if wa, ok := world_attr_at(session, world, wx, wz); ok && hattr_blocks_walk(wa.attr) {
        append(&out, Wall_Cell{pos = {wx, wz}, attr = wa.attr})
        if len(out) >= MAXCELLS {
          return out
        }
      }
    }
  }
  return out
}

// OBBs of nearby collidable props (OT_OBJ + OT_CTRL) within `radius` of (cx,cz) - the boxes tdbg draws.
// Prefers the CAMERA-INDEPENDENT tile-object source (all props, incl. off-screen); falls back to the
// on-screen cull array only when the tile arrays aren't pinned. Temp-allocated.
collect_nearby_obbs :: proc(session: ^Session, cx, cz, radius: f32) -> [dynamic]Obb {
  out := make([dynamic]Obb, context.temp_allocator)
  if session.ptr_size != 4 {
    return out
  }
  L0 := session.layout
  if L0.landobj_off != 0 && L0.land_off != 0 && L0.landwidth_off != 0 {
    world := read_ptr_at(session.proc_info.handle, session.proc_info.base + L0.world_rva, engine.Value_Type.U32)
    if world != 0 {
      lim2 := (radius + 24) * (radius + 24)
      for o in collect_area_colliders(session, world, cx, cz) {
        dx := o.center[0] - cx
        dz := o.center[2] - cz
        if dx * dx + dz * dz <= lim2 {
          append(&out, o)
        }
      }
      return out
    }
  }
  if L0.aobjcull_rva == 0 {
    return out
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  L := session.layout
  po := int(L.pos_off)
  wlen := po + 0x1C
  if wlen > 512 {
    return out
  }
  CAP :: 8192
  idx := make([]byte, CAP * 4, context.temp_allocator)
  n, _ := engine.read_into(handle, base + L.aobjcull_rva, idx)
  buf: [512]byte
  rf :: proc(b: []byte, k: int) -> f32 {return transmute(f32)rd_u32le(b, k)}
  lim := radius + 24 // slack for the box's own extent
  for k in 0 ..< int(n) / 4 {
    p := uintptr(rd_u32le(idx, k * 4))
    if p < 0x10000 {
      break
    }
    rn, rok := engine.read_into(handle, p, buf[:wlen])
    if !rok || int(rn) < wlen {
      break
    }
    vt := uintptr(rd_u32le(buf[:], 0))
    if vt < base || vt >= mod_end {
      break // end of the live cull prefix
    }
    ty := rd_u32le(buf[:], po + 0x10)
    if ty != 0 && ty != 3 {
      continue // OT_OBJ / OT_CTRL only
    }
    ocx := rf(buf[:], po)
    ocz := rf(buf[:], po + 8)
    dx := ocx - cx
    dz := ocz - cz
    if dx * dx + dz * dz > lim * lim {
      continue
    }
    oo := po - 0x3C
    o: Obb
    o.center = {rf(buf[:], oo), rf(buf[:], oo + 4), rf(buf[:], oo + 8)}
    o.ext = {rf(buf[:], oo + 0xC), rf(buf[:], oo + 0x10), rf(buf[:], oo + 0x14)}
    o.axis[0] = {rf(buf[:], oo + 0x18), rf(buf[:], oo + 0x1C), rf(buf[:], oo + 0x20)}
    o.axis[1] = {rf(buf[:], oo + 0x24), rf(buf[:], oo + 0x28), rf(buf[:], oo + 0x2C)}
    o.axis[2] = {rf(buf[:], oo + 0x30), rf(buf[:], oo + 0x34), rf(buf[:], oo + 0x38)}
    o.ty = ty
    o.decorative = obj_is_decorative(session, p, ty)
    append(&out, o)
  }
  return out
}

// ---------------------------------------------------------------------------
// Camera-INDEPENDENT collider source: each CLandscape tile's flat m_apObject arrays (all objects on the
// tile, not just the render-frustum cull list). Reach walks these so off-camera obstacles count. Cached
// per player area (static props don't move) so the ~per-tile scan is amortized. See flyff.odin LANDOBJ.
// ---------------------------------------------------------------------------

COLLIDER_CACHE_MOVE :: f32(16) // refresh the cache once the player moves this far from its center
COLLIDER_RADIUS :: f32(120) // gather colliders within this of the player (must cover reach segments)

// Persistent draw-only obstacle memory (see the section after collider_scan_worker). COLLIDER_RADIUS above
// doubles as the AUTHORITATIVE radius: within it the client always has every prop resident, so a box the
// fresh scan did not report really is gone (a respawn VFX that ended, a kind that just went on the ignore
// list) and leaves the store. Past it, absence only means the client unloaded the object - we keep it.
COLLIDER_MEM_RANGE :: f32(1200) // default eviction radius - 3x the 400-unit max radar view
COLLIDER_MEM_MAX :: 40000 // hard cap on remembered boxes (~3 MB) even in keep-the-whole-map mode
COLLIDER_MEM_QUANT :: f32(8) // box identity is its centre quantised to 1/8 world unit (see obb_key)

// Ground drops + skill/effect zones are OT_CTRL objects (this server renders ground loot as CCtrl, one
// per item, with a small ~1x0.5x1 box) that pile up exactly where you farm. The game never blocks
// movement on them, but the full-scan collider set would treat them as solid - drawing phantom purple
// boxes on the radar and making reach call a mob behind them "unreachable". A real OT_CTRL blocker
// (housing / walls / guild towers) is far larger, so we drop any OT_CTRL whose box is this small. OT_OBJ
// static props are unaffected (they keep the GMT_ERROR walk-through filter). Tune if a real small OT_CTRL
// blocker is ever missed.
CTRL_DROP_MAX_XZ :: f32(1.5) // half-extent; a drop/effect box is <= this wide/deep
CTRL_DROP_MAX_Y :: f32(0.75) // half-extent; and this short (real walls/housing are taller)

// Read one live CObj into an Obb (m_OBB at pos_off-0x3C) + its position + decorative flag. ok=false if
// it's not a live CObj (no module vtable) or the read fails.
obj_to_obb :: proc(session: ^Session, obj: uintptr) -> (o: Obb, pos: [3]f32, ok: bool) {
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  po := int(session.layout.pos_off)
  wlen := po + 0x1C
  if wlen > 512 {
    return
  }
  buf: [512]byte
  n, rok := engine.read_into(handle, obj, buf[:wlen])
  if !rok || int(n) < wlen {
    return
  }
  vt := uintptr(rd_u32le(buf[:], 0))
  if vt < base || vt >= mod_end {
    return
  }
  ty := rd_u32le(buf[:], po + 0x10)
  if ty != 0 && ty != 3 {
    return // OT_OBJ (trees/rocks/buildings) or OT_CTRL (walls/housing) only - the collidable props
  }
  idx := rd_u32le(buf[:], po + 0x14)
  if collider_denied(session, ty, idx) {
    return // this kind (m_dwType + m_dwIndex) is on the radar-inspect ignore-list - drop it entirely
  }
  rf :: proc(b: []byte, k: int) -> f32 {return transmute(f32)rd_u32le(b, k)}
  pos = {rf(buf[:], po), rf(buf[:], po + 4), rf(buf[:], po + 8)}
  oo := po - 0x3C
  o.center = {rf(buf[:], oo), rf(buf[:], oo + 4), rf(buf[:], oo + 8)}
  o.ext = {rf(buf[:], oo + 0xC), rf(buf[:], oo + 0x10), rf(buf[:], oo + 0x14)}
  // Drop / effect controls: a small OT_CTRL box is ground loot or a skill zone, not a real blocker - skip
  // it so it never draws as a phantom obstacle or fails a reach check. See CTRL_DROP_MAX_* above.
  if ty == 3 && o.ext[0] <= CTRL_DROP_MAX_XZ && o.ext[2] <= CTRL_DROP_MAX_XZ && o.ext[1] <= CTRL_DROP_MAX_Y {
    return
  }
  o.axis[0] = {rf(buf[:], oo + 0x18), rf(buf[:], oo + 0x1C), rf(buf[:], oo + 0x20)}
  o.axis[1] = {rf(buf[:], oo + 0x24), rf(buf[:], oo + 0x28), rf(buf[:], oo + 0x2C)}
  o.axis[2] = {rf(buf[:], oo + 0x30), rf(buf[:], oo + 0x34), rf(buf[:], oo + 0x38)}
  o.ty = ty
  o.idx = idx
  o.decorative = obj_is_decorative(session, obj, ty)
  o.obj = obj // keep the object handle so the radar inspect mode can trace this box back to its CObj
  ok = true
  return
}

// Gather (and cache) every collidable prop within COLLIDER_RADIUS of the player. Uses a FULL writable-
// memory scan for the world pointer (each CObj holds m_pWorld at field_off), then keeps OT_OBJ/OT_CTRL
// with a live OBB. Complete by construction: it finds every prop the game collides against regardless of
// which spatial list holds it. This matters on maps like Azria, where big static ice rocks live only in
// the CLandscape LINK MAP (m_apObjLink[linkStatic], what CWorld::ProcessCollision walks) and are ABSENT
// from the flat per-tile m_apObject array the old walk read - so reach/radar saw straight through them
// (path in, get stuck; not drawn). The picker already full-scans every tick, so this is the same cost
// class. Rebuilt only when the player leaves the cached area, so segment tests hit the cache (pure math).
collect_area_colliders :: proc(session: ^Session, world: uintptr, px, pz: f32, allow_async := false) -> []Obb {
  tracy.ZoneN("Collect_Colliders") // tiny on cache hit, balloons on the ~16-unit rebuild (stutter suspect)
  if world == 0 || session.ptr_size != 4 {
    return nil
  }
  // Zoning / re-log hands us a different CWorld: the remembered set belongs to the map it was scanned on,
  // so re-bind (which resets it on a change) BEFORE anything can draw the old map's geometry over this one.
  if session.layout.collider_memory_on {
    collider_memory_bind(session, world)
  } else if session.collider_memory_bound {
    collider_memory_reset(session) // toggled off - drop the store rather than let it go stale
  }
  if session.collider_cache_valid {
    dx := px - session.collider_cache_center[0]
    dz := pz - session.collider_cache_center[2]
    if dx * dx + dz * dz <= COLLIDER_CACHE_MOVE * COLLIDER_CACHE_MOVE {
      return session.collider_cache[:] // fresh - pure math from here
    }
  }
  // Cache is stale (or cold). The radar's soft reach visualization passes allow_async: it must NEVER
  // stall the 30fps frame on the ~200ms full-scan rebuild, so kick the off-thread worker and keep
  // serving the current (slightly stale) cache until it publishes. Accurate callers (the picker's reach
  // gate, tdbg/reachdbg, the pre-window probe, the background snapshot scan) leave allow_async at its
  // default and rebuild synchronously here - correctness over latency.
  if allow_async {
    collider_refresh_async(session, world, px, pz)
    return session.collider_cache[:]
  }
  batch := make([dynamic]Obb, context.temp_allocator) // scratch: collider_publish copies out of it
  collider_collect_into(session, world, px, pz, collider_collect_radius(session), &batch)
  collider_publish(session, batch[:], world, px, pz)
  return session.collider_cache[:]
}

// How wide one scan gathers. The scan itself is radius-INDEPENDENT - it enumerates every CObj in the
// process and reads each one regardless (see collider_collect_into), and the radius only decides whether
// the box is appended - so widening this costs a few appends and nothing else. That is what lets ONE scan
// feed both the 120-unit reach window and the far-reaching draw memory.
collider_collect_radius :: proc(session: ^Session) -> f32 {
  L := session.layout
  if !L.collider_memory_on {
    return COLLIDER_RADIUS
  }
  if L.collider_memory_map {
    return math.F32_MAX // keep-the-whole-map: take everything the client currently has resident
  }
  return math.max(COLLIDER_RADIUS, L.collider_memory_range)
}

// Publish one fresh scan batch: the live COLLIDER_RADIUS window that reach / targeting run on, and (when
// enabled) the persistent draw-only memory. Shared by the synchronous rebuild above and the background
// worker below so the two can never tell different stories. Caller holds exec_mutex.
collider_publish :: proc(session: ^Session, batch: []Obb, world: uintptr, px, pz: f32) {
  r2 := COLLIDER_RADIUS * COLLIDER_RADIUS
  clear(&session.collider_cache)
  for o in batch {
    dx := o.center[0] - px
    dz := o.center[2] - pz
    if dx * dx + dz * dz > r2 {
      continue // outside the live window: the memory store may keep it, reach must never see it
    }
    append(&session.collider_cache, o)
  }
  session.collider_cache_center = {px, 0, pz}
  session.collider_cache_valid = true
  if session.layout.collider_memory_on {
    collider_memory_bind(session, world)
    collider_memory_merge(session, batch, px, pz)
  }
}

// The rebuild body shared by the synchronous path above and the background worker below: a full writable-
// memory scan for the world pointer (each CObj holds m_pWorld at field_off), keeping OT_OBJ/OT_CTRL props
// that carry a live OBB within `radius` of the player. Appends to `out` (caller clears + owns it). Reads
// only proc_info / ptr_size / layout (through obj_to_obb), so it runs identically against the live session
// or a Session snapshot. Scratch comes from context.temp_allocator - the caller reclaims it.
collider_collect_into :: proc(session: ^Session, world: uintptr, px, pz: f32, radius: f32, out: ^[dynamic]Obb) {
  L := session.layout
  handle := session.proc_info.handle
  pt := engine.Value_Type.U32
  wval := engine.ptr_to_value(world, session.ptr_size)
  regions := engine.collect_regions(handle, true)
  defer delete(regions)
  set := engine.scan_exact_parallel(handle, pt, wval, regions[:], context.temp_allocator)
  r2 := radius * radius // +Inf in keep-the-whole-map mode, which keeps every box (nothing is > +Inf)
  seen := make(map[uintptr]bool, 2048, context.temp_allocator) // an object holds m_pWorld once, but guard anyway
  for m in set.matches {
    obj := uintptr(i64(m.addr) - L.field_off)
    if obj in seen {
      continue
    }
    seen[obj] = true
    o, _, ok := obj_to_obb(session, obj) // vtable-checked + type-filtered to OT_OBJ/OT_CTRL
    if !ok {
      continue
    }
    if o.ext[0] <= 0.01 && o.ext[2] <= 0.01 {
      continue // degenerate / uninitialised OBB - nothing to test or draw
    }
    dx := o.center[0] - px
    dz := o.center[2] - pz
    if dx * dx + dz * dz > r2 {
      continue
    }
    append(out, o)
  }
}

// One-at-a-time background collider rebuild. `active` gates re-entry; `gen` discards a publish whose
// request was superseded (a newer refresh, or a process detach/switch - see on_attach / on_detach which
// bump gen). All fields are touched only under exec_mutex: the frame kicks the job inside its locked
// section, the worker flips active + publishes under the lock.
Collider_Job :: struct {
  active: bool,
  gen:    int,
}

// Heap-owned request handed to collider_scan_worker. snap carries ONLY proc_info / ptr_size / layout -
// the same snapshot discipline as Scan_Job_Req, and exactly what collider_collect_into / obj_to_obb read.
Collider_Job_Req :: struct {
  session: ^Session,
  snap:    Session,
  world:   uintptr,
  px, pz:  f32,
  radius:  f32, // collider_collect_radius at kick time (the toggles can move while the worker runs)
  gen:     int,
}

// Force the next collect_area_colliders to rebuild: mark the cache stale AND bump the job generation so an
// in-flight (pre-change) background rebuild's publish is discarded. Called after the ignore-list changes so
// a newly-ignored kind leaves the cache (and the radar) on the next scan. Caller holds exec_mutex.
collider_cache_invalidate :: proc(session: ^Session) {
  session.collider_cache_valid = false
  session.collider_job.gen += 1
}

// Add or remove an object kind (type + index) from the collider ignore-list, invalidate the cache so the
// change takes effect on the next scan, and persist to flyff.cfg. Returns added=true if it was added (false
// if removed); ok=false only when the list is full. Caller must hold exec_mutex (mutates layout + cache).
collider_ignore_toggle :: proc(session: ^Session, ty, idx: u32) -> (added: bool, ok: bool) {
  L := &session.layout
  for i in 0 ..< int(L.collider_ignore_n) {
    if L.collider_ignore[i].ty == ty && L.collider_ignore[i].idx == idx {
      L.collider_ignore[i] = L.collider_ignore[L.collider_ignore_n - 1] // swap-with-last remove
      L.collider_ignore_n -= 1
      collider_cache_invalidate(session)
      if session.attached {flyff_save_cfg(session.layout, flyff_cfg_path())}
      return false, true
    }
  }
  if int(L.collider_ignore_n) >= FLYFF_MAX_COLLIDER_IGNORE {
    return false, false // full
  }
  L.collider_ignore[L.collider_ignore_n] = {ty, idx}
  L.collider_ignore_n += 1
  collider_cache_invalidate(session)
  collider_memory_purge_kind(session, ty, idx) // remembered boxes of this kind go too, not just live ones
  if session.attached {flyff_save_cfg(session.layout, flyff_cfg_path())}
  return true, true
}

// collignore [clear | rm <ty> <idx>] - view or edit the collider ignore-list (object kinds dropped from
// reach + the radar). No args = list it. Kinds are normally added by clicking a phantom box in the radar
// inspect mode (key I); this command is the headless way to view or remove them. ty: 0=OT_OBJ, 3=OT_CTRL.
cli_collignore :: proc(session: ^Session, args: []string) {
  L := &session.layout
  if len(args) > 0 {
    switch args[0] {
    case "clear":
      n := int(L.collider_ignore_n)
      L.collider_ignore_n = 0
      collider_cache_invalidate(session)
      if session.attached {flyff_save_cfg(session.layout, flyff_cfg_path())}
      fmt.printfln("collignore: cleared %d kind(s).", n)
      return
    case "rm", "remove":
      if len(args) < 3 {
        fmt.println("usage: collignore rm <ty> <idx>   (ty: 0=OT_OBJ, 3=OT_CTRL)")
        return
      }
      tv, tok := strconv.parse_int(args[1])
      iv, iok := strconv.parse_int(args[2])
      if !tok || !iok {
        fmt.println("collignore: <ty> and <idx> must be integers.")
        return
      }
      if !collider_denied(session, u32(tv), u32(iv)) {
        fmt.printfln("collignore: %s(%d) idx=%d not in the list.", ot_name(u32(tv)), tv, iv)
        return
      }
      collider_ignore_toggle(session, u32(tv), u32(iv)) // present -> removes it
      fmt.printfln("collignore: removed %s(%d) idx=%d.", ot_name(u32(tv)), tv, iv)
      return
    }
  }
  n := int(L.collider_ignore_n)
  if n == 0 {
    fmt.println("collignore: empty. In the radar press I (inspect) and click a phantom box to ignore its kind.")
    return
  }
  fmt.printfln("collignore: %d ignored kind(s) (hidden from reach + radar):", n)
  for i in 0 ..< n {
    k := L.collider_ignore[i]
    fmt.printfln("  %s(%d) idx=%d", ot_name(k.ty), k.ty, k.idx)
  }
  fmt.println("  edit: 'collignore rm <ty> <idx>'  |  'collignore clear'")
}

// collmem [on|off | map [on|off] | clear] - the persistent draw-only obstacle memory (see the section
// after collider_scan_worker). No args toggles it, like `trail` / `hillshade`. Radar shortcut: M.
cli_collmem :: proc(session: ^Session, args: []string) {
  L := &session.layout
  was_on := L.collider_memory_on
  was_map := L.collider_memory_map
  switch {
  case len(args) == 0:
    L.collider_memory_on = !L.collider_memory_on
  case args[0] == "on":
    L.collider_memory_on = true
  case args[0] == "off":
    L.collider_memory_on = false
  case args[0] == "clear":
    collider_memory_reset(session)
    fmt.println("collmem: remembered obstacles cleared (they re-learn as you walk).")
    return
  case args[0] == "map":
    switch {
    case len(args) == 1:
      L.collider_memory_map = !L.collider_memory_map
    case args[1] == "on":
      L.collider_memory_map = true
    case args[1] == "off":
      L.collider_memory_map = false
    case:
      fmt.eprintln("usage: collmem map [on|off]")
      return
    }
    if L.collider_memory_map {
      L.collider_memory_on = true // the whole-map mode is meaningless with the store switched off
    }
  case:
    fmt.eprintln("usage: collmem [on|off | map [on|off] | clear]")
    return
  }
  if !L.collider_memory_on {
    collider_memory_reset(session)
  }
  if L.collider_memory_on != was_on || L.collider_memory_map != was_map {
    collider_cache_invalidate(session) // the mode changes how WIDE a scan gathers - re-scan, don't wait
  }
  if session.attached {
    flyff_save_cfg(session.layout, flyff_cfg_path())
  }
  fmt.println(collmem_status_line(session))
}

// One-line state of the obstacle memory, shared by `collmem` and `status full` so they can't drift.
collmem_status_line :: proc(session: ^Session) -> string {
  L := session.layout
  if !L.collider_memory_on {
    return fmt.tprintf("obstacle memory: OFF - the radar draws only the live %.0f-unit window ('collmem on').", COLLIDER_RADIUS)
  }
  mode := L.collider_memory_map ? fmt.tprintf("whole map, cap %d", COLLIDER_MEM_MAX) : fmt.tprintf("evict past %.0f units", math.max(COLLIDER_RADIUS, L.collider_memory_range))
  where_s := "no map bound yet"
  if session.collider_memory_bound {
    where_s = session.collider_memory_map_ok ? fmt.tprintf("map %d", session.collider_memory_map) : fmt.tprintf("world 0x%X", session.collider_memory_world)
  }
  return fmt.tprintf("obstacle memory: ON (%s) - %d box(es) remembered on %s.", mode, len(session.collider_memory), where_s)
}

// Kick a background collider-cache rebuild if none is already in flight. Caller holds exec_mutex (the
// radar frame / reach pass). No-op while a worker runs - the stale cache is served until it publishes.
collider_refresh_async :: proc(session: ^Session, world: uintptr, px, pz: f32) {
  if session.collider_job.active {
    return
  }
  session.collider_job.active = true
  session.collider_job.gen += 1
  req := new(Collider_Job_Req)
  req.session = session
  req.snap.proc_info = session.proc_info
  req.snap.ptr_size = session.ptr_size
  req.snap.layout = session.layout
  req.world = world
  req.px = px
  req.pz = pz
  req.radius = collider_collect_radius(session)
  req.gen = session.collider_job.gen
  thread.create_and_start_with_data(req, collider_scan_worker, nil, .Normal, true) // self_cleanup: fire-and-forget
}

// Worker body: the expensive full-scan collect with NO lock held, then a tiny value-copy publish under
// exec_mutex. A stale generation (detached / superseded by a newer request) discards the batch.
collider_scan_worker :: proc(data: rawptr) {
  tracy.SetThreadName("collider_job")
  req := cast(^Collider_Job_Req)data
  defer free(req)
  defer free_all(context.temp_allocator) // reclaim the worker's scan scratch (Obbs below are value copies)
  tmp := make([dynamic]Obb) // context.allocator: survives the temp free, copied into the cache under the lock
  defer delete(tmp)
  collider_collect_into(&req.snap, req.world, req.px, req.pz, req.radius, &tmp)
  session := req.session
  sync.mutex_lock(&session.exec_mutex)
  defer sync.mutex_unlock(&session.exec_mutex)
  session.collider_job.active = false
  if !session.attached || req.gen != session.collider_job.gen {
    return // superseded - throw the batch away
  }
  // Zoning mid-scan would publish the PREVIOUS map's props - into the reach cache as well as the draw
  // memory - and gen only tracks attach/detach and newer requests, not a zone. The CWorld pointer changes
  // across one, so re-read it under the lock and drop the batch if we are no longer in the world we scanned.
  L := session.layout
  if read_ptr_at(session.proc_info.handle, session.proc_info.base + L.world_rva, .U32) != req.world {
    return
  }
  collider_publish(session, tmp[:], req.world, req.px, req.pz)
}

// ---------------------------------------------------------------------------
// Persistent obstacle memory - DRAW ONLY.
//
// collider_cache is a 120-unit window that is thrown away wholesale every ~16 units of walking, so props
// popped in and out of the radar as you moved even though they never actually move. This store keeps every
// collider we have already scanned on the current map, so the radar accumulates a picture of the ground
// you have walked instead of re-forgetting it.
//
// It NEVER feeds reach / target gating / sweep validation. Those stay on collider_cache, because the store
// can hold a box the client has since unloaded, and a stale blocker that marks ground unreachable would
// silently make the bot skip mobs - a far worse failure than a box drawn a few seconds too long.
//
// Bound to one map (see collider_memory_bind): zoning drops it. Eviction is by distance from the last scan
// centre (collider_memory_range), unless collider_memory_map is set, which keeps the whole map for as long
// as the app runs - capped at COLLIDER_MEM_MAX boxes so it can't grow without bound.
// ---------------------------------------------------------------------------

// Identity of a remembered box: its quantised world centre + type. Position-keyed rather than CObj*-keyed
// because the client frees and reallocates objects as it streams the map - the same tree comes back at a
// different address but at the exact same (static) centre, so a pointer key would duplicate it forever.
// Static props re-read bit-identical centres, so the quantisation never straddles a bucket boundary.
Obb_Key :: struct {
  qx, qy, qz: i32,
  ty:         u32,
}

obb_key :: proc(o: Obb) -> Obb_Key {
  q :: proc(v: f32) -> i32 {
    if !(v > -1e7 && v < 1e7) {
      return 0 // NaN / absurd centre (a half-initialised object): bucket it together, it draws as junk anyway
    }
    return i32(math.round(v * COLLIDER_MEM_QUANT))
  }
  return {q(o.center[0]), q(o.center[1]), q(o.center[2]), o.ty}
}

// Drop the remembered set and its map binding. Caller holds exec_mutex.
collider_memory_reset :: proc(session: ^Session) {
  clear(&session.collider_memory)
  session.collider_memory_bound = false
  session.collider_memory_map = 0
  session.collider_memory_map_ok = false
  session.collider_memory_world = 0
}

// The map a CWorld belongs to. CWorld::m_dwWorldID is declared immediately before m_nLandWidth (client
// World.h), so `worldscan`'s landwidth_off pins it for free - there is no finder here and nothing for
// `setup` to run. ok=false when the terrain offsets aren't pinned; callers fall back to the CWorld* value,
// which also changes across a zone (it is re-resolved every poll for exactly that reason).
world_map_id :: proc(session: ^Session, world: uintptr) -> (id: u32, ok: bool) {
  L := session.layout
  if world == 0 || L.landwidth_off < 4 {
    return 0, false
  }
  return u32(read_i32_at(session.proc_info.handle, world + uintptr(L.landwidth_off - 4))), true
}

// Point the store at the world we are in now, resetting it first if that is a different map than the one
// it was built from. Caller holds exec_mutex.
collider_memory_bind :: proc(session: ^Session, world: uintptr) {
  id, id_ok := world_map_id(session, world)
  if session.collider_memory_bound {
    same :=
      id_ok == session.collider_memory_map_ok &&
      (id_ok ? id == session.collider_memory_map : world == session.collider_memory_world)
    if same {
      return
    }
    collider_memory_reset(session)
  }
  session.collider_memory_bound = true
  session.collider_memory_map = id
  session.collider_memory_map_ok = id_ok
  session.collider_memory_world = world
}

// Fold one fresh scan batch into the remembered set. Caller holds exec_mutex.
//
// Rebuilt into a scratch array rather than patched in place: there is no persistent index to keep in sync
// with, and the whole pass is one map build plus one walk of the store, at the ~16-unit rebuild cadence.
// Three rules, in order:
//   1. the batch always wins - it is the freshest read of everything the client has resident
//   2. inside COLLIDER_RADIUS of the scan centre, a remembered box the batch did NOT report is GONE (a
//      respawn VFX that ended, a kind that just went on the ignore-list) - the scan is complete there
//   3. past it, keep the box - absence only means the client unloaded it - subject to distance eviction
collider_memory_merge :: proc(session: ^Session, batch: []Obb, px, pz: f32) {
  L := session.layout
  ev := math.max(COLLIDER_RADIUS, L.collider_memory_range) // never evict inside the live window
  ev2 := ev * ev
  fresh2 := COLLIDER_RADIUS * COLLIDER_RADIUS
  keys := make(map[Obb_Key]bool, 2 * len(batch) + 64, context.temp_allocator)
  out := make([dynamic]Obb, 0, len(batch) + len(session.collider_memory), context.temp_allocator)
  for o in batch {
    k := obb_key(o)
    if k in keys {
      continue // two props sharing a centre + type: one box is all there is to draw
    }
    keys[k] = true
    append(&out, o)
  }
  for o in session.collider_memory {
    if obb_key(o) in keys {
      continue // rule 1
    }
    dx := o.center[0] - px
    dz := o.center[2] - pz
    d2 := dx * dx + dz * dz
    if d2 <= fresh2 {
      continue // rule 2
    }
    if !L.collider_memory_map && d2 > ev2 {
      continue // rule 3
    }
    append(&out, o)
  }
  clear(&session.collider_memory)
  if len(out) <= COLLIDER_MEM_MAX {
    for o in out {
      append(&session.collider_memory, o)
    }
    return
  }
  // Over the cap (only reachable in keep-the-whole-map mode): keep the CLOSEST boxes. The far ones are the
  // least likely to be looked at again, and walking back over that ground re-learns them. Ranked through a
  // side array because an Odin proc literal can't capture the player position the comparison needs.
  Mem_Rank :: struct {
    d2: f32,
    i:  i32,
  }
  ranks := make([dynamic]Mem_Rank, 0, len(out), context.temp_allocator)
  for o, i in out {
    dx := o.center[0] - px
    dz := o.center[2] - pz
    append(&ranks, Mem_Rank{dx * dx + dz * dz, i32(i)})
  }
  slice.sort_by(ranks[:], proc(a, b: Mem_Rank) -> bool {return a.d2 < b.d2})
  for r in ranks[:COLLIDER_MEM_MAX] {
    append(&session.collider_memory, out[r.i])
  }
}

// Drop every remembered box of one kind. Called when that kind goes on the ignore-list, so the radar loses
// it everywhere at once instead of only where the next scan happens to reach. Caller holds exec_mutex.
collider_memory_purge_kind :: proc(session: ^Session, ty, idx: u32) {
  n := 0
  for o in session.collider_memory {
    if o.ty == ty && o.idx == idx {
      continue
    }
    session.collider_memory[n] = o // compact in place: n <= the read index, so this never clobbers
    n += 1
  }
  resize(&session.collider_memory, n)
}

// Apply the current eviction radius to the store right now, so `set collider_memory_range` to a smaller
// value is visible immediately instead of at the next ~16-unit rebuild. Caller holds exec_mutex. No-op in
// keep-the-whole-map mode (nothing evicts there) or before the first scan (there is no centre to measure).
collider_memory_trim :: proc(session: ^Session) {
  L := session.layout
  if !L.collider_memory_on || L.collider_memory_map || !session.collider_cache_valid {
    return
  }
  ev := math.max(COLLIDER_RADIUS, L.collider_memory_range)
  ev2 := ev * ev
  c := session.collider_cache_center
  n := 0
  for o in session.collider_memory {
    dx := o.center[0] - c[0]
    dz := o.center[2] - c[2]
    if dx * dx + dz * dz > ev2 {
      continue
    }
    session.collider_memory[n] = o // compact in place: n <= the read index
    n += 1
  }
  resize(&session.collider_memory, n)
}

// The boxes to DRAW this frame: everything remembered (or, with memory off, the live cache) that overlaps
// the visible world rect, appended to `out`. Culling here rather than at draw time keeps the per-frame copy
// proportional to the screen instead of to the store, which can hold tens of thousands of boxes. Caller
// holds exec_mutex - the store is republished from the background worker, so the copy has to happen here.
collider_memory_visible :: proc(session: ^Session, cam: [2]f32, scale, fw, fh: f32, out: ^[dynamic]Obb) {
  src := session.layout.collider_memory_on ? session.collider_memory[:] : session.collider_cache[:]
  if scale <= 0 {
    return
  }
  hw := fw / (2 * scale)
  hh := fh / (2 * scale)
  for o in src {
    // slack: a yawed OBB's footprint never reaches further than ext[0]+ext[2] from its centre
    s := o.ext[0] + o.ext[2]
    if abs(o.center[0] - cam[0]) > hw + s || abs(o.center[2] - cam[1]) > hh + s {
      continue
    }
    append(out, o)
  }
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
compute_reach :: proc(session: ^Session, world: uintptr, px, py, pz, tx, tz: f32, allow_async := false) -> Reach_Res {
  tracy.ZoneN("Compute_Reach")
  L := session.layout
  d := engine.dist_horizontal({px, 0, pz}, {tx, 0, tz})
  in_range := L.attack_range > 0 && d <= f32(L.attack_range)
  if tblocked, thit := reach_raycast(session, world, px, pz, tx, tz); tblocked {
    return {status = .Blocked_Terrain, d = d, in_range = in_range, thit = thit, oscan = true}
  }
  oblocked, ohit, oscan := obj_segment_blocked(session, px, py, pz, tx, tz, allow_async)
  if oblocked {
    // Two-stage mesh confirm: our OBB is the loose whole-silhouette box, so a "blocked" is often a false
    // positive on a GMT_NORMAL prop (thin trunk under a wide canopy). Re-test with the client's own
    // IntersectObjLine (OBB + triangle mesh) and treat as Clear if the client can reach it. OBB-CLEAR is
    // trusted (validated: the OBB never under-blocks), so an injection only ever happens on an OBB block.
    // Same knee-height horizontal segment obj_segment_blocked used (player Y for both ends).
    if session.mesh_reach_on && session.ptr_size == 4 && intersectobjline_rva_sane(session) {
      knee := f32(0.4)
      v1 := [3]f32{px, py + knee, pz}
      v2 := [3]f32{tx, py + knee, tz}
      if cblocked, cok := remote_intersect_objline(session, world, v1, v2, false, true); cok && !cblocked {
        return {status = .Clear, d = d, in_range = in_range, oscan = oscan}
      }
    }
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

// ---------------------------------------------------------------------------
// collision-mesh probe - read a prop's model filename + m_CollObject.m_Type (the "does this .o3d have a
// dedicated collision mesh" flag). Recon for the Cloakia decorative-prop filter. See flyff-particle-draw
// sibling recon + the GMTYPE note below.
// ---------------------------------------------------------------------------

// GMTYPE (Object3D.h): the collision classification of a CObject3D's m_CollObject. GMT_ERROR = NO
// dedicated collision mesh, in which case the engine falls back to colliding against the render mesh -
// so GMT_ERROR is NOT "no collision", just "no purpose-built collider". The others carry a real mesh.
GMT_ERROR :: i32(-1)
GMT_NORMAL :: i32(0)
GMT_SKIN :: i32(1)
GMT_BONE :: i32(2)

gmt_name :: proc(t: i32) -> string {
  switch t {
  case GMT_ERROR:
    return "ERROR(no-mesh)"
  case GMT_NORMAL:
    return "NORMAL"
  case GMT_SKIN:
    return "SKIN"
  case GMT_BONE:
    return "BONE"
  }
  return "?"
}

MODEL_ELEM_SCAN :: 0x600 // bytes of CModelObject scanned for the m_Element[0].m_pObject3D pointer
O3D_HEAD_SCAN :: 0x120 // bytes of CObject3D scanned for the m_szFileName string

// Chase CObj -> m_pModel (CModelObject) -> m_Element[0].m_pObject3D (CObject3D) -> m_szFileName +
// m_CollObject.m_Type. The two inner offsets aren't pinned yet, so we ANCHOR on the ".o3d" filename:
// scan the model for a heap pointer whose target holds an ".o3d" string, then read the collision type at
// (string start + 0x40) - m_szFileName is char[64] and m_CollObject.m_Type is GMOBJECT's first field -
// and require a valid GMTYPE. elem_off/name_off are returned so a caller can vote a consensus to pin.
probe_model_coll :: proc(session: ^Session, obj: uintptr) -> (fname: string, elem_off: i64, name_off: i64, coll: i32, ok: bool) {
  handle := session.proc_info.handle
  pt := engine.Value_Type.U32
  model := read_ptr_at(handle, obj + uintptr(session.layout.model_off), pt)
  if !is_heap_ptr(session, model) {
    return
  }
  mbuf: [MODEL_ELEM_SCAN]byte
  mn, mok := engine.read_into(handle, model, mbuf[:])
  if !mok {
    return
  }
  for eo := 0; eo + 4 <= int(mn); eo += 4 {
    p := uintptr(rd_u32le(mbuf[:], eo))
    if !is_heap_ptr(session, p) {
      continue
    }
    obuf: [O3D_HEAD_SCAN]byte
    on, ook := engine.read_into(handle, p, obuf[:])
    if !ook || int(on) < 0x60 {
      continue
    }
    for i := 0; i + 4 <= int(on); i += 1 {
      // case-insensitive ".o3d"
      if !(obuf[i] == '.' && (obuf[i + 1] | 0x20) == 'o' && obuf[i + 2] == '3' && (obuf[i + 3] | 0x20) == 'd') {
        continue
      }
      st := i // walk back to the printable-ASCII string (field) start
      for st > 0 && obuf[st - 1] >= 0x20 && obuf[st - 1] < 0x7f {
        st -= 1
      }
      to := st + 0x40 // m_CollObject.m_Type at m_szFileName + 0x40
      if to + 4 > int(on) {
        continue
      }
      t := transmute(i32)rd_u32le(obuf[:], to)
      if t < GMT_ERROR || t > GMT_BONE {
        continue // not a plausible GMTYPE - this pointer isn't the CObject3D
      }
      en := i + 4 // end of the filename run
      for en < int(on) && obuf[en] >= 0x20 && obuf[en] < 0x7f {
        en += 1
      }
      fname = strings.clone(string(obuf[st:en]), context.temp_allocator)
      elem_off = i64(eo)
      name_off = i64(st)
      coll = t
      ok = true
      return
    }
  }
  return
}

// Fast collision-mesh type via the pinned offsets: CObj.m_pModel -> m_Element[0].m_pObject3D ->
// m_CollObject.m_Type. Cheap (two pointer reads + one i32) so it can run in the per-segment prop walk,
// unlike probe_model_coll's string search. ok=false when the offsets aren't pinned or a pointer is dead.
obj_coll_type :: proc(session: ^Session, obj: uintptr) -> (t: i32, ok: bool) {
  L := session.layout
  if L.coll_obj3d_off == 0 || L.coll_type_off == 0 {
    return
  }
  handle := session.proc_info.handle
  pt := engine.Value_Type.U32
  model := read_ptr_at(handle, obj + uintptr(L.model_off), pt)
  if !is_heap_ptr(session, model) {
    return
  }
  obj3d := read_ptr_at(handle, model + uintptr(L.coll_obj3d_off), pt)
  if !is_heap_ptr(session, obj3d) {
    return
  }
  v, vok := engine.read_value(handle, obj3d + uintptr(L.coll_type_off), .U32)
  if !vok {
    return
  }
  t = transmute(i32)u32(engine.value_as_u64(.U32, v))
  ok = true
  return
}

// Is this object "kind" (m_dwType + m_dwIndex) on the user's collider ignore-list? Kinds are curated by
// clicking phantom boxes in the radar inspect mode (collider_ignore_toggle) and persisted in flyff.cfg. A
// denied kind is dropped from the collider set in obj_to_obb / obj_obb_blocks, so a mis-collected effect
// (e.g. a player-following OT_CTRL aura, index 1726) never walls off a mob or draws as a radar box. Reads
// session.layout by reference (the list is a fixed array in the layout) so it's cheap in the per-object scan.
collider_denied :: proc(session: ^Session, ty, idx: u32) -> bool {
  for i in 0 ..< int(session.layout.collider_ignore_n) {
    k := session.layout.collider_ignore[i]
    if k.ty == ty && k.idx == idx {
      return true
    }
  }
  return false
}

// Is this prop decorative (the game's pursuit collision walks straight through it)? Mirrors
// CWorld::ProcessCollision: OT_OBJ static props are tested with bNeedCollObject=TRUE, which SKIPS any
// whose m_CollObject.m_Type == GMT_ERROR (no dedicated collision mesh - bushes/grass/butterflies).
// OT_CTRL (walls/housing) is tested with bNeedCollObject=FALSE and always collides, so it's never
// decorative. When the coll offsets aren't pinned (ok=false) we can't tell, so we treat it as solid
// (keep blocking) - the pre-filter behaviour.
obj_is_decorative :: proc(session: ^Session, obj: uintptr, ty: u32) -> bool {
  if ty != 0 { // OT_OBJ only; OT_CTRL always blocks
    return false
  }
  if t, ok := obj_coll_type(session, obj); ok && t == GMT_ERROR {
    return true
  }
  return false
}

// collscan [radius] - for each nearby OT_OBJ / OT_CTRL prop (found by a full memory scan, so all props
// count, not just the on-screen ones), read its model filename + collision-mesh type. The decorative-prop
// recon: it shows, per prop, whether the .o3d has a dedicated collision mesh (NORMAL) or falls back to the
// render mesh (ERROR). Read-only; auto-pins the consensus (coll_obj3d_off, coll_type_off) for the filter.
cli_collscan :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if session.ptr_size != 4 {
    fmt.eprintln("collscan: 32-bit Flyff client only.")
    return
  }
  L := session.layout
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  po := int(L.pos_off)
  wlen := po + 0x1C
  if wlen > 512 {
    fmt.eprintln("collscan: implausible pos_off.")
    return
  }
  world := read_ptr_at(handle, base + L.world_rva, engine.Value_Type.U32)
  if world == 0 {
    fmt.eprintln("collscan: world not resolved - run 'setup <name>' first.")
    return
  }

  ppos, pok := read_player_pos(session)
  if !pok {
    fmt.eprintln("collscan: couldn't read player position.")
    return
  }
  radius := f32(40)
  if len(args) >= 1 {
    if r, rok := strconv.parse_f64(args[0]); rok && r > 0 {
      radius = f32(r)
    }
  }

  buf: [512]byte
  rf :: proc(b: []byte, k: int) -> f32 {return transmute(f32)rd_u32le(b, k)}

  Row :: struct {
    obj:      uintptr,
    ty:       u32,
    dist:     f32,
    coll:     i32,
    has_coll: bool,
    fname:    string,
  }
  rows := make([dynamic]Row, context.temp_allocator)
  votes := make(map[[2]i64]int, 8, context.temp_allocator)
  seen := make(map[uintptr]bool, 512, context.temp_allocator)
  n_props := 0
  n_probed := 0
  // Full writable-memory scan for the world pointer -> every CObj (holds m_pWorld at field_off), so we
  // see all nearby props (better consensus + no findcull/aobjcull dependency), not just the on-screen set.
  wval := engine.ptr_to_value(world, session.ptr_size)
  regions := engine.collect_regions(handle, true)
  defer delete(regions)
  set := engine.scan_exact_parallel(handle, engine.Value_Type.U32, wval, regions[:], context.temp_allocator)
  for m in set.matches {
    obj := uintptr(i64(m.addr) - L.field_off)
    if seen[obj] {
      continue
    }
    rn, rok := engine.read_into(handle, obj, buf[:wlen])
    if !rok || int(rn) < wlen {
      continue
    }
    vt := uintptr(rd_u32le(buf[:], 0))
    if vt < base || vt >= mod_end {
      continue // not a live CObj
    }
    ty := rd_u32le(buf[:], po + 0x10)
    if ty != 0 && ty != 3 {
      continue // OT_OBJ / OT_CTRL only (the collidable props)
    }
    seen[obj] = true
    dx := rf(buf[:], po) - ppos[0]
    dz := rf(buf[:], po + 8) - ppos[2]
    dist := math.sqrt(dx * dx + dz * dz)
    if dist > radius {
      continue
    }
    n_props += 1
    fname, eoff, noff, coll, cok := probe_model_coll(session, obj)
    if cok {
      n_probed += 1
      votes[[2]i64{eoff, noff}] += 1
    }
    append(&rows, Row{obj, ty, dist, coll, cok, fname})
  }

  // sort by distance (selection sort; small near-set)
  for i in 0 ..< len(rows) {
    mn := i
    for j in i + 1 ..< len(rows) {
      if rows[j].dist < rows[mn].dist {
        mn = j
      }
    }
    rows[i], rows[mn] = rows[mn], rows[i]
  }

  fmt.printfln("collscan: %d props (OT_OBJ/OT_CTRL) within %.0f of player; %d resolved a model+coll type.", n_props, radius, n_probed)
  fmt.println("  addr        type       dist  coll            model (.o3d)")
  n_err := 0
  n_mesh := 0
  for r in rows {
    coll_s := r.has_coll ? gmt_name(r.coll) : "?(no model)"
    if r.has_coll {
      if r.coll == GMT_ERROR {n_err += 1} else {n_mesh += 1}
    }
    fmt.printfln("  0x%08X  %-6s(%d)  %5.1f  %-14s  %s", r.obj, ot_name(r.ty), r.ty, r.dist, coll_s, r.fname)
  }
  fmt.printfln("  => %d with a dedicated collision mesh (NORMAL/SKIN/BONE), %d ERROR (render-mesh fallback).", n_mesh, n_err)
  // Consensus inner offsets (only meaningful if most props agree).
  best_key: [2]i64
  best_v := 0
  for key, v in votes {
    if v > best_v {
      best_v = v
      best_key = key
    }
  }
  if best_v > 0 {
    type_off := best_key[1] + 0x40
    fmt.printfln(
      "  => consensus offsets: m_Element[0].m_pObject3D @ model+0x%X, m_szFileName @ object3D+0x%X (%d/%d props agree). m_CollObject.m_Type @ +0x%X.",
      best_key[0], best_key[1], best_v, n_probed, type_off,
    )
    // Pin + save only on a strong consensus, so a patch-shifted layout can't half-pin a bad offset.
    if n_probed >= 8 && best_v == n_probed {
      L.coll_obj3d_off = best_key[0]
      L.coll_type_off = type_off
      session.layout = L
      if flyff_save_cfg(session.layout, flyff_cfg_path()) {
        fmt.println("  => pinned coll_obj3d_off / coll_type_off -> flyff.cfg. Decorative-prop filter is now ON.")
      }
    } else if best_v != n_probed {
      fmt.println("  => not saved (props disagree on the offsets). Re-run somewhere with more props in view.")
    }
  }
}

// ---------------------------------------------------------------------------
// collwatch - catch a TRANSIENT collider (a mob-respawn VFX / pet-activation effect that's only up for a
// fraction of a second, so a one-shot `collscan` can't be timed to it). Polls the object set every
// ~300ms for <seconds>; the instant an object APPEARS (after a baseline snapshot) it's logged with its
// full identity (type, model, collision mesh, box) and flagged [COLLIDER] if our reach filter would
// treat it as solid; when it vanishes, its lifetime is printed. Just run it and re-trigger the effect
// (activate the pick-up pet / farm at a spawn) - no timing needed. Read-only; releases exec_mutex
// between polls so auto-farm keeps running. Diagnostic only (pins nothing), so it's not in setup/status.
// ---------------------------------------------------------------------------

COLLWATCH_INTERVAL_MS :: u32(300)

Collwatch_Seen :: struct {
  first_ns:      i64,
  last_iter:     int, // last poll index this object was present in
  ident:         string, // cloned identity line (printed on vanish, after the object is freed)
  is_coll:       bool,
  reported_gone: bool,
}

// Format one object's identity for collwatch, and decide whether our reach filter would treat it as a
// solid collider (mirrors the obj_to_obb gate). within=false if it's outside <radius> of the player.
collwatch_identify :: proc(session: ^Session, obj: uintptr, ppos: [3]f32, radius: f32) -> (line: string, is_coll: bool, within: bool, ok: bool) {
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  po := int(session.layout.pos_off)
  wlen := po + 0x1C
  if wlen > 512 {
    return
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
  rf :: proc(b: []byte, k: int) -> f32 {return transmute(f32)rd_u32le(b, k)}
  ty := rd_u32le(buf[:], po + 0x10)
  pos := [3]f32{rf(buf[:], po), rf(buf[:], po + 4), rf(buf[:], po + 8)}
  dx := pos[0] - ppos[0]
  dz := pos[2] - ppos[2]
  d := math.sqrt(dx * dx + dz * dz)
  if d > radius {
    return "", false, false, true // valid object, just out of range
  }
  oo := po - 0x3C
  ext := [3]f32{rf(buf[:], oo + 0xC), rf(buf[:], oo + 0x10), rf(buf[:], oo + 0x14)}
  // Would obj_to_obb keep this as a solid collider? Type gate + degenerate-box drop + small-OT_CTRL drop.
  is_coll = (ty == 0 || ty == 3) && (ext[0] > 0.01 || ext[2] > 0.01)
  if is_coll && ty == 3 && ext[0] <= CTRL_DROP_MAX_XZ && ext[2] <= CTRL_DROP_MAX_XZ && ext[1] <= CTRL_DROP_MAX_Y {
    is_coll = false // small OT_CTRL = ground drop / effect zone, already dropped
  }
  coll_s := "-"
  if fname, _, _, coll, cok := probe_model_coll(session, obj); cok {
    coll_s = fmt.tprintf("%s '%s'", gmt_name(coll), fname)
  }
  line = fmt.tprintf(
    "0x%08X %s(%d) d=%4.1f box=(%.1f,%.1f,%.1f) mesh=%s",
    obj, ot_name(ty), ty, d, ext[0], ext[1], ext[2], coll_s,
  )
  return line, is_coll, true, true
}

// Build the multi-line identity readout for the radar inspect-mode tooltip: address, OT type + distance,
// .o3d model name, collision-mesh type + box half-extents, and whether reach blocks on it (decorative
// props are walk-through). Returns temp-allocated cstrings for the caller to draw this frame. Read-only;
// mirrors collwatch_identify's fields. `o` is a cached Obb (its .obj is the live CObj*, 0 if unknown).
collider_inspect_lines :: proc(session: ^Session, o: Obb, ppos: [3]f32) -> []cstring {
  lines := make([dynamic]cstring, 0, 6, context.temp_allocator)
  dx := o.center[0] - ppos[0]
  dz := o.center[2] - ppos[2]
  d := math.sqrt(dx * dx + dz * dz)
  // A REMEMBERED box outlives its CObj (the client streams objects out as you walk away), so identity comes
  // off the box itself - obj_to_obb captured it - and the live object is consulted only for the model/mesh
  // detail. `live` asks whether that CObj still holds THIS box, so a recycled address can't be printed as
  // if it were the thing under the cursor.
  po := uintptr(session.layout.pos_off)
  h := session.proc_info.handle
  live :=
    o.obj != 0 &&
    u32(read_i32_at(h, o.obj + po + 0x10)) == o.ty &&
    u32(read_i32_at(h, o.obj + po + 0x14)) == o.idx
  append(&lines, fmt.ctprintf("INSPECT  0x%08X%s", o.obj, live ? "" : "   (remembered)"))
  append(&lines, fmt.ctprintf("%s(%d) idx=%d   d=%.1f", ot_name(o.ty), o.ty, o.idx, d))
  model_s := "not loaded (client streamed it out)"
  mesh_s := "?"
  if live {
    model_s = "unknown"
    if fname, _, _, coll, cok := probe_model_coll(session, o.obj); cok {
      model_s = fname // temp-allocated by probe_model_coll - survives the frame
      mesh_s = gmt_name(coll)
    }
  }
  append(&lines, fmt.ctprintf("model: %s", model_s))
  append(&lines, fmt.ctprintf("mesh: %s   box=(%.1f,%.1f,%.1f)", mesh_s, o.ext[0], o.ext[1], o.ext[2]))
  append(&lines, fmt.ctprintf("BLOCKS REACH: %s", o.decorative ? "no (walk-through)" : "yes"))
  if collider_denied(session, o.ty, o.idx) {
    append(&lines, fmt.ctprintf("IGNORED  (collignore rm %d %d to restore)", o.ty, o.idx))
  } else {
    append(&lines, "click: ignore this kind (hides all like it)")
  }
  return lines[:]
}

// collwatch [seconds] [radius] - see the section header above.
cli_collwatch :: proc(session: ^Session, args: []string) {
  if !session.attached || session.ptr_size != 4 {
    fmt.eprintln("collwatch: attach a 32-bit Neuz first.")
    return
  }
  L := session.layout
  handle := session.proc_info.handle
  base := session.proc_info.base
  world := read_ptr_at(handle, base + L.world_rva, engine.Value_Type.U32)
  if world == 0 {
    fmt.eprintln("collwatch: world not resolved - run 'setup <name>' first.")
    return
  }
  // Args are position-free: 'all'/'v'/'verbose' -> also show non-collider objects (mobs/items/effects);
  // the first numeric = seconds, the second numeric = radius.
  secs := 30
  radius := f32(60)
  verbose := false
  nnum := 0
  for a in args {
    if a == "all" || a == "v" || a == "verbose" {
      verbose = true
      continue
    }
    if v, ok := strconv.parse_f64(a); ok && v > 0 {
      if nnum == 0 {
        secs = min(int(v), 600)
      } else if nnum == 1 {
        radius = f32(v)
      }
      nnum += 1
    }
  }

  seen := make(map[uintptr]Collwatch_Seen, 512) // default allocator - persists across polls
  defer {
    for _, s in seen {
      delete(s.ident)
    }
    delete(seen)
  }

  wval := engine.ptr_to_value(world, session.ptr_size)
  deadline := time.now()._nsec + i64(secs) * 1_000_000_000
  fmt.printfln(
    "collwatch: polling every %dms for %ds within %.0f, %s. Farm the spawn (tower map); each SOLID box logs as it appears - [COLLIDER] lines are the phantom-obstacle candidates.",
    COLLWATCH_INTERVAL_MS, secs, radius, verbose ? "ALL objects" : "colliders only (mobs/items hidden)",
  )
  iter := 0
  n_new := 0
  for {
    now_ns := time.now()._nsec
    // Re-resolve world + player each poll (zoning / re-log changes them).
    w := read_ptr_at(handle, base + L.world_rva, engine.Value_Type.U32)
    ppos, pok := read_player_pos(session)
    if w != 0 && pok {
      regions := engine.collect_regions(handle, true)
      set := engine.scan_exact_parallel(handle, engine.Value_Type.U32, wval, regions[:], context.temp_allocator)
      delete(regions)
      for m in set.matches {
        obj := uintptr(i64(m.addr) - L.field_off)
        line, is_coll, within, ok := collwatch_identify(session, obj, ppos, radius)
        if !ok || !within {
          continue
        }
        // COLLIDERS ONLY: the phantom is a solid OBJ/CTRL box (that's exactly what the radar draws as a
        // purple box). Movers (mobs), items, effects reach ignores are dropped here so they can't bury
        // the signal - unless <verbose> was passed (2nd... 'all' or 'v').
        if !is_coll && !verbose {
          continue
        }
        if s, found := &seen[obj]; found {
          s.last_iter = iter
        } else {
          seen[obj] = Collwatch_Seen{first_ns = now_ns, last_iter = iter, ident = strings.clone(line), is_coll = is_coll}
          if iter > 0 { // don't spam the baseline set on the first poll
            n_new += 1
            fmt.printfln("[collwatch +] %s%s", is_coll ? "[COLLIDER] " : "[non-coll] ", line)
          }
        }
      }
      // Vanished-since-last-poll -> print lifetime once (confirms transience; the memory is freed by now).
      for obj, &s in seen {
        if !s.reported_gone && s.last_iter < iter {
          fmt.printfln("[collwatch -] gone after %.1fs: %s", f32(now_ns - s.first_ns) / 1e9, s.ident)
          s.reported_gone = true
        }
        _ = obj
      }
      if iter == 0 {
        fmt.printfln("[collwatch] baseline: %d %s in range - now watching for new ones...", len(seen), verbose ? "object(s)" : "collider(s)")
      }
    }
    free_all(context.temp_allocator)
    iter += 1
    if time.now()._nsec >= deadline {
      break
    }
    // Release the lock across the sleep so the watcher keeps farming; re-acquire before the next poll
    // (cli_collwatch is entered holding exec_mutex and must return holding it).
    sync.mutex_unlock(&session.exec_mutex)
    win.Sleep(COLLWATCH_INTERVAL_MS)
    sync.mutex_lock(&session.exec_mutex)
  }
  fmt.printfln("collwatch: done. %d new object(s) appeared during the watch (look for [COLLIDER] lines).", n_new)
}

// ---------------------------------------------------------------------------
// linkscan - pin CLandscape::m_apObjLink (the collision spatial index) so reach can enumerate obstacles
// CAMERA-INDEPENDENTLY (unlike m_aobjCull, which only holds what the render frustum draws). Structure
// (landscape.h / lod.cpp): CLandscape.m_apObjLink[MAX_LINKTYPE=4][MAX_LINKLEVEL=7], each a CObj** head
// array of nWidth^2 cells (nWidth = 128>>level); objects chain via CObj::m_pNext (= pos_off+0x20).
// Cell index (InsertObjLink): nUnit=1<<level; nPos=(localZ/nUnit)*nWidth + localX/nUnit.
// ---------------------------------------------------------------------------

LINK_MAX_LEVEL :: 7
LINK_MAX_TYPE :: 4

// ---------------------------------------------------------------------------
// findobjline - re-pin intersectobjline_rva after a patch (the one-command meshreach setup)
// ---------------------------------------------------------------------------

// findobjline - re-derive intersectobjline_rva after a game patch. A patch shifts the function; the
// defaulted RVA then points at wrong code, so its prologue no longer matches and meshreach / objline /
// reachcmp all go inert (the "on but inert" you see in status). This is the missing "just works" finder:
// it needs no manual codescan/disasm.
//
// How it pins the function (mirrors findparticle, plus a hard prologue gate):
//  1. scan_bytes for the unique anchor string "CWorld::IntersectObjLine" - the Error() text in the
//     object-cull overflow guard inside the function body (verified single occurrence in the client).
//  2. codescan_u32 for code that pushes that string's absolute VA (the `push offset; call Error`).
//  3. walk back over MSVC int3 inter-function padding to the entry of the function containing that push.
//  4. verify the entry's prologue is the aligned-frame + __chkstk opener 55 8B EC 83 E4 F0 B8 (the huge
//     CObj* pNonCullObjs[10000] stack array forces exactly this). The prologue gate both confirms we
//     landed on the right function and is the same check intersectobjline_rva_sane uses before every call.
// Read-only recon (no injection). On success it sets + saves intersectobjline_rva; after that 'meshreach
// on' takes effect. It does NOT enable meshreach - that stays opt-in (it injects, crash-prone).
cli_findobjline :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if session.ptr_size != 4 {
    fmt.eprintln("IntersectObjLine lives in the 32-bit Flyff client; attach the WOW64 Neuz.exe.")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base

  // 1) Locate the anchor string. ASCII-only prefix (the literal continues in Korean, which is
  //    code-page-dependent); "CWorld::IntersectObjLine" occurs exactly once in the client.
  anchor := "CWorld::IntersectObjLine"
  pat := make([]byte, len(anchor), context.temp_allocator)
  copy(pat, anchor)
  straddrs := engine.scan_bytes(handle, pat, context.temp_allocator)
  if len(straddrs) == 0 {
    fmt.eprintln("findobjline: anchor string not found (a patch changed it?). Fall back to the manual disasm route.")
    return
  }

  // 2-4) For each string address, find the code refs, walk each back to a function entry, and keep the
  //       first entry whose prologue matches. The prologue gate disambiguates multiple refs/strings.
  want := [?]byte{0x55, 0x8B, 0xEC, 0x83, 0xE4, 0xF0, 0xB8}
  PRE :: 0x1000 // walk-back window: entry is well within this of the in-body Error() push
  found: uintptr = 0
  n_refs := 0
  for sa in straddrs {
    refs := engine.codescan_u32(handle, u32(sa), context.temp_allocator)
    n_refs += len(refs)
    for ref in refs {
      pre := make([]byte, PRE + 16, context.temp_allocator)
      rn, _ := engine.read_into(handle, ref - PRE, pre)
      if int(rn) < PRE {
        continue
      }
      // entry = nearest addr <= ref preceded by >=2 int3 (MSVC inter-function padding).
      entry: uintptr = 0
      for j := PRE; j >= 2; j -= 1 {
        if pre[j - 1] == 0xCC && pre[j - 2] == 0xCC {
          entry = ref - PRE + uintptr(j)
          break
        }
      }
      if entry == 0 {
        continue
      }
      pb: [len(want)]byte
      en, eok := engine.read_into(handle, entry, pb[:])
      if !eok || int(en) < len(want) {
        continue
      }
      match := true
      for b, i in want {
        if pb[i] != b {
          match = false
          break
        }
      }
      if match {
        found = entry
        break
      }
    }
    if found != 0 {
      break
    }
  }

  if found == 0 {
    fmt.eprintfln(
      "findobjline: located the anchor + %d code ref(s), but none walked back to a function with the",
      n_refs,
    )
    fmt.eprintln("  expected prologue 55 8B EC 83 E4 F0 B8. The compiler may have reshaped it - disasm around the")
    fmt.eprintln("  ref and 'set intersectobjline_rva 0x<entry>' by hand.")
    return
  }

  new_rva := found - base
  old := session.layout.intersectobjline_rva
  session.layout.intersectobjline_rva = new_rva
  if new_rva == old {
    fmt.printfln("findobjline: intersectobjline_rva=0x%X - already correct (prologue verified).", new_rva)
  } else {
    fmt.printfln("findobjline: intersectobjline_rva=0x%X (was 0x%X). prologue verified.", new_rva, old)
  }
  // Authoritative re-check against live memory - the exact gate every objline call runs.
  if intersectobjline_rva_sane(session) {
    fmt.println("  [OK] prologue re-checks in place. 'meshreach on' will now take effect (objline / reachcmp too).")
  } else {
    fmt.println("  [!!] unexpected: sane-check still fails after set - do NOT enable meshreach; disasm by hand.")
  }
  if flyff_save_cfg(session.layout, flyff_cfg_path()) {
    fmt.println("  saved to flyff.cfg.")
  }
}

// ---------------------------------------------------------------------------
// objline / reachcmp - validate our OBB oracle against the client's own IntersectObjLine (step 3)
// ---------------------------------------------------------------------------

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
