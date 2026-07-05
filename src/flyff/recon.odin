package flyff

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:strconv"
import win "core:sys/windows"
import "../engine"

cli_idscan :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: idscan <name>")
    return
  }
  name := strings.trim(strings.join(args, " ", context.temp_allocator), "'\"")
  LEN :: 0x4200

  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  if !wok {
    fmt.eprintln("could not read world anchor.")
    return
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  wval := engine.ptr_to_value(world, session.ptr_size)
  all := engine.collect_regions(handle, true)
  defer delete(all)
  set := engine.scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)

  bufs := make([dynamic][]byte, context.temp_allocator)
  objs := make([dynamic]uintptr, context.temp_allocator)
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
    nm, nok := engine.read_obj_name(handle, session.ptr_size, obj, session.layout.name_off)
    if !nok || !strings.contains(nm, name) {
      continue
    }
    b := make([]byte, LEN, context.temp_allocator)
    engine.read_into(handle, obj, b)
    append(&bufs, b)
    append(&objs, obj)
  }
  n := len(bufs)
  fmt.printfln("idscan '%s': %d movers; distinct in-range 4-byte fields:", name, n)
  if n < 2 {
    fmt.println("need >=2 movers named that; get more on screen and retry.")
    return
  }

  u32at :: proc(b: []byte, off: int) -> u32 {
    return u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24
  }

  // Re-read the SAME objects after a pause. m_objid is unique per mob AND never changes, so it is
  // both UNIQUE and STABLE; positions vary (mobs move) and drop out. We also test each value as a
  // pointer: real pointer fields (m_pModel etc.) resolve into committed memory, a plain objid does
  // not, so the ptr fraction separates objid from pointer fields regardless of its magnitude.
  fmt.println("sampling ~2.5s (let the mobs move / fight a little)...")
  win.Sleep(2500)
  bufs2 := make([][]byte, n, context.temp_allocator)
  dead := make([]bool, n, context.temp_allocator)
  for obj, i in objs {
    b := make([]byte, LEN, context.temp_allocator)
    engine.read_into(handle, obj, b)
    bufs2[i] = b
    vt, vok := engine.read_value(handle, obj, pt)
    if !vok || !in_module_range(uintptr(engine.value_as_u64(pt, vt)), base, mod_end) {
      dead[i] = true // freed/despawned during the window
    }
  }
  regions := engine.collect_regions(handle, false)
  defer delete(regions)
  slice.sort_by(regions[:], proc(a, b: engine.Region) -> bool {return a.base < b.base})

  shown := 0
  off := 0
  for off <= LEN - 4 {
    uniq := 0
    for i in 0 ..< n {
      v := u32at(bufs[i], off)
      if v == 0 {
        continue
      }
      dup := false
      for j in 0 ..< i {
        if u32at(bufs[j], off) == v {
          dup = true
          break
        }
      }
      if !dup {
        uniq += 1
      }
    }
    if uniq * 10 >= n * 8 {
      alive, stable, ptrs := 0, 0, 0
      for i in 0 ..< n {
        if dead[i] {
          continue
        }
        alive += 1
        if u32at(bufs[i], off) == u32at(bufs2[i], off) {
          stable += 1
        }
        if engine.region_contains(regions[:], uintptr(u32at(bufs[i], off))) {
          ptrs += 1
        }
      }
      if alive > 0 && stable * 10 >= alive * 9 && ptrs * 10 <= alive * 3 && shown < 24 {
        sb := strings.builder_make(context.temp_allocator)
        fmt.sbprintf(&sb, "  +0x%X uniq=%d ptr=%d/%d :", off, uniq, ptrs, alive)
        for i in 0 ..< min(n, 8) {
          fmt.sbprintf(&sb, " %d", u32at(bufs[i], off))
        }
        fmt.println(strings.to_string(sb))
        shown += 1
      }
    }
    off += 4
  }
  if shown == 0 {
    fmt.println("  (no unique+stable field found; objid may be past +0x1000 - tell me and I'll widen it)")
  } else {
    fmt.println("(m_objid = unique + stable + LOW ptr. pointer fields show ptr ~= alive; objid ~0.)")
  }
}

// A pet<->player link candidate: a 4-byte field at +off that references you, either as your
// player objid (id=true) or as a pointer to your player object (id=false).
Owner_Cand :: struct {
  off: int,
  id:  bool,
}

// findowner <pet-name> -> find how the client links your pet/mount to you, so auto's no-name /
// any-monster mode can skip your own summons. Summon the pet, run this with its exact name (keep a
// few wild monsters on screen for the cross-check). It searches the pet for a field that references
// YOU - either your objid (m_idOwner) or a pointer to your player object (m_pMaster) - keeps the one
// that is 0 on wild monsters, and auto-sets owner_off. The runtime exclusion compares that field
// against BOTH your objid and your player pointer, so either link works. If the pet holds no
// back-reference within the window, it instead reports any forward link in the PLAYER object
// (m_idPet / m_pPet) for diagnosis. Read-only except the cfg write.
cli_findowner :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: findowner <pet-name>   (summon your pet/mount first)")
    return
  }
  L := session.layout
  name := strings.trim(strings.join(args, " ", context.temp_allocator), "'\"")
  LEN :: 0x8000

  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64

  wv, wok := engine.read_value(handle, base + L.world_rva, pt)
  pv, pok := engine.read_value(handle, base + L.player_rva, pt)
  if !wok || !pok {
    fmt.eprintln("could not read world/player anchors - run calibrate first.")
    return
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  player := uintptr(engine.value_as_u64(pt, pv))
  pptr := u32(player) // your player object as a 32-bit pointer (m_pMaster would hold this)

  // Your objid (for the id-link search). Not fatal if objid_off is unset - we can still match the
  // pointer link; id matching is just disabled.
  player_objid: u32 = 0
  if L.objid_off != 0 {
    if oiv, oiok := engine.read_value(handle, player + uintptr(L.objid_off), .U32); oiok {
      player_objid = u32(engine.value_as_u64(.U32, oiv))
    }
  }

  // Enumerate movers: your pet(s) (name matches, keep buffer + address) + a monster sample.
  wval := engine.ptr_to_value(world, ps)
  all := engine.collect_regions(handle, true)
  defer delete(all)
  set := engine.scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)
  pets := make([dynamic][]byte, context.temp_allocator)
  pet_addrs := make([dynamic]uintptr, context.temp_allocator)
  mobs := make([dynamic][]byte, context.temp_allocator)
  for m in set.matches {
    obj := uintptr(i64(m.addr) - L.field_off)
    vt, vok := engine.read_value(handle, obj, pt)
    if !vok || !in_module_range(uintptr(engine.value_as_u64(pt, vt)), base, mod_end) {
      continue
    }
    if engine.read_obj_type(handle, obj, L.pos_off) != L.mover_type || obj == player {
      continue
    }
    nm, nok := engine.read_obj_name(handle, ps, obj, L.name_off)
    if !nok {
      continue
    }
    b := make([]byte, LEN, context.temp_allocator)
    engine.read_into(handle, obj, b)
    if strings.equal_fold(nm, name) {
      append(&pets, b)
      append(&pet_addrs, obj)
    } else if len(mobs) < 80 {
      append(&mobs, b)
    }
  }
  fmt.printfln(
    "findowner '%s': player=0x%X objid=%d (0x%X); %d matching mover(s), %d monsters sampled.",
    name,
    player,
    player_objid,
    player_objid,
    len(pets),
    len(mobs),
  )
  if len(pets) == 0 {
    fmt.println("no mover with that exact name. Summon the pet, verify the name (exact, case-insensitive), and retry.")
    return
  }

  // Primary + reliable: exclude by the pet's mover-prop species id (m_dwIndex at pos_off+0x14). It's
  // stable across re-summons (unlike the objid) and distinct from monster species ids. This alone
  // makes any-monster mode skip the pet; the objid links below are attempted only for extra precision.
  pet_index := rd_u32le(pets[0], int(L.pos_off) + 0x14)
  if pet_index != 0 {
    session.layout.pet_index = pet_index
    fmt.printfln("pet_index = %d - '%s' species id (m_dwIndex); any-monster mode will now skip it.", pet_index, name)
    if flyff_save_cfg(session.layout, flyff_cfg_path()) {
      fmt.println("saved to flyff.cfg.")
    }
  } else {
    fmt.println("WARNING: read the pet's m_dwIndex as 0 (unexpected) - falling back to the objid links below.")
  }

  // --- Direction 1: pet -> you. Offsets where EVERY pet holds your objid (id) or your pointer. ---
  raw := make([dynamic]Owner_Cand, context.temp_allocator)
  off := 0
  for off + 4 <= LEN {
    all_id := player_objid != 0
    all_ptr := true
    for b in pets {
      v := rd_u32le(b, off)
      if v != player_objid {
        all_id = false
      }
      if v != pptr {
        all_ptr = false
      }
    }
    if all_id {
      append(&raw, Owner_Cand{off, true})
    } else if all_ptr {
      append(&raw, Owner_Cand{off, false})
    }
    off += 4
  }
  if len(raw) > 0 {
    // Prefer candidates that are 0 on all sampled monsters (m_pMaster/m_idOwner is NULL/0 on wild
    // mobs), which rejects a coincidental shared value.
    best := make([dynamic]Owner_Cand, context.temp_allocator)
    for c in raw {
      zero := true
      for b in mobs {
        if rd_u32le(b, c.off) != 0 {
          zero = false
          break
        }
      }
      if zero {
        append(&best, c)
      }
    }
    pick := best
    tag := " (0 on all sampled monsters)"
    if len(best) == 0 {
      pick = raw
      tag = ""
    }
    fmt.printfln("pet -> you back-reference candidate(s)%s:", tag)
    for c in pick {
      fmt.printfln("  +0x%X  (%s)", c.off, c.id ? "your objid" : "pointer to you")
    }
    if len(pick) == 1 {
      session.layout.owner_off = i64(pick[0].off)
      fmt.printfln("owner_off = 0x%X (auto-set; matches your %s).", pick[0].off, pick[0].id ? "objid" : "player pointer")
      if flyff_save_cfg(session.layout, flyff_cfg_path()) {
        fmt.println("saved to flyff.cfg. 'auto' (no-name / any-monster) will now skip your pet.")
      }
    } else {
      fmt.println("multiple candidates - the owner/master field is the stable one. 'set owner_off 0x..' then verify 'auto' skips the pet.")
    }
    return
  }

  // --- Direction 2: you -> pet (diagnostic). Does the PLAYER object reference the pet? ---
  pbuf := make([]byte, LEN, context.temp_allocator)
  engine.read_into(handle, player, pbuf)
  pet_obj := pet_addrs[0]
  petptr := u32(pet_obj)
  pet_objid: u32 = 0
  if L.objid_off != 0 {
    if piv, piok := engine.read_value(handle, pet_obj + uintptr(L.objid_off), .U32); piok {
      pet_objid = u32(engine.value_as_u64(.U32, piv))
    }
  }
  fwd := make([dynamic]Owner_Cand, context.temp_allocator)
  off = 0
  for off + 4 <= LEN {
    v := rd_u32le(pbuf, off)
    if pet_objid != 0 && v == pet_objid {
      append(&fwd, Owner_Cand{off, true})
    } else if v == petptr {
      append(&fwd, Owner_Cand{off, false})
    }
    off += 4
  }
  fmt.printfln("no pet->you reference within +0x%X. pet=0x%X pet_objid=%d.", LEN, pet_obj, pet_objid)
  if len(fwd) > 0 {
    fmt.println("the PLAYER object references the pet at:")
    for c in fwd {
      fmt.printfln("  +0x%X  (%s)", c.off, c.id ? "pet objid" : "pointer to pet")
    }
    // An objid slot (m_idPet) is the one we can wire: at runtime we read [player+pet_id_off] and
    // skip the mover whose m_objid matches. A single such slot -> auto-set. (A pointer-to-pet slot
    // would go stale if the pet object reallocates, so we don't auto-wire that.)
    id_slots := make([dynamic]int, context.temp_allocator)
    for c in fwd {
      if c.id {
        append(&id_slots, c.off)
      }
    }
    if len(id_slots) == 1 {
      session.layout.pet_id_off = i64(id_slots[0])
      fmt.printfln("pet_id_off = 0x%X (auto-set; your player object holds the pet's objid here).", id_slots[0])
      if flyff_save_cfg(session.layout, flyff_cfg_path()) {
        fmt.println("saved to flyff.cfg. 'auto' (no-name / any-monster) will now skip your pet.")
      }
    } else if len(id_slots) > 1 {
      fmt.println("multiple pet-objid slots - pick the stable one with 'set pet_id_off 0x..', then verify 'auto' skips the pet.")
    } else {
      fmt.println("only a pointer-to-pet slot found (goes stale on re-summon); paste this and I'll wire it specially.")
    }
  } else {
    fmt.println("no extra objid link found either way - that's fine, pet_index (species id) above already excludes the pet.")
  }
}

// findmobflag <pet-name> -> find a MONSTER-category field so any-monster auto skips ALL pets/players/
// NPCs, not just your own pet. Summon your pet and stand where 2+ monster SPECIES are visible, then
// run this: it diffs your pet against the monster sample and reports offsets where the monsters agree
// on one value ACROSS >=2 species (so it's a category field, not a species id) while your pet differs.
// The right one is a mob-kind/belligerence flag. Wire it with 'set mob_flag_off 0x.. ; set mob_flag_val ..'
// (any-monster mode then requires [mover+mob_flag_off]==mob_flag_val). Read-only. Verify captains still
// share the value before trusting it. Needs a multi-species sample - single-species spots can't tell a
// category flag from a species id.
cli_findmobflag :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: findmobflag <pet-name>   (summon pet; stand where 2+ monster species are visible)")
    return
  }
  name := strings.trim(strings.join(args, " ", context.temp_allocator), "'\"")
  LEN :: 0x8000

  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  L := session.layout

  wv, wok := engine.read_value(handle, base + L.world_rva, pt)
  pv, pok := engine.read_value(handle, base + L.player_rva, pt)
  if !wok || !pok {
    fmt.eprintln("could not read world/player anchors - run calibrate first.")
    return
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  player := uintptr(engine.value_as_u64(pt, pv))
  idx_off := int(L.pos_off) + 0x14 // m_dwIndex (species id)

  wval := engine.ptr_to_value(world, ps)
  all := engine.collect_regions(handle, true)
  defer delete(all)
  set := engine.scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)
  pets := make([dynamic][]byte, context.temp_allocator)
  mobs := make([dynamic][]byte, context.temp_allocator)
  mob_sp := make([dynamic]u32, context.temp_allocator) // each monster's species id (m_dwIndex)
  for m in set.matches {
    obj := uintptr(i64(m.addr) - L.field_off)
    if obj == player {
      continue
    }
    vt, vok := engine.read_value(handle, obj, pt)
    if !vok || !in_module_range(uintptr(engine.value_as_u64(pt, vt)), base, mod_end) {
      continue
    }
    if engine.read_obj_type(handle, obj, L.pos_off) != L.mover_type {
      continue
    }
    nm, nok := engine.read_obj_name(handle, ps, obj, L.name_off)
    if !nok {
      continue
    }
    b := make([]byte, LEN, context.temp_allocator)
    engine.read_into(handle, obj, b)
    if strings.equal_fold(nm, name) {
      append(&pets, b)
    } else if len(mobs) < 80 {
      append(&mobs, b)
      append(&mob_sp, rd_u32le(b, idx_off))
    }
  }
  n := len(mobs)
  // count distinct species in the whole sample (sanity)
  species := make([dynamic]u32, context.temp_allocator)
  for s in mob_sp {
    dup := false
    for x in species {
      if x == s {
        dup = true
        break
      }
    }
    if !dup {
      append(&species, s)
    }
  }
  fmt.printfln("findmobflag '%s': %d pet(s), %d other movers (%d distinct species) sampled.", name, len(pets), n, len(species))
  if len(pets) == 0 {
    fmt.println("no mover with that exact name - summon the pet and retry.")
    return
  }
  if n < 6 || len(species) < 2 {
    fmt.println("need >=6 other movers spanning >=2 monster species on screen (else a species id looks like a category flag). Move to a busier/mixed spot and retry.")
    return
  }

  Cand :: struct {
    off:   int,
    mval:  u32, // value the monsters share
    pval:  u32, // your pet's value at this offset
    cnt:   int, // monsters holding mval
    sp:    int, // distinct species holding mval
  }
  cands := make([dynamic]Cand, context.temp_allocator)
  off := 0
  for off + 4 <= LEN {
    // modal value among monsters at this offset
    bestv: u32 = 0
    bestc := 0
    for i in 0 ..< n {
      v := rd_u32le(mobs[i], off)
      c := 0
      for j in 0 ..< n {
        if rd_u32le(mobs[j], off) == v {
          c += 1
        }
      }
      if c > bestc {
        bestc = c
        bestv = v
      }
    }
    // strong agreement + pet differs -> maybe a category field
    if bestc * 100 >= n * 85 && rd_u32le(pets[0], off) != bestv {
      // distinct species among monsters holding bestv (>=2 => category-level, not a species id)
      seen := make([dynamic]u32, context.temp_allocator)
      for i in 0 ..< n {
        if rd_u32le(mobs[i], off) == bestv {
          s := mob_sp[i]
          dup := false
          for x in seen {
            if x == s {
              dup = true
              break
            }
          }
          if !dup {
            append(&seen, s)
          }
        }
      }
      if len(seen) >= 2 {
        append(&cands, Cand{off, bestv, rd_u32le(pets[0], off), bestc, len(seen)})
      }
    }
    off += 4
  }
  slice.sort_by(cands[:], proc(a, b: Cand) -> bool {
    if a.sp != b.sp {
      return a.sp > b.sp
    }
    return a.cnt > b.cnt
  })
  fmt.printfln("%d monster-category candidate(s) (monsters agree across >=2 species, pet differs):", len(cands))
  if len(cands) == 0 {
    fmt.println("none found. Either the sample wasn't varied enough, or the pet/monster split isn't a simple 4-byte field in +0x8000. Paste a monster 'dump' + pet 'dump' and I'll look by hand.")
    return
  }
  shown := 0
  for c in cands {
    if shown >= 24 {
      fmt.printfln("  ... (%d more)", len(cands) - shown)
      break
    }
    fmt.printfln(
      "  +0x%X  monster=0x%X (%d/%d, %d species)  pet=0x%X   -> set mob_flag_off 0x%X ; set mob_flag_val 0x%X",
      c.off,
      c.mval,
      c.cnt,
      n,
      c.sp,
      c.pval,
      c.off,
      c.mval,
    )
    shown += 1
  }
  fmt.println("pick one whose monster value ALSO holds for captains/bosses (check a 'dump' of one), then set the two fields; any-monster auto will then skip everything that isn't that.")
}

// One SendSetTarget call-target candidate (see rank_settarget_cands).
Settarget_Cand :: struct {
  target:  uintptr, // absolute call target; rva = target - base
  disp:    i64, // objid_off (displacement in `push [reg+disp]`)
  set_cnt: int, // push-2 (set) call sites
  clr_cnt: int, // push-1 (clear) call sites
  ret8:    bool, // target ends in `ret 8` (stdcall, 2 args) - matches SendSetTarget
}

settarget_score :: proc(c: Settarget_Cand) -> int {
  return c.set_cnt * 4 + (c.clr_cnt > 0 ? 3 : 0) + (c.ret8 ? 2 : 0)
}

// Scan exec pages for the click-path `push 2; push [reg+objid_off]; call SendSetTarget` signature
// and return the call-target candidates, best-first (see net-package-targeting.md). Both srvsync
// fields fall out of one match: the call target is SendSetTarget, the disp is objid_off. Shared by
// `findsettarget` and `calibrate`. 32-bit only (returns empty otherwise). Read-only.
rank_settarget_cands :: proc(session: ^Session) -> [dynamic]Settarget_Cand {
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  cands := make([dynamic]Settarget_Cand, context.temp_allocator)
  if session.ptr_size != 4 {
    return cands
  }
  hits := engine.scan_settarget_sig(handle, context.temp_allocator)
  for h in hits {
    if h.target < base || h.target >= mod_end {
      continue // call target outside the module - not our function
    }
    if h.disp < 0x40 || h.disp > 0x8000 || (h.disp & 3) != 0 {
      continue // implausible object-field offset
    }
    idx := -1
    for c, k in cands {
      if c.target == h.target {
        idx = k
        break
      }
    }
    if idx < 0 {
      append(&cands, Settarget_Cand{target = h.target, disp = h.disp})
      idx = len(cands) - 1
    }
    if h.bclear == 2 {
      cands[idx].set_cnt += 1
      cands[idx].disp = h.disp // the set-target call carries the authoritative idTarget offset
    } else {
      cands[idx].clr_cnt += 1
      if cands[idx].disp == 0 {
        cands[idx].disp = h.disp
      }
    }
  }
  // Validate each target looks like SendSetTarget: a `ret 8` followed by int3 padding within the
  // function body (same function-end heuristic as `func`).
  for &c in cands {
    fnbuf := make([]byte, 0x800, context.temp_allocator)
    fn_n, _ := engine.read_into(handle, c.target, fnbuf)
    m := 0
    for m + 4 <= int(fn_n) {
      if fnbuf[m] == 0xC2 && fnbuf[m + 1] == 0x08 && fnbuf[m + 2] == 0x00 && fnbuf[m + 3] == 0xCC {
        c.ret8 = true
        break
      }
      m += 1
    }
  }
  slice.sort_by(cands[:], proc(a, b: Settarget_Cand) -> bool {return settarget_score(a) > settarget_score(b)})
  return cands
}

// True if the best candidate is a confident single winner: called by the set path (push 2), a
// `ret 8` stdcall, and strictly ahead of the runner-up. calibrate/findsettarget only auto-apply
// when this holds (matches the validated real-data case: set x1, clear x1, ret 8).
settarget_confident :: proc(cands: []Settarget_Cand) -> bool {
  if len(cands) == 0 {
    return false
  }
  if cands[0].set_cnt < 1 || !cands[0].ret8 {
    return false
  }
  if len(cands) >= 2 && settarget_score(cands[1]) >= settarget_score(cands[0]) {
    return false // tie at the top - not confident
  }
  return true
}

// findsettarget -> auto-derive the two srvsync fields (sendsettarget_rva + objid_off) by signature,
// instead of the manual codescan/disasm hunt after a patch. Ranks candidates (rank_settarget_cands)
// and, on a confident single winner, applies + saves flyff.cfg; otherwise prints the 'set' lines.
// `calibrate` runs the same derivation, so normally you don't need this separately.
cli_findsettarget :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if session.ptr_size != 4 {
    fmt.eprintln("SendSetTarget lives in the 32-bit Flyff client; attach the WOW64 Neuz.exe.")
    return
  }
  base := session.proc_info.base
  cands := rank_settarget_cands(session)
  if len(cands) == 0 {
    fmt.eprintln(
      "no SendSetTarget-shaped call found (push 2; push [reg+disp]; call). The click path may be inlined/changed - fall back to the manual disasm route.",
    )
    fmt.eprintfln("  try: codescan xref 0x%X   (world_rva), then disasm the select handler by hand.", session.layout.world_rva)
    return
  }

  fmt.printfln("findsettarget: %d candidate call target(s) (* = best):", len(cands))
  for c, k in cands {
    fmt.printfln(
      "  %s SendSetTarget=Neuz.exe+0x%X  objid_off=0x%X  (set x%d, clear x%d%s)",
      k == 0 ? "*" : " ",
      c.target - base,
      c.disp,
      c.set_cnt,
      c.clr_cnt,
      c.ret8 ? ", ret 8" : "",
    )
  }

  bc := cands[0]
  new_rva := bc.target - base
  L := session.layout
  fmt.println("")
  if uintptr(L.sendsettarget_rva) == new_rva && L.objid_off == bc.disp {
    fmt.printfln("matches current flyff.cfg (sendsettarget_rva=0x%X objid_off=0x%X) - no change needed.", new_rva, bc.disp)
  } else if settarget_confident(cands[:]) {
    session.layout.sendsettarget_rva = new_rva
    session.layout.objid_off = bc.disp
    fmt.printfln("high confidence -> applied sendsettarget_rva=0x%X objid_off=0x%X (was 0x%X / 0x%X).", new_rva, bc.disp, L.sendsettarget_rva, L.objid_off)
    if flyff_save_cfg(session.layout, flyff_cfg_path()) {
      fmt.println("saved to flyff.cfg. srvsync is now live; 'srvtest' to confirm.")
    }
  } else {
    fmt.printfln("current:  sendsettarget_rva=0x%X  objid_off=0x%X", L.sendsettarget_rva, L.objid_off)
    fmt.printfln("proposed: sendsettarget_rva=0x%X  objid_off=0x%X", new_rva, bc.disp)
    fmt.println("low confidence - not auto-applied. If srvtest works, apply with:")
    fmt.printfln("  set sendsettarget_rva 0x%X", new_rva)
    fmt.printfln("  set objid_off 0x%X", bc.disp)
    if bc.set_cnt == 0 {
      fmt.printfln("  (no set-path push-2 site - disasm to be sure: func +0x%X)", new_rva)
    }
  }
}

// srvsync           -> status
// srvsync on|off    -> toggle: after each focus select, also fire the client's own
//                      SendSetTarget(objid, 2) so the server registers our target.
cli_mobs :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: mobs <name>")
    return
  }
  name := strings.trim(strings.join(args, " ", context.temp_allocator), "'\"")
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  pv, pok := engine.read_value(handle, base + session.layout.player_rva, pt)
  if !wok || !pok {
    fmt.eprintln("could not read world/player anchors.")
    return
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  player := uintptr(engine.value_as_u64(pt, pv))
  player_pos, _ := engine.read_vec3(handle, player + uintptr(session.layout.pos_off))
  wval := engine.ptr_to_value(world, session.ptr_size)
  all := engine.collect_regions(handle, true)
  defer delete(all)
  set := engine.scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)

  Row :: struct {
    obj:      uintptr,
    d:        f32,
    hp:       i32,
    model:    uintptr,
    model_ok: bool,
  }
  rows := make([dynamic]Row, context.temp_allocator)
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
    nm, nok := engine.read_obj_name(handle, session.ptr_size, obj, session.layout.name_off)
    if !nok || !strings.contains(nm, name) {
      continue
    }
    pos, posok := engine.read_vec3(handle, obj + uintptr(session.layout.pos_off))
    if !posok {
      continue
    }
    hp: i32 = -1
    if hv, hok := engine.read_value(handle, obj + uintptr(session.layout.hp_off), .U32); hok {
      hp = i32(u32(engine.value_as_u64(.U32, hv)))
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
    append(&rows, Row{obj = obj, d = engine.dist_3d(pos, player_pos), hp = hp, model = model, model_ok = model_ok})
  }
  slice.sort_by(rows[:], proc(a, b: Row) -> bool {return a.d < b.d})
  ok_count := 0
  for r in rows {
    if r.model_ok {
      ok_count += 1
    }
  }
  fmt.printfln("%d '%s' movers (%d selectable), by distance:", len(rows), name, ok_count)
  for r, i in rows {
    if i >= 30 {
      break
    }
    fmt.printfln(
      "  #%d d=%.1f obj=0x%X hp=%d model=0x%X %s",
      i + 1,
      r.d,
      r.obj,
      r.hp,
      r.model,
      r.model_ok ? "OK" : "BAD",
    )
  }
}

// Read-only recon: enumerate movers named <name> (same way target_closest does, but
// it NEVER writes focus), snapshot LEN bytes of each, wait ~2.5s, re-read, and report
// the field offsets that DECREMENT for some movers while staying 0 for the rest - i.e.
// a per-corpse death/despawn countdown. Used to find the "don't target" flag without
// touching the game. Usage: deathscan <name>
cli_deathscan :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: deathscan <name>")
    return
  }
  name := strings.trim(strings.join(args, " ", context.temp_allocator), "'\"")
  LEN :: 0x4000

  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  if !wok {
    fmt.eprintln("could not read world anchor.")
    return
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  wval := engine.ptr_to_value(world, session.ptr_size)

  all := engine.collect_regions(handle, true)
  defer delete(all)
  set := engine.scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)
  objs := make([dynamic]uintptr, context.temp_allocator)
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
    nm, nok := engine.read_obj_name(handle, session.ptr_size, obj, session.layout.name_off)
    if !nok || !strings.contains(nm, name) {
      continue
    }
    append(&objs, obj)
  }
  n := len(objs)
  fmt.printfln("deathscan '%s': %d movers; sampling...", name, n)
  if n < 3 {
    fmt.println("need >=3 movers (some alive, some fresh corpses). kill a few and retry.")
    return
  }

  read_snap :: proc(handle: win.HANDLE, objs: [dynamic]uintptr) -> [][]byte {
    bufs := make([][]byte, len(objs), context.temp_allocator)
    for o, i in objs {
      b := make([]byte, LEN, context.temp_allocator)
      engine.read_into(handle, o, b)
      bufs[i] = b
    }
    return bufs
  }
  u32at :: proc(b: []byte, off: int) -> i64 {
    if off + 4 > len(b) {
      return -1
    }
    return i64(u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24)
  }

  worldv := i64(u32(world))
  SNAPS :: 6
  snaps := make([][][]byte, SNAPS, context.temp_allocator)
  for s in 0 ..< SNAPS {
    snaps[s] = read_snap(handle, objs)
    if s < SNAPS - 1 {
      win.Sleep(1000)
    }
  }

  // A despawn countdown is 0 for every live mover and, for a fresh corpse, strictly
  // counts DOWN over the ~5s window (then the object frees). Require: per-mover values
  // monotonically non-increasing with at least one drop, 0 for the rest, no oscillators.
  fmt.println("=== fields counting monotonically DOWN for some movers (despawn timer) ===")
  off := 0
  for off <= LEN - 4 {
    mono, allz, oth := 0, 0, 0
    for i in 0 ..< n {
      cnt, prev, first := 0, i64(0), true
      ismono, anydec, allzero, startpos := true, false, true, false
      for s in 0 ..< SNAPS {
        if u32at(snaps[s][i], int(session.layout.field_off)) != worldv {
          continue // skip snapshots where this slot isn't a live object
        }
        v := u32at(snaps[s][i], off)
        cnt += 1
        if v != 0 {allzero = false}
        if v < 0 || v >= 100000 {ismono = false}
        if first {
          prev, startpos, first = v, v > 0, false
        } else {
          if v > prev {ismono = false}
          if v < prev {anydec = true}
          prev = v
        }
      }
      if cnt < 2 {
        continue
      }
      if allzero {
        allz += 1
      } else if ismono && anydec && startpos {
        mono += 1
      } else {
        oth += 1
      }
    }
    if mono >= 1 && oth <= 2 && allz >= (n * 6) / 10 {
      fmt.printfln("  +0x%X: mono=%d zero=%d other=%d", off, mono, allz, oth)
      shown := 0
      for i in 0 ..< n {
        sb := strings.builder_make(context.temp_allocator)
        valid, nonzero := 0, false
        for s in 0 ..< SNAPS {
          if u32at(snaps[s][i], int(session.layout.field_off)) != worldv {
            continue
          }
          v := u32at(snaps[s][i], off)
          if v != 0 {nonzero = true}
          fmt.sbprintf(&sb, "%d ", v)
          valid += 1
        }
        if nonzero && valid >= 2 {
          fmt.printfln("      obj=0x%X: %s", objs[i], strings.to_string(sb))
          shown += 1
          if shown >= 10 {
            break
          }
        }
      }
    }
    off += 4
  }
  fmt.println("(done)")
}

// Read-only recon: enumerate movers named <name> and report every field offset where
// at least 2 of them hold <value> - used to locate a known stat (e.g. a full mob's HP)
// by its value. Usage: objscan <value> <name>
cli_objscan :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 2 {
    fmt.eprintln("usage: objscan <value> <name>")
    return
  }
  val, valok := strconv.parse_i64(args[0])
  if !valok {
    fmt.eprintln("bad value.")
    return
  }
  name := strings.trim(strings.join(args[1:], " ", context.temp_allocator), "'\"")
  LEN :: 0x4000

  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  pt := engine.Value_Type.U64
  if session.ptr_size == 4 {
    pt = .U32
  }
  wv, wok := engine.read_value(handle, base + session.layout.world_rva, pt)
  if !wok {
    fmt.eprintln("could not read world anchor.")
    return
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  wval := engine.ptr_to_value(world, session.ptr_size)
  all := engine.collect_regions(handle, true)
  defer delete(all)
  set := engine.scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)
  bufs := make([dynamic][]byte, context.temp_allocator)
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
    nm, nok := engine.read_obj_name(handle, session.ptr_size, obj, session.layout.name_off)
    if !nok || !strings.contains(nm, name) {
      continue
    }
    b := make([]byte, LEN, context.temp_allocator)
    engine.read_into(handle, obj, b)
    append(&bufs, b)
  }
  fmt.printfln("objscan %d in '%s': %d movers", val, name, len(bufs))
  target := u32(val)
  off := 0
  for off <= LEN - 4 {
    c := 0
    for b in bufs {
      if off + 4 <= len(b) {
        v := u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24
        if v == target {
          c += 1
        }
      }
    }
    if c >= 2 {
      // also show how many movers have it in [1, val] (HP-like) vs == 0
      hp_like, zero := 0, 0
      for b in bufs {
        if off + 4 <= len(b) {
          v := i64(u32(b[off]) | u32(b[off + 1]) << 8 | u32(b[off + 2]) << 16 | u32(b[off + 3]) << 24)
          if v == 0 {
            zero += 1
          } else if v > 0 && v <= val {
            hp_like += 1
          }
        }
      }
      fmt.printfln("  +0x%X: %d ==%d  (%d in 1..%d, %d ==0)", off, c, val, hp_like, val, zero)
    }
    off += 4
  }
  fmt.println("(done)")
}

// ---------------------------------------------------------------------------
// Parsing helpers
// ---------------------------------------------------------------------------

// Resolve a command operand to an absolute address. `[i]` refers to match #i (like
// 'peek'); anything else is parsed as an address (decimal or 0x-hex).
