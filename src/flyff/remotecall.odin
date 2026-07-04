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
