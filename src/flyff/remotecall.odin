package flyff
import "../engine"

import "core:fmt"
import win "core:sys/windows"

put32_le :: proc(b: []byte, v: u32) {
  b[0] = byte(v)
  b[1] = byte(v >> 8)
  b[2] = byte(v >> 16)
  b[3] = byte(v >> 24)
}

// Fixed 32-bit shim that calls SoM's SendSetTarget(idTarget, bClear=2) - a free __stdcall (ret 8), so
// the `mov ecx` is a harmless no-op the callee ignores. The shim is 32-bit on purpose: Neuz is WOW64,
// so a CreateRemoteThread'd thread runs in 32-bit mode even though memscan is x64.
//   B9 00000000   mov ecx, 0          (ignored)
//   68 02000000   push 2              (bClear)
//   68 <objid>    push idTarget       (patched per send; imm at SRV_SHIM_ID_OFF)
//   B8 <fn>       mov eax, SendSetTarget
//   FF D0         call eax
//   C2 04 00      ret 4               (clean the stdcall lpParameter the thread got)
SRV_SHIM_LEN :: 25
SRV_SHIM_ID_OFF :: 11

// Cached hot-path sender. On first use it allocates ONE RWX page in the target and writes the shim;
// every later send only rewrites the 4-byte idTarget and re-runs the thread - no VirtualAllocEx /
// full WriteProcessMemory / VirtualFreeEx per kill (cuts the per-advance AC/alloc churn). Serialized
// by the caller (exec_mutex), so there's no page-reuse race. Returns true if the thread completed.
remote_send_settarget :: proc(session: ^Session, objid: u32) -> bool {
  handle := session.proc_info.handle
  fn := u32(session.proc_info.base + session.layout.sendsettarget_rva)

  if session.srv_shim == 0 {
    shim: [SRV_SHIM_LEN]byte
    shim[0] = 0xB9 // mov ecx, 0
    shim[5] = 0x68 // push 2
    put32_le(shim[6:], 2)
    shim[10] = 0x68 // push <objid> (patched below/per call)
    put32_le(shim[11:], objid)
    shim[15] = 0xB8 // mov eax, fn
    put32_le(shim[16:], fn)
    shim[20] = 0xFF
    shim[21] = 0xD0 // call eax
    shim[22] = 0xC2
    shim[23] = 0x04
    shim[24] = 0x00 // ret 4
    page := win.VirtualAllocEx(handle, nil, SRV_SHIM_LEN, win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_EXECUTE_READWRITE)
    if page == nil {
      fmt.eprintfln("VirtualAllocEx (shim) failed (error %d)", win.GetLastError())
      return false
    }
    written: uint
    if win.WriteProcessMemory(handle, page, raw_data(shim[:]), SRV_SHIM_LEN, &written) == win.FALSE ||
       written != SRV_SHIM_LEN {
      fmt.eprintfln("WriteProcessMemory (shim) failed (error %d)", win.GetLastError())
      win.VirtualFreeEx(handle, page, 0, win.MEM_RELEASE)
      return false
    }
    session.srv_shim = uintptr(page)
  } else {
    // reuse: just patch the idTarget imm32 in place
    idb: [4]byte
    put32_le(idb[:], objid)
    w: uint
    if win.WriteProcessMemory(handle, rawptr(session.srv_shim + SRV_SHIM_ID_OFF), raw_data(idb[:]), 4, &w) ==
       win.FALSE {
      return false
    }
  }

  th := win.CreateRemoteThread(
    handle,
    nil,
    0,
    transmute(proc "system" (rawptr) -> win.DWORD)rawptr(session.srv_shim),
    nil,
    0,
    nil,
  )
  if th == nil {
    fmt.eprintfln("CreateRemoteThread failed (error %d)", win.GetLastError())
    return false
  }
  wait := win.WaitForSingleObject(th, 5000)
  win.CloseHandle(th)
  if wait != win.WAIT_OBJECT_0 {
    // Thread hung; can't safely reuse/free the page under it, so orphan it (leak) and re-allocate
    // fresh next time rather than risk a reuse race.
    fmt.eprintln("remote send thread did not finish in 5s; re-allocating the shim next send.")
    session.srv_shim = 0
    return false
  }
  return true
}

// Free the cached shim page (call while still attached, handle valid). Idempotent.
remote_free_shim :: proc(session: ^Session) {
  if session.srv_shim != 0 && session.attached {
    win.VirtualFreeEx(session.proc_info.handle, rawptr(session.srv_shim), 0, win.MEM_RELEASE)
  }
  session.srv_shim = 0
}

// --- Mesh-accurate reach via the client's own CWorld::IntersectObjLine -------------------------
// Fixed page layout (allocated once, reused per query): input vectors, a callee-written intersect
// point, our captured return slot, then the shim.
OBJLINE_VPOS_OFF :: 0x00 // D3DXVECTOR3 vPos (input, segment start)
OBJLINE_VEND_OFF :: 0x0C // D3DXVECTOR3 vEnd (input, segment end)
OBJLINE_POUT_OFF :: 0x18 // D3DXVECTOR3 pOut (callee writes the hit point; we don't read it)
OBJLINE_RES_OFF :: 0x24 // u32 result: the BOOL eax (TRUE = segment hit something)
OBJLINE_CODE_OFF :: 0x28 // shim code start
OBJLINE_PAGE_LEN :: 0x80

// Verify the function prologue at intersectobjline_rva before calling it, so a patch-shifted (stale)
// RVA refuses instead of jumping into wrong code and crashing the client. Prologue is
// `55 8B EC 83 E4 F0 B8` (push ebp; mov ebp,esp; and esp,-16; mov eax,imm) - the aligned-frame +
// __chkstk opener; the imm (frame size) is left out since it can shift build-to-build.
intersectobjline_rva_sane :: proc(session: ^Session) -> bool {
  if session.layout.intersectobjline_rva == 0 || session.ptr_size != 4 {
    return false
  }
  want := [?]byte{0x55, 0x8B, 0xEC, 0x83, 0xE4, 0xF0, 0xB8}
  buf: [7]byte
  n, ok := engine.read_into(session.proc_info.handle, session.proc_info.base + session.layout.intersectobjline_rva, buf[:])
  if !ok || int(n) < len(want) {
    return false
  }
  for b, i in want {
    if buf[i] != b {
      return false
    }
  }
  return true
}

// Call the client's own CWorld::IntersectObjLine(pOut,&v1,&v2,FALSE,bWithTerrain,bWithObject) from an
// injected thread: ground-truth OBB + triangle-mesh line test, the exact routine the game uses. Returns
// blocked=TRUE when the segment v1->v2 hits terrain/object per the flags. ok=false when disabled/unsafe
// (RVA unset or prologue mismatch) or the thread didn't finish. Serialise via exec_mutex. WARNING: runs
// game code that walks the world linkmaps from another thread - the same small main-thread race as the
// settarget/particle injections.
remote_intersect_objline :: proc(session: ^Session, world: uintptr, v1, v2: [3]f32, with_terrain, with_object: bool) -> (blocked: bool, ok: bool) {
  if world == 0 || !intersectobjline_rva_sane(session) {
    return
  }
  handle := session.proc_info.handle
  fn := u32(session.proc_info.base + session.layout.intersectobjline_rva)

  if session.objline_page == 0 {
    page := win.VirtualAllocEx(handle, nil, OBJLINE_PAGE_LEN, win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_EXECUTE_READWRITE)
    if page == nil {
      fmt.eprintfln("VirtualAllocEx (objline) failed (error %d)", win.GetLastError())
      return
    }
    session.objline_page = uintptr(page)
  }
  page := session.objline_page
  P := u32(page)

  buf: [OBJLINE_PAGE_LEN]byte
  put32_le(buf[OBJLINE_VPOS_OFF:], transmute(u32)v1[0])
  put32_le(buf[OBJLINE_VPOS_OFF + 4:], transmute(u32)v1[1])
  put32_le(buf[OBJLINE_VPOS_OFF + 8:], transmute(u32)v1[2])
  put32_le(buf[OBJLINE_VEND_OFF:], transmute(u32)v2[0])
  put32_le(buf[OBJLINE_VEND_OFF + 4:], transmute(u32)v2[1])
  put32_le(buf[OBJLINE_VEND_OFF + 8:], transmute(u32)v2[2])
  // OBJLINE_RES_OFF stays 0 (buf is zero-initialised) until the shim stores eax.

  // Args are pushed right-to-left; the callee (ret 0x18) cleans its own 6 args, then our `ret 4` cleans
  // the thread's lpParameter. ecx = CWorld* this.
  c := OBJLINE_CODE_OFF
  buf[c] = 0xB9;put32_le(buf[c + 1:], u32(world));c += 5 // mov ecx, world
  buf[c] = 0x6A;buf[c + 1] = with_object ? 1 : 0;c += 2 // push bWithObject
  buf[c] = 0x6A;buf[c + 1] = with_terrain ? 1 : 0;c += 2 // push bWithTerrain
  buf[c] = 0x6A;buf[c + 1] = 0x00;c += 2 // push bSkipTrans = FALSE
  buf[c] = 0x68;put32_le(buf[c + 1:], P + OBJLINE_VEND_OFF);c += 5 // push &vEnd
  buf[c] = 0x68;put32_le(buf[c + 1:], P + OBJLINE_VPOS_OFF);c += 5 // push &vPos
  buf[c] = 0x68;put32_le(buf[c + 1:], P + OBJLINE_POUT_OFF);c += 5 // push pOut
  buf[c] = 0xB8;put32_le(buf[c + 1:], fn);c += 5 // mov eax, IntersectObjLine
  buf[c] = 0xFF;buf[c + 1] = 0xD0;c += 2 // call eax
  buf[c] = 0xA3;put32_le(buf[c + 1:], P + OBJLINE_RES_OFF);c += 5 // mov [result], eax
  buf[c] = 0xC2;buf[c + 1] = 0x04;buf[c + 2] = 0x00 // ret 4

  written: uint
  if win.WriteProcessMemory(handle, rawptr(page), raw_data(buf[:]), OBJLINE_PAGE_LEN, &written) == win.FALSE ||
     written != OBJLINE_PAGE_LEN {
    fmt.eprintfln("WriteProcessMemory (objline) failed (error %d)", win.GetLastError())
    return
  }
  start := transmute(proc "system" (rawptr) -> win.DWORD)rawptr(page + uintptr(OBJLINE_CODE_OFF))
  th := win.CreateRemoteThread(handle, nil, 0, start, nil, 0, nil)
  if th == nil {
    fmt.eprintfln("CreateRemoteThread (objline) failed (error %d)", win.GetLastError())
    return
  }
  wait := win.WaitForSingleObject(th, 5000)
  win.CloseHandle(th)
  if wait != win.WAIT_OBJECT_0 {
    fmt.eprintln("objline thread did not finish in 5s; leaking its page for safety.")
    session.objline_page = 0
    return
  }
  rv, rok := engine.read_value(handle, page + uintptr(OBJLINE_RES_OFF), .U32)
  if !rok {
    return
  }
  blocked = engine.value_as_u64(.U32, rv) != 0
  ok = true
  return
}

// Free the cached IntersectObjLine page (call while attached, handle valid). Idempotent.
remote_free_objline_page :: proc(session: ^Session) {
  if session.objline_page != 0 && session.attached {
    win.VirtualFreeEx(session.proc_info.handle, rawptr(session.objline_page), 0, win.MEM_RELEASE)
  }
  session.objline_page = 0
}

// --- In-world debug markers via the client's own particle system -------------------------------
// CParticleMng layout (from disasm of CParticleMng::CreateParticle, see flyff-particle-draw.md):
//   m_pd3dDevice at g_ParticleMng+0x0, m_Particles[0] at +0x8, sizeof(CParticles)=0x3C, m_bActive +0x2C.
PARTICLE_CPARTICLES_SIZE :: 0x3C
PARTICLE_MPARTICLES_OFF :: 0x8
PARTICLE_BACTIVE_OFF :: 0x2C
PARTICLE_MAX_TYPE :: 32

// True if particle type `ntype` is already initialised in the client (m_bActive != 0). We only ever
// spawn warm types: a COLD type's first CreateParticle does off-thread D3D texture/VB creation, which
// races the render thread far worse than the (already present) linked-list race. Read-only.
particle_type_active :: proc(session: ^Session, ntype: int) -> bool {
  if ntype < 0 || ntype >= PARTICLE_MAX_TYPE || session.layout.particlemng_rva == 0 {
    return false
  }
  addr :=
    session.proc_info.base +
    session.layout.particlemng_rva +
    uintptr(PARTICLE_MPARTICLES_OFF + ntype * PARTICLE_CPARTICLES_SIZE + PARTICLE_BACTIVE_OFF)
  v, ok := engine.read_value(session.proc_info.handle, addr, .U32)
  return ok && engine.value_as_u64(.U32, v) != 0
}

// Cheap validity check for the particle RVAs, run BEFORE any injected CreateParticle call. A game patch
// shifts particlemng_rva / createparticle_rva, and calling a stale createparticle_rva jumps into a wrong
// address = instant client crash (a real incident). A patch moves both together, so we validate the
// cheap, read-only one, particlemng_rva, two ways (a zeroed stale region passes the m_bActive test alone,
// so the device-pointer check is the real guard). Returns false when unconfigured. Fix: findparticle.
particle_rvas_sane :: proc(session: ^Session) -> bool {
  if session.layout.particlemng_rva == 0 || session.layout.createparticle_rva == 0 {
    return false
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  // 1. m_pd3dDevice (g_ParticleMng+0) must be a live heap pointer: non-null, outside the module, and
  //    itself pointing at readable memory. A stale/zeroed particlemng reads 0 here - the reliable tell.
  dv, dok := engine.read_value(handle, base + session.layout.particlemng_rva, .U32)
  if !dok {
    return false
  }
  dev := uintptr(engine.value_as_u64(.U32, dv))
  if dev < 0x10000 || (dev >= base && dev < mod_end) {
    return false
  }
  if _, ok := engine.read_value(handle, dev, .U32); !ok {
    return false // the device pointer doesn't resolve -> particlemng_rva is wrong
  }
  // 2. Every particle type's m_bActive must read as a clean 0/1 boolean; anything else = wrong struct.
  for t in 0 ..< PARTICLE_MAX_TYPE {
    v, ok := engine.read_value(
      handle,
      base + session.layout.particlemng_rva + uintptr(PARTICLE_MPARTICLES_OFF + t * PARTICLE_CPARTICLES_SIZE + PARTICLE_BACTIVE_OFF),
      .U32,
    )
    if !ok || engine.value_as_u64(.U32, v) > 1 {
      return false
    }
  }
  return true
}

// Bytes of shim code emitted per particle (see the unrolled block below).
SPAWN_CODE_PER :: 32
// Minimum cached page size, so typical batches reuse the page instead of realloc'ing every refresh.
SPAWN_PAGE_MIN :: 64 * 1024

// Single-colour convenience wrapper: spawn every position as particle type `ntype`.
remote_spawn_particles :: proc(session: ^Session, ntype: int, positions: [][3]f32) -> bool {
  types := make([]int, len(positions), context.temp_allocator)
  for i in 0 ..< len(positions) {
    types[i] = ntype
  }
  return remote_spawn_particles_typed(session, positions, types)
}

// Drop a soft billboard dot of colour types[i] at positions[i] by calling the client's own
// CParticleMng::CreateParticle(type, &vPos, &vVel=0, fGroundY=y) from ONE injected thread (all spawns
// unrolled), so a whole batch - any mix of colours - is a single injection event. Dots fade over ~1s;
// vVel=0 holds them put. The callee folds &g_ParticleMng as an absolute so ecx is a don't-care (set
// anyway, harmless); it cleans its 4 stack args itself (ret 0x10). Caller MUST verify each type is
// warm (particle_type_active) so this never triggers off-thread device init. Serialise via exec_mutex.
// The RWX page is cached on the Session and reused/grown across calls (no per-refresh alloc churn).
// WARNING: mutates the particle linked list the render thread walks each frame - small race window.
remote_spawn_particles_typed :: proc(session: ^Session, positions: [][3]f32, types: []int) -> bool {
  n := len(positions)
  if n == 0 {
    return true
  }
  if len(types) != n {
    return false
  }
  if session.layout.particlemng_rva == 0 || session.layout.createparticle_rva == 0 || session.ptr_size != 4 {
    return false
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  g_pm := u32(base + session.layout.particlemng_rva)
  fn := u32(base + session.layout.createparticle_rva)

  // Page layout: [vVel(3xf32=0)] [pos array (n * 3xf32)] [code (n * SPAWN_CODE_PER + ret 4)].
  vvel_off := 0
  pos_arr_off := 12
  code_off := pos_arr_off + n * 12
  code_off = (code_off + 3) &~ 3 // 4-byte align the code
  total := uint(code_off + n * SPAWN_CODE_PER + 3)

  // Reuse the cached page if it's big enough; otherwise (re)allocate, keeping a generous minimum.
  if session.spawn_page == 0 || session.spawn_page_size < total {
    if session.spawn_page != 0 {
      win.VirtualFreeEx(handle, rawptr(session.spawn_page), 0, win.MEM_RELEASE)
      session.spawn_page = 0
      session.spawn_page_size = 0
    }
    want := total
    if want < SPAWN_PAGE_MIN {
      want = SPAWN_PAGE_MIN
    }
    page := win.VirtualAllocEx(handle, nil, want, win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_EXECUTE_READWRITE)
    if page == nil {
      fmt.eprintfln("VirtualAllocEx (particle) failed (error %d)", win.GetLastError())
      return false
    }
    session.spawn_page = uintptr(page)
    session.spawn_page_size = want
  }
  page := session.spawn_page

  buf := make([]byte, total, context.temp_allocator)
  P := u32(page)
  // vVel stays {0,0,0}. Write the position array.
  for pos, i in positions {
    o := pos_arr_off + i * 12
    put32_le(buf[o:], transmute(u32)pos[0])
    put32_le(buf[o + 4:], transmute(u32)pos[1])
    put32_le(buf[o + 8:], transmute(u32)pos[2])
  }
  // Emit one call block per particle. CreateParticle(type, &vPos, &vVel, fGroundY) - cdecl-style args
  // pushed right-to-left; the callee's `ret 0x10` rebalances the stack after each call.
  c := code_off
  for pos, i in positions {
    pos_addr := P + u32(pos_arr_off + i * 12)
    vvel_addr := P + u32(vvel_off)
    ground := transmute(u32)pos[1]
    buf[c] = 0xB9;put32_le(buf[c + 1:], g_pm);c += 5 // mov ecx, g_ParticleMng
    buf[c] = 0x68;put32_le(buf[c + 1:], ground);c += 5 // push fGroundY
    buf[c] = 0x68;put32_le(buf[c + 1:], vvel_addr);c += 5 // push &vVel
    buf[c] = 0x68;put32_le(buf[c + 1:], pos_addr);c += 5 // push &vPos
    buf[c] = 0x68;put32_le(buf[c + 1:], u32(types[i]));c += 5 // push type
    buf[c] = 0xB8;put32_le(buf[c + 1:], fn);c += 5 // mov eax, CreateParticle
    buf[c] = 0xFF;buf[c + 1] = 0xD0;c += 2 // call eax
  }
  buf[c] = 0xC2;buf[c + 1] = 0x04;buf[c + 2] = 0x00 // ret 4 (clean the thread lpParameter)

  written: uint
  if win.WriteProcessMemory(handle, rawptr(page), raw_data(buf), total, &written) == win.FALSE ||
     written != total {
    fmt.eprintfln("WriteProcessMemory (particle) failed (error %d)", win.GetLastError())
    return false
  }

  start := transmute(proc "system" (rawptr) -> win.DWORD)rawptr(page + uintptr(code_off))
  th := win.CreateRemoteThread(handle, nil, 0, start, nil, 0, nil)
  if th == nil {
    fmt.eprintfln("CreateRemoteThread (particle) failed (error %d)", win.GetLastError())
    return false
  }
  wait := win.WaitForSingleObject(th, 5000)
  win.CloseHandle(th)
  if wait != win.WAIT_OBJECT_0 {
    // Thread still running: the page may be executing. Drop our cache ref (leak it) and realloc next.
    fmt.eprintln("particle spawn thread did not finish in 5s; leaking its page for safety.")
    session.spawn_page = 0
    session.spawn_page_size = 0
    return false
  }
  return true
}

// Free the cached particle-spawn page (call while attached, handle valid). Idempotent.
remote_free_spawn_page :: proc(session: ^Session) {
  if session.spawn_page != 0 && session.attached {
    win.VirtualFreeEx(session.proc_info.handle, rawptr(session.spawn_page), 0, win.MEM_RELEASE)
  }
  session.spawn_page = 0
  session.spawn_page_size = 0
}

// Tell the server which mob we're attacking by making the client emit its OWN SendSetTarget - the
// exact call the click path makes (`push 2; push [pObj+0x2F0]; call SendSetTarget`). idTarget = the
// mover's network id at obj+objid_off (0x2F0 in SoM). The client does framing/CRC/g_DPlay itself, so
// the packet is byte-identical to a real click. No-op until sendsettarget_rva/objid_off are set.
notify_server_target :: proc(session: ^Session, obj: uintptr) -> bool {
  if session.layout.sendsettarget_rva == 0 || session.layout.objid_off == 0 {
    return false
  }
  if session.ptr_size != 4 {
    return false // 32-bit Flyff client only
  }
  idv, idok := engine.read_value(session.proc_info.handle, obj + uintptr(session.layout.objid_off), .U32)
  if !idok {
    return false
  }
  objid := u32(engine.value_as_u64(.U32, idv))
  if objid == 0 {
    return false
  }
  return remote_send_settarget(session, objid)
}

// --- Character control: jump via an injected SendActMsg call -------------------------------------
// jump calls a client thiscall member from a CreateRemoteThread'd 32-bit thread, the same mechanism as
// the settarget/objline injections. (moveto is a pure field-write - no injection - since SetDestPos is
// inlined in this build; see move.odin.) See flyff.odin for the RVA/offset config.

ACTMSG_RES_OFF :: 0x00 // u32 result: SendActMsg's int return (1 = message accepted; else a guard code)
ACTMSG_CODE_OFF :: 0x08 // shim code start
ACTMSG_PAGE_LEN :: 0x40

// Guard for an injected client call: RVA set, client 32-bit, and the bytes at base+rva match an expected
// function prologue - so a patch-shifted (stale) RVA refuses instead of jumping into wrong code and
// crashing the client. Same idea as intersectobjline_rva_sane.
rva_prologue_ok :: proc(session: ^Session, rva: uintptr, want: []byte) -> bool {
  if rva == 0 || session.ptr_size != 4 || len(want) == 0 {
    return false
  }
  buf: [16]byte
  if len(want) > len(buf) {
    return false
  }
  n, ok := engine.read_into(session.proc_info.handle, session.proc_info.base + rva, buf[:len(want)])
  if !ok || int(n) < len(want) {
    return false
  }
  for b, i in want {
    if buf[i] != b {
      return false
    }
  }
  return true
}

// CActionMover::SendActMsg opens with a distinctive 7-byte signature: `push ebp; mov ebp,esp;
// test byte [ecx+8],8` (55 8B EC F6 41 08 08). Checking it (not just the generic 55 8B EC) both guards a
// stale RVA and confirms findmove picked the right vtable slot. Adjust these bytes if a patch recompiles it.
SENDACTMSG_SIG := [?]byte{0x55, 0x8B, 0xEC, 0xF6, 0x41, 0x08, 0x08}

sendactmsg_rva_sane :: proc(session: ^Session) -> bool {
  return rva_prologue_ok(session, session.layout.sendactmsg_rva, SENDACTMSG_SIG[:])
}

// Send an act-message to the player by calling the client's own
// CActionMover::SendActMsg(dwMsg, 0,0,0,0) from an injected thread, with ecx = CMover.m_pActMover (the
// real callable body - CMover::SendActMsg is an inline forwarder). Used for jump (dwMsg = jump_msg); the
// in-client guards (grounded / not casting/attacking/sitting / not NOMOVE) run as normal and the handler's
// int return is captured (1 = accepted, else the code for the guard that blocked it). ok=false when
// disabled/unsafe, the player/actmover is unresolved, or the thread didn't finish. Serialise via exec_mutex.
remote_send_actmsg :: proc(session: ^Session, msg: u32) -> (ret: i32, ok: bool) {
  if !sendactmsg_rva_sane(session) {
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  player := read_ptr_at(handle, base + session.layout.player_rva, engine.Value_Type.U32)
  if player == 0 {
    return
  }
  actmover := read_ptr_at(handle, player + uintptr(session.layout.actmover_off), engine.Value_Type.U32)
  if actmover == 0 {
    return
  }
  fn := u32(base + session.layout.sendactmsg_rva)

  if session.actmsg_page == 0 {
    page := win.VirtualAllocEx(handle, nil, ACTMSG_PAGE_LEN, win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_EXECUTE_READWRITE)
    if page == nil {
      fmt.eprintfln("VirtualAllocEx (actmsg) failed (error %d)", win.GetLastError())
      return
    }
    session.actmsg_page = uintptr(page)
  }
  page := session.actmsg_page
  P := u32(page)

  buf: [ACTMSG_PAGE_LEN]byte
  // ACTMSG_RES_OFF stays 0 (buf is zero-initialised) until the shim stores eax.
  // thiscall: ecx = m_pActMover (CActionMover*); CActionMover::SendActMsg takes SIX stack args
  // (dwMsg + nParam1..nParam5) and cleans them itself (ret 0x18); then our `ret 4` cleans the injected
  // thread's lpParameter. Args pushed right-to-left, so dwMsg is pushed last.
  c := ACTMSG_CODE_OFF
  buf[c] = 0xB9;put32_le(buf[c + 1:], u32(actmover));c += 5 // mov ecx, m_pActMover
  buf[c] = 0x6A;buf[c + 1] = 0x00;c += 2 // push 0  (nParam5)
  buf[c] = 0x6A;buf[c + 1] = 0x00;c += 2 // push 0  (nParam4)
  buf[c] = 0x6A;buf[c + 1] = 0x00;c += 2 // push 0  (nParam3)
  buf[c] = 0x6A;buf[c + 1] = 0x00;c += 2 // push 0  (nParam2)
  buf[c] = 0x6A;buf[c + 1] = 0x00;c += 2 // push 0  (nParam1)
  buf[c] = 0x68;put32_le(buf[c + 1:], msg);c += 5 // push dwMsg
  buf[c] = 0xB8;put32_le(buf[c + 1:], fn);c += 5 // mov eax, SendActMsg
  buf[c] = 0xFF;buf[c + 1] = 0xD0;c += 2 // call eax
  buf[c] = 0xA3;put32_le(buf[c + 1:], P + ACTMSG_RES_OFF);c += 5 // mov [result], eax
  buf[c] = 0xC2;buf[c + 1] = 0x04;buf[c + 2] = 0x00 // ret 4

  written: uint
  if win.WriteProcessMemory(handle, rawptr(page), raw_data(buf[:]), ACTMSG_PAGE_LEN, &written) == win.FALSE ||
     written != ACTMSG_PAGE_LEN {
    fmt.eprintfln("WriteProcessMemory (actmsg) failed (error %d)", win.GetLastError())
    return
  }
  start := transmute(proc "system" (rawptr) -> win.DWORD)rawptr(page + uintptr(ACTMSG_CODE_OFF))
  th := win.CreateRemoteThread(handle, nil, 0, start, nil, 0, nil)
  if th == nil {
    fmt.eprintfln("CreateRemoteThread (actmsg) failed (error %d)", win.GetLastError())
    return
  }
  wait := win.WaitForSingleObject(th, 5000)
  win.CloseHandle(th)
  if wait != win.WAIT_OBJECT_0 {
    fmt.eprintln("actmsg thread did not finish in 5s; leaking its page for safety.")
    session.actmsg_page = 0
    return
  }
  rv, rok := engine.read_value(handle, page + uintptr(ACTMSG_RES_OFF), .U32)
  if !rok {
    return
  }
  ret = i32(u32(engine.value_as_u64(.U32, rv)))
  ok = true
  return
}

// Free the cached actmsg page (call while attached, handle valid). Idempotent.
remote_free_actmsg_page :: proc(session: ^Session) {
  if session.actmsg_page != 0 && session.attached {
    win.VirtualFreeEx(session.proc_info.handle, rawptr(session.actmsg_page), 0, win.MEM_RELEASE)
  }
  session.actmsg_page = 0
}

// --- moveto server-sync: flush the destpos to the server via g_DPlay.SendSnapshot(TRUE) --------------
DPLAY_PAGE_LEN :: 0x40

// SendSnapshot's prologue (push ebp; mov ebp,esp) - checked before the call so a stale RVA no-ops.
sendsnapshot_rva_sane :: proc(session: ^Session) -> bool {
  want := [?]byte{0x55, 0x8B, 0xEC}
  return rva_prologue_ok(session, session.layout.sendsnapshot_rva, want[:])
}

// Inject g_DPlay.SendSnapshot(TRUE) so the destpos moveto wrote into m_ss.playerdestpos is broadcast to
// the server as SNAPSHOTTYPE_DESTPOS - the immediate flush a ground click does (the client's own periodic
// snapshot won't push an externally-set fValid). thiscall: ecx=&g_DPlay (the body folds g_DPlay absolute,
// so ecx is belt-and-suspenders), 1 arg (fUnconditional=TRUE), callee ret 4; our ret 4 cleans lpParameter.
// ok=false when disabled/unsafe or the thread didn't finish. Serialise via exec_mutex.
remote_send_snapshot :: proc(session: ^Session) -> bool {
  if !sendsnapshot_rva_sane(session) || session.layout.gdplay_rva == 0 {
    return false
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  gd := u32(base + session.layout.gdplay_rva)
  fn := u32(base + session.layout.sendsnapshot_rva)

  if session.dplay_page == 0 {
    page := win.VirtualAllocEx(handle, nil, DPLAY_PAGE_LEN, win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_EXECUTE_READWRITE)
    if page == nil {
      fmt.eprintfln("VirtualAllocEx (snapshot) failed (error %d)", win.GetLastError())
      return false
    }
    session.dplay_page = uintptr(page)
  }
  page := session.dplay_page

  buf: [DPLAY_PAGE_LEN]byte
  c := 0
  buf[c] = 0xB9;put32_le(buf[c + 1:], gd);c += 5 // mov ecx, g_DPlay
  buf[c] = 0x6A;buf[c + 1] = 0x01;c += 2 // push 1  (fUnconditional = TRUE)
  buf[c] = 0xB8;put32_le(buf[c + 1:], fn);c += 5 // mov eax, SendSnapshot
  buf[c] = 0xFF;buf[c + 1] = 0xD0;c += 2 // call eax
  buf[c] = 0xC2;buf[c + 1] = 0x04;buf[c + 2] = 0x00 // ret 4

  written: uint
  if win.WriteProcessMemory(handle, rawptr(page), raw_data(buf[:]), DPLAY_PAGE_LEN, &written) == win.FALSE ||
     written != DPLAY_PAGE_LEN {
    fmt.eprintfln("WriteProcessMemory (snapshot) failed (error %d)", win.GetLastError())
    return false
  }
  start := transmute(proc "system" (rawptr) -> win.DWORD)rawptr(page)
  th := win.CreateRemoteThread(handle, nil, 0, start, nil, 0, nil)
  if th == nil {
    fmt.eprintfln("CreateRemoteThread (snapshot) failed (error %d)", win.GetLastError())
    return false
  }
  wait := win.WaitForSingleObject(th, 5000)
  win.CloseHandle(th)
  if wait != win.WAIT_OBJECT_0 {
    fmt.eprintln("snapshot thread did not finish in 5s; leaking its page for safety.")
    session.dplay_page = 0
    return false
  }
  return true
}

// SendPlayerMoved's prologue (push ebp; mov ebp,esp) - checked before the call so a stale RVA no-ops.
sendplayermoved_rva_sane :: proc(session: ^Session) -> bool {
  want := [?]byte{0x55, 0x8B, 0xEC}
  return rva_prologue_ok(session, session.layout.sendplayermoved_rva, want[:])
}

// jump SERVER-SYNC: inject the client's own local-player state sender (SendPlayerMoved-style) so the jump
// STATE that SendActMsg set locally is broadcast - otherwise other clients don't see the jump. thiscall:
// ecx=&g_DPlay, 1 arg = the player CMover* (the callee bails unless it == g_pPlayer), callee ret 4; our
// ret 4 cleans lpParameter. Reuses dplay_page (jump/moveto never overlap). ok=false when disabled/unsafe.
remote_send_playermoved :: proc(session: ^Session) -> bool {
  if !sendplayermoved_rva_sane(session) || session.layout.gdplay_rva == 0 {
    return false
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  player := read_ptr_at(handle, base + session.layout.player_rva, engine.Value_Type.U32)
  if player == 0 {
    return false
  }
  gd := u32(base + session.layout.gdplay_rva)
  fn := u32(base + session.layout.sendplayermoved_rva)

  if session.dplay_page == 0 {
    page := win.VirtualAllocEx(handle, nil, DPLAY_PAGE_LEN, win.MEM_COMMIT | win.MEM_RESERVE, win.PAGE_EXECUTE_READWRITE)
    if page == nil {
      fmt.eprintfln("VirtualAllocEx (playermoved) failed (error %d)", win.GetLastError())
      return false
    }
    session.dplay_page = uintptr(page)
  }
  page := session.dplay_page

  buf: [DPLAY_PAGE_LEN]byte
  c := 0
  buf[c] = 0xB9;put32_le(buf[c + 1:], gd);c += 5 // mov ecx, g_DPlay
  buf[c] = 0x68;put32_le(buf[c + 1:], u32(player));c += 5 // push player (CMover*)
  buf[c] = 0xB8;put32_le(buf[c + 1:], fn);c += 5 // mov eax, SendPlayerMoved
  buf[c] = 0xFF;buf[c + 1] = 0xD0;c += 2 // call eax
  buf[c] = 0xC2;buf[c + 1] = 0x04;buf[c + 2] = 0x00 // ret 4

  written: uint
  if win.WriteProcessMemory(handle, rawptr(page), raw_data(buf[:]), DPLAY_PAGE_LEN, &written) == win.FALSE ||
     written != DPLAY_PAGE_LEN {
    fmt.eprintfln("WriteProcessMemory (playermoved) failed (error %d)", win.GetLastError())
    return false
  }
  start := transmute(proc "system" (rawptr) -> win.DWORD)rawptr(page)
  th := win.CreateRemoteThread(handle, nil, 0, start, nil, 0, nil)
  if th == nil {
    fmt.eprintfln("CreateRemoteThread (playermoved) failed (error %d)", win.GetLastError())
    return false
  }
  wait := win.WaitForSingleObject(th, 5000)
  win.CloseHandle(th)
  if wait != win.WAIT_OBJECT_0 {
    fmt.eprintln("playermoved thread did not finish in 5s; leaking its page for safety.")
    session.dplay_page = 0
    return false
  }
  return true
}

// Free the cached g_DPlay-call page (call while attached, handle valid). Idempotent.
remote_free_dplay_page :: proc(session: ^Session) {
  if session.dplay_page != 0 && session.attached {
    win.VirtualFreeEx(session.proc_info.handle, rawptr(session.dplay_page), 0, win.MEM_RELEASE)
  }
  session.dplay_page = 0
}
