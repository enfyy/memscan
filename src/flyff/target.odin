package flyff

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:time"
import win "core:sys/windows"
import "../engine"

TC_Cand :: struct {
  obj: uintptr,
  d:   f32, // horizontal (ground-plane) distance to the player - the picker's sort + range gates use it
  pos: [3]f32, // mob world position (for the post-stuck opposite-direction retarget)
}

// A mob target_closest recently selected. We skip these for TC_RECENT_NS so a just-killed
// mob (which keeps reading as alive while it plays its death/despawn animation) isn't
// immediately re-selected. See the crash/death notes: there's no reliable in-memory "dead"
// flag we can read, so we avoid re-picking what we just picked instead.
TC_Recent :: struct {
  obj: uintptr,
  t:   i64, // time.now()._nsec when picked
}
TC_RECENT_NS :: i64(6_000_000_000) // ~6s, a bit longer than the corpse despawn delay

// True if <obj> appears in <list> (a recent-picks / blocked TC_Recent set) within <window> ns of <now>.
// Shared by the cooldown (tc_recent / TC_RECENT_NS) and stuck-blacklist (auto_blocked / BLOCKED_NS) skip
// tests; taking the list as a slice lets the debug predictor pass a local copy it mutates per sim-kill.
recent_list_contains :: proc(list: []TC_Recent, obj: uintptr, now: i64, window: i64) -> bool {
  for r in list {
    if r.obj == obj && now - r.t < window {
      return true
    }
  }
  return false
}

tc_mark_recent :: proc(session: ^Session, obj: uintptr, now: i64) {
  i := 0
  for i < len(session.tc_recent) {
    r := session.tc_recent[i]
    if r.obj == obj || now - r.t >= TC_RECENT_NS {
      unordered_remove(&session.tc_recent, i) // drop the old entry for obj + any expired
    } else {
      i += 1
    }
  }
  append(&session.tc_recent, TC_Recent{obj = obj, t = now})
}

// How long a mob flagged unreachable by the stuck-monitor stays blacklisted. Long enough to walk
// off and find other mobs, short enough that a genuinely-reachable mob (mis-flagged, or the obstacle
// cleared) becomes eligible again.
BLOCKED_NS :: i64(20_000_000_000) // ~20s

// Flag <obj> as blocked (unreachable) as of <now>, dropping any stale/duplicate entry first.
// Mirrors tc_mark_recent against the auto_blocked list.
mark_blocked :: proc(session: ^Session, obj: uintptr, now: i64) {
  i := 0
  for i < len(session.auto_blocked) {
    r := session.auto_blocked[i]
    if r.obj == obj || now - r.t >= BLOCKED_NS {
      unordered_remove(&session.auto_blocked, i)
    } else {
      i += 1
    }
  }
  append(&session.auto_blocked, TC_Recent{obj = obj, t = now})
}

// Proactive reach gate: is the straight approach to <cand_pos> clear (terrain grid + object OBBs)?
// Object colliders come from collect_area_colliders, which full-scans and CACHES (rebuilt only when the
// player moves), so the pick loop hits pure math after one scan - no per-candidate cost and no dependence
// on aobjcull_rva / findcull. compute_reach's terrain part self-noops if terrain isn't calibrated. Only
// inert when the world hasn't resolved (uncalibrated). Selecting an unreachable mob jams the character -
// this skips it up front.
cand_reach_status :: proc(session: ^Session, world: uintptr, player_pos, cand_pos: [3]f32) -> Reach_Status {
  if world == 0 {
    return .Clear // uncalibrated / not in-game - nothing to test against
  }
  res := compute_reach(session, world, player_pos[0], player_pos[1], player_pos[2], cand_pos[0], cand_pos[2])
  return res.status
}

cand_reachable :: proc(session: ^Session, world: uintptr, player_pos, cand_pos: [3]f32) -> bool {
  return cand_reach_status(session, world, player_pos, cand_pos) == .Clear
}

// Which cascade stage selected a target (for the debug map + logs). Excluded = never eligible.
TC_Stage :: enum {
  None,
  Melee,
  Avoid,
  Pocket,
  Nearest,
  Density,
  Excluded,
}

// Everything the pick cascade reads, snapshotted so a pick never touches live session state mid-run.
// The live picker (tc_select) builds one from the session and applies the result back; the debug
// predictor (tc_predict_order) builds one and then mutates a LOCAL copy across simulated kills. Ranges
// are ctx-carried so Phase 4 can feed attack_range in without touching the cascade.
Pick_Ctx :: struct {
  player_pos:    [3]f32,
  world:         uintptr, // for the reach gate (reads game memory; never mutated)
  now:           i64,
  name_filtered: bool, // len(names) > 0 -> the melee fast-path is enabled
  require_fresh: bool, // auto (true) vs manual target_closest (false)
  gate:          bool, // proactive reach filter on
  fence_on:      bool, // geo-fence gate on (session.fence.active) - skip mobs outside the fenced area
  avoid_on:      bool, // one-shot: prefer the opposite side from the last stuck mob
  avoid_dir:     [2]f32,
  last_kill_set: bool,
  last_kill_pos: [3]f32,
  melee:         f32, // melee fast-path radius (MELEE_RANGE today; attack_range-derived in Phase 4)
  engage:        f32, // bow/pocket radius (BOW_RANGE today)
  recent:        []TC_Recent, // cooldown set (skip just-killed); session.tc_recent live, a copy in sim
  blocked:       []TC_Recent, // stuck-blacklist set; session.auto_blocked live, a copy in sim
  density:       []int, // per-candidate local pack size (index-aligned to cands); nil = don't score
  density_w:     f32, // density_weight (world units); 0 = disabled (strict-nearest walk fallback)
}

// Skip test for one candidate: already consumed (alive[i]==false), on the recently-targeted cooldown,
// stuck-blacklisted, or (when gated) proactively unreachable. Reads the cooldown/blocked sets from ctx
// so a simulation can pass local copies. `alive` nil = every candidate still in the pool. Manual
// selection leaves ctx.gate false so it still honours an explicit pick behind cover.
tc_cand_skip :: proc(session: ^Session, ctx: Pick_Ctx, cands: []TC_Cand, i: int, alive: []bool) -> bool {
  if alive != nil && !alive[i] {
    return true
  }
  c := cands[i]
  if recent_list_contains(ctx.recent, c.obj, ctx.now, TC_RECENT_NS) {
    return true
  }
  if recent_list_contains(ctx.blocked, c.obj, ctx.now, BLOCKED_NS) {
    return true
  }
  if ctx.gate && !cand_reachable(session, ctx.world, ctx.player_pos, c.pos) {
    return true
  }
  if ctx.fence_on && !fence_contains(session.fence, c.pos[0], c.pos[2]) {
    return true // outside the configured geo-fence area
  }
  return false
}

// The target-selection cascade, factored out of tc_select so the live picker AND the debug predictor
// run the SAME logic (no drift). Returns the index into cands of the pick and which stage chose it, or
// (-1, .None) when nothing is eligible. Pure: reads ctx + game memory, mutates neither session nor ctx.
// Cands MUST be sorted nearest-first (tc_collect_cands does this) - the melee/pocket range breaks rely
// on it. Stages, in order: melee fast-path (name-filtered auto), opposite-side avoid (one-shot),
// bow-pocket nearest-to-last-kill, then plain nearest.
tc_pick_one :: proc(session: ^Session, cands: []TC_Cand, ctx: Pick_Ctx, alive: []bool) -> (idx: int, stage: TC_Stage) {
  // Melee fast-path: a mob in melee range is immediately reachable, so take the nearest such and skip
  // the anchor heuristics. Name-filtered auto ONLY: in any-monster mode something is almost always in
  // melee range, so this would grab whatever's closest and ignore the last-kill anchor, making the pick
  // ping-pong across the field.
  if ctx.require_fresh && ctx.name_filtered {
    for c, i in cands {
      if c.d > ctx.melee {
        break // sorted by distance - nothing further is in melee range
      }
      if tc_cand_skip(session, ctx, cands, i, alive) {
        continue
      }
      return i, .Melee
    }
  }
  // Right after a stuck-skip, prefer the nearest eligible mob on the OPPOSITE side of us from the one we
  // jammed on (dot(player->cand, avoid_dir) < 0), so we walk away from the wall instead of back into it.
  if ctx.require_fresh && ctx.avoid_on {
    for c, i in cands {
      if !cand_is_opposite(ctx.player_pos, c.pos, ctx.avoid_dir) {
        continue // cheap direction test first; only reach-check opposite-side candidates
      }
      if tc_cand_skip(session, ctx, cands, i, alive) {
        continue
      }
      return i, .Avoid
    }
  }
  // Bow-range retarget ("stay on the pack"): if an eligible mob is within engage range, pick the in-range
  // mob nearest the last kill's spot rather than the one nearest us. This is what stops a ranged/AoE char
  // from ping-ponging: it keeps re-targeting the pack it's already shooting instead of chasing whatever is
  // momentarily nearest. It's driven by engage (= attack_range), so it's only useful when attack_range is
  // set to your REAL hit range; with a too-small attack_range nothing is ever in engage and this is inert
  // (strict nearest, which ping-pongs). NOT gated by density - density is a separate, additive stage below.
  if ctx.require_fresh && ctx.last_kill_set {
    best := -1
    best_ad := f32(1e30)
    for c, i in cands {
      if c.d > ctx.engage {
        break // sorted by distance - nothing further is in engage range
      }
      if tc_cand_skip(session, ctx, cands, i, alive) {
        continue
      }
      ad := engine.dist_horizontal(c.pos, ctx.last_kill_pos)
      if ad < best_ad {
        best_ad = ad
        best = i
      }
    }
    if best >= 0 {
      return best, .Pocket
    }
  }
  // Density-steered walk pick: with density steering on (auto only, density_w > 0), when nothing eligible
  // is in engage range this stage chooses WHICH pack to walk to next - the eligible candidate maximizing
  // pack size vs travel distance (score = pack * W / (W + d)), so we head for a dense cluster instead of
  // the nearest lone straggler. A denser-but-farther pack only wins when its size beats the distance
  // penalty. With all packs equal (e.g. every mob isolated, pack==1) the score is monotone in -d, so it
  // reduces to the strict-nearest pick below - fully backward-compatible when density_w == 0.
  if ctx.require_fresh && ctx.density_w > 0 && len(ctx.density) == len(cands) {
    best := -1
    best_score := f32(-1)
    for c, i in cands {
      if tc_cand_skip(session, ctx, cands, i, alive) {
        continue
      }
      score := f32(ctx.density[i]) * ctx.density_w / (ctx.density_w + c.d)
      if score > best_score {
        best_score = score
        best = i
      }
    }
    if best >= 0 {
      return best, .Density
    }
  }
  // Fallback: the nearest eligible mob.
  for _, i in cands {
    if !tc_cand_skip(session, ctx, cands, i, alive) {
      return i, .Nearest
    }
  }
  return -1, .None
}

// True if <name> case-insensitively equals any entry in <names>. An empty <names> list is
// handled by the caller (means "match any"), so this returns false on empty.
name_matches :: proc(name: string, names: []string) -> bool {
  for n in names {
    if strings.equal_fold(name, n) {
      return true
    }
  }
  return false
}

// True if <obj> is a safe, correct focus target: a live object (vtable in module), a mover
// (type 5), name-matches one of <names> (or ANY mover when <names> is empty), has currentHP > 0,
// and a mapped m_pModel. Selecting a model-less / freed object crashes the client (it derefs the
// focused object's model to draw the selection), so this is used BOTH as the enumeration filter
// AND as the re-check done immediately before the focus write - objects can be freed/reallocated
// in between. NOTE: an empty <names> matches any mover including NPCs/other players; the caller
// (tc_collect_cands) excludes the player object and, in any-monster mode, applies the AII gate that
// keeps only attackable monsters (m_dwAIInterface == AII_MONSTER).
obj_is_selectable :: proc(session: ^Session, obj: uintptr, names: []string) -> bool {
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  vt, vok := engine.read_value(handle, obj, pt)
  if !vok {
    return false
  }
  vtable := uintptr(engine.value_as_u64(pt, vt))
  if vtable < base || vtable >= mod_end {
    return false // not a live object
  }
  if engine.read_obj_type(handle, obj, session.layout.pos_off) != session.layout.mover_type {
    return false // movers only
  }
  // Name gate: an empty list matches any mover (auto with no name); otherwise require a match. Uses the
  // species prop name (reliable) so named auto works even for mobs whose inline name buffer misreads.
  if len(names) > 0 {
    nm, nok := read_mover_name(session, obj)
    if !nok || !name_matches(nm, names) {
      return false
    }
  }
  // skip dying-but-not-despawned mobs (currentHP <= 0); a failed read leaves it eligible
  if hpv, hok := engine.read_value(handle, obj + uintptr(session.layout.hp_off), .U32); hok {
    if i32(u32(engine.value_as_u64(.U32, hpv))) <= 0 {
      return false
    }
  }
  // require a live, mapped model - selecting a model-less mob crashes the client
  model: uintptr = 0
  if mv, mok := engine.read_value(handle, obj + uintptr(session.layout.model_off), pt); mok {
    model = uintptr(engine.value_as_u64(pt, mv))
  }
  if model < 0x10000 {
    return false
  }
  if _, mok2 := engine.read_value(handle, model, pt); !mok2 {
    return false
  }
  return true
}

// True if the species prop-table gate is configured (findprop has run): the array pointer RVA and
// the record stride are both known. The AI offset may legitimately be small, so it isn't required.
prop_gate_ready :: proc(session: ^Session) -> bool {
  return session.layout.propmover_rva != 0 && session.layout.moverprop_stride != 0
}

// Live-validated prop gate for the setup / status babysitter (NOT the per-frame hot path): besides the
// offsets being set, actually resolve the MoverProp array pointer through propmover_rva and confirm it's
// non-zero. This catches a STALE non-zero propmover_rva carried over from a previous build after a game
// patch - the cheap prop_gate_ready would wrongly report that as configured, so `status` used to say
// "SETUP 6/6 COMPLETE" while the detail line said "[BROKEN] array pointer doesn't resolve".
prop_gate_live_ok :: proc(session: ^Session) -> bool {
  if !prop_gate_ready(session) || !session.attached {
    return false
  }
  pt := session.ptr_size == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  v, ok := engine.read_value(session.proc_info.handle, session.proc_info.base + session.layout.propmover_rva, pt)
  return ok && uintptr(engine.value_as_u64(pt, v)) != 0
}

// Read a mover's species AI class the way the client does: GetProp()->dwAI, i.e.
// [propbase + m_dwIndex*stride + moverprop_ai_off]. <propbase> is the already-resolved MoverProp
// array base. Returns 0xFFFFFFFF on any read failure or an out-of-range species id, so the caller
// treats such a mover as "not a monster" (conservative skip).
species_ai :: proc(session: ^Session, propbase: uintptr, obj: uintptr) -> u32 {
  handle := session.proc_info.handle
  idv, idok := engine.read_value(handle, obj + uintptr(session.layout.pos_off + SPECIES_REL), .U32)
  if !idok {
    return 0xFFFFFFFF
  }
  id := u32(engine.value_as_u64(.U32, idv))
  if id > 0xFFFF {
    return 0xFFFFFFFF // garbage / freed object - real species ids are small (~1300 max)
  }
  rec := propbase + uintptr(i64(id) * session.layout.moverprop_stride) + uintptr(session.layout.moverprop_ai_off)
  av, aok := engine.read_value(handle, rec, .U32)
  if !aok {
    return 0xFFFFFFFF
  }
  return u32(engine.value_as_u64(.U32, av))
}

// Best-effort mover NAME. For MONSTERS the reliable name is the species prop szName (GetProp()->szName)
// - the inline object name buffer misreads for some mobs (e.g. a Turtle Spear reads "USER32"). Pets,
// players, and NPCs keep their inline INSTANCE name (a pet's custom name like "jefe", a player's
// character name) - the species prop only has the generic species name for those. So: prop szName when
// the species is AII_MONSTER, else the inline buffer. Falls back to inline when the prop gate isn't
// configured. Result is temp-allocated.
read_mover_name :: proc(session: ^Session, obj: uintptr) -> (string, bool) {
  handle := session.proc_info.handle
  L := session.layout
  if L.propmover_rva != 0 && L.moverprop_stride != 0 {
    pt := engine.Value_Type.U64
    if session.ptr_size == 4 {
      pt = .U32
    }
    if pbv, ok := engine.read_value(handle, session.proc_info.base + L.propmover_rva, pt); ok {
      propbase := uintptr(engine.value_as_u64(pt, pbv))
      if propbase != 0 {
        if idv, iok := engine.read_value(handle, obj + uintptr(L.pos_off + SPECIES_REL), .U32); iok {
          id := u32(engine.value_as_u64(.U32, idv))
          if id != 0 && id <= 0xFFFF {
            rec := propbase + uintptr(i64(id) * L.moverprop_stride)
            // Only override the inline name for real monsters (species-named); pets/players/NPCs have
            // their own instance name inline.
            if aiv, aok := engine.read_value(handle, rec + uintptr(L.moverprop_ai_off), .U32);
               aok && u32(engine.value_as_u64(.U32, aiv)) == AII_MONSTER {
              nb: [40]byte
              if n, rok := engine.read_into(handle, rec + uintptr(MOVERPROP_NAME_OFF), nb[:]); rok && n > 0 {
                e := 0
                for e < len(nb) && nb[e] >= 0x20 && nb[e] < 0x7F {
                  e += 1
                }
                name := strings.trim_space(string(nb[:e]))
                if len(name) > 0 {
                  return strings.clone(name, context.temp_allocator), true
                }
              }
            }
          }
        }
      }
    }
  }
  return engine.read_obj_name(handle, session.ptr_size, obj, L.name_off)
}

// Scan for objects and return the selectable movers matching <names> (or any mover when
// <names> is empty), nearest first. Enumerates ALL writable regions fresh every call - complete
// regardless of spawns/zoning (the old region cache went stale and missed most of a big spawn).
// Each world-ptr hit is gated by obj_is_selectable (live object, mover, name, HP, model). The
// <player> object is always skipped. In any-monster mode (empty <names>) the species prop-table gate
// is the sole target filter: a mover whose GetProp()->dwAI (indexed by m_dwIndex) != AII_MONSTER is
// skipped, so pets / eggs / NPCs / other players / bosses are excluded. Inert until `findprop` runs.
tc_collect_cands :: proc(
  session: ^Session,
  names: []string,
  world: uintptr,
  player: uintptr,
  player_pos: [3]f32,
) -> [dynamic]TC_Cand {
  handle := session.proc_info.handle
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  // Attackable-monster gate: only in any-monster mode (empty names), require the mover's SPECIES to be
  // a monster - GetProp()->dwAI == AII_MONSTER, read from the client's MoverProp array. This excludes
  // pets (AII_PET=5), eggs (AII_EGG=9), NPCs (AII_NONE), other players, and special-AI bosses. Inert
  // until `findprop` fills propmover_rva / moverprop_stride / moverprop_ai_off. `propbase` is resolved
  // once here (the array base); per-mover we index it by m_dwIndex.
  prop_gate := len(names) == 0 && prop_gate_ready(session)
  propbase: uintptr = 0
  if prop_gate {
    if pb, ok := engine.read_value(handle, session.proc_info.base + session.layout.propmover_rva, pt); ok {
      propbase = uintptr(engine.value_as_u64(pt, pb))
    }
    if propbase == 0 {
      prop_gate = false // couldn't resolve the array; fall back to no gate rather than mis-filter
    }
  }
  wval := engine.ptr_to_value(world, session.ptr_size)
  regions := engine.collect_regions(handle, true) // all writable - complete, no stale cache
  defer delete(regions)
  set := engine.scan_exact_parallel(handle, pt, wval, regions[:], context.temp_allocator) // multithreaded

  cands := make([dynamic]TC_Cand, context.temp_allocator)
  for m in set.matches {
    obj := uintptr(i64(m.addr) - session.layout.field_off)
    if obj == player {
      continue // never target yourself (matters in any-monster mode where the name gate is off)
    }
    if prop_gate && species_ai(session, propbase, obj) != AII_MONSTER {
      continue // not an attackable monster (pet / egg / NPC / other player / boss) - any-monster mode only
    }
    if !obj_is_selectable(session, obj, names) {
      continue
    }
    pos, posok := engine.read_vec3(handle, obj + uintptr(session.layout.pos_off))
    if !posok {
      continue
    }
    append(&cands, TC_Cand{obj = obj, d = engine.dist_horizontal(pos, player_pos), pos = pos})
  }
  slice.sort_by(cands[:], proc(a, b: TC_Cand) -> bool {return a.d < b.d})
  return cands
}

// The density scorer's neighborhood radius (world units) - what counts as one "pack". Derived from the
// engage range so it scales with reach, floored so a melee character (tiny engage) still sees real
// clusters rather than only point-blank neighbors.
density_radius :: proc(engage: f32) -> f32 {
  r := engage * 2
  if r < DENSITY_R_MIN {
    r = DENSITY_R_MIN
  }
  return r
}

// Local PACK SIZE per candidate: how many candidates (including itself) lie within `r` horizontally.
// Index-aligned to `cands`; O(n^2) over the candidate set (tens-to-~150) so sub-millisecond. Run once
// per pick and carried in Pick_Ctx.density, so the live picker (tc_select) and the debug predictor
// (tc_predict_order) score identically. A lone mob has pack size 1. Temp-allocated.
compute_densities :: proc(cands: []TC_Cand, r: f32) -> []int {
  out := make([]int, len(cands), context.temp_allocator)
  r2 := r * r
  for a, i in cands {
    c := 0
    for b in cands {
      dx := a.pos[0] - b.pos[0]
      dz := a.pos[2] - b.pos[2]
      if dx * dx + dz * dz <= r2 {
        c += 1 // counts itself (d=0), so pack size is always >= 1
      }
    }
    out[i] = c
  }
  return out
}

// True if <cand_pos> lies on the opposite side of the player from <avoid> (a horizontal x,z delta
// pointing at the mob we just got stuck on). Only the sign of the dot matters, so no normalization
// is needed - a zero/degenerate avoid yields dot 0 (not opposite), so nothing qualifies and the
// caller falls back to the normal nearest pick.
cand_is_opposite :: proc(player_pos, cand_pos: [3]f32, avoid: [2]f32) -> bool {
  dx := cand_pos[0] - player_pos[0]
  dz := cand_pos[2] - player_pos[2]
  return dx * avoid[0] + dz * avoid[1] < 0
}

TC_Result :: enum {
  Picked, // wrote a mob into m_pObjFocus; obj/d/sel/total are set
  NoCandidates, // no selectable mover named <name> nearby
  AllOnCooldown, // candidates exist but all recently targeted (only when require_fresh)
  WentStale, // chosen obj was freed/reallocated between enumeration and the write
  AnchorFail, // couldn't read the world/player anchors (not in-game / wrong build)
  WriteFail, // the focus write failed (message already printed)
}

// Write <obj> into m_pObjFocus (the selected-target field) with the client-safe crash-guard +
// server-notify. Shared by tc_select (its distance-picked mob), the `target_at` command, and the
// radar's click-to-target - so all three go through one guard+write+notify. Re-validates <obj> with
// obj_is_selectable IMMEDIATELY before the write (it can be freed between the caller picking it and
// here); writing a stale/model-less pointer crashes the client's selection-render, so a failed guard
// returns .WentStale instead of writing. <names> gates the re-check (empty = any mover, e.g. a radar
// click targets whatever you clicked). Marks the pick on the recently-targeted cooldown so a later
// `auto` doesn't immediately re-skip it. Caller MUST hold exec_mutex.
focus_set_obj :: proc(session: ^Session, obj: uintptr, names: []string) -> TC_Result {
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  if !wok {
    return .AnchorFail
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  if world == 0 {
    return .AnchorFail
  }
  focus_addr := world + uintptr(session.layout.focus_off)
  if !obj_is_selectable(session, obj, names) {
    return .WentStale
  }
  tc_mark_recent(session, obj, time.now()._nsec)
  if !engine.write_value(handle, focus_addr, pt, engine.ptr_to_value(obj, session.ptr_size)) {
    fmt.eprintfln("write failed at focus 0x%X (error %d)", focus_addr, win.GetLastError())
    return .WriteFail
  }
  // Server sync: make the client emit its own SendSetTarget so the server registers the same target
  // (stops the after-N-kills DC). Inert unless 'srvsync on' and the srvsync offsets are configured.
  if session.srvsync_on {
    notify_server_target(session, obj)
  }
  return .Picked
}

// Resolve the Flyff world/player anchors, enumerate selectable movers named <name>, pick
// one by distance, and write it into m_pObjFocus - atomically, so the pick can't go stale
// between ranking and selecting. Shared by manual `target_closest` and the auto-farm loop.
// All the crash guards live in tc_collect_cands (vtable-in-module, type 5, HP>0, mapped
// model), so this never writes a dead/model-less mob.
//   require_fresh=false (manual): when every candidate is on the recently-targeted cooldown,
//     fall back to the closest - the #1<->#2 / next-fresh cycle of repeated presses.
//   require_fresh=true (auto): return AllOnCooldown instead, so a lone just-killed mob isn't
//     re-selected while it's still a fresh-looking corpse.
tc_select :: proc(
  session: ^Session,
  names: []string,
  require_fresh: bool,
) -> (
  res: TC_Result,
  obj: uintptr,
  d: f32,
  sel: int,
  total: int,
) {
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }

  // Resolve world + player from the static anchors.
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  pv, pok := engine.read_value(handle, base + session.layout.player_rva, pt)
  if !wok || !pok {
    return .AnchorFail, 0, 0, 0, 0
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  player := uintptr(engine.value_as_u64(pt, pv))
  player_pos, ppok := engine.read_vec3(handle, player + uintptr(session.layout.pos_off))
  if !ppok {
    return .AnchorFail, 0, 0, 0, 0
  }

  // Collect selectable (alive + rendered) movers matching <names> (or any mover), nearest first.
  cands := tc_collect_cands(session, names, world, player, player_pos)
  total = len(cands)
  if total == 0 {
    return .NoCandidates, 0, 0, 0, 0
  }

  // Build the pick context from live session state and run the shared cascade (tc_pick_one). A
  // just-killed mob can keep reading as alive (HP unchanged, model still valid) while it plays its
  // death animation, so the cooldown set (session.tc_recent) skips recent picks and advances to the
  // next mob after each kill.
  now := time.now()._nsec
  melee, engage := pick_ranges(session)
  // Density steering (auto only): precompute per-candidate pack sizes so the walk-target fallback can
  // prefer clusters. Skipped entirely when off (weight 0) or for manual picks, so tc pays no O(n^2) cost.
  dens: []int = nil
  if require_fresh && session.layout.density_weight > 0 {
    dens = compute_densities(cands[:], density_radius(engage))
  }
  ctx := Pick_Ctx {
    player_pos    = player_pos,
    world         = world,
    now           = now,
    name_filtered = len(names) > 0,
    require_fresh = require_fresh,
    gate          = require_fresh && session.reach_gate_on, // reach filter (auto only; inert w/o aobjcull_rva)
    fence_on      = session.fence.active, // geo-fence gate (auto + manual when active; 'fence off' to override)
    avoid_on      = session.auto_avoid_on,
    avoid_dir     = session.auto_avoid_dir,
    last_kill_set = session.last_kill_set,
    last_kill_pos = session.last_kill_pos,
    melee         = melee,
    engage        = engage,
    recent        = session.tc_recent[:],
    blocked       = session.auto_blocked[:],
    density       = dens,
    density_w     = session.layout.density_weight,
  }
  idx, _ := tc_pick_one(session, cands[:], ctx, nil)
  if idx < 0 {
    if require_fresh {
      return .AllOnCooldown, 0, 0, 0, total // don't re-lock a fresh corpse (auto)
    }
    idx = 0 // manual: fall back to the closest
  } else if require_fresh {
    session.auto_avoid_on = false // one-shot: consumed by this auto pick
  }
  chosen := cands[idx]
  sel = idx
  // Guard-revalidate + write m_pObjFocus + server-notify via the shared helper. It re-checks
  // obj_is_selectable immediately before the write (shrinking the TOCTOU window from the ~ms
  // sort/pick above to ~µs), so a freed/model-less pointer is refused, not written.
  if r := focus_set_obj(session, chosen.obj, names); r != .Picked {
    return r, chosen.obj, chosen.d, sel, total
  }
  if require_fresh {
    // Remember this mob (obj + where it was) so auto_tick can confirm it actually died before it
    // counts/prints a kill and anchors to it. Cleared/promoted before the next pick (tracks one target).
    session.auto_sel_pos = chosen.pos
    session.auto_sel_obj = chosen.obj
    session.auto_sel_set = true
  }
  return .Picked, chosen.obj, chosen.d, sel, total
}

// Pre-select: compute (but do NOT select) the mob auto would advance to AFTER the current target dies, so
// auto_tick can commit it the instant focus clears - removing the ~0.5s post-kill enumeration gap. Reuses
// the live cascade (tc_collect_cands + tc_pick_one) so it never drifts from tc_select. <current_focus> is
// the mob we're still fighting: it's EXCLUDED from the pick (added to a local cooldown copy, since it may
// have outlived TC_RECENT_NS during a long fight) and its live position anchors the pocket pass (that's
// where we'll be standing when it dies, so the next pick stays on this pack). Read-only: no focus write,
// no cooldown mark - both happen when auto_tick actually commits the pick (focus_set_obj). ok=false when
// the anchors fail or nothing else is eligible, so the caller just falls back to the reactive tc_select.
tc_precompute_next :: proc(
  session: ^Session,
  names: []string,
  current_focus: uintptr,
) -> (
  obj: uintptr,
  pos: [3]f32,
  ok: bool,
) {
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  pv, pok := engine.read_value(handle, base + session.layout.player_rva, pt)
  if !wok || !pok {
    return 0, {}, false
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  player := uintptr(engine.value_as_u64(pt, pv))
  player_pos, ppok := engine.read_vec3(handle, player + uintptr(session.layout.pos_off))
  if !ppok {
    return 0, {}, false
  }

  cands := tc_collect_cands(session, names, world, player, player_pos)
  if len(cands) == 0 {
    return 0, {}, false
  }

  now := time.now()._nsec
  melee, engage := pick_ranges(session)
  dens: []int = nil
  if session.layout.density_weight > 0 {
    dens = compute_densities(cands[:], density_radius(engage))
  }
  // Anchor the pocket pass to the mob we're about to kill (its live position), so the next pick stays on
  // this pack; fall back to the live last-kill anchor, then the player, if the focus pos can't be read.
  anchor := player_pos
  anchor_set := session.last_kill_set
  if anchor_set {
    anchor = session.last_kill_pos
  }
  if fpos, fok := engine.read_vec3(handle, current_focus + uintptr(session.layout.pos_off)); fok {
    anchor = fpos
    anchor_set = true
  }
  // Exclude the current focus from the pick via a local cooldown copy (never mutate session state here).
  local_recent := make([dynamic]TC_Recent, context.temp_allocator)
  append(&local_recent, ..session.tc_recent[:])
  append(&local_recent, TC_Recent{obj = current_focus, t = now})
  ctx := Pick_Ctx {
    player_pos    = player_pos,
    world         = world,
    now           = now,
    name_filtered = len(names) > 0,
    require_fresh = true,
    gate          = session.reach_gate_on,
    fence_on      = session.fence.active,
    avoid_on      = false, // pre-select never runs the one-shot stuck-avoid steer
    last_kill_set = anchor_set,
    last_kill_pos = anchor,
    melee         = melee,
    engage        = engage,
    recent        = local_recent[:],
    blocked       = session.auto_blocked[:],
    density       = dens,
    density_w     = session.layout.density_weight,
  }
  idx, _ := tc_pick_one(session, cands[:], ctx, nil)
  if idx < 0 {
    return 0, {}, false
  }
  return cands[idx].obj, cands[idx].pos, true
}

// One-shot: select the nearest selectable mover matching <name> by writing it into
// m_pObjFocus. Repeated presses advance through the nearby mobs (the recently-targeted
// cooldown skips a just-killed corpse). All anchors/offsets are baked Flyff constants, so
// it needs no setup: `target_closest Mutant Yetti`. Multiple names are allowed, comma-separated
// (quote names with spaces): `target_closest 'Mutant Yetti', 'Captain Mutant Yetti'`.
cli_target_closest :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  names := parse_target_names(strings.join(args, " ", context.temp_allocator))
  if len(names) == 0 {
    fmt.eprintln("usage: target_closest <name>[, <name> ...]")
    return
  }
  desc := auto_target_desc(names[:])

  res, obj, d, sel, total := tc_select(session, names[:], false)
  switch res {
  case .Picked:
    fmt.printfln("targeted %s #%d/%d obj=0x%X at d=%.1f.", desc, sel + 1, total, obj, d)
  case .NoCandidates:
    fmt.printfln("no %s found.", desc)
  case .AnchorFail:
    fmt.eprintln("could not read world/player anchors (wrong build or not in-game?).")
  case .AllOnCooldown:
    fmt.printfln("no fresh %s available.", desc) // unreachable with require_fresh=false
  case .WentStale:
    fmt.printfln("%s just died/despawned - try again.", desc)
  case .WriteFail: // tc_select already printed the specific error
  }
}

// target_at <addr> (alias tat) - select the EXACT object at <addr> (a raw CObj*), writing it into
// m_pObjFocus with the same crash-guard + server-notify as `tc`. Unlike `target_closest` (name +
// distance, which re-scans and could pick a different same-named mob), this pins the one object you
// name - it's the headless-testable primitive behind the radar's click-to-target (grab a live CObj*
// with `mobs`, then `target_at 0x..`). Refuses a freed / model-less / non-mover pointer (writing one
// crashes the client's selection-render). <addr> is decimal or 0x-hex.
cli_target_at :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: target_at <addr>   (a live CObj* - e.g. an address from 'mobs')")
    return
  }
  v, ok := engine.parse_addr(args[0])
  if !ok {
    fmt.eprintfln("bad address: %s", args[0])
    return
  }
  obj := uintptr(v)
  switch focus_set_obj(session, obj, nil) {
  case .Picked:
    fmt.printfln("targeted obj=0x%X.", obj)
  case .WentStale:
    fmt.printfln("obj 0x%X is not a live selectable mover (freed / model-less / wrong type) - not written.", obj)
  case .AnchorFail:
    fmt.eprintln("could not read world anchor (wrong build or not in-game?).")
  case .WriteFail: // focus_set_obj already printed the specific error
  case .NoCandidates, .AllOnCooldown: // not returned by focus_set_obj
  }
}

AUTO_MIN_INTERVAL_NS :: i64(30_000_000) // ~300ms between advance attempts (caps idle rescans)

// Stuck / obstacle detection tuning (see auto_monitor). While a target is focused we watch the
// player->target distance: no meaningful drop for STUCK_NS while still farther than ARRIVE_DIST
// means the character is jammed against an obstacle -> blacklist the mob and skip. Combat range
// (d <= ARRIVE_DIST) never trips it. PROGRESS_EPS is the min drop that counts as progress.
STUCK_NS :: i64(2_500_000_000) // ~2.5s of no progress while far -> blocked
ARRIVE_DIST :: f32(3.0) // within this of the target = arrived / in melee; never flagged
PROGRESS_EPS :: f32(0.5) // a distance drop >= this counts as making progress

// Fallback engage range, used only when attack_range isn't configured (attack_range == 0). When an
// eligible mob is within the engage range, the auto picker ranks by nearest-to-the-last-kill-anchor
// instead of nearest-to-player (stay on the pack); otherwise it walks to the nearest mob. Prefer
// 'set attack_range <n>' to your real range - pick_ranges uses that. See the pocket pass in tc_pick_one.
BOW_RANGE :: f32(16.0)

// Melee range: a mob this close is "on top of us" and immediately reachable, so it gets top pick
// priority (name-filtered auto only). Capped to the engage range. See the melee pass in tc_pick_one.
MELEE_RANGE :: f32(1.7)

// Floor for the density scorer's pack radius (density_radius), so a melee character with a tiny engage
// range still bins nearby mobs into real clusters rather than only counting point-blank neighbors.
DENSITY_R_MIN :: f32(15.0)

// The picker's two range thresholds, derived from the configured attack_range - horizontal (ground-plane)
// distances, matching tc_collect_cands. engage = your attack_range (the reach at which you can hit a mob,
// so the picker stays on the pack instead of walking to the strict-nearest); falls back to BOW_RANGE when
// attack_range is unset. melee is a short "on top of us" radius, capped to engage. Shared by the live
// picker (tc_select) and the debug predictor (tc_predict_order) so the two never drift.
pick_ranges :: proc(session: ^Session) -> (melee: f32, engage: f32) {
  engage = f32(session.layout.attack_range)
  if engage <= 0 {
    engage = BOW_RANGE
  }
  melee = MELEE_RANGE
  if melee > engage {
    melee = engage
  }
  return
}

// The weight `density on` sets - a moderate cluster bias. Tune with `density <n>` (~5 mild, ~40 strong).
DENSITY_ON_DEFAULT :: f32(20)

// density [on|off|<weight>] - toggle the auto-picker's cluster steering. OFF (weight 0) is the SIMPLE
// picker: it targets the plain nearest eligible mob and the stay-on-the-pack passes (pocket + density) are
// both inert, so a large attack_range never spreads picks - exactly the legacy behaviour. ON steers auto
// toward dense mob packs and keeps it on the current pack between kills. No arg just prints the state.
// Persisted to flyff.cfg (it's the same field as `set density_weight`). See tc_pick_one.
cli_density :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) >= 1 {
    switch strings.to_lower(args[0]) {
    case "on":
      session.layout.density_weight = DENSITY_ON_DEFAULT
    case "off":
      session.layout.density_weight = 0
    case:
      if v, ok := strconv.parse_f64(args[0]); ok && v >= 0 {
        session.layout.density_weight = f32(v)
      } else {
        fmt.eprintln("usage: density [on|off|<weight>]   (weight >= 0; ~5 mild, ~40 strong)")
        return
      }
    }
    flyff_save_cfg(session.layout, flyff_cfg_path())
  }
  if w := session.layout.density_weight; w > 0 {
    fmt.printfln("density steering: ON (weight %v) - auto prefers dense packs and stays on the pack between kills.", w)
  } else {
    fmt.println("density steering: OFF (weight 0) - auto targets the plain nearest eligible mob (simple/legacy behaviour).")
  }
}

// Read the player's world position: [base+player_rva] -> the CMover*, then +pos_off (m_vPos).
// Shared by the stuck monitor (auto_monitor) and any caller needing the live player position.
read_player_pos :: proc(session: ^Session) -> (pos: [3]f32, ok: bool) {
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  pv, pok := engine.read_value(handle, base + session.layout.player_rva, pt)
  if !pok {
    return {}, false
  }
  player := uintptr(engine.value_as_u64(pt, pv))
  if player == 0 {
    return {}, false
  }
  return engine.read_vec3(handle, player + uintptr(session.layout.pos_off))
}

// Read m_pObjFocus: world = [base+world_rva], then the CObj* at world+focus_off.
read_focus_ptr :: proc(session: ^Session) -> (focus: uintptr, ok: bool) {
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  if !wok {
    return 0, false
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  if world == 0 {
    return 0, false
  }
  fv, fok := engine.read_value(handle, world + uintptr(session.layout.focus_off), pt)
  if !fok {
    return 0, false
  }
  return uintptr(engine.value_as_u64(pt, fv)), true
}

// True if <obj> looks like a live object: its vtable points back into the game module.
// Cheap insurance so a non-zero-but-freed focus (e.g. after zoning) still triggers an
// advance; the primary auto trigger remains focus == 0 (game clears it on kill).
focus_obj_live :: proc(session: ^Session, obj: uintptr) -> bool {
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  vt, ok := engine.read_value(handle, obj, pt)
  if !ok {
    return false
  }
  vtable := uintptr(engine.value_as_u64(pt, vt))
  return vtable >= base && vtable < mod_end
}

