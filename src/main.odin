package main

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import win "core:sys/windows"

Attached_Process :: struct {
  pid:          u32,
  name:         string,
  window_title: string,
  handle:       win.HANDLE,
  base:         uintptr,
  module_size:  u32,
  is_wow64:     bool,
}

Session :: struct {
  attached:      bool,
  proc_info:     Attached_Process,
  vtype:         Value_Type,
  ptr_size:      int,
  writable_only: bool,
  scan_arena:    virtual.Arena,
  has_snapshot:  bool,
  snapshot:      Mem_Snapshot,
  has_matches:   bool,
  matches:       Match_Set,
}

main :: proc() {
  session: Session
  session.vtype = .U32
  session.ptr_size = 8
  session.writable_only = true

  if err := virtual.arena_init_growing(&session.scan_arena); err != .None {
    fmt.eprintln("failed to initialise scan arena")
    return
  }
  defer session_close(&session)

  run_cli(&session)
}

session_scan_allocator :: proc(session: ^Session) -> mem.Allocator {
  return virtual.arena_allocator(&session.scan_arena)
}

// Drops the current match set but keeps any snapshot alive.
session_clear_matches :: proc(session: ^Session) {
  session.has_matches = false
  session.matches = {}
}

// Fully resets the scan working set (matches + snapshot) and reclaims arena memory.
session_reset_scan :: proc(session: ^Session) {
  free_all(virtual.arena_allocator(&session.scan_arena))
  session.has_snapshot = false
  session.has_matches = false
  session.snapshot = {}
  session.matches = {}
}

session_close :: proc(session: ^Session) {
  if session.attached {
    win.CloseHandle(session.proc_info.handle)
  }
  free_all(virtual.arena_allocator(&session.scan_arena))
}
