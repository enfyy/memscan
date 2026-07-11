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
