package flyff

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

import "../engine"

// ===========================================================================
// BEHAVIOURS AS RULE LISTS - the model that replaces the node graph.
//
// A behaviour is a route plus ONE ORDERED LIST of `WHEN <condition> DO <steps>` rules. Every tick the
// list is read top to bottom and the first rule whose WHEN holds gets to run. That is the whole
// language. See BACKLOG.md, "DESIGN: behaviours as rule lists", for why - the short version is that
// node graphs express control flow, the control flow in this domain is trivial (walk, target, press,
// wait), and the real complexity is spatial and already lives in Odin.
//
// WHAT THIS BUYS, and it is the point of the whole design: THE LIST HAS NO POSITION. A graph is parked
// at a node, so "why is it doing that" means tracing edges backwards. Here the answer is always "read
// the list; the first true one wins". State does not vanish, it moves into the world - `patrol` knows
// which stop it is walking to and `kill` knows which mob it locked, and both are things you can look
// at, on the radar and in the game, rather than an invisible program counter.
//
// THE FOUR RULES OF EVALUATION:
//
//   1. Every tick, read top to bottom. The first rule whose WHEN holds runs its DO.
//   2. A DO runs its steps in order. A step that FAILS aborts the sequence - there is no fail edge,
//      because there is nowhere for it to go. Control returns to the top.
//   3. HIGHER IN THE LIST CAN INTERRUPT LOWER. Position is urgency. A strictly higher winner suspends
//      whatever is running and takes over.
//   4. INTERRUPTION RESUMES, IT DOES NOT RESTART. The suspended step is left mid-flight and picked up
//      where it was, which is what lets a rule that walks somewhere survive being cut into by a rule
//      that kills something.
//
// ONCE VS WHILE. Every rule declares whether it fires on the RISING EDGE (`fire_on_edge`, "once, when
// it starts") or runs WHILE ITS CONDITION IS TRUE. That is not new machinery: it is
// Condition_State.latched, which the two old interrupt evaluation sites already used to fire on an
// edge and re-arm when the condition went false. It just becomes visible and per-row instead of
// implicit in what kind of file you happened to write.
//
// A RULE LIST ALWAYS LOOPS. There is no once/loop mode to consult: "read the list every tick" has no
// end condition, and a list with an `otherwise` row would never reach one anyway. A run ends when a
// `stop` step runs, when the transport stops it, or when the session goes away.
//
// NO BRANCHING INSIDE A DO, EVER. This is the discipline that stops the design rotting back into a
// graph, and it is now enforced by the INSTRUCTION SET rather than by a check: Script_Op has exactly
// two entries, .Action and .Wait_For, so there is no op that could branch. A procedure that genuinely
// needs one becomes an Odin verb, exactly as `kill` and `approach` already are. That pressure valve is
// why a language was never actually needed.
// ===========================================================================

// --- types ---------------------------------------------------------------------------------------

// One row of the list. Owns its strings and its steps; the run takes ownership from the document at
// rules_begin, and script_run_free is what gives it back.
Rule :: struct {
  // Stable identity, and the SAME Node_Id space a step uses. The trace ring and the Problems tab
  // already address by id and never by position, so both keep working against rules for free.
  id:              Node_Id,
  condition:       Script_Condition, // reused verbatim - all-of / any-of, up to SCRIPT_MAX_CONDITION_ROWS
  condition_state: Condition_State,
  // Fire once on the false->true edge, or run for as long as the condition holds? The VERB supplies
  // the default when a rule is authored (`alert` is once, `press ... until` is while); the row can
  // override it. An edge rule runs its steps to completion even if its condition goes false underneath
  // it; a level rule is stopped the moment the condition does.
  fire_on_edge:    bool,
  steps:           [dynamic]Script_Step, // linear. No branching - see the header.
  label:           string, // owned; one line, for the trace and the list
  enabled:         bool, // per-row on/off. Always true for a behaviour's own rules; the persisted
  // toggle for a global one, which is what lets globals be a second list above the behaviour's.
  fires:           int, // how many times it has taken control this run
}

// What was suspended when a higher rule cut in. Three fields, and that is all there is to save: a rule
// list has no loops to keep a stack for and no calls to hand variables back to, so "where was it" is a
// rule, a step, and whether that step had already started.
Rule_Frame :: struct {
  rule:    int,
  step:    int,
  entered: bool, // was the suspended step mid-flight? A walk that is still walking must resume, not restart.
}

// --- the tick ------------------------------------------------------------------------------------

// One tick: arbitrate, then walk whatever won. Called from st_script, and THE single evaluation loop -
// it replaced three (the graph walker's per-step watcher pass, a separate interrupt pass, and a third
// one in interrupt.odin that ran only while nothing else did).
rules_tick :: proc(ctx: ^Behaviour_Context) {
  run := &ctx.session.script
  if run.stop_requested {
    script_finish(ctx, "stopped")
    return
  }
  rules_arbitrate(ctx)
  if run.active_rule < 0 {
    return
  }
  rules_walk(ctx, SCRIPT_MAX_STEPS_PER_TICK)
}

// Decide who should be running, and switch to them if it is not who is running now.
//
// EVERY RULE IS EVALUATED, even once a winner is known. Exactly the reason script_condition_holds
// evaluates every row of a condition: a row like `kills 20` updates its own baseline as a side effect
// of being asked, and a rule that went unasked for a whole run would measure from a stale point the
// moment it finally did win.
rules_arbitrate :: proc(ctx: ^Behaviour_Context) {
  run := &ctx.session.script
  winner := -1
  current_holds := false
  for &rule, i in run.rules {
    if !rule.enabled {
      continue
    }
    if !script_condition_holds(ctx, rule.condition, &rule.condition_state) {
      rule.condition_state.latched = false // condition went away - re-arm for the next edge
      continue
    }
    if i == run.active_rule {
      current_holds = true
    }
    // An edge rule that is still true from a previous fire is not a new edge, so it cannot win again.
    // A level rule has no such gate - being true IS its claim to the list.
    if rule.fire_on_edge && rule.condition_state.latched {
      continue
    }
    if winner < 0 {
      winner = i
    }
  }

  if run.active_rule < 0 {
    if winner >= 0 {
      rules_enter(ctx, winner)
    }
    return
  }
  // Rule 3: only a STRICTLY HIGHER rule preempts. A lower one waits its turn - which is what makes
  // "position is urgency" true rather than merely suggested.
  if winner >= 0 && winner < run.active_rule {
    rules_suspend(ctx, winner)
    return
  }
  // Rule 2's other half: a `while it's true` rule is over the moment its condition is not.
  if !run.rules[run.active_rule].fire_on_edge && !current_holds {
    rules_stop_current(ctx, "condition no longer holds")
  }
}

// Take control with <index>. Latching here rather than in the arbitration loop is deliberate: the
// latch means "this edge has been SERVICED", and a rule that was evaluated but did not win has not
// serviced anything.
rules_enter :: proc(ctx: ^Behaviour_Context, index: int) {
  run := &ctx.session.script
  rule := &run.rules[index]
  rule.condition_state.latched = true
  rule.fires += 1
  run.active_rule = index
  run.pc = 0
  run.entered = false
  script_trace(ctx.session, rule.id, .Note, "rule %d: %s", index + 1, rule.label)
}

// Park the running rule and hand control to the higher one. The suspended step is left ENTERED on
// purpose - see rule 4 in the header.
rules_suspend :: proc(ctx: ^Behaviour_Context, winner: int) {
  run := &ctx.session.script
  if run.rule_depth >= SCRIPT_MAX_FRAMES {
    return // no room to park it; the higher rule gets its turn when this one finishes
  }
  run.rule_frames[run.rule_depth] = Rule_Frame {
    rule    = run.active_rule,
    step    = run.pc,
    entered = run.entered,
  }
  run.rule_depth += 1
  script_trace(
    ctx.session,
    run.rules[run.active_rule].id,
    .Note,
    "suspended by rule %d (resumes at step %d)",
    winner + 1,
    run.pc + 1,
  )
  rules_enter(ctx, winner)
}

// Resume whatever was suspended. False when there was nothing - the list goes idle and the next tick
// arbitrates from the top.
rules_pop :: proc(ctx: ^Behaviour_Context) -> bool {
  run := &ctx.session.script
  if run.rule_depth <= 0 {
    run.active_rule = -1
    run.entered = false
    return false
  }
  run.rule_depth -= 1
  frame := run.rule_frames[run.rule_depth]
  run.active_rule = frame.rule
  run.pc = frame.step
  run.entered = frame.entered
  script_trace(ctx.session, run.rules[frame.rule].id, .Note, "resumed at step %d", frame.step + 1)
  return true
}

// The step the active rule is on, or nil when there is none (no rule running, or the rule is done).
rules_current_step :: proc(run: ^Script_Run) -> ^Script_Step {
  if run.active_rule < 0 || run.active_rule >= len(run.rules) {
    return nil
  }
  rule := &run.rules[run.active_rule]
  if run.pc < 0 || run.pc >= len(rule.steps) {
    return nil
  }
  return &rule.steps[run.pc]
}

// Run the in-flight step's exit, if there is one. The rule-list twin of script_exit_current, and
// needed for the same reason: leaving a step for ANY reason has to undo what it started, or `stop`
// mid-walk would let the character drift to the waypoint.
rules_exit_current :: proc(ctx: ^Behaviour_Context) {
  run := &ctx.session.script
  if run.active_rule < 0 || run.active_rule >= len(run.rules) {
    run.entered = false
    return
  }
  rule_steps_exit(ctx, run.rules[run.active_rule].steps[:], run.pc, &run.entered)
}

// End the running rule and go back to the top (or to whoever it interrupted).
rules_stop_current :: proc(ctx: ^Behaviour_Context, why: string) {
  run := &ctx.session.script
  if run.active_rule < 0 {
    return
  }
  rules_exit_current(ctx)
  script_trace(ctx.session, run.rules[run.active_rule].id, .Note, "rule ended: %s", why)
  rules_pop(ctx)
}

// --- the walker ----------------------------------------------------------------------------------

// Run up to <budget> steps of the active rule. Bounded because a rule
// whose DO is all `var`/`add` would otherwise spin the 20ms watcher tick forever without yielding.
rules_walk :: proc(ctx: ^Behaviour_Context, budget: int) {
  run := &ctx.session.script
  for _ in 0 ..< budget {
    if !run.active || run.active_rule < 0 {
      return
    }
    if run.stop_requested {
      script_finish(ctx, "stopped")
      return
    }
    rule := &run.rules[run.active_rule]
    switch rule_steps_run(ctx, rule.steps[:], &run.pc, &run.entered, budget) {
    case .Running:
      return // yield
    case .Done:
      // Rule 1 - back to the top, or to whoever this rule interrupted. Popping continues the loop
      // so a resumed rule gets its turn in the same tick rather than losing 20ms to the hand-over.
      rules_finish_current(ctx, "done")
    case .Aborted:
      rules_finish_current(ctx, "aborted")
    }
  }
}

// --- executing one rule's steps ---------------------------------------------------------------------
//
// Factored out of rules_walk so the GLOBAL rule list runs its steps with exactly the same semantics
// without a second copy of them (see interrupt.odin). The caller owns <pc> and <entered>; this proc
// owns what a step does. That is what makes "one evaluation loop" true rather than merely claimed.

Rule_Step_Result :: enum {
  Running, // still going - yield the tick
  Done,    // ran off the end of the list
  Aborted, // a step failed, so the rest of the sequence does not run
}

// Advance <steps> by up to <budget> instructions. Bounded for the same reason the graph walker is: a
// sequence of pure `var`/`add` steps would otherwise spin the 20ms watcher tick without ever yielding.
rule_steps_run :: proc(ctx: ^Behaviour_Context, steps: []Script_Step, pc: ^int, entered: ^bool, budget: int) -> Rule_Step_Result {
  for _ in 0 ..< budget {
    if pc^ < 0 || pc^ >= len(steps) {
      return .Done
    }
    step := &steps[pc^]
    advance :: proc(ctx: ^Behaviour_Context, step: ^Script_Step, pc: ^int, entered: ^bool) {
      if step.op == .Action {
        if def := action_def(step.action.kind); def != nil && def.exit != nil {
          def.exit(ctx, step)
        }
      }
      ctx.session.script.steps_done += 1
      pc^ += 1
      entered^ = false
    }
    switch step.op {
    case .Action:
      if !entered^ {
        entered^ = true
        ctx.session.script.step_at = ctx.now
        step.scratch = Step_Scratch {
          started_at = ctx.now,
        }
        if step.has_until {
          script_arm_condition(ctx, step.until, &step.condition_state)
        }
        script_note_line(ctx, step)
        def := action_def(step.action.kind)
        if def == nil || def.start == nil {
          script_trace(ctx.session, step.id, .Error, "block has no implementation -> rule aborted")
          entered^ = false
          return .Aborted
        }
        switch def.start(ctx, step) {
        case .Failed:
          script_trace(ctx.session, step.id, .Note, "failed to start -> rule aborted")
          advance(ctx, step, pc, entered)
          return .Aborted
        case .Done:
          advance(ctx, step, pc, entered)
        case .Running:
          if def.poll == nil {
            advance(ctx, step, pc, entered) // no poll => start's verdict was final
          } else {
            return .Running // yield; poll it next tick
          }
        }
        continue
      }
      // Already started: the `until` condition can end it early, otherwise poll it.
      if step.has_until && script_condition_holds(ctx, step.until, &step.condition_state) {
        advance(ctx, step, pc, entered)
        continue
      }
      def := action_def(step.action.kind)
      if def == nil || def.poll == nil {
        advance(ctx, step, pc, entered)
        continue
      }
      switch def.poll(ctx, step) {
      case .Done:
        advance(ctx, step, pc, entered)
      case .Failed:
        script_trace(ctx.session, step.id, .Note, "failed -> rule aborted")
        advance(ctx, step, pc, entered)
        return .Aborted
      case .Running:
        return .Running
      }

    case .Wait_For:
      if !entered^ {
        entered^ = true
        ctx.session.script.step_at = ctx.now
        script_arm_condition(ctx, step.condition, &step.condition_state)
        script_note_line(ctx, step)
      }
      if script_condition_holds(ctx, step.condition, &step.condition_state) {
        ctx.session.script.steps_done += 1
        pc^ += 1
        entered^ = false
        continue
      }
      return .Running

    }
  }
  return .Running
}

// Run the in-flight step's exit, whoever owns the sequence. The teardown half of rule_steps_run.
rule_steps_exit :: proc(ctx: ^Behaviour_Context, steps: []Script_Step, pc: int, entered: ^bool) {
  if !entered^ {
    return
  }
  if pc >= 0 && pc < len(steps) && steps[pc].op == .Action {
    if def := action_def(steps[pc].action.kind); def != nil && def.exit != nil {
      def.exit(ctx, &steps[pc])
    }
  }
  entered^ = false
}

rules_finish_current :: proc(ctx: ^Behaviour_Context, how: string) {
  run := &ctx.session.script
  if run.active_rule < 0 {
    return
  }
  rule := &run.rules[run.active_rule]
  script_trace(ctx.session, rule.id, .Step, "rule %s: %s", how, rule.label)
  rules_pop(ctx)
}

// --- starting a run ------------------------------------------------------------------------------

// Start a run. TAKES OWNERSHIP of <rules>.
//
// Notice what is NOT here, because it is the whole argument for the redesign. Starting a graph meant a
// watcher partition, a region build per watcher, a borrowed-watcher attach, a global-interrupt hoist,
// an id-to-index resolve over every edge, and an entry-node search. All of it existed to make a graph
// RUNNABLE; a list is runnable as it stands, so this is a dozen field assignments and one loop.
rules_begin :: proc(session: ^Session, name: string, rules: [dynamic]Rule, route := "", ignore_collision := false) {
  script_run_free(&session.script)
  run := &session.script
  run.rules = rules
  run.name = strings.clone(name)
  run.route = strings.clone(route)
  // "Is this a hunt behaviour" - see hunt_steering_on. Asked once, here, rather than per pick.
  run.sidestep_chart = false
  outer: for &rule in run.rules {
    for step in rule.steps {
      // `kill` with sidestep on IS hunt - see hunt_steering_on, which relaxes the reach gate for it: a
      // behaviour that steps around jams has to be allowed to pick a monster it cannot currently walk
      // to. Asked once here rather than per pick, because it is a property of the program.
      if step.op == .Action && step.action.kind == .Kill && step.action.nums[1] != 0 {
        run.sidestep_chart = true
        break outer
      }
    }
  }
  run.ignore_collision = ignore_collision
  run.active = true
  run.active_rule = -1
  run.rule_depth = 0
  run.rule_frames = {}
  run.pc = 0
  run.entered = false
  run.paused = false
  run.started_at = time.now()._nsec
  run.step_at = run.started_at

  ctx := Behaviour_Context {
    session = session,
    now     = run.started_at,
    board   = &session.bh_board,
  }
  // Arm every row's baseline up front. A rule that has never won still has to measure `kills 20` and
  // `elapsed 5` from the start of the run rather than from whenever it first happens to be asked.
  for &rule in run.rules {
    script_arm_condition(&ctx, rule.condition, &rule.condition_state)
  }
  session.script_trace = {} // a fresh run starts a fresh story
  script_trace(session, run.rules[0].id, .Note, "RUN '%s' - %d rule(s)%s", name, len(run.rules), route == "" ? "" : fmt.tprintf(", route '%s'", route))

  engine.ensure_hotkey_thread(&session.eng) // the walker only advances on the watcher tick
  behaviour_goto(session, .Script)
}

// Hand a document's rules to the runtime and start it. TAKES OWNERSHIP of <doc> - it moves the rules
// onto the run and frees the rest, on every path including the refusals, so the caller must not touch
// it afterwards.
script_cmd_run_rules :: proc(session: ^Session, doc: ^Behaviour_Doc) {
  label := strings.clone(doc.name, context.temp_allocator)
  if len(doc.rules) == 0 {
    fmt.eprintfln("script run: '%s' has no rules, so there is nothing to run.", label)
    fmt.eprintln("  a behaviour is a list of WHEN <condition> DO <steps> - give it at least one row.")
    behaviour_doc_free(doc)
    return
  }
  // Refuse up front rather than dying mid-run, which would leave the character somewhere unexpected.
  if problems := rules_check_avail(session, doc.rules[:]); len(problems) > 0 {
    fmt.eprintfln("script run: '%s' uses %d block(s) that aren't available yet - not started:", label, len(problems))
    for p in problems {
      fmt.eprintfln("  %s", p)
    }
    fmt.eprintln("  'script blocks' shows the whole catalog and what each missing one needs.")
    behaviour_doc_free(doc)
    return
  }
  rules := doc.rules
  doc.rules = nil // handed to the run; behaviour_doc_free must not take it too
  route := strings.clone(doc.route, context.temp_allocator)
  ignore_collision := doc.ignore_collision
  behaviour_doc_free(doc)
  rules_begin(session, label, rules, route, ignore_collision)
  if session.script.active {
    fmt.printfln("script: '%s' started - %d rule(s)%s.", label, len(session.script.rules), route == "" ? "" : fmt.tprintf(", route '%s'", route))
  }
}

// Every block a rule list would run, checked for availability before it starts. The []Script_Step twin
// is script_check_avail; this is the same question asked rule by rule.
rules_check_avail :: proc(session: ^Session, rules: []Rule) -> [dynamic]string {
  out := make([dynamic]string, context.temp_allocator)
  for rule in rules {
    for problem in script_check_avail(session, rule.steps[:]) {
      append(&out, problem)
    }
  }
  return out
}

// --- validation ----------------------------------------------------------------------------------

// Why <doc> cannot run, or "" when it can. Checked as a file is READ, so a bad document is refused
// where it is opened rather than on whichever tick first reaches the problem.
//
// The no-branching rule used to be checked here too. It is now enforced by the instruction set - there
// is no op that branches - so the only thing left to be wrong about a rule is having nothing to do.
rules_document_why_not :: proc(doc: ^Behaviour_Doc) -> string {
  if len(doc.rules) == 0 {
    return "it has no rules"
  }
  for rule in doc.rules {
    if len(rule.steps) == 0 {
      return fmt.tprintf("rule '%s' has nothing to do", rule.label)
    }
  }
  return ""
}

// --- showing one ------------------------------------------------------------------------------------

// `script show` for a rule list: the WHEN column and the numbered DO beside it, which is the shape the
// editor draws and the shape the design is argued in. No node-id gutter and no start marker - there is
// no position to start from.
script_show_rules :: proc(session: ^Session, doc: ^Behaviour_Doc, src: string) {
  fmt.printfln("=== %s (%s, %d rule(s)) ===", doc.name, src, len(doc.rules))
  if doc.route != "" {
    fmt.printfln("  route: %s", doc.route)
  }
  b := strings.builder_make(context.temp_allocator)
  for rule, i in doc.rules {
    fmt.println()
    strings.builder_reset(&b)
    script_write_condition(&b, rule.condition, true)
    when_text := strings.to_string(b)
    fmt.printfln(
      "%2d. WHEN %s%s%s",
      i + 1, when_text,
      rule.fire_on_edge ? "   [once, when it starts]" : "",
      rule.enabled ? "" : "   [OFF]",
    )
    if rule.label != "" {
      fmt.printfln("    (%s)", rule.label)
    }
    for step, si in rule.steps {
      fmt.printfln("    %d. %s", si + 1, step.src)
    }
  }
  fmt.println()
  fmt.println("  ^ read top to bottom every tick: the first rule whose WHEN holds runs its DO.")
  fmt.println("    a rule higher in the list interrupts one lower down, and the lower one resumes where it was.")
  if problems := rules_check_avail(session, doc.rules[:]); len(problems) > 0 {
    fmt.printfln("%d block(s) not usable right now:", len(problems))
    for p in problems {
      fmt.printfln("  %s", p)
    }
  }
}

// --- authoring a rule list in Odin -----------------------------------------------------------------
//
// The rule-list twin of builder.odin, and a tenth of its size - because there is nothing to wire. A
// built-in behaviour is now a list of rows, each a condition and a few steps, and the whole
// emit-first-wire-second discipline that `auto` needed goes away with the edges.

Rule_Builder :: struct {
  rules:   [dynamic]Rule,
  next_id: u32,
}

rules_builder_begin :: proc() -> ^Rule_Builder {
  b := new(Rule_Builder)
  b.rules = make([dynamic]Rule)
  b.next_id = 1
  return b
}

// Condition constructors BORROW their strings (see builder.odin's ownership note), so a condition on
// its way into a rule has to be deep-copied - the rule owns what it holds, and script_condition_free
// deletes every row of it.
@(private = "file")
rules_clone_condition :: proc(condition: Script_Condition) -> Script_Condition {
  out := condition
  for row in 0 ..< condition_row_count(condition) {
    r := condition_row_ptr(&out, row)
    r.strs[0] = r.strs[0] == "" ? "" : strings.clone(r.strs[0])
    r.strs[1] = r.strs[1] == "" ? "" : strings.clone(r.strs[1])
  }
  return out
}

// Start a row. Steps added after this belong to it, until the next `rule_row`.
rule_row :: proc(b: ^Rule_Builder, label: string, condition: Script_Condition, fire_on_edge := false) {
  append(&b.rules, Rule {
    id           = Node_Id(b.next_id),
    label        = strings.clone(label),
    condition    = rules_clone_condition(condition),
    fire_on_edge = fire_on_edge,
    steps        = make([dynamic]Script_Step),
    enabled      = true,
  })
  b.next_id += 1
}

// One step of the current row. Strings are cloned, the same rule builder.odin follows.
rule_step :: proc(b: ^Rule_Builder, action: Script_Action) {
  if len(b.rules) == 0 {
    return
  }
  step := Script_Step {
    id     = Node_Id(b.next_id),
    op     = .Action,
    action = action,
  }
  b.next_id += 1
  step.action.strs[0] = action.strs[0] == "" ? "" : strings.clone(action.strs[0])
  step.action.strs[1] = action.strs[1] == "" ? "" : strings.clone(action.strs[1])
  step.src = step_label(step)
  append(&b.rules[len(b.rules) - 1].steps, step)
}

rules_builder_end :: proc(b: ^Rule_Builder) -> [dynamic]Rule {
  out := b.rules
  free(b)
  return out
}

// --- self-test -----------------------------------------------------------------------------------

// The four rules of evaluation, each proved by a fixture that cannot pass by accident, plus the format
// round-trip. Synchronous throughout - it drives rules_tick by hand rather than waiting on the watcher
// thread, and no fixture depends on wall-clock time, so the suite cannot go flaky on a slow machine.
script_selftest_rules :: proc(session: ^Session) {
  fmt.println("  --- rule lists ---")
  fails := 0
  PREFIX :: "zz_selftest_rules_"
  order :: PREFIX + "order"
  preempt :: PREFIX + "preempt"
  latch :: PREFIX + "latch"

  written := make([dynamic]string, context.temp_allocator)
  defer {
    for n in written {
      os.remove(bhv_file_path(n))
    }
  }
  add :: proc(written: ^[dynamic]string, name: string, body: string, fails: ^int) -> bool {
    os.make_directory(bhv_dir_path())
    if err := os.write_entire_file(bhv_file_path(name), transmute([]byte)body); err != nil {
      fmt.eprintfln("  FAIL: could not write the fixture '%s' (%v)", name, err)
      fails^ += 1
      return false
    }
    append(written, name)
    return true
  }

  // Three rules whose conditions are ALL true. Only the first may ever run - that is rule 1, and it is
  // the whole reason a list needs no wiring.
  ok := add(&written, order, `# memscan behaviour
desc first match wins
version 2
rule 1 while
  name top
  when always
node 10 action
  do var ru_top 1
rule 2 while
  name middle
  when always
node 20 action
  do var ru_middle 1
rule 3 while
  name bottom
  when always
node 30 action
  do var ru_bottom 1
`, &fails)

  // Rule 2 parks on a wait_for. Rule 1 cuts in, runs to completion, and rule 2 must come back to the
  // SAME step - if it restarted, ru_starts would be 2.
  ok &= add(&written, preempt, `# memscan behaviour
desc higher interrupts lower, lower resumes
version 2
rule 1 once
  name urgent
  when var_is ru_trigger yes
node 10 action
  do var ru_trigger no
node 11 action
  do add ru_fired 1
rule 2 while
  name slow
  when always
node 20 action
  do add ru_starts 1
node 21 wait_for
  if var_is ru_go yes
node 22 action
  do var ru_finished yes
`, &fails)

  // A `once` rule against a condition that never goes false, and a failing step with a live step
  // behind it. Neither may happen more than it should.
  ok &= add(&written, latch, `# memscan behaviour
desc edge firing and abort-on-fail
version 2
rule 1 once
  name fires on the edge only
  when var_is ru_trigger yes
node 10 action
  do add ru_fired 1
rule 2 while
  name a failure aborts the rest
  when always
node 20 action
  do add ru_before 1
node 21 action
  do fail
node 22 action
  do add ru_after 1
`, &fails)
  if !ok {
    return
  }

  // One arbitration plus up to a tick's worth of steps, exactly as the watcher thread would do it.
  tick :: proc(session: ^Session) {
    ctx := Behaviour_Context {
      session = session,
      now     = time.now()._nsec,
      board   = &session.bh_board,
    }
    rules_tick(&ctx)
  }
  clear :: proc(session: ^Session, names: []string) {
    for name in names {
      engine.session_var_set(&session.eng, name, "")
    }
  }
  num :: proc(session: ^Session, name: string) -> string {
    v, _ := engine.session_var_get(&session.eng, name)
    return v
  }
  ALL_VARS :: []string {
    "ru_top", "ru_middle", "ru_bottom", "ru_trigger", "ru_fired", "ru_starts", "ru_go", "ru_finished",
    "ru_before", "ru_after",
  }

  // 1. FIRST MATCH WINS.
  script_stop(session)
  clear(session, ALL_VARS)
  script_cmd_run(session, []string{order})
  if !session.script.active {
    fmt.eprintfln("  FAIL: '%s' refused to start", order)
    return
  }
  for _ in 0 ..< 5 {
    tick(session)
  }
  if num(session, "ru_top") != "1" {
    fmt.eprintfln("  FAIL: the top rule should have run, ru_top is '%s'", num(session, "ru_top"))
    fails += 1
  }
  if num(session, "ru_middle") != "" || num(session, "ru_bottom") != "" {
    fmt.eprintfln("  FAIL: only the FIRST matching rule may run - ru_middle='%s' ru_bottom='%s'", num(session, "ru_middle"), num(session, "ru_bottom"))
    fails += 1
  }

  // 2. HIGHER INTERRUPTS LOWER, AND LOWER RESUMES.
  script_stop(session)
  clear(session, ALL_VARS)
  engine.session_var_set(&session.eng, "ru_trigger", "no")
  script_cmd_run(session, []string{preempt})
  if !session.script.active {
    fmt.eprintfln("  FAIL: '%s' refused to start", preempt)
    return
  }
  tick(session) // rule 2 takes control and parks on its wait_for
  if num(session, "ru_starts") != "1" {
    fmt.eprintfln("  FAIL: the low rule should have started once, ru_starts is '%s'", num(session, "ru_starts"))
    fails += 1
  }
  engine.session_var_set(&session.eng, "ru_trigger", "yes")
  tick(session) // rule 1 preempts, runs both its steps, and hands back
  if num(session, "ru_fired") != "1" {
    fmt.eprintfln("  FAIL: the high rule should have fired once, ru_fired is '%s'", num(session, "ru_fired"))
    fails += 1
  }
  if num(session, "ru_starts") != "1" {
    fmt.eprintfln("  FAIL: the low rule RESTARTED instead of resuming - ru_starts is '%s', expected 1", num(session, "ru_starts"))
    fails += 1
  }
  if num(session, "ru_finished") != "" {
    fmt.eprintln("  FAIL: the low rule ran past its wait_for while its condition was still false")
    fails += 1
  }
  engine.session_var_set(&session.eng, "ru_go", "yes")
  tick(session)
  if num(session, "ru_finished") != "yes" {
    fmt.eprintfln("  FAIL: the resumed rule should have finished, ru_finished is '%s'", num(session, "ru_finished"))
    fails += 1
  }
  if num(session, "ru_starts") != "1" {
    fmt.eprintfln("  FAIL: the low rule was restarted somewhere - ru_starts is '%s', expected 1", num(session, "ru_starts"))
    fails += 1
  }

  // 3. EDGE FIRING, AND A FAILING STEP ABORTS THE REST OF ITS RULE.
  script_stop(session)
  clear(session, ALL_VARS)
  engine.session_var_set(&session.eng, "ru_trigger", "yes") // true from the start and never cleared
  script_cmd_run(session, []string{latch})
  if !session.script.active {
    fmt.eprintfln("  FAIL: '%s' refused to start", latch)
    return
  }
  for _ in 0 ..< 20 {
    tick(session)
  }
  if num(session, "ru_fired") != "1" {
    fmt.eprintfln("  FAIL: a 'once' rule fired %s times against a condition that stayed true - expected 1", num(session, "ru_fired"))
    fails += 1
  }
  if num(session, "ru_before") == "" || num(session, "ru_before") == "0" {
    fmt.eprintln("  FAIL: the step before the failure never ran")
    fails += 1
  }
  if num(session, "ru_after") != "" {
    fmt.eprintfln("  FAIL: the step AFTER a failure ran %s time(s) - a failure must abort the sequence", num(session, "ru_after"))
    fails += 1
  }
  script_stop(session)
  clear(session, ALL_VARS)

  // 4. THE FORMAT ROUND-TRIPS. Write what we read, read it back, and the two must render identically -
  // the same check the graph half gets, so a rule can never lose a field across a save.
  for name in ([?]string{order, preempt, latch}) {
    doc, dok := bhv_open(name)
    if !dok {
      fmt.eprintfln("  FAIL: '%s' would not load", name)
      fails += 1
      continue
    }
    first := strings.builder_make(context.temp_allocator)
    bhv_serialize(&doc, &first)
    text := strings.to_string(first)
    behaviour_doc_free(&doc)

    again, aok := bhv_deserialize(name, text)
    if !aok {
      fmt.eprintfln("  FAIL: '%s' did not survive a save/load round-trip", name)
      fails += 1
      continue
    }
    second := strings.builder_make(context.temp_allocator)
    bhv_serialize(&again, &second)
    if strings.to_string(second) != text {
      fmt.eprintfln("  FAIL: '%s' renders differently after a round-trip", name)
      fails += 1
    }
    behaviour_doc_free(&again)
  }

  if fails == 0 {
    fmt.println("  PASS: first match wins, a higher rule preempts and the lower one RESUMES, 'once' fires on the edge, a failed step aborts its rule, and rules round-trip")
  }
}

// --- lifetime ------------------------------------------------------------------------------------

rule_free :: proc(rule: ^Rule) {
  delete(rule.label)
  script_condition_free(&rule.condition)
  script_steps_free(&rule.steps)
  rule^ = {}
}

rules_free :: proc(rules: ^[dynamic]Rule) {
  for &r in rules {
    rule_free(&r)
  }
  delete(rules^)
  rules^ = nil
}

// A deep copy, the twin of script_step_clone and needed for the same reason: the editor's undo ring
// snapshots whole documents, and a snapshot that shared its strings would be freed twice the moment
// either copy went away.
rule_clone :: proc(rule: Rule) -> (out: Rule) {
  out = rule
  out.label = rule.label == "" ? "" : strings.clone(rule.label)
  for i in 0 ..< condition_row_count(rule.condition) {
    r := condition_row_ptr(&out.condition, i)
    r.strs[0] = r.strs[0] == "" ? "" : strings.clone(r.strs[0])
    r.strs[1] = r.strs[1] == "" ? "" : strings.clone(r.strs[1])
  }
  out.steps = make([dynamic]Script_Step, 0, len(rule.steps))
  for s in rule.steps {
    append(&out.steps, script_step_clone(s))
  }
  return out
}
