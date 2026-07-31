package flyff

import "core:fmt"
import "core:math"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"
import "core:time"

// ===========================================================================
// VISUAL ALERTS - the border and banner behind the `alert` block.
//
// A beep says something happened. It does not say WHAT, or which chart said it, and by the time you
// have alt-tabbed back it is already over. So an alert here is a piece of STATE with a message on it:
// a severity-coloured vignette that breathes around the edge of the radar window for as long as it is
// up, plus a banner naming the event.
//
// THE BALANCE. An alert you can ignore is pointless; one you cannot work through is worse. Two rules
// hold the middle. Peak opacity stays under ALERT_ALPHA_CEILING, so the map is always legible THROUGH
// the border rather than behind it - that is what keeps this a notification instead of a modal. And
// only the border moves: the banner text, the part you actually read, is perfectly still. Motion in
// the periphery is what the eye catches anyway, so spending it there costs nothing and spending it on
// the text would only make the text harder to read.
//
// THREADING. alert_show / alert_clear are called by the behaviour VM on the watcher thread, holding
// exec_mutex. The drawing half (gui_alert_overlay, gui.odin) runs in the radar's UNLOCKED phase off a
// Gui_Frame snapshot. That is why Alert_State is plain old data with an inline byte array rather than
// a string: Gui_Frame is copied by value, and a row that owns nothing has no lifetime rule for anyone
// to get wrong. Script_Trace_Row is shaped this way for exactly the same reason.
//
// NOTHING HERE TICKS. fired_at, hold_ns and ended_at fully determine what is on screen at any instant,
// so an alert raised while the radar is shut simply expires unseen - no timer to keep running, no
// state to reconcile when the window opens. The envelope is a pure function of the clock.
// ===========================================================================

ALERT_TEXT_MAX :: 96 // banner cap; a line too long for the window is not a banner any more

// Envelope shape, in nanoseconds. The attack is quick enough to register as a CHANGE rather than as a
// fade-in - that snap is most of what makes it noticeable. The release is deliberately slower: things
// that vanish abruptly read as a glitch, and a glitch is not something you trust.
ALERT_ATTACK_NS :: i64(180_000_000) // 180ms ramp in
ALERT_RELEASE_NS :: i64(450_000_000) // 450ms fade out

// The breathing, applied to the border only. ~1.8s per cycle, which is slow on purpose: a fast strobe
// is what makes an overlay hostile to work under (and is a real photosensitivity hazard), while a slow
// swell just reads as "this is still on". The floor keeps it from ever blinking fully off - it swells
// between ALERT_PULSE_FLOOR and full, so there is no moment where the alert has apparently gone away.
ALERT_PULSE_HZ :: f32(0.55)
ALERT_PULSE_FLOOR :: f32(0.55)

// The BANNER's size animation. It lands oversized and settles - the impact read a game uses, and the
// reason the banner needs no plate behind it to be noticed: something that changes size is already
// moving, and movement is what the eye picks up. It then swells slightly as it fades, so the exit
// dissipates rather than merely dimming.
//
// The sustain breath is deliberately tiny and in phase with the border, so the two read as one object
// rather than two effects that happen to be on screen together. Big enough here and the text becomes
// something you wait out instead of read - that is the whole reason the number is 2%.
ALERT_PUNCH :: f32(0.55) // extra size at the instant it lands
ALERT_DISSIPATE :: f32(0.12) // extra size by the end of the fade
ALERT_BREATH :: f32(0.02) // sustain wobble, +/- this fraction

// Hard ceiling on border opacity, asserted by script_selftest_alert. The map has to stay readable
// through an alert; the moment it does not, the alert becomes something you dismiss rather than
// something you act on. This is the number to distrust if someone later reports the effect is too much.
ALERT_ALPHA_CEILING :: f32(0.5)

ALERT_DEFAULT_SECONDS :: f64(4)

ALERT_SEVERITY_NAMES :: []string{"info", "warn", "danger"}

Alert_Severity :: enum {
  Info,
  Warn,
  Danger,
}

// Peak border opacity per severity. Escalation is carried by WEIGHT, not by speed - all three breathe
// at the same rate, so `danger` reads as heavier rather than more frantic. Frantic is the thing that
// makes people turn a feature off.
ALERT_PEAK_ALPHA := [Alert_Severity]f32 {
  .Info   = 0.26,
  .Warn   = 0.36,
  .Danger = 0.46,
}

Alert_State :: struct {
  active:   bool,
  severity: Alert_Severity,
  fired_at: i64, // time.now()._nsec when it was raised
  hold_ns:  i64, // sustain length; 0 = hold until something clears it
  ended_at: i64, // when a clear cut the sustain short; 0 = running its own course
  text_len: u8,
  text:     [ALERT_TEXT_MAX]u8,
}

// ===========================================================================
// Timing - pure functions of the clock, safe to call from the unlocked draw phase
// ===========================================================================

@(private = "file")
ease_out_cubic :: proc(t: f32) -> f32 {
  u := 1 - clamp(t, 0, 1)
  return 1 - u * u * u
}

@(private = "file")
ease_in_cubic :: proc(t: f32) -> f32 {
  u := clamp(t, 0, 1)
  return u * u * u
}

// When the fade-out begins, in nsec. 0 means "not yet decided" - a sticky alert that nothing has
// cleared, which sustains indefinitely.
alert_release_start :: proc(a: Alert_State) -> i64 {
  if a.ended_at != 0 {
    return a.ended_at // an explicit clear cuts the sustain wherever it happens to be
  }
  if a.hold_ns > 0 {
    return a.fired_at + ALERT_ATTACK_NS + a.hold_ns
  }
  return 0
}

// The 0..1 intensity envelope: ramp up, hold, fade out. 0 means there is nothing to draw.
//
// The two ramps are combined with min() rather than sequenced through an if-chain, which is what makes
// every ordering fall out for free - including a clear that arrives DURING the attack, where the value
// simply stops climbing and comes back down from wherever it had got to.
alert_envelope :: proc(a: Alert_State, now: i64) -> f32 {
  if !a.active {
    return 0
  }
  rise := ease_out_cubic(f32(now - a.fired_at) / f32(ALERT_ATTACK_NS))
  fall := f32(1)
  if start := alert_release_start(a); start != 0 {
    fall = 1 - ease_in_cubic(f32(now - start) / f32(ALERT_RELEASE_NS))
  }
  return max(min(rise, fall), 0)
}

// The slow swell, 0..1, multiplied into the border alpha. Driven by wall-clock seconds rather than by
// the alert's own age so several alerts in a row stay in phase instead of each restarting the cycle.
alert_pulse :: proc(now_seconds: f64) -> f32 {
  s := f32(math.sin(now_seconds * 2 * math.PI * f64(ALERT_PULSE_HZ)))
  return ALERT_PULSE_FLOOR + (1 - ALERT_PULSE_FLOOR) * 0.5 * (1 + s)
}

// The banner's size multiplier: lands at 1+ALERT_PUNCH, settles to 1, swells to 1+ALERT_DISSIPATE as it
// goes. `pulse` is the same value the border is using this frame, so the breath stays in phase with it.
alert_text_scale :: proc(a: Alert_State, now: i64, pulse: f32) -> f32 {
  rise := ease_out_cubic(f32(now - a.fired_at) / f32(ALERT_ATTACK_NS))
  scale := 1 + ALERT_PUNCH * (1 - rise)
  if start := alert_release_start(a); start != 0 && now >= start {
    scale += ALERT_DISSIPATE * clamp(f32(now - start) / f32(ALERT_RELEASE_NS), 0, 1)
  }
  // Re-centre the pulse on 0 so the breath is symmetric about the settled size rather than only ever
  // shrinking it - the text should sit AT its size, not under it.
  breath := (pulse - ALERT_PULSE_FLOOR) / (1 - ALERT_PULSE_FLOOR) // 0..1
  return scale + ALERT_BREATH * (breath * 2 - 1)
}

// The message, as a string view into the fixed buffer. BY POINTER, and deliberately: the result aliases
// the buffer, so handing it a temporary copy would return a view of something already gone.
alert_text :: proc(a: ^Alert_State) -> string {
  return string(a.text[:a.text_len])
}

// Copy a message into the inline buffer, truncating to fit. Split out from alert_show so the truncation
// can be tested without a Session - it is the one part of raising an alert that can be got wrong.
alert_set_text :: proc(a: ^Alert_State, message: string) {
  n := min(len(message), ALERT_TEXT_MAX)
  // Never split a multi-byte rune: a chopped tail draws as a replacement box, which reads as a bug in
  // the alert rather than as a message that was too long.
  for n > 0 && n < len(message) && (message[n] & 0xC0) == 0x80 {
    n -= 1
  }
  copy(a.text[:], message[:n])
  a.text_len = u8(n)
}

// ===========================================================================
// Raising and clearing
// ===========================================================================

alert_show :: proc(session: ^Session, severity: Alert_Severity, message: string, hold_ns: i64, beep: bool) {
  a := &session.alert
  a.active = true
  a.severity = severity
  a.fired_at = time.now()._nsec
  a.hold_ns = max(hold_ns, 0)
  a.ended_at = 0 // re-raising restarts the envelope, which is what "a new alert" should look like
  alert_set_text(a, message)

  if beep {
    win.MessageBeep(0xFFFFFFFF) // the radar-closed fallback: audio is the only channel that still works
  }
}

// Take an alert down early. It still FADES - cutting to black would read as the window glitching, and
// the fade is also the acknowledgement that something cleared it.
alert_clear :: proc(session: ^Session) {
  a := &session.alert
  if !a.active {
    return
  }
  now := time.now()._nsec
  if alert_envelope(a^, now) <= 0 {
    a.active = false // already finished on its own; there is nothing left to fade
    return
  }
  if a.ended_at == 0 || now < a.ended_at {
    a.ended_at = now
  }
}

alert_severity_from_name :: proc(name: string) -> (Alert_Severity, bool) {
  switch strings.to_lower(name, context.temp_allocator) {
  case "info":
    return .Info, true
  case "warn", "warning":
    return .Warn, true
  case "danger", "critical", "error":
    return .Danger, true
  }
  return .Warn, false
}

// Spelled out rather than indexing ALERT_SEVERITY_NAMES, which is a constant (the catalog's `choices`
// wants it that way) and so cannot be indexed by a variable.
alert_severity_name :: proc(s: Alert_Severity) -> string {
  switch s {
  case .Info:
    return "info"
  case .Warn:
    return "warn"
  case .Danger:
    return "danger"
  }
  return "warn"
}

// ===========================================================================
// CLI
// ===========================================================================

// alert <info|warn|danger> <message...> [seconds]
// alert clear
// alert
//
// The message is the remaining words joined back together - the REPL splits on whitespace and has no
// quoting, so a trailing NUMBER is read as the duration and everything before it is the text. That is
// the only ambiguity, it is documented in help, and a message whose last word is a bare number can
// still be written by passing the duration explicitly after it.
cli_alert :: proc(session: ^Session, args: []string) {
  if len(args) == 0 {
    a := &session.alert
    now := time.now()._nsec
    if !a.active || alert_envelope(a^, now) <= 0 {
      fmt.println("no alert up. usage: alert <info|warn|danger> <message...> [seconds] | alert clear")
      return
    }
    // "fading" is worth saying out loud: a clear does not take the alert down instantly, so without it
    // the status right after one looks like the clear was ignored.
    state := a.hold_ns == 0 ? "until cleared" : fmt.tprintf("%.1fs", f64(a.hold_ns) / 1e9)
    if start := alert_release_start(a^); start != 0 && now >= start {
      state = "fading out"
    }
    fmt.printfln("alert %s (%s): %s", alert_severity_name(a.severity), state, alert_text(a))
    return
  }

  if args[0] == "clear" || args[0] == "off" {
    alert_clear(session)
    fmt.println("alert cleared.")
    return
  }

  severity, ok := alert_severity_from_name(args[0])
  if !ok {
    fmt.eprintfln("unknown severity: %s (want info, warn or danger)", args[0])
    return
  }

  rest := args[1:]
  seconds := ALERT_DEFAULT_SECONDS
  if len(rest) > 0 {
    if v, num_ok := strconv.parse_f64(rest[len(rest) - 1]); num_ok && v >= 0 {
      seconds = v
      rest = rest[:len(rest) - 1]
    }
  }
  message := strings.join(rest, " ", context.temp_allocator)

  alert_show(session, severity, message, i64(seconds * 1e9), false)
  if seconds <= 0 {
    fmt.printfln("alert %s up until cleared: %s", alert_severity_name(severity), message)
  } else {
    fmt.printfln("alert %s for %.1fs: %s", alert_severity_name(severity), seconds, message)
  }
  fmt.println("  (drawn in the radar window - nothing to see with it closed; the block's beep flag is the audible half)")
}
