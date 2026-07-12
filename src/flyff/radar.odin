package flyff

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strconv"
import "core:sync"
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

// Radar editor tool. The three draw tools map 1:1 to Fence_Kind; Eraser deletes the shape under the cursor.
Radar_Tool :: enum {
  Circle,
  Rect,
  Polygon,
  Eraser,
}

// Gather live mover positions from the player's tile + neighbours' m_apObject[OT_MOVER] arrays, within
// `radius` of (px,pz). Camera-independent and cheap (movers per tile are few). Appends world positions.
radar_gather_movers :: proc(session: ^Session, world: uintptr, px, pz, radius: f32, out: ^[dynamic][3]f32) {
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
          append(out, pos)
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
    fmt.eprintln("radar: world/player not resolved - run 'calibrate'.")
    return
  }
  probe := make([dynamic][3]f32, context.temp_allocator)
  radar_gather_movers(session, world, ppos[0], ppos[2], view_r + 20, &probe)
  probe_obbs := collect_area_colliders(session, world, ppos[0], ppos[2])
  fmt.printfln("radar: player (%.1f, %.1f), %d movers, %d obstacles in view. opening window%s...", ppos[0], ppos[2], len(probe), len(probe_obbs), dur > 0 ? fmt.tprintf(" for %.0fs", dur) : "")
  free_all(context.temp_allocator)

  rl.SetConfigFlags({.WINDOW_RESIZABLE})
  rl.InitWindow(820, 820, "memscan radar")
  defer rl.CloseWindow() // raylib's own (via /WHOLEARCHIVE:raylib.lib) - see note atop this file
  rl.SetTargetFPS(30)

  scale := f32(3.0) // pixels per world unit; mouse wheel zooms
  cam := [2]f32{ppos[0], ppos[2]} // world point at screen center; right-drag pans, C recenters on player
  show_cam := false // F toggles the render-camera eye + frustum overlay
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

  // cli_radar is entered holding exec_mutex (run_cli locks around every command). We keep that invariant:
  // each frame's session work runs locked, and we RELEASE the lock across the draw/present so the watcher
  // can farm, re-acquiring before the next iteration. On every exit path the mutex is held (run_cli unlocks).
  for !rl.WindowShouldClose() {
    if dur > 0 && rl.GetTime() - start >= dur {
      break
    }

    fw := f32(rl.GetScreenWidth())
    fh := f32(rl.GetScreenHeight())
    center := rl.Vector2{fw / 2, fh / 2}
    mouse := rl.GetMousePosition()
    mw := radar_s2w(cam, scale, center, mouse.x, mouse.y) // world (x,z) under the cursor

    // --- live player pos + facing (single player resolve) ---
    pangle: f32
    has_angle := false
    if player := read_ptr_at(handle, base + L.player_rva, pt); player != 0 {
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

    // --- input: view controls (both modes) ---
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

    // --- live data (snapshot shared state before releasing the lock) ---
    w := read_ptr_at(handle, base + L.world_rva, pt)
    mobs := make([dynamic][3]f32, context.temp_allocator)
    obbs: []Obb
    if w != 0 {
      radar_gather_movers(session, w, ppos[0], ppos[2], view_r + 20, &mobs)
      // collect_area_colliders returns session.collider_cache[:], which the watcher's reach gate also
      // rewrites - clone it into temp so drawing after we unlock can't touch a slice being reallocated.
      obbs = slice.clone(collect_area_colliders(session, w, ppos[0], ppos[2]), context.temp_allocator)
    }
    ceye, clook: [3]f32
    cam_ok := false
    if show_cam {
      ceye, clook, cam_ok = read_camera(session)
    }

    // Release exec_mutex for the draw/present so the watcher thread can run auto_tick this frame. All
    // session reads below (session.fence.shapes) have no concurrent writer: the radar's own fence writes
    // are above (locked) and the watcher only reads the fence.
    sync.mutex_unlock(&session.exec_mutex)

    // --- draw ---
    rl.BeginDrawing()
    rl.ClearBackground(rl.Color{12, 16, 22, 255})
    // screen-center crosshair (the current camera focus)
    rl.DrawLineV({center.x, 0}, {center.x, fh}, rl.Color{28, 38, 50, 255})
    rl.DrawLineV({0, center.y}, {fw, center.y}, rl.Color{28, 38, 50, 255})

    // obstacles (axis-aligned box from the OBB extent; rotation comes later)
    for o in obbs {
      p := radar_w2s(cam, scale, center, o.center[0], o.center[2])
      bw := 2 * o.ext[0] * scale
      bh := 2 * o.ext[2] * scale
      col := o.decorative ? rl.Color{120, 130, 145, 60} : rl.Color{155, 89, 182, 120}
      rl.DrawRectangleV({p.x - bw / 2, p.y - bh / 2}, {bw, bh}, col)
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

    // mobs (shaded by fence membership so the editor previews the target gate)
    have_fence := len(session.fence.shapes) > 0
    for m in mobs {
      p := radar_w2s(cam, scale, center, m[0], m[2])
      col := rl.Color{231, 76, 60, 255}
      if have_fence && !fence_geom_contains(session.fence, m[0], m[2]) {
        col = rl.Color{90, 96, 105, 200} // outside the fence -> dimmed (would be skipped)
      }
      rl.DrawCircleV(p, 3, col)
    }

    // player dot + facing arrow (m_fAngle; same convention as the tdbg HTML: on-screen dir = angle+180)
    pp := radar_w2s(cam, scale, center, ppos[0], ppos[2])
    if has_angle {
      theta := math.to_radians(pangle + 180)
      fx := -math.sin(theta) // screen-x component
      fz := math.cos(theta) // screen-y component (+ = down = +world z)
      tip := rl.Vector2{pp.x + fx * 17, pp.y + fz * 17}
      bl := rl.Vector2{pp.x + fz * 6, pp.y - fx * 6} // base corners (perp to the heading)
      br := rl.Vector2{pp.x - fz * 6, pp.y + fx * 6}
      rl.DrawTriangle(tip, bl, br, rl.RAYWHITE) // fill (winding may cull; outline below always shows)
      rl.DrawTriangleLines(tip, bl, br, rl.RAYWHITE)
    }
    rl.DrawCircleV(pp, 5, rl.WHITE)

    // HUD
    toolname: cstring = tool == .Circle ? "circle" : tool == .Rect ? "rect" : tool == .Polygon ? "polygon" : "eraser"
    rl.DrawText(fmt.ctprintf("%s | fence %s | %d shapes | tool:%s tag:%s | cam:%s | %.1f px/u", edit ? "EDIT" : "view", session.fence.active ? "ON" : "off", len(session.fence.shapes), toolname, include ? "+" : "-", show_cam ? "on" : "off", scale), 10, 10, 18, rl.RAYWHITE)
    hint: cstring = "E:edit fence   F:camera   wheel:zoom   Rdrag:pan   C:recenter   ESC:close"
    if edit {
      hint = "E:view  1/2/3:draw  4:erase  Tab:+/-  Ldrag/click  Enter:close-poly  Bksp:undo  Del:clear  A:on/off  Rdrag:pan  F:cam  C:recenter"
    }
    rl.DrawText(hint, 10, i32(fh) - 24, 16, rl.Color{150, 160, 172, 255})
    rl.EndDrawing()

    free_all(context.temp_allocator) // reclaim this frame's mob array + collider snapshot + HUD strings
    sync.mutex_lock(&session.exec_mutex) // re-acquire before the next iteration (and for run_cli to unlock)
  }
}
