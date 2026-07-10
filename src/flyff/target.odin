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
  d:   f32,
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

tc_seen_recently :: proc(session: ^Session, obj: uintptr, now: i64) -> bool {
  for r in session.tc_recent {
    if r.obj == obj && now - r.t < TC_RECENT_NS {
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

// True if <obj> was flagged blocked (unreachable) within the last BLOCKED_NS. Mirrors
// tc_seen_recently but against the auto_blocked list; used by the picker to skip stuck mobs.
obj_blocked_recently :: proc(session: ^Session, obj: uintptr, now: i64) -> bool {
  for r in session.auto_blocked {
    if r.obj == obj && now - r.t < BLOCKED_NS {
      return true
    }
  }
  return false
}

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
// Stays inert (returns true) when the FAST object path (aobjcull_rva) isn't set, so the gate never runs
// the slow full-memory scan inside the pick loop; compute_reach's terrain part self-noops if terrain
// isn't calibrated. Selecting an unreachable mob just makes the character jam - this skips it up front.
cand_reachable :: proc(session: ^Session, world: uintptr, player_pos, cand_pos: [3]f32) -> bool {
  if session.layout.aobjcull_rva == 0 {
    return true
  }
  res := compute_reach(session, world, player_pos[0], player_pos[1], player_pos[2], cand_pos[0], cand_pos[2])
  return res.status == .Clear
}

// Shared candidate-skip test for the auto picker passes: skip a mob if recently targeted,
// stuck-blacklisted, or (when `gate`) proactively unreachable. Manual target_closest passes gate=false
// so it still honours an explicit pick behind cover.
tc_skip_cand :: proc(session: ^Session, world: uintptr, player_pos: [3]f32, c: TC_Cand, now: i64, gate: bool) -> bool {
  if tc_seen_recently(session, c.obj, now) || obj_blocked_recently(session, c.obj, now) {
    return true
  }
  if gate && !cand_reachable(session, world, player_pos, c.pos) {
    return true
  }
  return false
}

// Debug: append everything we know about the object we're about to select to
// tc_targets.log (in the cwd), flushed before the focus write. The GAME crashes on a
// bad selection, not memscan, so memscan survives and the LAST entry in the log is
// whatever we targeted right before the crash. Remove once the crash is understood.
log_target :: proc(session: ^Session, obj: uintptr, world: uintptr, sel, total: int) {
  handle := session.proc_info.handle
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  rdp :: proc(handle: win.HANDLE, addr: uintptr, pt: engine.Value_Type) -> uintptr {
    v, ok := engine.read_value(handle, addr, pt)
    return ok ? uintptr(engine.value_as_u64(pt, v)) : 0
  }
  rdi :: proc(handle: win.HANDLE, addr: uintptr) -> i32 {
    v, ok := engine.read_value(handle, addr, .U32)
    return ok ? i32(u32(engine.value_as_u64(.U32, v))) : -1
  }
  dumprow :: proc(sb: ^strings.Builder, handle: win.HANDLE, addr: uintptr, off: uintptr, n: int) {
    b := make([]byte, n, context.temp_allocator)
    rn, ok := engine.read_into(handle, addr + off, b)
    fmt.sbprintf(sb, "  +0x%04X:", off)
    if ok {
      for i in 0 ..< int(rn) {
        fmt.sbprintf(sb, " %02X", b[i])
      }
    } else {
      fmt.sbprint(sb, " <read failed>")
    }
    fmt.sbprint(sb, "\n")
  }

  name, _ := read_mover_name(session, obj)
  pos, _ := engine.read_vec3(handle, obj + uintptr(session.layout.pos_off))
  mpw := rdp(handle, obj + uintptr(session.layout.field_off), pt)
  prev := rdp(handle, world + uintptr(session.layout.focus_off), pt)

  sb := strings.builder_make(context.temp_allocator)
  fmt.sbprintfln(&sb, "--- target obj=0x%X '%s' #%d/%d (prevFocus=0x%X) ---", obj, name, sel + 1, total, prev)
  fmt.sbprintfln(
    &sb,
    "  type=%d vtable=0x%X mpWorld=0x%X(want 0x%X%s) hp=%d max=%d pos=%.1f,%.1f,%.1f",
    engine.read_obj_type(handle, obj, session.layout.pos_off),
    rdp(handle, obj, pt),
    mpw,
    world,
    mpw == world ? "" : " MISMATCH",
    rdi(handle, obj + uintptr(session.layout.hp_off)),
    rdi(handle, obj + 0x814),
    pos[0],
    pos[1],
    pos[2],
  )
  dumprow(&sb, handle, obj, 0x0, 0x30) // vtable + early pointers
  dumprow(&sb, handle, obj, 0x160, 0x20) // pos/world/type/index/model
  dumprow(&sb, handle, obj, 0x800, 0x20) // maxHP region
  dumprow(&sb, handle, obj, 0x2800, 0x140) // currentHP (+0x281C) + despawn-timer region

  fd, err := os.open("tc_targets.log", os.O_WRONLY | os.O_CREATE | os.O_APPEND)
  if err == os.ERROR_NONE {
    os.write_string(fd, strings.to_string(sb))
    os.close(fd)
  }
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
    append(&cands, TC_Cand{obj = obj, d = engine.dist_3d(pos, player_pos), pos = pos})
  }
  slice.sort_by(cands[:], proc(a, b: TC_Cand) -> bool {return a.d < b.d})
  return cands
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
  focus_addr := world + uintptr(session.layout.focus_off)
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

  // Pick the nearest mob we haven't targeted in the last few seconds. A just-killed mob
  // can keep reading as alive (HP unchanged, model still valid) while it plays its death
  // animation, so picking the strict closest would re-select the corpse. Skipping recent
  // picks advances to the next mob after each kill.
  now := time.now()._nsec
  gate := require_fresh && session.reach_gate_on // proactive reach filter (auto only; inert w/o aobjcull_rva)
  chosen := cands[0]
  sel = 0
  found := false
  // Melee fast-path: a mob in melee range is immediately reachable, so take the nearest such mob and
  // skip the stuck/anchor heuristics. Name-filtered auto ONLY: in any-monster mode a mob of some kind
  // is almost always within melee range, so this would grab whatever's closest and ignore the last-kill
  // anchor, making the pick ping-pong across the field. Any-monster mode instead falls straight to the
  // bow-pocket cascade below (nearest to the last kill, within bow range) - the same thing that makes
  // name-filtered auto feel coherent.
  if require_fresh && len(names) > 0 {
    for c, i in cands {
      if c.d > MELEE_RANGE {
        break // sorted by distance - nothing further is in melee range
      }
      if tc_skip_cand(session, world, player_pos, c, now, gate) {
        continue
      }
      chosen = c
      sel = i
      found = true
      break
    }
  }
  // Right after a stuck-skip (auto only), try the nearest eligible mob on the OPPOSITE side of us from
  // the one we jammed on (dot(player->cand, avoid_dir) < 0), so we walk away from the wall instead of
  // straight back into it. Falls through to the normal nearest pick if there's none.
  if !found && require_fresh && session.auto_avoid_on {
    for c, i in cands {
      if !cand_is_opposite(player_pos, c.pos, session.auto_avoid_dir) {
        continue // cheap direction test first; only reach-check opposite-side candidates
      }
      if tc_skip_cand(session, world, player_pos, c, now, gate) {
        continue
      }
      chosen = c
      sel = i
      found = true
      break
    }
  }
  // Bow-range retarget: if we have a shootable pocket (an eligible mob within BOW_RANGE of us), stay on
  // the pack - pick the in-range mob nearest the last kill's spot rather than the one nearest us. Falls
  // through to plain nearest-to-player when nothing eligible is in range (walk to the next pocket).
  if !found && require_fresh && session.last_kill_set {
    best := -1
    best_ad := f32(1e30)
    for c, i in cands {
      if c.d > BOW_RANGE {
        break // sorted by distance - nothing further is in bow range
      }
      if tc_skip_cand(session, world, player_pos, c, now, gate) {
        continue
      }
      ad := engine.dist_horizontal(c.pos, session.last_kill_pos)
      if ad < best_ad {
        best_ad = ad
        best = i
      }
    }
    if best >= 0 {
      chosen = cands[best]
      sel = best
      found = true
    }
  }
  if !found {
    for c, i in cands {
      if !tc_skip_cand(session, world, player_pos, c, now, gate) {
        chosen = c
        sel = i
        found = true
        break
      }
    }
  }
  if !found {
    if require_fresh {
      return .AllOnCooldown, 0, 0, 0, total // don't re-lock a fresh corpse (auto)
    }
    chosen = cands[0] // manual: fall back to the closest
    sel = 0
  } else if require_fresh {
    session.auto_avoid_on = false // one-shot: consumed by this auto pick
  }
  // Re-validate immediately before the write. The object can be freed/reallocated between
  // enumeration and now; writing a stale pointer whose m_pModel has gone NULL crashes the
  // client. This shrinks the TOCTOU window from ~ms (the sort/pick above) to ~µs.
  if !obj_is_selectable(session, chosen.obj, names) {
    return .WentStale, 0, 0, 0, total
  }
  tc_mark_recent(session, chosen.obj, now)

  when ODIN_DEBUG {
    log_target(session, chosen.obj, world, sel, total)
  }
  if !engine.write_value(handle, focus_addr, pt, engine.ptr_to_value(chosen.obj, session.ptr_size)) {
    fmt.eprintfln("write failed at focus 0x%X (error %d)", focus_addr, win.GetLastError())
    return .WriteFail, chosen.obj, chosen.d, sel, total
  }
  if require_fresh {
    // Remember this mob (obj + where it was) so auto_tick can confirm it actually died before it
    // counts/prints a kill and anchors to it. Cleared/promoted before the next pick (tracks one target).
    session.auto_sel_pos = chosen.pos
    session.auto_sel_obj = chosen.obj
    session.auto_sel_set = true
  }
  // Server sync: also make the client emit its own SendSetTarget so the server registers the
  // same target (stops the after-N-kills DC). Inert unless 'srvsync on' and Phase-0 configured.
  if session.srvsync_on {
    notify_server_target(session, chosen.obj)
  }
  return .Picked, chosen.obj, chosen.d, sel, total
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

AUTO_MIN_INTERVAL_NS :: i64(300_000_000) // ~300ms between advance attempts (caps idle rescans)

// Stuck / obstacle detection tuning (see auto_monitor). While a target is focused we watch the
// player->target distance: no meaningful drop for STUCK_NS while still farther than ARRIVE_DIST
// means the character is jammed against an obstacle -> blacklist the mob and skip. Combat range
// (d <= ARRIVE_DIST) never trips it. PROGRESS_EPS is the min drop that counts as progress.
STUCK_NS :: i64(2_500_000_000) // ~2.5s of no progress while far -> blocked
ARRIVE_DIST :: f32(3.0) // within this of the target = arrived / in melee; never flagged
PROGRESS_EPS :: f32(0.5) // a distance drop >= this counts as making progress

// Ranger bow range. When an eligible mob is within BOW_RANGE of the player, the auto picker ranks by
// nearest-to-the-last-kill-anchor instead of nearest-to-player (stay on the pack); otherwise it walks
// to the nearest mob as usual. See the retarget block in tc_select.
BOW_RANGE :: f32(16.0)

// Melee range: a mob this close is "on top of us" and immediately reachable, so it gets top pick
// priority over every other heuristic. Rough guess - tune to taste. See the top pass in tc_select.
MELEE_RANGE :: f32(3.0)

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

// Human-readable run timer: "45s", "4m12s", "1h04m22s".
fmt_elapsed :: proc(ns: i64) -> string {
  s := ns / 1_000_000_000
  if s < 0 {
    s = 0
  }
  h := s / 3600
  m := (s % 3600) / 60
  sec := s % 60
  if h > 0 {
    return fmt.tprintf("%dh%02dm%02ds", h, m, sec)
  }
  if m > 0 {
    return fmt.tprintf("%dm%02ds", m, sec)
  }
  return fmt.tprintf("%ds", sec)
}

// One-line auto-farm stats since toggle-on: kill counter, run timer, kills/min.
auto_stats :: proc(session: ^Session, now: i64) -> string {
  el := now - session.auto_start
  if el < 0 {
    el = 0
  }
  mins := f64(el) / 60_000_000_000.0
  kpm := mins > 0 ? f64(session.auto_count) / mins : 0
  return fmt.tprintf("kill #%d  %s  %.1f/min", session.auto_count, fmt_elapsed(el), kpm)
}

// Stop condition for the 'kills' command: once the run's confirmed-kill count reaches auto_count_limit,
// turn auto-farm off and self-disarm. Returns true if it fired (so a caller can skip advancing to a
// next mob). No-op (returns false) while disarmed or below the quota. Mirrors the timer stop in auto_tick.
auto_count_reached :: proc(session: ^Session, now: i64) -> bool {
  if session.auto_count_limit == 0 || session.auto_count < session.auto_count_limit {
    return false
  }
  session.auto_on = false
  session.auto_count_limit = 0
  session.auto_paused = false
  session.pause_obj = 0
  fmt.printf("\n[auto] count reached (%d kills) - auto-farm OFF.  %s\n", session.auto_count, auto_stats(session, now))
  fmt.print("memscan> ")
  return true
}

// Progress monitor for the focused mob, called every tick while a live target is selected. Detects
// the character jamming against an obstacle: if the player->target distance stops dropping for
// STUCK_NS while still farther than ARRIVE_DIST, the mob is unreachable -> blacklist it and clear
// focus so the next tick re-acquires a reachable one. Reaching/attacking keeps d <= ARRIVE_DIST so
// combat is never flagged; a kill clears focus through the normal (advance) path instead.
auto_monitor :: proc(session: ^Session, focus: uintptr, now: i64) {
  // New target (or first sighting) -> (re)establish the baseline; judge progress from the next tick.
  if focus != session.auto_focus_obj {
    session.auto_focus_obj = focus
    session.auto_best_dist = 1e30
    session.auto_progress_at = now
    return
  }
  handle := session.proc_info.handle
  ppos, pok := read_player_pos(session)
  tpos, tok := engine.read_vec3(handle, focus + uintptr(session.layout.pos_off))
  if !pok || !tok {
    return // transient read failure; retry next tick
  }
  d := engine.dist_3d(ppos, tpos)
  if d <= ARRIVE_DIST {
    // Arrived / in melee - keep the window fresh so standing in combat never trips the monitor.
    session.auto_best_dist = d
    session.auto_progress_at = now
    return
  }
  if d < session.auto_best_dist - PROGRESS_EPS {
    // Closing in - real progress. Reset the stuck window.
    session.auto_best_dist = d
    session.auto_progress_at = now
    return
  }
  // Plateaued while still far. Once that's persisted for STUCK_NS, treat the mob as unreachable.
  if now - session.auto_progress_at >= STUCK_NS {
    name, _ := read_mover_name(session, focus)
    mark_blocked(session, focus, now)
    // We jammed trying to reach this mob, so the obstacle is roughly in its direction. Hint the next
    // pick to steer to the opposite side of us (see the retarget in tc_select).
    session.auto_avoid_dir = {tpos[0] - ppos[0], tpos[2] - ppos[2]}
    session.auto_avoid_on = true
    // Clear m_pObjFocus so the next tick advances; reset tracking + throttle so it fires promptly.
    base := session.proc_info.base
    pt := engine.Value_Type.U64
    if session.ptr_size == 4 {
      pt = .U32
    }
    if wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt); wok {
      world := uintptr(engine.value_as_u64(pt, wv))
      if world != 0 {
        engine.write_value(handle, world + uintptr(session.layout.focus_off), pt, engine.ptr_to_value(0, session.ptr_size))
      }
    }
    session.auto_focus_obj = 0
    session.auto_last = 0
    fmt.printf("\n[auto] '%s' blocked (d=%.1f) - skipping\n", name, d)
    fmt.print("memscan> ")
  }
}

// Read a mover's current HP (hp_off). ok=false when hp_off isn't configured or the read fails.
read_mob_hp :: proc(session: ^Session, obj: uintptr) -> (hp: i64, ok: bool) {
  if session.layout.hp_off == 0 {
    return 0, false
  }
  if v, rok := engine.read_value(session.proc_info.handle, obj + uintptr(session.layout.hp_off), .U32); rok {
    return i64(u32(engine.value_as_u64(.U32, v))), true
  }
  return 0, false
}

// Called every tick while auto is PAUSED. It doesn't advance/select; it just watches the currently
// targeted mob and resumes auto when that mob is KILLED (HP hits 0, or it despawns/frees). A mere
// deselect (mob still alive) keeps us paused, and with no target it idles - so you resume by targeting
// a mob and killing it (this is also how the armed 'auto' kicks off on the first kill).
pause_tick :: proc(session: ^Session, now: i64) {
  focus, fok := read_focus_ptr(session)
  if fok && focus != 0 && focus_obj_live(session, focus) {
    if hp, hok := read_mob_hp(session, focus); hok && hp <= 0 {
      pause_resume(session, focus, now) // HP hit 0 while focused = kill
      return
    }
    session.pause_obj = focus // alive (or HP unknown) - keep watching this one
    return
  }
  // No live target now. If we were watching one, tell a kill (freed / HP<=0) from a plain deselect.
  if session.pause_obj != 0 {
    watched := session.pause_obj
    session.pause_obj = 0
    killed := !focus_obj_live(session, watched)
    if !killed {
      if hp, hok := read_mob_hp(session, watched); hok && hp <= 0 {
        killed = true
      }
    }
    if killed {
      pause_resume(session, watched, now)
    }
  }
}

// Leave the paused state and let auto resume advancing. Seeds the bow-range anchor from where the mob
// died so the first pick after resuming stays on that spot's pack.
pause_resume :: proc(session: ^Session, killed_obj: uintptr, now: i64) {
  session.auto_paused = false
  session.pause_obj = 0
  session.auto_count += 1 // the kill that resumes us counts too (this is the first kill when armed)
  if pos, ok := engine.read_vec3(session.proc_info.handle, killed_obj + uintptr(session.layout.pos_off)); ok {
    session.last_kill_pos = pos
    session.last_kill_set = true
  }
  session.auto_last = 0 // advance promptly on the next tick
  fmt.printf("\n[auto] resumed (kill).  %s\n", auto_stats(session, now))
  fmt.print("memscan> ")
  auto_count_reached(session, now) // 'kills 1' (or a mid-run re-arm at/below current count): stop right away
}

// Auto-farm tick: called every ~20ms by the watcher thread. When a live target is selected, run the
// obstacle monitor (auto_monitor). When no live target is selected (m_pObjFocus cleared on kill, or
// pointing at a freed object), advance the focus to the next fresh mob matching auto_names. Your held
// attack key then keeps attacking it.
auto_tick :: proc(session: ^Session) {
  if !session.attached {
    return
  }
  now := time.now()._nsec
  // Auto-off timer ('timer' command): when the deadline passes, stop auto-farm. Self-disarms even
  // if auto is already off (silently, so a stale deadline can't kill a later run).
  if session.auto_timer_at != 0 && now >= session.auto_timer_at {
    was_on := session.auto_on
    session.auto_on = false
    session.auto_timer_at = 0
    session.auto_paused = false
    session.pause_obj = 0
    if was_on {
      fmt.printf("\n[auto] timer elapsed - auto-farm OFF.  %s\n", auto_stats(session, now))
      fmt.print("memscan> ")
    }
    return
  }
  if !session.auto_on {
    return
  }
  // Paused (armed): don't advance; just watch the targeted mob and resume auto when it's killed.
  if session.auto_paused {
    pause_tick(session, now)
    return
  }
  // A live target is still selected: watch it for obstacle-stuck (every tick, unthrottled) and wait.
  if focus, fok := read_focus_ptr(session); fok && focus != 0 && focus_obj_live(session, focus) {
    if session.auto_stuck_on {
      auto_monitor(session, focus, now)
    }
    return
  }
  // Focus cleared (kill) or focused obj freed -> advance to the next fresh mob. Throttle only this
  // rescan path (not the monitor above) so idle rescans stay capped.
  if now - session.auto_last < AUTO_MIN_INTERVAL_NS {
    return
  }
  session.auto_focus_obj = 0 // reset progress tracking for the mob we're about to pick
  // The focus cleared. If that was a genuine KILL (not a stuck-skip, which sets auto_avoid_on),
  // count it, anchor the next pick to its spot, and print - a kill is the ONLY thing that prints here.
  // auto_avoid_on is still set at this point (tc_select consumes it just below), so this reads it.
  if session.auto_sel_set {
    // Confirm the selected mob actually died (freed, or HP<=0) rather than being deselected - so a
    // stray Esc/deselect never prints a phantom kill. Stuck-skips (auto_avoid_on) are never kills.
    died := false
    if !session.auto_avoid_on {
      if !focus_obj_live(session, session.auto_sel_obj) {
        died = true
      } else if hp, hok := read_mob_hp(session, session.auto_sel_obj); hok && hp <= 0 {
        died = true
      }
    }
    if died {
      session.auto_count += 1
      session.last_kill_pos = session.auto_sel_pos
      session.last_kill_set = true
      fmt.printf("\n[auto] %s\n", auto_stats(session, now))
      fmt.print("memscan> ")
    }
    session.auto_sel_set = false
    // Hit the kill quota ('kills' command)? Stop before advancing so we don't grab an extra target.
    if died && auto_count_reached(session, now) {
      return
    }
  }
  // Advance to the next mob. Selection itself is silent now - no print unless something died above.
  tc_select(session, session.auto_names[:], true)
  session.auto_last = now
}

// Parse a raw target argument into a list of names. Comma-separated; each name may be wrapped
// in single/double quotes and may contain spaces. Empty input (or only whitespace) yields an
// empty list, meaning "any monster". Allocated in the temp allocator. Examples:
//   ""                                        -> []            (any monster)
//   "Aibatt"                                  -> ["Aibatt"]
//   "Mutant Yetti"                            -> ["Mutant Yetti"]
//   "'Club-tailed Reptillion', 'Captain ...'" -> ["Club-tailed Reptillion", "Captain ..."]
parse_target_names :: proc(raw: string) -> [dynamic]string {
  out := make([dynamic]string, context.temp_allocator)
  for part in strings.split(raw, ",", context.temp_allocator) {
    n := strings.trim_space(part)
    n = strings.trim(n, "'\"") // strip one layer of surrounding quotes
    n = strings.trim_space(n)
    if len(n) > 0 {
      append(&out, n)
    }
  }
  return out
}

// Human-readable description of a target-name list, for status/log lines.
//   []            -> "any monster"
//   ["A"]         -> "'A'"
//   ["A","B"]     -> "'A', 'B'"
auto_target_desc :: proc(names: []string) -> string {
  if len(names) == 0 {
    return "any monster"
  }
  sb := strings.builder_make(context.temp_allocator)
  for n, i in names {
    if i > 0 {
      fmt.sbprint(&sb, ", ")
    }
    fmt.sbprintf(&sb, "'%s'", n)
  }
  return strings.to_string(sb)
}

// Set-equality of two name lists (order-insensitive, case-insensitive). Two empty lists are
// equal (both "any monster"), so re-issuing the same request toggles auto off.
names_equal :: proc(a, b: []string) -> bool {
  if len(a) != len(b) {
    return false
  }
  for x in a {
    if !name_matches(x, b) {
      return false
    }
  }
  return true
}

// Free the cloned auto_names list (each string + the backing array). Idempotent.
auto_free_names :: proc(session: ^Session) {
  for n in session.auto_names {
    delete(n)
  }
  delete(session.auto_names)
  session.auto_names = nil
}

// Replace auto_names with persistent clones of <names> (default allocator, so they survive
// across REPL/watcher calls). Frees the previous list first.
auto_set_names :: proc(session: ^Session, names: []string) {
  auto_free_names(session)
  session.auto_names = make([dynamic]string)
  for n in names {
    append(&session.auto_names, strings.clone(n))
  }
}

// If auto is in any-monster mode (empty name list) but the species prop-table gate isn't configured
// yet, warn that pets / other players / NPCs will also be targeted, and point at the one-time fix.
auto_warn_mobgate :: proc(session: ^Session) {
  if len(session.auto_names) == 0 && !prop_gate_ready(session) {
    fmt.println("  note: any-monster mode will also target pets / players / NPCs until you run 'findprop' once (target your pet, with monsters on screen).")
  }
}

// auto                     -> off: start farming ANY nearby monster;  on: show status
// auto off | auto stop     -> turn auto-farm off
// auto any                 -> explicitly farm any monster (same as bare 'auto' when off)
// auto <name>              -> farm <name> (re-issuing the same request toggles off)
// auto 'A', 'B', ...       -> farm any of the listed names (comma-separated; quote names that
//                             contain spaces). A different request while on switches target.
// Good to bind to a single hotkey (re-issue toggles).
cli_auto :: proc(session: ^Session, args: []string) {
  // Stop.
  if len(args) == 1 && (args[0] == "off" || args[0] == "stop") {
    if session.auto_on {
      session.auto_on = false
      session.auto_timer_at = 0 // stopping the run cancels any pending auto-off timer
      session.auto_count_limit = 0 // ...and any pending kill-count limit
      session.auto_focus_obj = 0
      session.auto_avoid_on = false
      session.auto_sel_set = false
      session.last_kill_set = false
      session.auto_paused = false
      session.pause_obj = 0
      clear(&session.auto_blocked)
      fmt.printfln("auto-farm OFF.  %s", auto_stats(session, time.now()._nsec))
    } else {
      fmt.println("auto-farm already off.")
    }
    return
  }

  // Bare 'auto' while running -> status peek (don't disturb the run). When off it falls through
  // and starts any-monster mode.
  if len(args) == 0 && session.auto_on {
    state := session.auto_paused ? "ARMED/paused" : "ON"
    fmt.printfln("auto-farm %s: %s.  %s", state, auto_target_desc(session.auto_names[:]), auto_stats(session, time.now()._nsec))
    return
  }

  // Resolve the requested targets. No args, or the alias any/anything/*, means "any monster".
  names := parse_target_names(strings.join(args, " ", context.temp_allocator))
  if len(names) == 1 &&
     (strings.equal_fold(names[0], "any") || strings.equal_fold(names[0], "anything") || names[0] == "*") {
    clear(&names)
  }

  // Already running -> the same request toggles off; a different one switches target.
  if session.auto_on {
    if names_equal(names[:], session.auto_names[:]) {
      session.auto_on = false
      session.auto_timer_at = 0 // stopping the run cancels any pending auto-off timer
      session.auto_count_limit = 0 // ...and any pending kill-count limit
      session.auto_focus_obj = 0
      session.auto_avoid_on = false
      session.auto_sel_set = false
      session.last_kill_set = false
      session.auto_paused = false
      session.pause_obj = 0
      clear(&session.auto_blocked)
      fmt.printfln("auto-farm OFF.  %s", auto_stats(session, time.now()._nsec))
      return
    }
    auto_set_names(session, names[:])
    session.auto_last = 0
    fmt.printfln("auto-farm target -> %s.", auto_target_desc(session.auto_names[:]))
    auto_warn_mobgate(session)
    return
  }

  // Start.
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  auto_set_names(session, names[:])
  session.auto_last = 0
  session.auto_count = 0
  session.auto_start = time.now()._nsec
  session.auto_focus_obj = 0 // reset obstacle/stuck tracking for the new run
  session.auto_avoid_on = false
  session.auto_sel_set = false
  session.last_kill_set = false
  clear(&session.auto_blocked)
  // Start ARMED (paused): the first kill kicks off farming (see pause_tick). This avoids auto grabbing
  // a target the instant you type the command - you engage the first mob yourself.
  session.auto_paused = true
  session.pause_obj = 0
  session.auto_on = true
  ensure_hotkey_thread(session)
  fmt.printfln(
    "auto-farm ARMED: %s. target a mob and kill it to start; then it advances on each kill. F10 to pause, 'auto off' to stop.",
    auto_target_desc(session.auto_names[:]),
  )
  auto_warn_mobgate(session)
}

// stuck | stuck on|off -> toggle obstacle/stuck detection (auto_monitor). On by default. Disable for
// ranged/standing playstyles that attack without closing in, where "not getting closer" is normal and
// would otherwise be mis-read as blocked.
cli_stuck :: proc(session: ^Session, args: []string) {
  switch {
  case len(args) == 0:
    session.auto_stuck_on = !session.auto_stuck_on
  case len(args) == 1 && args[0] == "on":
    session.auto_stuck_on = true
  case len(args) == 1 && args[0] == "off":
    session.auto_stuck_on = false
  case:
    fmt.eprintln("usage: stuck [on|off]")
    return
  }
  fmt.printfln("stuck-detection %s.", session.auto_stuck_on ? "ON" : "OFF")
}

// reachgate | reachgate on|off -> toggle the PROACTIVE reach filter for auto: skip candidate mobs whose
// straight approach is blocked by terrain or a placed-object OBB, before selecting (the reactive
// stuck-monitor still catches the rest). On by default, but inert until 'findcull' sets aobjcull_rva (so
// it can't accidentally starve target selection or fall back to the slow scan in the pick loop).
cli_reachgate :: proc(session: ^Session, args: []string) {
  switch {
  case len(args) == 0:
    session.reach_gate_on = !session.reach_gate_on
  case len(args) == 1 && args[0] == "on":
    session.reach_gate_on = true
  case len(args) == 1 && args[0] == "off":
    session.reach_gate_on = false
  case:
    fmt.eprintln("usage: reachgate [on|off]")
    return
  }
  inert := session.layout.aobjcull_rva == 0
  hint := (session.reach_gate_on && inert) ? "  (inert: run 'findcull' once in-game to enable it)" : ""
  fmt.printfln("reach-gate %s.%s", session.reach_gate_on ? "ON" : "OFF", hint)
}

// pause -> toggle the auto-farm pause (default key: F10). Paused = auto stays on but stops advancing;
// killing the targeted mob resumes it. Does nothing if auto is off (won't start it).
cli_pause :: proc(session: ^Session, args: []string) {
  if !session.auto_on {
    fmt.println("auto is off - nothing to pause. start it with 'auto <name>'.")
    return
  }
  if session.auto_paused {
    session.auto_paused = false
    session.pause_obj = 0
    session.auto_last = 0 // advance promptly now that we've resumed
    fmt.println("auto-farm RESUMED.")
  } else {
    session.auto_paused = true
    session.pause_obj = 0
    fmt.println("auto-farm PAUSED - kill the targeted mob (or 'pause' again) to resume.")
  }
}

// timer <minutes> -> auto-disable 'auto' after <minutes> elapse (e.g. 'timer 60'): a safety stop
//                    for an unattended farm session. Absolute deadline from when you run it. If auto
//                    is already off when it elapses it just does nothing.
// timer           -> show the time remaining.
// timer off | 0   -> cancel the pending timer.
cli_timer :: proc(session: ^Session, args: []string) {
  now := time.now()._nsec

  if len(args) == 0 {
    if session.auto_timer_at == 0 {
      fmt.println("no auto-off timer armed.  usage: timer <minutes>   (e.g. 'timer 60')")
      return
    }
    rem := session.auto_timer_at - now
    if rem < 0 {
      rem = 0
    }
    fmt.printfln("auto-off timer: %s remaining%s.", fmt_elapsed(rem), session.auto_on ? "" : "  (auto is off)")
    return
  }

  if args[0] == "off" || args[0] == "stop" || args[0] == "cancel" {
    session.auto_timer_at = 0
    fmt.println("auto-off timer cancelled.")
    return
  }

  mins, ok := strconv.parse_f64(args[0])
  if !ok || mins < 0 {
    fmt.eprintln("usage: timer <minutes>   (e.g. 'timer 60'; 'timer off' to cancel)")
    return
  }
  if mins == 0 {
    session.auto_timer_at = 0
    fmt.println("auto-off timer cancelled.")
    return
  }
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }

  session.auto_timer_at = now + i64(mins * 60_000_000_000.0)
  ensure_hotkey_thread(session) // keep the watcher alive so the deadline is serviced
  note := session.auto_on ? "" : "  (auto is off now - it will only stop a run that's in progress then.)"
  fmt.printfln("auto-off timer armed: auto-farm OFF in %s.%s", fmt_elapsed(session.auto_timer_at - now), note)
}

// kills <n>  -> auto-disable 'auto' after <n> confirmed kills in the current run (e.g. 'kills 100'):
//               a quota stop for an unattended session. The count is the run total since 'auto'
//               started (auto resets it to 0), so 'auto <name>' then 'kills 100' stops after 100.
//               If auto is off when the quota is hit it just does nothing.
// kills      -> show progress (kills so far / target).
// kills off | 0 -> cancel the pending kill quota.
cli_kills :: proc(session: ^Session, args: []string) {
  if len(args) == 0 {
    if session.auto_count_limit == 0 {
      fmt.println("no kill quota armed.  usage: kills <n>   (e.g. 'kills 100')")
      return
    }
    fmt.printfln("kill quota: %d / %d%s.", session.auto_count, session.auto_count_limit, session.auto_on ? "" : "  (auto is off)")
    return
  }

  if args[0] == "off" || args[0] == "stop" || args[0] == "cancel" {
    session.auto_count_limit = 0
    fmt.println("kill quota cancelled.")
    return
  }

  n, ok := strconv.parse_int(args[0])
  if !ok || n < 0 {
    fmt.eprintln("usage: kills <n>   (e.g. 'kills 100'; 'kills off' to cancel)")
    return
  }
  if n == 0 {
    session.auto_count_limit = 0
    fmt.println("kill quota cancelled.")
    return
  }
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }

  session.auto_count_limit = n
  ensure_hotkey_thread(session) // keep the watcher alive so the quota is serviced
  // Arming at or below the current run count -> the quota is already met; stop now.
  if session.auto_on && auto_count_reached(session, time.now()._nsec) {
    return
  }
  note := session.auto_on ? "" : "  (auto is off now - it will only stop a run that's in progress then.)"
  remaining := n - session.auto_count
  fmt.printfln("kill quota armed: auto-farm OFF after %d more kill(s) (target %d).%s", remaining, n, note)
}

REFOCUS_INTERVAL_NS :: i64(200_000_000) // ~200ms between consistent write-backs

// Detection experiment: every ~200ms, read m_pObjFocus and write the SAME bytes back. This
// generates external WriteProcessMemory traffic to the focus field whose value always equals
// what the client itself set (via your clicks) - focus == the client's input "shadow". If the
// anti-cheat disconnects under this, it detects the raw cross-process write; if it does NOT,
// the ~5-min DC is the focus-vs-input mismatch and only *inconsistent* writes are the tell.
refocus_tick :: proc(session: ^Session) {
  if !session.refocus_on || !session.attached {
    return
  }
  now := time.now()._nsec
  if now - session.refocus_last < REFOCUS_INTERVAL_NS {
    return
  }
  session.refocus_last = now
  handle := session.proc_info.handle
  base := session.proc_info.base
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  if !wok {
    return
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  if world == 0 {
    return
  }
  focus_addr := world + uintptr(session.layout.focus_off)
  fv, fok := engine.read_value(handle, focus_addr, pt)
  if !fok {
    return
  }
  engine.write_value(handle, focus_addr, pt, fv) // write the exact same bytes back (no value change)
}

// refocus | refocus off  -> toggle the consistent-write experiment (see refocus_tick).
cli_refocus :: proc(session: ^Session, args: []string) {
  if session.refocus_on || (len(args) == 1 && (args[0] == "off" || args[0] == "stop")) {
    session.refocus_on = false
    fmt.println("refocus OFF.")
    return
  }
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  session.auto_on = false // mutually exclusive experiment
  session.refocus_last = 0
  session.refocus_on = true
  ensure_hotkey_thread(session)
  fmt.println(
    "refocus ON: writing the current focus value back every ~200ms. Play normally (click your own targets) and see if you still DC at ~5 min. 'refocus off' to stop.",
  )
}

// Read-only code recon (net-package-targeting.md Phase 0). Two forms:
//   codescan <u32>        find a 4-byte immediate in executable pages (e.g. 0xff0023, the
//                         SETTARGET packet id embedded in SendSetTarget)
//   codescan call <addr>  find direct CALL sites targeting <addr> (to read the preceding
//                         `mov ecx, imm32` = &g_DPlay)
// Each hit prints as absolute + Neuz.exe+RVA with a 20-byte window from 4 bytes before the
// hit, so the opcode / prologue / `mov ecx` is visible.
