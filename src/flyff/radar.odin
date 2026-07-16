package flyff

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:time"
import rl "vendor:raylib"

import "../engine"

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
CAM_COL :: rl.Color{90, 200, 225, 255} // camera eye + frustum cone (cyan; toggled with F)

MOB_COL :: rl.Color{231, 76, 60, 255} // attackable monster (red)
PLAYER_COL :: rl.Color{80, 150, 255, 255} // another player (azure; drawn larger, with a facing arrow)
OTHER_COL :: rl.Color{130, 140, 150, 220} // pet / egg / NPC (neutral grey)
UNCLASS_COL :: rl.Color{231, 76, 60, 255} // any mover, when the AI gate isn't configured (falls back to red)
SEL_COL :: rl.Color{241, 196, 15, 255} // selected-target highlight ring (yellow)
RANGE_COL :: rl.Color{46, 204, 113, 130} // attack_range ring around the player (soft green)

// --- Phase 4 radar interaction (click-to-target / shift-click-to-move) + juice (penya pop, move mark) ---
HIT_R :: f32(12) // screen-px radius: a left-click within this of a mob dot targets it
POP_TTL :: i64(1_200_000_000) // "+penya" pop lifetime (~1.2s): rises + fades over this
MARK_TTL :: i64(900_000_000) // move-destination marker lifetime (~0.9s)
PENYA_COL :: rl.Color{255, 208, 64, 255} // "+penya" pop text (gold)
HOVER_COL :: rl.Color{255, 255, 255, 180} // ring on the mob a plain click would target (white)
MARK_COL :: rl.Color{90, 200, 225, 255} // shift-click move-destination pip (cyan)

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
}

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
    res := compute_reach(session, world, ppos[0], ppos[1], ppos[2], m.pos[0], m.pos[2])
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

// Gather live movers from the player's tile + neighbours' m_apObject[OT_MOVER] arrays, within `radius`
// of (px,pz). Camera-independent and cheap (movers per tile are few). Each is classified (monster /
// player / other) via its species AI: <propbase> is the resolved MoverProp array base (0 => everything
// Unclassified) and <player_ai> the local player's species AI (0xFFFFFFFF => don't flag players). The
// <player> object itself is skipped (it's drawn separately as the white arrow). Appends Radar_Blips.
radar_gather_movers :: proc(session: ^Session, world, player: uintptr, propbase: uintptr, player_ai: u32, px, pz, radius: f32, out: ^[dynamic]Radar_Blip) {
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
          blip := Radar_Blip{pos = pos, obj = obj, kind = kind}
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

// ===========================================================================
// World <-> screen (world-anchored, pannable, zoomable). cam = the world (x,z) at the screen center;
// scale = pixels per world unit; center = screen midpoint.
// ===========================================================================

radar_w2s :: proc(cam: [2]f32, scale: f32, center: rl.Vector2, wx, wz: f32) -> rl.Vector2 {
  return {center.x + (wx - cam[0]) * scale, center.y + (wz - cam[1]) * scale}
}
radar_s2w :: proc(cam: [2]f32, scale: f32, center: rl.Vector2, sx, sy: f32) -> [2]f32 {
  return {cam[0] + (sx - center.x) / scale, cam[1] + (sy - center.y) / scale}
}
// Rotate a 2D (x,z) vector by a_rad (matches the world->screen axes: +z is screen-down).
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
  fz := math.cos(theta) // screen-y component (+ = down = +world z)
  tip := rl.Vector2{sp.x + fx * length, sp.y + fz * length}
  bl := rl.Vector2{sp.x + fz * half, sp.y - fx * half} // base corners (perp to the heading)
  br := rl.Vector2{sp.x - fz * half, sp.y + fx * half}
  rl.DrawTriangle(tip, bl, br, col) // fill (winding may cull; outline below always shows)
  rl.DrawTriangleLines(tip, bl, br, col)
}

// Draw one committed fence shape (green for +, orange for -). Polygons are outlined (fill needs
// triangulation and the mob shading conveys membership anyway).
radar_draw_shape :: proc(s: Fence_Shape, cam: [2]f32, scale: f32, center: rl.Vector2) {
  line := s.include ? FENCE_INC : FENCE_EXC
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
    rl.DrawRectangleV(p0, {p1.x - p0.x, p1.y - p0.y}, fill)
    rl.DrawRectangleLinesEx({p0.x, p0.y, p1.x - p0.x, p1.y - p0.y}, 1.5, line)
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
    rl.DrawRectangleV(p0, {p1.x - p0.x, p1.y - p0.y}, fill)
    rl.DrawRectangleLinesEx({p0.x, p0.y, p1.x - p0.x, p1.y - p0.y}, 2, red)
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
  view_r := f32(80)

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
    radar_gather_movers(session, world, probe_player, probe_pb, probe_pai, ppos[0], ppos[2], view_r + 20, &probe)
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

  scale := f32(3.0) // pixels per world unit; mouse wheel zooms
  cam := [2]f32{ppos[0], ppos[2]} // world point at screen center; right-drag pans, C recenters on player
  show_cam := false // F toggles the render-camera eye + frustum overlay
  show_reach := true // R toggles fading of monsters the collision check can't reach (off = less per-frame work)
  start := rl.GetTime()

  // Fence editor state - all local. session.fence is mutated only here (and by the `fence` commands),
  // always under the REPL's exec_mutex, so it never races the watcher's picker. poly_wip is heap-owned
  // (it lives across frames while the temp allocator is reclaimed each frame).
  edit := false
  tool := Radar_Tool.Circle
  include := true
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
  // penya field-watch (spawns "+penya" pops on a rise) + the pop/marker lists + the hover-target.
  penya_seeded := false
  last_penya: i64
  pops := make([dynamic]Penya_Pop)
  marks := make([dynamic]Move_Mark)
  defer delete(pops)
  defer delete(marks)
  hover_obj: uintptr // nearest hittable mob under the cursor (view mode) - drawn as a ring, plain-click targets it
  hover_pos: [3]f32

  // cli_radar is entered holding exec_mutex (run_cli locks around every command). We keep that invariant:
  // each frame's session work runs locked, and we RELEASE the lock across the draw/present so the watcher
  // can farm, re-acquiring before the next iteration. On every exit path the mutex is held (run_cli unlocks).
  for !rl.WindowShouldClose() {
    if dur > 0 && rl.GetTime() - start >= dur {
      break
    }

    fw := f32(rl.GetScreenWidth())
    fh := f32(rl.GetScreenHeight())
    center := rl.Vector2{(fw - PANEL_W) / 2, fh / 2} // recentre the world into the left region (panel on the right)
    mouse := rl.GetMousePosition()
    mw := radar_s2w(cam, scale, center, mouse.x, mouse.y) // world (x,z) under the cursor
    // Gate world input: panel clicks/scroll must never pan/zoom/edit the map, and typing in a panel
    // textbox must not trigger the E/F/R/C or fence hotkeys. (Modal open => treat all as panel.)
    mouse_in_panel := mouse.x >= fw - PANEL_W || ps.setup_open
    typing := ps.search_edit || ps.name_edit || ps.hp_edit

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

    // --- input: view controls + fence editor (both modes). Gated so the panel owns its region. ---
    if !mouse_in_panel && !typing {
    scale += rl.GetMouseWheelMove() * 0.5
    if scale < 0.5 {scale = 0.5}
    if scale > 24 {scale = 24}
    if rl.IsMouseButtonDown(.RIGHT) { // right-drag pans the world-anchored camera
      d := rl.GetMouseDelta()
      cam[0] -= d.x / scale
      cam[1] -= d.y / scale
    }
    if rl.IsKeyPressed(.E) {edit = !edit}
    if rl.IsKeyPressed(.F) {show_cam = !show_cam}
    if rl.IsKeyPressed(.R) {show_reach = !show_reach}
    if rl.IsKeyPressed(.C) || rl.IsKeyPressed(.HOME) {cam = {ppos[0], ppos[2]}}

    // --- input: fence editor (edit mode) ---
    if edit {
      if rl.IsKeyPressed(.ONE) {tool = .Circle}
      if rl.IsKeyPressed(.TWO) {tool = .Rect}
      if rl.IsKeyPressed(.THREE) {tool = .Polygon}
      if rl.IsKeyPressed(.FOUR) {tool = .Eraser}
      if rl.IsKeyPressed(.TAB) {include = !include}
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
          s := Fence_Shape{kind = .Polygon, include = include}
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
              append(&session.fence.shapes, Fence_Shape{kind = .Circle, include = include, cx = drag_start[0], cz = drag_start[1], r = r})
              session.fence.active = true
            }
          } else {
            minx := min(drag_start[0], mw[0])
            maxx := max(drag_start[0], mw[0])
            minz := min(drag_start[1], mw[1])
            maxz := max(drag_start[1], mw[1])
            if (maxx - minx) > 0.5 && (maxz - minz) > 0.5 {
              append(&session.fence.shapes, Fence_Shape{kind = .Rect, include = include, minx = minx, minz = minz, maxx = maxx, maxz = maxz})
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

    // --- live data (snapshot shared state before releasing the lock) ---
    w := read_ptr_at(handle, base + L.world_rva, pt)
    mobs := make([dynamic]Radar_Blip, context.temp_allocator)
    obbs: []Obb
    focus: uintptr // currently selected target (m_pObjFocus); 0 = nothing selected
    focus_pos: [3]f32
    focus_pos_ok := false
    if w != 0 {
      propbase, player_ai := radar_prop_ctx(session, player)
      radar_gather_movers(session, w, player, propbase, player_ai, ppos[0], ppos[2], view_r + 20, &mobs)
      if show_reach {
        radar_reach_pass(session, w, ppos, mobs[:]) // fade monsters the collision check can't reach
      }
      // collect_area_colliders returns session.collider_cache[:], which the watcher's reach gate also
      // rewrites - clone it into temp so drawing after we unlock can't touch a slice being reallocated.
      obbs = slice.clone(collect_area_colliders(session, w, ppos[0], ppos[2]), context.temp_allocator)
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
    // penya field-watch: pop "+N penya" when the live gold field rises (loot pickup). Read under the lock.
    if L.penya_off != 0 && player != 0 {
      if pvv, ok := engine.read_value(handle, player + uintptr(L.penya_off), .U32); ok {
        cur := i64(u32(engine.value_as_u64(.U32, pvv)))
        if !penya_seeded {
          last_penya = cur
          penya_seeded = true
        } else if cur > last_penya {
          append(&pops, Penya_Pop{amount = cur - last_penya, t = time.now()._nsec, pos = ppos})
          last_penya = cur
        } else if cur < last_penya {
          last_penya = cur // spent penya (repair / buy) - re-baseline, no pop
        }
      }
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
    groups := setup_groups(session)
    opins := optional_pins(session)
    status_hdr := setup_status_line(session)
    auto_on_s := session.auto_on
    auto_paused_s := session.auto_paused
    auto_desc_s := auto_target_desc(session.auto_names[:])
    auto_line_s := auto_on_s ? auto_stats(session, time.now()._nsec) : ""
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

    // --- draw ---
    rl.BeginDrawing()
    rl.ClearBackground(rl.Color{12, 16, 22, 255})
    // Clip all world/HUD drawing to the left region so nothing bleeds under the right-side panel.
    rl.BeginScissorMode(0, 0, i32(fw - PANEL_W), i32(fh))
    // screen-center crosshair (the current camera focus)
    rl.DrawLineV({center.x, 0}, {center.x, fh}, rl.Color{28, 38, 50, 255})
    rl.DrawLineV({0, center.y}, {fw, center.y}, rl.Color{28, 38, 50, 255})

    // obstacles: solid blockers (real collision mesh / OT_CTRL) as a filled purple box + bright outline;
    // walk-through props (GMT_ERROR - the game paths straight through them) as a faint grey outline only.
    // Both are shown so you can see the field, but the fill tells you which actually blocks. A minimum
    // on-screen size keeps small rocks from vanishing. (Axis-aligned from the OBB extent; rotation TODO.)
    for o in obbs {
      if o.ext[0] <= 0.01 && o.ext[2] <= 0.01 {
        continue // degenerate / uninitialised OBB (nothing to draw; would be a stray dot at the origin)
      }
      p := radar_w2s(cam, scale, center, o.center[0], o.center[2])
      bw := max(2 * o.ext[0] * scale, 5)
      bh := max(2 * o.ext[2] * scale, 5)
      rect := rl.Rectangle{p.x - bw / 2, p.y - bh / 2, bw, bh}
      if o.decorative {
        rl.DrawRectangleLinesEx(rect, 1, rl.Color{130, 140, 155, 95}) // walk-through -> outline only
      } else {
        rl.DrawRectangleV({rect.x, rect.y}, {bw, bh}, rl.Color{155, 89, 182, 70}) // blocker fill
        rl.DrawRectangleLinesEx(rect, 1.5, rl.Color{175, 115, 205, 205}) // + bright outline
      }
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
      col := include ? FENCE_INC : FENCE_EXC
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
      col := include ? FENCE_INC : FENCE_EXC
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

    // movers: coloured/sized by kind (red mob, azure player w/ facing arrow, grey pet/npc). Gate-eligible
    // mobs (monsters / unclassified) outside the fence are dimmed so the editor previews the target gate;
    // ones the reach check can't reach are drawn faded (R toggles).
    have_fence := len(session.fence.shapes) > 0
    for m in mobs {
      p := radar_w2s(cam, scale, center, m.pos[0], m.pos[2])
      col, radius := radar_blip_style(m.kind)
      gate_eligible := m.kind == .Monster || m.kind == .Unclassified
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

    // selected target (m_pObjFocus) - a bright yellow ring so you can see what's currently locked
    if focus != 0 && focus_pos_ok {
      fp := radar_w2s(cam, scale, center, focus_pos[0], focus_pos[2])
      rl.DrawCircleLinesV(fp, 9, SEL_COL)
      rl.DrawCircleLinesV(fp, 11, SEL_COL)
    }

    // player dot + facing arrow (m_fAngle; same convention as the tdbg HTML: on-screen dir = angle+180)
    pp := radar_w2s(cam, scale, center, ppos[0], ppos[2])
    if has_angle {
      radar_draw_arrow(pp, pangle, 17, 6, rl.RAYWHITE)
    }
    rl.DrawCircleV(pp, 5, rl.WHITE)

    // hover ring: the mob a plain left-click would target (view mode)
    if hover_obj != 0 {
      hpv := radar_w2s(cam, scale, center, hover_pos[0], hover_pos[2])
      rl.DrawCircleLinesV(hpv, 7, HOVER_COL)
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

    // HUD
    toolname: cstring = tool == .Circle ? "circle" : tool == .Rect ? "rect" : tool == .Polygon ? "polygon" : "eraser"
    rl.DrawText(fmt.ctprintf("%s | fence %s | %d shapes | tool:%s tag:%s | cam:%s | reach:%s | %.1f px/u", edit ? "EDIT" : "view", session.fence.active ? "ON" : "off", len(session.fence.shapes), toolname, include ? "+" : "-", show_cam ? "on" : "off", show_reach ? "on" : "off", scale), 10, 10, 18, rl.RAYWHITE)
    legend: cstring = prop_gate_ready(session) ? "red:mob  blue:player  grey:pet/npc  faded:unreachable  yellow ring:target  green ring:attack_range" : "movers:red (run 'findprop' to tell players/pets apart)  faded:unreachable  yellow ring:target"
    rl.DrawText(legend, 10, 32, 14, rl.Color{150, 160, 172, 255})
    hint: cstring = "click:target  shift+click:move  E:edit fence  F:camera  R:reach  wheel:zoom  RMB-drag:pan  C:recenter  ESC:close"
    if edit {
      hint = "E:view  1/2/3:draw  4:erase  Tab:+/-  Ldrag/click  Enter:close-poly  Bksp:undo  Del:clear  A:on/off  R:reach  RMB-drag:pan  F:cam  C:recenter"
    }
    rl.DrawText(hint, 10, i32(fh) - 24, 16, rl.Color{150, 160, 172, 255})
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
    if ps.setup_open {rl.GuiLock()} // freeze the background widgets while the modal is up

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

    // Setup dialog trigger
    if rl.GuiButton({x0, y, pw, 28}, "Setup...") {
      ps.setup_open = true
      ps.name_edit = true
    }
    y += 36

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
      rl.DrawText(fmt.ctprintf("%s: %s", auto_paused_s ? "ARMED" : "ON", auto_desc_s), i32(x0), i32(y), 11, rl.Color{150, 170, 190, 255})
      y += 15
      rl.DrawText(fmt.ctprintf("%s", auto_line_s), i32(x0), i32(y), 11, rl.Color{120, 190, 140, 255})
      y += 16
    } else {
      rl.DrawText(fmt.ctprintf("target: %s", len(ps.selected) == 0 ? "any monster" : "the chips below"), i32(x0), i32(y), 11, PANEL_DIM)
      y += 16
    }

    // mob search box + live-filtered suggestions
    rl.DrawText("target mobs (search, click to add)", i32(x0), i32(y), 11, PANEL_DIM)
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
    rl.DrawText(fmt.ctprintf("attack_range: %.2f", ps.ar_slider), i32(x0), i32(y), 12, PANEL_HDR)
    y += 18
    sl := rl.Rectangle{x0 + 4, y, pw - 8, 18}
    rl.GuiSlider(sl, "0", "30", &ps.ar_slider, 0, 30)
    if !ps.setup_open && rl.IsMouseButtonDown(.LEFT) && rl.CheckCollisionPointRec(mouse, sl) {
      ps.ar_dragging = true
    }
    if ps.ar_dragging && rl.IsMouseButtonReleased(.LEFT) {
      ps.ar_dragging = false
      panel_enqueue(&ps, fmt.tprintf("set attack_range %.3f", ps.ar_slider))
    }
    y += 26

    // --- VIEW / FENCE toolbar (view toggles flip local bools; fence state is deferred) ---
    rl.DrawLine(i32(x0), i32(y), i32(x0 + pw), i32(y), PANEL_SEP)
    y += 8
    rl.DrawText("VIEW / FENCE", i32(x0), i32(y), 13, PANEL_HDR)
    y += 18
    bw := (pw - 10) / 2
    if rl.GuiButton({x0, y, bw, 26}, edit ? "Edit: ON" : "Edit: off") {edit = !edit}
    if rl.GuiButton({x0 + bw + 10, y, bw, 26}, show_cam ? "Camera: ON" : "Camera: off") {show_cam = !show_cam}
    y += 30
    if rl.GuiButton({x0, y, bw, 26}, show_reach ? "Reach: ON" : "Reach: off") {show_reach = !show_reach}
    if rl.GuiButton({x0 + bw + 10, y, bw, 26}, "Recenter") {cam = {ppos[0], ppos[2]}}
    y += 30
    if rl.GuiButton({x0, y, bw, 26}, session.fence.active ? "Fence: ON" : "Fence: off") {
      panel_enqueue(&ps, session.fence.active ? "fence off" : "fence on")
    }
    if rl.GuiButton({x0 + bw + 10, y, bw, 26}, "Fence Clear") {panel_enqueue(&ps, "fence clear")}
    y += 30
    if rl.GuiButton({x0, y, bw, 26}, "Fence Undo") {panel_enqueue(&ps, "fence undo")}

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
      mh2 := f32(268)
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
      bw2 := (mw2 - 40) / 2
      if rl.GuiButton({mx + 14, my + mh2 - 40, bw2, 28}, "Run setup") {
        nm := strings.trim_space(panel_buf_str(ps.name_buf[:]))
        if len(nm) > 0 {
          hp := strings.trim_space(panel_buf_str(ps.hp_buf[:]))
          panel_enqueue(&ps, len(hp) > 0 ? fmt.tprintf("setup %s %s", nm, hp) : fmt.tprintf("setup %s", nm))
          // penya isn't derivable from the name anchor (it needs a live value), so it rides as a second
          // command: findpenya pins penya_off from the number you read off the game UI. Commas tolerated.
          py := strings.trim_space(panel_buf_str(ps.penya_buf[:]))
          py, _ = strings.remove_all(py, ",", context.temp_allocator)
          if len(py) > 0 {
            panel_enqueue(&ps, fmt.tprintf("findpenya %s", py))
          }
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
    rl.EndDrawing()

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
