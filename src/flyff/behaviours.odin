package flyff

import "core:fmt"
import "core:time"

import "../engine"

// ===========================================================================
// Built-in behaviours - the registry `script run <name>` selects from.
//
// Each is a plain Odin proc that builds a rule list. This is the library surface in use: Odin's own
// control flow does the static work (factoring into procs, repeating over config), and only a genuine
// runtime decision becomes a rule.
//
// The first group are the ones a person picks from. The second are the VERIFICATION behaviours - they
// use no game state, so they run fully detached and are what `script selftest` proves the block
// vocabulary with.
// ===========================================================================

Behaviour_Def :: struct {
  name:  string,
  blurb: string,
  test:  bool, // runs with nothing attached (the verification set)
  build: proc(b: ^Rule_Builder),
  route: string, // the waypoint set `patrol` walks, for a behaviour that has one
}

// The behaviours a PERSON picks from.
BEHAVIOURS := [?]Behaviour_Def {
  {
    name = "auto", blurb = "the farm loop: kill whatever is around, nearest threat first",
    build = bh_auto,
  },
  {
    name = "hunt", blurb = "commit to one monster and never drop it - step around jams instead",
    build = bh_hunt,
  },
  {
    name = "sweep", blurb = "clear a painted lane, taking only what is already in reach ('sweep to x,z')",
    build = bh_sweep,
  },
}

// The VERIFICATION set. Both run with nothing attached and end at a documented set of variables, which
// is how a change to the block vocabulary gets proved without a game client - script_selftest_behaviours
// runs them and checks the numbers, and `script run t_vars` still works if you name one.
//
// THERE USED TO BE TEN. Eight of them tested CONTROL FLOW - repeat counting, if/else, three-deep
// nesting, a back-edge loop, a two-armed branch, an interrupt region resuming the main program, a
// failing block taking its wired fail edge, and the same failure with no edge at all. Every one of
// those claims was about the graph, and the graph is gone; what replaced them is
// script_selftest_rules, which proves the four rules of arbitration directly against a real rule list
// (first match wins, higher preempts lower, the lower one RESUMES, a failure aborts the rest).
//
// These two survive because neither was ever about control flow. They are the only automated coverage
// of what a BLOCK does: that a variable written by one step can be read by a later condition, that
// `@name` interpolates in a value, and that `chance` rolls fresh on every ask instead of being a
// constant or a cached first answer.
TEST_BEHAVIOURS := [?]Behaviour_Def {
  {
    name = "t_vars", blurb = "variables: @name interpolation, var_is, var_below (tv_saw_d=1, tv_saw_a=1, tv_counted=3)", test = true,
    build = bh_test_vars,
  },
  {
    name = "t_random", blurb = "chance rolls fresh per ask (tr_flips=40, 0<tr_heads<40)", test = true,
    build = bh_test_random,
  },
}

// Resolve a name across BOTH registries. The test set is hidden from the LISTS, not from the tool:
// `script run t_vars` and `script show t_random` still work, which is what makes them usable as
// verification at all.
behaviour_def :: proc(name: string) -> ^Behaviour_Def {
  for &d in BEHAVIOURS {
    if d.name == name {
      return &d
    }
  }
  for &d in TEST_BEHAVIOURS {
    if d.name == name {
      return &d
    }
  }
  return nil
}

// ===========================================================================
// THE BUILT-IN BEHAVIOURS
//
// The numbers make the migration's point better than any argument: `auto` was 19 nodes and 14 wires,
// `hunt` was 16 and 12, and each is now ONE ROW. The priority ladder did not go anywhere - it lives
// inside `kill`, which calls tc_pick_one, which IS the ladder. What went away is DRAWING it, and the
// whole Auto_Cfg layer that existed to decide which nodes got emitted.
//
// The three used to be "the same chart with different wiring", which was the honest description of a
// design where behaviour was expressed as edge placement. They are now three different sentences.
// ===========================================================================

// THE FARM LOOP. Kill whatever is around, nearest threat first.
//
// The attack key is deliberately BLANK: `auto` has never pressed one itself. Damage comes from an armed
// interrupt (the `attack` behaviour, trigger focus_live -> press_key F2) or from the player, and wiring
// a key in here would change what `auto` DOES rather than how it is written.
bh_auto :: proc(b: ^Rule_Builder) {
  rule_row(b, "Kill whatever is around", all(always()))
  rule_step(b, do_kill())
}

// HUNT: commit to one monster and never drop it.
//
// This is the clearest case in the whole migration. "Never drop the target" was a flag consulted in
// four separate places inside auto_tick; then it was a chart where hold_target's fail edge pointed at
// approach instead of skip_target, plus sidestep on the approach - i.e. behaviour expressed as where
// two edges point. It is now one argument on one verb.
bh_hunt :: proc(b: ^Rule_Builder) {
  rule_row(b, "Commit to one monster and never let go", all(always()))
  rule_step(b, do_kill(sidestep = true))
}

// SWEEP: clear a painted lane, never leaving it.
//
// Two rows, and their ORDER is the whole rule: anything already in reach is dealt with before the lane
// is driven any further. That used to be a fail-edge chain from sweep_lane into the in-range pick.
//
// `in_range` on the kill is what keeps it on the lane - it replaces the whole ladder with the sweep
// rung, so selection can never propose a walk off the route. Without it the first aggro rung would
// pull the character away, which is the one thing sweep mode exists to prevent.
bh_sweep :: proc(b: ^Rule_Builder) {
  // NOT `always` - that would shadow the lane row below it and the sweep would never move. The
  // rule-list linter catches exactly this, and caught it here.
  rule_row(b, "Clear what is already in reach", all(mob_within("", 0)))
  rule_step(b, do_kill(in_range = true))

  rule_row(b, "Drive the painted lane", all(always()))
  rule_step(b, do_sweep_lane())
}

// ===========================================================================
// THE VERIFICATION BEHAVIOURS
// ===========================================================================

// The read half of the variable story. Four claims, each failing a different way:
//
//   tv_saw_d=1   - the first test took its turn while tv_dir was still "D", matched case-insensitively
//   tv_dir=A     - `var tv_dir @tv_next` copied one variable into another, i.e. a VALUE interpolated
//   tv_saw_a=1   - and the rule below it then saw the NEW value, so a rule's condition is re-read
//   tv_counted=3 - var_below bound a `while` rule, so a numeric read works on text written by `add`
//
// Rule 1 is `once` against `always`, which is how a rule list spells "do this at the start": the
// condition never goes false, so the edge latch means it can never fire twice.
bh_test_vars :: proc(b: ^Rule_Builder) {
  rule_row(b, "Seed the values", all(always()), fire_on_edge = true)
  rule_step(b, do_var("tv_dir", "D"))
  rule_step(b, do_var("tv_next", "A"))

  rule_row(b, "Saw D, and flip to whatever tv_next holds", all(var_is("tv_dir", "d")), fire_on_edge = true)
  rule_step(b, do_add("tv_saw_d", 1))
  rule_step(b, do_var("tv_dir", "@tv_next"))

  rule_row(b, "Saw A", all(var_is("tv_dir", "A")), fire_on_edge = true)
  rule_step(b, do_add("tv_saw_a", 1))

  // A `while` rule bounded by a numeric read of the counter it is incrementing. If var_below compared
  // text instead of numbers this would either never stop or stop on the first pass.
  rule_row(b, "Count to three", all(var_below("tv_counted", 3)))
  rule_step(b, do_add("tv_counted", 1))
}

// The randomness the look-alive behaviours are built from, and the one claim worth making about it:
// `chance` is rolled FRESH on every ask. The two ways that breaks are a roll that is really a constant
// and a roll armed once and then cached for every later visit; both show up here as tr_heads landing
// on exactly 0 or exactly 40.
//
// 40 flips: heads hitting either end has probability 2^-39, so "strictly between" is a safe assertion.
// The two rows share the counter, so every tick is exactly one flip whichever of them wins - the top
// row is the heads case and the bottom is the tails case.
bh_test_random :: proc(b: ^Rule_Builder) {
  rule_row(b, "Heads", all(var_below("tr_flips", 40), chance(50)))
  rule_step(b, do_add("tr_heads", 1))
  rule_step(b, do_add("tr_flips", 1))

  rule_row(b, "Tails", all(var_below("tr_flips", 40)))
  rule_step(b, do_add("tr_flips", 1))
}

// --- the verification run ---------------------------------------------------------------------------

// Run both verification behaviours headlessly and check what they left behind. Synchronous: it drives
// rules_tick by hand rather than waiting on the watcher thread, and neither fixture depends on
// wall-clock time, so the suite cannot go flaky on a slow machine.
script_selftest_behaviours :: proc(session: ^Session) {
  fmt.println("  --- verification behaviours ---")
  fails := 0
  ALL_VARS :: []string {
    "tv_dir", "tv_next", "tv_saw_d", "tv_saw_a", "tv_counted", "tr_flips", "tr_heads",
  }
  get :: proc(session: ^Session, name: string) -> string {
    v, _ := engine.session_var_get(&session.eng, name)
    return v
  }
  run :: proc(session: ^Session, name: string, ticks: int, fails: ^int) -> bool {
    script_stop(session)
    for v in ALL_VARS {
      engine.session_var_set(&session.eng, v, "")
    }
    script_cmd_run(session, []string{name})
    if !session.script.active {
      fmt.eprintfln("  FAIL: '%s' refused to start", name)
      fails^ += 1
      return false
    }
    for _ in 0 ..< ticks {
      ctx := Behaviour_Context {
        session = session,
        now     = time.now()._nsec,
        board   = &session.bh_board,
      }
      rules_tick(&ctx)
    }
    return true
  }

  if run(session, "t_vars", 20, &fails) {
    check :: proc(session: ^Session, name, want: string, fails: ^int) {
      if got := get(session, name); got != want {
        fmt.eprintfln("  FAIL: t_vars left %s='%s', expected '%s'", name, got, want)
        fails^ += 1
      }
    }
    check(session, "tv_saw_d", "1", &fails)
    check(session, "tv_dir", "A", &fails)
    check(session, "tv_saw_a", "1", &fails)
    check(session, "tv_counted", "3", &fails)
  }

  // 40 flips need 40 ticks (one rule runs per tick); 80 gives the list room to settle with both rows
  // false, which is also the state it has to be able to reach.
  if run(session, "t_random", 80, &fails) {
    if get(session, "tr_flips") != "40" {
      fmt.eprintfln("  FAIL: t_random flipped %s times, expected 40", get(session, "tr_flips"))
      fails += 1
    }
    heads := get(session, "tr_heads")
    if heads == "" || heads == "0" || heads == "40" {
      fmt.eprintfln("  FAIL: t_random got %s heads out of 40 - 'chance' is not rolling per ask", heads == "" ? "0" : heads)
      fails += 1
    }
  }
  script_stop(session)
  for v in ALL_VARS {
    engine.session_var_set(&session.eng, v, "")
  }
  if fails == 0 {
    fmt.println("  PASS: variables interpolate and read back, and 'chance' rolls fresh on every ask")
  }
}
