package flyff

import "core:fmt"
import "../engine"

cli_srvsync :: proc(session: ^Session, args: []string) {
  if len(args) == 0 {
    fmt.printfln("srvsync %s.", session.srvsync_on ? "ON" : "OFF")
    return
  }
  if args[0] == "off" || args[0] == "stop" {
    session.srvsync_on = false
    fmt.println("srvsync OFF.")
    return
  }
  if args[0] == "on" {
    if !srvsync_ready(session) {
      return
    }
    session.srvsync_on = true
    fmt.println("srvsync ON: each select now also sends the client's own SendSetTarget(objid, 2).")
    return
  }
  fmt.eprintln("usage: srvsync [on|off]")
}

// srvtest -> fire exactly ONE SendSetTarget at the currently-focused mob and report the result.
// The minimal PoC: select a mob (target_closest / a click), then 'srvtest' and watch whether the
// session survives past the usual ~5-min kill-count DC.
cli_srvtest :: proc(session: ^Session, args: []string) {
  if !srvsync_ready(session) {
    return
  }
  focus, fok := read_focus_ptr(session)
  if !fok || focus == 0 {
    fmt.eprintln("no mob focused - select one first (e.g. 'target_closest <name>' or click it).")
    return
  }
  idv, idok := engine.read_value(session.proc_info.handle, focus + uintptr(session.layout.objid_off), .U32)
  objid := idok ? u32(engine.value_as_u64(.U32, idv)) : 0
  ok := notify_server_target(session, focus)
  fmt.printfln("srvtest: SendSetTarget(objid=%d, 2) for obj=0x%X -> %s", objid, focus, ok ? "sent" : "FAILED")
}

// Shared precondition check for srvsync/srvtest: attached, 32-bit client, Phase-0 constants baked.
srvsync_ready :: proc(session: ^Session) -> bool {
  if !session.attached {
    fmt.eprintln("not attached.")
    return false
  }
  if session.layout.sendsettarget_rva == 0 || session.layout.objid_off == 0 {
    fmt.eprintln(
      "not configured: sendsettarget_rva / objid_off are still 0. 'set sendsettarget_rva 0x190AA0' and 'set objid_off 0x2F0' (SoM values; re-find via disasm after a patch).",
    )
    return false
  }
  if session.ptr_size != 4 {
    fmt.eprintln("srvsync targets the 32-bit Flyff client; attach the WOW64 Neuz.exe.")
    return false
  }
  return true
}

// Read-only: list movers named <name> by distance with HP and model-pointer validity.
// Never writes focus. Handy to see what target_closest will/won't consider selectable.
