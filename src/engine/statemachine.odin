package engine

// ===========================================================================
// Generic state machine - a state IS a proc, and it returns the NEXT state.
//
// Design copied from the author's RTS engine (C:\Users\jul\Documents\GitHub\rts,
// src/core/core.odin) - see src/games/duel/movement.odin there for the exemplar.
// Kept deliberately tiny and process-agnostic, like the rest of this package:
// the flyff module builds its behaviour machine on top (see flyff/behaviour.odin)
// and the engine never learns what the states mean.
//
// The shape it buys us: transitions read as `return st_approach` from inside a
// state's Update, and every state gets a matched Enter/Exit pair for free. That
// second half is the point - setup/teardown lives WITH the state instead of being
// re-written by hand at each site that leaves it.
//
// Conventions that come with the design (follow them in state procs):
//   - Enter sets the caller's durable state tag, so the serializable value can
//     never drift from the live proc pointer.
//   - The machine + its user_data context are SCRATCH: rebuild them as locals
//     each tick from the durable tag rather than storing them. A stack-local
//     context also can't be observed off-thread, which suits this codebase's
//     "mutate only under exec_mutex" discipline.
//   - Per-state timers: zero on Enter, increment on Update.
// ===========================================================================

State_Phase :: enum {
  Enter,
  Update,
  Exit,
}

// A state. Called with the owner's context as `user_data`; returns the state to be in NEXT.
// Returning itself (the usual case) means "stay". Only the Update phase's return value is
// acted on - Enter/Exit returns are ignored, so those phases can `return self` freely.
State_Function :: #type proc(user_data: rawptr, phase: State_Phase) -> State_Function

// Holds only the live proc + its context. Nothing durable: the owner keeps a serializable
// state tag (an enum, or a program counter) and rebuilds this from it each tick.
State_Machine :: struct {
  current_state: State_Function,
  user_data:     rawptr,
}

// Build a machine and run the initial state's Enter. Use this when starting a machine fresh;
// a machine rebuilt from an already-entered durable tag should be constructed literally
// instead, so Enter doesn't fire twice.
state_machine_create :: proc(initial: State_Function, user_data: rawptr) -> State_Machine {
  m := State_Machine {
    current_state = initial,
    user_data     = user_data,
  }
  if m.current_state != nil {
    m.current_state(m.user_data, .Enter)
  }
  return m
}

// One Update. If the state returned a different proc, run the old state's Exit and the new
// state's Enter before adopting it - so a transition can never skip either half.
state_machine_tick :: proc(machine: ^State_Machine) {
  if machine.current_state == nil {
    return
  }
  next := machine.current_state(machine.user_data, .Update)
  if next != machine.current_state {
    machine.current_state(machine.user_data, .Exit)
    next(machine.user_data, .Enter)
    machine.current_state = next
  }
}

// Force a transition WITHOUT running the current state's Update - the Exit/Enter pair still
// fires. Beyond the RTS original, which only ever transitions from inside an Update; an
// interrupt (see flyff/behaviour.odin) has to pre-empt the Update entirely, and doing that by
// hand at the call site would duplicate the pairing above. Returns false if nothing changed.
state_machine_goto :: proc(machine: ^State_Machine, next: State_Function) -> bool {
  if next == nil || next == machine.current_state {
    return false
  }
  if machine.current_state != nil {
    machine.current_state(machine.user_data, .Exit)
  }
  next(machine.user_data, .Enter)
  machine.current_state = next
  return true
}
