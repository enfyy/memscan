package flyff

import "base:runtime"
import "core:fmt"
import "core:strings"
import "core:sync"
import win "core:sys/windows"

PAUSE_VK :: u32(0x79) // F10 - default key that toggles the auto-farm pause

// A global hotkey: when `vk` transitions from up to down (anywhere, even while
// memscan is in the background), run `command` through the normal CLI. `was_down`
// is the watcher's edge-detection state.
Hotkey :: struct {
  vk:       u32,
  name:     string,
  command:  string,
  was_down: bool,
}

// Background thread that polls every registered hotkey's physical key state via
// GetAsyncKeyState (focus-independent) and fires its command on a fresh key press.
// All session access is serialized with the REPL through session.exec_mutex.
hotkey_thread_start :: proc "system" (param: rawptr) -> win.DWORD {
  context = runtime.default_context()
  hotkey_watch_loop(cast(^Session)param)
  return 0
}

hotkey_watch_loop :: proc(session: ^Session) {
  pause_prev := false // F10 edge-detection for the pause binding
  for {
    sync.mutex_lock(&session.exec_mutex)
    if session.hk_stop {
      sync.mutex_unlock(&session.exec_mutex)
      return
    }
    // Default pause binding: F10 toggles the auto-farm pause (only while auto is on, so a stray press
    // off the clock does nothing).
    pause_down := hotkey_key_down(PAUSE_VK)
    if pause_down && !pause_prev {
      if session.auto_on && session.exec_line != nil {
        fmt.printf("\n[F10] pause\n")
        session.exec_line(session, "pause")
        fmt.print("memscan> ")
      }
    }
    pause_prev = pause_down
    for &hk in session.hotkeys {
      down := hotkey_key_down(hk.vk)
      if down && !hk.was_down {
        fmt.printf("\n[%s] %s\n", hk.name, hk.command)
        if session.exec_line != nil {
          session.exec_line(session, hk.command)
        }
        fmt.print("memscan> ")
      }
      hk.was_down = down
    }
    auto_tick(session) // hands-free farm: advance focus when the target dies
    range_ring_tick(session) // attack-range circle overlay (ring / draw_range) - non-blocking
    sync.mutex_unlock(&session.exec_mutex)
    win.Sleep(20)
  }
}

// Lazily start the watcher on the first bound hotkey.
ensure_hotkey_thread :: proc(session: ^Session) {
  if session.hk_running {
    return
  }
  session.hk_stop = false
  h := win.CreateThread(nil, 0, hotkey_thread_start, session, 0, nil)
  if h == nil {
    fmt.eprintln("warning: could not start hotkey watcher thread.")
    return
  }
  session.hk_thread = h
  session.hk_running = true
}

// hotkey <command...>   -> prompt for a key, then bind it
// hotkey list           -> show bindings
// hotkey clear          -> remove all bindings
cli_hotkey :: proc(session: ^Session, args: []string) {
  if len(args) == 0 || args[0] == "list" {
    cli_hotkey_list(session)
    return
  }
  if args[0] == "clear" {
    clear(&session.hotkeys)
    fmt.println("all hotkeys cleared.")
    return
  }

  command := strings.trim_space(strings.join(args, " ", context.temp_allocator))
  if command == "" {
    fmt.eprintln("usage: hotkey <command>   (then press a key)   |   hotkey list | hotkey clear")
    return
  }

  fmt.printf("press a key to bind to \"%s\" (Esc to cancel)... ", command)
  vk, ok := capture_key()
  if !ok {
    fmt.println("cancelled.")
    return
  }
  name := hotkey_vk_name(vk, context.temp_allocator)

  for &hk in session.hotkeys {
    if hk.vk == vk {
      hk.command = strings.clone(command)
      fmt.printfln("%s rebound -> %s", name, command)
      ensure_hotkey_thread(session)
      return
    }
  }
  append(
    &session.hotkeys,
    Hotkey{vk = vk, name = strings.clone(name), command = strings.clone(command), was_down = true},
  )
  fmt.printfln("bound %s -> %s  (works while memscan is in the background)", name, command)
  ensure_hotkey_thread(session)
}

cli_hotkey_list :: proc(session: ^Session) {
  if len(session.hotkeys) == 0 {
    fmt.println("no hotkeys bound. usage: hotkey <command>  (then press a key)")
    return
  }
  fmt.printfln("%d hotkey(s):", len(session.hotkeys))
  for hk in session.hotkeys {
    fmt.printfln("  %-10s -> %s", hk.name, hk.command)
  }
}

// Block until the user presses a capturable key (returns its VK), or Esc (cancel).
// Phase 1 waits for a clean slate so the Enter that submitted the command isn't
// mistaken for the binding; phase 2 captures the first key-down, ~15s timeout.
capture_key :: proc() -> (vk: u32, ok: bool) {
  waited := 0
  for waited < 2000 {
    any_down := false
    for v := u32(0x08); v <= 0xFE; v += 1 {
      if hotkey_vk_excluded(v) {
        continue
      }
      if hotkey_key_down(v) {
        any_down = true
        break
      }
    }
    if !any_down {
      break
    }
    win.Sleep(15)
    waited += 15
  }

  elapsed := 0
  for elapsed < 15000 {
    if hotkey_key_down(0x1B) { // VK_ESCAPE cancels
      return 0, false
    }
    for v := u32(0x08); v <= 0xFE; v += 1 {
      if hotkey_vk_excluded(v) {
        continue
      }
      if hotkey_key_down(v) {
        return v, true
      }
    }
    win.Sleep(15)
    elapsed += 15
  }
  return 0, false
}

hotkey_key_down :: proc(vk: u32) -> bool {
  return (i32(win.GetAsyncKeyState(i32(vk))) & 0x8000) != 0
}

// Keys we never bind: Enter (submits the command), Esc (cancels), bare modifiers,
// and the Windows keys. Everything else in [0x08, 0xFE] is fair game.
hotkey_vk_excluded :: proc(vk: u32) -> bool {
  switch vk {
  case 0x0D, 0x1B, 0x10, 0x11, 0x12, 0x5B, 0x5C:
    return true
  case 0xA0 ..= 0xA5:
    return true
  }
  return vk < 0x08 || vk > 0xFE
}

hotkey_vk_name :: proc(vk: u32, allocator := context.allocator) -> string {
  switch vk {
  case 0x70 ..= 0x87:
    return fmt.aprintf("F%d", vk - 0x6F, allocator = allocator) // F1 == 0x70
  case 0x30 ..= 0x39, 0x41 ..= 0x5A: // '0'-'9', 'A'-'Z' (VK == ASCII)
    b := [1]byte{byte(vk)}
    return strings.clone(string(b[:]), allocator)
  case 0x60 ..= 0x69:
    return fmt.aprintf("Num%d", vk - 0x60, allocator = allocator)
  case 0x20:
    return strings.clone("Space", allocator)
  case 0x09:
    return strings.clone("Tab", allocator)
  case 0x08:
    return strings.clone("Backspace", allocator)
  case 0x13:
    return strings.clone("Pause", allocator)
  case 0x91:
    return strings.clone("ScrollLock", allocator)
  case 0x2D:
    return strings.clone("Insert", allocator)
  case 0x2E:
    return strings.clone("Delete", allocator)
  case 0x24:
    return strings.clone("Home", allocator)
  case 0x23:
    return strings.clone("End", allocator)
  case 0x21:
    return strings.clone("PageUp", allocator)
  case 0x22:
    return strings.clone("PageDown", allocator)
  case 0x25:
    return strings.clone("Left", allocator)
  case 0x26:
    return strings.clone("Up", allocator)
  case 0x27:
    return strings.clone("Right", allocator)
  case 0x28:
    return strings.clone("Down", allocator)
  case:
    return fmt.aprintf("VK_%X", vk, allocator = allocator)
  }
}
