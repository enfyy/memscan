package engine

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:sync"
import win "core:sys/windows"

// ===========================================================================
// Generic engine session - the reusable, Flyff-agnostic host state.
//
// This holds everything the memory-scanning REPL needs for ANY process: the
// attached handle, the default value type, the scan working set (snapshot +
// matches), and the background hotkey watcher. Flyff-specific automation lives
// in flyff.Session, which EMBEDS this struct as its first field (offset 0) so a
// ^engine.Session can be recovered to a ^flyff.Session by the module hooks.
//
// The engine never imports flyff; the flyff layer plugs in through the module
// hook function pointers below (registered at startup). See engine/repl.odin
// for the dispatch that calls module_dispatch, and engine/hotkey.odin for the
// watcher that calls module_tick.
// ===========================================================================

// A process we've opened for read/write (generic; not Flyff-specific).
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

  // Scan working set: an unknown-value snapshot and/or an exact-value match set, both owned by
  // scan_arena (reclaimed wholesale by session_reset_scan). targets is the last 'nearest' result.
  scan_arena:    virtual.Arena,
  has_snapshot:  bool,
  snapshot:      Mem_Snapshot,
  has_matches:   bool,
  matches:       Match_Set,
  targets:       [dynamic]Nearest_Entry, // last 'nearest' result, sorted by distance

  // Global hotkeys (see hotkey.odin). exec_mutex serializes command execution between the REPL
  // thread and the hotkey watcher thread. exec_line runs a CLI line (set by session_init to the
  // REPL's execute_line); the watcher calls it through this pointer so the watcher stays generic.
  hotkeys:       [dynamic]Hotkey,
  exec_mutex:    sync.Mutex,
  hk_thread:     win.HANDLE,
  hk_running:    bool,
  hk_stop:       bool,
  exec_line:     proc(^Session, string) -> bool,

  // App identity for the `version` command, injected by main so the engine never depends on the
  // application's generated VERSION / BUILD_HASH constants.
  app_version:    string,
  app_build_hash: string,

  // ---- Module interface -------------------------------------------------------------------
  // A module (currently only flyff) registers these so the generic engine can call into it
  // without importing it. All are nil / false until flyff_register runs. Each proc receives a
  // ^Session; the module recovers its own struct via an offset-0 cast (see flyff.flyff_of).
  module_active:   bool,
  module_name:     string,
  module_dispatch: proc(^Session, string, []string) -> (handled: bool), // the module's command set
  module_tick:     proc(^Session), // run each watcher loop (e.g. auto-farm, overlays)
  module_help:     proc(), // print the module's help section (between engine general help + footer)
  on_attach:       proc(^Session), // per-process setup (e.g. load config, defaults) after attach
  on_detach:       proc(^Session), // per-process teardown (e.g. free remote pages) before handle close
  on_close:        proc(^Session), // session-end teardown of module lifetime-owned resources
  open_ui:         proc(^Session), // open the module's UI window (Phase 3); blocks until closed. nil = none
}

// Initialise a fresh Session (defaults + scan arena + exec_line). Returns false if the arena
// can't be created. Flyff layers its own defaults + module registration on top (flyff.session_init).
session_init :: proc(session: ^Session) -> bool {
  session.vtype = .U32
  session.ptr_size = 8
  session.writable_only = true
  session.exec_line = execute_line
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

// Fully resets the scan working set (matches + snapshot) and reclaims arena memory. Module caches
// keyed to the scan set (if any) are cleared by the module's on_attach/on_detach, not here.
session_reset_scan :: proc(session: ^Session) {
  free_all(virtual.arena_allocator(&session.scan_arena))
  session.has_snapshot = false
  session.has_matches = false
  session.snapshot = {}
  session.matches = {}
  delete(session.targets)
  session.targets = nil
}

// Stop the watcher, run the module's teardown, close the handle, and free generic state. Called by
// flyff.session_close (a thin wrapper) via main's defer. The watcher is stopped FIRST so no tick
// races the teardown.
session_close :: proc(session: ^Session) {
  if session.hk_running {
    sync.mutex_lock(&session.exec_mutex)
    session.hk_stop = true
    sync.mutex_unlock(&session.exec_mutex)
    win.WaitForSingleObject(session.hk_thread, 1000)
    win.CloseHandle(session.hk_thread)
    session.hk_running = false
  }
  if session.on_close != nil {
    session.on_close(session) // module frees its remote pages (if attached) + lifetime-owned data
  }
  if session.attached {
    win.CloseHandle(session.proc_info.handle)
  }
  free_all(virtual.arena_allocator(&session.scan_arena))
  delete(session.targets)
  delete(session.hotkeys)
}
