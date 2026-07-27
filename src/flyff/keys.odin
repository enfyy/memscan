package flyff

import "core:fmt"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"

import "../engine"

// ===========================================================================
// Keystroke delivery - PostMessage(WM_KEYDOWN/WM_KEYUP) to the game's main window.
//
// This is the one place the tool simulates input, and it is deliberately narrow: it posts to the
// Neuz window's message queue rather than synthesising global input (SendInput). Two reasons that
// matters here - the game does NOT need to be focused, and your own keyboard is never hijacked, so
// a script can fire a hotkey while you use the PC normally.
//
// It is only for things the client exposes as a HOTKEY (skill bar slots, potions, teleport items,
// pet summon): actions the tool drives directly - move, jump, target - still go through the
// client's own functions (see move.odin), which is more robust and needs no window at all.
//
// KEY RELEASE IS A CONTRACT. Every press is a down/up pair separated by a short hold. If a script
// is stopped, interrupted, or the process detaches between the two, the key must still be released
// - a stuck key would keep firing a skill (or worse, keep you running) with nothing left to stop
// it. That is why the press_key block implements `exit` and not just `start`/`poll`.
// ===========================================================================

KEY_HOLD_NS :: i64(45_000_000) // ~45ms down before release - long enough for the client to sample it
KEY_HOLD_MS :: u32(45) // the same hold, for the one-shot `key` command's blocking sleep

// Resolve a key NAME to a virtual-key code. Accepts what a player would actually type in a script:
// "1".."0", "a".."z", "f1".."f12", and the common named keys. The inverse of engine.hotkey_vk_name.
vk_from_name :: proc(raw: string) -> (vk: u32, ok: bool) {
  name := strings.trim_space(raw)
  if len(name) == 0 {
    return 0, false
  }
  lower := strings.to_lower(name, context.temp_allocator)
  // Single character: digits and letters map straight to their ASCII value as VK codes.
  if len(lower) == 1 {
    c := lower[0]
    if c >= '0' && c <= '9' {
      return u32(c), true
    }
    if c >= 'a' && c <= 'z' {
      return u32(c - 'a' + 'A'), true // VK_A..VK_Z are the uppercase ASCII values
    }
  }
  if strings.has_prefix(lower, "f") && len(lower) <= 3 {
    if n, nok := strconv.parse_int(lower[1:]); nok && n >= 1 && n <= 12 {
      return u32(0x6F + n), true // VK_F1 == 0x70
    }
  }
  switch lower {
  case "space":
    return 0x20, true
  case "enter", "return":
    return 0x0D, true
  case "tab":
    return 0x09, true
  case "esc", "escape":
    return 0x1B, true
  case "up":
    return 0x26, true
  case "down":
    return 0x28, true
  case "left":
    return 0x25, true
  case "right":
    return 0x27, true
  case "insert":
    return 0x2D, true
  case "delete", "del":
    return 0x2E, true
  case "home":
    return 0x24, true
  case "end":
    return 0x23, true
  case "pageup", "pgup":
    return 0x21, true
  case "pagedown", "pgdn":
    return 0x22, true
  }
  // Raw numeric form for anything unnamed: "vk 0x70" style, or a plain number.
  if n, nok := engine.parse_addr(lower); nok && n > 0 && n <= 0xFE {
    return u32(n), true
  }
  return 0, false
}

// The game's main window, resolved fresh each time rather than cached: the client can be restarted
// or re-attached under us, and posting to a stale HWND silently does nothing (the worst failure
// mode - a script that looks like it is working). EnumWindows is cheap at script cadence.
game_window :: proc(session: ^Session) -> (win.HWND, bool) {
  if !session.attached {
    return nil, false
  }
  return engine.find_main_window_by_process_id(session.proc_info.pid)
}

// Build the lParam WM_KEYDOWN/WM_KEYUP expect: repeat count 1, the hardware scan code, and (for the
// up message) the transition + previous-state bits. Some clients read the scan code rather than the
// VK, so it is filled in properly rather than left zero.
key_lparam :: proc(vk: u32, down: bool) -> win.LPARAM {
  scan := win.MapVirtualKeyW(win.UINT(vk), win.MAPVK_VK_TO_VSC)
  lp := u32(1) | (u32(scan) << 16)
  if !down {
    lp |= (1 << 30) | (1 << 31) // previous state = down, transition = up
  }
  return win.LPARAM(uintptr(lp))
}

// key <name> - press one hotkey, right now.
//
// Exists because behaviours are compiled in: without this there is no way to try a keystroke without
// editing behaviours.odin and rebuilding, which is hopeless for the one primitive most likely to
// need fiddling (does this build read the message queue, or poll?). Every other primitive already
// has a direct command - moveto, jump, tc, auto, sweep to - so this closes the last gap.
cli_key :: proc(session: ^Session, args: []string) {
  if len(args) == 0 {
    fmt.eprintln("usage: key <name>   e.g. 'key 1', 'key f5', 'key space'")
    fmt.eprintln("  presses a hotkey in the game. the game does NOT need to be focused.")
    return
  }
  if !session.attached {
    fmt.eprintln("not attached. attach a Neuz first.")
    return
  }
  vk, ok := vk_from_name(args[0])
  if !ok {
    fmt.eprintfln("'%s' is not a key name (try 1-9, a-z, f1-f12, space, enter, or a raw 0x.. VK).", args[0])
    return
  }
  hwnd, wok := game_window(session)
  if !wok {
    fmt.eprintln("couldn't find the game's main window to post to (is it minimised to tray?).")
    return
  }
  if !key_post(session, vk, true) {
    fmt.eprintln("PostMessage failed for the key-down.")
    return
  }
  win.Sleep(KEY_HOLD_MS) // blocking is fine here - this is a one-shot manual command, not the tick
  key_post(session, vk, false)
  fmt.printfln("key '%s' (VK 0x%X) posted to hwnd 0x%X (down + up).", args[0], vk, uintptr(hwnd))
  fmt.println("  no visible effect? try again with the game focused - that distinguishes")
  fmt.println("  'the client ignores posted input' from 'the window was wrong'.")
}

key_post :: proc(session: ^Session, vk: u32, down: bool) -> bool {
  hwnd, ok := game_window(session)
  if !ok {
    return false
  }
  msg := u32(down ? win.WM_KEYDOWN : win.WM_KEYUP)
  return win.PostMessageW(hwnd, win.UINT(msg), win.WPARAM(uintptr(vk)), key_lparam(vk, down)) != win.FALSE
}
