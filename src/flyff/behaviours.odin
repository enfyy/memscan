package flyff

import "core:strings"
import "core:time"

// ===========================================================================
// Built-in behaviours - the registry `script run <name>` selects from.
//
// Each is a plain Odin proc that builds a program. This is the library surface in use: Odin's own
// control flow does the static work (factoring into procs, repeating over config), and only genuine
// runtime decisions become nodes.
//
// The first group are the VERIFICATION behaviours. They exist because they were the headless test
// suite - originally .ms files - and that coverage had to survive the text parser being deleted.
// They deliberately use no game state, so they run fully detached and prove the walker, jump
// resolution, loop counting, interrupt edges and mode handling without a client attached.
// ===========================================================================

Behaviour_Def :: struct {
  name:  string,
  blurb: string,
  test:  bool, // runs with nothing attached (the verification set)
  build: proc(b: ^Builder),
}

// The behaviours a PERSON picks from. Kept separate from TEST_BEHAVIOURS below so the browser and
// `script list` show four rows instead of thirteen - nine verification charts at the top of a chooser
// is a list you have to read past every time to reach the one you want.
BEHAVIOURS := [?]Behaviour_Def {
  {
    name = "auto", blurb = "the farm loop as a chart: scan, the priority ladder, engage, hold, count",
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
  {
    name = "clockworks", blurb = "example dungeon run (needs the game + findmove + hotkeys)",
    build = bh_clockworks,
  },
}

// The VERIFICATION set. Every one of these runs with nothing attached and ends at a documented set of
// variables, which is how a VM change gets proved without a game client - `script selftest` round-trips
// them all, and `script run t_flow` still works if you name one.
//
// They are hidden from the browser and from `script list`, not deleted: they are the only automated
// evidence that the walker, the graph ops, the interrupt regions and the file format still do what they
// say. Deleting them would buy a shorter list and cost the ability to notice a regression at all.
TEST_BEHAVIOURS := [?]Behaviour_Def {
  {
    name = "t_flow", blurb = "control flow: repeat counting, if/else branching", test = true,
    build = bh_test_flow,
  },
  {
    name = "t_loop", blurb = "loop mode: increments a counter forever until stopped", test = true,
    build = bh_test_loop,
  },
  {
    name = "t_interrupt", blurb = "interrupt edges: two watchers, first-match-wins, fires once each", test = true,
    build = bh_test_interrupt,
  },
  {
    name = "t_nesting", blurb = "nested blocks close correctly without end() pairs", test = true,
    build = bh_test_nesting,
  },
  {
    name = "t_graph", blurb = "graph ops: a back-edge loop and a two-armed branch (g_spins>0, g_done=1)", test = true,
    build = bh_test_graph,
  },
  {
    name = "t_irq", blurb = "an interrupt region runs a timed body then resumes (irq_a=1, irq_b=1)", test = true,
    build = bh_test_irq,
  },
  {
    name = "t_failedge", blurb = "a failing action takes its wired fail edge (fe_ok=1, fe_bad unset)", test = true,
    build = bh_test_fail_edge,
  },
  {
    name = "t_failstop", blurb = "a failing action with NO fail edge still ends the run (fe_after unset)", test = true,
    build = bh_test_fail_stop,
  },
  {
    name = "t_random", blurb = "chance rolls per visit and wait_random waits (flips=40, 0<heads<40)", test = true,
    build = bh_test_random,
  },
  {
    name = "t_vars", blurb = "a chart reads back what it set: @name in arguments + var_is/var_above (dir=A, saw_d=1, saw_a=1)", test = true,
    build = bh_test_vars,
  },
}

// Resolve a name across BOTH registries. The test set is hidden from the LISTS, not from the tool:
// `script run t_flow` and `script show t_graph` still work, which is what makes them usable as
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

// --- verification behaviours ---------------------------------------------------------------------

// Mirrors the old demo.ms exactly: counter should end at 7 (1 + 2*3), hits at 1, misses unset.
bh_test_flow :: proc(b: ^Builder) {
  s := seq(b)
  set_var(&s, "greeting", "hello")
  add_var(&s, "counter", 1)

  // Odin's for would unroll this; loop_times keeps it a single runtime node, which is what the
  // old `repeat 3` compiled to - so the test still covers the runtime loop path.
  {
    r := loop_times(&s, 3)
    add_var(&r, "counter", 2)
    wait(&r, 0.05)
  }
  {
    hit := branch(&s, always())
    add_var(&hit, "hits", 1)
  }
  {
    miss := branch(&s, never())
    add_var(&miss, "misses", 1)
  }
  wait(&s, 0.05)
}

bh_test_loop :: proc(b: ^Builder) {
  b.mode = .Loop
  s := seq(b)
  add_var(&s, "spins", 1)
  wait(&s, 0.05)
}

// Both conditions are always true, so the first should win each tick and each should fire exactly
// ONCE (edge-triggered, then latched) rather than every 20ms.
bh_test_interrupt :: proc(b: ^Builder) {
  s := seq(b)
  on(&s, always(), do_add("first"))
  on(&s, always(), do_add("second"))
  wait(&s, 30)
}

// Three levels deep, closed purely by scope exit. depth_c must run once, depth_b twice, depth_a
// three times if the auto-closing and jump resolution are right.
bh_test_nesting :: proc(b: ^Builder) {
  s := seq(b)
  {
    a := loop_times(&s, 3)
    add_var(&a, "depth_a", 1)
    {
      bb := branch(&a, always())
      add_var(&bb, "depth_b", 1)
      {
        c := branch(&bb, never())
        add_var(&c, "depth_c", 1)
      }
    }
  }
  add_var(&s, "after", 1)
}

// The graph half of the model, built with no structured block at all: the loop is a BACK-EDGE from a
// branch, not a `while`, which is the only way a canvas can express one. g_spins counts the passes and
// g_done proves the true arm was taken; if the branch re-armed its clock each pass (see the walker) the
// exit would never fire and this would spin forever.
bh_test_graph :: proc(b: ^Builder) {
  s := seq(b)
  set_var(&s, "g_done", "0")

  add_var(&s, "g_spins", 1)
  top := here(b) // `here` is always "the node I just emitted" - this one is the loop head
  wait(&s, 0.02) // yield, or the 64-steps-per-tick budget just burns
  out := branch_node(&s, after_minutes(0.004)) // ~0.24s
  wire(b, out, .False, top) // not yet -> go round again

  add_var(&s, "g_done", 1)
  wire(b, out, .True, here(b)) // done -> the node just emitted
}

// An interrupt whose body TAKES TIME. `always` is true on the first tick, so the region fires at once,
// runs a 0.25s wait to completion, and returns - after which the main program must continue from where
// it was suspended. Both vars ending at 1 is the proof: a lost pc would leave irq_b unset.
bh_test_irq :: proc(b: ^Builder) {
  s := seq(b)
  on(&s, always(), do_wait(0.25))
  add_var(&s, "irq_a", 1)
  wait(&s, 0.05)
  add_var(&s, "irq_b", 1)
}

// The fail edge, which is what lets a chart draw a fall-through chain (the priority ladder is pick
// blocks wired rung-to-rung by it). The failing node's .False edge jumps PAST the node that follows it
// in the array, so fe_bad proves the edge was taken rather than control simply falling through.
bh_test_fail_edge :: proc(b: ^Builder) {
  s := seq(b)
  fail_now(&s)
  bad_from := here(b)
  add_var(&s, "fe_bad", 1) // must be skipped
  skip := goto_node(&s) // the success path would land here; wired to the terminator below
  add_var(&s, "fe_ok", 1)
  wire(b, bad_from, .False, here(b)) // fail -> the fe_ok node just emitted
  return_node(&s)
  wire(b, skip, .True, here(b))
}

// The other half of the same rule: an UNWIRED failure must still stop the program, which is what a
// walk that cannot start relies on. fe_after must never be set.
bh_test_fail_stop :: proc(b: ^Builder) {
  s := seq(b)
  fail_now(&s)
  add_var(&s, "fe_after", 1)
}

// The randomness the look-alive behaviours are built from. 40 flips: heads landing on 0 or 40 has
// probability 2^-39, so "strictly between" is a safe assertion and catches the two ways this breaks -
// a roll that is really a constant, or one armed once and then cached for every later visit.
// The wait proves wait_random blocks at all; the printed run time should land in its 0.2-0.4s window.
bh_test_random :: proc(b: ^Builder) {
  s := seq(b)
  {
    r := loop_times(&s, 40)
    add_var(&r, "flips", 1)
    {
      h := branch(&r, chance(50))
      add_var(&h, "heads", 1)
    }
  }
  wait_between(&s, 0.20, 0.40)
  add_var(&s, "done", 1)
}

// The read half of the variable story, which had no coverage at all because until now there was nothing
// to read a variable WITH. Three separate claims, and each one fails a different way:
//
//   dir=A     - the flip happened, so `var_is` saw the value the chart itself had set a node earlier
//   saw_d=1   - the FIRST test took its true arm (dir was still "D")
//   saw_a=1   - `var dir @next` copied one variable into another, i.e. a VALUE argument interpolated
//   counted=3 - var_above/var_below bound a loop, so a numeric read works on text written by `add`
//
// It runs fully detached, like the rest of the t_* set: no key, no client, no game state.
bh_test_vars :: proc(b: ^Builder) {
  s := seq(b)
  set_var(&s, "dir", "D")
  set_var(&s, "next", "A")

  // Case-insensitive text match, and the value came from set_var above rather than from a literal here.
  {
    yes := branch(&s, var_is("dir", "d"))
    add_var(&yes, "saw_d", 1)
  }
  set_var(&s, "dir", "@next") // the VALUE interpolates - this is the flip
  {
    yes := branch(&s, var_is("dir", "A"))
    add_var(&yes, "saw_a", 1)
  }

  // A counter driven to exactly 3 by a back-edge loop whose exit is a numeric read of the counter. If
  // var_above compared text instead of numbers this would either never exit or exit on the first pass.
  add_var(&s, "counted", 1)
  top := here(b) // `here` is "the node I just emitted", so this names the counter - the loop head
  wait(&s, 0.02) // yield, or the 64-instructions-per-tick budget just burns
  out := branch_node(&s, var_above("counted", 2))
  wire(b, out, .False, top) // not there yet -> count again

  add_var(&s, "done", 1)
  wire(b, out, .True, here(b)) // done -> the node just emitted
}

// Clones, because `on` stores the action as-is and script_step_free will delete its strings - a
// borrowed literal reaching that delete corrupts the heap. Same rule as the do_* helpers in
// builder.odin: action constructors own their strings, condition constructors borrow.
@(private = "file")
do_add :: proc(name: string) -> Script_Action {
  a := Script_Action{kind = .Add}
  a.strs[0] = strings.clone(name)
  a.nums[0] = 1
  return a
}

// ===========================================================================
// `auto`, AS A CHART
//
// This is the migration's point: the farm loop is no longer a precedence chain of booleans inside one
// tick function, it is a graph you can look at and rewire.
//
// WHY IT IS GENERATED FROM A CONFIG rather than written out flat. Every existing command that shaped
// `auto` - priority, preset, density, lookalive, hunt, timer, kills - keeps working unchanged, because
// they all still write the same fields and those fields now decide WHICH NODES GET EMITTED. Odin's
// control flow runs at build time (see builder.odin), so `priority melee off` is not a flag the ladder
// consults at run time: the pick_melee node simply is not in the chart. That is what "the ladder is
// editable" has to mean for it to be worth anything.
//
// THE SHAPE. Every pick_* rung fails when it has nothing, so the ladder is a chain wired by fail
// edges, and each rung's SUCCESS edge jumps forward to the engage section:
//
//     scan_mobs ──fail──────────────────────────────────────────────► idle
//        │
//        ▼
//     pick_aggro ──fail──► pick_melee ──fail──► ... ──► pick_nearest ──fail──► idle
//        │                    │                             │
//        └────────────────────┴──── success ────────────────┘
//                                     ▼
//              [wait_random] ─► [chance?] ─► [approach] ─► lock_target ─► hold_target
//                                                              │fail          │fail
//                                                              ▼              ▼
//                                                             top          skip_target ─► top
//                                                       ┌── target_died? ──┐
//                                                    yes│                  │no
//                                                  count_kill            top
// ===========================================================================

// The knobs the three built-in charts are ASSEMBLED from. Each one below supplies a fixed literal.
//
// This used to be filled from live session state, so `density off` / `lookalive on` / `hunt on` etc.
// rebuilt the chart with different nodes. That whole layer is gone: the chart IS the configuration now.
// `script export auto as myfarm` gives you an editable copy, the options tab sets every value in it,
// and deleting a node is how a rung gets turned off - one place describing one behaviour, instead of a
// command set and a graph that had to be kept saying the same thing.
//
// It stays a struct rather than becoming three hand-written builders because the three charts are
// genuinely the same chart with different wiring, and a shared shape is what keeps them that way.
Auto_Cfg :: struct {
  names:               string, // target spec, "" = any monster
  aggro:               bool,   // rung 1
  melee:               bool,   // rung 2
  avoid:               bool,   // rung 3 - post-skip opposite-side steer
  pocket:              bool,   // rung 4
  density:             bool,   // rungs 5+6
  hesitate:            bool,   // human reaction delay before engaging
  hold_min, hold_max:  f64,
  approach:            bool, // walk to the mob before locking it
  step_chance:         f64,  // % of engages that take the scenic route (single-hop approach only)
  step_spread:         f64,
  max_range:           f64, // >0 = keep hopping until this close
  sidestep:            bool, // never drop a target; step around a jam (hunt)
  grace:               f64,  // combat-watch grace, seconds
  kills:               int,  // stop after N kills (0 = unlimited)
  minutes:             f64,  // stop after N minutes (0 = unlimited)
}

// The target list as a spec string parse_target_names can read back (the same text you would type
// after `auto`). Quoted so names with spaces survive the round trip.
auto_names_spec :: proc(s: ^Session) -> string {
  if len(s.auto_names) == 0 {
    return ""
  }
  b := strings.builder_make(context.temp_allocator)
  for n, i in s.auto_names {
    if i > 0 {
      strings.write_string(&b, ",")
    }
    strings.write_string(&b, "'")
    strings.write_string(&b, n)
    strings.write_string(&b, "'")
  }
  return strings.to_string(b)
}

// The live session, for behaviours that read configuration while BUILDING - which is the whole trick
// behind bh_auto: `priority melee off` has to decide whether the pick_melee NODE exists, and that
// decision happens here, not at run time.
//

// The full ladder, no walking, no theatrics - what `auto` did with a stock config. Everything that
// used to be a toggle is a NODE now: delete `pick_density` to stop pack-steering, add an `approach`
// to walk in, wire `hold_target`'s fail edge back to it to get hunt. Edit a copy (`script export auto
// as myfarm`) rather than this, or a rebuild takes your changes away.
bh_auto :: proc(b: ^Builder) {
  auto_chart(
    b,
    Auto_Cfg {
      aggro = true,
      melee = true,
      avoid = true,
      pocket = true,
      density = true,
      grace = f64(FLYFF_COMBAT_GRACE),
    },
  )
}

// EMIT FIRST, WIRE SECOND throughout - a rung's fail edge names the rung after it, which does not
// exist yet when the earlier one is emitted.
auto_chart :: proc(b: ^Builder, cfg: Auto_Cfg) {
  s := seq(b)
  b.mode = .Loop

  // A time limit is an interrupt, not a branch: `timer` stops auto wherever it is, not only at the
  // moment a kill happens to complete.
  if cfg.minutes > 0 {
    on(&s, after_minutes(cfg.minutes), do_abort())
  }

  section(b, "Look around")
  scan_mobs(&s, cfg.names)
  top := here(b)

  // --- the ladder ---
  section(b, "Pick a target")
  rungs := make([dynamic]Node_Id, context.temp_allocator)
  if cfg.aggro {
    pick_aggro(&s)
    append(&rungs, here(b))
  }
  if cfg.melee {
    pick_melee(&s)
    append(&rungs, here(b))
  }
  if cfg.avoid {
    pick_avoid(&s)
    append(&rungs, here(b))
  }
  if cfg.pocket {
    pick_pocket(&s)
    append(&rungs, here(b))
  }
  if cfg.density {
    pick_cluster(&s)
    append(&rungs, here(b))
    pick_density(&s)
    append(&rungs, here(b))
  }
  pick_nearest(&s) // the fallback rung is not optional - without it the ladder can answer nothing
  append(&rungs, here(b))

  // --- engage ---
  section(b, "Close in")
  engage := Node_Id(0)
  mark :: proc(cur: Node_Id, b: ^Builder) -> Node_Id {return cur != 0 ? cur : here(b)}

  if cfg.hesitate {
    wait_between(&s, cfg.hold_min, cfg.hold_max)
    engage = mark(engage, b)
  }
  // The scenic-route roll applies to the SINGLE-hop detour only. A max_range approach is not a
  // preference - it is how you get in range at all - so it is never rolled for. Same split auto made.
  roll := cfg.approach && cfg.max_range <= 0 && cfg.step_chance > 0 && cfg.step_chance < 100
  chance_node := Node_Id(0)
  if roll {
    chance_node = branch_node(&s, chance(cfg.step_chance))
    engage = mark(engage, b)
  }
  appr := Node_Id(0)
  if cfg.approach {
    approach(&s, cfg.max_range, cfg.step_spread, cfg.sidestep)
    appr = here(b)
    engage = mark(engage, b)
  }
  lock_target(&s)
  lock := here(b)
  engage = mark(engage, b)

  section(b, "Fight")
  hold_target(&s, cfg.grace)
  hold := here(b)

  died := branch_node(&s, target_died())
  count_kill(&s)
  killed_node := here(b)

  quota := Node_Id(0)
  if cfg.kills > 0 {
    quota = branch_node(&s, killed(cfg.kills))
    abort(&s) // reached only on the true arm; falls through to the goto below, which never runs
  }
  back := goto_node(&s)

  // --- skip / idle tails ---
  section(b, "Give up on it")
  skip_target(&s)
  skip := here(b)
  back2 := goto_node(&s)

  section(b, "Nothing to do")
  wait(&s, 0.3) // nothing eligible: wait a beat rather than spinning the 64-steps-per-tick budget
  idle := here(b)
  back3 := goto_node(&s)

  // --- wiring ---
  wire(b, top, .False, idle) // the scan itself failed (not in-game / unpinned)
  for id, i in rungs {
    wire(b, id, .True, engage)
    wire(b, id, .False, i + 1 < len(rungs) ? rungs[i + 1] : idle)
  }
  if roll {
    wire(b, chance_node, .True, appr)
    wire(b, chance_node, .False, lock)
  }
  if appr != 0 {
    wire(b, appr, .False, skip)
  }
  wire(b, lock, .False, top) // it died or moved out from under the pick - rescan
  wire(b, hold, .False, skip)
  wire(b, died, .True, killed_node)
  wire(b, died, .False, top)
  if quota != 0 {
    wire(b, quota, .False, top) // under quota - keep going (the true arm falls into `stop`)
  }
  wire(b, back, .True, top)
  wire(b, back2, .True, top)
  wire(b, back3, .True, top)
}

// HUNT: commit to one monster and never drop it.
//
// The same parts as bh_auto, wired differently - which is the argument for the whole migration. Hunt
// used to be a flag consulted in four separate places inside auto_tick (`hunt_steering_on`), because
// "never drop the target" is not a step, it is a change to where several edges point. Here it is
// exactly that: hold_target's fail edge goes back to APPROACH instead of to skip_target, and approach
// carries sidestep, so a jam steps around the obstacle rather than abandoning the mob.
bh_hunt :: proc(b: ^Builder) {
  // Fixed, like bh_auto: sidestep is what makes it hunt, and the spread keeps the walk-in from looking
  // machine-straight. Both were session flags; both are now just what this chart IS.
  cfg := Auto_Cfg{aggro = true, melee = true, pocket = true, sidestep = true, step_spread = 8, grace = f64(FLYFF_COMBAT_GRACE)}
  s := seq(b)
  b.mode = .Loop

  section(b, "Look around")
  scan_mobs(&s, cfg.names)
  top := here(b)

  section(b, "Pick a target")
  pick_aggro(&s) // something already on us outranks the ladder, even when hunting
  aggro := here(b)
  pick_nearest(&s)
  nearest := here(b)

  section(b, "Close in")
  approach(&s, 0, cfg.step_spread, true) // sidestep: step around a jam, never give up
  appr := here(b)
  lock_target(&s)
  lock := here(b)

  section(b, "Fight")
  hold_target(&s, cfg.grace)
  hold := here(b)

  died := branch_node(&s, target_died())
  count_kill(&s)
  killed_node := here(b)
  back := goto_node(&s)

  section(b, "Nothing to do")
  wait(&s, 0.3)
  idle := here(b)
  back2 := goto_node(&s)

  wire(b, top, .False, idle)
  wire(b, aggro, .True, appr)
  wire(b, aggro, .False, nearest)
  wire(b, nearest, .True, appr)
  wire(b, nearest, .False, idle)
  wire(b, appr, .False, top) // lost the mob entirely (died to someone else / despawned) - re-pick
  wire(b, lock, .False, top)
  wire(b, hold, .False, appr) // THE hunt edge: jammed or out of reach -> go at it again, do not skip
  wire(b, died, .True, killed_node)
  wire(b, died, .False, top)
  wire(b, back, .True, top)
  wire(b, back2, .True, top)
}

// SWEEP: clear a painted lane, never leaving it.
//
// sweep_lane owns the route and hands the tick back when the circle it is standing in needs working;
// pick_in_range is the whole ladder here, because anything else would propose a walk off the lane.
bh_sweep :: proc(b: ^Builder) {
  cfg := Auto_Cfg{}
  s := seq(b)
  b.mode = .Loop

  section(b, "Drive the lane")
  sweep_lane(&s)
  lane := here(b)

  section(b, "Pick a target")
  scan_mobs(&s, cfg.names)
  scan := here(b)
  pick_in_range(&s)
  inr := here(b)
  lock_target(&s)
  lock := here(b)

  section(b, "Fight")
  hold_target(&s, cfg.grace)
  hold := here(b)

  died := branch_node(&s, target_died())
  count_kill(&s)
  killed_node := here(b)
  back := goto_node(&s)

  section(b, "Give up on it")
  skip_target(&s)
  skip := here(b)
  back2 := goto_node(&s)

  section(b, "Lane finished")
  abort(&s) // the lane finished - end the run rather than idling on a route that no longer exists
  done := here(b)

  wire(b, lane, .False, done)
  wire(b, scan, .False, lane)
  wire(b, inr, .False, lane) // nothing in reach: back to the lane so it hops forward
  wire(b, lock, .False, lane)
  wire(b, hold, .False, skip)
  wire(b, died, .True, killed_node)
  wire(b, died, .False, lane)
  wire(b, back, .True, lane)
  wire(b, back2, .True, lane)
}

// --- the dungeon example ---------------------------------------------------------------------

// Config lives in a struct, not in the program - retuning is editing values, not logic.
Dungeon_Cfg :: struct {
  portal:               [3]f32,
  boss:                 string,
  tp, attack, pet, out: string,
  acquire_tries:        int,
  watchdog_minutes:     f64,
}

CLOCKWORKS := Dungeon_Cfg {
  portal           = {6800, 0, 3300},
  boss             = "Clockworks",
  tp               = "7",
  attack           = "2",
  pet              = "9",
  out              = "8",
  acquire_tries    = 8,
  watchdog_minutes = 8,
}

bh_clockworks :: proc(b: ^Builder) {
  dungeon_run(b, CLOCKWORKS)
}

// A whole dungeon, built from plain Odin procs. Note there is no `call` node anywhere - the
// sub-sequences below are procedures, which is what sub-scripts were always imitating.
dungeon_run :: proc(b: ^Builder, cfg: Dungeon_Cfg) {
  s := seq(b)

  // Safety rails, checked before every step for the whole run.
  on(&s, player_within(25), do_abort())
  on(&s, after_minutes(cfg.watchdog_minutes), do_abort())

  teleport_to(&s, cfg.tp, cfg.portal)
  walk(&s, cfg.portal)
  wait(&s, 5) // zone load

  acquire(&s, cfg.boss, cfg.acquire_tries)
  require(&s, not(no_target())) // never got it - abort rather than flail

  ensure_pet(&s, cfg.pet)
  fight(&s, cfg.attack)

  wait(&s, 4) // let the pet loot
  key(&s, cfg.out)
}

// Press the teleport hotkey, wait out the loading screen, and PROVE we arrived.
teleport_to :: proc(s: ^Seq, hotkey: string, dest: [3]f32) {
  key(s, hotkey)
  wait(s, 4)
  require(s, near(dest, 60))
}

// Retry targeting. The retry count is a build-time loop, so it unrolls - the runtime only ever sees
// "if nothing selected, target, wait".
acquire :: proc(s: ^Seq, name: string, tries: int) {
  for _ in 0 ..< tries {
    try := branch(s, no_target())
    pick(&try, name)
    wait(&try, 0.5)
  }
}

ensure_pet :: proc(s: ^Seq, hotkey: string) {
  p := branch(s, no_pet())
  key(&p, hotkey)
  wait(&p, 1)
}

// Spam the attack key until the target goes away. Gating on no_target rather than target HP is
// deliberate: with nothing selected an HP read fails and reads as "not below", which would spin here
// forever.
fight :: proc(s: ^Seq, hotkey: string) {
  f := loop_until(s, no_target())
  key(&f, hotkey)
  wait(&f, 0.4)
}
