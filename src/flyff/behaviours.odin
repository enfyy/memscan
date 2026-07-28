package flyff

import "core:strings"

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

BEHAVIOURS := [?]Behaviour_Def {
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
    name = "clockworks", blurb = "example dungeon run (needs the game + findmove + hotkeys)",
    build = bh_clockworks,
  },
}

behaviour_def :: proc(name: string) -> ^Behaviour_Def {
  for &d in BEHAVIOURS {
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
