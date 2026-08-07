package flyff

import "core:fmt"
import "core:mem"
import "core:mem/virtual"
import "core:time"

import "../engine"

// ===========================================================================
// The behaviour machine - the flyff module's declared state machine.
//
// Built on engine/statemachine.odin (a state IS a proc returning the NEXT state, with
// Enter/Update/Exit) and engine/events.odin (a Board: one latched signal per kind, cleared
// at the top of every tick). Both were ported from the author's RTS engine; see those files.
//
// WHY IT EXISTS: `auto` used to be auto_tick - a state machine that was never declared, its states
// a precedence chain over booleans spread across ~30 Session fields
// (auto_paused -> sweep_on -> la_approach_on -> focus-live -> advance). With no Exit phase, teardown
// had to be re-written by hand at every site that left a state, and a cross-cutting mode had to be
// threaded through by hand (hunt_steering_on was consulted in four places). That whole tick is gone:
// `auto` now builds and runs a chart (bh_auto), so the ladder is a graph and "never drop the target"
// is one edge instead of a flag checked in four places.
//
// TICK ORDER: behaviour_tick is the ONLY farm tick in module_tick now - it owns routing. penya_tick
// and range_ring_tick still run after it; they only observe.
//
// SENSE DISCIPLINE - two hard rules, because breaking either is how this feature would regress
// the farm it is supposed to replace:
//
//   1. A SENSE MAY READ, NEVER WRITE. Senses observe the game and the session; they never touch
//      auto/sweep/focus state. That is what makes this file behaviour-NEUTRAL while the states
//      are still stubs - it cannot change what the bot does, only report what it saw.
//
//   2. EVERY SENSE DECLARES ITS COST (Sense_Def.poll_ns). The RTS machine ticks at 120Hz over an
//      in-memory sim; here the watcher ticks every 20ms and each sense is a cross-process read,
//      some of which walk structures. Cheap ones run every tick; anything that enumerates gets a
//      throttle. Sensing everything every tick would put the full walk back on the watcher tick -
//      exactly the stutter the Phase 6 background-scan fix removed (see autofarm.odin's
//      pre-select comments). If you add a sense, set poll_ns from what it actually costs.
//
// Sensing is OFF until something needs it (`sense on`, or a running script once Stage 1 lands),
// so an idle session pays nothing and the watcher thread isn't started just for this.
// ===========================================================================

// --- events -------------------------------------------------------------------------------

// What the machine can notice. Each is produced by exactly one Sense_Def below, and consumed by
// state Updates and (Stage 1) script interrupts. Extended by the script event registry.
Behaviour_Event :: enum {
  Focus_Live,     // something is selected and its vtable resolves
  Focus_Lost,     // nothing selected, or the selected object was freed
  Kill_Confirmed, // a kill was recorded since the last tick (auto OR manual)
  Penya_Gain,     // penya was credited as earned since the last tick
  Hp_Fell,        // the player's own HP is lower than the last observation
  Inv_Full,       // the bag has no free slots
  Stuck,          // a walk stopped making progress - RAISED by an action, not polled (see behaviour_raise)
}

// One posted signal. Fixed-size name buffer rather than a string: the Board keeps the last value
// per kind across ticks, so a borrowed temp-allocator string would dangle after free_all. Same
// reason lb_cur_name / lb_status_buf are fixed arrays.
Behaviour_Signal :: struct {
  at:       i64,     // time.now()._nsec when it fired
  num:      f64,     // primary scalar: hp, penya amount, free slots, a count - per event
  obj:      uintptr, // the object it concerns (0 = none)
  name:     [64]u8,
  name_len: int,
}

Behaviour_Board :: engine.Board(Behaviour_Event, Behaviour_Signal)

// The signal's name field as a string. Takes a POINTER on purpose: the result borrows the caller's
// buffer, so a value parameter would either be unsliceable (not addressable) or return a slice into
// a dead local. Signals live on the session-owned Board, so a borrow from there is stable until the
// next post for that kind.
signal_name :: proc(sig: ^Behaviour_Signal) -> string {
  if sig == nil || sig.name_len <= 0 {
    return ""
  }
  n := min(sig.name_len, len(sig.name))
  return string(sig.name[:n])
}

// --- states -------------------------------------------------------------------------------

// The durable state tag. Serializable and printable; the live proc is rebuilt from it each tick
// via behaviour_state_function (the RTS convention - see movement_state_function there).
// Two states is the whole machine, and deliberately so: farming did NOT become
// Paused/Sweeping/Approaching/Fighting/Advancing states here. Those turned out to be steps in a
// program rather than modes of the host, so they live in the chart (bh_auto) and this level only has
// to know whether a chart is running.
Behaviour_State :: enum {
  Idle,
  Script,
}

behaviour_state_name :: proc(s: Behaviour_State) -> string {
  switch s {
  case .Idle:
    return "IDLE"
  case .Script:
    return "SCRIPT"
  }
  return "?"
}

// Per-tick scratch: the machine and this context are rebuilt as locals every tick from the
// durable tag, never stored on Session (RTS convention). A stack-local context also cannot be
// observed from another thread, which is exactly the discipline this codebase wants.
Behaviour_Context :: struct {
  session: ^Session,
  now:     i64,
  board:   ^Behaviour_Board,
}

bh_ctx :: #force_inline proc(user_data: rawptr) -> ^Behaviour_Context {
  return cast(^Behaviour_Context)user_data
}

behaviour_state_function :: proc(kind: Behaviour_State) -> engine.State_Function {
  switch kind {
  case .Idle:
    return st_idle
  case .Script:
    return st_script
  }
  return st_idle
}

// Force a transition from OUTSIDE the tick (the CLI: `script run`, `script stop`, detach). Goes
// through state_machine_goto so the Exit/Enter pair still runs - which is what guarantees that
// stopping a script tears down whatever it had in flight. Caller holds exec_mutex, so building the
// context here is the same discipline cli_sense uses.
behaviour_goto :: proc(session: ^Session, next: Behaviour_State) {
  ctx := Behaviour_Context {
    session = session,
    now     = time.now()._nsec,
    board   = &session.bh_board,
  }
  sm := engine.State_Machine {
    current_state = behaviour_state_function(session.bh_state),
    user_data     = &ctx,
  }
  if !session.bh_entered {
    // Nothing has entered yet, so there is no Exit owed - just enter the target directly.
    session.bh_entered = true
    session.bh_state = next
    behaviour_state_function(next)(&ctx, .Enter)
    return
  }
  engine.state_machine_goto(&sm, behaviour_state_function(next))
  session.bh_state = next
}

// The resting state. Does nothing on purpose: until the script VM (Stage 1) and the ported auto
// states (Stage 4) exist, the machine's only job is to prove it ticks, that the durable tag
// round-trips, and that the board is populated for `sense` to read.
st_idle :: proc(user_data: rawptr, phase: engine.State_Phase) -> engine.State_Function {
  ctx := bh_ctx(user_data)
  switch phase {
  case .Enter:
    ctx.session.bh_state = .Idle
    ctx.session.bh_state_at = ctx.now
  case .Update:
  case .Exit:
  }
  return st_idle
}

// --- sense table --------------------------------------------------------------------------

SENSE_EVERY_TICK :: i64(0)
SENSE_SLOW_NS :: i64(500_000_000) // 0.5s - for anything that walks a structure

// One sense: what it posts, what it costs, and whether it can run at all right now. This table
// is the single place a sense's cost is declared (rule 2 above).
Sense_Def :: struct {
  event:   Behaviour_Event,
  name:    string,
  blurb:   string,
  poll_ns: i64,
  avail:   proc(session: ^Session) -> (ok: bool, why: string), // nil = always available
  sense:   proc(ctx: ^Behaviour_Context) -> (fired: bool, sig: Behaviour_Signal),
}

@(rodata)
SENSES := [?]Sense_Def {
  {
    event = .Focus_Live, name = "focus_live", poll_ns = SENSE_EVERY_TICK,
    blurb = "a target is selected and its object still resolves",
    sense = sense_focus_live,
  },
  {
    event = .Focus_Lost, name = "focus_lost", poll_ns = SENSE_EVERY_TICK,
    blurb = "nothing selected, or the selected object was freed (the kill/advance trigger)",
    sense = sense_focus_lost,
  },
  {
    event = .Kill_Confirmed, name = "kill", poll_ns = SENSE_EVERY_TICK,
    blurb = "a kill was recorded since the last tick (reads kill_seq - auto and manual both count)",
    sense = sense_kill,
  },
  {
    event = .Penya_Gain, name = "penya", poll_ns = SENSE_EVERY_TICK,
    blurb = "penya credited as earned since the last tick (reads penya_seq)",
    avail = avail_penya, sense = sense_penya,
  },
  {
    event = .Hp_Fell, name = "hp_fell", poll_ns = SENSE_EVERY_TICK,
    blurb = "the player's own HP dropped since the last observation",
    avail = avail_hp, sense = sense_hp_fell,
  },
  {
    event = .Inv_Full, name = "inv_full", poll_ns = SENSE_SLOW_NS,
    blurb = "the bag has no free slots (walks the inventory - throttled)",
    avail = avail_inv, sense = sense_inv_full,
  },
}

sense_def :: proc(ev: Behaviour_Event) -> ^Sense_Def {
  for &d in SENSES {
    if d.event == ev {
      return &d
    }
  }
  return nil // raised by an action rather than polled (see behaviour_raise)
}

// Fallback label for an event with no Sense_Def.
behaviour_event_name :: proc(ev: Behaviour_Event) -> string {
  switch ev {
  case .Focus_Live:
    return "focus_live"
  case .Focus_Lost:
    return "focus_lost"
  case .Kill_Confirmed:
    return "kill"
  case .Penya_Gain:
    return "penya"
  case .Hp_Fell:
    return "hp_fell"
  case .Inv_Full:
    return "inv_full"
  case .Stuck:
    return "stuck"
  }
  return "?"
}

// --- availability predicates ---------------------------------------------------------------

// Each of these gates a block as well as a sense, so they check attachment too - several of the
// offsets they want have non-zero BUILT-IN defaults, and reporting [OK] for something that reads a
// process we aren't attached to would be a lie in `script blocks`.

avail_penya :: proc(session: ^Session) -> (bool, string) {
  if ok, why := avail_attached(session); !ok {
    return false, why
  }
  if session.layout.penya_off == 0 {
    return false, "needs penya_off - run 'findpenya <current-penya>'"
  }
  return true, ""
}

avail_hp :: proc(session: ^Session) -> (bool, string) {
  if ok, why := avail_attached(session); !ok {
    return false, why
  }
  if session.layout.hp_off == 0 {
    return false, "needs hp_off - run 'setup <name>'"
  }
  return true, ""
}

avail_inv :: proc(session: ^Session) -> (bool, string) {
  if ok, why := avail_attached(session); !ok {
    return false, why
  }
  if session.layout.inv_off == 0 || session.layout.item_stride == 0 {
    return false, "needs inv_off/item_stride - run 'findinv'"
  }
  return true, ""
}

// --- sense implementations -----------------------------------------------------------------
// Read-only, every one of them (rule 1). Where a sense needs a baseline to compare against, the
// baseline lives on Session as a bh_* field and is updated here - that is bookkeeping for the
// observation itself, not game or auto state.

sense_focus_live :: proc(ctx: ^Behaviour_Context) -> (bool, Behaviour_Signal) {
  focus, ok := read_focus_ptr(ctx.session)
  if !ok || focus == 0 || !focus_obj_live(ctx.session, focus) {
    return false, {}
  }
  return true, Behaviour_Signal{at = ctx.now, obj = focus}
}

sense_focus_lost :: proc(ctx: ^Behaviour_Context) -> (bool, Behaviour_Signal) {
  focus, ok := read_focus_ptr(ctx.session)
  if !ok {
    return false, {} // couldn't read - report nothing rather than a false "lost"
  }
  if focus != 0 && focus_obj_live(ctx.session, focus) {
    return false, {}
  }
  return true, Behaviour_Signal{at = ctx.now, obj = focus}
}

sense_kill :: proc(ctx: ^Behaviour_Context) -> (bool, Behaviour_Signal) {
  s := ctx.session
  if s.kill_seq <= s.bh_kill_seq_seen {
    return false, {}
  }
  n := s.kill_seq - s.bh_kill_seq_seen
  s.bh_kill_seq_seen = s.kill_seq
  return true, Behaviour_Signal{at = ctx.now, num = f64(n)}
}

sense_penya :: proc(ctx: ^Behaviour_Context) -> (bool, Behaviour_Signal) {
  s := ctx.session
  if s.penya_seq <= s.bh_penya_seq_seen {
    return false, {}
  }
  s.bh_penya_seq_seen = s.penya_seq
  // The amount belongs to the newest event; penya_tick appends in order and prunes by TTL.
  amount := f64(0)
  if n := len(s.penya_events); n > 0 {
    amount = f64(s.penya_events[n - 1].amount)
  }
  return true, Behaviour_Signal{at = ctx.now, num = amount}
}

sense_hp_fell :: proc(ctx: ^Behaviour_Context) -> (bool, Behaviour_Signal) {
  s := ctx.session
  player := read_ptr_at(
    s.proc_info.handle,
    s.proc_info.base + s.layout.player_rva,
    s.ptr_size == 4 ? engine.Value_Type.U32 : engine.Value_Type.U64,
  )
  if player == 0 {
    return false, {}
  }
  hp, ok := read_mob_hp(s, player)
  if !ok {
    return false, {}
  }
  prev := s.bh_hp_last
  s.bh_hp_last = hp
  if !s.bh_hp_seeded {
    s.bh_hp_seeded = true
    return false, {} // first observation is the baseline, not a drop
  }
  if hp >= prev {
    return false, {}
  }
  return true, Behaviour_Signal{at = ctx.now, num = f64(hp), obj = player}
}

sense_inv_full :: proc(ctx: ^Behaviour_Context) -> (bool, Behaviour_Signal) {
  _, free, _, ok := read_inventory_counts(ctx.session)
  if !ok || free > 0 {
    return false, {}
  }
  return true, Behaviour_Signal{at = ctx.now, num = 0}
}

// --- raised signals ---------------------------------------------------------------------------

// Publish a signal that no sense polls for - something an ACTION noticed (a walk that stopped making
// progress). It cannot just board_post: the board is cleared at the top of every tick, and actions run
// AFTER the sense pass, so anything posted directly would be wiped before the next tick's interrupt
// pass could ever see it. Raising instead defers the post to the START of the next tick, where it sits
// on the board for exactly one full tick - long enough for interrupts and `sense` to observe it.
behaviour_raise :: proc(session: ^Session, event: Behaviour_Event, sig: Behaviour_Signal) {
  session.bh_raised += {event}
  session.bh_raised_sig[event] = sig
}

// --- scratch memory -------------------------------------------------------------------------

// Reset and hand out the behaviour machine's OWN scratch allocator.
//
// Why not context.temp_allocator: nothing frees temp on the module_tick path. The REPL frees per
// line (engine/repl.odin), the radar frees per frame (radar.odin), and workers free their own - but
// the watcher tick has no such boundary. Anything allocating temp there, every 20ms forever, just
// grows. The mover-gathering senses below allocate per landscape tile, so they get an arena this
// file owns and resets at the top of every use instead.
//
// Callers override context.temp_allocator with this for the duration of the call. That override is
// a copy local to the calling proc (Odin passes context implicitly), so it never leaks out to the
// caller and needs no restore - but it DOES reach every callee, which is the point: it redirects the
// temp allocations inside radar_gather_movers without that proc knowing anything about it.
behaviour_scratch :: proc(session: ^Session) -> mem.Allocator {
  if !session.bh_scratch_ok {
    if err := virtual.arena_init_growing(&session.bh_scratch); err != nil {
      return context.temp_allocator // arena unavailable: fall back rather than fail the sense
    }
    session.bh_scratch_ok = true
  }
  alloc := virtual.arena_allocator(&session.bh_scratch)
  free_all(alloc)
  return alloc
}

behaviour_scratch_free :: proc(session: ^Session) {
  if session.bh_scratch_ok {
    virtual.arena_destroy(&session.bh_scratch)
    session.bh_scratch_ok = false
  }
}

// --- the tick -----------------------------------------------------------------------------

// Clear the board, then run each due sense. Caller holds exec_mutex, and the clear + the whole
// sense pass happen inside that one hold - so a reader on the REPL thread (`sense`) always sees a
// COMPLETE board for some tick, never a half-cleared one.
behaviour_sense_pass :: proc(ctx: ^Behaviour_Context) {
  s := ctx.session
  engine.board_clear(ctx.board)
  // Publish anything an action raised during the PREVIOUS tick, before the polled senses run. This
  // is the only way an action-observed signal survives to be seen by interrupts (see behaviour_raise).
  if s.bh_raised != {} {
    for ev in Behaviour_Event {
      if ev in s.bh_raised {
        engine.board_post(ctx.board, ev, s.bh_raised_sig[ev])
      }
    }
    s.bh_raised = {}
  }
  if !s.attached {
    return
  }
  for def in SENSES {
    if def.avail != nil {
      if ok, _ := def.avail(s); !ok {
        continue
      }
    }
    if def.poll_ns > SENSE_EVERY_TICK {
      if ctx.now < s.bh_sense_next[def.event] {
        continue // throttled - not due yet (rule 2)
      }
      s.bh_sense_next[def.event] = ctx.now + def.poll_ns
    }
    if fired, sig := def.sense(ctx); fired {
      engine.board_post(ctx.board, def.event, sig)
    }
  }
}

// Per-watcher-tick behaviour work: sense, then advance the machine. Called from module_tick ahead
// of auto_tick. Inert unless sensing is engaged, so an idle session pays nothing (and nothing
// starts the watcher thread just for this).
behaviour_tick :: proc(session: ^Session) {
  // Engaged by explicit sensing, by a running script, OR by an armed global interrupt. That third one
  // matters: a peace-out escape has to be watching while you farm under `auto` with no chart running
  // and `sense off`, which is the state most sessions are actually in.
  // Deliberately NOT gated on `attached`: a script built from pure-VM blocks (wait/repeat/if/var) is
  // meant to run with no game at all, which is also how the whole walker gets tested headlessly. The
  // sense pass does its own attach check.
  if !session.bh_sense_on && !session.script.active && !armed_watcher_any(session) {
    return
  }
  // Point temp at the machine's own arena for this whole tick, and reset it here. Everything below -
  // senses, the script walker, the mover gathers - then allocates scratch freely without leaking on a
  // thread that has no free_all boundary of its own. The override is local to this proc and its
  // callees (Odin passes context implicitly), so it never escapes to the rest of module_tick.
  context.temp_allocator = behaviour_scratch(session)
  ctx := Behaviour_Context {
    session = session,
    now     = time.now()._nsec,
    board   = &session.bh_board,
  }
  behaviour_sense_pass(&ctx)
  // THE GLOBAL RULE LIST, AFTER the senses (so a trigger reads this tick's board, not last tick's) and
  // BEFORE the state machine (so an interrupt that fires takes effect on the tick it fired rather than
  // after one more step of whatever was happening).
  //
  // While one has control the behaviour does not advance AT ALL - its in-flight step is left mid-flight
  // and resumed exactly where it was. That is what makes the globals "a second list above" rather than
  // a second thing running: higher interrupts lower, and interruption resumes. It used to take a hoist
  // into the run's watcher array plus a latch handed over in both directions; it is now one early
  // return. See interrupt.odin.
  if globals_tick(&ctx) {
    return
  }
  // First engagement: run the initial state's Enter, once. The per-tick rebuild below constructs the
  // machine literally instead of via state_machine_create precisely so Enter does NOT re-run every
  // tick - but that means nothing would ever enter the STARTING state (a state returning itself is
  // not a transition, so state_machine_tick sees no Enter to run). Hence this.
  if !session.bh_entered {
    session.bh_entered = true
    behaviour_state_function(session.bh_state)(&ctx, .Enter)
    return // Update starts on the next tick, with Enter's setup already in place
  }
  // Rebuilt from the durable tag each tick, NOT stored (RTS convention).
  sm := engine.State_Machine {
    current_state = behaviour_state_function(session.bh_state),
    user_data     = &ctx,
  }
  engine.state_machine_tick(&sm)
}

// Reset the observation baselines. Called on attach/detach: sequence counters and the HP anchor
// belong to the process that produced them, and carrying them across would report a phantom kill
// or HP drop on the first tick against a new client (the same reasoning as clear_focus dropping
// the combat-watch anchor).
behaviour_reset :: proc(session: ^Session) {
  // A global that was mid-flight belongs to the process it was walking against - the same reasoning
  // that drops the sense baselines here.
  session.global_active = -1
  session.global_pc = 0
  session.global_entered = false
  session.bh_state = .Idle
  session.bh_state_at = 0
  session.bh_entered = false // the new process's initial state needs its Enter to run again
  session.bh_kill_seq_seen = 0
  session.bh_penya_seq_seen = 0
  session.bh_hp_last = 0
  session.bh_hp_seeded = false
  session.bh_sense_next = {}
  session.bh_raised = {}
  engine.board_clear(&session.bh_board)
}

// --- CLI ----------------------------------------------------------------------------------

@(private = "file")
cli_sense_list :: proc(session: ^Session) {
  fmt.println("behaviour senses - what the machine can notice, and what each costs to check:")
  for def in SENSES {
    cost := def.poll_ns == SENSE_EVERY_TICK ? "every tick" : fmt.tprintf("every %.1fs", f64(def.poll_ns) / 1e9)
    mark := "[OK]"
    why := ""
    if def.avail != nil {
      if ok, w := def.avail(session); !ok {
        mark = "[--]"
        why = fmt.tprintf("  -> %s", w)
      }
    }
    fmt.printfln("  %s %-14s %-11s %s%s", mark, def.name, cost, def.blurb, why)
  }
  fmt.println("a sense only ever READS - none of them can change what the bot does.")
}
