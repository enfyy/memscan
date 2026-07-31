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
// matters here - the game does not need to be focused for a HOTKEY, and your own keyboard is never
// hijacked, so a script can fire one while you use the PC normally. (Movement keys are the exception
// and the client, not this file, is why - see THE MOVEMENT KEYS ARE THE EXCEPTION below.)
//
// It is only for things the client exposes as a HOTKEY (skill bar slots, potions, teleport items,
// pet summon): actions the tool drives directly - move, jump, target - still go through the
// client's own functions (see move.odin), which is more robust and needs no window at all.
//
// KEY RELEASE IS A CONTRACT. Every press is a down/up pair separated by a short hold. If a script
// is stopped, interrupted, or the process detaches between the two, the key must still be released
// - a stuck key would keep firing a skill (or worse, keep you running) with nothing left to stop
// it. That is why the press_key block implements `exit` and not just `start`/`poll`.
//
// HOLDING is the second shape, and it is the one that needs the registry below. Some things the
// client only does while a key is DOWN - walking with W, hold-to-attack, a channelled skill - so
// key_down/key_up (and `key hold`/`key release`) split the pair across two blocks and let the hold
// outlive the step that started it. That deliberately breaks press_key's "one step owns the pair"
// contract, so the contract moves up a level: every key put down is recorded in session.keys_held,
// and every teardown path releases the lot (script_teardown, script_reset, on_detach). A chart that
// forgets its `key_up`, or that is stopped mid-hold, still lets go of the key.
//
// ONE DOWN IS ENOUGH - no auto-repeat pump. Confirmed against the client source (Neuz.cpp MsgProc):
// WM_KEYDOWN does `g_bKeyTable[vk] = TRUE` and WM_KEYUP does `= FALSE`, so the client holds a LEVEL
// table that a single posted down sets and only a posted up clears. It never samples the real
// keyboard for these, which is why holding works from an unfocused window at all. (g_nOldVirtKey,
// which a per-frame line would use to clear a key, is never assigned anywhere - that path is dead.)
//
// THE MOVEMENT KEYS ARE THE EXCEPTION, and it is not a bug on our side. Setting g_bKeyTable is
// necessary but not sufficient: something has to READ it, and for W/A/S/D that reader refuses to while
// the window is in the background. _Interface/WndWorldControlPlayer.cpp, top of the per-frame input
// pass:
//
//     if (g_Neuz.m_bActiveNeuz == FALSE || <chat box has focus>) {
//         g_bKeyTable[g_Neuz.Key.chUp]    = FALSE;   // and chLeft / chBack / chRight / chQuest / 'E'
//     }
//
// It does not merely skip the keys, it ZEROES them, every frame the client is inactive. So a posted
// key_down W is wiped on the next frame and the character never moves. m_bActiveNeuz is set from
// WM_ACTIVATE (Neuz.cpp), i.e. real window activation, which PostMessage cannot fake.
//
// What this means in practice:
//   - hotkeys (skill slots, potions, F-keys, VK_SPACE) work backgrounded. Space is deliberately NOT in
//     that wipe list - only the movement set and 'E' are.
//   - W/A/S/D only work with the game focused, and no amount of posting fixes it.
//   - to MOVE in the background, use the client's own functions instead of keys: walk_to / jump_to /
//     moveto (move.odin). That is what the paragraph above means by "actions the tool drives directly".
//   - the real fix for background key-movement would be pinning m_bActiveNeuz to TRUE in the target.
//     Filed in BACKLOG.md; it needs a finder, and forcing it also re-enables the taskbar's slot-cooldown
//     animation (WndTaskBar.cpp is the only other reader), so it is not free.
//
// One more client-side thing can drop a hold: an open chat/edit box swallows key messages and zeroes the
// movement keys plus VK_SPACE (WndEditCtrl.cpp). If a hold stops by itself, look there first.
// ===========================================================================

KEY_HOLD_NS :: i64(45_000_000) // ~45ms down before release - long enough for the client to sample it
KEY_HOLD_MS :: u32(45) // the same hold, for the one-shot `key` command's blocking sleep
KEY_VK_COUNT :: 256 // virtual-key codes are a byte; sized to index session.keys_held by VK directly

// One spelling of a named key. `alias` marks a second spelling of a key already in the table - it
// still PARSES, but the picker offers only the canonical one, because a dropdown listing "enter" and
// "return" as separate rows implies they are different keys.
Key_Name :: struct {
  name:  string,
  vk:    u32,
  alias: bool,
}

// The named keys, as DATA rather than as a switch, because two things need them: vk_from_name below,
// and the node editor's key picker (there was no list to pick from, which is why a key argument used
// to be typed blind). The a-z / 0-9 / f1-f12 ranges stay code - they are ranges, and spelling out 48
// rows to say so would be the worse half of the trade.
//
// NOT the inverse of engine.hotkey_vk_name, which is what the comment here used to claim. That proc
// also prints Num0-Num9, Backspace, Pause and ScrollLock, and nothing here parses those back. The
// asymmetry is pre-existing and left alone; this table is the half a SCRIPT reads.
@(rodata)
KEY_NAMES := [?]Key_Name {
  {"space", 0x20, false},
  {"enter", 0x0D, false},
  {"return", 0x0D, true},
  {"tab", 0x09, false},
  {"esc", 0x1B, false},
  {"escape", 0x1B, true},
  {"up", 0x26, false},
  {"down", 0x28, false},
  {"left", 0x25, false},
  {"right", 0x27, false},
  {"insert", 0x2D, false},
  {"delete", 0x2E, false},
  {"del", 0x2E, true},
  {"home", 0x24, false},
  {"end", 0x23, false},
  {"pageup", 0x21, false},
  {"pgup", 0x21, true},
  {"pagedown", 0x22, false},
  {"pgdn", 0x22, true},
}

// Every key name worth OFFERING, in the order a Flyff player reaches for them: skill slots, then the
// item bar, then the named keys, then the letters. Aliases are left out (see Key_Name.alias).
// Temp-allocated - the picker rebuilds it per frame and it is 60-odd short strings.
key_name_choices :: proc(allocator := context.temp_allocator) -> []string {
  out := make([dynamic]string, 0, 64, allocator)
  for i in 1 ..= 12 {
    append(&out, fmt.aprintf("f%d", i, allocator = allocator))
  }
  for c in "1234567890" {
    append(&out, fmt.aprintf("%c", c, allocator = allocator))
  }
  for k in KEY_NAMES {
    if !k.alias {
      append(&out, k.name)
    }
  }
  for c in "abcdefghijklmnopqrstuvwxyz" {
    append(&out, fmt.aprintf("%c", c, allocator = allocator))
  }
  return out[:]
}

// Resolve a key NAME to a virtual-key code. Accepts what a player would actually type in a script:
// "1".."0", "a".."z", "f1".."f12", and the named keys in KEY_NAMES.
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
  for k in KEY_NAMES {
    if k.name == lower {
      return k.vk, true
    }
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

// --- the held-key registry --------------------------------------------------------------------

// Push a key down and REMEMBER that it is down. The pair to key_release; anything that only wants a
// tap should use key_post twice (or press_key) rather than these.
key_hold :: proc(session: ^Session, vk: u32) -> bool {
  if !key_post(session, vk, true) {
    return false
  }
  if vk < KEY_VK_COUNT {
    session.keys_held[vk] = true
  }
  return true
}

// Let a key go. Posts the up unconditionally - a WM_KEYUP for a key the client does not think is
// down is a no-op there, and refusing to send one for a key we have no record of would make this
// useless as a manual "unstick it" escape hatch.
//
// The record is cleared even when the post FAILS. A failed post means the window is gone (the client
// closed, or we detached), and in that world the key is not held by anything - keeping the flag would
// leave the registry claiming a hold forever and make every later release-all a lie.
key_release :: proc(session: ^Session, vk: u32) -> bool {
  ok := key_post(session, vk, false)
  if vk < KEY_VK_COUNT {
    session.keys_held[vk] = false
  }
  return ok
}

// Let go of everything. The safety net behind key_down: called from script_teardown, script_reset and
// on_detach, so no held key can outlive the run - or the process - that put it down. Returns how many
// were actually released, so a caller can stay quiet in the (normal) case of none.
keys_release_all :: proc(session: ^Session) -> int {
  n := 0
  for held, vk in session.keys_held {
    if !held {
      continue
    }
    key_release(session, u32(vk))
    n += 1
  }
  return n
}

keys_held_count :: proc(session: ^Session) -> int {
  n := 0
  for held in session.keys_held {
    if held {
      n += 1
    }
  }
  return n
}

// The held keys as "w + space", for status lines. Temp-allocated: only CLI/status printing calls it.
keys_held_text :: proc(session: ^Session, allocator := context.temp_allocator) -> string {
  b := strings.builder_make(allocator)
  n := 0
  for held, vk in session.keys_held {
    if !held {
      continue
    }
    if n > 0 {
      strings.write_string(&b, " + ")
    }
    strings.write_string(&b, engine.hotkey_vk_name(u32(vk), allocator))
    n += 1
  }
  return strings.to_string(b)
}

// --- CLI ----------------------------------------------------------------------------------------

// key <name> - press one hotkey, right now.
// key hold <name> / key release [<name>] - the direct-command form of the key_down / key_up blocks.
//
// Exists because behaviours are compiled in: without this there is no way to try a keystroke without
// editing behaviours.odin and rebuilding, which is hopeless for the one primitive most likely to
// need fiddling (does this build read the message queue, or poll?). Every other primitive already
// has a direct command - moveto, jump, tc, auto, sweep to - so this closes the last gap.
//
// The subcommands are `hold`/`release` and NOT `down`/`up` because "down" and "up" are themselves key
// names: `key down` already means "tap the down arrow", and quietly re-reading it as a subcommand
// would change what an existing line does.
cli_key :: proc(session: ^Session, args: []string) {
  if len(args) == 0 {
    fmt.eprintln("usage: key <name>            e.g. 'key 1', 'key f5', 'key space'  (down + up)")
    fmt.eprintln("       key hold <name>       push it down and LEAVE it down (the key_down block)")
    fmt.eprintln("       key release [<name>]  let go of one, or of everything (the key_up block)")
    fmt.eprintln("  posts to the game window, so the game does NOT need to be focused.")
    if n := keys_held_count(session); n > 0 {
      fmt.eprintfln("  currently held: %s   ('key release' to let go)", keys_held_text(session))
    }
    return
  }
  if !session.attached {
    fmt.eprintln("not attached. attach a Neuz first.")
    return
  }
  switch args[0] {
  case "hold":
    cli_key_hold(session, args[1:])
    return
  case "release":
    cli_key_release(session, args[1:])
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

@(private = "file")
cli_key_hold :: proc(session: ^Session, args: []string) {
  if len(args) == 0 {
    fmt.eprintln("usage: key hold <name>   e.g. 'key hold w', 'key hold space'")
    return
  }
  vk, ok := vk_from_name(args[0])
  if !ok {
    fmt.eprintfln("'%s' is not a key name (try 1-9, a-z, f1-f12, space, enter, or a raw 0x.. VK).", args[0])
    return
  }
  if !key_hold(session, vk) {
    fmt.eprintln("PostMessage failed for the key-down (is the game window still there?).")
    return
  }
  fmt.printfln("key '%s' (VK 0x%X) is now HELD DOWN. 'key release %s' lets go.", args[0], vk, args[0])
  fmt.println("  it stays down until you release it, the script ends, or memscan detaches.")
}

@(private = "file")
cli_key_release :: proc(session: ^Session, args: []string) {
  if len(args) == 0 {
    n := keys_release_all(session)
    if n == 0 {
      fmt.println("no keys were being held.")
      return
    }
    fmt.printfln("released %d held key(s).", n)
    return
  }
  vk, ok := vk_from_name(args[0])
  if !ok {
    fmt.eprintfln("'%s' is not a key name (try 1-9, a-z, f1-f12, space, enter, or a raw 0x.. VK).", args[0])
    return
  }
  was_held := vk < KEY_VK_COUNT && session.keys_held[vk]
  key_release(session, vk)
  fmt.printfln("key '%s' (VK 0x%X) released%s.", args[0], vk, was_held ? "" : " (it wasn't being held)")
}

key_post :: proc(session: ^Session, vk: u32, down: bool) -> bool {
  hwnd, ok := game_window(session)
  if !ok {
    return false
  }
  msg := u32(down ? win.WM_KEYDOWN : win.WM_KEYUP)
  return win.PostMessageW(hwnd, win.UINT(msg), win.WPARAM(uintptr(vk)), key_lparam(vk, down)) != win.FALSE
}
