package flyff

import "core:fmt"
import "core:strconv"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "../engine"

// Default marker colour if none is given and it happens to be warm (16 = red, most visible).
DEFAULT_MARK_TYPE :: 16

// The warm particle types are tiny angel-buff sparkles (size ~0.15), so a single dot is nearly
// invisible. We instead spawn a tall DENSE column (a pillar) centred on the target so it's unmissable.
MARK_Y_OFFSET :: 0.5 // start just above the feet
MARK_BEACON_COUNT :: 60 // dots stacked vertically (overlap into a continuous line)
MARK_BEACON_HEIGHT :: 14.0 // pillar height in world units
// Re-spawn cadence while holding a marker (each dot fades in ~1s, so <1s keeps it continuously visible).
MARK_HOLD_INTERVAL_MS :: 600

// Preference order when auto-picking a warm type for a bare `mark` (visible colours first).
mark_type_prefs := [?]int{16, 17, 18, 19, 20, 21, 13, 14, 15, 22, 23, 24, 2, 3, 4}

// mark [x,y,z] [type] - drop one billboard-sprite dot in the world for debugging.
//   no coords  -> at the player's current position
//   x,y,z      -> at that world position (as printed by the in-game /position command)
//   type 0..31 -> colour (13-15 blue, 16-18 red, 19-21 white, 22-24 green; 0 uses g_clrColor)
// See remote_spawn_particles / flyff-particle-draw.md. Injects one remote thread; ~1s lifetime.
cli_mark :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if session.ptr_size != 4 {
    fmt.eprintln("mark: 32-bit Flyff client only.")
    return
  }
  if session.layout.particlemng_rva == 0 || session.layout.createparticle_rva == 0 {
    fmt.eprintln("mark: particlemng_rva/createparticle_rva not set (check flyff.cfg).")
    return
  }

  // Parse: "x,y,z" (comma) = position; "Ns" = hold for N seconds; a bare integer = colour type.
  ntype := DEFAULT_MARK_TYPE
  explicit_type := false
  have_pos := false
  hold_secs := 0
  pos: [3]f32
  for a in args {
    if strings.contains(a, ",") {
      if p, ok := parse_vec3_literal(a); ok {
        pos = p
        have_pos = true
      } else {
        fmt.eprintfln("mark: bad coords %q (want x,y,z).", a)
        return
      }
    } else if strings.has_suffix(a, "s") && len(a) > 1 {
      if s, ok := strconv.parse_int(a[:len(a) - 1]); ok && s > 0 {
        hold_secs = s
      } else {
        fmt.eprintfln("mark: bad hold duration %q (want e.g. 5s).", a)
        return
      }
    } else if v, ok := strconv.parse_int(a); ok {
      ntype = v
      explicit_type = true
    } else {
      fmt.eprintfln("mark: unrecognised arg %q (want x,y,z, a type 0..31, and/or Ns hold).", a)
      return
    }
  }

  if !have_pos {
    p, ok := read_player_pos(session)
    if !ok {
      fmt.eprintln("mark: no coords given and couldn't read player position.")
      return
    }
    pos = p
  }

  if ntype < 0 || ntype >= PARTICLE_MAX_TYPE {
    fmt.eprintfln("mark: type must be 0..31 (got %d).", ntype)
    return
  }

  // Only spawn warm types (a cold type's first use does risky off-thread device init).
  if !particle_type_active(session, ntype) {
    if explicit_type {
      fmt.eprintfln("mark: particle type %d isn't initialised in the client right now.", ntype)
      mark_print_warm_types(session)
      return
    }
    // Bare `mark`: fall back to the first warm preferred colour.
    picked := -1
    for t in mark_type_prefs {
      if particle_type_active(session, t) {
        picked = t
        break
      }
    }
    if picked < 0 {
      fmt.eprintln("mark: no warm particle types available. Trigger an effect in-game (e.g. pick up")
      fmt.eprintln("      an item) to initialise one, then retry.")
      return
    }
    ntype = picked
  }

  // Build a tall dense pillar of dots centred on the target x,z so the marker is impossible to miss.
  positions := make([][3]f32, MARK_BEACON_COUNT, context.temp_allocator)
  for i in 0 ..< MARK_BEACON_COUNT {
    frac := f32(i) / f32(MARK_BEACON_COUNT - 1)
    positions[i] = {pos[0], pos[1] + MARK_Y_OFFSET + frac * MARK_BEACON_HEIGHT, pos[2]}
  }

  if hold_secs <= 0 {
    if remote_spawn_particles(session, ntype, positions) {
      fmt.printfln("mark: spawned type-%d pillar (%d dots) at (%.1f, _, %.1f).", ntype, MARK_BEACON_COUNT, pos[0], pos[2])
    } else {
      fmt.eprintln("mark: spawn failed (see error above).")
    }
    return
  }

  // Hold: re-spawn every interval so the ~1s pillar stays continuously visible for hold_secs.
  reps := (hold_secs * 1000) / MARK_HOLD_INTERVAL_MS
  if reps < 1 {
    reps = 1
  }
  fmt.printfln("mark: holding type-%d pillar (%d dots) at (%.1f, _, %.1f) for ~%ds...", ntype, MARK_BEACON_COUNT, pos[0], pos[2], hold_secs)
  for r in 0 ..< reps {
    if !remote_spawn_particles(session, ntype, positions) {
      fmt.eprintln("mark: spawn failed mid-hold (see error above).")
      return
    }
    if r < reps - 1 {
      time.sleep(MARK_HOLD_INTERVAL_MS * time.Millisecond)
    }
  }
  fmt.println("mark: hold done.")
}

// --- markmobs: drop a marker on every enumerated mob (verify `mobs` catches them all) ------------

MARKMOBS_MAX_COUNT :: 8 // max dots per mob pillar
MARKMOBS_MIN_COUNT :: 2 // min dots per mob pillar
MARKMOBS_HEIGHT :: 4.0 // pillar height in world units
MARKMOBS_SIZE :: 0.45 // particle size (3x the stock 0.15 sparkle)
MARKMOBS_HOLD_DEFAULT :: 20 // seconds to run the tracking overlay
MARKMOBS_REFRESH_MS :: 33 // default position-update cadence (~30 Hz); pure RPM writes, so cheap
MARKMOBS_REFRESH_MIN :: 15 // floor on the refresh interval (~66 Hz)
MARKMOBS_REENUM_MS :: 4000 // full re-scan this often to pick up new spawns / drop the dead
// We reuse the same pool slots every frame (not spawn-per-frame), so pool use is spatial not
// rate-based: keep total dots under the 512-slot pool.
MARKMOBS_POOL_BUDGET :: 480
// The overlay claims ONE game-UNUSED particle type and drives it uncontended (the fix for the blink -
// warm types 13-23 are the client's own angel sparkles and it fights us for those pools). Type 30 has
// no game code path that spawns it; we warm it once (loads a texture + VB), then tint per-particle.
MARKMOBS_OVERLAY_TYPE :: 30
MARKMOBS_GREEN := [4]f32{0.1, 1.0, 0.2, 1.0} // marker colour (all markers, single colour)

Mover_Hit :: struct {
  obj:      uintptr, // the CObj* - so we can re-read its position each refresh (cheap) to follow it
  pos:      [3]f32,
  model_ok: bool, // has a mapped model -> tc/auto would target it
}

// First warm type from prefs, or (0,false) if none are initialised.
pick_warm_type :: proc(session: ^Session, prefs: []int) -> (int, bool) {
  for t in prefs {
    if particle_type_active(session, t) {
      return t, true
    }
  }
  return 0, false
}

// Enumerate every type-5 mover whose inline name case-insensitively EQUALS `name` (empty = all) -
// same name gate as `auto`/`tc` (strings.equal_fold, not substring), so markmobs marks exactly the
// set those commands would target. Same scan `mobs`/`tc` use: read the world ptr, scan all writable
// regions for copies of it (each hit is obj+field_off), keep in-module vtables of mover_type.
// Returns world position + model-liveness per hit.
enum_movers :: proc(session: ^Session, name: string) -> [dynamic]Mover_Hit {
  hits := make([dynamic]Mover_Hit, context.temp_allocator)
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  if !wok {
    return hits
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  wval := engine.ptr_to_value(world, session.ptr_size)
  all := engine.collect_regions(handle, true)
  defer delete(all)
  set := engine.scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)
  for m in set.matches {
    obj := uintptr(i64(m.addr) - session.layout.field_off)
    vt, vok := engine.read_value(handle, obj, pt)
    if !vok {
      continue
    }
    vtable := uintptr(engine.value_as_u64(pt, vt))
    if vtable < base || vtable >= mod_end {
      continue
    }
    if engine.read_obj_type(handle, obj, session.layout.pos_off) != session.layout.mover_type {
      continue
    }
    if name != "" {
      nm, nok := read_mover_name(session, obj)
      if !nok || !strings.equal_fold(nm, name) {
        continue
      }
    }
    pos, posok := engine.read_vec3(handle, obj + uintptr(session.layout.pos_off))
    if !posok {
      continue
    }
    model: uintptr = 0
    if mv, mok := engine.read_value(handle, obj + uintptr(session.layout.model_off), pt); mok {
      model = uintptr(engine.value_as_u64(pt, mv))
    }
    model_ok := false
    if model >= 0x10000 {
      if _, r := engine.read_value(handle, model, pt); r {
        model_ok = true
      }
    }
    append(&hits, Mover_Hit{obj = obj, pos = pos, model_ok = model_ok})
  }
  return hits
}

// Cheap per-refresh update: re-read the position + model-liveness of a KNOWN object list (no memory
// scan). Skips any obj whose vtable is no longer in-module (despawned/freed) so we stop drawing on
// dead mobs. This is what lets the markers follow moving mobs at ~2 Hz between full re-enumerations.
reread_movers :: proc(session: ^Session, objs: []uintptr) -> [dynamic]Mover_Hit {
  hits := make([dynamic]Mover_Hit, context.temp_allocator)
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  for obj in objs {
    vt, vok := engine.read_value(handle, obj, pt)
    if !vok {
      continue
    }
    vtable := uintptr(engine.value_as_u64(pt, vt))
    if vtable < base || vtable >= mod_end {
      continue // despawned / freed since enumeration
    }
    pos, posok := engine.read_vec3(handle, obj + uintptr(session.layout.pos_off))
    if !posok {
      continue
    }
    model: uintptr = 0
    if mv, mok := engine.read_value(handle, obj + uintptr(session.layout.model_off), pt); mok {
      model = uintptr(engine.value_as_u64(pt, mv))
    }
    model_ok := false
    if model >= 0x10000 {
      if _, r := engine.read_value(handle, model, pt); r {
        model_ok = true
      }
    }
    append(&hits, Mover_Hit{obj = obj, pos = pos, model_ok = model_ok})
  }
  return hits
}

// --- Direct particle-pool control (no injection) -------------------------------------------------
// We drive a fixed set of particles by writing the pool + list straight into memory each frame, so
// markers move EXACTLY with the mob (we rewrite their position) at CONSTANT alpha (fade colour ==
// diffuse, and m_fFade pinned so the client never expires them). Offsets verified live 2026-07-07.
//
// CParticles (base = g_ParticleMng + 8 + type*0x3C):
PC_POOL :: 0x00 // PARTICLE* m_pPool (pool array base)
PC_POOLPTR :: 0x04 // int m_nPoolPtr
PC_NPARTICLES :: 0x18 // DWORD m_dwParticles
PC_NPARTICLESLIM :: 0x1C // DWORD m_dwParticlesLim (512 in this build)
PC_PARTICLES :: 0x20 // PARTICLE* m_pParticles (active list head)
PC_PARTICLESFREE :: 0x24 // PARTICLE* m_pParticlesFree
PC_PVB :: 0x28 // LPDIRECT3DVERTEXBUFFER9 m_pVB
PC_FSIZE :: 0x34 // FLOAT m_fSize
PC_PTEXTURE :: 0x38 // LPDIRECT3DTEXTURE9 m_pParticleTexture
// PARTICLE struct (0x44 bytes):
PT_SIZE :: 0x44
PT_VPOS :: 0x00 // D3DXVECTOR3 m_vPos
PT_VVEL :: 0x0C // D3DXVECTOR3 m_vVel
PT_DIFFUSE :: 0x18 // D3DXCOLOR m_clrDiffuse (r,g,b,a floats)
PT_FADE :: 0x28 // D3DXCOLOR m_clrFade
PT_FFADE :: 0x38 // FLOAT m_fFade (>0 or the client removes the particle)
PT_GROUNDY :: 0x3C // FLOAT m_fGroundY
PT_PNEXT :: 0x40 // PARTICLE* m_pNext
// m_fFade we write: large so the client's Update (-=0.015/frame) can't expire our particles even if
// we don't refresh for seconds (e.g. during a full re-scan) - that stops the periodic disappear-blink.
// Colour stays constant regardless because we set m_clrDiffuse == m_clrFade (their lerp is a no-op).
OVERLAY_FFADE :: f32(1000.0)

particle_cparticles_addr :: proc(session: ^Session, ntype: int) -> uintptr {
  return session.proc_info.base + session.layout.particlemng_rva + uintptr(8 + ntype * PARTICLE_CPARTICLES_SIZE)
}

wr_u32 :: proc(handle: win.HANDLE, addr: uintptr, v: u32) -> bool {
  b: [4]byte
  put32_le(b[:], v)
  w: uint
  return win.WriteProcessMemory(handle, rawptr(addr), raw_data(b[:]), 4, &w) != win.FALSE && w == 4
}

// Drive type `ntype`'s particle pool to exactly `positions`: build the PARTICLE array + linked list in
// one bulk write (constant white diffuse+fade so the texture colour shows at steady alpha, m_fFade=1,
// m_vVel=0, ground far below so gravity never removes them), then point the active list at it. Called
// every refresh with fresh positions so the SAME particles move to follow the mobs (no trail). Pure
// RPM writes - no injected code. The list nodes are stable across frames so a concurrent client-side
// Update walk reads identical m_pNext bytes (benign). Caller must have verified the type is warm.
overlay_drive_type :: proc(session: ^Session, ntype: int, positions: [][3]f32, colors: [][4]f32, size: f32) -> bool {
  handle := session.proc_info.handle
  cp := particle_cparticles_addr(session, ntype)
  pool_v, ok := engine.read_value(handle, cp + PC_POOL, .U32)
  if !ok {
    return false
  }
  pool := uintptr(engine.value_as_u64(.U32, pool_v))
  if pool < 0x10000 {
    return false
  }
  n := len(positions)
  if lim_v, lok := engine.read_value(handle, cp + PC_NPARTICLESLIM, .U32); lok {
    lim := int(engine.value_as_u64(.U32, lim_v))
    if lim > 0 && n > lim {
      n = lim
    }
  }
  if n == 0 {
    overlay_clear_type(session, ntype)
    return true
  }

  fade: u32 = transmute(u32)OVERLAY_FFADE
  low: u32 = transmute(u32)f32(-1.0e9)
  buf := make([]byte, n * PT_SIZE, context.temp_allocator)
  for i in 0 ..< n {
    o := i * PT_SIZE
    put32_le(buf[o + PT_VPOS:], transmute(u32)positions[i][0])
    put32_le(buf[o + PT_VPOS + 4:], transmute(u32)positions[i][1])
    put32_le(buf[o + PT_VPOS + 8:], transmute(u32)positions[i][2])
    // m_vVel left {0,0,0}. m_clrDiffuse == m_clrFade == colors[i] so the lerp is constant (steady
    // colour/alpha regardless of the client's fade progression).
    for k in 0 ..< 4 {
      c := transmute(u32)colors[i][k]
      put32_le(buf[o + PT_DIFFUSE + k * 4:], c)
      put32_le(buf[o + PT_FADE + k * 4:], c)
    }
    put32_le(buf[o + PT_FFADE:], fade) // large so it survives multi-second refresh gaps
    put32_le(buf[o + PT_GROUNDY:], low) // m_fGroundY far below
    next: u32 = 0
    if i < n - 1 {
      next = u32(pool + uintptr((i + 1) * PT_SIZE))
    }
    put32_le(buf[o + PT_PNEXT:], next)
  }
  w: uint
  if win.WriteProcessMemory(handle, rawptr(pool), raw_data(buf), uint(n * PT_SIZE), &w) == win.FALSE ||
     w != uint(n * PT_SIZE) {
    return false
  }
  // Control fields: size, then point the active list at our pool (head + count). poolptr/free set so
  // the client wouldn't clobber our slots if it ever spawned this type.
  wr_u32(handle, cp + PC_FSIZE, transmute(u32)size)
  wr_u32(handle, cp + PC_POOLPTR, u32(n))
  wr_u32(handle, cp + PC_PARTICLESFREE, 0)
  wr_u32(handle, cp + PC_NPARTICLES, u32(n))
  wr_u32(handle, cp + PC_PARTICLES, u32(pool)) // head last: makes the full list live in one write
  return true
}

// Empty a type's active list so its markers stop rendering (they were ours). Leaves the pool memory.
overlay_clear_type :: proc(session: ^Session, ntype: int) {
  handle := session.proc_info.handle
  cp := particle_cparticles_addr(session, ntype)
  wr_u32(handle, cp + PC_PARTICLES, 0)
  wr_u32(handle, cp + PC_NPARTICLES, 0)
}

// Ensure particle type `ntype` is initialised (its own pool + texture + VB). If cold, inject one
// CreateParticle so the client runs its own init (verified safe - the off-thread device init doesn't
// crash). We claim a game-UNUSED type this way so nothing contends for its pool. Idempotent.
overlay_warm_type :: proc(session: ^Session, ntype: int) -> bool {
  if particle_type_active(session, ntype) {
    return true
  }
  hidden := [1][3]f32{{0, -100000, 0}}
  if !remote_spawn_particles(session, ntype, hidden[:]) {
    return false
  }
  return particle_type_active(session, ntype)
}

// Positions + per-particle colours for one snapshot: `count` stacked dots per mob. Only mobs with a
// mapped model are marked (they are the on-screen, tc/auto-targetable ones); model-less mobs (beyond
// render range - nothing visible there to mark) are skipped. One batch into a single uncontended type.
build_mob_overlay :: proc(hits: []Mover_Hit, count: int) -> (positions: [][3]f32, colors: [][4]f32) {
  pos := make([dynamic][3]f32, context.temp_allocator)
  col := make([dynamic][4]f32, context.temp_allocator)
  for h in hits {
    if !h.model_ok {
      continue // no model = beyond render range; nothing on screen to mark
    }
    for i in 0 ..< count {
      frac: f32 = count <= 1 ? 0 : f32(i) / f32(count - 1)
      append(&pos, [3]f32{h.pos[0], h.pos[1] + 0.5 + frac * MARKMOBS_HEIGHT, h.pos[2]})
      append(&col, MARKMOBS_GREEN)
    }
  }
  return pos[:], col[:]
}

// markmobs [name] [Ns] [Nms] - a live overlay: pillars on every on-screen mover tc/auto would target.
// `name` is a case-insensitive EXACT match, same gate as auto/tc (so `markmobs Aibatt` marks "Aibatt"
// only, not "Small Aibatt"); empty = all movers. Model-less mobs (beyond render range) are not drawn.
// Markers FOLLOW the mobs exactly at CONSTANT alpha: we drive a fixed particle pool directly in memory
// (overlay_drive_type) - no spawning,
// no fade, no injection. Find the mobs once (the slow scan), then each refresh (default 33ms/~30Hz,
// override e.g. `16ms`) re-read positions and rewrite the pool so the same dots move with the mobs; a
// full re-scan every ~4s catches new spawns/deaths. Runs ~20s (or `Ns`); hotkey it to re-trigger.
cli_markmobs :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if session.ptr_size != 4 {
    fmt.eprintln("markmobs: 32-bit Flyff client only.")
    return
  }
  if session.layout.particlemng_rva == 0 || session.layout.createparticle_rva == 0 {
    fmt.eprintln("markmobs: particlemng_rva/createparticle_rva not set (check flyff.cfg).")
    return
  }

  // Split args into optional "Ns" run-duration, "Nms" refresh interval, and the (multi-word) name.
  // Check "ms" before "s" since "100ms" also ends in "s".
  hold_secs := MARKMOBS_HOLD_DEFAULT
  refresh_ms := MARKMOBS_REFRESH_MS
  name_parts := make([dynamic]string, context.temp_allocator)
  for a in args {
    if strings.has_suffix(a, "ms") && len(a) > 2 {
      if v, ok := strconv.parse_int(a[:len(a) - 2]); ok && v > 0 {
        refresh_ms = v
        continue
      }
    } else if strings.has_suffix(a, "s") && len(a) > 1 {
      if s, ok := strconv.parse_int(a[:len(a) - 1]); ok && s > 0 {
        hold_secs = s
        continue
      }
    }
    append(&name_parts, a)
  }
  name := strings.trim(strings.join(name_parts[:], " ", context.temp_allocator), "'\"")
  if refresh_ms < MARKMOBS_REFRESH_MIN {
    refresh_ms = MARKMOBS_REFRESH_MIN
  }

  // Claim a game-unused particle type (warm it once) so we drive it with no client contention.
  if !overlay_warm_type(session, MARKMOBS_OVERLAY_TYPE) {
    fmt.eprintfln("markmobs: couldn't warm overlay particle type %d.", MARKMOBS_OVERLAY_TYPE)
    return
  }

  label := name == "" ? "movers" : name
  cur_objs := make([dynamic]uintptr, context.temp_allocator)
  count := MARKMOBS_MAX_COUNT
  // Wall-clock driven so `Ns` is real seconds regardless of per-iteration cost (reads/writes/re-scan
  // take much longer than the refresh interval when there are many mobs).
  refresh := time.Duration(refresh_ms) * time.Millisecond
  reenum_interval := time.Duration(MARKMOBS_REENUM_MS) * time.Millisecond
  run_deadline := time.Duration(hold_secs) * time.Second
  start := time.tick_now()
  last_enum: time.Tick
  first := true

  for time.tick_since(start) < run_deadline {
    // Full re-scan on the first tick and every reenum_interval; cheap position re-read otherwise.
    hits: [dynamic]Mover_Hit
    if first || time.tick_since(last_enum) >= reenum_interval {
      hits = enum_movers(session, name)
      last_enum = time.tick_now()
      clear(&cur_objs)
      n_drawn := 0
      for h in hits {
        append(&cur_objs, h.obj)
        if h.model_ok {
          n_drawn += 1
        }
      }
      // Dots-per-mob so all drawn markers together stay under the 512-slot pool (refresh-independent).
      count = clamp(MARKMOBS_POOL_BUDGET / max(1, n_drawn), MARKMOBS_MIN_COUNT, MARKMOBS_MAX_COUNT)
    } else {
      hits = reread_movers(session, cur_objs[:])
    }

    if first {
      first = false
      if len(hits) == 0 {
        fmt.eprintfln("markmobs: no %s enumerated.", label)
        overlay_clear_type(session, MARKMOBS_OVERLAY_TYPE)
        return
      }
      n_sel := 0
      for h in hits {
        if h.model_ok {
          n_sel += 1
        }
      }
      hidden := ""
      if len(hits) - n_sel > 0 {
        hidden = fmt.tprintf(" (%d beyond render range, hidden)", len(hits) - n_sel)
      }
      fmt.printfln(
        "markmobs: tracking %d %s, %d dots each, %dms refresh, ~%ds%s...",
        n_sel,
        label,
        count,
        refresh_ms,
        hold_secs,
        hidden,
      )
    }

    // Drive the one uncontended pool to the current mob positions (markers follow exactly).
    positions, colors := build_mob_overlay(hits[:], count)
    if !overlay_drive_type(session, MARKMOBS_OVERLAY_TYPE, positions, colors, MARKMOBS_SIZE) {
      fmt.eprintln("markmobs: pool write failed.")
      break
    }
    time.sleep(refresh)
  }
  // Clear our markers so they don't linger after the overlay stops.
  overlay_clear_type(session, MARKMOBS_OVERLAY_TYPE)
  fmt.println("markmobs: done.")
}

// findparticle - re-derive particlemng_rva + createparticle_rva after a game patch (they shift).
// Anchors on a particle texture string (survives patches) -> the code that loads it is inside
// CParticleMng::CreateParticle -> scan back over int3 padding to its entry (createparticle_rva). Then
// scan the function for the m_Particles[] array access `[reg*4 + disp32]` (module-relative disp) - the
// smallest such disp is the array base = g_ParticleMng + 8. Saves to flyff.cfg. Read-only recon.
cli_findparticle :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  size := uintptr(session.proc_info.module_size)

  anchors := []string{"Sfx_ItemPatical01.dds", "etc_ParticleCloud01.bmp", "etc_Particle11.bmp"}
  ref: uintptr = 0
  used := ""
  for a in anchors {
    pat := make([]byte, len(a), context.temp_allocator)
    copy(pat, a)
    straddrs := engine.scan_bytes(handle, pat, context.temp_allocator)
    if len(straddrs) == 0 {
      continue
    }
    refs := engine.codescan_u32(handle, u32(straddrs[0]), context.temp_allocator)
    if len(refs) > 0 {
      ref = refs[0]
      used = a
      break
    }
  }
  if ref == 0 {
    fmt.eprintln("findparticle: no code reference to a particle texture string found (patch changed strings?).")
    return
  }

  // Function entry = nearest addr <= ref preceded by >=2 int3 (MSVC inter-function padding).
  PRE :: 0x800
  pre := make([]byte, PRE + 16, context.temp_allocator)
  engine.read_into(handle, ref - PRE, pre)
  entry := ref
  for j := PRE; j >= 2; j -= 1 {
    if pre[j - 1] == 0xCC && pre[j - 2] == 0xCC {
      entry = ref - PRE + uintptr(j)
      break
    }
  }

  // Scan the function for `[idx*4 + disp32]` (SIB byte 0x85, ModRM mod=00 rm=100) with a
  // module-relative disp32. The smallest is m_Particles[0] = g_ParticleMng + 8.
  SPAN :: 0x500
  code := make([]byte, SPAN, context.temp_allocator)
  n, _ := engine.read_into(handle, entry, code)
  best: u32 = 0
  for i := 1; i < int(n) - 5; i += 1 {
    if code[i] == 0x85 && (code[i - 1] & 0xC7) == 0x04 {
      d := u32(code[i + 1]) | u32(code[i + 2]) << 8 | u32(code[i + 3]) << 16 | u32(code[i + 4]) << 24
      if uintptr(d) >= base && uintptr(d) < base + size && (best == 0 || d < best) {
        best = d
      }
    }
  }
  if best == 0 {
    fmt.eprintfln("findparticle: found CreateParticle at Neuz.exe+0x%X but couldn't extract g_ParticleMng.", entry - base)
    fmt.eprintln("  set createparticle_rva manually and inspect with `func` for the m_Particles base.")
    return
  }
  g_pm := uintptr(best) - 8

  session.layout.createparticle_rva = entry - base
  session.layout.particlemng_rva = g_pm - base
  fmt.printfln(
    "findparticle: createparticle_rva=0x%X  particlemng_rva=0x%X  (anchor %q)",
    session.layout.createparticle_rva,
    session.layout.particlemng_rva,
    used,
  )
  // Sanity check: type 16's m_bActive should be a 0/1 flag.
  if v, ok := engine.read_value(handle, g_pm + uintptr(8 + 16 * PARTICLE_CPARTICLES_SIZE + 0x2C), .U32); ok {
    av := engine.value_as_u64(.U32, v)
    fmt.printfln("  sanity: type16 m_bActive=%d (want 0 or 1)%s", av, av > 1 ? "  <-- SUSPICIOUS, verify!" : "")
  }
  if flyff_save_cfg(session.layout, flyff_cfg_path()) {
    fmt.println("  saved to flyff.cfg.")
  }
}

// warmtype <n> - inject ONE CreateParticle to initialise a cold particle type (allocates its pool,
// loads its texture, builds its VB). Used to claim a GAME-UNUSED type for the follow-overlay so the
// client never spawns into it (no pool contention = the fix for the blink). The init runs on our
// injected thread (off-thread D3D device calls) - the one risky bit; spawns at y=-100000 so nothing
// shows. Reports the resulting pool/texture/VB so we can confirm it initialised cleanly.
cli_warmtype :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: warmtype <0-31>")
    return
  }
  n, ok := strconv.parse_int(args[0])
  if !ok || n < 0 || n >= PARTICLE_MAX_TYPE {
    fmt.eprintln("warmtype: type must be 0..31.")
    return
  }
  if particle_type_active(session, n) {
    fmt.printfln("warmtype: type %d already warm.", n)
    return
  }
  fmt.printfln("warmtype: injecting CreateParticle to init cold type %d (off-thread device init)...", n)
  if !overlay_warm_type(session, n) {
    fmt.eprintln("warmtype: injection failed / type did not initialise.")
    return
  }
  handle := session.proc_info.handle
  cp := particle_cparticles_addr(session, n)
  rd :: proc(h: win.HANDLE, a: uintptr) -> u64 {
    v, _ := engine.read_value(h, a, .U32)
    return engine.value_as_u64(.U32, v)
  }
  fmt.printfln(
    "warmtype: type %d -> active=%v pool=0x%X vb=0x%X tex=0x%X",
    n,
    particle_type_active(session, n),
    rd(handle, cp + PC_POOL),
    rd(handle, cp + PC_PVB),
    rd(handle, cp + PC_PTEXTURE),
  )
}

mark_print_warm_types :: proc(session: ^Session) {
  warm := make([dynamic]int, context.temp_allocator)
  for t in 0 ..< PARTICLE_MAX_TYPE {
    if particle_type_active(session, t) {
      append(&warm, t)
    }
  }
  if len(warm) == 0 {
    fmt.eprintln("      (none warm right now - trigger an in-game effect first.)")
  } else {
    fmt.eprintfln("      warm types now: %v  (13-15 blue, 16-18 red, 19-21 white, 22-24 green)", warm[:])
  }
}
