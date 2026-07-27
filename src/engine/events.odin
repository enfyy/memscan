package engine

// ===========================================================================
// Event Board + Inbox - two tiny generic message containers.
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
// INBOX is the queue: fixed capacity, preserves duplicates, drainable, and posts
// to a full inbox are refused rather than dropping what's already queued. Suits
// deferred commands (the radar already hand-rolls this shape in radar.odin).
// ===========================================================================

// At most one message per kind until cleared. $Kind must be an enum.
Board :: struct($Kind: typeid, $Message: typeid) {
  posted: bit_set[Kind],
  data:   [Kind]Message,
}

// Fixed-capacity pending message list. Unlike Board, identity is the message itself
// (e.g. a union tag), so duplicates are preserved.
Inbox :: struct($Message: typeid, $N: uint) {
  items: [N]Message,
  size:  int,
}

// ---------------------------------------------------------------------------
// Board
// ---------------------------------------------------------------------------

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

// ---------------------------------------------------------------------------
// Inbox
// ---------------------------------------------------------------------------

inbox_clear :: proc(inbox: ^Inbox($Message, $N)) {
  if inbox == nil {
    return
  }
  inbox.size = 0
}

// Returns false when the inbox is full; queued messages are left intact.
inbox_post :: proc(inbox: ^Inbox($Message, $N), message: Message) -> bool {
  if inbox == nil {
    return false
  }
  if uint(inbox.size) >= N {
    return false
  }
  inbox.items[inbox.size] = message
  inbox.size += 1
  return true
}

inbox_count :: proc "contextless" (inbox: ^Inbox($Message, $N)) -> int {
  if inbox == nil {
    return 0
  }
  return inbox.size
}

inbox_empty :: proc "contextless" (inbox: ^Inbox($Message, $N)) -> bool {
  return inbox_count(inbox) == 0
}

// The live messages, in post order. Borrowed - valid until the next post/clear.
inbox_drain :: proc(inbox: ^Inbox($Message, $N)) -> []Message {
  if inbox == nil {
    return nil
  }
  return inbox.items[:inbox.size]
}

inbox_get :: proc(inbox: ^Inbox($Message, $N), index: int) -> (message: Message, ok: bool) #optional_ok {
  if inbox == nil {
    return
  }
  if index < 0 || index >= inbox.size {
    return
  }
  return inbox.items[index], true
}
