package flyff

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:sync"
import win "core:sys/windows"
import "../engine"

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
  vtype:         engine.Value_Type,
  ptr_size:      int,
  writable_only: bool,

  // Live Flyff memory layout (RVAs + offsets). Seeded from flyff_layout_default(), overwritten
  // by flyff.cfg on attach, re-derived by `calibrate`. See flyff.odin Flyff_Layout / layout.odin.
  layout:        Flyff_Layout,
  scan_arena:    virtual.Arena,
  has_snapshot:  bool,
  snapshot:      engine.Mem_Snapshot,
  has_matches:   bool,
  matches:       engine.Match_Set,
  targets:       [dynamic]engine.Nearest_Entry, // last 'nearest' result, sorted by distance
  tc_recent:     [dynamic]TC_Recent, // objs target_closest picked recently (skip just-killed)

  // Auto-farm mode (see auto_tick / cli_auto in target.odin). When on, the watcher thread
  // advances the focus to the next fresh mob named auto_name whenever m_pObjFocus clears.
  auto_on:       bool,
  auto_name:     string, // cloned target name; freed on toggle/close
  auto_last:     i64, // time.now()._nsec of the last advance attempt (throttle)

  // Detection experiment (see refocus_tick in target.odin): write the current m_pObjFocus value
  // back to itself periodically - a consistent external write that matches the client's input.
  refocus_on:    bool,
  refocus_last:  i64,

  // Server target-sync (see notify_server_target / cli_srvsync). When on, each focus select
  // also fires the client's own SendSetTarget(objid, 2) so the server's m_idSetTarget matches
  // what we attack - the anti-DC fix. Cleared on detach/close.
  srvsync_on:    bool,
  srv_shim:      uintptr, // cached RWX shim page in the target (remote_send_settarget); 0 = none

  // Global hotkeys (see hotkey.odin). exec_mutex serializes command execution between the REPL
  // thread and the hotkey watcher thread. exec_line runs a CLI line (set by main to the REPL's
  // dispatcher); the watcher calls it through this pointer so flyff never imports the cli/main
  // package (breaks what would otherwise be a flyff<->main cycle).
  hotkeys:       [dynamic]Hotkey,
  exec_mutex:    sync.Mutex,
  hk_thread:     win.HANDLE,
  hk_running:    bool,
  hk_stop:       bool,
  exec_line:     proc(^Session, string) -> bool,
}

// Initialise a fresh Session (defaults + scan arena). Returns false if the arena can't be created.
session_init :: proc(session: ^Session) -> bool {
  session.vtype = .U32
  session.ptr_size = 8
  session.writable_only = true
  session.layout = flyff_layout_default()
  if err := virtual.arena_init_growing(&session.scan_arena); err != .None {
    fmt.eprintln("failed to initialise scan arena")
    return false
  }
  return true
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
  delete(session.targets)
  session.targets = nil
  delete(session.tc_recent)
  session.tc_recent = nil
}

session_close :: proc(session: ^Session) {
  // Stop the hotkey watcher before closing the process handle it may be using.
  if session.hk_running {
    sync.mutex_lock(&session.exec_mutex)
    session.hk_stop = true
    sync.mutex_unlock(&session.exec_mutex)
    win.WaitForSingleObject(session.hk_thread, 1000)
    win.CloseHandle(session.hk_thread)
    session.hk_running = false
  }
  if session.attached {
    remote_free_shim(session)
    win.CloseHandle(session.proc_info.handle)
  }
  free_all(virtual.arena_allocator(&session.scan_arena))
  delete(session.targets)
  delete(session.hotkeys)
  delete(session.tc_recent)
  delete(session.auto_name)
}
