package engine

// ===========================================================================
// Event Board - a tiny generic per-tick message latch.
//
// Copied from the author's RTS engine (C:\Users\jul\Documents\GitHub\rts,
// src/events/events.odin). The verbs are renamed to the noun_verb form this
// package already uses (session_clear_matches, hotkey_watch_loop): the original
// exposes them as a `clear`/`post`/`get` proc group, which works there because
// `events` is its own package, but at engine scope `clear` would shadow the
// builtin that hotkey.odin already calls. Semantics are unchanged.
//
// BOARD is the per-tick latch: at most one message per kind, last post wins, and
// the whole thing is cleared at the top of each tick. That is exactly the shape of
// "did this happen since I last looked" - which is what a behaviour machine's
// senses and interrupts need (see flyff/behaviour.odin). Sense once, then let any
// number of readers ask, instead of each one polling the game independently.
//
// The RTS original also has an Inbox (a fixed-capacity queue that preserves
// duplicates). It was copied over with the Board and never used - the radar's
// deferred-command list, the one thing shaped like it, predates this file and
// hand-rolls a [dynamic]string. Deleted rather than kept "in case": an unused
// generic is a thing every reader has to rule out.
// ===========================================================================

// At most one message per kind until cleared. $Kind must be an enum.
Board :: struct($Kind: typeid, $Message: typeid) {
  posted: bit_set[Kind],
  data:   [Kind]Message,
}

board_clear :: proc(board: ^Board($Kind, $Message)) {
  if board == nil {
    return
  }
  board.posted = {}
}

board_post :: proc(board: ^Board($Kind, $Message), kind: Kind, message: Message) {
  if board == nil {
    return
  }
  board.data[kind] = message
  board.posted += {kind}
}

board_has :: proc "contextless" (board: ^Board($Kind, $Message), kind: Kind) -> bool {
  if board == nil {
    return false
  }
  return kind in board.posted
}

board_get :: proc(board: ^Board($Kind, $Message), kind: Kind) -> (message: Message, ok: bool) #optional_ok {
  if board == nil {
    return
  }
  if kind not_in board.posted {
    return
  }
  return board.data[kind], true
}
