package flyff

import "core:fmt"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"

import "../engine"

// ===========================================================================
// Character control commands: `moveto` (walk to a world point) and `jump`.
//
// moveto is a PURE FIELD-WRITE: movement is client-authoritative, so writing CMover's destination
// fields (m_vDestPos + the arrival-sign bits + m_bForward + m_idDest=NULL_ID) makes the client's own
// ProcessMove walk there each tick and re-report position - no injected call, no screen projection.
// (CMover::SetDestPos is inlined in this build, so there's nothing to call anyway; the field-writes are
// exactly what it does internally, minus the predictive destpos snapshot, which the continuous position
// sync makes unnecessary.) jump DOES inject (remote_send_actmsg -> the client's SendActMsg).
//
// The offsets/RVA these need live in Session.layout (destpos_off / iddest_off / forward_off /
// sendactmsg_rva / actmover_off / jump_msg), pinned by `findmove` and persisted in flyff.cfg.
// ===========================================================================

// moveto <x,z> | <x,y,z> - walk the player to a world point. With two coords the Y is taken from the
// player's current height (the ground clamp fixes the exact Y anyway); three coords set it explicitly.
cli_moveto :: proc(session: ^Session, args: []string) {
  if !moveto_ready(session) {
    return
  }
  if len(args) == 0 {
    fmt.eprintln("usage: moveto <x,z> | <x,y,z>   (walk to a world point; Y defaults to your current height)")
    return
  }
  coords, n, cok := parse_coords(args)
  if !cok {
    fmt.eprintln("bad coords - use x,z or x,y,z (e.g. 'moveto 6800,3300').")
    return
  }
  ppos, pok := read_player_pos(session)
  if !pok {
    fmt.eprintln("couldn't read player position - run 'calibrate' first.")
    return
  }
  dest: [3]f32
  if n == 2 {
    dest = {f32(coords[0]), ppos[1], f32(coords[1])}
  } else {
    dest = {f32(coords[0]), f32(coords[1]), f32(coords[2])}
  }
  d := engine.dist_horizontal(ppos, dest)
  if !write_dest_pos(session, ppos, dest) {
    fmt.eprintln("moveto failed (couldn't write the destination fields - is the player resolved?).")
    return
  }
  // Server-sync: flush the destpos we just wrote into g_DPlay so OTHER clients see a walk, not a teleport.
  // (write_dest_pos already staged m_ss.playerdestpos; SendSnapshot(TRUE) broadcasts it now.) Inert until
  // sendsnapshot_rva/gdplay_rva are configured, in which case moveto stays purely local (self-only).
  synced := remote_send_snapshot(session)
  fmt.printfln(
    "moveto -> (%.1f, %.1f, %.1f)  [%.1f units away]  walking...%s",
    dest[0], dest[1], dest[2], d, synced ? "" : "  (local only - run 'findmove' for other clients to see it)",
  )
}

// Write CMover's destination fields on the player so the client's own ProcessMove walks there.
// ORDER MATTERS: everything else is written BEFORE m_vDestPos (written last), because ProcessMove treats
// a zero m_vDestPos as "no destination" (IsEmptyDestPos) and returns early - so until the final write the
// move stays disarmed and can never observe half-updated sign bits. The sign bits must equal
// (m_vPos - dest) > 0, which is exactly what ProcessMove recomputes and compares each tick; a mismatch
// makes it think it already passed the target and arrive instantly.
write_dest_pos :: proc(session: ^Session, cur: [3]f32, dest: [3]f32) -> bool {
  handle := session.proc_info.handle
  player := read_ptr_at(handle, session.proc_info.base + session.layout.player_rva, engine.Value_Type.U32)
  if player == 0 {
    return false
  }
  L := session.layout
  posx: u8 = (cur[0] - dest[0]) > 0 ? 1 : 0 // m_bPositiveX = (m_vPos.x - dest.x) > 0
  posz: u8 = (cur[2] - dest[2]) > 0 ? 1 : 0 // m_bPositiveZ = (m_vPos.z - dest.z) > 0
  ok := true
  if !wr_u32(handle, player + uintptr(L.iddest_off), 0xFFFFFFFF) {ok = false} // m_idDest = NULL_ID (dest-pos mode)
  if !wr_u8(handle, player + uintptr(L.forward_off), 1) {ok = false} // m_bForward
  if !wr_u8(handle, player + uintptr(L.forward_off + 1), posx) {ok = false} // m_bPositiveX
  if !wr_u8(handle, player + uintptr(L.forward_off + 2), posz) {ok = false} // m_bPositiveZ
  if !wr_vec3(handle, player + uintptr(L.destpos_off), dest) {ok = false} // m_vDestPos LAST -> arms the move

  // Server sync: also queue the destination in g_DPlay's snapshot struct (m_ss.playerdestpos) so the
  // client's OWN per-frame SendSnapshot broadcasts SNAPSHOTTYPE_DESTPOS - otherwise other clients see a
  // teleport instead of a walk. No injected call: we set the same fields PutPlayerDestPos would, fValid
  // LAST so a snapshot never catches a half-written destpos. Inert until gdplay_rva/dplay_destpos_off set.
  if L.gdplay_rva != 0 && L.dplay_destpos_off != 0 {
    vp := session.proc_info.base + L.gdplay_rva + uintptr(L.dplay_destpos_off)
    // playerdestpos layout (from the inlined PutPlayerDestPos): vPos @ +0, fForward (byte) @ +0xC,
    // fValid (BOOL) @ +0x10. fValid LAST so SendSnapshot never catches a half-written destpos.
    if !wr_vec3(handle, vp, dest) {ok = false} // playerdestpos.vPos
    if !wr_u8(handle, vp + 0xC, 1) {ok = false} // playerdestpos.fForward
    if !wr_u32(handle, vp + 0x10, 1) {ok = false} // playerdestpos.fValid = TRUE -> flags it ready to send
  }
  return ok
}

// jump - make the player jump by sending the client's own OBJMSG_JUMP (jump_msg). The in-client guards
// (grounded / not casting/attacking/sitting / not NOMOVE) run as normal; the handler's return code is
// reported (1 = jumped, else the guard that blocked it).
cli_jump :: proc(session: ^Session, args: []string) {
  if !jump_ready(session) {
    return
  }
  ret, ok := remote_send_actmsg(session, session.layout.jump_msg)
  if !ok {
    fmt.eprintln("jump failed (the injected SendActMsg call didn't complete).")
    return
  }
  if ret == 1 {
    fmt.println("jump.")
  } else {
    fmt.printfln(
      "jump not performed (SendActMsg returned %d - likely already airborne / casting / attacking / sitting).",
      ret,
    )
  }
}

// ---------------------------------------------------------------------------
// findmove - pin the move/jump config
// ---------------------------------------------------------------------------

// findmove auto-derives actmover_off (CMover.m_pActMover via the CActionMover's backref to the player)
// and sendactmsg_rva (the actmover vtable[1], SendActMsg-signature-verified - robust across the fork's
// code re-patches), seeds jump_msg, and reports/validates the moveto field offsets (which are re-patch-
// stable data offsets, seeded to the known values). Saves flyff.cfg. Read-only except the cfg write.
cli_findmove :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if session.ptr_size != 4 {
    fmt.eprintln("character control targets the 32-bit Flyff client.")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  ps := session.ptr_size
  pt := engine.Value_Type.U32
  L := &session.layout

  player := read_ptr_at(handle, base + L.player_rva, pt)
  if player == 0 || !in_module_range(read_ptr_at(handle, player, pt), base, mod_end) {
    fmt.eprintln("player not resolved - run 'calibrate'/'setup' first (need a valid player object).")
    return
  }
  fmt.printfln("findmove: player obj = 0x%X", player)

  // 1. actmover_off: a CMover pointer-field whose target is a heap object (module vtable) that holds a
  //    pointer back to the player - the CActionMover (CAction::m_pObj == the owning CMover). This
  //    uniquely distinguishes m_pActMover from m_pModel etc. Scan the plausible CMover field region.
  actmover: uintptr = 0
  for off := i64(0x40); off <= 0x800; off += 4 {
    cand := read_ptr_at(handle, player + uintptr(off), pt)
    if cand == 0 || cand == player || !is_heap_ptr(session, cand) {
      continue
    }
    if !in_module_range(read_ptr_at(handle, cand, pt), base, mod_end) {
      continue // target has no module vtable -> not a CActionMover
    }
    for bo := i64(0); bo <= 0x80; bo += 4 {
      if read_ptr_at(handle, cand + uintptr(bo), pt) == player {
        L.actmover_off = off
        actmover = cand
        fmt.printfln("  actmover_off = 0x%X   (m_pActMover -> 0x%X; backref to player at +0x%X)", off, cand, bo)
        break
      }
    }
    if actmover != 0 {
      break
    }
  }
  if actmover == 0 {
    fmt.println("  actmover_off NOT found (no CMover field references the player back) - set manually if known.")
  }

  // 2. sendactmsg_rva: CActionMover::SendActMsg is virtual = vtable[1] on the actmover. Verify it opens
  //    with the SendActMsg signature (guards against a vtable-layout change). Robust across re-patches.
  if actmover != 0 {
    vtable := read_ptr_at(handle, actmover, pt)
    if in_module_range(vtable, base, mod_end) {
      slot1 := read_ptr_at(handle, vtable + uintptr(ps), pt) // vtable[1]
      if slot1 >= base && slot1 < mod_end {
        cand_rva := slot1 - base
        if rva_prologue_ok(session, cand_rva, SENDACTMSG_SIG[:]) {
          L.sendactmsg_rva = cand_rva
          fmt.printfln("  sendactmsg_rva = 0x%X   (CActionMover vtable[1]; SendActMsg signature verified)", cand_rva)
        } else {
          fmt.printfln("  sendactmsg_rva NOT auto-derived (vtable[1]=0x%X prologue != SendActMsg sig) - set manually.", cand_rva)
        }
      }
    }
  }

  // 3. jump_msg: auto-derive OBJMSG_JUMP from the SendActMsg switch (the case that writes OBJSTA_SJUMP1)
  //    so an enum renumber - this fork already shifted it +1 vs the base source - is handled. Fall back
  //    to seed/keep if the switch can't be parsed.
  if L.sendactmsg_rva != 0 {
    if jm, jok := derive_jump_msg(session, L.sendactmsg_rva); jok {
      L.jump_msg = jm
      fmt.printfln("  jump_msg = 0x%X   (derived: the SendActMsg switch case that writes OBJSTA_SJUMP1)", jm)
    } else if L.jump_msg == 0 {
      L.jump_msg = FLYFF_JUMP_MSG
      fmt.printfln("  jump_msg = 0x%X   (couldn't derive from the switch; seeded default)", L.jump_msg)
    } else {
      fmt.printfln("  jump_msg = 0x%X   (couldn't derive; kept current - verify jump does a JUMP, not a stun)", L.jump_msg)
    }
  } else if L.jump_msg == 0 {
    L.jump_msg = FLYFF_JUMP_MSG
    fmt.printfln("  jump_msg = 0x%X   (seeded default; sendactmsg_rva unset so can't derive)", L.jump_msg)
  }

  // 4. moveto field offsets: re-patch-stable data offsets, seeded to the known build values. Report +
  //    keep (they've survived the code re-patches). A structural patch that moved them needs a manual
  //    'set destpos_off 0x..' after observing a live click-to-move (the field that holds the dest coord).
  if L.destpos_off == 0 {L.destpos_off = FLYFF_DESTPOS_OFF}
  if L.iddest_off == 0 {L.iddest_off = FLYFF_IDDEST_OFF}
  if L.forward_off == 0 {L.forward_off = FLYFF_FORWARD_OFF}
  fmt.printfln(
    "  moveto fields: destpos_off=0x%X iddest_off=0x%X forward_off=0x%X (m_bPositiveX/Z at +1/+2)",
    L.destpos_off, L.iddest_off, L.forward_off,
  )

  // 5. moveto SERVER-SYNC (so other clients see a walk, not a teleport). gdplay_rva + dplay_destpos_off
  //    are data-stable (seeded); sendsnapshot_rva is code (re-patches per launch) so it's AUTO-DERIVED
  //    from the SendSnapshot code that reads playerdestpos.vPos - keeps move-sync alive across patches.
  if L.gdplay_rva == 0 {L.gdplay_rva = FLYFF_GDPLAY_RVA}
  if L.dplay_destpos_off == 0 {L.dplay_destpos_off = FLYFF_DPLAY_DESTPOS_OFF}
  gd_ok := L.gdplay_rva != 0 && in_module_range(read_ptr_at(handle, base + L.gdplay_rva, pt), base, mod_end)
  if ss, sok := derive_sendsnapshot_rva(session); sok {
    L.sendsnapshot_rva = ss
    fmt.printfln("  sendsnapshot_rva = 0x%X   (derived: SendSnapshot reads playerdestpos.vPos)", ss)
  } else if L.sendsnapshot_rva != 0 && sendsnapshot_rva_sane(session) {
    fmt.printfln("  sendsnapshot_rva = 0x%X   (kept)", L.sendsnapshot_rva)
  } else {
    fmt.println("  sendsnapshot_rva NOT derived - moveto still works but stays LOCAL-ONLY (others see a teleport).")
  }
  fmt.printfln(
    "  server-sync: gdplay_rva=0x%X %s  dplay_destpos_off=0x%X (fForward +0xC, fValid +0x10)",
    L.gdplay_rva, gd_ok ? "[OK resolves]" : "[unresolved - set gdplay_rva]", L.dplay_destpos_off,
  )

  if flyff_save_cfg(session.layout, flyff_cfg_path()) {
    fmt.println("  saved -> flyff.cfg")
  }
}

// Walk back from an address to the enclosing function start (nearest byte preceded by >=2 int3 padding) -
// the same heuristic `func` uses. Returns addr unchanged if no padding is found in the window.
func_start :: proc(handle: win.HANDLE, addr: uintptr) -> uintptr {
  PRE :: 0x800
  pre := make([]byte, PRE + 16, context.temp_allocator)
  n, ok := engine.read_into(handle, addr - PRE, pre)
  if !ok || int(n) < PRE {
    return addr
  }
  for j := PRE; j >= 2; j -= 1 {
    if pre[j - 1] == 0xCC && pre[j - 2] == 0xCC {
      return addr - PRE + uintptr(j)
    }
  }
  return addr
}

// Auto-derive sendsnapshot_rva: codescan the destpos.vPos ABSOLUTE address; the instruction that READS it
// (`movq xmm,[vPos]` = F3 0F 7E 05 <vPos>) is inside SendSnapshot (it builds the SNAPSHOTTYPE_DESTPOS
// packet). Walk back to the function start + verify the prologue. This is what keeps move-sync working
// across the fork's per-launch RVA re-patch. Needs gdplay_rva + dplay_destpos_off. Read-only.
derive_sendsnapshot_rva :: proc(session: ^Session) -> (rva: uintptr, ok: bool) {
  L := session.layout
  if L.gdplay_rva == 0 || L.dplay_destpos_off == 0 {
    return 0, false
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  vpos_abs := u32(base + L.gdplay_rva + uintptr(L.dplay_destpos_off))
  hits := engine.codescan_u32(handle, vpos_abs, context.temp_allocator)
  sig := [?]byte{0x55, 0x8B, 0xEC}
  for h in hits {
    pre: [4]byte // the reader instruction is `F3 0F 7E 05 <vpos_abs>`; those 4 bytes precede the disp32
    n, rok := engine.read_into(handle, h - 4, pre[:])
    if !rok || int(n) < 4 {
      continue
    }
    if pre[0] == 0xF3 && pre[1] == 0x0F && pre[2] == 0x7E && pre[3] == 0x05 {
      start := func_start(handle, h - 4)
      if start > base && rva_prologue_ok(session, start - base, sig[:]) {
        return start - base, true
      }
    }
  }
  return 0, false
}

// ---------------------------------------------------------------------------
// jump_msg auto-derivation (survives the fork renumbering the OBJMSG enum)
// ---------------------------------------------------------------------------

// Derive jump_msg (OBJMSG_JUMP) by parsing SendActMsg's message switch and finding the case whose
// handler writes OBJSTA_SJUMP1 (0x5000) into the action state (the jump takeoff). SendActMsg forwards to
// a ProcessActMsg dispatcher (a jump-table switch on dwMsg); we try each of its call targets. Read-only.
derive_jump_msg :: proc(session: ^Session, sendactmsg_rva: uintptr) -> (msg: u32, ok: bool) {
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  sbuf: [80]byte
  engine.read_into(handle, base + sendactmsg_rva, sbuf[:])
  for i := 0; i + 5 <= len(sbuf); i += 1 {
    if sbuf[i] != 0xE8 { // E8 rel32 = call
      continue
    }
    rel := i32(u32(sbuf[i + 1]) | u32(sbuf[i + 2]) << 8 | u32(sbuf[i + 3]) << 16 | u32(sbuf[i + 4]) << 24)
    tgt := base + sendactmsg_rva + uintptr(i) + 5 + uintptr(int(rel))
    if tgt < base || tgt >= mod_end {
      continue
    }
    if m, mok := jump_msg_from_dispatch(session, tgt); mok {
      return m, true
    }
  }
  return 0, false
}

// Parse a ProcessActMsg dispatcher and return the dwMsg whose case handler writes OBJSTA_SJUMP1. The
// switch is `lea eax,[ebx+base_n]; cmp eax,range; ja default; movzx eax,byte[eax+indexTbl];
// jmp [eax*4+jumpTbl]` - so dwMsg = (index into indexTbl) - base_n. ok=false if the shape isn't found.
jump_msg_from_dispatch :: proc(session: ^Session, fn: uintptr) -> (msg: u32, ok: bool) {
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  head: [0xA0]byte
  engine.read_into(handle, fn, head[:])
  index_tbl, jump_tbl: uintptr
  base_n: i32 = 0
  range_ := 0
  have_jmp := false
  for i := 0; i + 7 <= len(head); i += 1 {
    if head[i] == 0x0F && head[i + 1] == 0xB6 && head[i + 2] == 0x80 { // movzx eax, byte [eax + disp32]
      index_tbl = uintptr(u32(head[i + 3]) | u32(head[i + 4]) << 8 | u32(head[i + 5]) << 16 | u32(head[i + 6]) << 24)
    }
    if head[i] == 0xFF && head[i + 1] == 0x24 && head[i + 2] == 0x85 { // jmp [eax*4 + disp32]
      jump_tbl = uintptr(u32(head[i + 3]) | u32(head[i + 4]) << 8 | u32(head[i + 5]) << 16 | u32(head[i + 6]) << 24)
      have_jmp = true
    }
    if head[i] == 0x8D && head[i + 1] == 0x43 { // lea eax, [ebx + disp8] (signed; the dwMsg->index base)
      base_n = i32(i8(head[i + 2]))
    }
    if head[i] == 0x83 && head[i + 1] == 0xF8 && range_ == 0 { // cmp eax, imm8 (switch range)
      range_ = int(head[i + 2])
    }
  }
  if !have_jmp || index_tbl < base || index_tbl >= mod_end || jump_tbl < base || jump_tbl >= mod_end {
    return 0, false
  }
  if range_ <= 0 || range_ > 0x100 {
    range_ = 0x60
  }
  idx := make([]byte, range_ + 1, context.temp_allocator)
  engine.read_into(handle, index_tbl, idx)
  maxidx := 0
  for b in idx {
    if int(b) > maxidx {
      maxidx = int(b)
    }
  }
  jt := make([]uintptr, maxidx + 1, context.temp_allocator)
  for k in 0 ..< len(jt) {
    jt[k] = read_ptr_at(handle, jump_tbl + uintptr(k * 4), engine.Value_Type.U32)
  }
  for p in 0 ..< len(idx) {
    handler := jt[int(idx[p])]
    if handler < base || handler >= mod_end {
      continue
    }
    // Bound the scan to this case: up to the next case handler in address order (else a fixed window).
    end := handler + 0x140
    for e in jt {
      if e > handler && e < end {
        end = e
      }
    }
    n := int(end - handler)
    if n <= 0 || n > 0x300 {
      n = 0x140
    }
    body := make([]byte, n, context.temp_allocator)
    engine.read_into(handle, handler, body)
    if case_writes_sjump1(body) {
      m := i32(p) - base_n // input index = dwMsg + base_n  =>  dwMsg = p - base_n
      if m > 0 && m < 0x100 {
        return u32(m), true
      }
    }
  }
  return 0, false
}

// True if the case body contains `or r/m32, 0x00005000` (SetJumpState(OBJSTA_SJUMP1)): the imm32 0x5000
// preceded within 8 bytes by an 0x81 (ALU-with-imm32 opcode group).
case_writes_sjump1 :: proc(body: []byte) -> bool {
  for i := 0; i + 4 <= len(body); i += 1 {
    if body[i] == 0x00 && body[i + 1] == 0x50 && body[i + 2] == 0x00 && body[i + 3] == 0x00 {
      lo := i - 8 < 0 ? 0 : i - 8
      for j in lo ..< i {
        if body[j] == 0x81 {
          return true
        }
      }
    }
  }
  return false
}

// ---------------------------------------------------------------------------
// position
// ---------------------------------------------------------------------------

// position (aliases: pos, /position) - print the player's world position, with a copy-paste x,y,z form
// (commas, no spaces) that calibrate / moveto / findpos accept directly.
cli_position :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  pos, ok := read_player_pos(session)
  if !ok {
    fmt.eprintln("couldn't read player position - run 'calibrate' first (need a resolved player).")
    return
  }
  fmt.printfln("position: x=%.3f  y=%.3f  z=%.3f", pos[0], pos[1], pos[2])
  fmt.printfln("copy: %.3f,%.3f,%.3f", pos[0], pos[1], pos[2])
}

// ---------------------------------------------------------------------------
// preconditions + coord parsing + write helpers
// ---------------------------------------------------------------------------

// Shared precondition for moveto: attached, 32-bit client, dest-field offsets configured.
moveto_ready :: proc(session: ^Session) -> bool {
  if !char_control_attached(session) {
    return false
  }
  L := session.layout
  if L.destpos_off == 0 || L.iddest_off == 0 || L.forward_off == 0 {
    fmt.eprintln(
      "moveto not configured: dest-field offsets (destpos_off/iddest_off/forward_off) are unset. Run 'findmove' (or 'set destpos_off 0x38C' etc.).",
    )
    return false
  }
  return true
}

// Shared precondition for jump: attached, 32-bit, sendactmsg_rva sane, actmover_off + jump_msg set.
jump_ready :: proc(session: ^Session) -> bool {
  if !char_control_attached(session) {
    return false
  }
  if !sendactmsg_rva_sane(session) {
    fmt.eprintln(
      "jump not configured: sendactmsg_rva is unset or its prologue doesn't match. Run 'findmove' in-game (or 'set sendactmsg_rva 0x..').",
    )
    return false
  }
  if session.layout.actmover_off == 0 {
    fmt.eprintln("jump not configured: actmover_off (CMover.m_pActMover) is unset. Run 'findmove' (or 'set actmover_off 0x..').")
    return false
  }
  if session.layout.jump_msg == 0 {
    fmt.eprintln("jump not configured: jump_msg (OBJMSG_JUMP) is 0. Seed 'set jump_msg 0x11' or run 'findmove'.")
    return false
  }
  return true
}

char_control_attached :: proc(session: ^Session) -> bool {
  if !session.attached {
    fmt.eprintln("not attached.")
    return false
  }
  if session.ptr_size != 4 {
    fmt.eprintln("character control targets the 32-bit Flyff client; attach the WOW64 Neuz.exe.")
    return false
  }
  return true
}

// Parse 2 or 3 numeric coords from args, accepting "x,z" / "x,y,z" / "x z" / "x y z" (commas or spaces).
// n is the count parsed (2 or 3). ok=false on non-numeric input or a wrong count.
parse_coords :: proc(args: []string) -> (coords: [3]f64, n: int, ok: bool) {
  joined := strings.join(args, " ", context.temp_allocator)
  spaced, _ := strings.replace_all(joined, ",", " ", context.temp_allocator)
  fields := strings.fields(spaced, context.temp_allocator)
  if len(fields) < 2 || len(fields) > 3 {
    return {}, 0, false
  }
  for f, i in fields {
    v, vok := strconv.parse_f64(f)
    if !vok {
      return {}, 0, false
    }
    coords[i] = v
  }
  return coords, len(fields), true
}

// Write a single byte / a vec3 (3x f32, one WriteProcessMemory) into the target. Companion to wr_u32
// (draw.odin). Used by write_dest_pos.
wr_u8 :: proc(handle: win.HANDLE, addr: uintptr, v: u8) -> bool {
  b := [1]byte{v}
  w: uint
  return win.WriteProcessMemory(handle, rawptr(addr), raw_data(b[:]), 1, &w) != win.FALSE && w == 1
}

wr_vec3 :: proc(handle: win.HANDLE, addr: uintptr, v: [3]f32) -> bool {
  b: [12]byte
  put32_le(b[0:], transmute(u32)v[0])
  put32_le(b[4:], transmute(u32)v[1])
  put32_le(b[8:], transmute(u32)v[2])
  w: uint
  return win.WriteProcessMemory(handle, rawptr(addr), raw_data(b[:]), 12, &w) != win.FALSE && w == 12
}
