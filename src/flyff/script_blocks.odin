package flyff

import "core:fmt"
import "core:strconv"
import "core:strings"
import win "core:sys/windows"

import "../engine"

// ===========================================================================
// The block catalog - the single source of truth for what a behaviour script can DO and NOTICE.
//
// One table entry per block. The same entry drives the parser, the unparser (`script show`), the
// `script blocks` listing, the pre-run availability check, and - later - a node editor's palette
// and port list. Adding a block means adding a row plus its procs; nothing else has to learn
// about it. Same shape as PRESETS (preset.odin) and setup_groups (setup.odin).
//
// AVAILABILITY IS PART OF THE CATALOG. A block whose functionality does not exist yet (chat, key
// presses, NPC menus) is still listed, with `avail` reporting what it needs. It parses, `script
// blocks` shows it as [--] with the reason, and `script run` refuses UP FRONT rather than dying
// halfway through a run. That makes this table the feature's roadmap as well as its dispatch.
//
// PHASES. A long-running action is start-then-poll, which is exactly the state machine's
// Enter/Update/Exit (see engine/statemachine.odin):
//   start -> Enter   : issue the thing (write the destination, turn auto on)
//   poll  -> Update  : has it finished? (arrived, kill quota met)
//   exit  -> Exit    : undo whatever start did, on ANY exit - completion, abort, detach, or a
//                      script that stopped. This is the half the old hardcoded modes never had,
//                      and it is why `script stop` mid-walk actually halts the character.
// ===========================================================================

// --- parameters -----------------------------------------------------------------------------

// How one argument is parsed, stored, and printed back. Coord takes TWO num slots (x,z);
// everything else takes one slot of its storage class.
Param_Kind :: enum {
  Num,      // any number
  Duration, // seconds (float)
  Percent,  // 0-100
  Coord,    // x,z  -> two num slots
  Str,      // a bare word or a quoted string
  Names,    // a comma-separated monster-name list, stored verbatim (parse_target_names splits it)
}

Param_Spec :: struct {
  name:     string,
  kind:     Param_Kind,
  optional: bool,
  def:      f64, // default when optional and omitted (numeric kinds only)
}

// A parsed block instance. Deliberately a flat fixed payload rather than a per-kind union: it
// keeps the table generic, makes the whole step POD (no ownership beyond `strs`), and gives a node
// editor a fixed port layout to bind to.
Script_Action :: struct {
  kind: Script_Action_Kind,
  nums: [4]f64,
  strs: [2]string, // owned by the Script_Run that parsed them
}

Script_Event :: struct {
  kind:   Script_Event_Kind,
  nums:   [4]f64,
  strs:   [2]string, // owned by the Script_Run that parsed them
  // `not <event>` - the negation lives on the EVENT rather than on the step, so one implementation
  // covers every site an event can appear: if / while / until / wait_for / on. Without it every
  // predicate would need a hand-written inverse twin (the way no_mob_in_range mirrors mob_in_range),
  // which does not scale past a handful of blocks.
  negate: bool,
}

Step_Status :: enum {
  Running,
  Done,
  Failed,
}

// Per-instance event bookkeeping. Each `until` / `if` / `while` / `wait_for` / `on` site gets its
// own, armed when the site is entered - so `until kills 50` counts from where IT started, and two
// sites watching the same event never share a baseline.
Event_State :: struct {
  armed_at:  i64,
  base_i64:  i64, // baseline counter (kills, penya, ...)
  next_poll: i64, // throttle deadline for events that cost something to check
  armed:     bool,
  latched:   bool, // edge-detection for `on` watchers - see script_interrupts
}

// Per-instance action scratch, reset by the pc walker when the step is entered.
Step_Scratch :: struct {
  started_at:  i64,
  wp:          [3]f32, // waypoint (walk-style actions)
  best:        f32,    // closest distance seen (progress watchdog)
  progress_at: i64,
  flag:        bool,   // per-action spare (e.g. "start already issued")
}

// --- kinds ----------------------------------------------------------------------------------

Script_Action_Kind :: enum {
  None,
  Wait,
  Var,
  Add,
  Stop,
  Walk_To,
  Jump,
  Jump_To,
  Target,
  Farm,
  Sweep_To,
  Alert,
  Pause,
  Run_Cmd,
  Press_Key,
  // --- not implemented yet (see the NOT-YET block section); registered so they parse and are
  // discoverable, and so `script run` refuses up front instead of dying mid-run.
  Attack_Once,
  Say,
  Whisper,
  Npc_Talk,
  Npc_Menu,
  Sweep_Record,
  Sweep_Play,
}

Script_Event_Kind :: enum {
  None,
  Always,
  Never,
  Kills,
  Kills_Of,
  Elapsed,
  Inv_Full,
  Penya_At,
  Mob_In_Range,
  No_Mob_In_Range,
  Aggro,
  Player_Near,
  Player_Named_Near,
  Hp_Below,
  Target_Hp_Below,
  At_Position,
  Pet_Active,
  Focus_Lost,
  Stuck,
  // --- not implemented yet (see the NOT-YET block section)
  Chat_Msg,
  Whisper_From,
  Captcha,
}

// --- definitions ----------------------------------------------------------------------------

Action_Def :: struct {
  kind:   Script_Action_Kind,
  name:   string,
  params: []Param_Spec,
  blurb:  string,
  avail:  proc(session: ^Session) -> (ok: bool, why: string), // nil = always available
  start:  proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status,
  poll:   proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status, // nil = start's verdict is final
  exit:   proc(ctx: ^Behaviour_Context, step: ^Script_Step),                // nil = nothing to undo
}

Event_Def :: struct {
  kind:   Script_Event_Kind,
  name:   string,
  params: []Param_Spec,
  blurb:  string,
  avail:  proc(session: ^Session) -> (ok: bool, why: string),
  arm:    proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State), // nil = stateless
  fired:  proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool,
}

// --- param spec tables ----------------------------------------------------------------------

@(rodata)
PARAMS_WAIT := [?]Param_Spec{{name = "seconds", kind = .Duration}}

@(rodata)
PARAMS_VAR := [?]Param_Spec{{name = "name", kind = .Str}, {name = "value", kind = .Str}}

@(rodata)
PARAMS_ADD := [?]Param_Spec{{name = "name", kind = .Str}, {name = "delta", kind = .Num, optional = true, def = 1}}

@(rodata)
PARAMS_COORD := [?]Param_Spec{{name = "x,z", kind = .Coord}}

@(rodata)
PARAMS_NAMES_OPT := [?]Param_Spec{{name = "names", kind = .Names, optional = true}}

@(rodata)
PARAMS_NAME := [?]Param_Spec{{name = "name", kind = .Str}}

@(rodata)
PARAMS_TEXT := [?]Param_Spec{{name = "text", kind = .Str}}

@(rodata)
PARAMS_COUNT := [?]Param_Spec{{name = "n", kind = .Num}}

@(rodata)
PARAMS_MINUTES := [?]Param_Spec{{name = "minutes", kind = .Duration}}

@(rodata)
PARAMS_RADIUS := [?]Param_Spec{{name = "radius", kind = .Num}}

@(rodata)
PARAMS_RADIUS_OPT := [?]Param_Spec{{name = "radius", kind = .Num, optional = true, def = 0}}

@(rodata)
PARAMS_PERCENT := [?]Param_Spec{{name = "percent", kind = .Percent}}

@(rodata)
PARAMS_KILLS_OF := [?]Param_Spec{{name = "name", kind = .Str}, {name = "n", kind = .Num}}

@(rodata)
PARAMS_NAME_RADIUS := [?]Param_Spec{{name = "name", kind = .Str}, {name = "radius", kind = .Num}}

@(rodata)
PARAMS_MOB_RANGE := [?]Param_Spec {
  {name = "names", kind = .Names},
  {name = "radius", kind = .Num, optional = true, def = 0},
}

@(rodata)
PARAMS_NAME_TEXT := [?]Param_Spec{{name = "who", kind = .Str}, {name = "text", kind = .Str}}

@(rodata)
PARAMS_KEY := [?]Param_Spec{{name = "key", kind = .Str}}

@(rodata)
PARAMS_COORD_RADIUS := [?]Param_Spec {
  {name = "x,z", kind = .Coord},
  {name = "radius", kind = .Num, optional = true, def = 10},
}

// --- the action catalog ---------------------------------------------------------------------
// Not @(rodata): the rows hold proc pointers and param slices, which aren't constant initializers,
// and the lookups below hand out ^Action_Def (so the array has to be addressable). Treat as
// read-only by convention - nothing mutates these after startup.

ACTIONS := [?]Action_Def {
  {
    kind = .Wait, name = "wait", params = PARAMS_WAIT[:],
    blurb = "pause the script for N seconds",
    start = act_wait_start, poll = act_wait_poll,
  },
  {
    kind = .Var, name = "var", params = PARAMS_VAR[:],
    blurb = "set a session variable (the same @name the REPL's 'var' command sets)",
    start = act_var_start,
  },
  {
    kind = .Add, name = "add", params = PARAMS_ADD[:],
    blurb = "add to a numeric variable (counters); creates it at 0 if unset",
    start = act_add_start,
  },
  {
    kind = .Stop, name = "stop", params = {},
    blurb = "end the run here (the script's Exit still runs, so anything in flight is torn down)",
    start = act_stop_start,
  },
  {
    kind = .Walk_To, name = "walk_to", params = PARAMS_COORD[:],
    blurb = "walk to a world point and wait until you arrive",
    avail = avail_moveto, start = act_walk_start, poll = act_walk_poll, exit = act_walk_exit,
  },
  {
    kind = .Jump, name = "jump", params = {},
    blurb = "jump once (the client's own jump guards all apply)",
    avail = avail_jump, start = act_jump_start,
  },
  {
    kind = .Jump_To, name = "jump_to", params = PARAMS_COORD[:],
    blurb = "face a world point, start walking there, and jump (a directional jump)",
    avail = avail_move_and_jump, start = act_jump_to_start,
  },
  {
    kind = .Target, name = "target", params = PARAMS_NAMES_OPT[:],
    blurb = "select the nearest matching monster (no names = any monster)",
    avail = avail_attached, start = act_target_start,
  },
  {
    kind = .Farm, name = "farm", params = PARAMS_NAMES_OPT[:],
    blurb = "hand steering to the auto-brain and farm (pair it with 'until <event>')",
    avail = avail_attached, start = act_farm_start, poll = act_farm_poll, exit = act_farm_exit,
  },
  {
    kind = .Sweep_To, name = "sweep_to", params = PARAMS_COORD[:],
    blurb = "paint a lane from here to a world point and clear it (turns the auto-brain on)",
    avail = avail_moveto, start = act_sweep_start, poll = act_sweep_poll, exit = act_sweep_exit,
  },
  {
    kind = .Alert, name = "alert", params = {},
    blurb = "sound the system alert (works with the radar closed - it has no audio device of its own)",
    start = act_alert_start,
  },
    {
    kind = .Pause, name = "pause", params = {},
    blurb = "toggle the auto-farm pause (auto stays on but stops advancing)",
    avail = avail_attached, start = act_pause_start,
  },
  {
    kind = .Run_Cmd, name = "run", params = PARAMS_TEXT[:],
    blurb = "run any REPL command line - the escape hatch that makes every existing feature scriptable",
    start = act_run_cmd_start,
  },

  {
    kind = .Press_Key, name = "press_key", params = PARAMS_KEY[:],
    blurb = "press a hotkey in the game (skill slot, potion, teleport item) - the game need not be focused",
    avail = avail_press_key, start = act_press_key_start, poll = act_press_key_poll, exit = act_press_key_exit,
  },

  // --- NOT YET IMPLEMENTED --------------------------------------------------------------------
  // These are the blocks the design calls for whose underlying capability does not exist in the tool
  // yet. They are listed on purpose: `script blocks` doubles as the roadmap, the parser accepts them
  // so a script can be written ahead of the capability, and script_check_avail refuses the run up
  // front with the reason - which beats discovering it halfway through a farm. Each `why` names the
  // recon that would unblock it. Implementing one = swapping avail/start, nothing else changes.
  {
    kind = .Attack_Once, name = "attack_once", params = {},
    blurb = "swing once at the current target, then move on (for AoE pulls)",
    avail = na_attack, start = act_not_implemented,
  },
  {
    kind = .Say, name = "say", params = PARAMS_TEXT[:],
    blurb = "write a message in chat",
    avail = na_chat_send, start = act_not_implemented,
  },
  {
    kind = .Whisper, name = "whisper", params = PARAMS_NAME_TEXT[:],
    blurb = "whisper a message to one player",
    avail = na_chat_send, start = act_not_implemented,
  },
  {
    kind = .Npc_Talk, name = "npc_talk", params = PARAMS_NAME[:],
    blurb = "open dialogue with a named NPC",
    avail = na_npc, start = act_not_implemented,
  },
  {
    kind = .Npc_Menu, name = "npc_menu", params = PARAMS_COUNT[:],
    blurb = "choose entry N of the open NPC menu",
    avail = na_npc, start = act_not_implemented,
  },
  {
    kind = .Sweep_Record, name = "sweep_record", params = PARAMS_NAME[:],
    blurb = "record the path you walk and save it under <name>",
    avail = na_sweep_record, start = act_not_implemented,
  },
  {
    kind = .Sweep_Play, name = "sweep_play", params = PARAMS_NAME[:],
    blurb = "replay a recorded path as a sweep lane",
    avail = na_sweep_record, start = act_not_implemented,
  },
}

// --- the event catalog -----------------------------------------------------------------------
// Not @(rodata), same reason as ACTIONS.

EVENTS := [?]Event_Def {
  {
    kind = .Always, name = "always", params = {},
    blurb = "always true (authoring + testing)",
    fired = ev_always,
  },
  {
    kind = .Never, name = "never", params = {},
    blurb = "never true (authoring + testing)",
    fired = ev_never,
  },
  {
    kind = .Kills, name = "kills", params = PARAMS_COUNT[:],
    blurb = "N kills have happened since this point in the script",
    avail = avail_attached, arm = ev_kills_arm, fired = ev_kills,
  },
  {
    kind = .Kills_Of, name = "kills_of", params = PARAMS_KILLS_OF[:],
    blurb = "N kills of one species since the run started (name must match exactly)",
    avail = avail_attached, arm = ev_kills_of_arm, fired = ev_kills_of,
  },
  {
    kind = .Elapsed, name = "elapsed", params = PARAMS_MINUTES[:],
    blurb = "N minutes have passed since this point in the script",
    fired = ev_elapsed,
  },
  {
    kind = .Inv_Full, name = "inv_full", params = {},
    blurb = "the bag has no free slots",
    avail = avail_inv, fired = ev_inv_full,
  },
  {
    kind = .Penya_At, name = "penya_at", params = PARAMS_COUNT[:],
    blurb = "your penya balance has reached N",
    avail = avail_penya, fired = ev_penya_at,
  },
  {
    kind = .Mob_In_Range, name = "mob_in_range", params = PARAMS_MOB_RANGE[:],
    blurb = "a matching monster is within <radius> (0 = your attack_range)",
    avail = avail_movers, fired = ev_mob_in_range,
  },
  {
    kind = .No_Mob_In_Range, name = "no_mob_in_range", params = PARAMS_RADIUS[:],
    blurb = "NO monster is within <radius> - the spot is cleared out",
    avail = avail_movers, fired = ev_no_mob_in_range,
  },
  {
    kind = .Aggro, name = "aggro", params = PARAMS_RADIUS_OPT[:],
    blurb = "something is coming for YOU (its m_idDest is your objid)",
    avail = avail_aggro, fired = ev_aggro,
  },
  {
    kind = .Player_Near, name = "player_near", params = PARAMS_RADIUS[:],
    blurb = "another PLAYER is within <radius> (the peace-out trigger)",
    avail = avail_players, fired = ev_player_near,
  },
  {
    kind = .Player_Named_Near, name = "player_named_near", params = PARAMS_NAME_RADIUS[:],
    blurb = "a player with that exact name is within <radius>",
    avail = avail_players, fired = ev_player_named_near,
  },
  {
    kind = .Hp_Below, name = "hp_below", params = PARAMS_PERCENT[:],
    blurb = "your HP has dropped below <percent> of maximum",
    avail = avail_hp, fired = ev_hp_below,
  },
  {
    kind = .Target_Hp_Below, name = "target_hp_below", params = PARAMS_PERCENT[:],
    blurb = "the SELECTED mob's HP is below <percent> (0 = it died / stopped being selectable)",
    avail = avail_hp, fired = ev_target_hp_below,
  },
  {
    kind = .At_Position, name = "at_position", params = PARAMS_COORD_RADIUS[:],
    blurb = "you are within <radius> of that world point - the teleport / zone-change confirmation",
    avail = avail_attached, fired = ev_at_position,
  },
  {
    kind = .Pet_Active, name = "pet_active", params = {},
    blurb = "your loot-collecting pet is summoned ('not pet_active' to check it needs calling out)",
    avail = avail_pet, fired = ev_pet_active,
  },
  {
    kind = .Focus_Lost, name = "focus_lost", params = {},
    blurb = "nothing is selected right now (the target died, or was dropped)",
    avail = avail_attached, fired = ev_focus_lost,
  },
  {
    kind = .Stuck, name = "stuck", params = {},
    blurb = "a walk stopped making progress (posted by walk_to before it gives up)",
    fired = ev_stuck,
  },

  // --- NOT YET IMPLEMENTED (see the note on the action side) -----------------------------------
  {
    kind = .Chat_Msg, name = "chat_msg", params = PARAMS_TEXT[:],
    blurb = "a chat message containing <text> appeared",
    avail = na_chat_read, fired = ev_not_implemented,
  },
  {
    kind = .Whisper_From, name = "whisper_from", params = PARAMS_NAME[:],
    blurb = "that player whispered you",
    avail = na_chat_read, fired = ev_not_implemented,
  },
  {
    kind = .Captcha, name = "captcha", params = {},
    blurb = "an anti-bot CAPTCHA popup appeared",
    avail = na_captcha, fired = ev_not_implemented,
  },
}

// --- lookup ---------------------------------------------------------------------------------

action_def :: proc(kind: Script_Action_Kind) -> ^Action_Def {
  for &d in ACTIONS {
    if d.kind == kind {
      return &d
    }
  }
  return nil
}

action_def_by_name :: proc(name: string) -> ^Action_Def {
  for &d in ACTIONS {
    if d.name == name {
      return &d
    }
  }
  return nil
}

event_def :: proc(kind: Script_Event_Kind) -> ^Event_Def {
  for &d in EVENTS {
    if d.kind == kind {
      return &d
    }
  }
  return nil
}

event_def_by_name :: proc(name: string) -> ^Event_Def {
  for &d in EVENTS {
    if d.name == name {
      return &d
    }
  }
  return nil
}

action_name :: proc(kind: Script_Action_Kind) -> string {
  if d := action_def(kind); d != nil {
    return d.name
  }
  return "?"
}

event_name :: proc(kind: Script_Event_Kind) -> string {
  if d := event_def(kind); d != nil {
    return d.name
  }
  return "?"
}

// --- action implementations -------------------------------------------------------------------

act_wait_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  step.scratch.started_at = ctx.now
  return .Running
}

act_wait_poll :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  if ctx.now - step.scratch.started_at >= script_secs_ns(step.action.nums[0]) {
    return .Done
  }
  return .Running
}

act_var_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  engine.session_var_set(&ctx.session.eng, step.action.strs[0], step.action.strs[1])
  return .Done
}

act_add_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  name := step.action.strs[0]
  cur := f64(0)
  if s, ok := engine.session_var_get(&ctx.session.eng, name); ok {
    if v, vok := strconv.parse_f64(strings.trim_space(s)); vok {
      cur = v
    }
  }
  cur += step.action.nums[0]
  // Whole values print without a trailing ".000" so a counter reads as a counter.
  txt := cur == f64(i64(cur)) ? fmt.tprintf("%d", i64(cur)) : fmt.tprintf("%v", cur)
  engine.session_var_set(&ctx.session.eng, name, txt)
  return .Done
}

act_stop_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  ctx.session.script.stop_requested = true
  return .Done
}

// --- event implementations ---------------------------------------------------------------------

ev_always :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return true
}

ev_never :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return false
}

// --- availability predicates ---------------------------------------------------------------------

avail_attached :: proc(session: ^Session) -> (bool, string) {
  if !session.attached || session.ptr_size != 4 {
    return false, "needs a 32-bit Neuz attached"
  }
  return true, ""
}

avail_moveto :: proc(session: ^Session) -> (bool, string) {
  if ok, why := avail_attached(session); !ok {
    return false, why
  }
  if !moveto_configured(session) {
    return false, "needs the move offsets - run 'findmove' (or 'setup <name>')"
  }
  return true, ""
}

avail_jump :: proc(session: ^Session) -> (bool, string) {
  if ok, why := avail_attached(session); !ok {
    return false, why
  }
  if !jump_configured(session) {
    return false, "needs sendactmsg_rva/actmover_off/jump_msg - run 'findmove'"
  }
  return true, ""
}

avail_move_and_jump :: proc(session: ^Session) -> (bool, string) {
  if ok, why := avail_moveto(session); !ok {
    return false, why
  }
  return avail_jump(session)
}

// The tile-window mover gather (radar_gather_movers) needs the landscape object arrays.
avail_movers :: proc(session: ^Session) -> (bool, string) {
  if ok, why := avail_attached(session); !ok {
    return false, why
  }
  L := session.layout
  if L.landobj_off == 0 || L.land_off == 0 || L.landwidth_off == 0 {
    return false, "needs the landscape offsets - run 'setup <name>' (worldscan)"
  }
  return true, ""
}

avail_players :: proc(session: ^Session) -> (bool, string) {
  if ok, why := avail_movers(session); !ok {
    return false, why
  }
  if !prop_gate_ready(session) {
    return false, "can't tell players from monsters without the species gate - run 'findprop'"
  }
  return true, ""
}

avail_aggro :: proc(session: ^Session) -> (bool, string) {
  if ok, why := avail_movers(session); !ok {
    return false, why
  }
  if session.layout.objid_off == 0 || session.layout.iddest_off == 0 {
    return false, "needs objid_off/iddest_off - run 'setup <name>' (findsettarget)"
  }
  return true, ""
}

// --- movement + combat actions ---------------------------------------------------------------------

// A script owns movement. Handing steering to the auto-brain is what `farm` / `sweep_to` are FOR, so
// every other movement block refuses while auto is running rather than fighting it for the character.
script_movement_ok :: proc(ctx: ^Behaviour_Context, what: string) -> bool {
  if !ctx.session.auto_on {
    return true
  }
  fmt.printf(
    "\n[script] '%s' needs the auto-farm off (it steers the character too).\n  fix: 'auto off' before the script, or wrap the farming in a 'farm ... until <event>' block.\n",
    what,
  )
  fmt.print("memscan> ")
  return false
}

act_walk_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  if !script_movement_ok(ctx, "walk_to") {
    return .Failed
  }
  ppos, pok := read_player_pos(ctx.session)
  if !pok {
    return .Failed
  }
  dest := [3]f32{f32(step.action.nums[0]), ppos[1], f32(step.action.nums[1])}
  if !write_dest_pos(ctx.session, ppos, dest) {
    return .Failed // refused (an avoid(!) fence zone) or the player couldn't be resolved
  }
  remote_send_snapshot(ctx.session) // so other clients see a walk, not a teleport
  step.scratch.wp = dest
  step.scratch.best = engine.dist_horizontal(ppos, dest)
  step.scratch.progress_at = ctx.now
  return .Running
}

act_walk_poll :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  ppos, pok := read_player_pos(ctx.session)
  if !pok {
    return .Running // transient read failure - keep walking
  }
  d := engine.dist_horizontal(ppos, step.scratch.wp)
  if d <= SWEEP_ARRIVE {
    return .Done
  }
  if d < step.scratch.best - PROGRESS_EPS {
    step.scratch.best = d
    step.scratch.progress_at = ctx.now
    return .Running
  }
  if ctx.now - step.scratch.progress_at >= STUCK_NS {
    // Give up on this leg but let the script continue, and post Stuck so `on stuck -> ...` and
    // `sense` can see it. Same judgement sweep_tick makes about a jammed hop: whatever is in the way
    // is usually transient (a mob body, another player), and hard-failing the whole run over one
    // blocked leg would kill a long patrol for a temporary obstacle.
    behaviour_raise(ctx.session, .Stuck, Behaviour_Signal{at = ctx.now, num = f64(d)})
    fmt.printf("\n[script] walk_to: no progress for %.0fs, %.0f units short - moving on.\n", f64(STUCK_NS) / 1e9, d)
    fmt.print("memscan> ")
    return .Done
  }
  return .Running
}

// Halt the walk on ANY exit - arrival, `script stop`, an interrupt, a detach. This is the phase the
// old hardcoded modes never had, and it is exactly why stopping a script stops the character instead
// of letting it drift to the waypoint.
act_walk_exit :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) {
  move_stop(ctx.session)
}

act_jump_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  ret, ok := remote_send_actmsg(ctx.session, ctx.session.layout.jump_msg)
  if !ok {
    return .Failed
  }
  if ret == 1 {
    ctx.session.jump_fired_at = ctx.now // radar dot-hop animation
    remote_send_playermoved(ctx.session) // broadcast so others see it
  }
  // A refused jump (airborne / casting / sitting) is not a script error - the client's own guards
  // said no, which is normal mid-combat. Report Done either way.
  return .Done
}

act_jump_to_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  if !script_movement_ok(ctx, "jump_to") {
    return .Failed
  }
  ppos, pok := read_player_pos(ctx.session)
  if !pok {
    return .Failed
  }
  dest := [3]f32{f32(step.action.nums[0]), ppos[1], f32(step.action.nums[1])}
  if !write_dest_pos(ctx.session, ppos, dest) {
    return .Failed
  }
  remote_send_snapshot(ctx.session)
  return act_jump_start(ctx, step) // walking + jumping = a directional jump
}

act_target_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  names := parse_target_names(step.action.strs[0])
  res, _, _, _, _ := tc_select(ctx.session, names[:], false)
  #partial switch res {
  case .AnchorFail, .WriteFail:
    return .Failed
  }
  // NoCandidates / AllOnCooldown are ordinary conditions (nothing nearby right now), not errors -
  // a script gates on mob_in_range if it cares.
  return .Done
}

// --- farm (hands steering to the auto-brain) --------------------------------------------------------

act_farm_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  s := ctx.session
  spec := strings.trim_space(step.action.strs[0])
  cmd := spec == "" ? "auto" : fmt.tprintf("auto %s", spec)
  // Routed through the REPL rather than reimplemented: cli_auto owns the arming semantics (starts
  // paused, the F10 re-arm spec, the name parsing, the printed summary) and duplicating any of that
  // here is how the two would drift. NOTE: execute_line frees the temp allocator on the way out, so
  // nothing temp-allocated may be read after this call.
  if s.exec_line != nil {
    s.exec_line(&s.eng, cmd)
  }
  s.script.auto_owned = true
  return .Running
}

act_farm_poll :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  // The `until` event is checked by the walker before this. Without one, the block ends when auto
  // turns itself off (its own 'timer' / 'kills' quota, or F10).
  if !ctx.session.auto_on {
    return .Done
  }
  return .Running
}

act_farm_exit :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) {
  if ctx.session.script.auto_owned {
    auto_stop(ctx.session)
    ctx.session.script.auto_owned = false
  }
}

// --- sweep ---------------------------------------------------------------------------------------

act_sweep_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  s := ctx.session
  if s.sweep_on {
    return .Failed // a lane is already armed; two routes would fight
  }
  if s.layout.attack_range <= 0 {
    return .Failed // attack_range IS the brush width
  }
  world, _, ppos, aok := tc_resolve_anchors(s)
  if !aok {
    return .Failed
  }
  wip: Sweep_Wip
  defer sweep_wip_free(&wip)
  sweep_wip_begin(&wip, ppos)
  sweep_wip_extend(s, world, &wip, f32(step.action.nums[0]), f32(step.action.nums[1]), ppos[1])
  if !sweep_arm(s, &wip) {
    return .Failed // too short, or blocked right at the start (sweep_arm printed why)
  }
  // A painted lane is walked by sweep_tick, which only runs inside auto_tick - so sweeping means
  // handing steering to the auto-brain, exactly like `farm`.
  if !s.auto_on {
    if s.exec_line != nil {
      s.exec_line(&s.eng, "auto")
    }
    s.script.auto_owned = true
  }
  return .Running
}

act_sweep_poll :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  if !ctx.session.sweep_on {
    return .Done // sweep_finish cleared it - the lane is swept
  }
  return .Running
}

act_sweep_exit :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) {
  if ctx.session.sweep_on {
    sweep_clear(ctx.session) // also halts an in-flight hop
  }
  if ctx.session.script.auto_owned {
    auto_stop(ctx.session)
    ctx.session.script.auto_owned = false
  }
}

// --- misc actions ------------------------------------------------------------------------------------

act_alert_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  win.MessageBeep(0xFFFFFFFF) // MB_OK-ish default beep; the radar's raylib audio device is window-scoped
  return .Done
}

act_pause_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  cli_pause(ctx.session, {})
  return .Done
}

act_run_cmd_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  s := ctx.session
  if s.exec_line != nil {
    s.exec_line(&s.eng, step.action.strs[0])
  }
  return .Done
}

// --- event implementations (Stage 2) ------------------------------------------------------------------

ev_kills_arm :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) {
  st.base_i64 = i64(ctx.session.auto_count)
}

ev_kills :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return i64(ctx.session.auto_count) - st.base_i64 >= i64(ev.nums[0])
}

ev_kills_of_arm :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) {
  st.base_i64 = i64(script_kills_of(&ctx.session.script, ev.strs[0]))
}

ev_kills_of :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return i64(script_kills_of(&ctx.session.script, ev.strs[0])) - st.base_i64 >= i64(ev.nums[1])
}

ev_elapsed :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return ctx.now - st.armed_at >= i64(ev.nums[0] * 60 * 1e9)
}

// Reads the sense Board rather than re-walking the inventory: the sense layer already paid for it
// this tick, on its own throttle (see SENSES in behaviour.odin).
ev_inv_full :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return engine.board_has(ctx.board, Behaviour_Event.Inv_Full)
}

ev_focus_lost :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return engine.board_has(ctx.board, Behaviour_Event.Focus_Lost)
}

ev_stuck :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return engine.board_has(ctx.board, Behaviour_Event.Stuck)
}

ev_penya_at :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return ctx.session.penya_last >= i64(ev.nums[0])
}

ev_hp_below :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  s := ctx.session
  player := read_ptr_at(s.proc_info.handle, s.proc_info.base + s.layout.player_rva, engine.Value_Type.U32)
  if player == 0 {
    return false
  }
  hp, ok := read_mob_hp(s, player)
  if !ok {
    return false
  }
  // maxHP is the field right after currentHP (see the hp_off note in flyff.odin).
  maxv, mok := engine.read_value(s.proc_info.handle, player + uintptr(s.layout.hp_off + 4), .I32)
  if !mok {
    return false
  }
  maxhp := i64(i32(engine.value_as_u64(.I32, maxv)))
  if maxhp <= 0 {
    return false
  }
  return f64(hp) * 100.0 / f64(maxhp) < ev.nums[0]
}

// --- mover-gathering events ------------------------------------------------------------------------
// All four share one bounded, camera-independent gather (radar_gather_movers - the same one the radar
// runs at 30fps), throttled here and pointed at the behaviour machine's own arena so the watcher tick
// never accumulates temp allocations. See behaviour_scratch.

EV_MOVER_POLL_NS :: i64(500_000_000)
EV_MOVER_RADIUS_MAX :: f32(200)

// Uses context.temp_allocator, which behaviour_tick has already pointed at the machine's own arena
// for the whole tick (see behaviour_scratch) - so the per-tile scratch inside radar_gather_movers is
// reclaimed with everything else at the top of the next tick, instead of accumulating forever on a
// thread that has no free_all boundary.
script_gather_movers :: proc(ctx: ^Behaviour_Context, radius: f32, filter: []string) -> []Radar_Blip {
  s := ctx.session
  world, player, ppos, ok := tc_resolve_anchors(s)
  if !ok {
    return nil
  }
  propbase, player_ai := radar_prop_ctx(s, player)
  blips := make([dynamic]Radar_Blip, context.temp_allocator)
  cache := make(map[uintptr]Radar_Name_Entry, 16, context.temp_allocator)
  r := clamp(radius, 1, EV_MOVER_RADIUS_MAX)
  radar_gather_movers(s, world, player, propbase, player_ai, ppos[0], ppos[2], r, &blips, filter, &cache, ctx.now)
  return blips[:]
}

// Throttle gate: these cost a real enumeration, so they answer from the last result between polls.
script_mover_due :: proc(ctx: ^Behaviour_Context, st: ^Event_State) -> bool {
  if ctx.now < st.next_poll {
    return false
  }
  st.next_poll = ctx.now + EV_MOVER_POLL_NS
  return true
}

ev_mob_in_range :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  if !script_mover_due(ctx, st) {
    return st.base_i64 != 0 // hold the last verdict until the next poll is due
  }
  radius := f32(ev.nums[0])
  if radius <= 0 {
    radius = ctx.session.layout.attack_range
  }
  names := parse_target_names(ev.strs[0])
  hit := false
  for b in script_gather_movers(ctx, radius, names[:]) {
    if b.kind == .Monster || b.kind == .Unclassified {
      hit = true
      break
    }
  }
  st.base_i64 = hit ? 1 : 0
  return hit
}

ev_no_mob_in_range :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  if !script_mover_due(ctx, st) {
    return st.base_i64 != 0
  }
  clear_ := true
  for b in script_gather_movers(ctx, f32(ev.nums[0]), nil) {
    if b.kind == .Monster || b.kind == .Unclassified {
      clear_ = false
      break
    }
  }
  st.base_i64 = clear_ ? 1 : 0
  return clear_
}

ev_player_near :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  if !script_mover_due(ctx, st) {
    return st.base_i64 != 0
  }
  hit := false
  for b in script_gather_movers(ctx, f32(ev.nums[0]), nil) {
    if b.kind == .Player {
      hit = true
      break
    }
  }
  st.base_i64 = hit ? 1 : 0
  return hit
}

ev_player_named_near :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  if !script_mover_due(ctx, st) {
    return st.base_i64 != 0
  }
  want := ev.strs[0]
  hit := false
  for b in script_gather_movers(ctx, f32(ev.nums[1]), nil) {
    if b.kind != .Player {
      continue
    }
    if nm, ok := read_mover_name(ctx.session, b.obj); ok && nm == want {
      hit = true
      break
    }
  }
  st.base_i64 = hit ? 1 : 0
  return hit
}

ev_aggro :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  if !script_mover_due(ctx, st) {
    return st.base_i64 != 0
  }
  my_id, idok := read_player_objid(ctx.session)
  if !idok || my_id == 0 {
    return false
  }
  radius := f32(ev.nums[0])
  if radius <= 0 {
    radius = EV_MOVER_RADIUS_MAX
  }
  hit := false
  for b in script_gather_movers(ctx, radius, nil) {
    if b.kind != .Monster && b.kind != .Unclassified {
      continue
    }
    if mob_targets_player(ctx.session, b.obj, my_id) {
      hit = true
      break
    }
  }
  st.base_i64 = hit ? 1 : 0
  return hit
}

// --- press_key ------------------------------------------------------------------------------------

avail_press_key :: proc(session: ^Session) -> (bool, string) {
  if !session.attached {
    return false, "needs a Neuz attached"
  }
  if _, ok := game_window(session); !ok {
    return false, "can't find the game's main window to post keys to (is it minimised to tray?)"
  }
  return true, ""
}

act_press_key_start :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  vk, ok := vk_from_name(step.action.strs[0])
  if !ok {
    fmt.printf("\n[script] press_key: '%s' isn't a key name (try 1-9, a-z, f1-f12, space, enter).\n", step.action.strs[0])
    fmt.print("memscan> ")
    return .Failed
  }
  if !key_post(ctx.session, vk, true) {
    return .Failed
  }
  step.scratch.started_at = ctx.now
  step.scratch.flag = true // the key is DOWN - exit must release it (see keys.odin)
  return .Running
}

act_press_key_poll :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  if ctx.now - step.scratch.started_at < KEY_HOLD_NS {
    return .Running
  }
  return .Done // exit releases it - one place, so completion and abort behave identically
}

// Release on EVERY exit path: completion, `script stop`, an interrupt, a detach. A key left down
// would keep firing whatever it is bound to with nothing left running to stop it.
act_press_key_exit :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) {
  if !step.scratch.flag {
    return
  }
  if vk, ok := vk_from_name(step.action.strs[0]); ok {
    key_post(ctx.session, vk, false)
  }
  step.scratch.flag = false
}

// --- target / position events -----------------------------------------------------------------------

// The SELECTED mob's HP as a percentage. Same shape as ev_hp_below but anchored on m_pObjFocus, so a
// boss fight can end on "it died" rather than a fixed timer. Reports false with nothing selected,
// which is what makes `while not target_hp_below 1` terminate when the mob despawns.
ev_target_hp_below :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  s := ctx.session
  focus, ok := read_focus_ptr(s)
  if !ok || focus == 0 || !focus_obj_live(s, focus) {
    return false
  }
  hp, hok := read_mob_hp(s, focus)
  if !hok {
    return false
  }
  maxv, mok := engine.read_value(s.proc_info.handle, focus + uintptr(s.layout.hp_off + 4), .I32)
  if !mok {
    return false
  }
  maxhp := i64(i32(engine.value_as_u64(.I32, maxv)))
  if maxhp <= 0 {
    return false
  }
  return f64(hp) * 100.0 / f64(maxhp) < ev.nums[0]
}

avail_pet :: proc(session: ^Session) -> (bool, string) {
  if ok, why := avail_attached(session); !ok {
    return false, why
  }
  if session.layout.petid_off == 0 {
    return false, "needs petid_off - summon/unsummon your pet and diff the player object, then 'set petid_off 0x..'"
  }
  return true, ""
}

// Is the loot-collecting pet out? This is the client's own HasActivatedSystemPet() test, which is
// literally `m_dwPetId != NULL_ID`: the field holds the INVENTORY SLOT of the summoned pet item, and
// NULL_ID (0xFFFFFFFF) when nothing is out.
//
// Worth knowing if this ever needs re-deriving: there is no pointer link to follow. The player object
// holds no pointer to the pet, and the pet holds none back - verified by scanning all writable memory
// for both addresses while a pet was out. The association is by slot/OBJID only, so this field (or the
// pet's OBJID at a neighbouring offset) is the only honest signal.
ev_pet_active :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  s := ctx.session
  player := read_ptr_at(s.proc_info.handle, s.proc_info.base + s.layout.player_rva, engine.Value_Type.U32)
  if player == 0 {
    return false
  }
  v, ok := engine.read_value(s.proc_info.handle, player + uintptr(s.layout.petid_off), .U32)
  if !ok {
    return false
  }
  return u32(engine.value_as_u64(.U32, v)) != NULL_ID
}

// Are we standing within <radius> of a world point? The teleport / zone-change confirmation: after a
// hotkey teleport, this is how a script tells "it worked" from "it was on cooldown / I'm still here".
ev_at_position :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  ppos, ok := read_player_pos(ctx.session)
  if !ok {
    return false
  }
  target := [3]f32{f32(ev.nums[0]), ppos[1], f32(ev.nums[1])}
  return engine.dist_horizontal(ppos, target) <= f32(ev.nums[2])
}

// --- NOT-YET blocks: availability + stubs ---------------------------------------------------------
// Each `why` names the specific recon that would unblock the block, so `script blocks` reads as a
// worklist rather than a list of apologies. The stubs below are unreachable in practice (a run is
// refused before it starts) and exist as defence in depth.

na_attack :: proc(session: ^Session) -> (bool, string) {
  return false, "no attack primitive yet (you hold the attack key today) - needs SendActMsg(OBJMSG_ATTACK..) recon, like derive_jump_msg did for jump"
}

na_chat_send :: proc(session: ^Session) -> (bool, string) {
  return false, "needs chat-send recon (the client's own say/whisper packet builder)"
}

na_chat_read :: proc(session: ^Session) -> (bool, string) {
  return false, "needs chat-read recon (where incoming chat lands, and how to watch it)"
}

na_npc :: proc(session: ^Session) -> (bool, string) {
  return false, "needs NPC interaction + menu recon (dialogue open / menu select packets)"
}

na_sweep_record :: proc(session: ^Session) -> (bool, string) {
  return false, "needs path recording + serialization (the 2.0 backlog item) - 'sweep to <x,z>' works today"
}

na_captcha :: proc(session: ^Session) -> (bool, string) {
  return false, "needs CAPTCHA popup recon (finding the dialog's live state)"
}

act_not_implemented :: proc(ctx: ^Behaviour_Context, step: ^Script_Step) -> Step_Status {
  return .Failed // unreachable: script_check_avail refuses the run before it starts
}

ev_not_implemented :: proc(ctx: ^Behaviour_Context, ev: Script_Event, st: ^Event_State) -> bool {
  return false
}

// --- shared helpers used by the tables ---------------------------------------------------------

// Seconds -> nanoseconds, guarding against a negative literal.
script_secs_ns :: proc(secs: f64) -> i64 {
  if secs <= 0 {
    return 0
  }
  return i64(secs * 1e9)
}
