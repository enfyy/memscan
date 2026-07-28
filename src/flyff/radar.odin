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

import imgui_rl "../../lib/imgui_impl_raylib"
import imgui "../../lib/odin-imgui"
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
// This file draws the MAP. Every widget over it is Dear ImGui and lives in gui.odin.
//
// Runs on the calling (REPL) thread until closed (ESC / window X / optional duration). Each frame it does
// all session-touching work (mouse fence edits, memory reads, collider snapshot) while holding the REPL's
// exec_mutex, then RELEASES it for the draw/present so the watcher thread can run auto_tick - so auto-farm
// keeps going while the radar is open. Because fence writes happen only inside that locked section, they
// never race the picker (which reads session.fence under the same mutex). The text command channel stays
// the headless/scripting interface (the fence is also fully authorable via the `fence` commands).
//
// It does NOT require an attached process: with none, gui.odin puts up the Attach dialog and every
// game read is skipped (`live`). handle/base/layout are therefore re-read per frame rather than hoisted
// out of the loop - you can attach, detach and re-attach without closing the window.
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
AGGRO_COL :: rl.Color{255, 120, 90, 255} // ring on a mob whose m_idDest is US - it's coming for you (ladder rung 1)

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

// Sweep lane paint (see sweep.odin). Amber - unused by any other radar element, so a painted route never
// reads as a mob, a fence, a collider or the trail. PAINT_BAD marks the part of an in-progress stroke the
// pre-validation rejected (behind a wall / a rock): it is drawn so you can see where the cursor went, and
// trimmed the moment you release. Drawn UNDER the range ring, the trail and every blip.
PAINT_COL :: rl.Color{255, 176, 46, 255} // painted (un-swept) lane
PAINT_BAD :: rl.Color{230, 70, 70, 255}  // the pre-validation's rejected tail, while drawing
// A stretch that threads under a tree/rock silhouette. KEPT and walkable (see sweep_obj_block - the OBB
// is the whole canopy, not the trunk), but tinted olive so "the validator saw this and let it through"
// is visible rather than looking like a miss.
PAINT_SOFT :: rl.Color{186, 168, 74, 255}
PAINT_SWATH_A :: 30                      // swath fill alpha - the quads tile edge-to-edge, so this is flat
PAINT_LINE_A :: 200                      // centreline alpha (legible where the swath is faint)
PAINT_LINE_W :: f32(2.0)                 // centreline thickness (px)
// Screen-space floor for the two sweep HIT TESTS (start a stroke inside the ring / click the lane to
// cancel). A melee attack_range is ~1.75 units, which at a normal zoom is a 5px ring - unclickable. The
// floor only widens what counts as a grab; the painted swath itself is always exactly attack_range wide,
// because the swath IS the ground that gets killed.
PAINT_GRAB_PX :: f32(14)

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

// Radar no-walk overlay (display-only; toggle: `nowalk`, radar key N). The reach oracle already knows
// exactly which terrain cells stop a walker - the heightmap encodes them as an attribute (see decode_hgt
// / hattr_blocks_walk). This paints those cells onto the map, so an invisible wall becomes something you
// SEE rather than something auto discovers by walking into it. Each square is one of the game's own
// attribute cells (mpu world units, sampled on that exact grid - not a resampling of it), so what you see
// is what the reach raycast tests. Needs `worldscan` pinned, same as the hillshade; drawn over the relief
// and under obstacles/fences/dots so it never hides a mob.
NOWALK_MAX_DIM :: 220 // cap on painted cells per side; past it the sample step coarsens instead
NOWALK_A :: u8(104)   // fill alpha - reads as a hazard wash without burying the relief underneath

// Radar vision (mob-dot gather/draw radius, world units) - bounds. The max stays under one
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
  aggro:        bool, // its m_idDest is US: it is chasing/attacking the player (priority-ladder rung 1)
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

// View-keyed cache guard shared by the two static-terrain layers (hillshade + no-walk). Terrain does not
// move, so both keep their built cell lists until the camera, the zoom or the window size changes - a
// still view costs only the rect draws. One struct per layer instead of five parallel locals each.
Terrain_Layer_Cache :: struct {
  cam:   [2]f32,
  scale: f32,
  fw:    f32,
  fh:    f32,
  valid: bool,
}

terrain_layer_stale :: proc(c: Terrain_Layer_Cache, cam: [2]f32, scale, fw, fh: f32) -> bool {
  return !c.valid || c.cam != cam || c.scale != scale || c.fw != fw || c.fh != fh
}

terrain_layer_mark :: proc(c: ^Terrain_Layer_Cache, cam: [2]f32, scale, fw, fh: f32) {
  c^ = Terrain_Layer_Cache{cam = cam, scale = scale, fw = fw, fh = fh, valid = true}
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

// Resolve the landscape grid once for a whole overlay rebuild: the CLandscape* array, its tile
// dimensions and the map's meters-per-unit. ok=false = terrain offsets unpinned / world not resolved /
// implausible dimensions, i.e. "there is no terrain to draw" - both terrain layers just draw nothing.
terrain_grid_ctx :: proc(session: ^Session, world: uintptr) -> (arr: uintptr, lw, lh: int, mpu: f32, ok: bool) {
  handle := session.proc_info.handle
  pt := session.ptr_size == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  L := session.layout
  if world == 0 || L.land_off == 0 || L.landwidth_off == 0 || L.hmap_off == 0 {
    return
  }
  lw = int(read_i32_at(handle, world + uintptr(L.landwidth_off)))
  lh = int(read_i32_at(handle, world + uintptr(L.landwidth_off + 4)))
  if lw <= 0 || lh <= 0 || lw > 256 || lh > 256 {
    return 0, 0, 0, 0, false
  }
  arr = read_ptr_at(handle, world + uintptr(L.land_off), pt) // m_apLand (CLandscape**)
  if !is_heap_ptr(session, arr) {
    return 0, 0, 0, 0, false
  }
  return arr, lw, lh, f32(world_mpu(session, world)), true
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

// Decoded terrain attribute + height at an integer heightmap cell (global grid coords gx,gz), resolving
// which tile owns it. ok=false = off-world / unloaded. The bulk-read building block under both the
// hillshade's bilinear sampler (height only) and the no-walk overlay (attribute only); it mirrors the
// per-cell math in world_attr_at, minus the per-sample pointer walk.
hill_corner :: proc(session: ^Session, arr: uintptr, land_width, land_height, gx, gz: int, cache: ^map[int][]f32) -> (attr: int, h: f32, ok: bool) {
  if gx < 0 || gz < 0 || gx >= land_width * MAP_SIZE || gz >= land_height * MAP_SIZE {
    return 0, 0, false
  }
  m_x := gx / MAP_SIZE
  m_z := gz / MAP_SIZE
  tile := m_x + m_z * land_width
  if tile < 0 || tile >= land_width * land_height {
    return 0, 0, false
  }
  hm := hill_tile_hmap(session, arr, tile, cache)
  if hm == nil {
    return 0, 0, false
  }
  cell := (gx - m_x * MAP_SIZE) + (gz - m_z * MAP_SIZE) * HMAP_STRIDE
  if cell < 0 || cell >= len(hm) {
    return 0, 0, false
  }
  a, height := decode_hgt(hm[cell])
  return a, height, true
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
  _, h00, ok00 := hill_corner(session, arr, land_width, land_height, ix, iz, cache)
  if !ok00 {
    return 0, false
  }
  _, h10, ok10 := hill_corner(session, arr, land_width, land_height, ix + 1, iz, cache)
  _, h01, ok01 := hill_corner(session, arr, land_width, land_height, ix, iz + 1, cache)
  _, h11, ok11 := hill_corner(session, arr, land_width, land_height, ix + 1, iz + 1, cache)
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
  arr, lw, lh, mpu, gok := terrain_grid_ctx(session, world)
  if !gok {
    return
  }

  // draw-cell world-size: keep cells ~HILL_CELL_PX on screen at EVERY zoom (the bilinear sampler below
  // fills in detail between the coarser mpu-spaced heightmap samples, so sub-mpu cells are meaningful -
  // this is what makes the relief smooth instead of stair-stepping to the 4-unit grid when zoomed in).
  d := f32(HILL_CELL_PX) / scale
  // visible world rect ([0,0]..[fw, fh] - the map owns the whole window); pad one cell for edge
  // gradients and snap the origin to a multiple of d so cells don't shimmer as the view pans.
  vw := fw
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

// ===========================================================================
// Terrain no-walk overlay (display-only). See the NOWALK_* constants for the design note.
// ===========================================================================

// One painted blocked cell. Screen rect precomputed at gather time, like Hill_Cell.
Nowalk_Cell :: struct {
  rect: rl.Rectangle,
  col:  rl.Color,
}

// Hazard colour per blocked attribute. Warm hues only - the map's cool greys are terrain, and blue/green
// are already spoken for by fences and density. NOFLY is deliberately absent: a walker ignores it.
radar_nowalk_color :: proc(attr: int) -> rl.Color {
  switch attr {
  case HATTR_NOWALK:
    return rl.Color{224, 148, 46, NOWALK_A} // fly-only ground: you jam here, but it is not a wall
  case HATTR_NOMOVE:
    return rl.Color{214, 68, 62, NOWALK_A} // solid wall (the invisible-collision band around cliffs)
  case HATTR_DIE:
    return rl.Color{206, 46, 148, NOWALK_A} // instant-death cell - loudest colour on the map
  }
  return rl.Color{0, 0, 0, 0}
}

// Build the no-walk cell list for the current view. Called in the radar's LOCKED phase (it reads game
// memory) and cached by view like the hillshade. Walks the attribute grid itself, one sample per game
// cell, so a painted square IS a cell of the grid the reach raycast reads; zoomed far out the step
// coarsens (and the squares grow to match) so one rebuild stays bounded.
radar_gather_nowalk :: proc(session: ^Session, world: uintptr, cam: [2]f32, scale: f32, center: rl.Vector2, fw, fh: f32, out: ^[dynamic]Nowalk_Cell) {
  clear(out)
  arr, lw, lh, mpu, gok := terrain_grid_ctx(session, world)
  if !gok || mpu <= 0 {
    return
  }
  // Visible world rect -> inclusive cell range, padded a cell so a partially-visible edge cell still
  // paints. The map owns the whole window, so the rect is just the two screen corners unprojected.
  c0 := radar_s2w(cam, scale, center, 0, 0)
  c1 := radar_s2w(cam, scale, center, fw, fh)
  gx0 := int(math.floor(min(c0[0], c1[0]) / mpu)) - 1
  gz0 := int(math.floor(min(c0[1], c1[1]) / mpu)) - 1
  gx1 := int(math.floor(max(c0[0], c1[0]) / mpu)) + 1
  gz1 := int(math.floor(max(c0[1], c1[1]) / mpu)) + 1
  step := 1
  if cols, rows := gx1 - gx0 + 1, gz1 - gz0 + 1; cols > NOWALK_MAX_DIM || rows > NOWALK_MAX_DIM {
    step = (max(cols, rows) + NOWALK_MAX_DIM - 1) / NOWALK_MAX_DIM // sample every Nth cell, draw N-wide
  }
  d := mpu * f32(step)

  tiles := make(map[int][]f32, 32, context.temp_allocator) // per-rebuild tile-heightmap cache (bulk reads)
  for gz := gz0; gz <= gz1; gz += step {
    for gx := gx0; gx <= gx1; gx += step {
      attr, _, ok := hill_corner(session, arr, lw, lh, gx, gz, &tiles)
      if !ok || !hattr_blocks_walk(attr) {
        continue // off-world / unloaded / walkable -> nothing to paint
      }
      // Cell (gx,gz) governs the world square [gx*mpu, (gx+1)*mpu) - see world_attr_at's floor math.
      p0 := radar_w2s(cam, scale, center, f32(gx) * mpu, f32(gz) * mpu)
      p1 := radar_w2s(cam, scale, center, f32(gx) * mpu + d, f32(gz) * mpu + d)
      // Min corner + abs size (north-up flips z, and a negative-height rect draws nothing), +1px on the
      // far edges so neighbouring cells merge into one wall instead of showing seams between them.
      append(
        out,
        Nowalk_Cell {
          rl.Rectangle{min(p0.x, p1.x), min(p0.y, p1.y), abs(p1.x - p0.x) + 1, abs(p1.y - p0.y) + 1},
          radar_nowalk_color(attr),
        },
      )
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
  // Aggro highlight input (priority-ladder rung 1): our own OBJID, resolved once per gather. A mob whose
  // m_idDest equals it is coming for us. 0 = offsets unpinned -> nothing is flagged and the map looks
  // exactly as it did before. One extra 4-byte read per drawn mover.
  my_objid: u32 = 0
  if L.objid_off != 0 && L.iddest_off != 0 && player != 0 {
    if v, ok := engine.read_value(handle, player + uintptr(L.objid_off), .U32); ok {
      my_objid = u32(engine.value_as_u64(.U32, v))
    }
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
          if my_objid != 0 && (kind == .Monster || kind == .Unclassified) {
            if dv, dok := engine.read_value(handle, obj + uintptr(L.iddest_off), .U32); dok {
              blip.aggro = u32(engine.value_as_u64(.U32, dv)) == my_objid
            }
          }
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
// ===========================================================================
// Map overlay text + rings, drawn through ImGui instead of raylib.
//
// WHY NOT rl.DrawText / rl.DrawCircleLinesV. raylib's default font is a 10px bitmap face that reads as
// a different program's UI next to Fredoka, and its circle primitives are fixed-step polygons with no
// anti-aliasing, so a 7px hover ring comes out visibly faceted. ImGui gives us the UI font and AA
// geometry for free, and both are already on screen this frame.
//
// LAYER. The BACKGROUND draw list renders after ALL raylib content but beneath every ImGui window -
// exactly where entity labels and rings want to be (on top of the map, under a dialog). That is also
// why the world-layer rings (attack_range, density radius) deliberately stay on raylib: they are drawn
// UNDER the mob dots on purpose, and this layer would put them over.
//
// THREADING. Same rule as gui.odin: these run in the unlocked draw phase, so they take plain values,
// never session pointers.
// ===========================================================================

// One map label, in the UI font, with the near-black shadow gui_gauge uses so it stays legible over
// both dark terrain and a bright hillshade. (x,y) is the top-left, matching rl.DrawText's convention so
// the call sites keep their hand-tuned offsets.
radar_label :: proc(x, y: f32, text: cstring, col: rl.Color) {
  dl := imgui.GetBackgroundDrawList()
  c := imgui.ColorConvertFloat4ToU32({f32(col.r) / 255, f32(col.g) / 255, f32(col.b) / 255, f32(col.a) / 255})
  imgui.DrawList_AddText(dl, {x + 1, y + 1}, imgui.ColorConvertFloat4ToU32({0, 0, 0, f32(col.a) / 255 * 0.75}), text)
  imgui.DrawList_AddText(dl, {x, y}, c, text)
}

// An anti-aliased ring. num_segments 0 lets ImGui pick from CircleTessellationMaxError (gui_apply_theme
// lowers it to 0.10px), so small rings stay round instead of hexagonal.
radar_ring :: proc(p: rl.Vector2, r: f32, col: rl.Color, thickness: f32 = 1) {
  c := imgui.ColorConvertFloat4ToU32({f32(col.r) / 255, f32(col.g) / 255, f32(col.b) / 255, f32(col.a) / 255})
  imgui.DrawList_AddCircle(imgui.GetBackgroundDrawList(), {p.x, p.y}, r, c, 0, thickness)
}

// Width of a label in the UI font - the rl.MeasureText replacement for centring a pop.
radar_text_w :: proc(text: cstring) -> f32 {
  return imgui.CalcTextSize(text).x
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

// Inspect mode: outline one OBB in a bright cyan highlight (distinct from the purple blocker fill and the
// red eraser hover) so it's obvious which box the identity tooltip describes. Same footprint math as
// radar_draw_obb.
radar_draw_obb_hi :: proc(o: Obb, cam: [2]f32, scale: f32, center: rl.Vector2) {
  u := radar_axis_half({o.axis[0][0], o.axis[0][2]}, o.ext[0] * scale, 2.5)
  v := radar_axis_half({o.axis[2][0], o.axis[2][2]}, o.ext[2] * scale, 2.5)
  u[1] = -u[1] // north-up projection: flip z (see radar_draw_obb)
  v[1] = -v[1]
  p := radar_w2s(cam, scale, center, o.center[0], o.center[2])
  c0 := rl.Vector2{p.x - u[0] - v[0], p.y - u[1] - v[1]}
  c1 := rl.Vector2{p.x + u[0] - v[0], p.y + u[1] - v[1]}
  c2 := rl.Vector2{p.x + u[0] + v[0], p.y + u[1] + v[1]}
  c3 := rl.Vector2{p.x - u[0] + v[0], p.y - u[1] + v[1]}
  radar_fill_quad(c0, c1, c2, c3, rl.Color{90, 220, 255, 55})
  radar_line_loop(c0, c1, c2, c3, 2.5, rl.Color{90, 220, 255, 255})
}

// How opaque one sweep node still is: 1 while un-eaten, then a linear fade to 0 over SWEEP_FADE_NS after
// the circle passed over it. Fading (rather than vanishing on the frame it's eaten) is what sells "the
// circle is erasing the paint" instead of "nodes are blinking out".
sweep_node_alpha :: proc(n: Sweep_Node, now: i64) -> f32 {
  if !n.eaten {
    return 1
  }
  if n.eaten_at == 0 {
    return 0
  }
  el := now - n.eaten_at
  if el >= SWEEP_FADE_NS {
    return 0
  }
  return 1 - f32(el) / f32(SWEEP_FADE_NS)
}

// Colour for one lane segment: red if either end was rejected by the pre-validation (drawing only -
// sweep_arm trims these), olive if either end threads under a prop silhouette, else the normal amber.
sweep_seg_color :: proc(a, b: Sweep_Node) -> rl.Color {
  if !a.valid || !b.valid {
    return PAINT_BAD
  }
  if a.soft || b.soft {
    return PAINT_SOFT
  }
  return PAINT_COL
}

// Draw one sweep lane, in two layers: the SWATH (per segment, a quad from prev +/- n*r to cur +/- n*r,
// where n is the segment's 2D normal and r the brush width) and a CENTRELINE polyline on top. Edge-to-
// edge quads tile without overlapping, so the swath reads as one flat translucent band instead of the
// alpha-banded stack you'd get from drawing a disc per node; caps go on the head and tail only. A
// segment's alpha is the dimmer of its two endpoints, so the erase front recedes smoothly.
//
// Runs in the UNLOCKED draw phase, so <nodes> must be a snapshot (the watcher reallocs the live list) -
// see the temp clone in the UI-snapshot block. Off-screen segments are skipped: the node list can run
// to SWEEP_MAX_NODES and only the visible slice is worth two triangles.
radar_draw_sweep :: proc(nodes: []Sweep_Node, r: f32, cam: [2]f32, scale: f32, center: rl.Vector2, fw, fh: f32, now: i64) {
  if len(nodes) < 2 || r <= 0 {
    return
  }
  margin := r * scale + 16 // a segment just off-screen can still paint its swath into view
  visible :: proc(a, b: rl.Vector2, fw, fh, m: f32) -> bool {
    return max(a.x, b.x) >= -m && min(a.x, b.x) <= fw + m && max(a.y, b.y) >= -m && min(a.y, b.y) <= fh + m
  }
  // swath
  for i in 1 ..< len(nodes) {
    a := nodes[i - 1]
    b := nodes[i]
    fade := min(sweep_node_alpha(a, now), sweep_node_alpha(b, now))
    if fade <= 0 {
      continue
    }
    sa := radar_w2s(cam, scale, center, a.pos[0], a.pos[2])
    sb := radar_w2s(cam, scale, center, b.pos[0], b.pos[2])
    if !visible(sa, sb, fw, fh, margin) {
      continue
    }
    dx := b.pos[0] - a.pos[0]
    dz := b.pos[2] - a.pos[2]
    l := math.sqrt(dx * dx + dz * dz)
    if l < 1e-4 {
      continue
    }
    nx := -dz / l * r // 2D normal of the segment, scaled to the brush half-width
    nz := dx / l * r
    col := sweep_seg_color(a, b)
    col.a = u8(f32(PAINT_SWATH_A) * fade)
    radar_fill_quad(
      radar_w2s(cam, scale, center, a.pos[0] + nx, a.pos[2] + nz),
      radar_w2s(cam, scale, center, b.pos[0] + nx, b.pos[2] + nz),
      radar_w2s(cam, scale, center, b.pos[0] - nx, b.pos[2] - nz),
      radar_w2s(cam, scale, center, a.pos[0] - nx, a.pos[2] - nz),
      col,
    )
  }
  // centreline (on top of the swath, so the route stays legible where the fill is faint)
  for i in 1 ..< len(nodes) {
    a := nodes[i - 1]
    b := nodes[i]
    fade := min(sweep_node_alpha(a, now), sweep_node_alpha(b, now))
    if fade <= 0 {
      continue
    }
    sa := radar_w2s(cam, scale, center, a.pos[0], a.pos[2])
    sb := radar_w2s(cam, scale, center, b.pos[0], b.pos[2])
    if !visible(sa, sb, fw, fh, margin) {
      continue
    }
    col := sweep_seg_color(a, b)
    col.a = u8(f32(PAINT_LINE_A) * fade)
    rl.DrawLineEx(sa, sb, PAINT_LINE_W, col)
  }
  // round caps at the head (first un-eaten node - the erase front) and the tail (the end of the lane)
  head := -1
  for n, i in nodes {
    if !n.eaten {
      head = i
      break
    }
  }
  if head >= 0 {
    cap_col := PAINT_COL
    cap_col.a = PAINT_SWATH_A
    rl.DrawCircleV(radar_w2s(cam, scale, center, nodes[head].pos[0], nodes[head].pos[2]), r * scale, cap_col)
    last := nodes[len(nodes) - 1]
    tail_col := sweep_seg_color(last, last)
    tail_col.a = PAINT_SWATH_A
    rl.DrawCircleV(radar_w2s(cam, scale, center, last.pos[0], last.pos[2]), r * scale, tail_col)
  }
}

// Pick the collider box under a world point (inspect-mode hit test): the SMALLEST-footprint containing
// box wins, so a tight inner box stays selectable even when a larger one overlaps it. Returns an index
// into `obbs`, or -1 if nothing is under the point. Mirrors fence_shape_at's role for fence shapes.
obb_pick_at :: proc(obbs: []Obb, wx, wz: f32) -> int {
  best := -1
  best_area := f32(1e30)
  for o, i in obbs {
    if o.ext[0] <= 0.01 && o.ext[2] <= 0.01 {
      continue // degenerate (matches the draw skip)
    }
    if point_in_obb_xz(wx, wz, o) {
      area := o.ext[0] * o.ext[2]
      if area < best_area {
        best_area = area
        best = i
      }
    }
  }
  return best
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

// nowalk [on|off] - toggle the radar's no-walk overlay: the terrain cells the reach oracle treats as
// walk-blocking (NOWALK / NOMOVE / DIE), painted where they are. This is the SAME attribute grid the
// targeting reach raycast reads, so it shows you the invisible walls auto is already avoiding. Reads the
// terrain heightmap, so it needs `worldscan` pinned; the toggle still flips (it activates once terrain
// resolves). Persisted like hillshade (attach-gated save). Radar key: N.
cli_nowalk :: proc(session: ^Session, args: []string) {
  switch {
  case len(args) == 0:
    session.layout.nowalk_on = !session.layout.nowalk_on
  case len(args) == 1 && args[0] == "on":
    session.layout.nowalk_on = true
  case len(args) == 1 && args[0] == "off":
    session.layout.nowalk_on = false
  case:
    fmt.eprintln("usage: nowalk [on|off]")
    return
  }
  if session.attached {
    flyff_save_cfg(session.layout, flyff_cfg_path())
  }
  fmt.printfln("no-walk overlay %s.", session.layout.nowalk_on ? "ON" : "OFF")
  if session.layout.nowalk_on {
    fmt.println("  legend: orange = NOWALK (fly-only), red = NOMOVE (wall), magenta = DIE.")
    if !terrain_ready(session) {
      fmt.println("  note: terrain offsets not pinned yet - run 'worldscan' (in-game) so there is an attribute grid to paint.")
    }
  }
}


// radar [seconds] - open the live radar window. seconds>0 auto-closes after that long (handy for a quick
// look / headless smoke test); omit to run until you close the window. Press E in-window for the fence
// editor (see the HUD for controls); draw your fence, close the window, then `fence save <name>`.
cli_radar :: proc(session: ^Session, args: []string) {
  dur := f64(0)
  if len(args) >= 1 {
    if v, ok := strconv.parse_f64(args[0]); ok && v > 0 {
      dur = v
    }
  }
  pt := engine.Value_Type.U32

  // NOT attach-gated. The window opens with no process attached and shows the Attach dialog - it is the
  // way IN, so requiring an attach first would be a dead end (same reasoning that already dropped the
  // "setup must be complete" gate). Consequently handle/base/layout are NOT captured here: attaching from
  // inside the window would leave those stale forever. They are re-read per frame, in the locked section.
  ppos := [3]f32{0, 0, 0}
  if session.attached && session.ptr_size == 4 {
    // Read once and report BEFORE opening a window, so the data pipeline stays verifiable headlessly.
    L0 := session.layout
    view_r0 := clamp(L0.radar_range, RADAR_RANGE_MIN, RADAR_RANGE_MAX)
    world0 := read_ptr_at(session.proc_info.handle, session.proc_info.base + L0.world_rva, pt)
    p0, pok := read_player_pos(session)
    if pok {
      ppos = p0
    }
    if !pok || world0 == 0 {
      fmt.eprintln("radar: world/player not resolved yet - opening anyway so you can run Setup. Be in-game; blips appear once it resolves.")
    } else {
      probe_player := read_ptr_at(session.proc_info.handle, session.proc_info.base + L0.player_rva, pt)
      probe_pb, probe_pai := radar_prop_ctx(session, probe_player)
      probe := make([dynamic]Radar_Blip, context.temp_allocator)
      radar_gather_movers(session, world0, probe_player, probe_pb, probe_pai, ppos[0], ppos[2], view_r0 + 20, &probe, nil, nil, 0)
      probe_obbs := collect_area_colliders(session, world0, ppos[0], ppos[2])
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
  } else {
    fmt.printfln("radar: not attached - opening the window on the Attach dialog%s...", dur > 0 ? fmt.tprintf(" for %.0fs", dur) : "")
  }
  free_all(context.temp_allocator)

  rl.SetConfigFlags({.WINDOW_RESIZABLE})
  rl.InitWindow(1000, 820, "memscan")
  defer rl.CloseWindow() // raylib's own (via /WHOLEARCHIVE:raylib.lib) - see note atop this file
  rl.SetWindowMinSize(520, 420)
  rl.SetTargetFPS(30)
  // Kill raylib's default ESC-quits-the-window binding. ESC is a dialog/cancel key everywhere else in
  // this UI, and having it also tear down the whole window (mid-fence-edit, mid-setup) was a trap. The
  // titlebar X and the `radar <seconds>` timeout are the ways out now.
  rl.SetExitKey(.KEY_NULL)

  // Dear ImGui owns every widget now (see gui.odin). The font atlas is baked at layout.ui_scale, so the
  // scale is latched here for the window's life - `set ui_scale <n>` then re-open to change it.
  gui_init(session.layout.ui_scale)
  defer gui_shutdown()

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
  // L / the toolbar camera button: lock the view on the player so the dot stays centred (pan disabled).
  // ON by default - following the player is what you want ~always, and the map-style recenter button only
  // appears once you unlock and pan away.
  cam_lock := true
  show_cam := false // F toggles the render-camera eye + frustum overlay
  show_reach := true // R toggles fading of monsters the collision check can't reach (off = less per-frame work)
  start := rl.GetTime()

  // Fence editor state - all local. session.fence is mutated only here (and by the `fence` commands),
  // always under the REPL's exec_mutex, so it never races the watcher's picker. poly_wip is heap-owned
  // (it lives across frames while the temp allocator is reclaimed each frame).
  edit := false
  inspect := false // I toggles read-only obstacle inspect mode; mutually exclusive with the fence editor
  tool := Radar_Tool.Circle
  tag_i := 0 // fence draw tag: 0 = include(+), 1 = exclude(-), 2 = avoid(!). Tab cycles.
  drag_active := false
  drag_start := [2]f32{}
  poly_wip := make([dynamic][2]f32)
  defer delete(poly_wip)

  // Sweep-lane stroke state - radar-local and heap-owned across frames, exactly like poly_wip. paint_wip
  // holds the stroke being drawn (pre-validated node by node); it is only ever published into
  // session.sweep_path by sweep_arm on release. paint_active suppresses the right-drag pan while a stroke
  // is live, so a paint gesture never also scrolls the map. See sweep.odin.
  paint_wip: Sweep_Wip
  defer sweep_wip_free(&paint_wip)
  paint_active := false

  // UI widget state (see gui.odin). Local, like poly_wip. Its pending strings + process rows are
  // heap-owned; freed on close (the per-frame drain frees the commands it runs).
  ps: Panel_State
  defer panel_state_free(&ps)
  recenter_req := false // set by the toolbar's recenter button, consumed at the top of the next frame

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

  // The two terrain layers - hillshade relief and the no-walk overlay. Both are cached screen-cell lists
  // rebuilt only when the view (cam/scale/size) changes, since terrain is static: a still view costs
  // only the rect draws. Cells are value-only; the guard struct is what decides "the view moved".
  hill_cells := make([dynamic]Hill_Cell)
  defer delete(hill_cells)
  hill_cache: Terrain_Layer_Cache
  nowalk_cells := make([dynamic]Nowalk_Cell)
  defer delete(nowalk_cells)
  nowalk_cache: Terrain_Layer_Cache

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
  insp_pick := -1 // inspect mode: index into obbs of the box under the cursor this frame (-1 = none)
  insp_lines: []cstring // its identity tooltip lines (temp-allocated each frame; drawn after unlock)
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

    // Open the ImGui frame FIRST: it pumps raylib's input into ImGui and computes WantCaptureMouse /
    // WantCaptureKeyboard for THIS frame, which is what gates the map input below. The matching
    // imgui_rl.end() runs inside BeginDrawing/EndDrawing at the bottom of the loop.
    imgui_rl.begin()

    fw := f32(rl.GetScreenWidth())
    fh := f32(rl.GetScreenHeight())
    center := rl.Vector2{fw / 2, fh / 2} // the map owns the whole window now; the UI floats over it
    mouse := rl.GetMousePosition()
    mw := radar_s2w(cam, scale, center, mouse.x, mouse.y) // world (x,z) under the cursor
    // Gate world input through ImGui itself: a click on a widget must never also pan/zoom/target/edit,
    // and typing in a text box must not fire the E/F/R/C/Space or fence hotkeys. This replaced a
    // hand-maintained list of panel/toolbar/button rectangles - ImGui already knows what it is hovering.
    io := imgui.GetIO()
    ui_owns_mouse := io.WantCaptureMouse || gui_modal_up(&ps, session.attached)
    typing := io.WantCaptureKeyboard

    // Everything below reads the game, so it only runs while a 32-bit process is attached. handle/base/
    // layout are re-read EVERY frame, never captured before the loop: you can attach (and re-attach) from
    // inside this window, which would leave a hoisted copy pointing at a closed handle forever.
    live := session.attached && session.ptr_size == 4
    handle := session.proc_info.handle
    base := session.proc_info.base
    // Re-snapshot the layout every frame (under the lock): setup/findpenya from the UI and an external
    // 'set attack_range' all mutate session.layout live, and a frozen copy kept the ring, the penya watch
    // and the cold-start blip pipeline stale until the window was reopened.
    L := session.layout
    view_r := clamp(L.radar_range, RADAR_RANGE_MIN, RADAR_RANGE_MAX) // live vision radius

    if recenter_req {
      cam = {ppos[0], ppos[2]}
      recenter_req = false
    }

    // --- live player pos + facing (single player resolve) ---
    pangle: f32
    has_angle := false
    player := live ? read_ptr_at(handle, base + L.player_rva, pt) : 0
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

    // --- input: view controls + fence editor (both modes). Gated so the UI wins any click it wants. ---
    if !ui_owns_mouse && !typing {
    scale += rl.GetMouseWheelMove() * 0.5
    if scale < 0.5 {scale = 0.5}
    if scale > 24 {scale = 24}
    // --- sweep gesture (see sweep.odin). A right-PRESS resolves to exactly one of three things, in this
    // order, so the three can never compete:
    //   1. a lane is armed and the press lands on it (within a brush width of an un-eaten node) -> cancel
    //      it. Checked first, so a live lane is always cancellable.
    //   2. no lane armed and the press is inside the attack-range ring -> start a stroke at our feet.
    //   3. anything else -> pan, exactly as before.
    // Sampling + the release-arm live in a later block (they need the CWorld* for validation); only the
    // decision and the pan suppression happen here. Inert while attack_range is 0 - it IS the brush width.
    if rl.IsMouseButtonPressed(.RIGHT) && !paint_active && L.attack_range > 0 {
      grab := max(L.attack_range, PAINT_GRAB_PX / scale) // keep a melee-sized ring clickable at any zoom
      if session.sweep_on {
        if sweep_hit_path(session, mw[0], mw[1], grab) {
          _, sw_left, _ := sweep_progress(session)
          sweep_clear(session)
          fmt.printfln("[sweep] cancelled (%.0f units unswept) - normal targeting resumed.", sw_left)
        }
      } else {
        rdx := mw[0] - ppos[0]
        rdz := mw[1] - ppos[2]
        if rdx * rdx + rdz * rdz <= grab * grab {
          sweep_wip_begin(&paint_wip, ppos)
          paint_active = true
        }
      }
    }
    if !cam_lock && !paint_active && rl.IsMouseButtonDown(.RIGHT) { // right-drag pans (disabled while locked to the player, or while painting a lane)
      d := rl.GetMouseDelta()
      cam[0] -= d.x / scale
      cam[1] += d.y / scale // north-up projection: screen-y is inverted vs world z (see radar_w2s)
    }
    if rl.IsKeyPressed(.E) {edit = !edit;if edit {inspect = false}} // fence editor + inspect are mutually exclusive
    if rl.IsKeyPressed(.I) {inspect = !inspect;if inspect {edit = false}} // read-only obstacle inspector
    if rl.IsKeyPressed(.F) {show_cam = !show_cam}
    if rl.IsKeyPressed(.R) {show_reach = !show_reach}
    if rl.IsKeyPressed(.L) {cam_lock = !cam_lock}
    if rl.IsKeyPressed(.M) {panel_enqueue(&ps, "collmem")} // remember obstacles you have walked past
    if rl.IsKeyPressed(.C) || rl.IsKeyPressed(.HOME) {cam = {ppos[0], ppos[2]}}
    if rl.IsKeyPressed(.H) {panel_enqueue(&ps, "hillshade")} // toggle terrain relief (deferred like jump)
    if rl.IsKeyPressed(.N) {panel_enqueue(&ps, "nowalk")} // toggle the no-walk overlay (same, deferred)
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
    } // end input gate (the UI has the cursor / keyboard)

    // Camera-lock: keep the player centred by pinning the view to its live position every frame (the world
    // scrolls under a stationary dot instead of the dot drifting off-centre). Applied after input so it
    // overrides any stray pan; zoom still works.
    if cam_lock {
      cam = {ppos[0], ppos[2]}
    }

    // --- live data (snapshot shared state before releasing the lock) ---
    w := live ? read_ptr_at(handle, base + L.world_rva, pt) : 0
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
      // Keep the collider sets fresh. allow_async keeps the frame off the ~200ms rebuild: a stale cache
      // kicks the background collider_scan_worker and serves the current one meanwhile. We drop the
      // returned live-window slice on the floor and DRAW from the persistent memory store instead, so
      // props stay on the map once seen instead of popping out at COLLIDER_RADIUS (collmem off falls back
      // to that same live window). Both are republished by the worker under exec_mutex, so the visible
      // subset is copied out here - drawing runs after we unlock.
      collect_area_colliders(session, w, ppos[0], ppos[2], allow_async = true)
      draw_obbs := make([dynamic]Obb, 0, 512, context.temp_allocator)
      collider_memory_visible(session, cam, scale, fw, fh, &draw_obbs)
      obbs = draw_obbs[:]
      // Terrain hillshade: rebuild the relief cells only when the view changed (static terrain). Reads
      // game memory, so it must run here (locked). Gated on the toggle + terrain offsets being pinned.
      if L.hillshade_on && terrain_ready(session) {
        if terrain_layer_stale(hill_cache, cam, scale, fw, fh) {
          radar_gather_hillshade(session, w, cam, scale, center, fw, fh, L.hillshade_z, L.hillshade_light, &hill_cells)
          terrain_layer_mark(&hill_cache, cam, scale, fw, fh)
        }
      } else if hill_cache.valid {
        clear(&hill_cells)
        hill_cache.valid = false
      }
      // No-walk overlay: same deal (static terrain, view-keyed rebuild), reading the attribute half of
      // the very same heightmap cells.
      if L.nowalk_on && terrain_ready(session) {
        if terrain_layer_stale(nowalk_cache, cam, scale, fw, fh) {
          radar_gather_nowalk(session, w, cam, scale, center, fw, fh, &nowalk_cells)
          terrain_layer_mark(&nowalk_cache, cam, scale, fw, fh)
        }
      } else if nowalk_cache.valid {
        clear(&nowalk_cells)
        nowalk_cache.valid = false
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
    tracy.PlotI("Radar_Remembered", i64(len(session.collider_memory)))

    // --- Phase 4 click interaction (still locked): plain-click = target the mob under the cursor;
    // Shift+click = walk to the ground point. Only in view mode (edit owns left-click for fences) and
    // not over a widget. focus_set_obj / write_dest_pos need exec_mutex, which we still hold here. ---
    shift_down := rl.IsKeyDown(.LEFT_SHIFT) || rl.IsKeyDown(.RIGHT_SHIFT)
    hover_obj = 0
    insp_pick = -1 // reset per-frame like hover_obj so a stale pick can't linger (obbs indices shift each frame)
    insp_lines = nil
    if !ui_owns_mouse && !typing && !edit && !inspect {
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
    // --- sweep stroke sampling (still locked): extend the in-progress lane toward the cursor, resampling
    // every SWEEP_SAMPLE units and reach-validating each new node. It lives HERE rather than up with the
    // gesture because validation needs `w` (the CWorld*, read above) and the collider set. The release is
    // handled UNGATED - a drag that ends over a widget must still arm, or paint_active would stick. ---
    if paint_active {
      if rl.IsMouseButtonDown(.RIGHT) && !ui_owns_mouse && !typing {
        sweep_wip_extend(session, w, &paint_wip, mw[0], mw[1], ppos[1])
      }
      if !rl.IsMouseButtonDown(.RIGHT) {
        paint_active = false
        // Only a real stroke gets armed (or told off for being short). A press that never moved is just
        // a right-click on your own dot - discard it silently instead of nagging.
        if len(paint_wip.nodes) >= 2 {
          sweep_arm(session, &paint_wip) // trims the invalid tail, publishes, and prints the outcome
        }
        sweep_wip_reset(&paint_wip)
      }
    }
    // --- inspect mode (still locked): identify the collider box under the cursor. Read-only - it never
    // touches the reach filter. Pick the box (smallest footprint wins), read its identity live for the
    // tooltip, and on left-click echo the one-liner to the console (a persistent, copyable record). ---
    if inspect && !ui_owns_mouse && !typing {
      insp_pick = obb_pick_at(obbs, mw[0], mw[1])
      if insp_pick >= 0 {
        o := obbs[insp_pick]
        insp_lines = collider_inspect_lines(session, o, ppos)
        // Left-click adds this box's KIND (type + m_dwIndex) to the ignore-list - it's dropped from the
        // collider set on the next scan, so every box like it vanishes from reach AND the radar. Persisted.
        // Identity comes off the box (obj_to_obb captured it), not a live re-read: a REMEMBERED box's CObj
        // may already be streamed out, and clicking one of those has to work exactly the same.
        if rl.IsMouseButtonPressed(.LEFT) {
          ty := o.ty
          idx := o.idx
          if added, ok := collider_ignore_toggle(session, ty, idx); !ok {
            fmt.printfln("[ignore] list full (max %d) - 'collignore clear' to reset", FLYFF_MAX_COLLIDER_IGNORE)
          } else if added {
            fmt.printfln("[ignore] added %s(%d) idx=%d - hidden from reach + radar (undo: 'collignore rm %d %d')", ot_name(ty), ty, idx, ty, idx)
          } else {
            fmt.printfln("[ignore] removed %s(%d) idx=%d", ot_name(ty), ty, idx)
          }
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
    if live {
      penya_tick(session)
      kill_watch_tick(session, time.now()._nsec)
    }
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

    // Bag fullness for the gauge. read_inventory_counts is a ~100KB RPM read, so throttle it (~2.5/s);
    // the last result persists across frames. No-op/hidden until 'findinv' has pinned the offsets.
    if live && L.inv_off != 0 && L.item_stride != 0 {
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

    // --- UI snapshot: everything gui_frame needs, captured HERE under the lock. The draw phase must
    // never read `session` (the watcher owns it the moment we unlock), so anything the widgets show has
    // to land in this struct first. Strings are either static or temp-allocated, which outlives the draw.
    gf := Gui_Frame {
      attached      = session.attached,
      ptr_size      = session.ptr_size,
      pid           = session.proc_info.pid,
      proc_name     = session.proc_info.name,
      groups        = setup_groups(session),
      opins         = optional_pins(session),
      setup_running = session.setup_running,
      setup_step    = session.setup_step,
      penya_show    = L.penya_off != 0 && session.penya_seeded, // pinned + read at least once
      penya_cur     = session.penya_last,
      inv_have      = inv_have,
      inv_used      = inv_used,
      inv_cap       = inv_cap,
      sfx_on        = L.sfx_on,
      nowalk_on     = L.nowalk_on,
      attack_range  = L.attack_range,
      fence_active  = session.fence.active,
      fence_shapes  = len(session.fence.shapes),
    }
    // Behaviour run state. The strings are CLONED into temp: the watcher thread frees and replaces
    // run.name / run.last_line whenever the program moves on, and the draw phase runs unlocked.
    if run := &session.script; run.active {
      gf.script_active = true
      gf.script_paused = run.paused
      gf.script_step = run.stepping
      gf.script_irq = run.irq_depth > 0
      gf.script_name = strings.clone(run.name, context.temp_allocator)
      gf.script_pc = min(run.pc + 1, run.main_len)
      gf.script_len = run.main_len
      gf.script_line = strings.clone(run.last_line, context.temp_allocator)
      if run.pc >= 0 && run.pc < len(run.steps) {
        gf.script_node = run.steps[run.pc].id
      }
    }
    jump_at_s := session.jump_fired_at // player-dot hop animation (set by cli_jump / look-alive)
    prop_ok_s := live ? prop_gate_ready(session) : false
    // Sweep lane: the node list is CLONED into temp because the watcher's sweep_tick reallocs/mutates the
    // live one (erase marks + a completion clear) and the draw below runs after we unlock - same reason as
    // the obbs clone above. The in-progress stroke needs no clone: paint_wip is radar-local.
    sweep_on_s := session.sweep_on
    sweep_nodes_s: []Sweep_Node
    if sweep_on_s {
      sweep_nodes_s = slice.clone(session.sweep_path[:], context.temp_allocator)
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
    // terrain hillshade relief (bottom layer; colourless, under crosshair/obstacles/fences/dots)
    if L.hillshade_on {
      for c in hill_cells {
        rl.DrawRectangleRec(c.rect, c.col)
      }
    }
    // no-walk overlay: the walk-blocking attribute cells, over the relief (it shades them) and under
    // everything semantic, so a hazard wash never hides a mob dot or a fence edge.
    if L.nowalk_on {
      for c in nowalk_cells {
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
    // inspect mode: highlight the box under the cursor (its identity tooltip is drawn later, near the cursor)
    if inspect && insp_pick >= 0 && insp_pick < len(obbs) {
      radar_draw_obb_hi(obbs[insp_pick], cam, scale, center)
    }

    // render-camera overlay (F)
    if show_cam && cam_ok {
      radar_draw_camera(ceye, clook, cam, scale, center)
    }

    // committed fence shapes
    for s in session.fence.shapes {
      radar_draw_shape(s, cam, scale, center)
    }
    // sweep lane: the armed route (snapshot) and, over it, the stroke currently being painted. Drawn in
    // this layer - i.e. UNDER the attack-range ring, the trail and every blip - so a lane never hides a
    // mob. Brush width is the live attack_range, so dragging the slider re-widens the paint immediately.
    if sweep_on_s {
      radar_draw_sweep(sweep_nodes_s, L.attack_range, cam, scale, center, fw, fh, now_frame)
    }
    if len(paint_wip.nodes) > 1 {
      radar_draw_sweep(paint_wip.nodes[:], L.attack_range, cam, scale, center, fw, fh, now_frame)
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
      // Aggro ring: this mob is coming for US, so the picker's rung 1 will take it next. Drawn as a ring
      // rather than a recolour so it composes with the density hue / fence dim / reach fade above, and
      // so the one thing you'd want to eyeball ("is it actually detecting aggro?") is visible at a glance.
      if m.aggro {
        radar_ring(p, radius + 4, AGGRO_COL)
      }
      if m.kind == .Player && m.has_angle {
        radar_draw_arrow(p, m.angle, 11, 4, col) // other players get a facing arrow too
      }
    }

    // Map-wide giant overlay: draw every cached "Giant *" monster (see radar_scan_giants) with a gold ring +
    // name so it stands out. A giant beyond the visible map region is rim-clamped to the window edge with an
    // arrow + distance, so a far hunt target is always locatable no matter the zoom/pan.
    map_rect := rl.Rectangle{0, 0, fw, fh}
    for g in giants {
      gs := radar_w2s(cam, scale, center, g.pos[0], g.pos[2])
      on_screen := gs.x >= map_rect.x && gs.x <= map_rect.x + map_rect.width && gs.y >= 0 && gs.y <= fh
      if on_screen {
        rl.DrawCircleV(gs, 4, GIANT_COL)
        radar_ring(gs, 8, GIANT_COL)
        radar_ring(gs, 10, GIANT_COL)
        radar_label(gs.x + 13, gs.y - 8, fmt.ctprintf("%s", g.name), GIANT_COL)
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
        radar_ring(ep, 6, GIANT_COL)
        gd := engine.dist_horizontal(g.pos, ppos)
        label := fmt.ctprintf("%s (%.0fu)", g.name, gd)
        lw := radar_text_w(label)
        // Nudge the label inward so it never spills off the region edge.
        lx := clamp(ep.x + 10, map_rect.x + 2, map_rect.width - lw - 2)
        radar_label(lx, clamp(ep.y - 8, 2, fh - 16), label, GIANT_COL)
      }
    }

    // selected target (m_pObjFocus) - a bright yellow ring + its name, so you can see what's locked
    if focus != 0 && focus_pos_ok {
      fp := radar_w2s(cam, scale, center, focus_pos[0], focus_pos[2])
      radar_ring(fp, 9, SEL_COL)
      radar_ring(fp, 11, SEL_COL)
      if sel_name != "" {
        radar_label(fp.x + 13, fp.y - 8, fmt.ctprintf("%s", sel_name), SEL_COL)
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
      radar_ring(hpv, 7, HOVER_COL)
      if hover_name != "" {
        radar_label(hpv.x + 10, hpv.y - 8, fmt.ctprintf("%s", hover_name), HOVER_COL)
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
      radar_label(sp.x - radar_text_w(txt) * 0.5, sp.y - frac * 30 - 22, txt, col)
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

    // inspect mode: the active-mode banner. The per-collider identity readout is an ImGui tooltip now
    // (gui_frame does not own it - it is cursor-anchored map data, so it is drawn here).
    if inspect {
      radar_label(10, fh - 26, insp_pick >= 0 ? "INSPECT - click to ignore this kind" : "INSPECT - hover a purple box", rl.Color{90, 220, 255, 255})
      if insp_lines != nil {
        imgui.SetNextWindowPos({mouse.x + 16, mouse.y + 12}, .Always)
        if imgui.Begin("##inspect", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoSavedSettings, .AlwaysAutoResize, .NoNavInputs, .NoMouseInputs, .NoDocking}) {
          for l in insp_lines {
            imgui.TextUnformatted(l)
          }
        }
        imgui.End()
      }
    }

    // === UI === (see gui.odin). Built here in the UNLOCKED phase from the gf snapshot; every action it
    // wants lands in ps.pending and is drained under exec_mutex below, exactly like a typed REPL line.
    gui_frame(session, &ps, &gf, Gui_View{edit = &edit, cam_lock = &cam_lock, recenter = &recenter_req, tool = &tool, tag = &tag_i})
    imgui_rl.end() // renders the ImGui draw data through rlgl - must be inside Begin/EndDrawing

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
