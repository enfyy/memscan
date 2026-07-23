package flyff

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"
import win "core:sys/windows"
import "../engine"

import tracy "../../lib/odin-tracy"

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
// Cluster = continuing an existing cluster commitment; Density = a fresh pick where the mingain/detour
// gate steered the walk to a denser pack instead of the nearest mob.
TC_Stage :: enum {
  None,
  Melee,
  Avoid,
  Cluster,
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
  player_pos:    [3]f32, // the RANKING/collection anchor (live player reactively; the kill-spot in pre-select)
  live_player:   [3]f32, // the player's ACTUAL position - the in-range (pocket) stage gates + ranks on THIS,
  // so "in range" always means "within attack_range of where I stand" (not of the rolling kill anchor).
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
  density:       []int, // per-candidate local pack size (index-aligned to cands); nil when density is off
  density_on:    bool, // master enable for the cluster/density stages; false = the v0.4.0 cascade exactly
  min_gain:      int, // extra pack members a farther pack needs to steal the pick (density stage gate 1)
  max_detour:    f32, // max extra walk distance (world units) for that detour (density stage gate 2)
  cluster_committed:  bool, // a previous pick locked onto a pack; keep eating it (cluster stage)
  cluster_origin_pos: [3]f32, // where that commitment started - the leash reference (see cluster_advance)
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
    return true // outside the configured geo-fence area (or inside an exclude/avoid carve-out)
  }
  if ctx.fence_on && fence_blocks_path(session.fence, ctx.player_pos[0], ctx.player_pos[2], c.pos[0], c.pos[2]) {
    return true // an avoid(!) zone lies across the path - can't reach this mob without entering the no-go zone
  }
  return false
}

// The target-selection cascade, factored out of tc_select so the live picker AND the debug predictor
// run the SAME logic (no drift). Returns the index into cands of the pick and which stage chose it, or
// (-1, .None) when nothing is eligible. Pure: reads ctx + game memory, mutates neither session nor ctx.
// Cands MUST be sorted nearest-first (tc_collect_cands does this) - the melee/pocket range breaks rely
// on it. Stages, in order: melee fast-path (name-filtered auto), opposite-side avoid (one-shot),
// bow-pocket nearest-to-last-kill (in-range mobs ALWAYS win - the anchor leaves attack_range only when
// it has to), cluster commitment (density on), switch-threshold density (density on), then plain
// nearest. With density off the two density stages are dead code, so the cascade is exactly the v0.4.0
// one (melee/avoid/pocket/nearest).
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
  // In-range priority ("stay on the pack, but never leave my reach"): among the mobs within attack_range
  // of where the PLAYER actually stands, take the one NEAREST THE LAST-KILL spot (pack stickiness). Above
  // the cluster stage: whatever is in range dies first, and we only leave the player's range when nothing
  // eligible is inside it.
  //   The GATE is the fix - it measures from ctx.live_player (the true player position), NOT the rolling
  // last-kill anchor. The old gate used c.d (anchor-relative; in pre-select the anchor is the kill spot,
  // up to attack_range away), so it counted mobs up to ~2x attack_range from the player as "in range" and
  // marched the target off along the pack (targets at 16, 23, 33, 45+ units while the mob next to you was
  // ignored). The RANKING stays nearest-to-last-kill so pack behaviour is unchanged; before the first kill
  // (no anchor) it falls back to nearest-to-player. c.d is anchor-relative, so the gate can't break early.
  if ctx.require_fresh {
    best := -1
    best_rank := f32(1e30)
    for c, i in cands {
      pd := engine.dist_horizontal(c.pos, ctx.live_player)
      if pd > ctx.engage {
        continue // not within attack_range of the player - can't hit it where we stand
      }
      if tc_cand_skip(session, ctx, cands, i, alive) {
        continue
      }
      rank := ctx.last_kill_set ? engine.dist_horizontal(c.pos, ctx.last_kill_pos) : pd
      if rank < best_rank {
        best_rank = rank
        best = i
      }
    }
    if best >= 0 {
      return best, .Pocket
    }
  }
  // Cluster commitment (density feature, auto only): a previous pick locked onto a pack (see
  // cluster_advance), so KEEP eating it - the eligible mob nearest the rolling anchor (last_kill_pos)
  // that is still inside the pack radius AND within the leash of where the commitment started. Only
  // reached when NOTHING eligible is in engage range (the pocket stage above owns that case), so this
  // decides where to WALK next, never drags us off an in-range mob. Other packs are not scored at all
  // while members remain; that hysteresis is what stops two similar packs from flipping the pick every
  // kill. Falls through when the committed pack has no eligible member left (wiped or all blocked),
  // landing in the density/nearest stages below for a fresh pick.
  if ctx.require_fresh && ctx.density_on && ctx.cluster_committed && ctx.last_kill_set {
    cr := density_radius(ctx.engage)
    leash := cr * CLUSTER_LEASH_MULT
    best := -1
    best_ad := f32(1e30)
    for c, i in cands {
      ad := engine.dist_horizontal(c.pos, ctx.last_kill_pos)
      if ad > cr {
        continue // not part of the committed pack
      }
      if engine.dist_horizontal(c.pos, ctx.cluster_origin_pos) > leash {
        continue // beyond the leash - don't let a spawn line chain-drag the commitment across the map
      }
      if tc_cand_skip(session, ctx, cands, i, alive) {
        continue // cheap distance gates above run first; reach checks only on real pack members
      }
      if ad < best_ad {
        best_ad = ad
        best = i
      }
    }
    if best >= 0 {
      return best, .Cluster
    }
  }
  // Switch-threshold density (density feature, auto only): nothing eligible is in engage range and no
  // committed pack has members left, so we're choosing WHICH mob to walk to next. Default is the plain
  // nearest eligible mob; a denser alternative steals the pick ONLY when it clears BOTH gates - at least
  // min_gain more pack members AND at most max_detour extra walk distance. A hard double gate instead of
  // the old continuous score, so two similarly-sized packs can never flip the pick on a marginal
  // difference. Returns .Nearest when the winner IS the nearest (no detour taken), so tdbg's stage
  // column only says "density" when the gate actually changed the pick.
  if ctx.require_fresh && ctx.density_on && len(ctx.density) == len(cands) {
    nearest := -1
    for _, i in cands {
      if !tc_cand_skip(session, ctx, cands, i, alive) {
        nearest = i
        break // sorted nearest-first
      }
    }
    if nearest >= 0 {
      best := nearest
      best_pack := ctx.density[nearest]
      for c, i in cands {
        if c.d > cands[nearest].d + ctx.max_detour {
          break // sorted by distance - nothing further can clear the detour gate
        }
        if i == nearest {
          continue
        }
        // Must clear the gain gate vs the NEAREST pick, and strictly beat the current winner's pack
        // (ties keep the nearer candidate, since we iterate nearest-first). Cheap gates run before the
        // reach/fence skip test so only real contenders pay for it.
        if ctx.density[i] < ctx.density[nearest] + ctx.min_gain || ctx.density[i] <= best_pack {
          continue
        }
        if tc_cand_skip(session, ctx, cands, i, alive) {
          continue
        }
        best = i
        best_pack = ctx.density[i]
      }
      return best, best == nearest ? .Nearest : .Density
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
// BACKGROUND-SAFE + allocator-parametric: tc_scan_worker calls this on a worker thread with a throwaway
// Session snapshot and context.allocator (the worker's temp arena dies with the thread). The proc itself
// - and every helper it calls (prop_gate_ready, species_ai, obj_is_selectable and its read_mover_name /
// read_mob_hp chain) - may therefore only ever read session.proc_info / session.ptr_size /
// session.layout. Reading ANY other Session field here breaks the background scan (the snapshot leaves
// the rest zeroed); extend the snapshot in tc_scan_request if that ever becomes necessary.
tc_collect_cands :: proc(
  session: ^Session,
  names: []string,
  world: uintptr,
  player: uintptr,
  player_pos: [3]f32,
  allocator := context.temp_allocator,
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

  cands := make([dynamic]TC_Cand, allocator)
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

// Decide the cluster-commitment state to carry into the NEXT pick, given what tc_pick_one just
// returned. Pure data transform, shared by ALL cascade callers - the live picker (tc_select), the
// pre-select commit (auto_tick), and the debug simulator (tc_predict_order) - so their commitment
// behaviour can never drift. tc_pick_one itself only READS the committed/origin state. Rules:
//   .Density pick - a deliberate detour to a new pack: re-anchor the commitment there (if it is a
//     real pack), regardless of the previous state.
//   continuing a commitment (.Cluster stage, or ANY in-leash pick while committed - e.g. the melee
//     fast-path grabbing a pack member) - keep the ORIGINAL origin. Re-anchoring on every melee pick
//     would slide the leash along with us so it never binds (endless chain-drift down a spawn line).
//   anything else - fresh ground: commit here if the pick sits in a real pack, else uncommitted.
// <cr> is the pack radius (density_radius(engage)); <pack> is the picked mob's local pack size.
cluster_advance :: proc(
  prev_committed: bool,
  prev_origin: [3]f32,
  stage: TC_Stage,
  picked_pos: [3]f32,
  pack: int,
  cr: f32,
) -> (
  committed: bool,
  origin: [3]f32,
) {
  if stage == .Density {
    if pack >= CLUSTER_MIN_SIZE {
      return true, picked_pos
    }
    return false, {}
  }
  if prev_committed && stage == .Cluster {
    return true, prev_origin
  }
  if prev_committed && engine.dist_horizontal(picked_pos, prev_origin) <= cr * CLUSTER_LEASH_MULT {
    return true, prev_origin
  }
  if pack >= CLUSTER_MIN_SIZE {
    return true, picked_pos
  }
  return false, {}
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
  world, player, player_pos, aok := tc_resolve_anchors(session)
  if !aok {
    return .AnchorFail, 0, 0, 0, 0
  }
  // Collect selectable (alive + rendered) movers matching <names> (or any mover), nearest first.
  cands := tc_collect_cands(session, names, world, player, player_pos)
  return tc_finish_select(session, cands[:], names, world, player_pos, require_fresh, 0)
}

// Resolve the world + player anchors and the live player position - the shared preamble of every pick
// path (tc_select, tc_precompute_next, and auto_tick's background-scan request/consume sites).
tc_resolve_anchors :: proc(session: ^Session) -> (world: uintptr, player: uintptr, player_pos: [3]f32, ok: bool) {
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := session.ptr_size == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  pv, pok := engine.read_value(handle, base + session.layout.player_rva, pt)
  if !wok || !pok {
    return 0, 0, {}, false
  }
  world = uintptr(engine.value_as_u64(pt, wv))
  player = uintptr(engine.value_as_u64(pt, pv))
  ppos, ppok := engine.read_vec3(handle, player + uintptr(session.layout.pos_off))
  if !ppok {
    return 0, 0, {}, false
  }
  return world, player, ppos, true
}

// The pick-and-commit tail of tc_select, parameterized by an already-collected candidate batch so
// auto_tick's reactive advance can run the SAME cascade over a batch enumerated off-thread (see
// tc_scan_worker). <player_pos> must be the anchor the batch was collected/sorted against. <exclude>
// (0 = none) adds one extra obj to a local cooldown copy - the background consume passes the mob a
// precompute batch was computed for, which may have outlived TC_RECENT_NS during a long fight.
tc_finish_select :: proc(
  session: ^Session,
  cands: []TC_Cand,
  names: []string,
  world: uintptr,
  player_pos: [3]f32,
  require_fresh: bool,
  exclude: uintptr,
) -> (
  res: TC_Result,
  obj: uintptr,
  d: f32,
  sel: int,
  total: int,
) {
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
  // Density steering (auto only): precompute per-candidate pack sizes so the cluster/density stages can
  // read them. Skipped entirely when off or for manual picks, so tc pays no O(n^2) cost.
  dens: []int = nil
  if require_fresh && session.layout.density_on {
    dens = compute_densities(cands, density_radius(engage))
  }
  recent := session.tc_recent[:]
  if exclude != 0 {
    local_recent := make([dynamic]TC_Recent, context.temp_allocator)
    append(&local_recent, ..session.tc_recent[:])
    append(&local_recent, TC_Recent{obj = exclude, t = now})
    recent = local_recent[:]
  }
  ctx := Pick_Ctx {
    player_pos    = player_pos,
    live_player   = player_pos, // reactive: the collection anchor IS the live player
    world         = world,
    now           = now,
    name_filtered = len(names) > 0,
    require_fresh = require_fresh,
    gate          = require_fresh && session.reach_gate_on && !session.hunt_on, // reach filter (auto only; hunt commits even to a blocked target - it side-steps in)
    fence_on      = session.fence.active, // geo-fence gate (auto + manual when active; 'fence off' to override)
    avoid_on      = session.auto_avoid_on,
    avoid_dir     = session.auto_avoid_dir,
    last_kill_set = session.last_kill_set,
    last_kill_pos = session.last_kill_pos,
    melee         = melee,
    engage        = engage,
    recent        = recent,
    blocked       = session.auto_blocked[:],
    density       = dens,
    density_on    = session.layout.density_on,
    min_gain      = session.layout.density_min_gain,
    max_detour    = session.layout.density_max_detour,
    cluster_committed  = session.cluster_committed,
    cluster_origin_pos = session.cluster_origin_pos,
  }
  idx, stage := tc_pick_one(session, cands, ctx, nil)
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
    lb_note_commit(session, chosen.obj, len(dens) == len(cands) ? dens[idx] : 0) // leaderboard kill attribution (no-op unless recording)
    // Carry the cluster commitment forward (density feature). Forced off when the toggle is off, so
    // switching density off mid-run cleans the state up immediately.
    if session.layout.density_on {
      pack := len(dens) == len(cands) ? dens[idx] : 0
      session.cluster_committed, session.cluster_origin_pos = cluster_advance(
        session.cluster_committed, session.cluster_origin_pos, stage, chosen.pos, pack, density_radius(engage),
      )
    } else {
      session.cluster_committed = false
      session.cluster_origin_pos = {}
    }
  }
  return .Picked, chosen.obj, chosen.d, sel, total
}

// Pre-select: compute (but do NOT select) the mob auto would advance to AFTER the current target dies, so
// auto_tick can commit it the instant focus clears - removing the ~0.5s post-kill enumeration gap. Reuses
// the live cascade (tc_collect_cands + tc_pick_one) so it never drifts from tc_select. <current_focus> is
// the mob we're still fighting: it's EXCLUDED from the pick (added to a local cooldown copy, since it may
// have outlived TC_RECENT_NS during a long fight).
//
// CRITICAL: every distance/range/reach here is measured from the ANCHOR - the current target's live
// position, i.e. where we'll be STANDING when the kill commits this pick - NOT from the live player
// position. The focus locks before the walk, so at precompute time the player is still at the PREVIOUS
// kill spot; measuring from there made the cached "nearest" mean "nearest to where we came from", a
// systematic backward bias that committed a behind-us mob on every kill - THE pre-1.0 ping-pong bug.
// Anchored this way the precompute picks exactly what the reactive post-kill scan would (mob drift
// aside - tc_precompute_still_valid + the auto_tick anchor-drift re-arm cover that).
//
// Read-only: no focus write, no cooldown mark, no cluster-state write - all happen when auto_tick
// actually commits the pick, which is why <stage>/<pack> are returned (they feed cluster_advance at
// commit time) and <anchor_used> is returned (auto_tick re-arms the cache if the fight drags away from
// it). ok=false when the anchors fail or nothing else is eligible - caller falls back to tc_select.
tc_precompute_next :: proc(
  session: ^Session,
  names: []string,
  current_focus: uintptr,
) -> (
  obj: uintptr,
  pos: [3]f32,
  stage: TC_Stage,
  pack: int,
  anchor_used: [3]f32,
  ok: bool,
) {
  world, player, player_pos, aok := tc_resolve_anchors(session)
  if !aok {
    return 0, {}, .None, 0, {}, false
  }
  anchor, anchor_set := tc_precompute_anchor(session, current_focus, player_pos)
  cands := tc_collect_cands(session, names, world, player, anchor)
  obj, pos, stage, pack, ok = tc_finish_precompute(session, cands[:], names, world, anchor, anchor_set, current_focus, player_pos)
  return obj, pos, stage, pack, anchor, ok
}

// The anchor = where we'll be standing at kill time: the current target's live position, falling back
// to the live last-kill anchor, then the player, if the focus pos can't be read. Both the candidate
// distances and the pocket pass are measured from it. Shared by the sync precompute wrapper and
// auto_tick's background request site so the two measure identically.
tc_precompute_anchor :: proc(session: ^Session, current_focus: uintptr, player_pos: [3]f32) -> (anchor: [3]f32, anchor_set: bool) {
  anchor = player_pos
  anchor_set = session.last_kill_set
  if anchor_set {
    anchor = session.last_kill_pos
  }
  if fpos, fok := engine.read_vec3(session.proc_info.handle, current_focus + uintptr(session.layout.pos_off)); fok {
    anchor = fpos
    anchor_set = true
  }
  return anchor, anchor_set
}

// The cascade tail of tc_precompute_next, parameterized by an already-collected batch so auto_tick can
// run it over a batch enumerated off-thread (see tc_scan_worker). Read-only against session run-state,
// exactly like the wrapper: no focus write, no cooldown mark, no cluster-state write.
tc_finish_precompute :: proc(
  session: ^Session,
  cands: []TC_Cand,
  names: []string,
  world: uintptr,
  anchor: [3]f32,
  anchor_set: bool,
  current_focus: uintptr,
  live_player: [3]f32,
) -> (
  obj: uintptr,
  pos: [3]f32,
  stage: TC_Stage,
  pack: int,
  ok: bool,
) {
  if len(cands) == 0 {
    return 0, {}, .None, 0, false
  }
  now := time.now()._nsec
  melee, engage := pick_ranges(session)
  dens: []int = nil
  if session.layout.density_on {
    dens = compute_densities(cands, density_radius(engage))
  }
  // Exclude the current focus from the pick via a local cooldown copy (never mutate session state here).
  local_recent := make([dynamic]TC_Recent, context.temp_allocator)
  append(&local_recent, ..session.tc_recent[:])
  append(&local_recent, TC_Recent{obj = current_focus, t = now})
  ctx := Pick_Ctx {
    player_pos    = anchor, // pack ranking + reach start from the kill spot, not today's player position
    live_player   = live_player, // ...but in-range priority still gates on where the player ACTUALLY stands
    world         = world,
    now           = now,
    name_filtered = len(names) > 0,
    require_fresh = true,
    gate          = session.reach_gate_on && !session.hunt_on, // hunt commits even to a blocked target (see tc_finish_select)
    fence_on      = session.fence.active,
    avoid_on      = false, // pre-select never runs the one-shot stuck-avoid steer
    last_kill_set = anchor_set,
    last_kill_pos = anchor,
    melee         = melee,
    engage        = engage,
    recent        = local_recent[:],
    blocked       = session.auto_blocked[:],
    density       = dens,
    density_on    = session.layout.density_on,
    min_gain      = session.layout.density_min_gain,
    max_detour    = session.layout.density_max_detour,
    cluster_committed  = session.cluster_committed, // READ only - commit-time cluster_advance mutates it
    cluster_origin_pos = session.cluster_origin_pos,
  }
  idx, st := tc_pick_one(session, cands, ctx, nil)
  if idx < 0 {
    return 0, {}, .None, 0, false
  }
  pk := len(dens) == len(cands) ? dens[idx] : 0
  return cands[idx].obj, cands[idx].pos, st, pk, true
}

// How far a cached pre-select pick may have wandered from where it was when precomputed before the
// whole snapshot is distrusted and the reactive scan runs instead (world units, horizontal).
PRESELECT_DRIFT_MAX :: f32(6.0)

// Re-validate a cached pre-select pick at COMMIT time. The precompute runs once per locked target, at
// the START of a fight, so by the time the current mob dies the cached pick can be seconds stale: it may
// have wandered off / been dragged away, and the reach or fence picture can have changed. focus_set_obj
// already covers alive/HP/model; this covers position drift + reach + fence with a handful of reads (NOT
// a rescan). Returns the pick's LIVE position so the caller anchors its bookkeeping to reality instead
// of the snapshot. ok=false - the caller skips the stale commit and falls back to the reactive tc_select.
tc_precompute_still_valid :: proc(session: ^Session, obj: uintptr, cached_pos: [3]f32) -> (live_pos: [3]f32, ok: bool) {
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := session.ptr_size == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  if !wok {
    return {}, false
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  if world == 0 {
    return {}, false
  }
  player_pos, ppok := read_player_pos(session)
  if !ppok {
    return {}, false
  }
  lp, lok := engine.read_vec3(handle, obj + uintptr(session.layout.pos_off))
  if !lok {
    return {}, false
  }
  if engine.dist_horizontal(lp, cached_pos) > PRESELECT_DRIFT_MAX {
    return {}, false // wandered too far - the precomputed choice may no longer make sense
  }
  if session.reach_gate_on && !session.hunt_on && !cand_reachable(session, world, player_pos, lp) {
    return {}, false // approach is blocked NOW (terrain/object), whatever it looked like at precompute (hunt commits anyway)
  }
  if session.fence.active && !fence_contains(session.fence, lp[0], lp[2]) {
    return {}, false // drifted outside the geo-fence
  }
  if session.fence.active && fence_blocks_path(session.fence, player_pos[0], player_pos[2], lp[0], lp[2]) {
    return {}, false // an avoid(!) zone now sits across the path to it
  }
  return lp, true
}

// ===========================================================================
// Background candidate scan (the kill-tick stutter fix).
//
// tc_collect_cands is the expensive half of every auto pick: a full writable-region walk plus a
// multithreaded value scan of the whole target process. Running it synchronously inside auto_tick
// (watcher thread, under exec_mutex) froze the radar's frame pump for the scan's duration on exactly
// the ticks a kill landed. The job below moves ONLY that enumeration onto a one-shot worker thread
// that runs with NO lock held; the cascade tail (cheap) still runs on the watcher via the tc_finish_*
// procs, so pick semantics are unchanged. The REPL paths (target_closest, tdbg) keep the synchronous
// tc_select - blocking the typing user is fine there.
// ===========================================================================

// Result/state of the background job. All fields are read/written under exec_mutex only.
Scan_Job :: struct {
  active:         bool, // a worker is in flight (one at a time)
  gen:            int, // bumped by every request + invalidate; a publish with a stale gen is discarded
  res_ready:      bool, // res_* hold an unconsumed batch
  res_gen:        int,
  res_for:        uintptr, // focus obj a precompute batch was requested for; 0 = reactive batch
  res_anchor:     [3]f32, // the anchor the batch was collected/sorted against
  res_anchor_set: bool,
  res_cands:      [dynamic]TC_Cand, // context.allocator - the consumer must delete()
}

// Heap-owned request handed to the worker. snap is a throwaway Session value carrying ONLY
// proc_info / ptr_size / layout - everything tc_collect_cands and its helpers are allowed to read
// (see the invariant comment on tc_collect_cands). names are deep clones (the live auto_names can
// be freed/swapped while the worker runs).
Scan_Job_Req :: struct {
  session:    ^Session,
  snap:       Session,
  names:      [dynamic]string,
  world:      uintptr,
  player:     uintptr,
  anchor:     [3]f32,
  anchor_set: bool,
  for_obj:    uintptr,
  gen:        int,
}

// Kick off a background candidate collect. Caller holds exec_mutex (auto_tick). No-op while one is
// already in flight. <anchor> is the position the batch will be measured/sorted from (the live player
// for a reactive advance, the precompute anchor for a pre-select batch); <for_obj> tags a pre-select
// batch with its focus (0 = reactive).
tc_scan_request :: proc(session: ^Session, names: []string, world, player: uintptr, anchor: [3]f32, anchor_set: bool, for_obj: uintptr) {
  if session.scan_job.active {
    return
  }
  session.scan_job.active = true
  session.scan_job.gen += 1
  req := new(Scan_Job_Req)
  req.session = session
  req.snap.proc_info = session.proc_info
  req.snap.ptr_size = session.ptr_size
  req.snap.layout = session.layout
  req.names = make([dynamic]string)
  for n in names {
    append(&req.names, strings.clone(n))
  }
  req.world = world
  req.player = player
  req.anchor = anchor
  req.anchor_set = anchor_set
  req.for_obj = for_obj
  req.gen = session.scan_job.gen
  thread.create_and_start_with_data(req, tc_scan_worker, nil, .Normal, true) // self_cleanup: fire-and-forget
}

// Worker body: the expensive enumeration with NO lock held, then a microsecond publish under
// exec_mutex. A stale generation (auto stopped / target switched / detached mid-scan) is discarded.
tc_scan_worker :: proc(data: rawptr) {
  tracy.SetThreadName("scan_job")
  req := cast(^Scan_Job_Req)data
  defer {
    for n in req.names {
      delete(n)
    }
    delete(req.names)
    free(req)
  }
  cands := tc_collect_cands(&req.snap, req.names[:], req.world, req.player, req.anchor, context.allocator)
  session := req.session
  sync.mutex_lock(&session.exec_mutex)
  defer sync.mutex_unlock(&session.exec_mutex)
  session.scan_job.active = false
  if !session.attached || req.gen != session.scan_job.gen {
    delete(cands) // superseded - throw the batch away
    return
  }
  delete(session.scan_job.res_cands) // drop an unconsumed older batch
  session.scan_job.res_cands = cands
  session.scan_job.res_anchor = req.anchor
  session.scan_job.res_anchor_set = req.anchor_set
  session.scan_job.res_for = req.for_obj
  session.scan_job.res_gen = req.gen
  session.scan_job.res_ready = true
}

// Drop any pending/unconsumed batch and orphan an in-flight worker (its publish will see the gen
// mismatch and discard). Called when the run state the batch was computed against changes wholesale:
// auto stop, target-name switch.
tc_scan_invalidate :: proc(session: ^Session) {
  session.scan_job.gen += 1
  session.scan_job.res_ready = false
  delete(session.scan_job.res_cands)
  session.scan_job.res_cands = nil
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

// Locked-target reach re-watch tuning (see auto_reach_watch). Complements the plateau monitor above:
// it catches "target went unreachable AFTER selection" directly instead of waiting out the plateau.
REACH_RECHECK_NS :: i64(500_000_000) // ~0.5s between reach probes on the locked target
REACH_BLOCKED_DEBOUNCE :: 2 // consecutive blocked probes (~1s) before skipping - forgives transient clips

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

// Cluster-commitment tuning (density feature; see cluster_advance + the cluster stage in tc_pick_one).
// A pick whose local pack size reaches CLUSTER_MIN_SIZE commits auto to that pack; the commitment holds
// until no eligible member remains within the pack radius of the rolling anchor - but never drags
// further than CLUSTER_LEASH_MULT pack radii from where it started (a spawn line would otherwise chain
// the commitment across the whole map). Compiled-in starting values, deliberately not cfg knobs (the
// user-facing surface stays at density on|off + mingain + detour); tune here if live play disagrees.
CLUSTER_MIN_SIZE :: 4
CLUSTER_LEASH_MULT :: f32(3.0)

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

// density                -> show the cluster-steering state
// density on|off         -> master toggle. OFF (default) = the plain nearest-mob cascade,
//                           v0.4.0-identical. ON = auto commits to a mob pack until it's wiped and only
//                           detours to a denser pack past the mingain/detour gate. Persisted.
// density mingain <n>    -> gate 1: extra pack members a farther pack needs to steal the pick (default 3)
// density detour <n>     -> gate 2: max extra walk distance (world units) for that detour (default 20)
// The old numeric weight form (`density 20`) is retired - the two gates replaced the continuous weight.
cli_density :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  usage :: "usage: density [on|off]  |  density mingain <n>  |  density detour <n>  |  density hue [on|off]"
  if len(args) >= 1 {
    switch strings.to_lower(args[0]) {
    case "on":
      session.layout.density_on = true
      session.cluster_committed = false // start fresh; the next pick decides the first commitment
      session.cluster_origin_pos = {}
    case "off":
      session.layout.density_on = false
      session.cluster_committed = false
      session.cluster_origin_pos = {}
    case "mingain":
      if len(args) < 2 {
        fmt.eprintln(usage)
        return
      }
      n, nok := strconv.parse_int(args[1])
      if !nok || n < 0 {
        fmt.eprintln("mingain wants a whole number >= 0 (extra pack members, e.g. 3).")
        return
      }
      session.layout.density_min_gain = n
    case "detour":
      if len(args) < 2 {
        fmt.eprintln(usage)
        return
      }
      v, vok := strconv.parse_f64(args[1])
      if !vok || v < 0 {
        fmt.eprintln("detour wants a distance >= 0 in world units (e.g. 20).")
        return
      }
      session.layout.density_max_detour = f32(v)
    case "hue":
      // Radar display toggle (no picker effect): colour monster dots by local pack size. Handled
      // inline (own save + message + return) so it doesn't also print the cluster-steering status.
      on := !session.layout.density_hue_on
      if len(args) >= 2 {
        switch strings.to_lower(args[1]) {
        case "on":
          on = true
        case "off":
          on = false
        case:
          fmt.eprintln("usage: density hue [on|off]")
          return
        }
      }
      session.layout.density_hue_on = on
      flyff_save_cfg(session.layout, flyff_cfg_path())
      fmt.printfln("radar density-hue: %s - monster dots %s.", on ? "ON" : "OFF", on ? "tinted by local pack size (lone red -> dense green)" : "flat red")
      return
    case:
      if _, isnum := strconv.parse_f64(args[0]); isnum {
        fmt.eprintln("the numeric density weight is retired - use 'density on' plus 'density mingain <n>' / 'density detour <n>'.")
      } else {
        fmt.eprintln(usage)
      }
      return
    }
    flyff_save_cfg(session.layout, flyff_cfg_path())
  }
  if session.layout.density_on {
    fmt.printfln(
      "density steering: ON (mingain=%d detour=%v) - auto sticks to a mob pack until it's wiped; a farther pack steals the pick only with >=%d more members within %v extra walk.",
      session.layout.density_min_gain,
      session.layout.density_max_detour,
      session.layout.density_min_gain,
      session.layout.density_max_detour,
    )
  } else {
    fmt.println("density steering: OFF - auto targets the plain nearest eligible mob (v0.4.0 behaviour).")
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

