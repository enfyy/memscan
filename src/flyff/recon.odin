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

// findaii -> DIAGNOSTIC (RE only; not the gate - that's `findprop`). With a mover selected it scans
// the OBJECT for per-object AI-region fields that differ between the selection and the nearby crowd,
// and `findaii <off> <off> ...` dumps the selected object's raw u32 at those offsets. Used to prove
// that the client doesn't carry a usable AI type ON the object (only your stat pet gets AII_PET/EGG
// there) - the real classification is per-species via GetProp()->dwAI, which `findprop` reads. Read-only.
cli_findaii :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  ps := session.ptr_size
  pt := ps == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64
  L := session.layout
  LEN :: 0x4000

  wv, wok := engine.read_value(handle, base + L.world_rva, pt)
  pv, pok := engine.read_value(handle, base + L.player_rva, pt)
  if !wok || !pok {
    fmt.eprintln("could not read world/player anchors - run calibrate first.")
    return
  }
  world := uintptr(engine.value_as_u64(pt, wv))
  player := uintptr(engine.value_as_u64(pt, pv))

  fp, fok := engine.read_value(handle, world + uintptr(L.focus_off), pt)
  if !fok {
    fmt.eprintln("could not read the selection (focus_off) - run calibrate / findfocus first.")
    return
  }
  focus := uintptr(engine.value_as_u64(pt, fp))
  if focus == 0 || focus == player {
    fmt.eprintln("target your PET (or any known NON-monster) first, then run findaii.")
    return
  }
  fvt, fvtok := engine.read_value(handle, focus, pt)
  if !fvtok || !in_module_range(uintptr(engine.value_as_u64(pt, fvt)), base, mod_end) ||
     engine.read_obj_type(handle, focus, L.pos_off) != L.mover_type {
    fmt.eprintln("the selected object isn't a live mover - target your pet and retry.")
    return
  }
  fnm, _ := engine.read_obj_name(handle, ps, focus, L.name_off)
  ref := make([]byte, LEN, context.temp_allocator)
  engine.read_into(handle, focus, ref)

  // Offset-dump mode: `findaii 0x190 0x3F0C ...` prints the SELECTED object's raw u32 at each given
  // offset. Run it on a pet, then a known monster, then an NPC to compare the same offsets by hand.
  if len(args) > 0 {
    fmt.printfln("findaii dump for selected '%s':", fnm)
    for a in args {
      off, ok := engine.parse_addr(a)
      if !ok {
        fmt.printfln("  %s: bad offset", a)
        continue
      }
      if int(off) + 4 > LEN {
        fmt.printfln("  +0x%X: beyond the %d-byte scan window", off, LEN)
        continue
      }
      v := rd_u32le(ref, int(off))
      fmt.printfln("  +0x%X = %d (0x%X)", off, v, v)
    }
    return
  }

  // Sample nearby movers (the "crowd" - mostly monsters, plus players/NPCs). Exclude self + the ref.
  wval := engine.ptr_to_value(world, ps)
  all := engine.collect_regions(handle, true)
  defer delete(all)
  set := engine.scan_exact_regions(handle, pt, wval, all[:], nil, context.temp_allocator)
  bufs := make([dynamic][]byte, context.temp_allocator)
  for m in set.matches {
    obj := uintptr(i64(m.addr) - L.field_off)
    if obj == player || obj == focus {
      continue
    }
    vt, vok := engine.read_value(handle, obj, pt)
    if !vok || !in_module_range(uintptr(engine.value_as_u64(pt, vt)), base, mod_end) {
      continue
    }
    if engine.read_obj_type(handle, obj, L.pos_off) != L.mover_type {
      continue
    }
    b := make([]byte, LEN, context.temp_allocator)
    engine.read_into(handle, obj, b)
    append(&bufs, b)
    if len(bufs) >= 120 {
      break
    }
  }
  nmov := len(bufs)
  fmt.printfln("findaii: using selected '%s' as the non-monster reference; scanned vs %d nearby movers.", fnm, nmov)
  if nmov < 5 {
    fmt.println("need a few monsters on screen too. Stand where monsters are visible (pet targeted) and retry.")
    return
  }

  // Fallback discriminator report: the pet's species id (m_dwIndex @ pos+0x14) is unique to the pet,
  // so if ~no monster shares it, excluding that species also works.
  sp_off := int(L.pos_off) + 0x14
  ref_sp := rd_u32le(ref, sp_off)
  same_sp := 0
  for b in bufs {
    if rd_u32le(b, sp_off) == ref_sp {
      same_sp += 1
    }
  }
  fmt.printfln("  ref species (m_dwIndex @ +0x%X) = %d; %d/%d crowd movers share it.", sp_off, ref_sp, same_sp, nmov)

  // Find the AI-type field WITHOUT assuming enum numbers (this modded build may have remapped both the
  // offset AND the values). Scan the whole object for the offset where the crowd strongly agrees on one
  // small value (the monster consensus) but the selected pet holds a DIFFERENT small value - AND where
  // almost no monster shares the pet's value (that last part separates the real type field from mere
  // proximity/size flags, which many close monsters share with the pet).
  Cand :: struct {
    off:    int,
    petv:   u32,
    mv:     int, // crowd modal small value (the monster consensus)
    mc:     int, // crowd count sharing mv
    shares: int, // crowd count sharing the pet's value (i.e. other pets)
    big:    int,
  }
  cands := make([dynamic]Cand, context.temp_allocator)
  for off := 0; off + 4 <= LEN; off += 4 {
    petv := rd_u32le(ref, off)
    if petv >= 256 {
      continue // the AI-type value is a small enum, not a pointer/id/float
    }
    cnt: [256]int
    big := 0
    for b in bufs {
      v := rd_u32le(b, off)
      if v < 256 {
        cnt[v] += 1
      } else {
        big += 1
      }
    }
    if big * 5 > nmov {
      continue // mostly pointer/float/id field
    }
    mv, mc := 0, 0
    for c, v in cnt {
      if c > mc {
        mc = c
        mv = v
      }
    }
    if mc * 2 < nmov {
      continue // no strong single-value consensus among the crowd
    }
    if u32(mv) == petv {
      continue // pet agrees with the crowd here - not a discriminator
    }
    append(&cands, Cand{off, petv, mv, mc, cnt[petv], big})
  }
  if len(cands) == 0 {
    fmt.println("no field separates the pet from the monster crowd in the first 0x4000 bytes.")
    fmt.println("Tell me and I'll widen the window or switch to a pet-vs-known-monster capture diff.")
    return
  }
  slice.sort_by(cands[:], proc(a, b: Cand) -> bool {
    if a.shares != b.shares {
      return a.shares < b.shares // fewest monsters sharing the pet's value first = most likely the type field
    }
    return a.mc > b.mc
  })
  fmt.println("fields where the crowd agrees on one value but the pet differs (best candidates first;")
  fmt.println("the AI-type field has crowd-sharing-pet-val ~0 - no monster is a pet):")
  shown := 0
  for c in cands {
    if shown >= 40 {
      fmt.printfln("  ... (%d more)", len(cands) - shown)
      break
    }
    extra := c.big > 0 ? fmt.tprintf("  big=%d", c.big) : ""
    fmt.printfln(
      "  +0x%X  pet=%d  crowd-consensus=%d (x%d/%d)  crowd-sharing-pet-val=%d%s",
      c.off, c.petv, c.mv, c.mc, nmov, c.shares, extra,
    )
    shown += 1
  }
  fmt.println("--> paste this; the top rows (pet differs, ~0 monsters share the pet's value) are m_dwAIInterface.")
}

// Read a mover's species id (m_dwIndex @ pos_off+0x14).
read_species :: proc(session: ^Session, obj: uintptr) -> (u32, bool) {
  v, ok := engine.read_value(session.proc_info.handle, obj + uintptr(session.layout.pos_off + SPECIES_REL), .U32)
  if !ok {
    return 0, false
  }
  return u32(engine.value_as_u64(.U32, v)), true
}

// All addresses in writable memory whose 4-byte value == <val>. Used by findprop to anchor the
// MoverProp array (record[i].dwID == i). Temp-allocated.
scan_u32_addrs :: proc(session: ^Session, val: u32) -> [dynamic]uintptr {
  handle := session.proc_info.handle
  regions := engine.collect_regions(handle, true)
  defer delete(regions)
  set := engine.scan_exact_regions(handle, .U32, engine.ptr_to_value(uintptr(val), 4), regions[:], nil, context.temp_allocator)
  out := make([dynamic]uintptr, context.temp_allocator)
  for m in set.matches {
    append(&out, uintptr(m.addr))
  }
  return out
}

// Read GetProp()->dwAI for a species id off an already-resolved prop-array base (uses the layout's
// current stride/ai_off). -1 on read failure.
read_prop_ai :: proc(session: ^Session, propbase: uintptr, id: u32) -> i64 {
  addr := propbase + uintptr(i64(id) * session.layout.moverprop_stride + session.layout.moverprop_ai_off)
  if v, ok := engine.read_value(session.proc_info.handle, addr, .U32); ok {
    return i64(u32(engine.value_as_u64(.U32, v)))
  }
  return -1
}

// Human-readable verdict for a species' GetProp()->dwAI under the any-monster gate.
aii_verdict :: proc(ai: i64) -> string {
  switch ai {
  case 2:
    return "AII_MONSTER -> TARGETED by auto any"
  case 5:
    return "AII_PET -> excluded"
  case 9:
    return "AII_EGG -> excluded"
  case 0:
    return "AII_NONE (NPC) -> excluded"
  case 1:
    return "AII_MOVER (player/mover) -> excluded"
  }
  return "excluded (not AII_MONSTER)"
}

// findprop -> derive the species MoverProp-array gate for "auto any": propmover_rva / moverprop_stride
// / moverprop_ai_off. TARGET your PET (target_closest <pet>) with a few monsters on screen, then run it.
// The client resolves a mob's AI class as GetProp()->dwAI = m_pPropMover[m_dwIndex].dwAI - a flat array
// indexed by species. Since record[i].dwID == i, this locates the array base + stride from the live
// species ids on screen, then finds dwAI's column (your pet reads AII_PET=5/EGG=9, monsters read
// AII_MONSTER=2) and the stable global-pointer RVA. Saves flyff.cfg. Read-only except the cfg write.
cli_findprop :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  size := session.proc_info.module_size
  mod_end := base + uintptr(size)
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

  // `findprop check <species_id>` -> look up a species' prop dwAI + szName directly (no target needed).
  if len(args) >= 2 && args[0] == "check" {
    if idv, idok := engine.parse_addr(args[1]); idok {
      if !prop_gate_ready(session) {
        fmt.eprintln("prop gate not configured - run findprop (pet targeted) first.")
        return
      }
      pb, pbok := engine.read_value(handle, base + L.propmover_rva, pt)
      if !pbok {
        fmt.eprintln("couldn't resolve the prop-array pointer.")
        return
      }
      propbase := uintptr(engine.value_as_u64(pt, pb))
      sp := u32(idv)
      ai := read_prop_ai(session, propbase, sp)
      nb: [24]byte
      engine.read_into(handle, propbase + uintptr(i64(sp) * L.moverprop_stride + 4), nb[:])
      end := 0
      for end < len(nb) && nb[end] >= 0x20 && nb[end] < 0x7F {
        end += 1
      }
      fmt.printfln("findprop check: species=%d szName='%s' dwAI=%d  %s", sp, string(nb[:end]), ai, aii_verdict(ai))
      return
    }
  }

  fp, fok := engine.read_value(handle, world + uintptr(L.focus_off), pt)
  if !fok {
    fmt.eprintln("could not read the selection - run calibrate / findfocus first.")
    return
  }
  focus := uintptr(engine.value_as_u64(pt, fp))
  if focus == 0 || focus == player {
    fmt.eprintln("target your PET first (target_closest <pet name>), with monsters on screen, then run findprop.")
    return
  }
  focus_id, fidok := read_species(session, focus)
  if !fidok || focus_id == 0 || focus_id > 0xFFFF {
    fmt.eprintln("couldn't read the pet's species id - retry with the pet targeted.")
    return
  }
  fnm, _ := engine.read_obj_name(handle, ps, focus, L.name_off)

  // `findprop check` -> classify the currently-targeted mob via the configured prop gate (verify).
  if len(args) >= 1 && args[0] == "check" {
    if !prop_gate_ready(session) {
      fmt.eprintln("prop gate not configured - run findprop (pet targeted) first.")
      return
    }
    pb, pbok := engine.read_value(handle, base + L.propmover_rva, pt)
    if !pbok {
      fmt.eprintln("couldn't resolve the prop-array pointer.")
      return
    }
    ai := read_prop_ai(session, uintptr(engine.value_as_u64(pt, pb)), focus_id)
    fmt.printfln("findprop check: '%s' species=%d dwAI=%d  %s", fnm, focus_id, ai, aii_verdict(ai))
    return
  }

  // Gather distinct live species ids (anchors for the array-identity solve).
  wval := engine.ptr_to_value(world, ps)
  regions0 := engine.collect_regions(handle, true)
  set0 := engine.scan_exact_regions(handle, pt, wval, regions0[:], nil, context.temp_allocator)
  delete(regions0)
  ids := make([dynamic]u32, context.temp_allocator)
  for m in set0.matches {
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
    if id, ok := read_species(session, obj); ok && id != 0 && id <= 0xFFFF {
      dup := false
      for x in ids {
        if x == id {
          dup = true
          break
        }
      }
      if !dup {
        append(&ids, id)
      }
    }
  }
  dup := false
  for x in ids {
    if x == focus_id {
      dup = true
      break
    }
  }
  if !dup {
    append(&ids, focus_id)
  }
  if len(ids) < 4 {
    fmt.println("need more species variety on screen (a few different monsters + your pet). Move and retry.")
    return
  }

  // Anchor1 = the pet's id (definitely valid). Some of the "live species" are garbage from coincidental
  // world-ptr scan hits, so don't trust the single largest id; try several plausible ones (<= 5000).
  // record[i].dwID == i, so for the right (R0, stride): u32(R0 + i*stride) == i for every real id.
  anchor1 := focus_id
  hitsA := scan_u32_addrs(session, anchor1)
  if len(hitsA) == 0 {
    fmt.println("pet species value not found in memory - retry with the pet targeted.")
    return
  }
  cand2 := make([dynamic]u32, context.temp_allocator)
  for id in ids {
    if id == anchor1 || id > 5000 {
      continue
    }
    seen := false
    for x in cand2 {
      if x == id {
        seen = true
        break
      }
    }
    if !seen {
      append(&cand2, id)
    }
  }
  if len(cand2) == 0 {
    fmt.println("need at least two distinct plausible species on screen.")
    return
  }
  slice.sort(cand2[:]) // ascending; iterate from the back (largest ids = rarest in memory)
  fmt.printfln("findprop: pet '%s' species %d; %d live species; anchor %d x%d; locating array...", fnm, focus_id, len(ids), anchor1, len(hitsA))

  best_r0 := i64(0)
  best_stride := i64(0)
  best_score := 0
  good := max(12, len(ids) / 3)
  tried := 0
  anchors: for k := len(cand2) - 1; k >= 0; k -= 1 {
    if tried >= 8 {
      break
    }
    anchor2 := cand2[k]
    hitsB := scan_u32_addrs(session, anchor2)
    if len(hitsB) == 0 || len(hitsB) > 40000 {
      continue // not found, or too common to pair efficiently
    }
    tried += 1
    span := i64(anchor1) - i64(anchor2)
    if span == 0 {
      continue
    }
    pre_id := u32(0)
    for id in ids {
      if id != anchor1 && id != anchor2 {
        pre_id = id
        break
      }
    }
    for a in hitsA {
      aa := i64(a)
      for b in hitsB {
        d := aa - i64(b)
        if d > 0x8000000 || d < -0x8000000 {
          continue // records of one array are within ~128MB
        }
        if d % span != 0 {
          continue
        }
        stride := d / span
        if stride < 0x80 || stride > 0x20000 || stride % 4 != 0 {
          continue
        }
        r0 := aa - i64(anchor1) * stride
        if r0 <= 0 {
          continue
        }
        // Cheap pre-check on a third id before the full validation (skips coincidental strides fast).
        if pre_id != 0 {
          if v, ok := engine.read_value(handle, uintptr(r0 + i64(pre_id) * stride), .U32);
             !ok || u32(engine.value_as_u64(.U32, v)) != pre_id {
            continue
          }
        }
        score := 0
        for id in ids {
          if v, ok := engine.read_value(handle, uintptr(r0 + i64(id) * stride), .U32); ok &&
             u32(engine.value_as_u64(.U32, v)) == id {
            score += 1
          }
        }
        if score > best_score {
          best_score = score
          best_r0 = r0
          best_stride = stride
        }
      }
    }
    if best_score >= good {
      break anchors
    }
  }
  // Acceptance floor. Each match is an EXACT record[i].dwID == i at a computed offset, and the (r0,stride)
  // already forces 2 anchors + a pre-checked third to match, so 4 total is a confident lock - a wrong
  // stride matching 4 distinct ids exactly is astronomically unlikely. Only scale the floor up for large
  // id sets (where the real array scores far higher anyway); farm spots often have just 4-6 species.
  min_score := max(4, len(ids) / 4)
  if best_score < min_score {
    fmt.printfln(
      "couldn't lock the prop array (best %d/%d species matched; need >=%d). Get a few more DISTINCT monster species on screen and retry.",
      best_score, len(ids), min_score,
    )
    return
  }
  r0 := best_r0
  stride := best_stride
  fmt.printfln("  array located: record[i].dwID matched %d/%d live species; stride 0x%X.", best_score, len(ids), stride)

  // propbase (record[0] start) + stable global-pointer RVA. m_pPropMover points at record[0]; dwID is
  // usually the first record field, but allow a small lead-in offset.
  propbase := uintptr(0)
  propmover_rva := uintptr(0)
  for doff := i64(0); doff <= 0x40; doff += 4 {
    cand := uintptr(r0 - doff)
    hits := engine.scan_image_for_ptr(handle, base, size, cand, ps, context.temp_allocator)
    if len(hits) > 0 {
      propbase = cand
      propmover_rva = hits[0] - base
      break
    }
  }
  if propbase == 0 {
    fmt.printfln("  located the array (record[0].dwID @ 0x%X, stride 0x%X) but couldn't find the global", r0, stride)
    fmt.println("  m_pPropMover pointer in the module image - paste this and I'll widen the pointer search.")
    return
  }

  // dwAI column: an ENUM field, so every species record reads a small AII value (0..14 or 100). It's
  // the all-enum column where the PET reads its own AII type (AII_PET=5 / AII_EGG=9) and at least some
  // live species read AII_MONSTER(2); pick the one with the most monsters (the gate keeps those). No
  // fixed monster-fraction threshold - a farm area can have few distinct AII_MONSTER species on screen.
  ai_off := i64(-1)
  best_two := -1
  lim := stride < 0x600 ? stride : 0x600
  for off := i64(0); off + 4 <= lim; off += 4 {
    pav, paok := engine.read_value(handle, propbase + uintptr(i64(focus_id) * stride + off), .U32)
    if !paok {
      continue
    }
    pv := u32(engine.value_as_u64(.U32, pav))
    if pv != 5 && pv != 9 {
      continue // the pet's species reads AII_PET or AII_EGG at the real dwAI column
    }
    all_enum := true
    two := 0
    for id in ids {
      v, ok := engine.read_value(handle, propbase + uintptr(i64(id) * stride + off), .U32)
      if !ok {
        all_enum = false
        break
      }
      vv := u32(engine.value_as_u64(.U32, v))
      if !(vv <= 14 || vv == 100) {
        all_enum = false
        break
      }
      if vv == 2 {
        two += 1
      }
    }
    if all_enum && two >= 1 && two > best_two {
      best_two = two
      ai_off = off
    }
  }
  if ai_off < 0 {
    fmt.printfln("  found the array (propbase 0x%X rva 0x%X stride 0x%X) but not a clean dwAI column.", propbase, propmover_rva, stride)
    fmt.print("  pet record dump (+off=value):")
    for o := i64(0); o < 0x180; o += 4 {
      if v, ok := engine.read_value(handle, propbase + uintptr(i64(focus_id) * stride + o), .U32); ok {
        fmt.printf(" +0x%X=%d", o, u32(engine.value_as_u64(.U32, v)))
      }
    }
    fmt.println("")
    return
  }

  session.layout.propmover_rva = propmover_rva
  session.layout.moverprop_stride = stride
  session.layout.moverprop_ai_off = ai_off
  pet_ai := read_prop_ai(session, propbase, focus_id)
  fmt.printfln("  propmover_rva=0x%X moverprop_stride=0x%X moverprop_ai_off=0x%X", propmover_rva, stride, ai_off)
  fmt.printfln("  validation: pet '%s' (species %d) dwAI=%d; %d/%d live species read AII_MONSTER(2).", fnm, focus_id, pet_ai, best_two, len(ids))
  if flyff_save_cfg(session.layout, flyff_cfg_path()) {
    fmt.println("saved to flyff.cfg. run 'auto off' then 'auto any' - it now skips pets / eggs / NPCs / players by species.")
  }
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
