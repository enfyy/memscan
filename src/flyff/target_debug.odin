package flyff

import "core:fmt"
import "core:math"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import "../engine"

// ============================================================================
// Target-selection debug: predict the full auto kill-order from the current snapshot and render it as
// an external top-down map (HTML + inline SVG) plus a console factor table. We can't usefully label
// mobs on the live screen (they don't fit, and in-world numbers would need risky particle injection),
// but memscan already knows every mob's world position - so we draw our OWN map. See `tdbg` (cli.odin).
//
// The prediction reuses the live picker's exact cascade (tc_pick_one in target.odin), so what the map
// shows is what auto would actually do - no drift. It's non-destructive: the session is never mutated.
// ============================================================================

// Per-candidate factor record for the map/table. rank = predicted kill order (0-based; -1 while the mob
// is excluded - on cooldown, blocked, or unreachable). Distances are split (horizontal vs 3D vs Δy) so
// the vertical-map bug (the picker mixes the two metrics) is visible at a glance.
TC_Factors :: struct {
  obj:          uintptr,
  name:         string,
  pos:          [3]f32,
  d_player_h:   f32,
  d_player_3d:  f32,
  dy:           f32, // pos.y - player.y
  d_lastkill_h: f32, // -1 when there's no last-kill anchor
  cluster:      int, // local pack size (# candidates within density_radius, incl. self)
  in_melee:     bool,
  in_engage:    bool,
  on_cooldown:  bool,
  blocked:      bool,
  reachable:    bool,
  reach_status: Reach_Status, // why it's (un)reachable: Clear / Blocked_Terrain / Blocked_Object
  stage:        TC_Stage,
  rank:         int,
}

// One prediction run: per-candidate factors (index-aligned), the predicted pick order (candidate
// indices), and the geometry/ranges needed to draw the map.
TC_Debug :: struct {
  facts:         []TC_Factors,
  order:         []int, // candidate indices, rank 0 first
  player_pos:    [3]f32,
  player_angle:  f32, // CObj.m_fAngle (yaw, degrees) - facing direction
  has_angle:     bool,
  cam_eye:       [3]f32, // render camera eye (for the cull-cone overlay)
  cam_lookat:    [3]f32,
  has_camera:    bool,
  world:         uintptr, // for the obstacle overlay (walls / OBBs)
  mpu:           f32, // terrain meters-per-unit (wall-cell size)
  last_kill_set: bool,
  last_kill_pos: [3]f32,
  anchor_src:    string, // where the anchor came from (live / selected mob / nearest mob)
  melee:         f32,
  engage:        f32,
  attack_range:  f32,
  density_on:    bool,
  min_gain:      int,
  max_detour:    f32,
  cluster_committed: bool, // the LIVE session commitment at snapshot time (seeds the simulation)
  reversals:     int, // simulated-walk direction reversals among ranked picks (anti-turn-around metric)
}

// Aggregate stats that differ between a "good" map (tower) and a "bad" one (cloakia) - the whole point
// of being able to diff two runs. Vertical spread + the 3D-vs-horizontal split is the tell.
TC_Summary :: struct {
  n, ranked, excluded:                    int,
  n_cooldown, n_blocked, n_unreach:       int,
  spacing_min, spacing_mean, spacing_max:  f32, // nearest-neighbour horizontal spacing among candidates
  dy_max, dy_mean:                         f32, // |Δy| spread (verticality)
  stage_counts:                            [TC_Stage]int,
}

// Simulate the full auto kill-order from the CURRENT snapshot, without mutating the session. Answers
// "starting from here, in what order does the picker yield these mobs". The simulated STAND-POINT walks
// with each kill: candidate distances are re-measured and re-sorted from the rolling kill spot before
// every simulated pick, exactly like the live loop re-scans from wherever the player actually stands
// (a player-fixed view would mispredict every later pick as "nearest to where you started" - the same
// backward bias the pre-select anchor fix removed). Uses the live picker's own cascade (tc_pick_one).
tc_predict_order :: proc(session: ^Session, names: []string) -> (dbg: TC_Debug, ok: bool) {
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := session.ptr_size == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64

  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  pv, pok := engine.read_value(handle, base + session.layout.player_rva, pt)
  if !wok || !pok {
    return {}, false
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  player := uintptr(engine.value_as_u64(pt, pv))
  player_pos, ppok := engine.read_vec3(handle, player + uintptr(session.layout.pos_off))
  if !ppok {
    return {}, false
  }
  player_angle: f32
  has_angle := false
  if session.layout.angle_off != 0 {
    if av, aok := read_f32_at(handle, player + uintptr(session.layout.angle_off)); aok {
      player_angle = av
      has_angle = true
    }
  }
  cam_eye, cam_lookat, has_camera := read_camera(session)

  cands := tc_collect_cands(session, names, world, player, player_pos) // temp-allocated, sorted nearest-first
  n := len(cands)

  now := time.now()._nsec
  melee, engage := pick_ranges(session)
  // Always compute pack sizes for the map/table (so you can see clusters even with density off while
  // tuning); the cluster/density STAGES only fire when density_on (see the Pick_Ctx below).
  don := session.layout.density_on
  dens := compute_densities(cands[:], density_radius(engage))
  lk_set := session.last_kill_set
  lk_pos := session.last_kill_pos
  anchor_src := "live last-kill anchor (auto running)"
  if !lk_set {
    // Not mid-run, so there's no live anchor - which would make the pocket/walk logic never engage and
    // every mob show as "nearest" (a raw distance sort, not the real farming order). Seed the anchor so
    // the prediction shows the realistic nearest-neighbour pack-walk: prefer the mob you currently have
    // selected (you'd start there), else the nearest candidate (as if you just killed it).
    if focus, fok := read_focus_ptr(session); fok && focus != 0 && focus_obj_live(session, focus) {
      if fpos, fpok := engine.read_vec3(handle, focus + uintptr(session.layout.pos_off)); fpok {
        lk_pos = fpos
        lk_set = true
        anchor_src = "your selected mob (seeded)"
      }
    }
    if !lk_set && n > 0 {
      lk_pos = cands[0].pos // sorted nearest-first
      lk_set = true
      anchor_src = "nearest mob (seeded, auto off)"
    }
  }

  // Per-candidate factor properties, evaluated against the current snapshot (player pos + live
  // cooldown/blocked + initial last-kill anchor). rank/stage are filled by the simulation below.
  facts := make([]TC_Factors, n, context.temp_allocator)
  for c, i in cands {
    nm, _ := read_mover_name(session, c.obj)
    rs := cand_reach_status(session, world, player_pos, c.pos)
    facts[i] = TC_Factors {
      obj          = c.obj,
      name         = nm,
      pos          = c.pos,
      d_player_h   = c.d, // c.d is the horizontal distance (tc_collect_cands)
      d_player_3d  = engine.dist_3d(c.pos, player_pos),
      dy           = c.pos[1] - player_pos[1],
      d_lastkill_h = lk_set ? engine.dist_horizontal(c.pos, lk_pos) : -1,
      cluster      = dens[i],
      in_melee     = c.d <= melee,
      in_engage    = c.d <= engage,
      on_cooldown  = recent_list_contains(session.tc_recent[:], c.obj, now, TC_RECENT_NS),
      blocked      = recent_list_contains(session.auto_blocked[:], c.obj, now, BLOCKED_NS),
      reachable    = rs == .Clear,
      reach_status = rs,
      stage        = .Excluded,
      rank         = -1,
    }
  }

  // Simulate the kill sequence over local mutable copies so the session is untouched.
  alive := make([]bool, n, context.temp_allocator)
  for i in 0 ..< n {
    alive[i] = true
  }
  local_recent := make([dynamic]TC_Recent, context.temp_allocator)
  append(&local_recent, ..session.tc_recent[:])
  ctx := Pick_Ctx {
    player_pos    = player_pos,
    world         = world,
    now           = now,
    name_filtered = len(names) > 0,
    require_fresh = true,
    gate          = session.reach_gate_on,
    fence_on      = session.fence.active,
    avoid_on      = session.auto_avoid_on,
    avoid_dir     = session.auto_avoid_dir,
    last_kill_set = lk_set,
    last_kill_pos = lk_pos,
    melee         = melee,
    engage        = engage,
    recent        = local_recent[:],
    blocked       = session.auto_blocked[:],
    density       = dens,
    density_on    = don,
    min_gain      = session.layout.density_min_gain,
    max_detour    = session.layout.density_max_detour,
    cluster_committed  = session.cluster_committed, // seed the sim from the live commitment
    cluster_origin_pos = session.cluster_origin_pos,
  }
  order := make([dynamic]int, context.temp_allocator)
  reversals := 0
  prev_step: [2]f32
  have_step := false
  // Rolling stand-point view: before each simulated pick, re-measure and re-sort every candidate from
  // the spot we'd be standing at (the previous sim-kill's position; the seeded anchor for the first).
  // The cascade requires cands sorted nearest-first with d relative to the stand-point, and alive/
  // density are index-aligned to it, so the view carries a back-mapping (View_Ref.i) to snapshot order.
  View_Ref :: struct {
    i: int, // index into cands/facts (snapshot order)
    d: f32, // horizontal distance from the current stand-point
  }
  cur_pos := player_pos // the player's simulated stand-point: starts where you ACTUALLY are, and only
  // moves when a pick was out of range (a walk) - an in-range pick keeps you put (a stationary ranged char)
  refs := make([]View_Ref, n, context.temp_allocator)
  view := make([]TC_Cand, n, context.temp_allocator)
  view_alive := make([]bool, n, context.temp_allocator)
  view_dens := make([]int, n, context.temp_allocator)
  for k in 0 ..< n {
    for c, i in cands {
      refs[i] = View_Ref{i = i, d = engine.dist_horizontal(c.pos, cur_pos)}
    }
    slice.sort_by(refs, proc(a, b: View_Ref) -> bool {return a.d < b.d})
    for r, j in refs {
      view[j] = TC_Cand{obj = cands[r.i].obj, d = r.d, pos = cands[r.i].pos}
      view_alive[j] = alive[r.i]
      view_dens[j] = dens[r.i]
    }
    ctx.player_pos = cur_pos // ranges + reach start from the stand-point, like the live re-scan would
    ctx.live_player = cur_pos // in-range gate measures from where we stand this step
    ctx.density = view_dens
    vidx, stage := tc_pick_one(session, view, ctx, view_alive)
    if vidx < 0 {
      break // everything left is excluded (cooldown / blocked / unreachable)
    }
    idx := refs[vidx].i
    facts[idx].rank = k
    facts[idx].stage = stage
    append(&order, idx)
    alive[idx] = false
    append(&local_recent, TC_Recent{obj = cands[idx].obj, t = now}) // consume: on cooldown for later picks
    ctx.recent = local_recent[:]
    // Direction-reversal metric: the horizontal step from the previous stand-point to this pick, against
    // the previous step - dot < 0 means the walk turned around. The objective input for deciding
    // whether an explicit anti-turn-around bias is still needed (deferred; see ONEPOINTO phase 6).
    step := [2]f32{cands[idx].pos[0] - cur_pos[0], cands[idx].pos[2] - cur_pos[2]}
    if step[0] != 0 || step[1] != 0 {
      if have_step && step[0] * prev_step[0] + step[1] * prev_step[1] < 0 {
        reversals += 1
      }
      prev_step = step
      have_step = true
    }
    // Walk the commitment state forward exactly like the live pick paths (tc_select / auto_tick) do.
    if don {
      ctx.cluster_committed, ctx.cluster_origin_pos = cluster_advance(
        ctx.cluster_committed, ctx.cluster_origin_pos, stage, cands[idx].pos, dens[idx], density_radius(engage),
      )
    }
    ctx.last_kill_set = true
    ctx.last_kill_pos = cands[idx].pos
    // Move the stand-point ONLY when we had to leave our range to take this pick (Melee/Pocket are
    // in-range, so a ranged char stays put; Nearest/Cluster/Density/Avoid are walks toward the mob).
    if stage != .Melee && stage != .Pocket {
      cur_pos = cands[idx].pos
    }
    ctx.avoid_on = false // one-shot, consumed by the first pick
  }

  dbg = TC_Debug {
    facts         = facts,
    order         = order[:],
    player_pos    = player_pos,
    player_angle  = player_angle,
    has_angle     = has_angle,
    cam_eye       = cam_eye,
    cam_lookat    = cam_lookat,
    has_camera    = has_camera,
    world         = world,
    mpu           = f32(world_mpu(session, world)),
    last_kill_set = lk_set,
    last_kill_pos = lk_pos,
    anchor_src    = anchor_src,
    melee         = melee,
    engage        = engage,
    attack_range  = session.layout.attack_range,
    density_on    = don,
    min_gain      = session.layout.density_min_gain,
    max_detour    = session.layout.density_max_detour,
    cluster_committed = session.cluster_committed,
    reversals     = reversals,
  }
  return dbg, true
}

tc_summarize :: proc(dbg: TC_Debug) -> TC_Summary {
  s: TC_Summary
  s.n = len(dbg.facts)
  dy_sum: f32 = 0
  for f in dbg.facts {
    if f.rank >= 0 {
      s.ranked += 1
      s.stage_counts[f.stage] += 1
    } else {
      s.excluded += 1
      if f.blocked {
        s.n_blocked += 1
      }
      if f.on_cooldown {
        s.n_cooldown += 1
      }
      if !f.reachable {
        s.n_unreach += 1
      }
    }
    ady := f.dy < 0 ? -f.dy : f.dy
    if ady > s.dy_max {
      s.dy_max = ady
    }
    dy_sum += ady
  }
  if s.n > 0 {
    s.dy_mean = dy_sum / f32(s.n)
  }

  // Nearest-neighbour horizontal spacing per candidate, then min/mean/max - characterises clumping.
  s.spacing_min = 1e30
  sp_sum: f32 = 0
  sp_cnt := 0
  for a, i in dbg.facts {
    nn: f32 = 1e30
    for b, j in dbg.facts {
      if i == j {
        continue
      }
      d := engine.dist_horizontal(a.pos, b.pos)
      if d < nn {
        nn = d
      }
    }
    if nn < 1e29 {
      if nn < s.spacing_min {
        s.spacing_min = nn
      }
      if nn > s.spacing_max {
        s.spacing_max = nn
      }
      sp_sum += nn
      sp_cnt += 1
    }
  }
  if sp_cnt > 0 {
    s.spacing_mean = sp_sum / f32(sp_cnt)
  } else {
    s.spacing_min = 0
  }
  return s
}

// --- rendering ------------------------------------------------------------------------------------

stage_name :: proc(s: TC_Stage) -> string {
  switch s {
  case .Melee:
    return "melee"
  case .Avoid:
    return "avoid"
  case .Cluster:
    return "cluster"
  case .Pocket:
    return "pocket"
  case .Nearest:
    return "nearest"
  case .Density:
    return "density"
  case .None:
    return "-"
  case .Excluded:
    return "excluded"
  }
  return "-"
}

// Marker fill: ranked mobs are coloured by the stage that picked them; excluded mobs by WHY (blocked
// red, unreachable purple, cooldown amber, else grey).
fact_color :: proc(f: TC_Factors) -> string {
  if f.rank >= 0 {
    switch f.stage {
    case .Melee:
      return "#1abc9c"
    case .Avoid:
      return "#e67e22"
    case .Cluster:
      return "#e84393"
    case .Pocket:
      return "#3498db"
    case .Nearest:
      return "#2ecc71"
    case .Density:
      return "#f1c40f"
    case .None, .Excluded:
      return "#8899aa"
    }
    return "#8899aa"
  }
  if f.blocked {
    return "#e74c3c"
  }
  if !f.reachable {
    return f.reach_status == .Blocked_Terrain ? "#e67e22" : "#9b59b6" // wall=orange, object=purple
  }
  if f.on_cooldown {
    return "#b8912f"
  }
  return "#5a6572"
}

html_escape :: proc(b: ^strings.Builder, s: string) {
  for r in s {
    switch r {
    case '&':
      strings.write_string(b, "&amp;")
    case '<':
      strings.write_string(b, "&lt;")
    case '>':
      strings.write_string(b, "&gt;")
    case '"':
      strings.write_string(b, "&quot;")
    case:
      strings.write_rune(b, r)
    }
  }
}

// Replace anything that isn't [A-Za-z0-9_-] with '_' so a label is safe in a filename.
sanitize_label :: proc(s: string) -> string {
  b := strings.builder_make(context.temp_allocator)
  for r in s {
    if (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') || (r >= '0' && r <= '9') || r == '-' || r == '_' {
      strings.write_rune(&b, r)
    } else {
      strings.write_rune(&b, '_')
    }
  }
  return strings.to_string(b)
}

yn :: proc(v: bool) -> string {
  return v ? "y" : "."
}

// Reach reason for the table/console: clear, or blocked by a terrain wall vs a placed-object box.
reach_word :: proc(rs: Reach_Status) -> string {
  switch rs {
  case .Clear:
    return "clear"
  case .Blocked_Terrain:
    return "wall"
  case .Blocked_Object:
    return "obj"
  }
  return "?"
}

// Round x up to a "nice" 1/2/5 x 10^k value, for the concentric distance-ring interval.
nice_step :: proc(x: f32) -> f32 {
  if x <= 0 {
    return 1
  }
  p := f32(1)
  for x / p >= 10 {
    p *= 10
  }
  for x / p < 1 {
    p /= 10
  }
  m := x / p
  if m <= 2 {
    return 2 * p
  }
  if m <= 5 {
    return 5 * p
  }
  return 10 * p
}

// World->screen projection for the radar scope. Horizontal (x,z) plane; player at centre. Mobs beyond
// the view radius are clamped onto the rim (clamped=true) so you still see their direction. `d` is the
// point's horizontal distance to the player (already computed per candidate).
proj_pt :: proc(player: [3]f32, scale, view_r, cx, cy, wx, wz, d: f32) -> (px, py: f32, clamped: bool) {
  dx := wx - player[0]
  dz := wz - player[2]
  if d > view_r && d > 0.001 {
    k := view_r / d
    dx *= k
    dz *= k
    clamped = true
  }
  return cx + dx * scale, cy + dz * scale, clamped
}

// Declutter budget: only the first TDBG_NUM picks get a big numbered dot; picks up to TDBG_WALK get a
// gradient dot on the walk line; everything past that is faint dust. A 500-mob field is otherwise an
// unreadable solid blob - you care about what's NEXT, not the 300th pick.
TDBG_NUM :: 12
TDBG_WALK :: 40

// Rank-gradient colour: t=0 (next pick) warm/bright, t=1 (later) cool/dim. Makes the pick ORDER legible
// even when every mob is the same stage (e.g. all "nearest") and would otherwise be one flat colour.
rank_color :: proc(t: f32) -> string {
  tt := clamp(t, 0, 1)
  a := [3]f32{255, 236, 130} // soonest
  c := [3]f32{70, 120, 165} // latest
  r := int(a[0] + (c[0] - a[0]) * tt)
  g := int(a[1] + (c[1] - a[1]) * tt)
  bl := int(a[2] + (c[2] - a[2]) * tt)
  return fmt.tprintf("#%02x%02x%02x", r, g, bl)
}

// Build the whole HTML document (top-down radar map + summary + factor table). zoom>0 forces the view
// radius (world units); zoom<=0 auto-fits robustly (p85 of mob distances, floored at 2x engage).
tc_render_html :: proc(session: ^Session, dbg: TC_Debug, s: TC_Summary, names: []string, label: string, zoom: f32) -> string {
  W :: 760 // svg viewport
  cx :: f32(W / 2)
  cy :: f32(W / 2)
  margin :: f32(46)

  // Robust view radius: a few far outliers shouldn't shrink the near field. p85 of mob distances,
  // floored at 2x the engage range (so the range ring is always readable). Or an explicit zoom.
  view_r := zoom
  if view_r <= 0 {
    ds := make([]f32, len(dbg.facts), context.temp_allocator)
    for f, i in dbg.facts {
      ds[i] = f.d_player_h
    }
    slice.sort(ds)
    p85 := len(ds) > 0 ? ds[min(len(ds) - 1, int(0.85 * f32(len(ds))))] : dbg.engage
    view_r = max(2 * dbg.engage, p85)
    if view_r < 10 {
      view_r = 10
    }
  }
  scale := (cx - margin) / view_r

  b := strings.builder_make(context.temp_allocator)
  desc := auto_target_desc(names)
  fmt.sbprintf(&b, "<title>tc map%s%s</title>\n", label == "" ? "" : " - ", label)
  fmt.sbprint(&b, `<style>
  body{background:#12161c;color:#c9d3df;font:13px/1.5 system-ui,Segoe UI,Arial;margin:16px}
  h1{font-size:16px;margin:0 0 6px} .sub{color:#7f8c98;margin:0 0 4px} .warn{color:#e0a53a;margin:0 0 12px}
  .wrap{display:flex;gap:20px;flex-wrap:wrap;align-items:flex-start}
  .map{position:relative;width:760px;height:760px;background:#0c0f14;border:1px solid #222b36;border-radius:6px;overflow:hidden;flex:none}
  .toggles{display:flex;gap:16px;flex-wrap:wrap;color:#9aa7b4;font-size:12px;margin:0 0 8px}
  .toggles label{cursor:pointer;user-select:none} .toggles input{vertical-align:-1px;margin-right:4px}
  .wall{position:absolute;background:rgba(231,126,52,.28);pointer-events:none}
  .obb{position:absolute;border:1px solid rgba(155,89,182,.65);background:rgba(155,89,182,.1);box-sizing:border-box;pointer-events:none}
  .obb.dec{border:1px dashed rgba(120,130,145,.35);background:transparent}
  .rline{position:absolute;height:2px;pointer-events:none;opacity:.5}
  body:has(#t-wall:not(:checked)) .wall{display:none}
  body:has(#t-obb:not(:checked)) .obb{display:none}
  body:has(#t-line:not(:checked)) .rline{display:none}
  body:has(#t-dot:not(:checked)) .dot{display:none}
  .ring{position:absolute;border-radius:50%;border:1px solid #1a2532;box-sizing:border-box;pointer-events:none}
  .rlbl{position:absolute;width:32px;text-align:center;color:#41505f;font-size:9px}
  .axis{position:absolute;background:#161f2a}
  .dot{position:absolute;transform:translate(-50%,-50%);border-radius:50%}
  .dot.num{text-align:center;color:#04121a;font-weight:700;font-size:10px}
  .anchor{position:absolute;transform:translate(-50%,-50%);color:#e0a53a;font-size:15px;font-weight:700;line-height:1}
  .you{position:absolute;left:380px;top:380px;transform:translate(-50%,-50%);width:10px;height:10px;border-radius:50%;background:#eee;box-shadow:0 0 0 3px rgba(238,238,238,.2)}
  .heading{position:absolute;left:380px;top:380px;width:0;height:0;border-left:7px solid transparent;border-right:7px solid transparent;border-top:17px solid #eee;transform-origin:50% 0}
  .frustum{position:absolute;left:0;top:0;width:760px;height:760px;background:rgba(53,194,214,.07);pointer-events:none}
  .cam{position:absolute;transform:translate(-50%,-50%);width:9px;height:9px;background:#35c2d6;border-radius:2px}
  .camlbl{position:absolute;transform:translate(-50%,-50%);color:#35c2d6;font-size:9px;white-space:nowrap}
  body:has(#t-cam:not(:checked)) .frustum,body:has(#t-cam:not(:checked)) .cam,body:has(#t-cam:not(:checked)) .camlbl{display:none}
  .youlbl{position:absolute;left:380px;top:362px;transform:translateX(-50%);color:#eee;font-size:10px}
  table{border-collapse:collapse;font-variant-numeric:tabular-nums;font-size:12px}
  th,td{padding:2px 8px;text-align:right;border-bottom:1px solid #1e2731;white-space:nowrap}
  th{color:#8fa0b2;text-align:right;position:sticky;top:0;background:#12161c}
  td.l,th.l{text-align:left} tr.ex{color:#6b7784}
  .card{background:#0c0f14;border:1px solid #222b36;border-radius:6px;padding:10px 14px;min-width:220px}
  .card h2{font-size:13px;margin:0 0 6px;color:#8fa0b2} .k{color:#7f8c98} .v{color:#e6edf5}
  .lg span{display:inline-block;width:10px;height:10px;border-radius:2px;margin:0 5px 0 12px;vertical-align:middle}
</style>` + "\n")

  fmt.sbprintf(&b, "<h1>target order - %s%s</h1>\n", desc, label == "" ? "" : fmt.tprintf("  [%s]", label))
  fmt.sbprintf(
    &b,
    "<p class=sub>%d candidates, %d ranked, %d excluded &nbsp;|&nbsp; attack_range=%.0f (engage), melee=%.0f, density=%s &nbsp;|&nbsp; anchor: %s &nbsp;|&nbsp; view radius %.0f</p>\n",
    s.n,
    s.ranked,
    s.excluded,
    dbg.attack_range,
    dbg.melee,
    dbg.density_on ? fmt.tprintf("on (mingain=%d detour=%.0f)", dbg.min_gain, dbg.max_detour) : "off",
    dbg.anchor_src,
    view_r,
  )
  warned := false
  // A tower / multi-level area collapses onto one spot in a top-down x,z map - warn and point at the Δy column.
  if s.dy_max > dbg.engage && s.dy_max > 6 {
    fmt.sbprintf(
      &b,
      "<p class=warn>! high vertical spread (|Δy| up to %.0f): this looks like a multi-level / tower area. A top-down map collapses floors onto each other, so lean on the &Delta;y column in the table below.</p>\n",
      s.dy_max,
    )
    warned = true
  }
  // Engage-range diagnostic: if the very nearest mob is already past attack_range, the pocket/pack logic
  // can never fire, so auto just picks strict nearest-to-player (this is likely what feels "off").
  nearest_ranked := len(dbg.order) > 0 ? dbg.facts[dbg.order[0]].d_player_h : -1
  if dbg.engage > 0 && nearest_ranked > dbg.engage {
    fmt.sbprintf(
      &b,
      "<p class=warn>! nearest mob is %.0f but attack_range/engage is %.0f - nothing is ever in range at pick time, so the pack/pocket logic is INACTIVE and auto picks strict nearest-to-player. If you actually hit mobs from ~%.0f, raise it: <b>set attack_range %.0f</b>.</p>\n",
      nearest_ranked,
      dbg.engage,
      nearest_ranked,
      nearest_ranked + 2,
    )
    warned = true
  }
  if !warned {
    fmt.sbprint(&b, "<p class=sub>&nbsp;</p>\n")
  }

  // Layer toggles (pure CSS via :has - no JS): uncheck to hide a layer.
  fmt.sbprint(&b, "<div class=toggles>")
  fmt.sbprint(&b, "<label><input type=checkbox id=t-dot checked>mob dots</label>")
  fmt.sbprint(&b, "<label><input type=checkbox id=t-obb checked>object boxes</label>")
  fmt.sbprint(&b, "<label><input type=checkbox id=t-wall checked>walls</label>")
  fmt.sbprint(&b, "<label><input type=checkbox id=t-line checked>reason lines</label>")
  fmt.sbprint(&b, "<label><input type=checkbox id=t-cam checked>camera cone</label>")
  fmt.sbprint(&b, "</div>\n")

  fmt.sbprint(&b, "<div class=wrap>\n")

  // ---- radar map: plain absolutely-positioned <div>s (renders in every browser; no SVG) ----
  fmt.sbprint(&b, "<div class=map>\n")

  // Camera cull cone (very bottom): m_aobjCull only holds what this cone draws, so the object-reach
  // check is BLIND outside it. Horizontal FOV is an estimate; the far plane (512) runs off the map.
  if dbg.has_camera {
    ex := cx + (dbg.cam_eye[0] - dbg.player_pos[0]) * scale
    ez := cy + (dbg.cam_eye[2] - dbg.player_pos[2]) * scale
    fdx := dbg.cam_lookat[0] - dbg.cam_eye[0]
    fdz := dbg.cam_lookat[2] - dbg.cam_eye[2]
    flen := math.sqrt(fdx * fdx + fdz * fdz)
    if flen > 0.001 {
      fdx /= flen
      fdz /= flen
      half := math.to_radians(FRUSTUM_HFOV_DEG * 0.5)
      ch := math.cos(half)
      sh := math.sin(half)
      L := f32(1200) // beyond the map; the div's clip-path clips it to the viewport
      fmt.sbprintf(
        &b,
        "<div class=frustum style='clip-path:polygon(%.0fpx %.0fpx, %.0fpx %.0fpx, %.0fpx %.0fpx)'></div>\n",
        ex,
        ez,
        ex + (fdx * ch - fdz * sh) * L,
        ez + (fdx * sh + fdz * ch) * L,
        ex + (fdx * ch + fdz * sh) * L,
        ez + (-fdx * sh + fdz * ch) * L,
      )
    }
  }

  // Obstacle overlay (bottom layer): the same walls (terrain cells) + boxes (object OBBs) the reach
  // check uses to exclude mobs, so you can SEE why a mob was unreachable.
  walls := collect_wall_cells(session, dbg.world, dbg.player_pos[0], dbg.player_pos[2], min(view_r, 90))
  wcell := max(dbg.mpu * scale, 2)
  for w in walls {
    sx := cx + (w.pos[0] - dbg.player_pos[0]) * scale
    sy := cy + (w.pos[1] - dbg.player_pos[2]) * scale
    if sx < -wcell || sx > f32(W) + wcell || sy < -wcell || sy > f32(W) + wcell {
      continue
    }
    fmt.sbprintf(&b, "<div class=wall style='left:%.1fpx;top:%.1fpx;width:%.1fpx;height:%.1fpx'></div>\n", sx - wcell / 2, sy - wcell / 2, wcell, wcell)
  }
  obbs := collect_nearby_obbs(session, dbg.player_pos[0], dbg.player_pos[2], view_r)
  for o in obbs {
    sx := cx + (o.center[0] - dbg.player_pos[0]) * scale
    sy := cy + (o.center[2] - dbg.player_pos[2]) * scale
    wpx := 2 * o.ext[0] * scale
    hpx := 2 * o.ext[2] * scale
    if sx < -wpx || sx > f32(W) + wpx || sy < -hpx || sy > f32(W) + hpx {
      continue
    }
    ang := math.atan2(o.axis[0][2], o.axis[0][0]) * 180 / math.PI
    cls := o.decorative ? "obb dec" : "obb"
    fmt.sbprintf(&b, "<div class='%s' style='left:%.1fpx;top:%.1fpx;width:%.1fpx;height:%.1fpx;transform:translate(-50%%,-50%%) rotate(%.1fdeg)'></div>\n", cls, sx, sy, wpx, hpx, ang)
  }

  // Concentric distance rings at a nice interval, each labelled with its world distance.
  step := nice_step(view_r / 4.5)
  for rr := step; rr <= view_r + 0.01; rr += step {
    pr := rr * scale
    fmt.sbprintf(&b, "<div class=ring style='left:%.1fpx;top:%.1fpx;width:%.1fpx;height:%.1fpx'></div>\n", cx - pr, cy - pr, 2 * pr, 2 * pr)
    fmt.sbprintf(&b, "<div class=rlbl style='left:%.1fpx;top:%.1fpx'>%.0f</div>\n", cx - 16, cy - pr + 1, rr)
  }
  // axes
  fmt.sbprintf(&b, "<div class=axis style='left:%.1fpx;top:0;width:1px;height:%dpx'></div>\n", cx, W)
  fmt.sbprintf(&b, "<div class=axis style='left:0;top:%.1fpx;width:%dpx;height:1px'></div>\n", cy, W)
  // engage / attack_range ring (cyan) + faint dashed melee ring
  if dbg.engage > 0 && dbg.engage <= view_r * 1.02 {
    er := dbg.engage * scale
    fmt.sbprintf(&b, "<div class=ring style='left:%.1fpx;top:%.1fpx;width:%.1fpx;height:%.1fpx;border-color:#35c2d6'></div>\n", cx - er, cy - er, 2 * er, 2 * er)
    fmt.sbprintf(&b, "<div class=rlbl style='left:%.1fpx;top:%.1fpx;color:#35c2d6'>range %.0f</div>\n", cx - 16, cy - er - 11, dbg.engage)
  }
  if dbg.melee > 0 && dbg.melee < dbg.engage && dbg.melee <= view_r {
    mr := dbg.melee * scale
    fmt.sbprintf(&b, "<div class=ring style='left:%.1fpx;top:%.1fpx;width:%.1fpx;height:%.1fpx;border-style:dashed;border-color:#5a6572'></div>\n", cx - mr, cy - mr, 2 * mr, 2 * mr)
  }

  walk_span := min(len(dbg.order), TDBG_WALK)
  gspan := f32(max(1, walk_span - 1)) // denominator for the rank gradient

  // Reason lines: from you to each mob excluded by REACH, coloured by cause (wall=orange, object=purple).
  // You can literally see the straight line clipping a box or a wall cell.
  for f in dbg.facts {
    if f.reach_status == .Clear {
      continue
    }
    px, py, _ := proj_pt(dbg.player_pos, scale, view_r, cx, cy, f.pos[0], f.pos[2], f.d_player_h)
    ddx := px - cx
    ddy := py - cy
    length := math.sqrt(ddx * ddx + ddy * ddy)
    if length < 1 {
      continue
    }
    ang := math.atan2(ddy, ddx) * 180 / math.PI
    col := f.reach_status == .Blocked_Terrain ? "#e67e22" : "#9b59b6"
    fmt.sbprintf(
      &b,
      "<div class=rline style='left:%.1fpx;top:%.1fpx;width:%.1fpx;transform:translate(-50%%,-50%%) rotate(%.1fdeg);background:%s'></div>\n",
      (cx + px) / 2,
      (cy + py) / 2,
      length,
      ang,
      col,
    )
  }

  // Mob dots, back to front: excluded dust -> tail dust -> walk dots (gradient) -> numbered (gradient).
  for pass in 0 ..< 4 {
    for f in dbg.facts {
      numbered := f.rank >= 0 && f.rank < TDBG_NUM
      walkdot := f.rank >= TDBG_NUM && f.rank < TDBG_WALK
      tail := f.rank >= TDBG_WALK
      excluded := f.rank < 0
      which := excluded ? 0 : (tail ? 1 : (walkdot ? 2 : 3))
      if which != pass {
        continue
      }
      px, py, clamped := proj_pt(dbg.player_pos, scale, view_r, cx, cy, f.pos[0], f.pos[2], f.d_player_h)
      if excluded {
        // Faint reason-coloured speck (blocked/unreachable/cooldown/other).
        fmt.sbprintf(&b, "<div class=dot style='left:%.1fpx;top:%.1fpx;width:4px;height:4px;background:%s;opacity:0.3'></div>\n", px, py, fact_color(f))
        continue
      }
      if tail {
        fmt.sbprintf(&b, "<div class=dot style='left:%.1fpx;top:%.1fpx;width:3px;height:3px;background:#3a4a5a;opacity:%s'></div>\n", px, py, clamped ? "0.14" : "0.28")
        continue
      }
      col := rank_color(f32(f.rank) / gspan)
      if walkdot {
        fmt.sbprintf(&b, "<div class=dot style='left:%.1fpx;top:%.1fpx;width:5px;height:5px;background:%s;opacity:%s'></div>\n", px, py, col, clamped ? "0.5" : "0.9")
        continue
      }
      ring := f.rank == 0 ? ";box-shadow:0 0 0 2px #fff" : ""
      fmt.sbprintf(
        &b,
        "<div class='dot num' style='left:%.1fpx;top:%.1fpx;width:15px;height:15px;line-height:15px;background:%s%s'>%d</div>\n",
        px,
        py,
        col,
        ring,
        f.rank + 1,
      )
    }
  }

  // Anchor marker (live or seeded) - where the pack-walk starts from.
  if dbg.last_kill_set {
    ax, ay, _ := proj_pt(dbg.player_pos, scale, view_r, cx, cy, dbg.last_kill_pos[0], dbg.last_kill_pos[2], engine.dist_horizontal(dbg.player_pos, dbg.last_kill_pos))
    fmt.sbprintf(&b, "<div class=anchor style='left:%.1fpx;top:%.1fpx'>&times;</div>\n", ax, ay)
  }

  // Player at centre.
  if dbg.has_camera {
    ex := cx + (dbg.cam_eye[0] - dbg.player_pos[0]) * scale
    ez := cy + (dbg.cam_eye[2] - dbg.player_pos[2]) * scale
    fmt.sbprintf(&b, "<div class=cam style='left:%.1fpx;top:%.1fpx'></div>\n", ex, ez)
    fmt.sbprintf(&b, "<div class=camlbl style='left:%.1fpx;top:%.1fpx'>cam</div>\n", ex, ez - 11)
  }
  if dbg.has_angle {
    // Facing arrow: a down-pointing triangle rotated by m_fAngle. Source builds RotationY(-m_fAngle) on a
    // local -Z forward, so on-screen it's m_fAngle + 180 (verified against the live camera/back-view).
    fmt.sbprintf(&b, "<div class=heading style='transform:translate(-50%%,0) rotate(%.1fdeg)'></div>\n", dbg.player_angle + 180)
  }
  fmt.sbprint(&b, "<div class=you></div>\n<div class=youlbl>you</div>\n")
  fmt.sbprint(&b, "</div>\n")

  // ---- side panel: legend + summary ----
  fmt.sbprint(&b, "<div>\n")
  fmt.sbprint(&b, "<div class=card lg><h2>legend</h2>\n")
  fmt.sbprint(&b, "<div><span style='background:#2ecc71'></span>nearest <span style='background:#e84393'></span>cluster <span style='background:#f1c40f'></span>density <span style='background:#3498db'></span>pocket <span style='background:#1abc9c'></span>melee <span style='background:#e67e22'></span>avoid</div>\n")
  fmt.sbprint(&b, "<div><span style='background:#e74c3c'></span>stuck-blacklist <span style='background:#e67e22'></span>walled <span style='background:#9b59b6'></span>blocked by object <span style='background:#b8912f'></span>cooldown</div>\n")
  fmt.sbprintf(&b, "<div style='margin-top:4px;color:#7f8c98'>dot colour = predicted kill order: <b style='color:#ffec82'>warm/bright = next</b> &rarr; cool/dim = later. Numbers mark the first %d picks; small dots are later picks. Faint grey rings = distance markers (world units); cyan ring = attack_range; gold &times; = anchor. <b style='color:#9b59b6'>Solid purple boxes</b> = real object collision (trees/rocks/buildings), <b style='color:#8a95a5'>faint dashed boxes</b> = decorative props (bushes/grass) the game walks through, <b style='color:#e67e22'>orange squares</b> = terrain walls; a line from you to an excluded mob shows what its straight path clips. Toggle any layer with the checkboxes above the map.</div>\n", TDBG_NUM)
  fmt.sbprint(&b, "</div>\n")

  fmt.sbprint(&b, "<div class=card style='margin-top:12px'><h2>map profile (diff this across maps)</h2>\n")
  row :: proc(b: ^strings.Builder, k: string, v: string) {
    fmt.sbprintf(b, "<div><span class=k>%s</span> &nbsp;<span class=v>%s</span></div>\n", k, v)
  }
  row(&b, "vertical spread |Δy|", fmt.tprintf("max %.1f, mean %.1f", s.dy_max, s.dy_mean))
  row(&b, "mob spacing (nn horiz)", fmt.tprintf("min %.1f, mean %.1f, max %.1f", s.spacing_min, s.spacing_mean, s.spacing_max))
  row(&b, "stages", fmt.tprintf("melee %d, avoid %d, cluster %d, pocket %d, nearest %d, density %d", s.stage_counts[.Melee], s.stage_counts[.Avoid], s.stage_counts[.Cluster], s.stage_counts[.Pocket], s.stage_counts[.Nearest], s.stage_counts[.Density]))
  row(&b, "walk reversals", fmt.tprintf("%d of %d picks turned around", dbg.reversals, len(dbg.order)))
  row(&b, "excluded", fmt.tprintf("%d  (cooldown %d, blocked %d, unreachable %d)", s.excluded, s.n_cooldown, s.n_blocked, s.n_unreach))
  fmt.sbprint(&b, "</div>\n")
  fmt.sbprint(&b, "</div>\n") // side panel
  fmt.sbprint(&b, "</div>\n") // wrap

  // ---- table ----
  fmt.sbprint(&b, "<h2 style='margin-top:16px;font-size:14px'>candidates (by predicted order)</h2>\n")
  fmt.sbprint(&b, "<table><thead><tr><th>#</th><th class=l>name</th><th>d_horiz</th><th>d_3d</th><th>Δy</th><th>d_lastkill</th><th>pack</th><th>melee</th><th>engage</th><th>reach</th><th>blkd</th><th>cd</th><th class=l>stage</th></tr></thead><tbody>\n")
  // rows sorted by rank (ranked ascending, excluded last)
  order := make([dynamic]int, context.temp_allocator)
  for _, i in dbg.facts {
    if dbg.facts[i].rank >= 0 {
      append(&order, i)
    }
  }
  // ranked already in dbg.order; append excluded after
  clear(&order)
  for idx in dbg.order {
    append(&order, idx)
  }
  for f, i in dbg.facts {
    if f.rank < 0 {
      append(&order, i)
    }
  }
  for idx in order {
    f := dbg.facts[idx]
    fmt.sbprintf(&b, "<tr%s>", f.rank < 0 ? " class=ex" : "")
    if f.rank >= 0 {
      fmt.sbprintf(&b, "<td>%d</td>", f.rank + 1)
    } else {
      fmt.sbprint(&b, "<td>-</td>")
    }
    fmt.sbprint(&b, "<td class=l>")
    html_escape(&b, f.name)
    fmt.sbprintf(
      &b,
      "</td><td>%.1f</td><td>%.1f</td><td>%+.1f</td><td>%s</td><td>%d</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td>%s</td><td class=l>%s</td></tr>\n",
      f.d_player_h,
      f.d_player_3d,
      f.dy,
      f.d_lastkill_h < 0 ? "-" : fmt.tprintf("%.1f", f.d_lastkill_h),
      f.cluster,
      yn(f.in_melee),
      yn(f.in_engage),
      reach_word(f.reach_status),
      yn(f.blocked),
      yn(f.on_cooldown),
      stage_name(f.stage),
    )
  }
  fmt.sbprint(&b, "</tbody></table>\n")
  return strings.to_string(b)
}

// Compact console table + summary, so the run is fully usable headless and pasteable without a
// screenshot. Prints the ranked mobs (and a tail of excluded ones).
tc_print_console :: proc(dbg: TC_Debug, s: TC_Summary, names: []string) {
  fmt.printfln("target order - %s : %d candidates, %d ranked, %d excluded", auto_target_desc(names), s.n, s.ranked, s.excluded)
  fmt.printfln("  anchor: %s", dbg.anchor_src)
  nearest_ranked := len(dbg.order) > 0 ? dbg.facts[dbg.order[0]].d_player_h : -1
  if dbg.engage > 0 && nearest_ranked > dbg.engage {
    fmt.printfln(
      "  ! nearest mob %.0f > engage %.0f: nothing in attack range at pick time -> pack/pocket logic INACTIVE (strict nearest). if you hit from ~%.0f, try 'set attack_range %.0f'.",
      nearest_ranked,
      dbg.engage,
      nearest_ranked,
      nearest_ranked + 2,
    )
  }
  fmt.printfln(
    "  ranges: attack_range=%.0f melee=%.0f engage=%.0f density=%s | vert |Δy| max %.1f mean %.1f | spacing nn min %.1f mean %.1f",
    dbg.attack_range,
    dbg.melee,
    dbg.engage,
    dbg.density_on ? fmt.tprintf("on (mingain=%d detour=%.0f)", dbg.min_gain, dbg.max_detour) : "off",
    s.dy_max,
    s.dy_mean,
    s.spacing_min,
    s.spacing_mean,
  )
  fmt.printfln(
    "  stages: melee %d avoid %d cluster %d pocket %d nearest %d density %d | reversals %d/%d | excluded: cooldown %d blocked %d unreach %d",
    s.stage_counts[.Melee],
    s.stage_counts[.Avoid],
    s.stage_counts[.Cluster],
    s.stage_counts[.Pocket],
    s.stage_counts[.Nearest],
    s.stage_counts[.Density],
    dbg.reversals,
    len(dbg.order),
    s.n_cooldown,
    s.n_blocked,
    s.n_unreach,
  )
  fmt.println("   #  d_horiz  d_3d    Δy   d_lkill  pack  m e r b c  stage     name   (r reach: . clear / w wall / o object)")
  order := make([dynamic]int, context.temp_allocator)
  for idx in dbg.order {
    append(&order, idx)
  }
  for f, i in dbg.facts {
    if f.rank < 0 {
      append(&order, i)
    }
  }
  shown := 0
  for idx in order {
    if shown >= 30 {
      fmt.printfln("   ... (%d more)", len(order) - shown)
      break
    }
    f := dbg.facts[idx]
    rank_s := f.rank >= 0 ? fmt.tprintf("%3d", f.rank + 1) : "  -"
    lk_s := f.d_lastkill_h < 0 ? "     -" : fmt.tprintf("%6.1f", f.d_lastkill_h)
    fmt.printfln(
      "  %s %7.1f %6.1f %+5.1f  %s  %4d  %s %s %s %s %s  %-8s  %s",
      rank_s,
      f.d_player_h,
      f.d_player_3d,
      f.dy,
      lk_s,
      f.cluster,
      yn(f.in_melee),
      yn(f.in_engage),
      f.reach_status == .Clear ? "." : (f.reach_status == .Blocked_Terrain ? "w" : "o"),
      yn(f.blocked),
      yn(f.on_cooldown),
      stage_name(f.stage),
      f.name,
    )
    shown += 1
  }
}

// tdbg [label] [zoom] - write a top-down radar map of the PREDICTED auto kill-order to
// tc_map[_label].html and print the same as a console table. The mob filter is whatever `auto` is set
// to (or any-monster); the optional label tags the output file so you can diff maps (`tdbg cloakia` vs
// `tdbg tower`). A trailing NUMBER sets the map's view radius in world units (e.g. `tdbg tower 30` to
// zoom in); omit it to auto-fit. Predicts the pack-walk from your selected mob / nearest mob when auto
// isn't running, so the order is meaningful either way.
cli_tdbg :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  // A trailing numeric arg is the view radius (zoom); the rest is the label.
  zoom: f32 = 0
  label_parts := make([dynamic]string, context.temp_allocator)
  for a in args {
    if v, vok := strconv.parse_f64(a); vok && v > 0 {
      zoom = f32(v)
    } else {
      append(&label_parts, a)
    }
  }
  label := strings.trim(strings.join(label_parts[:], " ", context.temp_allocator), "'\"")
  names := session.auto_names[:] // predict for the current auto target set (empty = any monster)

  dbg, ok := tc_predict_order(session, names)
  if !ok {
    fmt.eprintln("could not read world/player anchors (wrong build or not in-game?). run 'setup <name>' first.")
    return
  }
  if len(dbg.facts) == 0 {
    fmt.printfln("no %s candidates in view.", auto_target_desc(names))
    return
  }

  s := tc_summarize(dbg)
  tc_print_console(dbg, s, names)

  html := tc_render_html(session, dbg, s, names, label, zoom)
  fname := label == "" ? "tc_map.html" : fmt.tprintf("tc_map_%s.html", sanitize_label(label))
  if err := os.write_entire_file(fname, transmute([]byte)html); err != nil {
    fmt.eprintfln("tdbg: failed to write %s (%v).", fname, err)
    return
  }
  fmt.printfln("tdbg: wrote ./%s in the memscan working dir  (open it in a browser)", fname)
}
