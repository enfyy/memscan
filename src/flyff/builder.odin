package flyff

import "core:strings"

// ===========================================================================
// The authoring vocabulary - the constructors a behaviour is written with in Odin.
//
// This is what is left of the builder. It used to be a whole graph-emission API: a Builder holding a
// nesting stack, a Seq cursor whose depth auto-closed blocks so Odin's braces gave you structure, and
// a set of node emitters (branch, loop_until, loop_times, goto_node, branch_node, wire, call_chart).
// All of it existed to WIRE things, and there is nothing left to wire - a behaviour is an ordered list
// of rules, and a rule's DO is a numbered sequence. See script_rules.odin's Rule_Builder, which is
// what actually assembles one now and is a tenth of the size.
//
// What survives is the part that was never about the graph: VALUES. A condition constructor returns a
// Script_Event, an action constructor returns a Script_Action, and both are just payloads - the same
// payloads the file format writes and the editor edits. They are worth keeping as procs rather than
// letting each caller fill a struct literal, because the SLOT a value lands in is not obvious
// (`killed_of` puts the name in strs[0] and the count in nums[0], counted separately) and getting it
// wrong silently loses the argument on the next save. See the param_slot note in script_blocks.odin.
//
// THE ONE RULE WORTH INTERNALISING, and it did not change: Odin's control flow runs at BUILD time.
// A `for` around rule_step unrolls and is gone; only a condition on a rule is checked live.
// ===========================================================================

// One step, rendered back to the line that produced it. Drives the rule editor's row captions, the
// dock's step readout and the trace ring.
//
// Returns an INDEPENDENTLY allocated string. Both halves of that matter: the render buffer is temp
// so it goes away on its own, and the result is cloned rather than handed back as a slice into that
// buffer - Script_Step.src is deleted by script_step_free, and freeing a trimmed sub-slice passes a
// length that doesn't match the allocation, which corrupts the heap.
step_label :: proc(step: Script_Step) -> string {
  sb := strings.builder_make(context.temp_allocator)
  switch step.op {
  case .Action:
    // display: this is the row's caption and the dock's step readout, so a rolled f64 gets two
    // decimals instead of its full expansion. The file and `script show` still carry the exact value.
    script_write_action(&sb, step.action, display = true)
    if step.has_until {
      strings.write_string(&sb, " until ")
      script_write_condition(&sb, step.until, display = true)
    }
  case .Wait_For:
    strings.write_string(&sb, "wait_for ")
    script_write_condition(&sb, step.condition, display = true)
  }
  return strings.clone(strings.trim_right_space(strings.to_string(sb)))
}

// --- combining conditions -----------------------------------------------------------------------
//
// Row 0 of a Script_Condition is EMBEDDED rather than being more[0], which is why one event is already
// a condition and `all(x)` costs nothing over `x`.

// Every one of them has to hold.
all :: proc(events: ..Script_Event) -> Script_Condition {
  out := Script_Condition{}
  for event, index in events {
    if index >= SCRIPT_MAX_CONDITION_ROWS {
      break
    }
    condition_row_ptr(&out, index)^ = event
    out.row_count = index + 1
  }
  return out
}

// One of them is enough.
any :: proc(evs: ..Script_Event) -> Script_Condition {
  out := all(..evs)
  out.match_any = true
  return out
}

// --- conditions (values, evaluated at run time) -------------------------------------------------
//
// STRING OWNERSHIP: condition constructors BORROW their strings - the value you get back points at
// whatever you passed in (usually a literal). Only storing a condition into a rule clones it, via
// rules_clone_condition in rule_row. Keep it that way: if constructors cloned too, the intermediate
// would leak on every use, and a borrowed literal reaching script_condition_free's delete would
// corrupt the heap. Action constructors are the other way round - see do_key below.

@(private = "file")
ev :: proc(kind: Script_Event_Kind) -> Script_Event {
  return Script_Event{kind = kind}
}

not         :: proc(c: Script_Event) -> Script_Event {out := c; out.negate = !c.negate; return out}
always      :: proc() -> Script_Event {return ev(.Always)}
never       :: proc() -> Script_Event {return ev(.Never)}
no_target   :: proc() -> Script_Event {return ev(.Focus_Lost)}
no_pet      :: proc() -> Script_Event {return not(ev(.Pet_Active))}
pet_out     :: proc() -> Script_Event {return ev(.Pet_Active)}
bag_full    :: proc() -> Script_Event {return ev(.Inv_Full)}
stuck       :: proc() -> Script_Event {return ev(.Stuck)}

killed :: proc(n: int) -> Script_Event {
  c := ev(.Kills)
  c.nums[0] = f64(n)
  return c
}

// NB the slot: nums and strs are counted separately, so `<name> <n>` is strs[0] + nums[0]. See the
// param_slot note in script_blocks.odin - this used to say nums[1] and the number was lost on save.
killed_of :: proc(name: string, n: int) -> Script_Event {
  c := ev(.Kills_Of)
  c.strs[0] = name
  c.nums[0] = f64(n)
  return c
}

after_minutes :: proc(m: f64) -> Script_Event {
  c := ev(.Elapsed)
  c.nums[0] = m
  return c
}

near :: proc(p: [3]f32, radius: f32 = 10) -> Script_Event {
  c := ev(.At_Position)
  c.nums[0] = f64(p[0])
  c.nums[1] = f64(p[2])
  c.nums[2] = f64(radius)
  return c
}

player_within :: proc(radius: f32) -> Script_Event {
  c := ev(.Player_Near)
  c.nums[0] = f64(radius)
  return c
}

player_named_within :: proc(name: string, radius: f32) -> Script_Event {
  c := ev(.Player_Named_Near)
  c.strs[0] = name
  c.nums[0] = f64(radius)
  return c
}

mob_within :: proc(names: string, radius: f32 = 0) -> Script_Event {
  c := ev(.Mob_In_Range)
  c.strs[0] = names
  c.nums[0] = f64(radius)
  return c
}

nothing_within :: proc(radius: f32) -> Script_Event {
  c := ev(.No_Mob_In_Range)
  c.nums[0] = f64(radius)
  return c
}

aggro_on_me :: proc(radius: f32 = 0) -> Script_Event {
  c := ev(.Aggro)
  c.nums[0] = f64(radius)
  return c
}

hp_under :: proc(pct: f64) -> Script_Event {
  c := ev(.Hp_Below)
  c.nums[0] = pct
  return c
}

target_hp_under :: proc(pct: f64) -> Script_Event {
  c := ev(.Target_Hp_Below)
  c.nums[0] = pct
  return c
}

have_target :: proc() -> Script_Event {return ev(.Focus_Live)}
have_pick :: proc() -> Script_Event {return ev(.Picked)}
target_died :: proc() -> Script_Event {return ev(.Target_Died)}

// A clear straight walk to the selected monster. Gate it behind focus_live: with nothing selected this
// is false, so `not target_reachable` on its own would claim something is in the way.
target_reachable :: proc() -> Script_Event {return ev(.Target_Reachable)}

// 0 = your attack_range.
target_within :: proc(range: f64 = 0) -> Script_Event {
  c := ev(.Target_Within)
  c.nums[0] = range
  return c
}

// True <pct> of the time it is asked - the roll behind look-alive's "sometimes take the scenic route".
chance :: proc(pct: f64) -> Script_Event {
  c := ev(.Chance)
  c.nums[0] = pct
  return c
}

penya_at_least :: proc(n: i64) -> Script_Event {
  c := ev(.Penya_At)
  c.nums[0] = f64(n)
  return c
}

// --- reading back what the behaviour set itself --------------------------------------------------
//
// The read halves of do_var / do_add. `not(var_is(...))` is "differs from", `not(var_above(...))` is
// "at most" - there are no separate inverse twins, for the same reason no other predicate has one.

// Text match ignoring case; two numbers compare as numbers. <value> may itself be `@other`.
var_is :: proc(name: string, value: string) -> Script_Event {
  c := ev(.Var_Is)
  c.strs[0] = name
  c.strs[1] = value
  return c
}

// Strictly above. An unset (or non-numeric) variable reads as 0.
var_above :: proc(name: string, n: f64) -> Script_Event {
  c := ev(.Var_Above)
  c.strs[0] = name
  c.nums[0] = n
  return c
}

// Strictly below. An unset (or non-numeric) variable reads as 0.
var_below :: proc(name: string, n: f64) -> Script_Event {
  c := ev(.Var_Below)
  c.strs[0] = name
  c.nums[0] = n
  return c
}

// --- actions (what a rule's DO is made of) --------------------------------------------------------
//
// These CLONE their strings, the opposite of the condition constructors above, because an action goes
// straight onto a step and script_step_free deletes what it finds there. rule_step clones again on the
// way in, so the intermediate is freed with the temp arena rather than leaked - the asymmetry is the
// same one builder.odin always had, and it is written down here because it is the one thing about this
// file that will bite someone.

do_stop :: proc() -> Script_Action {return Script_Action{kind = .Stop}}
do_fail :: proc() -> Script_Action {return Script_Action{kind = .Fail}}
do_alert_clear :: proc() -> Script_Action {return Script_Action{kind = .Alert_Clear}}

do_alert :: proc(message := "", severity := "warn", seconds := ALERT_DEFAULT_SECONDS, beep := false) -> Script_Action {
  a := Script_Action{kind = .Alert}
  a.strs[0] = strings.clone(message)
  a.strs[1] = strings.clone(severity)
  a.nums[0] = seconds
  a.nums[1] = beep ? 1 : 0
  return a
}

do_key :: proc(k: string) -> Script_Action {
  a := Script_Action{kind = .Press_Key}
  a.strs[0] = strings.clone(k)
  return a
}

do_wait :: proc(secs: f64) -> Script_Action {
  a := Script_Action{kind = .Wait}
  a.nums[0] = secs
  return a
}

do_wait_between :: proc(lo, hi: f64) -> Script_Action {
  a := Script_Action{kind = .Wait_Random}
  a.nums[0] = lo
  a.nums[1] = hi
  return a
}

// Set a variable. <value> may be `@other`, which is expanded when the step runs.
do_var :: proc(name, value: string) -> Script_Action {
  a := Script_Action{kind = .Var}
  a.strs[0] = strings.clone(name)
  a.strs[1] = strings.clone(value)
  return a
}

// Add to a variable, treating an unset one as 0.
do_add :: proc(name: string, delta: f64 = 1) -> Script_Action {
  a := Script_Action{kind = .Add}
  a.strs[0] = strings.clone(name)
  a.nums[0] = delta
  return a
}

// THE VERB: scan, pick, walk in, fight, count - the whole kill chain, which used to be fourteen wired
// blocks. <names> empty means anything attackable; <key> empty means "press nothing", which is what
// `auto` wants because its damage comes from an armed interrupt.
do_kill :: proc(names := "", key := "", sidestep := false, in_range := false) -> Script_Action {
  a := Script_Action{kind = .Kill}
  a.strs[0] = strings.clone(names)
  a.strs[1] = strings.clone(key)
  a.nums[1] = sidestep ? 1 : 0
  a.nums[2] = in_range ? 1 : 0
  return a
}

do_sweep_lane :: proc() -> Script_Action {return Script_Action{kind = .Sweep_Lane}}
do_patrol :: proc() -> Script_Action {return Script_Action{kind = .Patrol}}
