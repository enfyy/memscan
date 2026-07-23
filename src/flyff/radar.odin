package flyff

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import rl "vendor:raylib"

import "../engine"

import tracy "../../lib/odin-tracy"

// NOTE (raylib static link): raylib's CloseWindow / ShowCursor collide by NAME with Win32 user32.dll's,
// and memscan links user32 (global hotkeys). We statically link raylib with the linker flag
// `/WHOLEARCHIVE:raylib.lib` (see build.bat / [[memscan-build-and-test]]), which forces raylib's whole
// archive in first so its CloseWindow wins and user32's is never pulled - so `rl.CloseWindow` here is
// raylib's and tears the window down correctly. Build WITHOUT that flag and the window lingers frozen.

// ===========================================================================
// Live top-down radar window (raylib). Player + mobs + obstacles are drawn each frame from the
// CAMERA-INDEPENDENT tile object arrays (m_apObject) - see terrain.odin. The view is WORLD-ANCHORED
// (a pannable camera in world coords), so shapes and fences stay put as the player moves. Press E to
// enter the fence editor (draw +/- circles/rects/polygons with the mouse); membership shades the live
// mobs so you preview exactly what the target gate will keep. Press F to overlay the render camera's
// eye + frustum cone. The white player dot carries a facing arrow (m_fAngle, same convention as the
// tdbg HTML). See fence.odin for the model + gate.
//
// Runs on the calling (REPL) thread until closed (ESC / window X / optional duration). Each frame it does
// all session-touching work (mouse fence edits, memory reads, collider snapshot) while holding the REPL's
// exec_mutex, then RELEASES it for the draw/present so the watcher thread can run auto_tick - so auto-farm
// keeps going while the radar is open. Because fence writes happen only inside that locked section, they
// never race the picker (which reads session.fence under the same mutex). The text command channel stays
// the headless/scripting interface (the fence is also fully authorable via the `fence` commands).
// ===========================================================================

OT_MOVER_IDX :: 5 // m_apObject[] index for OT_MOVER (mobs / players / pets)

FENCE_INC :: rl.Color{46, 204, 113, 255} // + inclusion shape (green)
FENCE_EXC :: rl.Color{231, 126, 34, 255} // - exclusion / carve-out shape (orange)
FENCE_AVOID :: rl.Color{224, 40, 96, 255} // ! avoid / hard no-go shape (crimson)

// Fence shape outline color by its role (see Fence_Shape). Shared by the live draw + the editor preview.
fence_shape_color :: proc(include, avoid: bool) -> rl.Color {
  if avoid {
    return FENCE_AVOID
  }
  return include ? FENCE_INC : FENCE_EXC
}
CAM_COL :: rl.Color{90, 200, 225, 255} // camera eye + frustum cone (cyan; toggled with F)

MOB_COL :: rl.Color{231, 76, 60, 255} // attackable monster (red)
PLAYER_COL :: rl.Color{80, 150, 255, 255} // another player (azure; drawn larger, with a facing arrow)
OTHER_COL :: rl.Color{130, 140, 150, 220} // pet / egg / NPC (neutral grey)
UNCLASS_COL :: rl.Color{231, 76, 60, 255} // any mover, when the AI gate isn't configured (falls back to red)
FILTER_DIM_COL :: rl.Color{72, 80, 92, 130} // monster that DOESN'T match the active name filter (dimmed, not a target)
GIANT_COL :: rl.Color{255, 190, 60, 255} // "Giant *" monster overlay (gold); shown map-wide, even beyond vision range

// Map-wide giant scan (radar_scan_giants): giants can spawn far outside the vision-range mover window, so a
// throttled full-tile pass finds every "Giant *" monster on the map and the overlay draws/rim-clamps them.
GIANT_SCAN_NS :: i64(1_200_000_000) // rescan interval (~1.2s; giants are rare + slow, so this is plenty)
SEL_COL :: rl.Color{241, 196, 15, 255} // selected-target highlight ring (yellow)
RANGE_COL :: rl.Color{46, 204, 113, 130} // attack_range ring around the player (soft green)

// --- Phase 4 radar interaction (click-to-target / shift-click-to-move) + juice (penya pop, move mark) ---
HIT_R :: f32(12) // screen-px radius: a left-click within this of a mob dot targets it
POP_TTL :: i64(1_200_000_000) // "+penya" pop lifetime (~1.2s): rises + fades over this
MARK_TTL :: i64(900_000_000) // move-destination marker lifetime (~0.9s)
PENYA_COL :: rl.Color{255, 208, 64, 255} // "+penya" pop text (gold)
HOVER_COL :: rl.Color{64, 224, 255, 220} // ring on the mob a plain click would target (bright cyan-blue; distinct from the yellow selection ring)
MARK_COL :: rl.Color{90, 200, 225, 255} // shift-click move-destination pip (cyan)
LASER_TTL :: i64(400_000_000) // kill laser-beam lifetime (~0.4s): drawn from you to the mob, fading out
LASER_COL :: rl.Color{255, 70, 190, 255} // kill beam (magenta - distinct from every other radar colour)

// Player-path trail (radar juice; toggle: `trail`). A faint fading breadcrumb line behind the player,
// sampled into a radar-local ring each frame when the player has moved >= TRAIL_MIN_STEP world units
// since the last crumb (idling never grows it; a single hop > TRAIL_BREAK_STEP is a teleport / map
// change -> clear + restart). Total world length is capped at L.trail_len; alpha fades from TRAIL_MAX_A
// at the player to 0 at the tail via the L.trail_fade exponent. Deliberately thin + low-alpha, and drawn
// UNDER the mob/player dots, so it never masks a target.
TRAIL_COL :: rl.Color{235, 240, 250, 255} // soft near-white (reads as "my path", behind the white dot)
TRAIL_MAX_A :: 90                          // peak alpha at the player (out of 255) - deliberately subtle
TRAIL_W :: f32(2.0)                        // line thickness (px)
TRAIL_MIN_STEP :: f32(0.6)                 // min world-move before a new crumb is appended
TRAIL_BREAK_STEP :: f32(60.0)              // a single hop farther than this = teleport/map change -> clear
TRAIL_MAX_PTS :: 2000                      // hard cap on crumb count (safety net; > max_len/min_step so it never truncates before trail_len)

// Radar terrain hillshade (display-only; toggle: `hillshade`). A COLOURLESS shaded-relief backdrop of
// the terrain, lit from a fixed compass direction (hillshade_light, degrees CW from north; default NW).
// It reads the same heightmap the reach oracle uses (world_attr_at / decode_hgt) and shades each screen
// cell by the slope's alignment with the light, so hills/cliffs/ramps emboss in grey WITHOUT spending
// any of the map's semantic colour budget. Flat ground -> HILL_BASE (a hair above the background, which
// also demarcates "terrain here" from void/water); slopes swing +/- HILL_SPAN. Drawn UNDER everything
// (bottom layer, under crosshair/obstacles/fences/dots). Needs `worldscan` pinned; else draws nothing.
HILL_BASE :: 24     // flat-ground luminance (just above the {12,16,22} background)
HILL_SPAN :: 34     // luminance swing from base by slope-vs-light (lit ridge brighter, shadow recedes)
HILL_CELL_PX :: 8   // on-screen cell size (px), constant at every zoom; bilinear sampling fills detail
HILL_MAX_DIM :: 260 // hard cap on grid columns/rows (huge windows) so one rebuild stays bounded

// Fence floating toolbar (edit mode only; drawn over the map's top-left). The rect is also excluded
// from map input (mouse_in_panel) while edit is on, so a toolbar click never doubles as a fence
// draw/erase at the same screen point.
FENCE_TB_RECT :: rl.Rectangle{12, 36, 252, 62}

// Quick-access sound mute button, top-left corner of the map (mirrors the "?" legend badge top-right).
// Click toggles L.sfx_on (same state the Options "Sound" button and the `sfx` command drive). Excluded
// from map input via mouse_in_panel so a click never also pans/targets. Sits above the fence toolbar.
MUTE_BTN_RECT :: rl.Rectangle{8, 8, 34, 26}

// Radar vision (mob-dot gather/draw radius, world units) - slider bounds. The max stays under one
// landscape tile side (MAP_SIZE*mpu ~ 512u) so the current 3x3 mover tile-window always covers it; a
// larger range would need radar_gather_movers' tile loop widened. Persisted as layout.radar_range.
RADAR_RANGE_MIN :: f32(40)
RADAR_RANGE_MAX :: f32(400)

// Jump dot-hop animation (see the player-dot draw): the player dot lifts along a 0.6s sine hump.
JUMP_ANIM_NS :: i64(600_000_000)
JUMP_LIFT_PX :: f32(14)

// A floating "+N penya" popup at a world point (drawn on the radar, rises + fades). Appended when the
// live penya field increases (a loot pickup); pruned once older than POP_TTL. Radar-local (see cli_radar).
Penya_Pop :: struct {
  amount: i64,
  t:      i64, // time.now()._nsec at spawn
  pos:    [3]f32,
}
// A fading destination marker where a shift-click issued a moveto.
Move_Mark :: struct {
  pos: [3]f32,
  t:   i64,
}
// A fading kill laser-beam from the player to where a mob just died (drained from session.kill_events).
Laser_Fx :: struct {
  to: [3]f32,
  t:  i64,
}

// ===========================================================================
// SFX - tiny synthesized sounds, no asset files. Built once when the radar opens; the sample buffers
// use context.allocator and are deliberately NEVER freed (a few KB, one-off per window - sidesteps any
// LoadSoundFromWave copy-semantics doubt). Play only while the radar window (+ its audio device) is up.
// ===========================================================================

SFX_SR :: 44100 // sample rate (Hz)
// Durations pre-converted to whole sample counts (Odin won't truncate a fractional float const to int).
CHIME_N1 :: 3969 // ~90ms  @ 44100
CHIME_N2 :: 6174 // ~140ms
CHIME_ATK :: 220 // ~5ms attack
ZAP_N :: 5733 // ~130ms
ZAP_ATK :: 132 // ~3ms attack

// Amplitude envelope for one note: linear attack over <attack> samples, then a linear taper to 0 by the
// end of <total>. Keeps note edges click-free.
sfx_env :: proc(i, total, attack: int) -> f32 {
  a := f32(1)
  if attack > 0 && i < attack {
    a = f32(i) / f32(attack)
  }
  return a * f32(total - i) / f32(total)
}

// Wrap a mono i16 PCM buffer as a Sound. The buffer is intentionally leaked (see section note).
sfx_from_samples :: proc(buf: []i16) -> rl.Sound {
  wave := rl.Wave{frameCount = u32(len(buf)), sampleRate = SFX_SR, sampleSize = 16, channels = 1, data = raw_data(buf)}
  return rl.LoadSoundFromWave(wave)
}

// Soft coin-ish "+penya" chime: two short rising sine notes (A5 -> E6), ~230ms.
synth_penya_chime :: proc() -> rl.Sound {
  notes := [2]f32{880, 1318.5}
  durs := [2]int{CHIME_N1, CHIME_N2}
  buf := make([]i16, durs[0] + durs[1])
  off := 0
  for n in 0 ..< 2 {
    for i in 0 ..< durs[n] {
      t := f32(i) / f32(SFX_SR)
      s := math.sin(2 * math.PI * notes[n] * t) * sfx_env(i, durs[n], CHIME_ATK) * 0.18
      buf[off + i] = i16(s * 32767)
    }
    off += durs[n]
  }
  return sfx_from_samples(buf)
}

// Short descending "zap" on kill: a sine glide 1200 -> 200 Hz over ~130ms (phase-accumulated for a clean sweep).
synth_kill_zap :: proc() -> rl.Sound {
  buf := make([]i16, ZAP_N)
  phase := f32(0)
  for i in 0 ..< ZAP_N {
    freq := 1200 + (200 - 1200) * (f32(i) / f32(ZAP_N))
    phase += 2 * math.PI * freq / f32(SFX_SR)
    s := math.sin(phase) * sfx_env(i, ZAP_N, ZAP_ATK) * 0.17
    buf[i] = i16(s * 32767)
  }
  return sfx_from_samples(buf)
}

// One blip on the radar: a live mover with its world position, kind (for colour/size), the object
// pointer (to match the selected target), and - for players - a facing angle drawn like our own arrow.
Radar_Blip_Kind :: enum {
  Unclassified, // AI gate not configured - drawn like the old red mob dot
  Monster, // GetProp()->dwAI == AII_MONSTER
  Player, // species AI matches the local player's
  Other, // pet / egg / NPC
}
Radar_Blip :: struct {
  pos:          [3]f32,
  obj:          uintptr,
  kind:         Radar_Blip_Kind,
  angle:        f32,
  has_angle:    bool,
  reach_tested: bool, // did the reach pass evaluate this blip (monsters only, bounded set)
  reachable:    bool, // straight-line reach to it is clear (terrain + object OBBs) - else drawn faded
  name_match:   bool, // monster/unclass matches the active name filter (always true when no filter) - drives coloring
}

// A "Giant *" monster located by the throttled map-wide scan (radar_scan_giants). Cached across frames in
// cli_radar and redrawn every frame (rim-clamped when off the visible map), so a far hunt target is never
// lost even though it sits outside the normal vision-range mover window.
Radar_Giant :: struct {
  pos:  [3]f32,
  obj:  uintptr,
  name: string, // owned clone (freed when the cache is refilled / the radar closes)
}

// Per-obj mover-name cache for the radar's filter coloring (bounds the RPM cost of reading every nearby
// monster's name each frame). Lives for the radar window; names are cloned and freed on eviction / close.
Radar_Name_Entry :: struct {
  name: string, // owned clone
  at:   i64,    // last refresh (ns); re-read past RADAR_NAME_TTL_NS
}
RADAR_NAME_TTL_NS :: i64(750_000_000) // a mob's species name is stable; re-reading every ~0.75s is plenty

REACH_VIS_R :: f32(60) // only reach-test monsters within this of the player (relevance + per-frame cost bound)
REACH_VIS_MAX :: 48 // cap reach raycasts per frame (terrain raycast does per-cell reads; keep the loop smooth)

// Classify a mover for the radar from its species AI (GetProp()->dwAI). <propbase> is the resolved
// MoverProp array base (0 => gate off, everything is Unclassified). <player_ai> is the local player's
// own species AI, read live so player detection stays build-independent; 0xFFFFFFFF => don't flag
// players (couldn't resolve it, or it collided with a pet/egg/NPC/monster class - see cli_radar).
radar_classify :: proc(session: ^Session, propbase: uintptr, obj: uintptr, player_ai: u32) -> Radar_Blip_Kind {
  if propbase == 0 {
    return .Unclassified
  }
  ai := species_ai(session, propbase, obj)
  if ai == AII_MONSTER {
    return .Monster
  }
  if player_ai != 0xFFFFFFFF && ai == player_ai {
    return .Player
  }
  return .Other
}

// Radar dot colour + radius for a blip kind. Players are drawn a touch larger than mobs so they stand
// out; pets/eggs/NPCs are a muted grey; an unclassified mover falls back to the old red mob dot.
radar_blip_style :: proc(k: Radar_Blip_Kind) -> (col: rl.Color, radius: f32) {
  switch k {
  case .Player:
    return PLAYER_COL, 5
  case .Monster:
    return MOB_COL, 3
  case .Other:
    return OTHER_COL, 3
  case .Unclassified:
    return UNCLASS_COL, 3
  }
  return MOB_COL, 3
}

// Radar density-hue (display only, toggled by density_hue_on): map a monster's local pack size to a dot
// colour. A lone mob (pack 1) keeps the base red; denser packs rotate the hue toward green. The scale is
// ADAPTIVE - it normalises against the busier of a fixed floor (DENSITY_HUE_SAT_FLOOR) and the densest
// pack currently in view, so the full red->green range is used on both sparse and packed maps. With a
// fixed ceiling every dot on a real spawn map pinned to green (pack counts blow past ~8); stretching to
// the observed max keeps sparse/edge mobs red and reserves green for the genuine hotspots. Never touches
// the picker - it just visualises the same pack-size metric compute_densities feeds the auto-brain.
DENSITY_HUE_SAT_FLOOR :: 8 // on a sparse map you still need ~this many for green; denser maps stretch past it
radar_density_color :: proc(pack, maxpack: int) -> rl.Color {
  denom := max(f32(maxpack - 1), f32(DENSITY_HUE_SAT_FLOOR - 1)) // never < the floor, so green means dense
  t := clamp(f32(pack - 1) / denom, 0, 1) // 0 = lone/sparsest, 1 = densest in view
  return rl.ColorFromHSV(t * 120, 0.9, 0.95) // hue 0 (red) -> 120 (green)
}

// ===========================================================================
// Terrain hillshade relief (display-only radar backdrop). See the HILL_* constants for the design note.
// ===========================================================================

Hill_Cell :: struct {
  rect: rl.Rectangle,
  col:  rl.Color,
}

// Grey for one hillshade cell from its terrain slope (gx,gz = dHeight/dWorld). Directional-derivative
// shading: flat -> HILL_BASE; a slope rising toward the light brightens, away darkens. Colourless (a
// faint cool tint matching the background). zexag exaggerates the vertical relief; light_deg is the
// compass bearing (deg CW from north/+z) the light comes FROM. North-up projection (see radar_w2s), so
// +z is screen-up: at 0deg the light is from the top, keeping the default NW light in the upper-left.
radar_hillshade_color :: proc(gx, gz, zexag, light_deg: f32) -> rl.Color {
  th := math.to_radians(light_deg)
  lx := math.sin(th) // horizontal light dir (north-up screen): +z (north) at 0deg -> up, +x (east) at 90deg -> right
  lz := math.cos(th)
  s := -(gx * lx + gz * lz) * zexag // > 0 = the surface faces the light
  s = clamp(s, -1, 1)
  lum := clamp(f32(HILL_BASE) + f32(HILL_SPAN) * s, 0, 255)
  return rl.Color{u8(lum * 0.86), u8(lum * 0.93), u8(lum), 255}
}

// Load (and cache for this rebuild) a landscape tile's 129x129 heightmap floats in one bulk read.
// Returns nil for an unloaded/unreadable tile (cached as nil so we don't re-probe it every sample).
hill_tile_hmap :: proc(session: ^Session, arr: uintptr, tile: int, cache: ^map[int][]f32) -> []f32 {
  if h, ok := cache[tile]; ok {
    return h
  }
  handle := session.proc_info.handle
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  L := session.layout
  pland := read_ptr_at(handle, arr + uintptr(tile * ps), pt)
  if !is_heap_ptr(session, pland) {
    cache[tile] = nil
    return nil
  }
  hmap := read_ptr_at(handle, pland + uintptr(L.hmap_off), pt) // m_pHeightMap (float*)
  if !is_heap_ptr(session, hmap) {
    cache[tile] = nil
    return nil
  }
  buf := make([]f32, HMAP_STRIDE * HMAP_STRIDE, context.temp_allocator)
  n, ok := engine.read_into(handle, hmap, slice.to_bytes(buf))
  if !ok || n < uint(len(buf) * 4) {
    cache[tile] = nil
    return nil
  }
  cache[tile] = buf
  return buf
}

// Decoded terrain height at an integer heightmap corner (global grid coords gx,gz), resolving which
// tile owns it. ok=false = off-world / unloaded. The bulk-read building block for the bilinear sampler.
hill_corner :: proc(session: ^Session, arr: uintptr, land_width, land_height, gx, gz: int, cache: ^map[int][]f32) -> (h: f32, ok: bool) {
  if gx < 0 || gz < 0 || gx >= land_width * MAP_SIZE || gz >= land_height * MAP_SIZE {
    return 0, false
  }
  m_x := gx / MAP_SIZE
  m_z := gz / MAP_SIZE
  tile := m_x + m_z * land_width
  if tile < 0 || tile >= land_width * land_height {
    return 0, false
  }
  hm := hill_tile_hmap(session, arr, tile, cache)
  if hm == nil {
    return 0, false
  }
  cell := (gx - m_x * MAP_SIZE) + (gz - m_z * MAP_SIZE) * HMAP_STRIDE
  if cell < 0 || cell >= len(hm) {
    return 0, false
  }
  _, height := decode_hgt(hm[cell])
  return height, true
}

// BILINEAR decoded terrain height at world (wx,wz) via the cached tile heightmaps - blends the 4
// surrounding mpu-spaced corners so the relief is smooth between samples instead of stair-stepped.
// ok=false when the primary (containing) corner is off-world / unloaded; far corners clamp to it at
// the loaded-terrain edge.
hill_sample :: proc(session: ^Session, arr: uintptr, land_width, land_height: int, mpu, wx, wz: f32, cache: ^map[int][]f32) -> (h: f32, ok: bool) {
  ux := wx / mpu
  uz := wz / mpu
  if ux < 0 || uz < 0 || ux >= f32(land_width * MAP_SIZE) || uz >= f32(land_height * MAP_SIZE) {
    return 0, false
  }
  ix := int(ux)
  iz := int(uz)
  fx := ux - f32(ix)
  fz := uz - f32(iz)
  h00, ok00 := hill_corner(session, arr, land_width, land_height, ix, iz, cache)
  if !ok00 {
    return 0, false
  }
  h10, ok10 := hill_corner(session, arr, land_width, land_height, ix + 1, iz, cache)
  h01, ok01 := hill_corner(session, arr, land_width, land_height, ix, iz + 1, cache)
  h11, ok11 := hill_corner(session, arr, land_width, land_height, ix + 1, iz + 1, cache)
  if !ok10 {h10 = h00}
  if !ok01 {h01 = h00}
  if !ok11 {h11 = h00}
  a := h00 + (h10 - h00) * fx
  b := h01 + (h11 - h01) * fx
  return a + (b - a) * fz, true
}

// Build the hillshade cell list for the current view. Called in the radar's LOCKED phase (it reads game
// memory). Samples the visible world rect on a grid (>= one heightmap cell, coarsened when zoomed out),
// computes each cell's slope by central differences, and emits a precomputed screen rect + grey. Each
// visible tile's heightmap is bulk-read once into a temp cache, so a rebuild costs a handful of reads.
radar_gather_hillshade :: proc(session: ^Session, world: uintptr, cam: [2]f32, scale: f32, center: rl.Vector2, fw, fh, zexag, light_deg: f32, out: ^[dynamic]Hill_Cell) {
  clear(out)
  handle := session.proc_info.handle
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  L := session.layout
  if world == 0 || L.land_off == 0 || L.landwidth_off == 0 || L.hmap_off == 0 {
    return
  }
  lw := int(read_i32_at(handle, world + uintptr(L.landwidth_off)))
  lh := int(read_i32_at(handle, world + uintptr(L.landwidth_off + 4)))
  if lw <= 0 || lh <= 0 || lw > 256 || lh > 256 {
    return
  }
  arr := read_ptr_at(handle, world + uintptr(L.land_off), pt) // m_apLand (CLandscape**)
  if !is_heap_ptr(session, arr) {
    return
  }
  mpu := f32(world_mpu(session, world))

  // draw-cell world-size: keep cells ~HILL_CELL_PX on screen at EVERY zoom (the bilinear sampler below
  // fills in detail between the coarser mpu-spaced heightmap samples, so sub-mpu cells are meaningful -
  // this is what makes the relief smooth instead of stair-stepping to the 4-unit grid when zoomed in).
  d := f32(HILL_CELL_PX) / scale
  // visible world rect (scissor region is [0,0]..[fw-PANEL_W, fh]); pad one cell for edge gradients and
  // snap the origin to a multiple of d so cells don't shimmer as the view pans.
  vw := fw - PANEL_W
  c0 := radar_s2w(cam, scale, center, 0, 0)
  c1 := radar_s2w(cam, scale, center, vw, fh)
  minx := math.floor(min(c0[0], c1[0]) / d) * d - d
  minz := math.floor(min(c0[1], c1[1]) / d) * d - d
  maxx := max(c0[0], c1[0]) + d
  maxz := max(c0[1], c1[1]) + d
  cols := int((maxx - minx) / d) + 2
  rows := int((maxz - minz) / d) + 2
  // extreme zoom-out guard: coarsen d so the grid never exceeds HILL_MAX_DIM per side.
  if cols > HILL_MAX_DIM || rows > HILL_MAX_DIM {
    k := f32(max(cols, rows)) / f32(HILL_MAX_DIM)
    d *= k
    cols = int((maxx - minx) / d) + 2
    rows = int((maxz - minz) / d) + 2
  }
  // gradient stencil: at least one heightmap cell (mpu) wide so central differences straddle real
  // samples and the shading stays smooth - a sub-cell stencil would trace the bilinear grid's creases.
  gstep := max(d, mpu)

  tiles := make(map[int][]f32, 32, context.temp_allocator) // per-rebuild tile-heightmap cache
  half := d * 0.5
  for iz in 0 ..< rows {
    wz := minz + f32(iz) * d
    for ix in 0 ..< cols {
      wx := minx + f32(ix) * d
      hc, cok := hill_sample(session, arr, lw, lh, mpu, wx, wz, &tiles)
      if !cok {
        continue // no terrain here -> leave the background showing (reads as void/water)
      }
      hxp, ok1 := hill_sample(session, arr, lw, lh, mpu, wx + gstep, wz, &tiles)
      hxm, ok2 := hill_sample(session, arr, lw, lh, mpu, wx - gstep, wz, &tiles)
      hzp, ok3 := hill_sample(session, arr, lw, lh, mpu, wx, wz + gstep, &tiles)
      hzm, ok4 := hill_sample(session, arr, lw, lh, mpu, wx, wz - gstep, &tiles)
      if !ok1 {hxp = hc} // fall back to the centre height at the world edge (partial gradient)
      if !ok2 {hxm = hc}
      if !ok3 {hzp = hc}
      if !ok4 {hzm = hc}
      gx := (hxp - hxm) / (2 * gstep)
      gz := (hzp - hzm) / (2 * gstep)
      col := radar_hillshade_color(gx, gz, zexag, light_deg)
      p0 := radar_w2s(cam, scale, center, wx - half, wz - half)
      p1 := radar_w2s(cam, scale, center, wx + half, wz + half)
      // +1px on the far edges so adjacent cells overlap (no single-pixel seams between them). Build from
      // the min corner + abs size so the north-up projection's flipped z can't yield a negative-height
      // rect (raylib draws nothing for those - which is what blanked the whole relief).
      append(out, Hill_Cell{rl.Rectangle{min(p0.x, p1.x), min(p0.y, p1.y), abs(p1.x - p0.x) + 1, abs(p1.y - p0.y) + 1}, col})
    }
  }
}

// Resolve the MoverProp array base + the local player's own species AI, for radar classification.
// propbase = [base+propmover_rva] (0 when the AI gate isn't configured -> everything Unclassified).
// player_ai is the local player's GetProp()->dwAI, read live so other players (same AI) are flagged
// without a build-specific constant; forced to 0xFFFFFFFF (players not flagged) when it can't be read
// or would collide with a monster/pet/egg/NPC class (so those crowds can never be mislabelled players).
radar_prop_ctx :: proc(session: ^Session, player: uintptr) -> (propbase: uintptr, player_ai: u32) {
  player_ai = 0xFFFFFFFF
  if !prop_gate_ready(session) {
    return
  }
  handle := session.proc_info.handle
  pt := engine.Value_Type.U32
  if pb, ok := engine.read_value(handle, session.proc_info.base + session.layout.propmover_rva, pt); ok {
    propbase = uintptr(engine.value_as_u64(pt, pb))
  }
  if propbase == 0 || player == 0 {
    propbase = 0
    return
  }
  ai := species_ai(session, propbase, player)
  if ai != 0xFFFFFFFF && ai != AII_MONSTER && ai != AII_PET && ai != AII_EGG && ai != AII_NONE {
    player_ai = ai
  }
  return
}

// Reachability pass for the radar: flag which nearby monster blips are blocked (terrain grid + object
// OBBs) using the SAME compute_reach the target picker's gate consults, so a dot fades exactly when the
// picker would consider it unreachable. Bounded for the 30fps loop - only the nearest REACH_VIS_MAX
// monsters within REACH_VIS_R are tested (far mobs aren't actionable and the terrain raycast reads
// per-cell). Players/others are never tested. Runs under exec_mutex (reads game memory).
radar_reach_pass :: proc(session: ^Session, world: uintptr, ppos: [3]f32, mobs: []Radar_Blip) {
  tracy.ZoneN("Reach_Pass")
  if world == 0 {
    return
  }
  Reach_Idx :: struct {
    i: int,
    d: f32,
  }
  cand := make([dynamic]Reach_Idx, context.temp_allocator)
  for m, i in mobs {
    if m.kind != .Monster && m.kind != .Unclassified {
      continue
    }
    if !m.name_match {
      continue // filtered-out mob (not a target) - don't spend a raycast fading a dot we already dimmed
    }
    d := engine.dist_horizontal(m.pos, ppos)
    if d > REACH_VIS_R {
      continue
    }
    append(&cand, Reach_Idx{i, d})
  }
  slice.sort_by(cand[:], proc(a, b: Reach_Idx) -> bool {return a.d < b.d})
  n := min(len(cand), REACH_VIS_MAX)
  for k in 0 ..< n {
    m := &mobs[cand[k].i]
    res := compute_reach(session, world, ppos[0], ppos[1], ppos[2], m.pos[0], m.pos[2], allow_async = true)
    m.reach_tested = true
    m.reachable = res.status == .Clear
  }
}

// Radar editor tool. The three draw tools map 1:1 to Fence_Kind; Eraser deletes the shape under the cursor.
Radar_Tool :: enum {
  Circle,
  Rect,
  Polygon,
  Eraser,
}

// The handful of giants the game ships WITHOUT the "Giant" prefix. There's no cheap per-mover "is giant"
// flag to read, so - since it's only these few - we special-case them by name alongside the prefix test.
GIANT_NAME_EXCEPTIONS :: []string {
  "General Chimeradon",
  "General Bearnerky",
  "Great Chef Muffrin",
  "Queen Popcrank",
}

// True if a mover name marks a giant: either the "Giant" prefix, or one of the prefix-less exceptions
// above. Case-insensitive (the client's names are ASCII), matching name_has_prefix_fold.
is_giant_name :: proc(nm: string) -> bool {
  if name_has_prefix_fold(nm, "Giant") {
    return true
  }
  for ex in GIANT_NAME_EXCEPTIONS {
    if strings.equal_fold(nm, ex) {
      return true
    }
  }
  return false
}

// Case-insensitive prefix test (for the map-wide "Giant *" giant scan; the client's names are ASCII).
name_has_prefix_fold :: proc(s, prefix: string) -> bool {
  return len(s) >= len(prefix) && strings.equal_fold(s[:len(prefix)], prefix)
}

// TTL-cached mover-name read (see Radar_Name_Entry). Bounds the per-frame RPM cost of the filter coloring:
// a mob's name is stable, so we re-read it at most every RADAR_NAME_TTL_NS. Cloned names are owned by the
// cache and freed on eviction (here) and when the radar closes (radar_name_cache_free).
radar_name_cached :: proc(cache: ^map[uintptr]Radar_Name_Entry, session: ^Session, obj: uintptr, now: i64) -> (string, bool) {
  if e, ok := cache^[obj]; ok && now - e.at < RADAR_NAME_TTL_NS {
    return e.name, e.name != ""
  }
  nm, ok := read_mover_name(session, obj)
  if old, had := cache^[obj]; had && len(old.name) > 0 {
    delete(old.name) // replace the stale clone (only real clones are heap-owned)
  }
  clone: string // "" (a nil literal) for a miss - never a heap alloc, so teardown never frees a non-heap ptr
  if ok && len(nm) > 0 {
    clone = strings.clone(nm)
  }
  cache^[obj] = Radar_Name_Entry{name = clone, at = now}
  return clone, clone != ""
}

// Free every cloned name in a radar name cache and the map itself (radar-window teardown).
radar_name_cache_free :: proc(cache: ^map[uintptr]Radar_Name_Entry) {
  for _, e in cache {
    if len(e.name) > 0 {
      delete(e.name)
    }
  }
  delete(cache^)
}

// Gather live movers from the player's tile + neighbours' m_apObject[OT_MOVER] arrays, within `radius`
// of (px,pz). Camera-independent and cheap (movers per tile are few). Each is classified (monster /
// player / other) via its species AI: <propbase> is the resolved MoverProp array base (0 => everything
// Unclassified) and <player_ai> the local player's species AI (0xFFFFFFFF => don't flag players). The
// <player> object itself is skipped (it's drawn separately as the white arrow). Appends Radar_Blips.
radar_gather_movers :: proc(session: ^Session, world, player: uintptr, propbase: uintptr, player_ai: u32, px, pz, radius: f32, out: ^[dynamic]Radar_Blip, filter: []string, name_cache: ^map[uintptr]Radar_Name_Entry, now: i64) {
  tracy.ZoneN("Gather_Movers")
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  pt := engine.Value_Type.U32
  L := session.layout
  if L.landobj_off == 0 || L.land_off == 0 || L.landwidth_off == 0 {
    return
  }
  mpu := f32(world_mpu(session, world))
  land_width := read_i32_at(handle, world + uintptr(L.landwidth_off))
  land_height := read_i32_at(handle, world + uintptr(L.landwidth_off + 4))
  arr := read_ptr_at(handle, world + uintptr(L.land_off), pt)
  if !is_heap_ptr(session, arr) || land_width <= 0 || land_height <= 0 {
    return
  }
  r2 := radius * radius
  m_x := int(px / mpu) / MAP_SIZE
  m_z := int(pz / mpu) / MAP_SIZE
  for tz := m_z - 1; tz <= m_z + 1; tz += 1 {
    for tx := m_x - 1; tx <= m_x + 1; tx += 1 {
      if tx < 0 || tz < 0 || tx >= int(land_width) || tz >= int(land_height) {
        continue
      }
      pland := read_ptr_at(handle, arr + uintptr((tx + tz * int(land_width)) * session.ptr_size), pt)
      if !is_heap_ptr(session, pland) {
        continue
      }
      arrp := read_ptr_at(handle, pland + uintptr(L.landobj_off + OT_MOVER_IDX * 4), pt)
      if !is_heap_ptr(session, arrp) {
        continue
      }
      cnt := read_i32_at(handle, pland + uintptr(L.landobj_off + LANDOBJ_MAX_ARRAY * 4 + OT_MOVER_IDX * 4))
      if cnt <= 0 || cnt > 200000 {
        continue
      }
      ab := make([]byte, int(cnt) * 4, context.temp_allocator)
      rn, _ := engine.read_into(handle, arrp, ab)
      for k in 0 ..< int(rn) / 4 {
        obj := uintptr(rd_u32le(ab, k * 4))
        if obj < 0x10000 {
          continue
        }
        if obj == player {
          continue // our own object is drawn separately (the white facing arrow)
        }
        vt := read_ptr_at(handle, obj, pt)
        if vt < base || vt >= mod_end {
          continue // not a live CObj
        }
        pos, ok := engine.read_vec3(handle, obj + uintptr(L.pos_off))
        if !ok {
          continue
        }
        dx := pos[0] - px
        dz := pos[2] - pz
        if dx * dx + dz * dz <= r2 {
          kind := radar_classify(session, propbase, obj, player_ai)
          // Drop dead-but-not-despawned monsters immediately (currentHP <= 0) so a corpse's dot vanishes on
          // death instead of lingering through the despawn animation. Same death signal obj_is_selectable
          // uses; a failed HP read leaves it drawn. Only monsters/unclassified movers corpse this way.
          if (kind == .Monster || kind == .Unclassified) && L.hp_off != 0 {
            if hpv, hok := engine.read_value(handle, obj + uintptr(L.hp_off), .U32); hok {
              if i32(u32(engine.value_as_u64(.U32, hpv))) <= 0 {
                continue
              }
            }
          }
          blip := Radar_Blip{pos = pos, obj = obj, kind = kind, name_match = true}
          // Filter coloring: with an active name filter, a monster/unclassified mover whose name doesn't
          // match is drawn dimmed (not a target). No filter -> everything stays coloured (name_match true).
          if len(filter) > 0 && (kind == .Monster || kind == .Unclassified) {
            nm, nok := radar_name_cached(name_cache, session, obj, now)
            blip.name_match = nok && name_matches(nm, filter)
          }
          if blip.kind == .Player && L.angle_off != 0 { // draw other players' facing like our own
            if a, aok := read_f32_at(handle, obj + uintptr(L.angle_off)); aok {
              blip.angle = a
              blip.has_angle = true
            }
          }
          append(out, blip)
        }
      }
    }
  }
}

// Map-wide scan for "Giant *" monsters, refilling <out> (its old cloned names are freed first). Unlike
// radar_gather_movers (a 3x3 tile window bounded by the vision radius), this walks EVERY landscape tile so
// a giant that spawns far across a large area is still found - the target picker's full-memory scan can
// target such a giant, but the tile-window radar couldn't see it. Throttled by the caller (GIANT_SCAN_NS)
// since it reads a name per mover map-wide; giants are rare + slow, so a ~1.2s refresh is plenty. Corpses
// (HP<=0) are dropped. Runs under exec_mutex (reads game memory), like the gather.
radar_scan_giants :: proc(session: ^Session, world, player: uintptr, out: ^[dynamic]Radar_Giant) {
  tracy.ZoneN("Scan_Giants")
  for g in out {
    delete(g.name)
  }
  clear(out)
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  pt := engine.Value_Type.U32
  L := session.layout
  if L.landobj_off == 0 || L.land_off == 0 || L.landwidth_off == 0 {
    return
  }
  land_width := read_i32_at(handle, world + uintptr(L.landwidth_off))
  land_height := read_i32_at(handle, world + uintptr(L.landwidth_off + 4))
  arr := read_ptr_at(handle, world + uintptr(L.land_off), pt)
  if !is_heap_ptr(session, arr) || land_width <= 0 || land_height <= 0 {
    return
  }
  if int(land_width) * int(land_height) > 4096 {
    return // sanity clamp: a corrupt dimension would spin the tile loop forever
  }
  for tz in 0 ..< int(land_height) {
    for tx in 0 ..< int(land_width) {
      pland := read_ptr_at(handle, arr + uintptr((tx + tz * int(land_width)) * session.ptr_size), pt)
      if !is_heap_ptr(session, pland) {
        continue
      }
      arrp := read_ptr_at(handle, pland + uintptr(L.landobj_off + OT_MOVER_IDX * 4), pt)
      if !is_heap_ptr(session, arrp) {
        continue
      }
      cnt := read_i32_at(handle, pland + uintptr(L.landobj_off + LANDOBJ_MAX_ARRAY * 4 + OT_MOVER_IDX * 4))
      if cnt <= 0 || cnt > 200000 {
        continue
      }
      ab := make([]byte, int(cnt) * 4, context.temp_allocator)
      rn, _ := engine.read_into(handle, arrp, ab)
      for k in 0 ..< int(rn) / 4 {
        obj := uintptr(rd_u32le(ab, k * 4))
        if obj < 0x10000 || obj == player {
          continue
        }
        vt := read_ptr_at(handle, obj, pt)
        if vt < base || vt >= mod_end {
          continue // not a live CObj
        }
        nm, nok := read_mover_name(session, obj)
        if !nok || !is_giant_name(nm) {
          continue
        }
        if L.hp_off != 0 { // drop corpses (HP<=0), like the gather
          if hpv, hok := engine.read_value(handle, obj + uintptr(L.hp_off), .U32); hok {
            if i32(u32(engine.value_as_u64(.U32, hpv))) <= 0 {
              continue
            }
          }
        }
        pos, pok := engine.read_vec3(handle, obj + uintptr(L.pos_off))
        if !pok {
          continue
        }
        append(out, Radar_Giant{pos = pos, obj = obj, name = strings.clone(nm)})
      }
    }
  }
}

// ===========================================================================
// World <-> screen (world-anchored, pannable, zoomable). cam = the world (x,z) at the screen center;
// scale = pixels per world unit; center = screen midpoint.
// ===========================================================================

// NORTH-UP projection: world +z (north) maps to screen-UP (negative y). The game's yaw is left-handed
// (Obj.cpp: RotationY(-m_fAngle)), so a plain +z-down mapping would mirror the world and reverse the
// on-screen turn direction (clockwise in-game -> counter-clockwise on the radar). Negating z here makes
// the radar a true top-down map: turning clockwise in-game turns the facing arrow clockwise on-screen.
radar_w2s :: proc(cam: [2]f32, scale: f32, center: rl.Vector2, wx, wz: f32) -> rl.Vector2 {
  return {center.x + (wx - cam[0]) * scale, center.y - (wz - cam[1]) * scale}
}
radar_s2w :: proc(cam: [2]f32, scale: f32, center: rl.Vector2, sx, sy: f32) -> [2]f32 {
  return {cam[0] + (sx - center.x) / scale, cam[1] - (sy - center.y) / scale}
}
// Rotate a 2D world (x,z) vector by a_rad. Result is fed back through radar_w2s (which handles the z-flip),
// so this stays a plain world-space rotation.
radar_rot2 :: proc(v: [2]f32, a_rad: f32) -> [2]f32 {
  c := math.cos(a_rad)
  s := math.sin(a_rad)
  return {v[0] * c - v[1] * s, v[0] * s + v[1] * c}
}

// Draw a facing arrow at screen point <sp> for m_fAngle <a_deg> (on-screen dir = angle+180, same
// convention as the tdbg HTML). <length> = tip distance, <half> = base half-width. Shared by the local
// player (large, white) and other-player blips (small, azure).
radar_draw_arrow :: proc(sp: rl.Vector2, a_deg, length, half: f32, col: rl.Color) {
  theta := math.to_radians(a_deg + 180)
  fx := -math.sin(theta) // screen-x component
  fz := -math.cos(theta) // screen-y component (north-up projection: +world z -> screen-up)
  tip := rl.Vector2{sp.x + fx * length, sp.y + fz * length}
  bl := rl.Vector2{sp.x + fz * half, sp.y - fx * half} // base corners (perp to the heading)
  br := rl.Vector2{sp.x - fz * half, sp.y + fx * half}
  rl.DrawTriangle(tip, bl, br, col) // fill (winding may cull; outline below always shows)
  rl.DrawTriangleLines(tip, bl, br, col)
}

// Draw a small speaker glyph centred at (cx,cy): a back plate + a cone flaring right. When <muted> a red
// slash crosses it; otherwise two sound-wave arcs radiate. Primitive-only (no glyph font dependency) so
// it renders identically everywhere. <col> tints the speaker body; the waves reuse it.
radar_draw_speaker :: proc(cx, cy: f32, muted: bool, col: rl.Color) {
  rl.DrawRectangleRec({cx - 9, cy - 3, 5, 6}, col) // back plate (the magnet)
  // cone: a trapezoid flaring to the right (narrow at the plate, tall at the mouth). radar_fill_quad
  // fixes the winding so raylib's back-face cull never drops the fill.
  radar_fill_quad({cx - 4, cy - 2}, {cx + 3, cy - 7}, {cx + 3, cy + 7}, {cx - 4, cy + 2}, col)
  if muted {
    red := rl.Color{231, 76, 60, 255}
    rl.DrawLineEx({cx + 6, cy - 6}, {cx + 15, cy + 6}, 2, red)
    rl.DrawLineEx({cx + 15, cy - 6}, {cx + 6, cy + 6}, 2, red)
  } else {
    wc := rl.Vector2{cx + 3, cy}
    rl.DrawRing(wc, 7, 8.5, -42, 42, 10, col) // inner sound wave
    rl.DrawRing(wc, 10.5, 12, -42, 42, 10, col) // outer sound wave
  }
}

// Draw a small bag/pouch glyph centred at (cx,cy): a handle arc over a rounded body. Primitive-only (no
// glyph font dependency) so it renders identically everywhere. <col> tints the whole bag. Used by the
// bottom-left inventory (free/total) readout.
radar_draw_bag :: proc(cx, cy: f32, col: rl.Color) {
  rl.DrawRing({cx, cy - 2}, 2.6, 4, -150, -30, 12, col) // handle over the top (top = -90 deg, y is down)
  rl.DrawRectangleRounded({cx - 6, cy - 2, 12, 10}, 0.4, 6, col) // pouch body
}

// A small coin glyph for the bottom-left penya readout (same anchor/scale as radar_draw_bag).
radar_draw_coin :: proc(cx, cy: f32, col: rl.Color) {
  rl.DrawCircle(i32(cx), i32(cy), 6, col)
  rl.DrawCircleLines(i32(cx), i32(cy), 6, rl.Color{40, 34, 14, 255}) // thin dark rim
  rl.DrawRectangleRounded({cx - 1, cy - 3, 2, 6}, 0.5, 4, rl.Color{60, 48, 16, 210}) // faint coin mark
}

// A loud throbbing bar behind a bottom-left readout (full bag / penya near the cap) so the alert is
// impossible to miss. <cy> is the readout's vertical center, <p> the 0..1 pulse phase, <rgb> the alert hue.
radar_alert_bg :: proc(x, cy, w: f32, p: f32, rgb: [3]u8) {
  a := u8(45 + 170 * p) // fill throbs from faint to near-solid
  rl.DrawRectangleRounded({x, cy - 14, w, 28}, 0.45, 6, rl.Color{rgb.r, rgb.g, rgb.b, a})
  rl.DrawRectangleRoundedLines({x, cy - 14, w, 28}, 0.45, 6, rl.Color{rgb.r, rgb.g, rgb.b, 255})
}

// Fence editor draw-tag <-> (include, avoid, label). Tab cycles 0->1->2 (include+ / exclude- / avoid!).
radar_fence_tag :: proc(i: int) -> (include, avoid: bool, label: cstring) {
  switch i {
  case 1:
    return false, false, "-"
  case 2:
    return false, true, "!"
  }
  return true, false, "+"
}

// Screen half-edge vector for a unit box axis' xz projection, clamped to a min pixel length so tiny
// props stay visible. <dir> = axis (x,z) - unit for the yaw-only props Flyff places; <half> = ext*scale
// pixels; <min_half> = floor so a small rock never shrinks to a dot.
radar_axis_half :: proc(dir: [2]f32, half, min_half: f32) -> [2]f32 {
  l := math.sqrt(dir[0] * dir[0] + dir[1] * dir[1])
  h := max(half, min_half)
  if l < 1e-6 { // axis has no xz footprint (box points straight up) - draw an axis-aligned stub
    return {h, 0}
  }
  return {dir[0] / l * h, dir[1] / l * h}
}

// Filled convex quad from 4 ring-ordered screen corners. raylib culls back faces (CCW in its y-down
// space), so we check the winding once and reverse the ring if needed - otherwise a translucent fill
// silently drops out for half the box orientations.
radar_fill_quad :: proc(a, b, c, d: rl.Vector2, col: rl.Color) {
  bb, dd := b, d
  cr := (bb.x - a.x) * (c.y - a.y) - (bb.y - a.y) * (c.x - a.x)
  if cr > 0 { // wrong winding for raylib - reverse the ring (a,b,c,d -> a,d,c,b)
    bb, dd = dd, bb
  }
  rl.DrawTriangle(a, bb, c, col)
  rl.DrawTriangle(a, c, dd, col)
}

// Closed 4-segment outline through the ring-ordered corners.
radar_line_loop :: proc(a, b, c, d: rl.Vector2, th: f32, col: rl.Color) {
  rl.DrawLineEx(a, b, th, col)
  rl.DrawLineEx(b, c, th, col)
  rl.DrawLineEx(c, d, th, col)
  rl.DrawLineEx(d, a, th, col)
}

// Draw one placed-object OBB as its ORIENTED xz footprint (props are yawed about Y, so rotate the box
// by its own axes instead of drawing an AABB). Blockers get a translucent fill + bright outline;
// walk-through props (GMT_ERROR) get a faint outline only. axis[1] is world-up and irrelevant top-down.
radar_draw_obb :: proc(o: Obb, cam: [2]f32, scale: f32, center: rl.Vector2) {
  u := radar_axis_half({o.axis[0][0], o.axis[0][2]}, o.ext[0] * scale, 2.5)
  v := radar_axis_half({o.axis[2][0], o.axis[2][2]}, o.ext[2] * scale, 2.5)
  u[1] = -u[1] // north-up projection: world +z maps to screen-up, so flip the extent vectors' z too
  v[1] = -v[1]
  p := radar_w2s(cam, scale, center, o.center[0], o.center[2])
  c0 := rl.Vector2{p.x - u[0] - v[0], p.y - u[1] - v[1]}
  c1 := rl.Vector2{p.x + u[0] - v[0], p.y + u[1] - v[1]}
  c2 := rl.Vector2{p.x + u[0] + v[0], p.y + u[1] + v[1]}
  c3 := rl.Vector2{p.x - u[0] + v[0], p.y - u[1] + v[1]}
  if o.decorative {
    radar_line_loop(c0, c1, c2, c3, 1, rl.Color{130, 140, 155, 95}) // walk-through -> outline only
  } else {
    radar_fill_quad(c0, c1, c2, c3, rl.Color{155, 89, 182, 70}) // blocker fill
    radar_line_loop(c0, c1, c2, c3, 1.5, rl.Color{175, 115, 205, 205}) // + bright outline
  }
}

// Draw one committed fence shape (green for +, orange for -). Polygons are outlined (fill needs
// triangulation and the mob shading conveys membership anyway).
radar_draw_shape :: proc(s: Fence_Shape, cam: [2]f32, scale: f32, center: rl.Vector2) {
  line := fence_shape_color(s.include, s.avoid)
  fill := line
  fill.a = 40
  switch s.kind {
  case .Circle:
    c := radar_w2s(cam, scale, center, s.cx, s.cz)
    rl.DrawCircleV(c, s.r * scale, fill)
    rl.DrawCircleLinesV(c, s.r * scale, line)
  case .Rect:
    p0 := radar_w2s(cam, scale, center, s.minx, s.minz)
    p1 := radar_w2s(cam, scale, center, s.maxx, s.maxz)
    rc := rl.Rectangle{min(p0.x, p1.x), min(p0.y, p1.y), abs(p1.x - p0.x), abs(p1.y - p0.y)} // min corner + abs size (z is flipped, see radar_w2s)
    rl.DrawRectangleRec(rc, fill)
    rl.DrawRectangleLinesEx(rc, 1.5, line)
  case .Polygon:
    n := len(s.verts)
    for i in 0 ..< n {
      a := radar_w2s(cam, scale, center, s.verts[i][0], s.verts[i][1])
      b := radar_w2s(cam, scale, center, s.verts[(i + 1) % n][0], s.verts[(i + 1) % n][1])
      rl.DrawLineEx(a, b, 1.5, line)
    }
  }
}

// Eraser hover: overlay the shape the cursor is over in red so you can see what a click will delete.
radar_draw_erase_hover :: proc(s: Fence_Shape, cam: [2]f32, scale: f32, center: rl.Vector2) {
  red := rl.Color{231, 76, 60, 255}
  fill := rl.Color{231, 76, 60, 70}
  switch s.kind {
  case .Circle:
    c := radar_w2s(cam, scale, center, s.cx, s.cz)
    rl.DrawCircleV(c, s.r * scale, fill)
    rl.DrawCircleLinesV(c, s.r * scale, red)
  case .Rect:
    p0 := radar_w2s(cam, scale, center, s.minx, s.minz)
    p1 := radar_w2s(cam, scale, center, s.maxx, s.maxz)
    rc := rl.Rectangle{min(p0.x, p1.x), min(p0.y, p1.y), abs(p1.x - p0.x), abs(p1.y - p0.y)} // min corner + abs size (z is flipped, see radar_w2s)
    rl.DrawRectangleRec(rc, fill)
    rl.DrawRectangleLinesEx(rc, 2, red)
  case .Polygon:
    n := len(s.verts)
    for i in 0 ..< n {
      a := radar_w2s(cam, scale, center, s.verts[i][0], s.verts[i][1])
      b := radar_w2s(cam, scale, center, s.verts[(i + 1) % n][0], s.verts[(i + 1) % n][1])
      rl.DrawLineEx(a, b, 2.5, red)
    }
  }
}

// Draw the render camera: eye marker + view axis + horizontal frustum cone (out to the cull far plane).
// The far plane (512) is large, so the cone edges usually run off-screen - that's the real cull region.
radar_draw_camera :: proc(eye, lookat: [3]f32, cam: [2]f32, scale: f32, center: rl.Vector2) {
  es := radar_w2s(cam, scale, center, eye[0], eye[2])
  fx := lookat[0] - eye[0]
  fz := lookat[2] - eye[2]
  flen := math.sqrt(fx * fx + fz * fz)
  if flen > 0.001 {
    fx /= flen
    fz /= flen
    half := math.to_radians(FRUSTUM_HFOV_DEG * 0.5)
    l := radar_rot2({fx, fz}, half)
    r := radar_rot2({fx, fz}, -half)
    fl := radar_w2s(cam, scale, center, eye[0] + l[0] * FRUSTUM_FAR, eye[2] + l[1] * FRUSTUM_FAR)
    fr := radar_w2s(cam, scale, center, eye[0] + r[0] * FRUSTUM_FAR, eye[2] + r[1] * FRUSTUM_FAR)
    fill := CAM_COL
    fill.a = 20
    rl.DrawTriangle(es, fl, fr, fill) // faint fill (winding may cull; the edges below always show)
    edge := CAM_COL
    edge.a = 130
    rl.DrawLineV(es, fl, edge)
    rl.DrawLineV(es, fr, edge)
    ls := radar_w2s(cam, scale, center, lookat[0], lookat[2])
    rl.DrawLineV(es, ls, rl.Color{CAM_COL.r, CAM_COL.g, CAM_COL.b, 90}) // view axis toward the aim point
  }
  rl.DrawCircleV(es, 4, CAM_COL)
  rl.DrawCircleLinesV(es, 6, CAM_COL)
}

// ===========================================================================
// PANEL - the Phase 3 raygui control surface. A fixed strip on the right edge of the radar window whose
// widgets drive the existing REPL commands, so the tool becomes UI-controlled without losing the headless
// REPL. All widgets draw in cli_radar's exec_mutex-UNLOCKED section, so any action that touches session
// automation is DEFERRED: it appends a command string to Panel_State.pending during the draw, and the
// loop drains it through exec_line right after re-locking the mutex (matching REPL discipline). Radar-local
// view bools (edit/show_cam/show_reach/cam) are single-threaded stack locals and mutate directly. The
// panel READS setup_groups/optional_pins/auto_* directly, so it never drifts from `status`/`auto`.
// ===========================================================================

PANEL_W :: f32(280) // fixed right-side control panel; the radar map keeps the left region
OPT_PAD :: f32(14) // uniform inner padding for the Options modal - every element sits within [ox+PAD, ox+ow-PAD]

PANEL_BG :: rl.Color{20, 26, 34, 255} // opaque panel background (over the right strip)
PANEL_SEP :: rl.Color{40, 50, 62, 255} // section divider / panel edge line
PANEL_HDR :: rl.Color{200, 210, 222, 255} // section header text
PANEL_TXT :: rl.Color{198, 206, 216, 255} // body label text
PANEL_DIM :: rl.Color{132, 142, 154, 255} // secondary / hint text
DOT_OK :: rl.Color{46, 204, 113, 255} // status light: pinned (green)
DOT_REQ :: rl.Color{231, 76, 60, 255} // status light: required + missing (red)
DOT_OPT :: rl.Color{241, 196, 15, 255} // status light: optional + missing (yellow)
CHIP_BG :: rl.Color{52, 73, 94, 255} // selected mob-name pill

// raygui's built-in theme is a low-contrast light-grey scheme; its DISABLED state (light-grey text on a
// near-white base) reads as unreadable "white text on white background" - and the WHOLE panel renders in
// that state whenever it draws while gui-locked (we GuiLock() the panel behind the Setup modal). Applied
// once at window init, this overrides every control state to a dark, high-contrast look so text stays
// legible in NORMAL/FOCUSED/PRESSED/DISABLED alike, and bumps the tiny default font. Colors are packed
// 0xRRGGBBAA as raygui expects. See cli_radar's per-frame GuiUnlock guard for the lock-leak half of the fix.
gui_rgba :: proc(c: rl.Color) -> i32 {
  return i32(u32(c.r) << 24 | u32(c.g) << 16 | u32(c.b) << 8 | u32(c.a))
}

radar_apply_theme :: proc() {
  // THE button-label fix: raygui keeps its OWN font (guiFont), separate from raylib's default. Until it's
  // initialised it's a zero Font (texture id 0) that renders NOTHING - which is why every GuiButton label
  // was blank while our rl.DrawText panel text drew fine. It was never a colour/contrast problem (that's
  // why darkening the button backgrounds didn't help). GuiLoadStyleDefault initialises guiFont (=
  // GetFontDefault) plus baseline props (text alignment / border width / padding); we override the colours
  // + text size below. GuiSetFont is belt-and-suspenders for raygui builds that don't set the font there.
  rl.GuiLoadStyleDefault()
  rl.GuiSetFont(rl.GetFontDefault())
  set :: proc(prop: rl.GuiControlProperty, col: rl.Color) {
    rl.GuiSetStyle(.DEFAULT, i32(prop), gui_rgba(col)) // DEFAULT base props propagate to every control
  }
  // global: larger, more legible text + dark surfaces for GuiPanel background / dividers
  rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SIZE), 14)
  rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.TEXT_SPACING), 1)
  rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.BACKGROUND_COLOR), gui_rgba(rl.Color{20, 26, 34, 255}))
  rl.GuiSetStyle(.DEFAULT, i32(rl.GuiDefaultProperty.LINE_COLOR), gui_rgba(rl.Color{48, 60, 74, 255}))
  // NORMAL - slate button on the dark panel, near-white label (high contrast)
  set(.BORDER_COLOR_NORMAL, rl.Color{64, 80, 98, 255})
  set(.BASE_COLOR_NORMAL, rl.Color{38, 48, 62, 255})
  set(.TEXT_COLOR_NORMAL, rl.Color{206, 214, 224, 255})
  // FOCUSED (hover) - lighter fill, blue-accent border, brighter text
  set(.BORDER_COLOR_FOCUSED, rl.Color{92, 150, 210, 255})
  set(.BASE_COLOR_FOCUSED, rl.Color{54, 72, 94, 255})
  set(.TEXT_COLOR_FOCUSED, rl.Color{236, 242, 250, 255})
  // PRESSED - bright accent
  set(.BORDER_COLOR_PRESSED, rl.Color{120, 180, 235, 255})
  set(.BASE_COLOR_PRESSED, rl.Color{70, 104, 146, 255})
  set(.TEXT_COLOR_PRESSED, rl.Color{255, 255, 255, 255})
  // DISABLED - clearly dimmed but STILL readable (never near-white on near-white)
  set(.BORDER_COLOR_DISABLED, rl.Color{44, 54, 66, 255})
  set(.BASE_COLOR_DISABLED, rl.Color{28, 34, 42, 255})
  set(.TEXT_COLOR_DISABLED, rl.Color{110, 122, 136, 255})
}

// Full Flyff monster roster offered in the mob-search suggestions, MERGED (deduped, case-insensitive)
// with the live nearby monster names each frame (see the panel snapshot). Purely a convenience corpus;
// a typed name that isn't listed can still be added as a custom chip. Sourced from the Flyff wiki's
// "Complete Monster list" (flyff.fandom.com/wiki/Complete_Monster_list) - regenerate from there on updates.
AUTO_MOB_SUGGESTIONS :: []string {
  "(Anguished Soul) Mara", "(Deathbringer) Kheldor", "(Demonic Soul) Hel", "(General) Razgul", "(God of Death) Ankou", "(Perverted Soul) Morrigan",
  "(Tormented Soul) Nergal", "(Twisted Soul) Orcus", "(Violent Soul) Ghed", "Abraxas", "Aibatt", "Air Marshall Spiketail",
  "Ant Turtle", "Antiquery", "Araknoid", "Arc Master of the Violet Magician Troupe", "Asmodan", "Asterius",
  "Asuras", "Atrox", "Augu", "Axe-Jaw Ant", "Babari", "Bang",
  "Basque", "Battle Toadrin", "Bearnerky", "Beast King Khan", "Beast Overlord Khan", "Big Muscle",
  "Blackweb Shade", "Blighted Gryphon", "Blood Trillipy", "Bloody Mary", "Blue Meteonyker", "Blue Roach",
  "Blue Roach Queen", "Boo", "Boss Cardpuppet", "Brigadier General Crumple", "Bucrow", "Burudeng",
  "Cannibal Mammoth", "Cardpuppet", "Carrierbomb", "Catsy", "Chaner", "Chef Muffrin",
  "Chief Keokuk", "Chimeradon", "Clocks", "Clockworks", "Clockworks Butler", "Club-tailed Reptilion",
  "Colonel Club-tailed Reptilion", "Crane Machinery", "Creper", "Cursed Axe-Jaw Ant", "Cursed Giant Maul Rat", "Cursed Giant Scorpede",
  "Cursed Maul Rat", "Cursed Razor Axe-Jaw Ant", "Cursed Scorpede", "Cyclops X", "Dantalian", "Demian",
  "Dire Razor", "Dorian", "Doridoma", "Drakul the Diabolic", "Dread Drakul the Diabolic", "Dread Lykanos the Malevolent",
  "Dreadful Rangda", "Driller", "Dumb Bull", "Dump", "Elderguard", "Elite Keakoon Guard",
  "Elite Keakoon Guard Leader", "Elite Keakoon Worker", "Elite Keakoon Worker Leader", "Elite Tanuki Enforcer", "Elite Tanuki Protector", "Emeraldmantis",
  "Fallen Necromancer", "Fefern", "Female Zombie", "Flbyrigen", "Flybat", "Forsaken Banshee",
  "GM Cromiell", "Gangard", "Gannessa", "Garbagepider", "General Bearnerky", "General Chimeradon",
  "General Glyphaxz", "Ghost of the Forgotten King", "Ghost of the Forgotten Prince", "Giant Abraxas", "Giant Aibatt", "Giant Antiquery",
  "Giant Araknoid", "Giant Asterius", "Giant Asuras", "Giant Bang", "Giant Basque", "Giant Battle Toadrin",
  "Giant Boo", "Giant Bucrow", "Giant Burudeng", "Giant Carrierbomb", "Giant Catsy", "Giant Crane Machinery",
  "Giant Dantalian", "Giant Demian", "Giant Doridoma", "Giant Driller", "Giant Dumb Bull", "Giant Dump",
  "Giant Elderguard", "Giant Fefern", "Giant Flbyrigen", "Giant Flybat", "Giant Gannessa", "Giant Garbagepider",
  "Giant Giggle Box", "Giant Glaphan", "Giant Gongury", "Giant Greemong", "Giant Grrr", "Giant Gullah",
  "Giant Hague", "Giant Harpy", "Giant Hobo", "Giant Hoppre", "Giant Iren", "Giant Jack The Hammer",
  "Giant Kern", "Giant Lawolf", "Giant Leyena", "Giant Luia", "Giant Maul Rat", "Giant Mia",
  "Giant Mothbee", "Giant Mr Pumpkin", "Giant Mushpang", "Giant Mushpoie", "Giant Nautrepy", "Giant Nuctuvehicle",
  "Giant Nutty Wheel", "Giant Nyangnyang", "Giant Peakyturtle", "Giant Pukepuke", "Giant Red Mantis", "Giant Risem",
  "Giant Rock Muscle", "Giant Rockepeller", "Giant Scorpede", "Giant Scorpicon", "Giant Shuhamma", "Giant Steamwalker",
  "Giant Steel Knight", "Giant Syliaca", "Giant Tengu", "Giant Tombstone Bearer", "Giant Totemia", "Giant Trangfoma",
  "Giant Volt", "Giant Wagsaac", "Giant Watangka", "Giant Wheelem", "Giant Zombiger", "Giantmage Prankster",
  "Giggle Box", "Glaphan", "Gobbler", "Gongury", "Great Abraxas", "Great Asterius",
  "Great Asuras", "Great Catsy", "Great Chef Muffrin", "Great Dantalian", "Great Gannessa", "Great Gullah",
  "Great Hague", "Great Harpy", "Great Tengu", "Great White Bolo", "Greemong", "Green Meteonyker",
  "Green Trillipy", "Grrr", "Grumble Mauler", "Guan Yu Heavyblade", "Gullah", "Hadeseor",
  "Hague", "Hammer Kick", "Harpy", "Hazard Blood Trillipy", "Hazard Green Trillipy", "Hazard Violet Trillipy",
  "Hellhound", "Hobo", "Hoiren", "Hoppre", "Horrible Rangda", "Hundur Sharpfoot",
  "Hunter X", "Idol of Blighted Gryphon", "Idol of Fallen Necromancer", "Idol of Forsaken Banshee", "Idol of Scythe Protector", "Idol of Vile Flayer",
  "Immovable Crag", "Iren", "Ivillis Black Otem", "Ivillis Boxter", "Ivillis Crasher", "Ivillis Dandysher",
  "Ivillis Destroyer", "Ivillis Guardian", "Ivillis Leanes", "Ivillis Mushellizer", "Ivillis Poisoner", "Ivillis Puppet",
  "Ivillis Quaker", "Ivillis Red Otem", "Ivillis Thief", "Ivillis Wrecker", "Jack The Hammer", "Kanonicus",
  "Keakoon Guard", "Keakoon Guard Leader", "Keakoon Worker", "Keakoon Worker Leader", "Kern", "Kidler",
  "Kingster", "Kraken", "Krrr", "Kynsy", "Kyouchish", "Lawolf",
  "Leyena", "Lieutenant General Scythoid", "Lord Bang", "Lord Bang Hanoyan", "Lord Clockworks Alpha", "Luia",
  "Lykanos the Malevolent", "Mage Redcloud", "Male Zombie", "Mammoth", "Master Demian", "Master Muffrin",
  "Maul Rat", "Meral", "Meteonyker", "Mia", "Mocomochi", "Monument of Death",
  "Mothbee", "Mr Pumpkin", "Mushmoot", "Mushpang", "Mushpoie", "Mutant Augu",
  "Mutant Bang", "Mutant Fefern", "Mutant Giant 2nd Class Fefern", "Mutant Giant Bang King", "Mutant Giant Nyangnyang", "Mutant Keakoon Guard",
  "Mutant Keakoon Guard Leader", "Mutant Keakoon Worker", "Mutant Keakoon Worker Leader", "Mutant Nyangnyang", "Mutant Yetti", "Mythic Prismatic Cobra",
  "Mythic Twinstrike Cobra", "Mythic Wildwood Stalker", "Naga", "Nautrepy", "Nuctuvehicle", "Nutty Wheel",
  "Nyangnyang", "Nyx", "Okean", "Organigor", "Peakyturtle", "Pink Roach",
  "Pink Roach Queen", "Popcrank", "Prankster", "Prismatic Cobra", "Pukepuke", "Queen Popcrank",
  "R. DeFeo", "Rampaging Dumb Bull", "Rangda", "Razor Axe-Jaw Ant", "Red Bang", "Red Mantis",
  "Red Meteonyker", "Ren", "Risem", "Risen Assassin", "Risen Gladiator", "Risen Mage",
  "Risen Pikeman", "Risen Warrior", "Rock Muscle", "Rockepeller", "Rubo", "Sakai",
  "Samoset", "Scorpede", "Scorpicon", "Scythe Protector", "Seido", "Serus Uriel",
  "Shacalpion", "Shadowy Wildwood Shaman", "Shuhamma", "Shuraiture", "Sisif", "Small Mushpoie",
  "Spotted Bolo", "Steamwalker", "Steel Knight", "Syliaca", "Taiaha", "Tanuki Enforcer",
  "Tanuki Protector", "Tengu", "Tombstone Bearer", "Totem", "Totemia", "Trangfoma",
  "Troglodon Warlord", "Troglodon Warrior", "Twinstrike Cobra", "Uncanny Rangda", "Venel Guardian", "Vice Veduque",
  "Vile Flayer", "Vile Thorn", "Violet Magician Troupe", "Violet Trillipy", "Volt", "Wagsaac",
  "Watangka", "Wheelem", "Wildwood Shaman", "Wildwood Stalker", "Worm Veduque", "Yetti",
  "Zombiger", "Mortom", "Captain Catsy", "Captain Harpy"
}

// Per-window widget state for the control panel. A LOCAL in cli_radar (like poly_wip), NOT a package
// global - a shared global would be the forbidden Radar struct. Holds only UI buffers + the deferred
// command queue; nothing here is read by the watcher. `pending`/`selected` strings are HEAP-owned (they
// must outlive the frame's temp free_all, which runs before the drain) and are freed on drain / close.
Panel_State :: struct {
  pending:     [dynamic]string, // deferred session commands, drained under exec_mutex after each frame

  setup_open:  bool, // the Setup modal is up
  name_buf:    [64]u8, // character-name textbox (setup modal)
  name_edit:   bool,
  hp_buf:      [16]u8, // optional-hp textbox (setup modal)
  hp_edit:     bool,
  penya_buf:   [24]u8, // optional-penya textbox (setup modal) -> runs findpenya to pin penya_off
  penya_edit:  bool,

  search_buf:  [64]u8, // mob-search textbox (auto section)
  search_edit: bool,
  selected:    [dynamic]string, // chosen mob-name chips (heap-owned)

  ar_slider:   f32, // attack_range slider value (seeded from the layout, live while dragging)
  ar_dragging: bool, // slider held -> defer the flyff.cfg persist until release
  ar_seeded:   bool, // one-time seed of ar_slider from the live attack_range

  rr_slider:   f32, // radar-range (vision) slider value; same seed/drag/persist dance as ar_slider
  rr_dragging: bool, // slider held -> defer the flyff.cfg persist until release
  rr_seeded:   bool, // one-time seed of rr_slider from the live radar_range

  tr_slider:   f32, // trail length slider value; same seed/drag/persist dance as rr_slider
  tr_dragging: bool,
  tr_seeded:   bool,

  tf_slider:   f32, // trail fade-exponent slider value; same dance
  tf_dragging: bool,
  tf_seeded:   bool,

  options_open: bool, // the Options modal is up (mutually exclusive with the Setup modal)
  opt_ar_buf:   [16]u8, // attack_range textbox (options modal)
  opt_ar_edit:  bool,
  opt_mg_buf:   [8]u8, // density mingain textbox
  opt_mg_edit:  bool,
  opt_dt_buf:   [12]u8, // density detour textbox
  opt_dt_edit:  bool,
  // look-alive tuning textboxes (options modal): hesitation min/max, jump interval min/max (seconds),
  // and jump chance (percent). Seeded from the locked snapshot alongside the other option boxes.
  opt_lahmin_buf:  [8]u8,
  opt_lahmin_edit: bool,
  opt_lahmax_buf:  [8]u8,
  opt_lahmax_edit: bool,
  opt_lajmin_buf:  [8]u8,
  opt_lajmin_edit: bool,
  opt_lajmax_buf:  [8]u8,
  opt_lajmax_edit: bool,
  opt_lajch_buf:   [8]u8, // jump chance (percent)
  opt_lajch_edit:  bool,
  opt_lastepch_buf: [8]u8, // step chance (percent)
  opt_lastepch_edit: bool,
  opt_lastepsp_buf: [8]u8, // step spread (world units)
  opt_lastepsp_edit: bool,
  opt_lamaxr_buf:  [8]u8, // max-range approach distance (world units)
  opt_lamaxr_edit: bool,
  opt_seeded:   bool, // one-time seed of the option textboxes on modal open
  opt_scroll:   f32, // Options modal vertical scroll offset (<=0; content scrolls under the fixed title/footer)
  opt_content_h: f32, // measured intrinsic content height (for the scroll clamp) - set each frame while open

  // Leaderboards modal (see leaderboard.odin). The trigger button appears at the bottom-center of the
  // sidebar only when leaderboard_url is set; the modal drives the same `leaderboard` subcommands as the CLI.
  leaderboard_open: bool,
  lb_seeded:        bool,   // one-time seed of the name box on open
  lb_name_buf:      [64]u8, // submission-name textbox
  lb_name_edit:     bool,
  lb_sort:          i32,    // selected board sort (index into LB_SORTS; drives the toggle group + Refresh)
}

// Write <s> into a raygui textbox byte buffer (NUL-terminated, tail-zeroed). For seeding the Options
// modal's textboxes from the live layout values.
panel_buf_set :: proc(buf: []u8, s: string) {
  n := min(len(s), len(buf) - 1)
  copy(buf, s[:n])
  for i in n ..< len(buf) {
    buf[i] = 0
  }
}

// Clear every Options-modal textbox edit flag. raygui keeps focus per-box, so on any box click we clear
// all of them and then re-focus just the clicked one (see the option textbox handlers).
panel_opt_clear_edits :: proc(ps: ^Panel_State) {
  ps.opt_ar_edit = false
  ps.opt_mg_edit = false
  ps.opt_dt_edit = false
  ps.opt_lahmin_edit = false
  ps.opt_lahmax_edit = false
  ps.opt_lajmin_edit = false
  ps.opt_lajmax_edit = false
  ps.opt_lajch_edit = false
  ps.opt_lastepch_edit = false
  ps.opt_lastepsp_edit = false
  ps.opt_lamaxr_edit = false
}

// Read a NUL-terminated string out of a raygui textbox byte buffer (pure; no session touch).
panel_buf_str :: proc(buf: []u8) -> string {
  n := 0
  for n < len(buf) && buf[n] != 0 {
    n += 1
  }
  return string(buf[:n])
}

// Enqueue a deferred command. The string is cloned to the heap so it survives the frame's temp free_all
// (which runs before the drain); the drain frees it after running it.
panel_enqueue :: proc(ps: ^Panel_State, cmd: string) {
  append(&ps.pending, strings.clone(cmd))
}

// Run SLOW commands (the setup pipeline [+ findpenya]) on a one-shot worker thread instead of the
// deferred drain: the drain executes on the RENDER thread, which then cannot draw its own progress -
// the whole window froze for the multi-second pipeline. The worker takes exec_mutex around the run
// exactly like the REPL does; cli_setup additionally publishes per-step progress and yields the lock
// between steps (setup_step_mark), so the frame loop redraws a live step counter while it works. One
// run at a time - cli_setup's own setup_running guard rejects a concurrent invocation (REPL or panel).
Panel_Async_Job :: struct {
  session: ^Session,
  cmds:    [dynamic]string,
}

panel_run_async :: proc(session: ^Session, cmds: []string) {
  job := new(Panel_Async_Job)
  job.session = session
  job.cmds = make([dynamic]string)
  for c in cmds {
    append(&job.cmds, strings.clone(c))
  }
  thread.create_and_start_with_data(job, proc(data: rawptr) {
    j := cast(^Panel_Async_Job)data
    sync.mutex_lock(&j.session.exec_mutex)
    for c in j.cmds {
      if j.session.exec_line != nil {
        j.session.exec_line(&j.session.eng, c)
      }
    }
    sync.mutex_unlock(&j.session.exec_mutex)
    for c in j.cmds {
      delete(c)
    }
    delete(j.cmds)
    free(j)
  }, nil, .Normal, true) // self_cleanup: fire-and-forget
}

// sfx [on|off] - master toggle for the radar's sound effects (penya-gain chime + kill zap). Persisted
// to flyff.cfg (attach-gated save: the pre-attach layout is defaults and must never overwrite a
// calibrated cfg). The sounds only exist while a radar window is open (the audio device lives with it).
cli_sfx :: proc(session: ^Session, args: []string) {
  switch {
  case len(args) == 0:
    session.layout.sfx_on = !session.layout.sfx_on
  case len(args) == 1 && args[0] == "on":
    session.layout.sfx_on = true
  case len(args) == 1 && args[0] == "off":
    session.layout.sfx_on = false
  case:
    fmt.eprintln("usage: sfx [on|off]")
    return
  }
  if session.attached {
    flyff_save_cfg(session.layout, flyff_cfg_path())
  }
  fmt.printfln("radar sfx %s.", session.layout.sfx_on ? "ON" : "OFF")
}

// fxlaser [on|off] - toggle the radar's kill laser-beam effect. Persisted like sfx.
cli_fxlaser :: proc(session: ^Session, args: []string) {
  switch {
  case len(args) == 0:
    session.layout.fx_laser_on = !session.layout.fx_laser_on
  case len(args) == 1 && args[0] == "on":
    session.layout.fx_laser_on = true
  case len(args) == 1 && args[0] == "off":
    session.layout.fx_laser_on = false
  case:
    fmt.eprintln("usage: fxlaser [on|off]")
    return
  }
  if session.attached {
    flyff_save_cfg(session.layout, flyff_cfg_path())
  }
  fmt.printfln("kill laser fx %s.", session.layout.fx_laser_on ? "ON" : "OFF")
}

// trail [on|off] - toggle the radar's fading player-path trail (a subtle breadcrumb behind the player
// dot that fades out over distance). Length + fade are `set trail_len` / `set trail_fade`. Persisted
// like sfx (attach-gated save: never overwrite a calibrated cfg with the pre-attach defaults).
cli_trail :: proc(session: ^Session, args: []string) {
  switch {
  case len(args) == 0:
    session.layout.trail_on = !session.layout.trail_on
  case len(args) == 1 && args[0] == "on":
    session.layout.trail_on = true
  case len(args) == 1 && args[0] == "off":
    session.layout.trail_on = false
  case:
    fmt.eprintln("usage: trail [on|off]")
    return
  }
  if session.attached {
    flyff_save_cfg(session.layout, flyff_cfg_path())
  }
  fmt.printfln("player trail %s.", session.layout.trail_on ? "ON" : "OFF")
}

// hillshade [on|off] - toggle the radar's colourless terrain relief (a shaded-relief backdrop that
// embosses hills/cliffs/ramps in grey, lit from hillshade_light). Reads the terrain heightmap, so it
// needs `worldscan` pinned; the toggle still flips (it activates once terrain resolves). Depth is
// `set hillshade_z`, light direction `set hillshade_light`. Persisted like trail (attach-gated save).
cli_hillshade :: proc(session: ^Session, args: []string) {
  switch {
  case len(args) == 0:
    session.layout.hillshade_on = !session.layout.hillshade_on
  case len(args) == 1 && args[0] == "on":
    session.layout.hillshade_on = true
  case len(args) == 1 && args[0] == "off":
    session.layout.hillshade_on = false
  case:
    fmt.eprintln("usage: hillshade [on|off]")
    return
  }
  if session.attached {
    flyff_save_cfg(session.layout, flyff_cfg_path())
  }
  fmt.printfln("terrain hillshade %s.", session.layout.hillshade_on ? "ON" : "OFF")
  if session.layout.hillshade_on && !terrain_ready(session) {
    fmt.println("  note: terrain offsets not pinned yet - run 'worldscan' (in-game) so the relief has heights to draw.")
  }
}

// Multi-line hover tooltip (the "?" legend badge + anything else needing more than one line). Shares
// the visual language of the status-light tooltip; clamps to the given right edge.
panel_tooltip_lines :: proc(x, y: f32, lines: []cstring, right_edge: f32) {
  w := i32(0)
  for l in lines {
    lw := rl.MeasureText(l, 12)
    if lw > w {
      w = lw
    }
  }
  h := i32(len(lines)) * 16 + 8
  tx := x
  ty := y
  if tx + f32(w) + 12 > right_edge {
    tx = right_edge - f32(w) - 12
  }
  rl.DrawRectangle(i32(tx - 4), i32(ty - 3), w + 12, h, rl.Color{10, 14, 20, 240})
  rl.DrawRectangleLines(i32(tx - 4), i32(ty - 3), w + 12, h, rl.Color{80, 90, 102, 255})
  for l, i in lines {
    rl.DrawText(l, i32(tx + 1), i32(ty + f32(i * 16)), 12, rl.RAYWHITE)
  }
}

// Case-insensitive membership test over a name list (for "already a chip" / dedup checks).
panel_name_in :: proc(list: []string, name: string) -> bool {
  for e in list {
    if strings.equal_fold(e, name) {
      return true
    }
  }
  return false
}

// Append <name> to the temp candidate pool if not already present (case-insensitive dedup).
panel_add_cand :: proc(pool: ^[dynamic]string, name: string) {
  if !panel_name_in(pool[:], name) {
    append(pool, name)
  }
}

// One status light: a colored dot + label. Returns the row rectangle so the caller can hit-test it for a
// hover tooltip. Green = pinned; red = required + missing; yellow = optional + missing.
panel_status_light :: proc(x, y, w: f32, g: Setup_Group) -> rl.Rectangle {
  col := g.ok ? DOT_OK : (g.required ? DOT_REQ : DOT_OPT)
  rl.DrawCircle(i32(x + 6), i32(y + 8), 5, col)
  rl.DrawText(fmt.ctprintf("%s", g.label), i32(x + 18), i32(y + 2), 12, PANEL_TXT)
  return rl.Rectangle{x, y, w, 16}
}

// Format an integer with thousands separators (e.g. 1240 -> "1,240"), temp-allocated. For the penya pop.
commafy :: proc(n: i64) -> string {
  s := fmt.tprintf("%d", n)
  neg := len(s) > 0 && s[0] == '-'
  if neg {
    s = s[1:]
  }
  b := strings.builder_make(context.temp_allocator)
  if neg {
    strings.write_byte(&b, '-')
  }
  L := len(s)
  for i in 0 ..< L {
    if i > 0 && (L - i) % 3 == 0 {
      strings.write_byte(&b, ',')
    }
    strings.write_byte(&b, s[i])
  }
  return strings.to_string(b)
}

// radar [seconds] - open the live radar window. seconds>0 auto-closes after that long (handy for a quick
// look / headless smoke test); omit to run until you close the window. Press E in-window for the fence
// editor (see the HUD for controls); draw your fence, close the window, then `fence save <name>`.
cli_radar :: proc(session: ^Session, args: []string) {
  if !session.attached || session.ptr_size != 4 {
    fmt.eprintln("radar: attach a 32-bit Neuz first.")
    return
  }
  dur := f64(0)
  if len(args) >= 1 {
    if v, ok := strconv.parse_f64(args[0]); ok && v > 0 {
      dur = v
    }
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := engine.Value_Type.U32
  L := session.layout
  view_r := clamp(L.radar_range, RADAR_RANGE_MIN, RADAR_RANGE_MAX) // vision radius; re-read live each frame in the loop

  // Read once and report BEFORE opening a window, so the data pipeline is verifiable headlessly.
  world := read_ptr_at(handle, base + L.world_rva, pt)
  ppos, pok := read_player_pos(session)
  if !pok || world == 0 {
    // Open ANYWAY with an empty map. The control panel's Setup dialog is how you configure the tool, so
    // requiring setup to be complete before you can open it is a dead end (this used to hard-return here).
    // The render loop re-reads world + player every frame and guards all mob/obstacle work on them, so
    // blips appear live the instant setup resolves them. Fall back to the origin for the initial camera.
    if !pok {
      ppos = {0, 0, 0}
    }
    fmt.eprintln("radar: world/player not resolved yet - opening the panel so you can run Setup. Be in-game + run setup; blips appear once it resolves.")
  } else {
    probe_player := read_ptr_at(handle, base + L.player_rva, pt)
    probe_pb, probe_pai := radar_prop_ctx(session, probe_player)
    probe := make([dynamic]Radar_Blip, context.temp_allocator)
    radar_gather_movers(session, world, probe_player, probe_pb, probe_pai, ppos[0], ppos[2], view_r + 20, &probe, nil, nil, 0)
    probe_obbs := collect_area_colliders(session, world, ppos[0], ppos[2])
    nmon, nply, noth := 0, 0, 0
    for b in probe {
      switch b.kind {
      case .Monster:
        nmon += 1
      case .Player:
        nply += 1
      case .Other, .Unclassified:
        noth += 1
      }
    }
    fmt.printfln(
      "radar: player (%.1f, %.1f), %d movers (%d mob, %d player, %d other), %d obstacles in view. opening window%s...",
      ppos[0], ppos[2], len(probe), nmon, nply, noth, len(probe_obbs), dur > 0 ? fmt.tprintf(" for %.0fs", dur) : "",
    )
  }
  free_all(context.temp_allocator)

  rl.SetConfigFlags({.WINDOW_RESIZABLE})
  rl.InitWindow(820 + i32(PANEL_W), 820, "memscan radar")
  defer rl.CloseWindow() // raylib's own (via /WHOLEARCHIVE:raylib.lib) - see note atop this file
  rl.SetWindowMinSize(i32(PANEL_W) + 320, 480) // keep the panel + a usable map region visible
  rl.SetTargetFPS(30)
  radar_apply_theme() // dark, high-contrast raygui theme (raylib's default is unreadable low-contrast grey)

  // Audio lives with the window: the penya chime + kill zap can only play while the radar is open, which
  // is exactly what we want. Synthesized once (no assets). Guards on IsAudioDeviceReady so a headless /
  // no-device environment just stays silent (PlaySound on a zero Sound is a safe no-op regardless).
  rl.InitAudioDevice()
  defer rl.CloseAudioDevice()
  audio_ok := rl.IsAudioDeviceReady()
  snd_penya, snd_kill: rl.Sound
  if audio_ok {
    snd_penya = synth_penya_chime()
    snd_kill = synth_kill_zap()
  }
  defer if audio_ok {rl.UnloadSound(snd_penya); rl.UnloadSound(snd_kill)}

  scale := f32(3.0) // pixels per world unit; mouse wheel zooms
  cam := [2]f32{ppos[0], ppos[2]} // world point at screen center; right-drag pans, C recenters on player
  cam_lock := false // L / VIEW button: lock the camera on the player so the dot stays centred (pan disabled)
  show_cam := false // F toggles the render-camera eye + frustum overlay
  show_reach := true // R toggles fading of monsters the collision check can't reach (off = less per-frame work)
  start := rl.GetTime()

  // Fence editor state - all local. session.fence is mutated only here (and by the `fence` commands),
  // always under the REPL's exec_mutex, so it never races the watcher's picker. poly_wip is heap-owned
  // (it lives across frames while the temp allocator is reclaimed each frame).
  edit := false
  tool := Radar_Tool.Circle
  tag_i := 0 // fence draw tag: 0 = include(+), 1 = exclude(-), 2 = avoid(!). Tab cycles.
  drag_active := false
  drag_start := [2]f32{}
  poly_wip := make([dynamic][2]f32)
  defer delete(poly_wip)

  // Control-panel widget state (Phase 3). Local, like poly_wip. Its pending/selected strings are
  // heap-owned; free any leftovers on close (the per-frame drain frees the rest).
  ps: Panel_State
  defer {
    for c in ps.pending {delete(c)}
    delete(ps.pending)
    for s in ps.selected {delete(s)}
    delete(ps.selected)
  }

  // Phase 4 interaction state - radar-local (like poly_wip); the watcher thread never touches these.
  // The "+penya" pops, kill lasers, and move markers, plus the hover-target.
  pops := make([dynamic]Penya_Pop)
  marks := make([dynamic]Move_Mark)
  laser_fx := make([dynamic]Laser_Fx)
  defer delete(pops)
  defer delete(marks)
  defer delete(laser_fx)
  // Player-path trail - radar-local world points (like pops/marks); sampled + trimmed each frame.
  trail := make([dynamic][3]f32)
  defer delete(trail)

  // Terrain hillshade relief - cached screen-cell list, rebuilt only when the view (cam/scale/size)
  // changes (terrain is static), so a still view costs only the rect draws. Cells are value-only.
  hill_cells := make([dynamic]Hill_Cell)
  defer delete(hill_cells)
  hill_cam := [2]f32{}
  hill_scale := f32(-1)
  hill_fw := f32(-1)
  hill_fh := f32(-1)
  hill_valid := false

  // Filter-coloring name cache + map-wide giant overlay - radar-local, persist across frames (like poly_wip),
  // freed on close. The giant list is refilled by a throttled scan (GIANT_SCAN_NS); giants_at gates it.
  name_cache := make(map[uintptr]Radar_Name_Entry)
  defer radar_name_cache_free(&name_cache)
  giants := make([dynamic]Radar_Giant)
  defer {for g in giants {delete(g.name)};delete(giants)}
  giants_at := i64(0)
  // Seq cursors: penya/kill events are appended by the watcher (session.*_events) and drained here into
  // pops/lasers. Seed to the current seq so a freshly-opened window doesn't replay old history. Read under
  // the lock (cli_radar is entered holding exec_mutex).
  penya_seen := session.penya_seq
  kill_seen := session.kill_seq
  hover_obj: uintptr // nearest hittable mob under the cursor (view mode) - drawn as a ring, plain-click targets it
  hover_pos: [3]f32
  // Bottom-left bag readout (free/total). read_inventory_counts is a ~100KB read, so throttle it (the
  // count barely moves) and persist the last result across frames; inv_have gates the whole HUD element.
  inv_used, inv_cap := 0, 0
  inv_have := false
  inv_next_read: f64 = 0

  // cli_radar is entered holding exec_mutex (run_cli locks around every command). We keep that invariant:
  // each frame's session work runs locked, and we RELEASE the lock across the draw/present so the watcher
  // can farm, re-acquiring before the next iteration. On every exit path the mutex is held (run_cli unlocks).
  for !rl.WindowShouldClose() {
    tracy.FrameMark() // closes the previous radar frame on the Tracy timeline
    tracy.ZoneN("Radar_Frame") // deferred_out auto-closes at the end of this loop iteration (incl. break)
    if dur > 0 && rl.GetTime() - start >= dur {
      break
    }

    fw := f32(rl.GetScreenWidth())
    fh := f32(rl.GetScreenHeight())
    center := rl.Vector2{(fw - PANEL_W) / 2, fh / 2} // recentre the world into the left region (panel on the right)
    mouse := rl.GetMousePosition()
    mw := radar_s2w(cam, scale, center, mouse.x, mouse.y) // world (x,z) under the cursor
    // Gate world input: panel clicks/scroll must never pan/zoom/edit the map, and typing in a panel
    // textbox must not trigger the E/F/R/C or fence hotkeys. (Modal open => treat all as panel.) The
    // fence toolbar rect counts as panel while edit mode is on, so a toolbar click never also lands a
    // fence draw/erase at that same screen point.
    mouse_in_panel :=
      mouse.x >= fw - PANEL_W ||
      ps.setup_open ||
      ps.options_open ||
      ps.leaderboard_open ||
      rl.CheckCollisionPointRec(mouse, MUTE_BTN_RECT) ||
      (edit && rl.CheckCollisionPointRec(mouse, FENCE_TB_RECT))
    typing := ps.search_edit || ps.name_edit || ps.hp_edit || ps.penya_edit || ps.lb_name_edit

    // Re-snapshot the layout every frame (under the lock): setup/findpenya from the panel and an
    // external 'set attack_range' all mutate session.layout live, and a frozen copy kept the ring,
    // the penya watch, and the cold-start blip pipeline stale until the window was reopened.
    L = session.layout
    view_r = clamp(L.radar_range, RADAR_RANGE_MIN, RADAR_RANGE_MAX) // live vision radius (Options slider)

    // --- live player pos + facing (single player resolve) ---
    pangle: f32
    has_angle := false
    player := read_ptr_at(handle, base + L.player_rva, pt)
    if player != 0 {
      if p, ok := engine.read_vec3(handle, player + uintptr(L.pos_off)); ok {
        ppos = p
      }
      if L.angle_off != 0 {
        if a, ok := read_f32_at(handle, player + uintptr(L.angle_off)); ok {
          pangle = a
          has_angle = true
        }
      }
    }

    // --- player-path trail sample: distance-gated (idling doesn't grow it; a big hop = teleport ->
    // reset), then trim the oldest crumbs so the total path length stays within L.trail_len. ---
    if L.trail_on {
      if len(trail) == 0 {
        append(&trail, ppos)
      } else {
        last := trail[len(trail) - 1]
        dx := ppos[0] - last[0]
        dz := ppos[2] - last[2]
        d := math.sqrt(dx * dx + dz * dz)
        if d >= TRAIL_BREAK_STEP {
          clear(&trail)
          append(&trail, ppos)
        } else if d >= TRAIL_MIN_STEP {
          append(&trail, ppos)
        }
      }
      if L.trail_len > 0 && len(trail) >= 2 {
        acc: f32 = 0
        cut := 0
        for i := len(trail) - 1; i > 0; i -= 1 {
          dx := trail[i][0] - trail[i - 1][0]
          dz := trail[i][2] - trail[i - 1][2]
          acc += math.sqrt(dx * dx + dz * dz)
          if acc > L.trail_len {cut = i;break} // crumbs [0, cut) are older than the window
        }
        for k := 0; k < cut; k += 1 {ordered_remove(&trail, 0)}
      }
      for len(trail) > TRAIL_MAX_PTS {ordered_remove(&trail, 0)}
    } else if len(trail) > 0 {
      clear(&trail) // toggle off -> drop history so it can't reappear stale on re-enable
    }

    // --- input: view controls + fence editor (both modes). Gated so the panel owns its region. ---
    if !mouse_in_panel && !typing {
    scale += rl.GetMouseWheelMove() * 0.5
    if scale < 0.5 {scale = 0.5}
    if scale > 24 {scale = 24}
    if !cam_lock && rl.IsMouseButtonDown(.RIGHT) { // right-drag pans (disabled while locked to the player)
      d := rl.GetMouseDelta()
      cam[0] -= d.x / scale
      cam[1] += d.y / scale // north-up projection: screen-y is inverted vs world z (see radar_w2s)
    }
    if rl.IsKeyPressed(.E) {edit = !edit}
    if rl.IsKeyPressed(.F) {show_cam = !show_cam}
    if rl.IsKeyPressed(.R) {show_reach = !show_reach}
    if rl.IsKeyPressed(.L) {cam_lock = !cam_lock}
    if rl.IsKeyPressed(.C) || rl.IsKeyPressed(.HOME) {cam = {ppos[0], ppos[2]}}
    if rl.IsKeyPressed(.H) {panel_enqueue(&ps, "hillshade")} // toggle terrain relief (deferred like jump)
    if rl.IsKeyPressed(.SPACE) && !edit {panel_enqueue(&ps, "jump")} // jump (deferred like every UI action)

    // --- input: fence editor (edit mode) ---
    if edit {
      if rl.IsKeyPressed(.ONE) {tool = .Circle}
      if rl.IsKeyPressed(.TWO) {tool = .Rect}
      if rl.IsKeyPressed(.THREE) {tool = .Polygon}
      if rl.IsKeyPressed(.FOUR) {tool = .Eraser}
      if rl.IsKeyPressed(.TAB) {tag_i = (tag_i + 1) % 3} // cycle + / - / !
      e_include, e_avoid, _ := radar_fence_tag(tag_i)
      if rl.IsKeyPressed(.A) {session.fence.active = !session.fence.active}
      if rl.IsKeyPressed(.DELETE) {
        fence_reset(&session.fence)
        clear(&poly_wip)
        drag_active = false
      }
      if tool != .Circle && tool != .Rect {
        drag_active = false // no drag for polygon/eraser (avoids a stuck drag when switching tool mid-drag)
      }
      switch tool {
      case .Polygon:
        if rl.IsMouseButtonPressed(.LEFT) {
          append(&poly_wip, mw)
        }
        if rl.IsKeyPressed(.ENTER) && len(poly_wip) >= 3 {
          s := Fence_Shape{kind = .Polygon, include = e_include, avoid = e_avoid}
          append(&s.verts, ..poly_wip[:])
          append(&session.fence.shapes, s)
          clear(&poly_wip)
          session.fence.active = true
        }
        if rl.IsKeyPressed(.BACKSPACE) {
          if len(poly_wip) > 0 {
            pop(&poly_wip)
          } else {
            fence_pop_shape(&session.fence)
          }
        }
      case .Eraser:
        if rl.IsMouseButtonPressed(.LEFT) {
          fence_erase_at(&session.fence, mw[0], mw[1]) // deletes the shape under the cursor (no-op if none)
        }
        if rl.IsKeyPressed(.BACKSPACE) {
          fence_pop_shape(&session.fence)
        }
      case .Circle, .Rect:
        if rl.IsMouseButtonPressed(.LEFT) {
          drag_start = mw
          drag_active = true
        }
        if drag_active && rl.IsMouseButtonReleased(.LEFT) {
          drag_active = false
          if tool == .Circle {
            dx := mw[0] - drag_start[0]
            dz := mw[1] - drag_start[1]
            r := math.sqrt(dx * dx + dz * dz)
            if r > 0.5 {
              append(&session.fence.shapes, Fence_Shape{kind = .Circle, include = e_include, avoid = e_avoid, cx = drag_start[0], cz = drag_start[1], r = r})
              session.fence.active = true
            }
          } else {
            minx := min(drag_start[0], mw[0])
            maxx := max(drag_start[0], mw[0])
            minz := min(drag_start[1], mw[1])
            maxz := max(drag_start[1], mw[1])
            if (maxx - minx) > 0.5 && (maxz - minz) > 0.5 {
              append(&session.fence.shapes, Fence_Shape{kind = .Rect, include = e_include, avoid = e_avoid, minx = minx, minz = minz, maxx = maxx, maxz = maxz})
              session.fence.active = true
            }
          }
        }
        if rl.IsKeyPressed(.BACKSPACE) {
          fence_pop_shape(&session.fence)
        }
      }
    }
    } // end input gate (mouse_in_panel / typing)

    // Camera-lock: keep the player centred by pinning the view to its live position every frame (the world
    // scrolls under a stationary dot instead of the dot drifting off-centre). Applied after input so it
    // overrides any stray pan; zoom still works.
    if cam_lock {
      cam = {ppos[0], ppos[2]}
    }

    // --- live data (snapshot shared state before releasing the lock) ---
    w := read_ptr_at(handle, base + L.world_rva, pt)
    mobs := make([dynamic]Radar_Blip, context.temp_allocator)
    obbs: []Obb
    focus: uintptr // currently selected target (m_pObjFocus); 0 = nothing selected
    focus_pos: [3]f32
    focus_pos_ok := false
    now_frame := time.now()._nsec
    if w != 0 {
      propbase, player_ai := radar_prop_ctx(session, player)
      radar_gather_movers(session, w, player, propbase, player_ai, ppos[0], ppos[2], view_r + 20, &mobs, session.auto_names[:], &name_cache, now_frame)
      if show_reach {
        radar_reach_pass(session, w, ppos, mobs[:]) // fade monsters the collision check can't reach
      }
      // Map-wide giant overlay: throttled full-tile scan (giants can spawn far beyond the vision window).
      if now_frame - giants_at >= GIANT_SCAN_NS {
        radar_scan_giants(session, w, player, &giants)
        giants_at = now_frame
      }
      // collect_area_colliders returns session.collider_cache[:]. allow_async keeps the frame off the
      // ~200ms rebuild: a stale cache kicks the background collider_scan_worker and serves the current
      // slice. That worker republishes the cache under exec_mutex, so clone into temp - drawing runs after
      // we unlock and must not touch a slice being reallocated out from under it.
      obbs = slice.clone(collect_area_colliders(session, w, ppos[0], ppos[2], allow_async = true), context.temp_allocator)
      // Terrain hillshade: rebuild the relief cells only when the view changed (static terrain). Reads
      // game memory, so it must run here (locked). Gated on the toggle + terrain offsets being pinned.
      if L.hillshade_on && terrain_ready(session) {
        if !hill_valid || hill_cam != cam || hill_scale != scale || hill_fw != fw || hill_fh != fh {
          radar_gather_hillshade(session, w, cam, scale, center, fw, fh, L.hillshade_z, L.hillshade_light, &hill_cells)
          hill_cam = cam
          hill_scale = scale
          hill_fw = fw
          hill_fh = fh
          hill_valid = true
        }
      } else if hill_valid {
        clear(&hill_cells)
        hill_valid = false
      }
      // Selected target: read m_pObjFocus + its position so we can ring it (it may sit outside the
      // gathered radius, so we resolve its position directly rather than relying on the mob list).
      focus = read_ptr_at(handle, w + uintptr(L.focus_off), pt)
      if focus != 0 {
        if fvt := read_ptr_at(handle, focus, pt); fvt >= base && fvt < base + uintptr(session.proc_info.module_size) {
          focus_pos, focus_pos_ok = engine.read_vec3(handle, focus + uintptr(L.pos_off))
        } else {
          focus = 0 // stale/freed pointer - don't ring it
        }
      }
    }
    // Per-frame counts, plotted so frame-time spikes can be correlated with a collider rebuild
    // (obbs jumps on the ~16-unit cache miss - the suspected stutter frame).
    tracy.PlotI("Radar_Movers", i64(len(mobs)))
    tracy.PlotI("Radar_Colliders", i64(len(obbs)))

    // --- Phase 4 click interaction (still locked): plain-click = target the mob under the cursor;
    // Shift+click = walk to the ground point. Only in view mode (edit owns left-click for fences) and
    // off the panel. focus_set_obj / write_dest_pos need exec_mutex, which we still hold here. ---
    shift_down := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
    hover_obj = 0
    if !mouse_in_panel && !typing && !edit {
      best := HIT_R // nearest mob dot under the cursor (hover ring + plain-click target)
      for m in mobs {
        sp := radar_w2s(cam, scale, center, m.pos[0], m.pos[2])
        dx := sp.x - mouse.x
        dy := sp.y - mouse.y
        dd := math.sqrt(dx * dx + dy * dy)
        if dd <= best {
          best = dd
          hover_obj = m.obj
          hover_pos = m.pos
        }
      }
      if rl.IsMouseButtonPressed(.LEFT) {
        if shift_down {
          if moveto_ready(session) { // walk to the world point under the cursor (broadcasts the walk)
            dest := [3]f32{mw[0], ppos[1], mw[1]}
            write_dest_pos(session, ppos, dest)
            remote_send_snapshot(session)
            append(&marks, Move_Mark{pos = dest, t = time.now()._nsec})
          }
        } else if hover_obj != 0 { // select the exact mob under the cursor (guarded write + srvsync)
          focus_set_obj(session, hover_obj, nil)
        }
      }
    }
    // Selected / hovered entity NAMES (resolved under the lock; read_mover_name is temp-allocated and
    // survives until this frame's free_all after the draw). Drawn beside their rings below.
    sel_name := ""
    if focus != 0 {
      if nm, ok := read_mover_name(session, focus); ok {
        sel_name = nm
      }
    }
    hover_name := ""
    if hover_obj != 0 && hover_obj != focus {
      if nm, ok := read_mover_name(session, hover_obj); ok {
        hover_name = nm
      }
    }
    // Penya + kill juice: penya_tick accrues the total and records gains (it also runs on the watcher,
    // both under this lock, so no double-count). kill_watch_tick records HAND kills (auto off) so the
    // laser/zap fire when farming manually too. Then drain any events newer than when we opened into the
    // "+penya" pops / kill lasers, and fire the chime / zap once per batch of new events.
    penya_tick(session)
    kill_watch_tick(session, time.now()._nsec)
    now_ev := time.now()._nsec
    play_chime := false
    for ev in session.penya_events {
      if ev.seq > penya_seen {
        append(&pops, Penya_Pop{amount = ev.amount, t = now_ev, pos = ev.pos})
        penya_seen = ev.seq
        play_chime = true
      }
    }
    play_zap := false
    for ev in session.kill_events {
      if ev.seq > kill_seen {
        append(&laser_fx, Laser_Fx{to = ev.pos, t = now_ev})
        kill_seen = ev.seq
        play_zap = true
      }
    }
    if audio_ok && L.sfx_on {
      if play_chime {rl.PlaySound(snd_penya)}
      if play_zap {rl.PlaySound(snd_kill)}
    }

    ceye, clook: [3]f32
    cam_ok := false
    if show_cam {
      ceye, clook, cam_ok = read_camera(session)
    }

    // --- panel snapshot (structured status/auto/range data; drawn after unlock, no text parsing) ---
    // attack_range slider seed/apply. ONLY write the layout from the slider WHILE the user is dragging it
    // (ar_dragging), so the green ring tracks the drag; otherwise re-seed the slider FROM the layout each
    // frame. That (a) reflects an external `set attack_range`/`density` and (b) stops GuiSlider's pixel-
    // quantisation from drifting the stored value every time the panel opens - that silent creep is what
    // bloated attack_range to ~17 and made the auto-picker's engage range spread targets. The aligned
    // 4-byte store is atomic vs the watcher's read; the flyff.cfg persist is deferred to slider release.
    if !ps.ar_seeded {
      ps.ar_slider = session.layout.attack_range
      ps.ar_seeded = true
    }
    if ps.ar_dragging {
      session.layout.attack_range = ps.ar_slider
    } else {
      ps.ar_slider = session.layout.attack_range
    }
    // radar-range (vision) slider: same discipline as attack_range. While dragging, push the value into
    // the layout so the gathered/drawn radius grows live; otherwise re-seed from the layout. Persist to
    // flyff.cfg is deferred to release (the Options slider block below).
    if !ps.rr_seeded {
      ps.rr_slider = session.layout.radar_range
      ps.rr_seeded = true
    }
    if ps.rr_dragging {
      session.layout.radar_range = ps.rr_slider
    } else {
      ps.rr_slider = session.layout.radar_range
    }
    // player-trail sliders (length + fade): same discipline. Display-only fields the watcher never reads,
    // so writing them live from the render thread is safe; flyff.cfg persist is deferred to release.
    if !ps.tr_seeded {
      ps.tr_slider = session.layout.trail_len
      ps.tr_seeded = true
    }
    if ps.tr_dragging {
      session.layout.trail_len = ps.tr_slider
    } else {
      ps.tr_slider = session.layout.trail_len
    }
    if !ps.tf_seeded {
      ps.tf_slider = session.layout.trail_fade
      ps.tf_seeded = true
    }
    if ps.tf_dragging {
      session.layout.trail_fade = ps.tf_slider
    } else {
      ps.tf_slider = session.layout.trail_fade
    }
    groups := setup_groups(session)
    opins := optional_pins(session)
    status_hdr := setup_status_line(session)
    auto_on_s := session.auto_on
    auto_paused_s := session.auto_paused
    auto_desc_s := auto_target_desc(session.auto_names[:])
    auto_line_s := auto_on_s ? auto_stats_panel(session, time.now()._nsec) : ""
    // Phase 6 panel snapshot: everything the (unlocked) draw phase needs is captured here, under the
    // lock, like the auto_* lines above - widgets must never read session during the draw.
    setup_running_s := session.setup_running
    setup_step_s := session.setup_step
    density_on_s := session.layout.density_on
    density_hue_s := session.layout.density_hue_on
    preselect_on_s := session.preselect_on
    lookalive_on_s := session.lookalive_on
    reach_gate_s := session.reach_gate_on
    hunt_s := session.hunt_on
    stuck_on_s := session.auto_stuck_on
    sfx_on_s := session.layout.sfx_on
    fx_laser_s := session.layout.fx_laser_on
    trail_s := session.layout.trail_on
    hillshade_on_s := session.layout.hillshade_on
    opt_ar_cur := session.layout.attack_range
    opt_mg_cur := session.layout.density_min_gain
    opt_dt_cur := session.layout.density_max_detour
    opt_lahmin_cur := session.layout.la_hold_min
    opt_lahmax_cur := session.layout.la_hold_max
    opt_lajmin_cur := session.layout.la_jump_min
    opt_lajmax_cur := session.layout.la_jump_max
    opt_lajch_cur := session.layout.la_jump_chance
    la_hesitate_s := session.layout.la_hesitate_on
    la_jump_s := session.layout.la_jump_on
    la_step_s := session.layout.la_step_on
    la_maxrange_s := session.layout.la_maxrange_on
    opt_lastepch_cur := session.layout.la_step_chance
    opt_lastepsp_cur := session.layout.la_step_spread
    opt_lamaxr_cur := session.layout.la_max_range
    prop_ok_s := prop_gate_ready(session)
    penya_total_s := session.penya_total
    penya_cur_s := session.penya_last // current gold balance (bottom-left HUD readout + cap warning)
    penya_show_s := session.layout.penya_off != 0 && session.penya_seeded // pinned + read at least once
    jump_at_s := session.jump_fired_at // for the player-dot hop animation (set by cli_jump / look-alive)
    // Leaderboards snapshot: cheap scalars always (the gated button reads lb_configured_s); the board rows +
    // status are cloned into temp only while the modal is open (a Session.lb_board mutated by the async worker
    // must never be drawn lock-free). lb_rows_s is temp-lifetime - consumed by this frame's draw, freed after.
    lb_configured_s := session.layout.leaderboard_url != ""
    lb_active_s := session.lb_run.active
    lb_has_run_s := session.lb_run.active || session.lb_run.start_ns != 0
    lb_elapsed_s := lb_elapsed_sec(session)
    lb_kills_s := session.lb_run.kills
    lb_penya_s := lb_penya(session)
    lb_kpm_s := lb_kpm(session)
    lb_density_s := session.lb_run.max_density
    lb_species_s := len(session.lb_run.names)
    lb_busy_s := session.lb_net_busy
    lb_submitted_s := session.lb_run.submitted
    lb_board_sort_s := session.lb_board_sort
    lb_status_s := ""
    lb_rows_s: []Lb_Row
    if ps.leaderboard_open {
      lb_status_s = strings.clone(lb_status_str(session), context.temp_allocator)
      lb_rows_s = slice.clone(session.lb_board[:], context.temp_allocator)
    }
    // Bag fullness for the bottom-left HUD readout. read_inventory_counts is a ~100KB RPM read, so
    // throttle it (~2.5/s); the last result persists across frames. No-op/hidden when 'findinv' is unset.
    if L.inv_off != 0 && L.item_stride != 0 {
      if rl.GetTime() >= inv_next_read {
        if used, _, cap, ok := read_inventory_counts(session); ok {
          inv_used, inv_cap, inv_have = used, cap, true
        } else {
          inv_have = false
        }
        inv_next_read = rl.GetTime() + 0.4
      }
    } else {
      inv_have = false
    }
    // Distinct nearby monster names for the search suggestions - only read (extra RPM) while the search
    // box is in use, so an idle panel costs nothing. Temp-lifetime (consumed by this frame's draw).
    live_names := make([dynamic]string, context.temp_allocator)
    if ps.search_edit || panel_buf_str(ps.search_buf[:]) != "" {
      for m in mobs {
        if m.kind != .Monster {
          continue
        }
        if nm, ok := read_mover_name(session, m.obj); ok && len(nm) > 0 {
          panel_add_cand(&live_names, nm)
        }
      }
    }

    // Release exec_mutex for the draw/present so the watcher thread can run auto_tick this frame. All
    // session reads below (session.fence.shapes) have no concurrent writer: the radar's own fence writes
    // are above (locked) and the watcher only reads the fence.
    sync.mutex_unlock(&session.exec_mutex)

    // --- draw --- (bare block so tracy.ZoneN("Radar_Draw") scopes the whole present; inner code
    // keeps its existing indentation - the braces exist only to bound the profiling zone)
    { tracy.ZoneN("Radar_Draw")
    rl.BeginDrawing()
    rl.ClearBackground(rl.Color{12, 16, 22, 255})
    // Clip all world/HUD drawing to the left region so nothing bleeds under the right-side panel.
    rl.BeginScissorMode(0, 0, i32(fw - PANEL_W), i32(fh))
    // terrain hillshade relief (bottom layer; colourless, under crosshair/obstacles/fences/dots)
    if hillshade_on_s {
      for c in hill_cells {
        rl.DrawRectangleRec(c.rect, c.col)
      }
    }
    // screen-center crosshair (the current camera focus)
    rl.DrawLineV({center.x, 0}, {center.x, fh}, rl.Color{28, 38, 50, 255})
    rl.DrawLineV({0, center.y}, {fw, center.y}, rl.Color{28, 38, 50, 255})

    // obstacles: solid blockers (real collision mesh / OT_CTRL) as a filled purple box + bright outline;
    // walk-through props (GMT_ERROR - the game paths straight through them) as a faint grey outline only.
    // Both are shown so you can see the field, but the fill tells you which actually blocks. Each box is
    // drawn ORIENTED by its own OBB axes (yaw about Y), matching the collision oracle and the tdbg map.
    for o in obbs {
      if o.ext[0] <= 0.01 && o.ext[2] <= 0.01 {
        continue // degenerate / uninitialised OBB (nothing to draw; would be a stray dot at the origin)
      }
      radar_draw_obb(o, cam, scale, center)
    }

    // render-camera overlay (F)
    if show_cam && cam_ok {
      radar_draw_camera(ceye, clook, cam, scale, center)
    }

    // committed fence shapes
    for s in session.fence.shapes {
      radar_draw_shape(s, cam, scale, center)
    }
    // eraser hover: highlight the shape a click would delete
    if edit && tool == .Eraser {
      if hi := fence_shape_at(session.fence, mw[0], mw[1]); hi >= 0 {
        radar_draw_erase_hover(session.fence.shapes[hi], cam, scale, center)
      }
    }
    // in-progress polygon (edit mode)
    if edit && tool == .Polygon && len(poly_wip) > 0 {
      pinc, pavo, _ := radar_fence_tag(tag_i)
      col := fence_shape_color(pinc, pavo)
      for i in 0 ..< len(poly_wip) {
        a := radar_w2s(cam, scale, center, poly_wip[i][0], poly_wip[i][1])
        rl.DrawCircleV(a, 3, col)
        if i > 0 {
          b := radar_w2s(cam, scale, center, poly_wip[i - 1][0], poly_wip[i - 1][1])
          rl.DrawLineEx(b, a, 1.5, col)
        }
      }
      last := radar_w2s(cam, scale, center, poly_wip[len(poly_wip) - 1][0], poly_wip[len(poly_wip) - 1][1])
      rl.DrawLineEx(last, mouse, 1, rl.Color{col.r, col.g, col.b, 120}) // rubber-band to cursor
    }
    // in-progress circle/rect drag (edit mode)
    if edit && drag_active && (tool == .Circle || tool == .Rect) {
      dinc, davo, _ := radar_fence_tag(tag_i)
      col := fence_shape_color(dinc, davo)
      sp := radar_w2s(cam, scale, center, drag_start[0], drag_start[1])
      if tool == .Circle {
        dx := mw[0] - drag_start[0]
        dz := mw[1] - drag_start[1]
        rl.DrawCircleLinesV(sp, math.sqrt(dx * dx + dz * dz) * scale, col)
      } else {
        rl.DrawRectangleLinesEx({min(sp.x, mouse.x), min(sp.y, mouse.y), abs(mouse.x - sp.x), abs(mouse.y - sp.y)}, 1.5, col)
      }
    }

    // attack_range ring - your configured reach around the player (drives the picker; 'set attack_range')
    if L.attack_range > 0 {
      pc := radar_w2s(cam, scale, center, ppos[0], ppos[2])
      rl.DrawCircleLinesV(pc, L.attack_range * scale, RANGE_COL)
    }

    // player-path trail: a faint fading breadcrumb behind the player, anchored at the live player point
    // and walking back through the crumbs. Alpha fades with cumulative distance-from-player (trail_fade
    // exponent). Drawn here (under the density-hue/blip loop below) so mob + player dots render on top.
    if L.trail_on && L.trail_len > 0 && len(trail) >= 1 {
      prev_w := [2]f32{ppos[0], ppos[2]}
      prev_s := radar_w2s(cam, scale, center, prev_w[0], prev_w[1])
      acc: f32 = 0
      for i := len(trail) - 1; i >= 0; i -= 1 {
        cur_w := [2]f32{trail[i][0], trail[i][2]}
        cur_s := radar_w2s(cam, scale, center, cur_w[0], cur_w[1])
        dx := prev_w[0] - cur_w[0]
        dz := prev_w[1] - cur_w[1]
        acc += math.sqrt(dx * dx + dz * dz)
        frac := clamp(acc / L.trail_len, 0, 1)
        col := TRAIL_COL
        col.a = u8(f32(TRAIL_MAX_A) * math.pow(1 - frac, max(L.trail_fade, 0.01)))
        rl.DrawLineEx(prev_s, cur_s, TRAIL_W, col)
        if acc >= L.trail_len {break}
        prev_w = cur_w
        prev_s = cur_s
      }
    }

    // density-hue (display toggle): per-blip local pack size (monster blips within density_radius), so
    // each mob dot can be tinted by how crowded its spot is - the same metric compute_densities feeds the
    // picker, counted over what the radar shows. O(n^2) over tens of blips, only while the mode is on.
    hue_pack: []int
    hue_maxpack := 1 // densest pack in view -> the adaptive hue scale normalises against it
    if L.density_hue_on {
      hr2 := density_radius(L.attack_range)
      hr2 *= hr2
      hp := make([]int, len(mobs), context.temp_allocator)
      for a, i in mobs {
        if a.kind != .Monster && a.kind != .Unclassified {
          continue
        }
        c := 0
        for b in mobs {
          if b.kind != .Monster && b.kind != .Unclassified {
            continue
          }
          dx := a.pos[0] - b.pos[0]
          dz := a.pos[2] - b.pos[2]
          if dx * dx + dz * dz <= hr2 {
            c += 1 // counts itself, so a lone mob is pack 1
          }
        }
        hp[i] = c
        hue_maxpack = max(hue_maxpack, c)
      }
      hue_pack = hp
    }

    // movers: coloured/sized by kind (red mob, azure player w/ facing arrow, grey pet/npc). Gate-eligible
    // mobs (monsters / unclassified) outside the fence are dimmed so the editor previews the target gate;
    // ones the reach check can't reach are drawn faded (R toggles). With density-hue on, a gate-eligible
    // mob's base red is replaced by its pack-size tint before the fence/reach dimming is applied.
    have_fence := len(session.fence.shapes) > 0
    for m, i in mobs {
      p := radar_w2s(cam, scale, center, m.pos[0], m.pos[2])
      col, radius := radar_blip_style(m.kind)
      gate_eligible := m.kind == .Monster || m.kind == .Unclassified
      if gate_eligible && !m.name_match {
        // active name filter, and this monster isn't in it -> dim it (not a target). Skips density hue.
        rl.DrawCircleV(p, radius, FILTER_DIM_COL)
        continue
      }
      if L.density_hue_on && gate_eligible {
        col = radar_density_color(hue_pack[i], hue_maxpack)
      }
      if have_fence && gate_eligible && !fence_geom_contains(session.fence, m.pos[0], m.pos[2]) {
        col = rl.Color{90, 96, 105, 200} // outside the fence -> dimmed (would be skipped)
      } else if m.reach_tested && !m.reachable {
        col.a = 70 // unreachable per the collision check (terrain/obstacle in the way) -> faded
      }
      rl.DrawCircleV(p, radius, col)
      if m.kind == .Player && m.has_angle {
        radar_draw_arrow(p, m.angle, 11, 4, col) // other players get a facing arrow too
      }
    }

    // Map-wide giant overlay: draw every cached "Giant *" monster (see radar_scan_giants) with a gold ring +
    // name so it stands out. A giant beyond the visible map region is rim-clamped to the edge with an arrow +
    // distance, so a far hunt target is always locatable no matter the zoom/pan. Drawn under the scissor, so
    // clamped markers stay off the side panel.
    map_rect := rl.Rectangle{0, 0, fw - PANEL_W, fh}
    for g in giants {
      gs := radar_w2s(cam, scale, center, g.pos[0], g.pos[2])
      on_screen := gs.x >= map_rect.x && gs.x <= map_rect.x + map_rect.width && gs.y >= 0 && gs.y <= fh
      if on_screen {
        rl.DrawCircleV(gs, 4, GIANT_COL)
        rl.DrawCircleLinesV(gs, 8, GIANT_COL)
        rl.DrawCircleLinesV(gs, 10, GIANT_COL)
        rl.DrawText(fmt.ctprintf("%s", g.name), i32(gs.x + 13), i32(gs.y - 7), 13, GIANT_COL)
      } else {
        // Clamp the marker onto the map-region edge along the line from the screen center to the giant.
        mrg := f32(14) // margin so the clamped marker + label stay fully inside the region
        cx := center.x
        cy := center.y
        dx := gs.x - cx
        dy := gs.y - cy
        len2 := math.sqrt(dx * dx + dy * dy)
        if len2 < 0.001 {
          continue
        }
        ux := dx / len2
        uy := dy / len2
        // Parametric clamp to the region rectangle (left region only, [mrg, width-mrg] x [mrg, fh-mrg]).
        tmax := f32(1e30)
        if ux > 0.001 {tmax = min(tmax, (map_rect.width - mrg - cx) / (ux * len2))} else if ux < -0.001 {tmax = min(tmax, (mrg - cx) / (ux * len2))}
        if uy > 0.001 {tmax = min(tmax, (fh - mrg - cy) / (uy * len2))} else if uy < -0.001 {tmax = min(tmax, (mrg - cy) / (uy * len2))}
        tmax = clamp(tmax, 0, 1)
        ep := rl.Vector2{cx + dx * tmax, cy + dy * tmax}
        // radar_draw_arrow takes a game-angle in DEGREES; its tip points along screen dir (sin, cos) of a_deg
        // (north-up projection). Solve for the tip to point outward along (ux, uy): a_deg = deg(atan2(ux, uy)).
        radar_draw_arrow(ep, math.to_degrees(math.atan2(ux, uy)), 12, 6, GIANT_COL)
        rl.DrawCircleLinesV(ep, 6, GIANT_COL)
        gd := engine.dist_horizontal(g.pos, ppos)
        label := fmt.ctprintf("%s (%.0fu)", g.name, gd)
        lw := rl.MeasureText(label, 12)
        // Nudge the label inward so it never spills off the region edge.
        lx := clamp(ep.x + 10, map_rect.x + 2, map_rect.width - f32(lw) - 2)
        rl.DrawText(label, i32(lx), i32(clamp(ep.y - 6, 2, fh - 14)), 12, GIANT_COL)
      }
    }

    // selected target (m_pObjFocus) - a bright yellow ring + its name, so you can see what's locked
    if focus != 0 && focus_pos_ok {
      fp := radar_w2s(cam, scale, center, focus_pos[0], focus_pos[2])
      rl.DrawCircleLinesV(fp, 9, SEL_COL)
      rl.DrawCircleLinesV(fp, 11, SEL_COL)
      if sel_name != "" {
        rl.DrawText(fmt.ctprintf("%s", sel_name), i32(fp.x + 13), i32(fp.y - 7), 13, SEL_COL)
      }
    }

    // player dot + facing arrow (m_fAngle; same convention as the tdbg HTML: on-screen dir = angle+180).
    // On a jump (cli_jump / look-alive), lift the dot along a 0.6s sine hump and drop a shrinking ground
    // shadow at the true position, so every confirmed jump reads on the radar.
    pp := radar_w2s(cam, scale, center, ppos[0], ppos[2])
    if jump_at_s != 0 {
      jage := time.now()._nsec - jump_at_s
      if jage >= 0 && jage <= JUMP_ANIM_NS {
        arc := math.sin(f32(jage) / f32(JUMP_ANIM_NS) * math.PI) // 0 -> 1 -> 0 hump
        rl.DrawCircleV(pp, 5 * (1 - arc * 0.5), rl.Color{0, 0, 0, 90}) // shrinking shadow at the ground
        pp.y -= arc * JUMP_LIFT_PX // lift the dot + arrow drawn just below
      }
    }
    if has_angle {
      radar_draw_arrow(pp, pangle, 17, 6, rl.RAYWHITE)
    }
    rl.DrawCircleV(pp, 5, rl.WHITE)

    // hover ring: the mob a plain left-click would target (view mode) + its name
    if hover_obj != 0 {
      hpv := radar_w2s(cam, scale, center, hover_pos[0], hover_pos[2])
      rl.DrawCircleLinesV(hpv, 7, HOVER_COL)
      if hover_name != "" {
        rl.DrawText(fmt.ctprintf("%s", hover_name), i32(hpv.x + 10), i32(hpv.y - 6), 12, HOVER_COL)
      }
    }
    // move-destination markers (shift-click) - shrinking cyan crosshair, fades out. Prune expired.
    now_ns := time.now()._nsec
    for i := len(marks) - 1; i >= 0; i -= 1 {
      age := now_ns - marks[i].t
      if age > MARK_TTL {
        ordered_remove(&marks, i)
        continue
      }
      frac := f32(age) / f32(MARK_TTL)
      mp := radar_w2s(cam, scale, center, marks[i].pos[0], marks[i].pos[2])
      col := MARK_COL
      col.a = u8(200 * (1 - frac))
      rl.DrawCircleLinesV(mp, (1 - frac) * 10 + 2, col)
      rl.DrawLineV({mp.x - 5, mp.y}, {mp.x + 5, mp.y}, col)
      rl.DrawLineV({mp.x, mp.y - 5}, {mp.x, mp.y + 5}, col)
    }
    // "+penya" pops - gold text, rises + fades. Prune expired.
    for i := len(pops) - 1; i >= 0; i -= 1 {
      age := now_ns - pops[i].t
      if age > POP_TTL {
        ordered_remove(&pops, i)
        continue
      }
      frac := f32(age) / f32(POP_TTL)
      sp := radar_w2s(cam, scale, center, pops[i].pos[0], pops[i].pos[2])
      col := PENYA_COL
      col.a = u8(255 * (1 - frac))
      txt := fmt.ctprintf("+%s penya", commafy(pops[i].amount))
      tw := rl.MeasureText(txt, 16)
      rl.DrawText(txt, i32(sp.x) - tw / 2, i32(sp.y - frac * 30) - 22, 16, col)
    }
    // kill laser beams - a magenta line from the player to where each mob died, thinning + fading out.
    // Prune expired regardless; only draw when the Laser FX toggle is on. Origin is the player's ground
    // point (not the jump-lifted dot).
    pg := radar_w2s(cam, scale, center, ppos[0], ppos[2])
    for i := len(laser_fx) - 1; i >= 0; i -= 1 {
      age := now_ns - laser_fx[i].t
      if age > LASER_TTL {
        ordered_remove(&laser_fx, i)
        continue
      }
      if !L.fx_laser_on {
        continue
      }
      frac := f32(age) / f32(LASER_TTL)
      to := radar_w2s(cam, scale, center, laser_fx[i].to[0], laser_fx[i].to[2])
      col := LASER_COL
      col.a = u8(255 * (1 - frac))
      rl.DrawLineEx(pg, to, 2.5 * (1 - frac) + 0.5, col)
    }

    // --- fence floating toolbar (edit mode only; lives over the map, not in the sidebar). Its rect is
    // excluded from map input via mouse_in_panel, so these clicks never double as fence edits.
    if edit {
      rl.GuiUnlock()
      if ps.setup_open || ps.options_open || ps.leaderboard_open {rl.GuiLock()} // modal up -> toolbar renders disabled like the panel
      rl.DrawRectangleRounded(FENCE_TB_RECT, 0.15, 6, rl.Color{16, 22, 30, 235})
      rl.DrawRectangleRoundedLines(FENCE_TB_RECT, 0.15, 6, rl.Color{60, 74, 90, 255})
      tool_i := i32(tool)
      rl.GuiToggleGroup({20, 40, 55, 24}, "Circle;Rect;Poly;Erase", &tool_i)
      tool = Radar_Tool(tool_i)
      _, _, taglabel := radar_fence_tag(tag_i)
      // the tag button cycles + (include) -> - (exclude) -> ! (avoid / hard no-go)
      if rl.GuiButton({20, 68, 36, 24}, taglabel) {tag_i = (tag_i + 1) % 3}
      if rl.GuiButton({60, 68, 62, 24}, session.fence.active ? "On" : "Off") {
        panel_enqueue(&ps, session.fence.active ? "fence off" : "fence on")
      }
      if rl.GuiButton({126, 68, 60, 24}, "Clear") {panel_enqueue(&ps, "fence clear")}
      if rl.GuiButton({190, 68, 54, 24}, "Undo") {panel_enqueue(&ps, "fence undo")}
      // compact live state + key hints, only while editing (the always-on HUD text is gone - see badge)
      toolname: cstring = tool == .Circle ? "circle" : tool == .Rect ? "rect" : tool == .Polygon ? "polygon" : "eraser"
      tagword: cstring = tag_i == 0 ? "include(+)" : tag_i == 1 ? "exclude(-)" : "AVOID(!)"
      rl.DrawText(fmt.ctprintf("EDIT  tool:%s  tag:%s  fence %s (%d shapes)", toolname, tagword, session.fence.active ? "ON" : "off", len(session.fence.shapes)), 10, i32(fh) - 46, 14, rl.RAYWHITE)
      rl.DrawText("1/2/3:draw  4:erase  Tab:+/-/!  Ldrag/click  Enter:close-poly  Bksp:undo  Del:clear  A:on/off  E:done", 10, i32(fh) - 24, 14, rl.Color{150, 160, 172, 255})
    }

    // Bottom-left penya readout (just above the bag): a coin glyph + your current gold, comma-grouped.
    // Only shown once 'findpenya' has pinned penya_off and a value has been read. It PULSES RED as you
    // approach the in-game penya ceiling (max i32 = 2,147,483,647) - past that, farmed penya overflows and
    // is lost, so this warns you to bank/spend. Hidden while the fence editor owns this corner.
    if penya_show_s && !edit {
      PENYA_CAP :: i64(2_147_483_647) // max(i32) - the in-game penya cap
      PENYA_WARN :: PENYA_CAP - 25_000_000 // start warning 25M short of it
      py := fh - 42
      txt := fmt.ctprintf("%s", commafy(penya_cur_s))
      coin_col := PENYA_COL
      pfs: i32 = 14
      if penya_cur_s >= PENYA_WARN {
        // Near the cap: hammer it. A fast sine throbs a solid RED bar behind the readout, swells the number
        // hard, and flashes the text yellow->white-hot for contrast. Impossible to miss.
        p := f32(0.5 + 0.5 * math.sin(rl.GetTime() * 9.0))
        pfs = 14 + i32(11 * p)
        radar_alert_bg(6, py, f32(rl.MeasureText(txt, pfs)) + 34, p, {235, 40, 40})
        coin_col = {255, u8(205 + 50 * p), u8(70 + 185 * p), 255} // yellow -> white
      }
      radar_draw_coin(19, py, coin_col)
      rl.DrawText(txt, 31, i32(py) - pfs / 2, pfs, coin_col)
    }

    // Bottom-left bag readout: a small pouch glyph + free/total slots. Hidden while the fence editor owns
    // this corner. Turns orange when the bag is full (0 free). Only shown once 'findinv' has pinned it.
    if inv_have && !edit {
      by := fh - 15
      full := inv_used == inv_cap
      txt := fmt.ctprintf("%d/%d", inv_used, inv_cap)
      bag_col := rl.Color{170, 180, 192, 255}
      fs: i32 = 14
      if full {
        // Full bag: hammer it too - a throbbing ORANGE bar behind the readout, a hard size swell, and the
        // number flashing orange->white. Same loud idiom as the penya cap warning above.
        p := f32(0.5 + 0.5 * math.sin(rl.GetTime() * 8.0))
        fs = 14 + i32(10 * p)
        radar_alert_bg(6, by, f32(rl.MeasureText(txt, fs)) + 34, p, {240, 120, 30})
        bag_col = {255, u8(210 + 45 * p), u8(80 + 175 * p), 255} // orange -> white
      }
      radar_draw_bag(19, by, bag_col)
      // Anchor the number's left edge + vertical center so the size pulse grows in place, not off-corner.
      rl.DrawText(txt, 31, i32(by) - fs / 2, fs, bag_col)
    }

    // Sound mute button (top-left): one-click toggle of the radar SFX. Same state/command path as the
    // Options "Sound" button, just always reachable. Click is gated out of map input via mouse_in_panel.
    mute_hov := rl.CheckCollisionPointRec(mouse, MUTE_BTN_RECT) && !ps.setup_open && !ps.options_open && !ps.leaderboard_open
    rl.DrawRectangleRounded(MUTE_BTN_RECT, 0.5, 6, mute_hov ? rl.Color{54, 72, 94, 235} : rl.Color{26, 34, 44, 210})
    rl.DrawRectangleRoundedLines(MUTE_BTN_RECT, 0.5, 6, rl.Color{70, 84, 100, 255})
    mute_glyph := sfx_on_s ? (mute_hov ? rl.RAYWHITE : rl.Color{170, 180, 192, 255}) : rl.Color{110, 118, 130, 255}
    radar_draw_speaker(MUTE_BTN_RECT.x + 13, MUTE_BTN_RECT.y + 13, !sfx_on_s, mute_glyph)
    if mute_hov && rl.IsMouseButtonPressed(.LEFT) {
      panel_enqueue(&ps, sfx_on_s ? "sfx off" : "sfx on")
    }
    if mute_hov {
      panel_tooltip_lines(MUTE_BTN_RECT.x, MUTE_BTN_RECT.y + 30, {sfx_on_s ? "Sound: ON  (click to mute)" : "Sound: muted  (click to unmute)", "chime on penya pickup, zap on kill"}, fw - PANEL_W - 6)
    }

    // "?" legend badge (replaces the old always-on HUD text): hover for the legend + hotkeys, top-right
    // of the map region. Tooltip-only, so the map stays clean.
    badge := rl.Rectangle{fw - PANEL_W - 40, 8, 28, 26}
    badge_hov := rl.CheckCollisionPointRec(mouse, badge) && !ps.setup_open && !ps.options_open && !ps.leaderboard_open
    rl.DrawRectangleRounded(badge, 0.5, 6, badge_hov ? rl.Color{54, 72, 94, 235} : rl.Color{26, 34, 44, 210})
    rl.DrawRectangleRoundedLines(badge, 0.5, 6, rl.Color{70, 84, 100, 255})
    rl.DrawText("?", i32(badge.x + 10), i32(badge.y + 4), 18, badge_hov ? rl.RAYWHITE : rl.Color{150, 160, 172, 255})
    if badge_hov {
      legend0: cstring = prop_ok_s ? "red: mob   blue: player   grey: pet/npc" : "movers: red (run 'findprop' to tell players/pets apart)"
      lines := []cstring {
        legend0,
        "faded: unreachable   dimmed: outside fence",
        "yellow ring: target   green ring: attack_range",
        "",
        "click: target        shift+click: move",
        "Space: jump          E: fence editor",
        "F: camera overlay    R: reach fade",
        "L: lock on player    C/Home: recenter",
        "RMB-drag: pan        wheel: zoom   ESC: close",
        "",
        "edit mode:  1/2/3: draw   4: erase",
        "  Tab: +include / -exclude / !avoid(no-go)",
        "  A: fence on/off   Enter: close poly",
        "  Bksp: undo   Del: clear   E: done",
      }
      panel_tooltip_lines(badge.x, badge.y + 32, lines[:], fw - PANEL_W - 6)
    }
    rl.EndScissorMode() // end the world/HUD clip; the panel draws over the right strip below

    // === PANEL === (raygui control surface; every session-touching action is deferred to ps.pending
    // and drained under exec_mutex after this frame - see the PANEL section header near the top).
    px := fw - PANEL_W
    rl.DrawRectangle(i32(px), 0, i32(PANEL_W), i32(fh), PANEL_BG)
    rl.DrawLine(i32(px), 0, i32(px), i32(fh), PANEL_SEP)
    x0 := px + 12
    pw := PANEL_W - 24
    y := f32(12)
    rl.GuiUnlock() // clear any stale lock leaked from a prior frame -> panel never gets stuck in DISABLED
    if ps.setup_open || ps.options_open || ps.leaderboard_open {rl.GuiLock()} // freeze the background widgets while a modal is up

    // header + setup status lights + optional pins (hover a missing one for the fix)
    rl.DrawText(fmt.ctprintf("%s", status_hdr), i32(x0), i32(y), 11, PANEL_HDR)
    y += 20
    tooltip: cstring = nil
    for g in groups {
      row := panel_status_light(x0, y, pw, g)
      if !ps.setup_open && !g.ok && rl.CheckCollisionPointRec(mouse, row) {
        tooltip = fmt.ctprintf("%s", g.need)
      }
      y += 17
    }
    y += 3
    rl.DrawText("optional pins", i32(x0), i32(y), 11, PANEL_DIM)
    y += 15
    for g in opins {
      row := panel_status_light(x0, y, pw, g)
      if !ps.setup_open && !g.ok && rl.CheckCollisionPointRec(mouse, row) {
        tooltip = fmt.ctprintf("run: %s", g.need)
      }
      y += 17
    }
    y += 6

    // Setup / Options dialog triggers. While an async setup runs, the row swaps to a live step counter
    // (raygui has no per-widget disable; a label swap sidesteps GuiLock games) - see cli_setup.
    if setup_running_s {
      step_lbl := setup_step_s >= 1 && setup_step_s <= 9 ? SETUP_STEP_LABELS[setup_step_s - 1] : "starting..."
      rl.DrawText(fmt.ctprintf("Setup running... step %d/9", setup_step_s), i32(x0), i32(y), 12, rl.Color{120, 190, 140, 255})
      rl.DrawText(fmt.ctprintf("%s", step_lbl), i32(x0), i32(y + 15), 11, PANEL_DIM)
      y += 36
    } else {
      half := (pw - 10) / 2
      if rl.GuiButton({x0, y, half, 28}, "Setup...") {
        ps.setup_open = true
        ps.name_edit = true
      }
      if rl.GuiButton({x0 + half + 10, y, half, 28}, "Options...") {
        ps.options_open = true
        ps.opt_seeded = false
      }
      y += 36
    }

    // --- AUTO-FARM ---
    rl.DrawLine(i32(x0), i32(y), i32(x0 + pw), i32(y), PANEL_SEP)
    y += 8
    rl.DrawText("PLAY", i32(x0), i32(y), 13, PANEL_HDR)
    y += 18
    toggle_label: cstring = auto_on_s ? "Stop" : "Start"
    if rl.GuiButton({x0, y, pw, 30}, toggle_label) {
      if auto_on_s {
        panel_enqueue(&ps, "auto off") // explicit off (clearer than re-issuing the same set, which toggles)
      } else if len(ps.selected) == 0 {
        panel_enqueue(&ps, "auto any")
      } else {
        sb := strings.builder_make(context.temp_allocator)
        strings.write_string(&sb, "auto ")
        for s, i in ps.selected {
          if i > 0 {strings.write_byte(&sb, ',')}
          strings.write_byte(&sb, '\'')
          strings.write_string(&sb, s)
          strings.write_byte(&sb, '\'')
        }
        panel_enqueue(&ps, strings.to_string(sb))
      }
    }
    y += 36
    if auto_on_s {
      rl.DrawText(fmt.ctprintf("%s: %s", auto_paused_s ? "ARMED" : "ON", auto_desc_s), i32(x0), i32(y), 13, rl.Color{150, 170, 190, 255})
      y += 18
      rl.DrawText(fmt.ctprintf("%s", auto_line_s), i32(x0), i32(y), 17, rl.Color{120, 190, 140, 255})
      y += 23
    } else {
      rl.DrawText(fmt.ctprintf("target: %s", len(ps.selected) == 0 ? "any monster" : "the chips below"), i32(x0), i32(y), 11, PANEL_DIM)
      y += 16
    }
    if penya_total_s > 0 {
      rl.DrawText(fmt.ctprintf("penya: %s", commafy(penya_total_s)), i32(x0), i32(y), 16, PENYA_COL)
      y += 21
    }

    // mob search box + live-filtered suggestions
    rl.DrawText("farm targets (empty = any monster)", i32(x0), i32(y), 11, PANEL_DIM)
    y += 15
    if rl.GuiTextBox({x0, y, pw, 26}, cstring(&ps.search_buf[0]), i32(len(ps.search_buf)), ps.search_edit) {
      ps.search_edit = !ps.search_edit
    }
    y += 30
    search_txt := strings.trim_space(panel_buf_str(ps.search_buf[:]))
    if !ps.setup_open && len(search_txt) > 0 {
      // merged, deduped candidate pool: hardcoded corpus + live nearby names
      pool := make([dynamic]string, context.temp_allocator)
      for n in AUTO_MOB_SUGGESTIONS {panel_add_cand(&pool, n)}
      for n in live_names {panel_add_cand(&pool, n)}
      // "Captain"/"Small" are variant MODIFIERS, not filters: a leading one is stripped so it never
      // excludes any base monster (the whole list stays visible), and it's prepended onto whatever you
      // pick - the badge becomes e.g. "Captain Aibatt". Any text after it still narrows the base list.
      prefix := ""
      rest := search_txt
      low := strings.to_lower(search_txt, context.temp_allocator)
      switch {
      case low == "captain" || strings.has_prefix(low, "captain "):
        prefix = "Captain"
        rest = strings.trim_space(search_txt[len("Captain"):])
      case low == "small" || strings.has_prefix(low, "small "):
        prefix = "Small"
        rest = strings.trim_space(search_txt[len("Small"):])
      }
      prefix_lc_space := ""
      if prefix != "" {prefix_lc_space = fmt.tprintf("%s ", strings.to_lower(prefix, context.temp_allocator))}
      needle := strings.to_lower(rest, context.temp_allocator)
      seen := make([dynamic]string, context.temp_allocator) // composed badges already offered this frame
      shown := 0
      for cand in pool {
        if shown >= 6 {break}
        if len(needle) > 0 && !strings.contains(strings.to_lower(cand, context.temp_allocator), needle) {continue}
        // compose the badge; don't double up if the candidate already carries the modifier
        full := cand
        if prefix != "" && !strings.has_prefix(strings.to_lower(cand, context.temp_allocator), prefix_lc_space) {
          full = fmt.tprintf("%s %s", prefix, cand)
        }
        if panel_name_in(ps.selected[:], full) {continue}
        if panel_name_in(seen[:], full) {continue} // two bases can compose to the same badge - offer it once
        append(&seen, full)
        if rl.GuiButton({x0, y, pw, 22}, fmt.ctprintf("+ %s", full)) {
          append(&ps.selected, strings.clone(full))
          ps.search_buf = {} // clear the box after picking
        }
        y += 24
        shown += 1
      }
      // add the typed text verbatim as a custom chip
      if !panel_name_in(ps.selected[:], search_txt) {
        if rl.GuiButton({x0, y, pw, 22}, fmt.ctprintf("+ add \"%s\"", search_txt)) {
          append(&ps.selected, strings.clone(search_txt))
          ps.search_buf = {}
        }
        y += 24
      }
    }

    // selected chips (wrap across rows; click the x to remove)
    if len(ps.selected) > 0 {
      cx := x0
      chip_h := f32(22)
      for i := 0; i < len(ps.selected); i += 1 {
        cname := ps.selected[i]
        tw := f32(rl.MeasureText(fmt.ctprintf("%s", cname), 12))
        cw := tw + 30
        if cx + cw > x0 + pw {
          cx = x0
          y += chip_h + 4
        }
        rl.DrawRectangleRounded({cx, y, cw, chip_h}, 0.4, 6, CHIP_BG)
        rl.DrawText(fmt.ctprintf("%s", cname), i32(cx + 8), i32(y + 5), 12, rl.RAYWHITE)
        xb := rl.Rectangle{cx + cw - 18, y, 18, chip_h}
        xhov := !ps.setup_open && rl.CheckCollisionPointRec(mouse, xb)
        rl.DrawText("x", i32(cx + cw - 13), i32(y + 5), 12, xhov ? rl.RED : rl.Color{205, 185, 185, 255})
        if xhov && rl.IsMouseButtonPressed(.LEFT) {
          delete(ps.selected[i])
          ordered_remove(&ps.selected, i)
          i -= 1
          continue
        }
        cx += cw + 6
      }
      y += chip_h + 6
    }

    // --- attack_range slider (live ring feedback; persists to flyff.cfg on release) ---
    rl.DrawLine(i32(x0), i32(y), i32(x0 + pw), i32(y), PANEL_SEP)
    y += 8
    rl.DrawText(fmt.ctprintf("attack_range: %.2f  (0-30)", ps.ar_slider), i32(x0), i32(y), 12, PANEL_HDR)
    y += 18
    sl := rl.Rectangle{x0 + 4, y, pw - 8, 18}
    // Empty side labels: raygui draws them OUTSIDE the bar, so "0"/"30" spilled past the panel edge.
    rl.GuiSlider(sl, "", "", &ps.ar_slider, 0, 30)
    if !ps.setup_open && rl.IsMouseButtonDown(.LEFT) && rl.CheckCollisionPointRec(mouse, sl) {
      ps.ar_dragging = true
    }
    if ps.ar_dragging && rl.IsMouseButtonReleased(.LEFT) {
      ps.ar_dragging = false
      panel_enqueue(&ps, fmt.tprintf("set attack_range %.3f", ps.ar_slider))
    }
    y += 26

    // --- MODES (deferred toggles; labels read the locked snapshot, never live session state) ---
    rl.DrawLine(i32(x0), i32(y), i32(x0 + pw), i32(y), PANEL_SEP)
    y += 8
    rl.DrawText("MODES", i32(x0), i32(y), 13, PANEL_HDR)
    y += 18
    bw := (pw - 10) / 2
    if rl.GuiButton({x0, y, bw, 26}, density_on_s ? "Density: ON" : "Density: off") {
      panel_enqueue(&ps, density_on_s ? "density off" : "density on")
    }
    if rl.GuiButton({x0 + bw + 10, y, bw, 26}, preselect_on_s ? "Preselect: ON" : "Preselect: off") {
      panel_enqueue(&ps, preselect_on_s ? "preselect off" : "preselect on")
    }
    y += 30
    if rl.GuiButton({x0, y, bw, 26}, lookalive_on_s ? "Look-alive: ON" : "Look-alive: off") {
      panel_enqueue(&ps, lookalive_on_s ? "lookalive off" : "lookalive on")
    }
    y += 30

    // --- VIEW toolbar (local view state; the fence controls moved to the in-map edit toolbar) ---
    rl.DrawLine(i32(x0), i32(y), i32(x0 + pw), i32(y), PANEL_SEP)
    y += 8
    rl.DrawText("VIEW", i32(x0), i32(y), 13, PANEL_HDR)
    y += 18
    if rl.GuiButton({x0, y, bw, 26}, edit ? "Edit: ON" : "Edit: off") {edit = !edit}
    if rl.GuiButton({x0 + bw + 10, y, bw, 26}, show_cam ? "Camera: ON" : "Camera: off") {show_cam = !show_cam}
    y += 30
    if rl.GuiButton({x0, y, bw, 26}, show_reach ? "Reach: ON" : "Reach: off") {show_reach = !show_reach}
    if rl.GuiButton({x0 + bw + 10, y, bw, 26}, "Recenter") {cam = {ppos[0], ppos[2]}}
    y += 30
    if rl.GuiButton({x0, y, pw, 26}, cam_lock ? "Lock on player: ON" : "Lock on player: off") {cam_lock = !cam_lock}
    y += 30
    if rl.GuiButton({x0, y, pw, 26}, "Jump (Space)") {panel_enqueue(&ps, "jump")}

    // Leaderboards trigger: bottom-center of the sidebar, absolutely positioned (independent of the flow
    // `y` cursor, like MUTE_BTN_RECT), shown ONLY when leaderboard_url is set (lb_configured_s snapshot).
    if lb_configured_s {
      lbw := f32(160)
      lbh := f32(30)
      if rl.GuiButton({px + (PANEL_W - lbw) / 2, fh - lbh - 12, lbw, lbh}, "Leaderboards...") {
        ps.leaderboard_open = true
        ps.lb_seeded = false
      }
    }

    // hovered status-light tooltip (on top of the panel)
    if tooltip != nil {
      tw := rl.MeasureText(tooltip, 12)
      tx := mouse.x + 14
      ty := mouse.y + 6
      if tx + f32(tw) + 10 > fw {tx = fw - f32(tw) - 10}
      rl.DrawRectangle(i32(tx - 4), i32(ty - 3), tw + 10, 20, rl.Color{10, 14, 20, 240})
      rl.DrawRectangleLines(i32(tx - 4), i32(ty - 3), tw + 10, 20, rl.Color{80, 90, 102, 255})
      rl.DrawText(tooltip, i32(tx + 1), i32(ty), 12, rl.RAYWHITE)
    }

    // --- Setup modal (drawn last, on top; background widgets are GuiLock'd above) ---
    if ps.setup_open {
      rl.GuiUnlock()
      rl.DrawRectangle(0, 0, i32(fw), i32(fh), rl.Color{0, 0, 0, 150})
      mw2 := f32(360)
      mh2 := f32(302)
      mx := (fw - mw2) / 2
      my := (fh - mh2) / 2
      rl.GuiPanel({mx, my, mw2, mh2}, "setup <name> [hp]")
      rl.GuiLabel({mx + 14, my + 34, mw2 - 28, 18}, "character name")
      if rl.GuiTextBox({mx + 14, my + 54, mw2 - 28, 28}, cstring(&ps.name_buf[0]), i32(len(ps.name_buf)), ps.name_edit) {
        ps.name_edit = !ps.name_edit
        ps.hp_edit = false
        ps.penya_edit = false
      }
      rl.GuiLabel({mx + 14, my + 92, mw2 - 28, 18}, "current hp (optional)")
      if rl.GuiTextBox({mx + 14, my + 112, mw2 - 28, 28}, cstring(&ps.hp_buf[0]), i32(len(ps.hp_buf)), ps.hp_edit) {
        ps.hp_edit = !ps.hp_edit
        ps.name_edit = false
        ps.penya_edit = false
      }
      // optional penya: if filled, Run setup also fires `findpenya <penya>` to pin penya_off (radar +penya pop)
      rl.GuiLabel({mx + 14, my + 150, mw2 - 28, 18}, "current penya (optional -> +penya pop)")
      if rl.GuiTextBox({mx + 14, my + 170, mw2 - 28, 28}, cstring(&ps.penya_buf[0]), i32(len(ps.penya_buf)), ps.penya_edit) {
        ps.penya_edit = !ps.penya_edit
        ps.name_edit = false
        ps.hp_edit = false
      }
      // standalone penya pin: findpenya alone (fast, so the normal deferred drain is fine) - no need to
      // re-run the whole pipeline just to pin penya_off after a patch.
      if rl.GuiButton({mx + 14, my + 202, mw2 - 28, 26}, "Find penya only") {
        py := strings.trim_space(panel_buf_str(ps.penya_buf[:]))
        py, _ = strings.remove_all(py, ",", context.temp_allocator)
        if len(py) > 0 {
          panel_enqueue(&ps, fmt.tprintf("findpenya %s", py))
          ps.setup_open = false
          ps.name_edit = false
          ps.hp_edit = false
          ps.penya_edit = false
        }
      }
      bw2 := (mw2 - 40) / 2
      if rl.GuiButton({mx + 14, my + mh2 - 40, bw2, 28}, "Run setup") {
        nm := strings.trim_space(panel_buf_str(ps.name_buf[:]))
        if len(nm) > 0 && !setup_running_s {
          // The pipeline runs on a one-shot worker (panel_run_async), NOT the deferred drain - the
          // drain executes on this render thread, which then couldn't draw the step progress.
          cmds := make([dynamic]string, context.temp_allocator)
          hp := strings.trim_space(panel_buf_str(ps.hp_buf[:]))
          append(&cmds, len(hp) > 0 ? fmt.tprintf("setup %s %s", nm, hp) : fmt.tprintf("setup %s", nm))
          // penya isn't derivable from the name anchor (it needs a live value), so it rides as a second
          // command: findpenya pins penya_off from the number you read off the game UI. Commas tolerated.
          py := strings.trim_space(panel_buf_str(ps.penya_buf[:]))
          py, _ = strings.remove_all(py, ",", context.temp_allocator)
          if len(py) > 0 {
            append(&cmds, fmt.tprintf("findpenya %s", py))
          }
          panel_run_async(session, cmds[:])
          ps.setup_open = false
          ps.name_edit = false
          ps.hp_edit = false
          ps.penya_edit = false
        }
      }
      if rl.GuiButton({mx + 26 + bw2, my + mh2 - 40, bw2, 28}, "Cancel") {
        ps.setup_open = false
        ps.name_edit = false
        ps.hp_edit = false
        ps.penya_edit = false
      }
    }

    // --- Options modal (tunables only - raw RVAs/offsets stay CLI-only via `status full` / `set`) ---
    if ps.options_open {
      rl.GuiUnlock()
      rl.DrawRectangle(0, 0, i32(fw), i32(fh), rl.Color{0, 0, 0, 150})
      ow := f32(400)
      oh := f32(772) // panel height (window is 820); content taller than this scrolls (opt_scroll)
      ox := (fw - ow) / 2
      panel_oy := (fh - oh) / 2 // fixed panel top; content is drawn at oy (= panel_oy + scroll)
      if !ps.opt_seeded {
        // seed the textboxes once per open from the locked snapshot of the live values
        panel_buf_set(ps.opt_ar_buf[:], fmt.tprintf("%.2f", opt_ar_cur))
        panel_buf_set(ps.opt_mg_buf[:], fmt.tprintf("%d", opt_mg_cur))
        panel_buf_set(ps.opt_dt_buf[:], fmt.tprintf("%.1f", opt_dt_cur))
        panel_buf_set(ps.opt_lahmin_buf[:], fmt.tprintf("%.1f", opt_lahmin_cur))
        panel_buf_set(ps.opt_lahmax_buf[:], fmt.tprintf("%.1f", opt_lahmax_cur))
        panel_buf_set(ps.opt_lajmin_buf[:], fmt.tprintf("%.1f", opt_lajmin_cur))
        panel_buf_set(ps.opt_lajmax_buf[:], fmt.tprintf("%.1f", opt_lajmax_cur))
        panel_buf_set(ps.opt_lajch_buf[:], fmt.tprintf("%d", opt_lajch_cur))
        panel_buf_set(ps.opt_lastepch_buf[:], fmt.tprintf("%d", opt_lastepch_cur))
        panel_buf_set(ps.opt_lastepsp_buf[:], fmt.tprintf("%.1f", opt_lastepsp_cur))
        panel_buf_set(ps.opt_lamaxr_buf[:], fmt.tprintf("%.1f", opt_lamaxr_cur))
        ps.opt_seeded = true
        ps.opt_scroll = 0 // reopen at the top
      }
      rl.GuiPanel({ox, panel_oy, ow, oh}, "options")
      // Scrollable content: the title bar stays fixed at the top and the Apply/Close bar at the bottom;
      // everything between scrolls when it's taller than the viewport. Wheel over the modal scrolls; the
      // content is clipped to the viewport and its input is gated to it (so a scrolled-out widget under the
      // title/footer can't be clicked). opt_content_h is measured at the end of the content for the clamp.
      title_h := f32(28)
      footer_h := f32(44)
      view_top := panel_oy + title_h
      view_h := oh - title_h - footer_h
      max_scroll := max(ps.opt_content_h - view_h, 0)
      if rl.CheckCollisionPointRec(mouse, {ox, panel_oy, ow, oh}) {
        ps.opt_scroll += rl.GetMouseWheelMove() * 28
      }
      ps.opt_scroll = clamp(ps.opt_scroll, -max_scroll, 0)
      oy := panel_oy + ps.opt_scroll // content anchor (scrolls); all content below is drawn relative to it
      content_view := rl.Rectangle{ox, view_top, ow, view_h}
      in_view := rl.CheckCollisionPointRec(mouse, content_view) // gates the sliders' grab + tooltips to the viewport
      rl.BeginScissorMode(i32(ox), i32(view_top), i32(ow), i32(view_h))
      col_w := (ow - 3 * OPT_PAD) / 2
      // Hover explanation for whichever config value the cursor is over (drawn on top at the end). Each
      // check uses the label+widget rect; otip holds the last hovered item's lines this frame.
      otip: []cstring = nil
      hov :: proc(mouse: rl.Vector2, r: rl.Rectangle, lines: []cstring, otip: ^[]cstring) {
        if rl.CheckCollisionPointRec(mouse, r) {otip^ = lines}
      }
      // numeric tunables (one Apply commits all three; unchanged values are skipped)
      rl.GuiLabel({ox + OPT_PAD, oy + 34, col_w, 18}, "attack_range")
      if rl.GuiTextBox({ox + OPT_PAD, oy + 54, col_w, 26}, cstring(&ps.opt_ar_buf[0]), i32(len(ps.opt_ar_buf)), ps.opt_ar_edit) {
        was := ps.opt_ar_edit
        panel_opt_clear_edits(&ps)
        ps.opt_ar_edit = !was
      }
      hov(mouse, {ox + OPT_PAD, oy + 34, col_w, 46}, {
        "attack_range - your character's MAX attack reach, in world units.",
        "Mobs within this distance of you count as 'in range' and are killed",
        "without moving; the picker only walks when nothing is inside it.",
        "Set it to your REAL hit range (e.g. 16.1). Too small: it walks to",
        "mobs it could already hit. Too big: it treats far mobs as in-range.",
      }, &otip)
      rl.GuiLabel({ox + 2 * OPT_PAD + col_w, oy + 34, col_w, 18}, "density mingain")
      if rl.GuiTextBox({ox + 2 * OPT_PAD + col_w, oy + 54, col_w, 26}, cstring(&ps.opt_mg_buf[0]), i32(len(ps.opt_mg_buf)), ps.opt_mg_edit) {
        was := ps.opt_mg_edit
        panel_opt_clear_edits(&ps)
        ps.opt_mg_edit = !was
      }
      hov(mouse, {ox + 2 * OPT_PAD + col_w, oy + 34, col_w, 46}, {
        "density mingain - cluster-steering gate 1 (only used when Density is ON).",
        "How many MORE members a farther pack must have before the picker",
        "detours to it instead of taking the nearest mob. Default 3. Higher =",
        "more reluctant to switch packs.",
      }, &otip)
      rl.GuiLabel({ox + OPT_PAD, oy + 88, col_w, 18}, "density detour")
      if rl.GuiTextBox({ox + OPT_PAD, oy + 108, col_w, 26}, cstring(&ps.opt_dt_buf[0]), i32(len(ps.opt_dt_buf)), ps.opt_dt_edit) {
        was := ps.opt_dt_edit
        panel_opt_clear_edits(&ps)
        ps.opt_dt_edit = !was
      }
      hov(mouse, {ox + OPT_PAD, oy + 88, col_w, 46}, {
        "density detour - cluster-steering gate 2 (only used when Density is ON).",
        "The MAX extra walk distance (world units) the picker will take to",
        "reach a denser pack instead of the nearest mob. Default 20. Higher =",
        "willing to travel further for a bigger pack.",
      }, &otip)
      // mode toggles (immediate; same deferred-command pattern as the sidebar)
      ty0 := oy + 150
      rl.GuiLabel({ox + OPT_PAD, ty0, ow - 2 * OPT_PAD, 18}, "modes")
      ty0 += 22
      if rl.GuiButton({ox + OPT_PAD, ty0, col_w, 26}, density_on_s ? "Density: ON" : "Density: off") {
        panel_enqueue(&ps, density_on_s ? "density off" : "density on")
      }
      hov(mouse, {ox + OPT_PAD, ty0, col_w, 26}, {
        "Density - cluster steering. ON: commit to a mob pack until it's wiped,",
        "and only detour to a denser pack past the mingain + detour gates.",
        "OFF (default): just target the nearest eligible mob.",
      }, &otip)
      if rl.GuiButton({ox + 2 * OPT_PAD + col_w, ty0, col_w, 26}, preselect_on_s ? "Preselect: ON" : "Preselect: off") {
        panel_enqueue(&ps, preselect_on_s ? "preselect off" : "preselect on")
      }
      hov(mouse, {ox + 2 * OPT_PAD + col_w, ty0, col_w, 26}, {
        "Preselect - precompute the NEXT target while you fight the current one,",
        "so auto advances the instant it dies (removes the ~0.5s post-kill gap).",
        "On by default. Turn off to go back to scanning after each kill.",
      }, &otip)
      ty0 += 30
      if rl.GuiButton({ox + OPT_PAD, ty0, col_w, 26}, lookalive_on_s ? "Look-alive: ON" : "Look-alive: off") {
        panel_enqueue(&ps, lookalive_on_s ? "lookalive off" : "lookalive on")
      }
      hov(mouse, {ox + OPT_PAD, ty0, col_w, 26}, {
        "Look-alive - human-like farming for low-spawn quests: a random delay",
        "before locking each new target + occasional jumps while traveling.",
        "Deliberately less efficient - off by default. Jumps need 'findmove'.",
      }, &otip)
      if rl.GuiButton({ox + 2 * OPT_PAD + col_w, ty0, col_w, 26}, reach_gate_s ? "Reach-gate: ON" : "Reach-gate: off") {
        panel_enqueue(&ps, reach_gate_s ? "reachgate off" : "reachgate on")
      }
      hov(mouse, {ox + 2 * OPT_PAD + col_w, ty0, col_w, 26}, {
        "Reach-gate - before targeting, skip mobs whose straight path to you is",
        "blocked by terrain or an object. On by default. Turn OFF if it wrongly",
        "marks reachable mobs as blocked (e.g. it targets nothing in the tower).",
      }, &otip)
      ty0 += 30
      if rl.GuiButton({ox + OPT_PAD, ty0, col_w, 26}, stuck_on_s ? "Stuck-detect: ON" : "Stuck-detect: off") {
        panel_enqueue(&ps, stuck_on_s ? "stuck off" : "stuck on")
      }
      hov(mouse, {ox + OPT_PAD, ty0, col_w, 26}, {
        "Stuck-detect - if the character jams on an obstacle (distance to the",
        "target stops dropping while still far), blacklist that mob and pick",
        "another. On by default; turn off for ranged/standing playstyles.",
      }, &otip)
      if rl.GuiButton({ox + 2 * OPT_PAD + col_w, ty0, col_w, 26}, hunt_s ? "Hunt: ON" : "Hunt: off") {
        panel_enqueue(&ps, hunt_s ? "hunt off" : "hunt on")
      }
      hov(mouse, {ox + 2 * OPT_PAD + col_w, ty0, col_w, 26}, {
        "Hunt - commit to ONE target (a giant, a quest mob) and never drop it for",
        "being far or unreachable: keep walking in, and side-step around obstacles",
        "instead of skipping. Off by default (farming). Side-step needs 'findmove'.",
      }, &otip)
      ty0 += 40
      rl.GuiLabel({ox + OPT_PAD, ty0, ow - 2 * OPT_PAD, 18}, "radar juice")
      ty0 += 22
      if rl.GuiButton({ox + OPT_PAD, ty0, col_w, 26}, sfx_on_s ? "Sound: ON" : "Sound: off") {
        panel_enqueue(&ps, sfx_on_s ? "sfx off" : "sfx on")
      }
      hov(mouse, {ox + OPT_PAD, ty0, col_w, 26}, {
        "Sound - radar sound effects: a chime on penya pickup and a zap on kill.",
        "Only plays while the radar window is open.",
      }, &otip)
      if rl.GuiButton({ox + 2 * OPT_PAD + col_w, ty0, col_w, 26}, fx_laser_s ? "Laser FX: ON" : "Laser FX: off") {
        panel_enqueue(&ps, fx_laser_s ? "fxlaser off" : "fxlaser on")
      }
      hov(mouse, {ox + 2 * OPT_PAD + col_w, ty0, col_w, 26}, {
        "Laser FX - radar visual: a short beam drawn from you to each mob you kill.",
      }, &otip)
      ty0 += 30
      if rl.GuiButton({ox + OPT_PAD, ty0, col_w, 26}, density_hue_s ? "Density hue: ON" : "Density hue: off") {
        panel_enqueue(&ps, density_hue_s ? "density hue off" : "density hue on")
      }
      hov(mouse, {ox + OPT_PAD, ty0, col_w, 26}, {
        "Density hue - tint each monster dot by how crowded its spot is (local",
        "pack size within the density radius): lone stays red, denser packs",
        "shift toward green. Display only - it does not change targeting.",
      }, &otip)
      if rl.GuiButton({ox + 2 * OPT_PAD + col_w, ty0, col_w, 26}, trail_s ? "Trail: ON" : "Trail: off") {
        panel_enqueue(&ps, trail_s ? "trail off" : "trail on")
      }
      hov(mouse, {ox + 2 * OPT_PAD + col_w, ty0, col_w, 26}, {
        "Trail - a subtle fading breadcrumb behind your dot showing where you've",
        "walked. Off by default. Tune length + fade with the sliders below. Display",
        "only, drawn under the mob dots so it never masks a target.",
      }, &otip)
      ty0 += 30
      if rl.GuiButton({ox + OPT_PAD, ty0, col_w, 26}, hillshade_on_s ? "Hillshade: ON" : "Hillshade: off") {
        panel_enqueue(&ps, hillshade_on_s ? "hillshade off" : "hillshade on")
      }
      hov(mouse, {ox + OPT_PAD, ty0, col_w, 26}, {
        "Hillshade - colourless shaded relief of the terrain (lit from the NW), drawn",
        "under the dots. Shows hills/cliffs/ramps via light + shadow, no added colour.",
        "Needs 'worldscan'. Depth: 'set hillshade_z'; light dir: 'set hillshade_light'. Key: H.",
      }, &otip)
      // vision radius slider (world units): how far the radar gathers/draws mob dots. Same seed/drag/
      // persist-on-release dance as the sidebar attack_range slider (the locked block seeds ps.rr_slider
      // and, while dragging, pushes it into the layout so view_r grows live).
      ty0 += 40
      // Range folded into the header (not the slider's side labels, which raygui draws OUTSIDE the bar and
      // would overflow the panel) so the whole widget stays within the uniform padding.
      rl.GuiLabel({ox + OPT_PAD, ty0, ow - 2 * OPT_PAD, 18}, fmt.ctprintf("vision radius: %.0f  (mob dots, %.0f-%.0f)", ps.rr_slider, RADAR_RANGE_MIN, RADAR_RANGE_MAX))
      ty0 += 22
      rr_sl := rl.Rectangle{ox + OPT_PAD, ty0, ow - 2 * OPT_PAD, 18}
      rl.GuiSlider(rr_sl, "", "", &ps.rr_slider, RADAR_RANGE_MIN, RADAR_RANGE_MAX)
      if in_view && rl.IsMouseButtonDown(.LEFT) && rl.CheckCollisionPointRec(mouse, rr_sl) {
        ps.rr_dragging = true
      }
      if ps.rr_dragging && rl.IsMouseButtonReleased(.LEFT) {
        ps.rr_dragging = false
        panel_enqueue(&ps, fmt.tprintf("set radar_range %.1f", ps.rr_slider))
      }
      hov(mouse, rr_sl, {
        "Vision radius - how far (world units) the radar gathers and draws mob dots.",
        "Default 80. Bigger = see farther, but you still only see mobs the game has",
        "loaded around you. Obstacle boxes use a separate fixed radius, unaffected.",
      }, &otip)
      // player-trail sliders (length + fade). Same seed/drag/persist-on-release dance as the vision slider
      // (the locked block seeds ps.tr_slider/ps.tf_slider and pushes them into the layout while dragging).
      ty0 += 40
      rl.GuiLabel({ox + OPT_PAD, ty0, ow - 2 * OPT_PAD, 18}, fmt.ctprintf("trail length: %.0f  (world units, 0-800)", ps.tr_slider))
      ty0 += 22
      tr_sl := rl.Rectangle{ox + OPT_PAD, ty0, ow - 2 * OPT_PAD, 18}
      rl.GuiSlider(tr_sl, "", "", &ps.tr_slider, 0, 800)
      if in_view && rl.IsMouseButtonDown(.LEFT) && rl.CheckCollisionPointRec(mouse, tr_sl) {
        ps.tr_dragging = true
      }
      if ps.tr_dragging && rl.IsMouseButtonReleased(.LEFT) {
        ps.tr_dragging = false
        panel_enqueue(&ps, fmt.tprintf("set trail_len %.1f", ps.tr_slider))
      }
      hov(mouse, tr_sl, {
        "Trail length - how far back (world units) the trail extends before it has",
        "fully faded to nothing. Longer = a longer tail. Only visible while Trail is on.",
      }, &otip)
      ty0 += 40
      rl.GuiLabel({ox + OPT_PAD, ty0, ow - 2 * OPT_PAD, 18}, fmt.ctprintf("trail fade: %.2f  (1 = even, higher = fades faster)", ps.tf_slider))
      ty0 += 22
      tf_sl := rl.Rectangle{ox + OPT_PAD, ty0, ow - 2 * OPT_PAD, 18}
      rl.GuiSlider(tf_sl, "", "", &ps.tf_slider, 0.25, 4.0)
      if in_view && rl.IsMouseButtonDown(.LEFT) && rl.CheckCollisionPointRec(mouse, tf_sl) {
        ps.tf_dragging = true
      }
      if ps.tf_dragging && rl.IsMouseButtonReleased(.LEFT) {
        ps.tf_dragging = false
        panel_enqueue(&ps, fmt.tprintf("set trail_fade %.2f", ps.tf_slider))
      }
      hov(mouse, tf_sl, {
        "Trail fade - how fast the trail fades with distance from you. 1 = even",
        "falloff; higher = fades faster (visible only near you); lower = stays",
        "visible further out along the tail.",
      }, &otip)
      // --- look-alive tuning (only takes effect while Look-alive is ON; committed by Apply) ---
      ty0 += 40
      rl.DrawLine(i32(ox + OPT_PAD), i32(ty0), i32(ox + ow - OPT_PAD), i32(ty0), PANEL_SEP)
      ty0 += 8
      rl.DrawText(fmt.ctprintf("look-alive%s", lookalive_on_s ? "" : "  (mode is off)"), i32(ox + OPT_PAD), i32(ty0), 13, PANEL_HDR)
      ty0 += 22
      // Per-feature enables (each sub-behavior toggles independently under the master mode). Same
      // deferred-command pattern as the MODES toggles above; step + max-range need 'findmove' to walk.
      if rl.GuiButton({ox + OPT_PAD, ty0, col_w, 26}, la_hesitate_s ? "Hesitation: ON" : "Hesitation: off") {
        panel_enqueue(&ps, la_hesitate_s ? "lookalive hesitate off" : "lookalive hesitate on")
      }
      hov(mouse, {ox + OPT_PAD, ty0, col_w, 26}, {
        "Hesitation - a random pause before locking each new target after a kill.",
        "Off = lock the next target immediately (no reaction delay).",
      }, &otip)
      if rl.GuiButton({ox + 2 * OPT_PAD + col_w, ty0, col_w, 26}, la_jump_s ? "Jump: ON" : "Jump: off") {
        panel_enqueue(&ps, la_jump_s ? "lookalive jump off" : "lookalive jump on")
      }
      hov(mouse, {ox + 2 * OPT_PAD + col_w, ty0, col_w, 26}, {
        "Jump - sporadic jumps while travelling to a target. Needs 'findmove'.",
        "Off = never jump.",
      }, &otip)
      ty0 += 30
      if rl.GuiButton({ox + OPT_PAD, ty0, col_w, 26}, la_step_s ? "Int. step: ON" : "Int. step: off") {
        panel_enqueue(&ps, la_step_s ? "lookalive step off" : "lookalive step on")
      }
      hov(mouse, {ox + OPT_PAD, ty0, col_w, 26}, {
        "Intermediate step - sometimes walk to an offset waypoint partway to the mob",
        "before locking on, instead of beelining. Chance-gated (step chance). Needs",
        "'findmove'. Off = walk straight in.",
      }, &otip)
      if rl.GuiButton({ox + 2 * OPT_PAD + col_w, ty0, col_w, 26}, la_maxrange_s ? "Max-range: ON" : "Max-range: off") {
        panel_enqueue(&ps, la_maxrange_s ? "lookalive maxrange off" : "lookalive maxrange on")
      }
      hov(mouse, {ox + 2 * OPT_PAD + col_w, ty0, col_w, 26}, {
        "Max-range - for far spawns, approach in shrinking, slightly zig-zagged hops",
        "until inside 'max range', then lock (instead of a long straight beeline).",
        "Needs 'findmove'. Off = beeline any distance.",
      }, &otip)
      ty0 += 34
      // Row 1 - hesitation window (delayed lock-on before each new target), seconds.
      rl.GuiLabel({ox + OPT_PAD, ty0, col_w, 18}, "hesitate min (s)")
      rl.GuiLabel({ox + 2 * OPT_PAD + col_w, ty0, col_w, 18}, "hesitate max (s)")
      ty0 += 18
      if rl.GuiTextBox({ox + OPT_PAD, ty0, col_w, 26}, cstring(&ps.opt_lahmin_buf[0]), i32(len(ps.opt_lahmin_buf)), ps.opt_lahmin_edit) {
        was := ps.opt_lahmin_edit
        panel_opt_clear_edits(&ps)
        ps.opt_lahmin_edit = !was
      }
      if rl.GuiTextBox({ox + 2 * OPT_PAD + col_w, ty0, col_w, 26}, cstring(&ps.opt_lahmax_buf[0]), i32(len(ps.opt_lahmax_buf)), ps.opt_lahmax_edit) {
        was := ps.opt_lahmax_edit
        panel_opt_clear_edits(&ps)
        ps.opt_lahmax_edit = !was
      }
      hov(mouse, {ox + OPT_PAD, ty0 - 18, ow - 2 * OPT_PAD, 44}, {
        "Hesitation - a random pause in this range before the picker locks onto each",
        "NEW target after a kill (a human-like reaction delay, not an instant snap).",
        "Seconds. e.g. 0.8 to 3.0. Bigger = lazier / more AFK-looking farming.",
      }, &otip)
      ty0 += 34
      // Row 2 - travel-jump interval, seconds.
      rl.GuiLabel({ox + OPT_PAD, ty0, col_w, 18}, "jump every min (s)")
      rl.GuiLabel({ox + 2 * OPT_PAD + col_w, ty0, col_w, 18}, "jump every max (s)")
      ty0 += 18
      if rl.GuiTextBox({ox + OPT_PAD, ty0, col_w, 26}, cstring(&ps.opt_lajmin_buf[0]), i32(len(ps.opt_lajmin_buf)), ps.opt_lajmin_edit) {
        was := ps.opt_lajmin_edit
        panel_opt_clear_edits(&ps)
        ps.opt_lajmin_edit = !was
      }
      if rl.GuiTextBox({ox + 2 * OPT_PAD + col_w, ty0, col_w, 26}, cstring(&ps.opt_lajmax_buf[0]), i32(len(ps.opt_lajmax_buf)), ps.opt_lajmax_edit) {
        was := ps.opt_lajmax_edit
        panel_opt_clear_edits(&ps)
        ps.opt_lajmax_edit = !was
      }
      hov(mouse, {ox + OPT_PAD, ty0 - 18, ow - 2 * OPT_PAD, 44}, {
        "Jump interval - the random gap between travel-jump attempts while walking to",
        "a target (jumps only happen far from the mob, not in melee). Seconds, e.g.",
        "4 to 12. Needs 'findmove'; without it jumps are skipped.",
      }, &otip)
      ty0 += 34
      // Row 3 - jump chance (left) + step chance (right), percent.
      rl.GuiLabel({ox + OPT_PAD, ty0, col_w, 18}, "jump chance (%)")
      rl.GuiLabel({ox + 2 * OPT_PAD + col_w, ty0, col_w, 18}, "step chance (%)")
      ty0 += 18
      if rl.GuiTextBox({ox + OPT_PAD, ty0, col_w, 26}, cstring(&ps.opt_lajch_buf[0]), i32(len(ps.opt_lajch_buf)), ps.opt_lajch_edit) {
        was := ps.opt_lajch_edit
        panel_opt_clear_edits(&ps)
        ps.opt_lajch_edit = !was
      }
      if rl.GuiTextBox({ox + 2 * OPT_PAD + col_w, ty0, col_w, 26}, cstring(&ps.opt_lastepch_buf[0]), i32(len(ps.opt_lastepch_buf)), ps.opt_lastepch_edit) {
        was := ps.opt_lastepch_edit
        panel_opt_clear_edits(&ps)
        ps.opt_lastepch_edit = !was
      }
      hov(mouse, {ox + OPT_PAD, ty0 - 18, col_w, 44}, {
        "Jump chance - the odds (0-100%) that any scheduled jump window actually fires.",
        "Below 100 makes jumping sporadic instead of a steady metronome. Default 65.",
        "0 = never jump; 100 = jump on every window.",
      }, &otip)
      hov(mouse, {ox + 2 * OPT_PAD + col_w, ty0 - 18, col_w, 44}, {
        "Step chance - the odds (0-100%) that an advance takes a single intermediate",
        "detour step (Int. step must be ON). Default 40. 0 = never; 100 = every time.",
      }, &otip)
      ty0 += 34
      // Row 4 - step spread (left) + max range (right), world units.
      rl.GuiLabel({ox + OPT_PAD, ty0, col_w, 18}, "step spread (u)")
      rl.GuiLabel({ox + 2 * OPT_PAD + col_w, ty0, col_w, 18}, "max range (u)")
      ty0 += 18
      if rl.GuiTextBox({ox + OPT_PAD, ty0, col_w, 26}, cstring(&ps.opt_lastepsp_buf[0]), i32(len(ps.opt_lastepsp_buf)), ps.opt_lastepsp_edit) {
        was := ps.opt_lastepsp_edit
        panel_opt_clear_edits(&ps)
        ps.opt_lastepsp_edit = !was
      }
      if rl.GuiTextBox({ox + 2 * OPT_PAD + col_w, ty0, col_w, 26}, cstring(&ps.opt_lamaxr_buf[0]), i32(len(ps.opt_lamaxr_buf)), ps.opt_lamaxr_edit) {
        was := ps.opt_lamaxr_edit
        panel_opt_clear_edits(&ps)
        ps.opt_lamaxr_edit = !was
      }
      hov(mouse, {ox + OPT_PAD, ty0 - 18, col_w, 44}, {
        "Step spread - max sideways offset (world units) of an approach waypoint from the",
        "straight line to the mob. Bigger = wider, more wandering detours. Default 8.",
      }, &otip)
      hov(mouse, {ox + 2 * OPT_PAD + col_w, ty0 - 18, col_w, 44}, {
        "Max range - the 'too far to beeline' distance (world units). Beyond it, Max-range",
        "approaches in shrinking hops until inside this, then locks. Default 40.",
      }, &otip)
      ty0 += 34
      // End scrollable content: measure its intrinsic height (scroll-independent - ty0 flows from oy) for
      // next frame's scroll clamp, close the clip + input gate, then draw the fixed footer + scrollbar hint.
      ps.opt_content_h = (ty0 - oy) + OPT_PAD
      rl.EndScissorMode()
      if max_scroll > 0 { // scrollbar thumb on the right edge (only when content overflows)
        thumb_h := view_h * (view_h / ps.opt_content_h)
        thumb_y := view_top + (-ps.opt_scroll / max_scroll) * (view_h - thumb_h)
        rl.DrawRectangleRounded({ox + ow - 6, thumb_y, 4, thumb_h}, 0.5, 4, rl.Color{140, 150, 165, 200})
      }
      // Apply + Close (fixed footer, anchored to the panel not the scrolled content)
      bw3 := (ow - 3 * OPT_PAD) / 2
      if rl.GuiButton({ox + OPT_PAD, panel_oy + oh - OPT_PAD - 28, bw3, 28}, "Apply values") {
        ar_txt := strings.trim_space(panel_buf_str(ps.opt_ar_buf[:]))
        if v, vok := strconv.parse_f64(ar_txt); vok && v >= 0 && f32(v) != opt_ar_cur {
          panel_enqueue(&ps, fmt.tprintf("set attack_range %.3f", v))
        }
        mg_txt := strings.trim_space(panel_buf_str(ps.opt_mg_buf[:]))
        if n, nok := strconv.parse_int(mg_txt); nok && n >= 0 && n != opt_mg_cur {
          panel_enqueue(&ps, fmt.tprintf("density mingain %d", n))
        }
        dt_txt := strings.trim_space(panel_buf_str(ps.opt_dt_buf[:]))
        if v, vok := strconv.parse_f64(dt_txt); vok && v >= 0 && f32(v) != opt_dt_cur {
          panel_enqueue(&ps, fmt.tprintf("density detour %v", f32(v)))
        }
        // look-alive hesitation window (one command sets both ends; enqueue if either changed)
        hmin_txt := strings.trim_space(panel_buf_str(ps.opt_lahmin_buf[:]))
        hmax_txt := strings.trim_space(panel_buf_str(ps.opt_lahmax_buf[:]))
        if lo, lok := strconv.parse_f64(hmin_txt); lok && lo >= 0 {
          if hi, hik := strconv.parse_f64(hmax_txt); hik && hi >= 0 {
            if f32(lo) != opt_lahmin_cur || f32(hi) != opt_lahmax_cur {
              panel_enqueue(&ps, fmt.tprintf("lookalive hold %v %v", f32(lo), f32(hi)))
            }
          }
        }
        // look-alive travel-jump interval
        jmin_txt := strings.trim_space(panel_buf_str(ps.opt_lajmin_buf[:]))
        jmax_txt := strings.trim_space(panel_buf_str(ps.opt_lajmax_buf[:]))
        if lo, lok := strconv.parse_f64(jmin_txt); lok && lo >= 0 {
          if hi, hik := strconv.parse_f64(jmax_txt); hik && hi >= 0 {
            if f32(lo) != opt_lajmin_cur || f32(hi) != opt_lajmax_cur {
              panel_enqueue(&ps, fmt.tprintf("lookalive jump %v %v", f32(lo), f32(hi)))
            }
          }
        }
        // look-alive jump chance (percent, clamped 0-100)
        ch_txt := strings.trim_space(panel_buf_str(ps.opt_lajch_buf[:]))
        if n, nok := strconv.parse_int(ch_txt); nok && n >= 0 && n <= 100 && n != opt_lajch_cur {
          panel_enqueue(&ps, fmt.tprintf("lookalive chance %d", n))
        }
        // look-alive step chance (percent, clamped 0-100)
        stepch_txt := strings.trim_space(panel_buf_str(ps.opt_lastepch_buf[:]))
        if n, nok := strconv.parse_int(stepch_txt); nok && n >= 0 && n <= 100 && n != opt_lastepch_cur {
          panel_enqueue(&ps, fmt.tprintf("lookalive step chance %d", n))
        }
        // look-alive step spread (world units)
        stepsp_txt := strings.trim_space(panel_buf_str(ps.opt_lastepsp_buf[:]))
        if v, vok := strconv.parse_f64(stepsp_txt); vok && v >= 0 && f32(v) != opt_lastepsp_cur {
          panel_enqueue(&ps, fmt.tprintf("lookalive step spread %v", f32(v)))
        }
        // look-alive max-range approach distance (world units)
        maxr_txt := strings.trim_space(panel_buf_str(ps.opt_lamaxr_buf[:]))
        if v, vok := strconv.parse_f64(maxr_txt); vok && v >= 0 && f32(v) != opt_lamaxr_cur {
          panel_enqueue(&ps, fmt.tprintf("lookalive maxrange %v", f32(v)))
        }
        ps.opt_seeded = false // re-seed next frame so the boxes reflect what actually applied
      }
      if rl.GuiButton({ox + 2 * OPT_PAD + bw3, panel_oy + oh - OPT_PAD - 28, bw3, 28}, "Close") {
        ps.options_open = false
        panel_opt_clear_edits(&ps)
      }
      // Hovered-value explanation, drawn last so it sits on top of the modal. Positioned below the
      // cursor, or above it near the screen bottom, and clamped to the screen width. Suppressed when the
      // cursor is outside the scrollable viewport (a scrolled-out widget under the title/footer must not
      // pop its tooltip).
      if otip != nil && in_view {
        ty := mouse.y + 18
        if ty + f32(len(otip) * 16 + 8) > fh {
          ty = mouse.y - f32(len(otip) * 16 + 8) - 6
        }
        panel_tooltip_lines(mouse.x + 14, ty, otip, fw)
      }
    }

    // --- Leaderboards modal (submit a timed run + browse the board; trigger gated on leaderboard_url) ---
    if ps.leaderboard_open {
      rl.GuiUnlock()
      rl.DrawRectangle(0, 0, i32(fw), i32(fh), rl.Color{0, 0, 0, 150})
      lw := f32(474)
      lh := f32(590)
      lx := (fw - lw) / 2
      ly := (fh - lh) / 2
      rl.GuiPanel({lx, ly, lw, lh}, "leaderboards")
      ix := lx + 14
      iw := lw - 28
      yy := ly + 34
      if !ps.lb_seeded {
        ps.lb_seeded = true
        ps.lb_sort = i32(lb_board_sort_s) // reflect whatever sort the board currently holds
        ps.lb_name_edit = false
      }

      // RECORDING group: name box + Start/Stop + Submit + live stats.
      rl.DrawText("RECORDING", i32(ix), i32(yy), 13, PANEL_HDR)
      yy += 20
      if rl.GuiTextBox({ix, yy, iw, 28}, cstring(&ps.lb_name_buf[0]), i32(len(ps.lb_name_buf)), ps.lb_name_edit) {
        ps.lb_name_edit = !ps.lb_name_edit
      }
      rl.DrawText("name shown on the board", i32(ix), i32(yy + 30), 10, PANEL_DIM)
      yy += 48
      lbhalf := (iw - 10) / 2
      start_lbl: cstring = lb_active_s ? "Stop recording" : "Start recording"
      if rl.GuiButton({ix, yy, lbhalf, 28}, start_lbl) {
        panel_enqueue(&ps, lb_active_s ? "leaderboard stop" : "leaderboard start")
      }
      nm_typed := strings.trim_space(panel_buf_str(ps.lb_name_buf[:]))
      submit_ready := lb_has_run_s && lb_elapsed_s >= LB_MIN_SEC && !lb_busy_s && !lb_submitted_s && nm_typed != ""
      submit_rect := rl.Rectangle{ix + lbhalf + 10, yy, lbhalf, 28}
      if !submit_ready {rl.GuiDisable()}
      if rl.GuiButton(submit_rect, "Submit run") {
        clean, _ := strings.remove_all(nm_typed, ";", context.temp_allocator) // guard the ';' command splitter
        panel_enqueue(&ps, fmt.tprintf("leaderboard submit %s", clean))
      }
      if !submit_ready {rl.GuiEnable()}
      // Explain WHY submit is greyed out (drawn on top at the end of the modal so nothing covers it).
      submit_tip: cstring = nil
      if !submit_ready && rl.CheckCollisionPointRec(mouse, submit_rect) {
        if !lb_has_run_s {
          submit_tip = "Press \"Start recording\" first."
        } else if lb_submitted_s {
          submit_tip = "This run is already on the board - Start a new run to submit again."
        } else if nm_typed == "" {
          submit_tip = "Enter a name to appear on the board."
        } else if lb_busy_s {
          submit_tip = "A submission is already in flight..."
        } else {
          rem := LB_MIN_SEC - lb_elapsed_s
          submit_tip = fmt.ctprintf("Record at least %d min to submit - %d:%02d more to go.", LB_MIN_SEC / 60, rem / 60, rem % 60)
        }
      }
      yy += 34
      run_state := lb_active_s ? "RECORDING" : (lb_has_run_s ? "stopped" : "idle")
      rl.DrawText(fmt.ctprintf("%s   %s   %d kills   %d penya", run_state, fmt_elapsed(i64(lb_elapsed_s) * 1_000_000_000), lb_kills_s, lb_penya_s), i32(ix), i32(yy), 11, rl.RAYWHITE)
      yy += 16
      if lb_elapsed_s >= LB_MIN_SEC {
        rl.DrawText(fmt.ctprintf("%.1f kpm   peak-density %d   %d species   -   READY to submit", lb_kpm_s, lb_density_s, lb_species_s), i32(ix), i32(yy), 11, PANEL_DIM)
      } else {
        rem := LB_MIN_SEC - lb_elapsed_s
        rl.DrawText(fmt.ctprintf("%.1f kpm   peak-density %d   %d species   -   %d:%02d until submit", lb_kpm_s, lb_density_s, lb_species_s, rem / 60, rem % 60), i32(ix), i32(yy), 11, PANEL_DIM)
      }
      yy += 22
      rl.DrawLine(i32(ix), i32(yy), i32(ix + iw), i32(yy), PANEL_SEP)
      yy += 8

      // BOARD group: sort toggle (re-fetches on change) + Refresh + rows with a per-row "cfg" download.
      rl.DrawText("BOARD", i32(ix), i32(yy), 13, PANEL_HDR)
      if rl.GuiButton({ix + iw - 80, yy - 4, 80, 22}, "Refresh") {
        panel_enqueue(&ps, fmt.tprintf("leaderboard refresh %s", LB_SORTS[clamp(int(ps.lb_sort), 0, len(LB_SORTS) - 1)]))
      }
      yy += 20
      prev_sort := ps.lb_sort
      rl.GuiToggleGroup({ix, yy, (iw - 8) / 5, 22}, "penya;kpm;kills;mobs;dens", &ps.lb_sort)
      if ps.lb_sort != prev_sort {
        panel_enqueue(&ps, fmt.tprintf("leaderboard refresh %s", LB_SORTS[clamp(int(ps.lb_sort), 0, len(LB_SORTS) - 1)]))
      }
      yy += 28
      cx_rank := ix
      cx_name := ix + 24
      cx_kills := ix + 166
      cx_penya := ix + 212
      cx_kpm := ix + 296
      cx_dens := ix + 342
      cx_cfg := ix + iw - 42
      rl.DrawText("#", i32(cx_rank), i32(yy), 10, PANEL_DIM)
      rl.DrawText("name", i32(cx_name), i32(yy), 10, PANEL_DIM)
      rl.DrawText("kills", i32(cx_kills), i32(yy), 10, PANEL_DIM)
      rl.DrawText("penya", i32(cx_penya), i32(yy), 10, PANEL_DIM)
      rl.DrawText("kpm", i32(cx_kpm), i32(yy), 10, PANEL_DIM)
      rl.DrawText("dns", i32(cx_dens), i32(yy), 10, PANEL_DIM)
      yy += 14
      rl.DrawLine(i32(ix), i32(yy), i32(ix + iw), i32(yy), PANEL_SEP)
      yy += 4
      max_rows := 13
      if len(lb_rows_s) == 0 {
        rl.DrawText("(no entries yet - press Refresh)", i32(ix), i32(yy + 4), 11, PANEL_DIM)
      }
      shown := min(len(lb_rows_s), max_rows)
      for ri in 0 ..< shown {
        r := &lb_rows_s[ri]
        ry := yy + f32(ri) * 20
        nm := panel_buf_str(r.name[:])
        if len(nm) > 18 {nm = nm[:18]}
        rl.DrawText(fmt.ctprintf("%d", ri + 1), i32(cx_rank), i32(ry + 3), 11, rl.RAYWHITE)
        rl.DrawText(fmt.ctprintf("%s", nm), i32(cx_name), i32(ry + 3), 11, rl.RAYWHITE)
        rl.DrawText(fmt.ctprintf("%d", r.kills), i32(cx_kills), i32(ry + 3), 11, rl.RAYWHITE)
        rl.DrawText(fmt.ctprintf("%d", r.penya), i32(cx_penya), i32(ry + 3), 11, rl.RAYWHITE)
        rl.DrawText(fmt.ctprintf("%.1f", r.kpm), i32(cx_kpm), i32(ry + 3), 11, rl.RAYWHITE)
        rl.DrawText(fmt.ctprintf("%d", r.max_density), i32(cx_dens), i32(ry + 3), 11, rl.RAYWHITE)
        if rl.GuiButton({cx_cfg, ry, 40, 18}, "cfg") {
          panel_enqueue(&ps, fmt.tprintf("leaderboard getcfg %d", r.id))
        }
      }

      // status line + Close (anchored to the modal bottom, independent of the row count above)
      if lb_status_s != "" {
        rl.DrawText(fmt.ctprintf("%s", lb_status_s), i32(ix), i32(ly + lh - 62), 11, rl.Color{150, 200, 160, 255})
      }
      if rl.GuiButton({ix, ly + lh - 40, iw, 28}, "Close") {
        ps.leaderboard_open = false
        ps.lb_name_edit = false
      }
      // disabled-Submit explanation, drawn last so it sits above the whole modal
      if submit_tip != nil {
        tw := rl.MeasureText(submit_tip, 12)
        tx := mouse.x + 14
        ty := mouse.y + 18
        if tx + f32(tw) + 10 > fw {tx = fw - f32(tw) - 10}
        rl.DrawRectangle(i32(tx - 4), i32(ty - 3), tw + 10, 20, rl.Color{12, 16, 22, 250})
        rl.DrawRectangleLines(i32(tx - 4), i32(ty - 3), tw + 10, 20, rl.Color{90, 100, 115, 255})
        rl.DrawText(submit_tip, i32(tx + 1), i32(ty), 12, rl.RAYWHITE)
      }
    }

    rl.EndDrawing()
    } // end Radar_Draw zone scope (free_all / relock / drain below run outside the draw zone)

    free_all(context.temp_allocator) // reclaim this frame's mob array + collider snapshot + HUD strings
    sync.mutex_lock(&session.exec_mutex) // re-acquire before the next iteration (and for run_cli to unlock)

    // Drain deferred widget commands now that we hold exec_mutex again (matches REPL discipline). The
    // pending strings are heap-owned, so the free_all above didn't touch them; free each after it runs.
    for cmd in ps.pending {
      if session.exec_line != nil {
        session.exec_line(&session.eng, cmd)
      }
      delete(cmd)
    }
    clear(&ps.pending)
  }
}
