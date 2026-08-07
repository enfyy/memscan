package flyff

import "core:fmt"
import "core:math"
import "core:time"

import "../engine"

// ===========================================================================
// Sweep mode - paint a path on the radar, clear it lane by lane.
//
// Normally the auto-brain decides WHERE the character goes: the priority ladder in tc_pick_one picks a
// mob and the character walks to it, so the route through a farm spot is an emergent side effect of
// scoring. Two rungs (aggro, nearest) are deliberately distance-unbounded, so on an open map the
// character wanders wherever the mobs happen to be. The geo-fence bounds where you may TARGET, but it is
// an area, not a route, and it does not move you.
//
// Sweep mode is the route: right-drag the attack-range circle on the radar to paint a swath of ground,
// release, and the bot clears the circle it is standing in, steps forward along the stroke, clears
// again - a lawnmower pass. The paint is erased by the circle as it passes, so the radar shows exactly
// how much lane is left. While a lane is armed the picker will only ever take a mob ALREADY inside
// attack_range of where we stand (see the sweep short-circuit in tc_pick_one), so selection can never
// propose a walk and nothing can pull the character off the painted route.
//
// No new memory offsets and no new finder: the walk is the same write_dest_pos + SendSnapshot pair
// moveto uses (needs 'findmove'), the validation is the existing reach oracle (terrain grid + collider
// OBBs), and the brush width IS layout.attack_range. Nothing is persisted to flyff.cfg - a lane is
// deliberately per-run state.
//
// Threading: session.sweep_* is mutated and read only under exec_mutex, exactly like session.fence -
// the REPL/radar author it, the watcher's sweep_tick consumes it. The radar's IN-PROGRESS stroke
// (Sweep_Wip) is frame-loop-local and never shared. See [[flyff-geofence]] / radar.odin for the gesture.
// ===========================================================================

// --- tuning -----------------------------------------------------------------------------------

SWEEP_SAMPLE :: f32(1.5) // resample spacing - the paint + erase granularity
SWEEP_MIN_LEN :: f32(8.0) // strokes shorter than this are rejected (a mis-click isn't a lane)
SWEEP_MAX_NODES :: 4000 // hard cap (~6000 world units of lane)
SWEEP_ARRIVE :: f32(2.0) // hop arrival tolerance (stays well under the hop length)
SWEEP_HOP_MIN :: f32(6.0) // floor for the hop length when attack_range is tiny (a melee char)
SWEEP_SETTLE_NS :: i64(400_000_000) // no-focus dwell before stepping forward (see sweep_tick)
SWEEP_FADE_NS :: i64(600_000_000) // eaten-node fade-out (the "erased by the circle" feel)

// --- types ------------------------------------------------------------------------------------

// One resampled point of a painted lane.
Sweep_Node :: struct {
  pos:      [3]f32, // world; y from the terrain heightmap where readable, else the player's y
  eaten:    bool, // the circle has passed over it
  eaten_at: i64, // nsec it was eaten - drives the short fade-out (0 = never)
  valid:    bool, // pre-validation verdict (drawing only; invalid nodes are trimmed on arm)
  soft:     bool, // valid, but an OT_OBJ prop's silhouette overlaps it - see sweep_obj_block
}

// Why a stroke's pre-validation rejected a node. Reported in the arm/reject message so a trimmed lane
// says WHAT stopped it. Fence is the avoid(!) zone gate that write_dest_pos would refuse at walk time
// anyway (better to say so while painting).
Sweep_Block :: enum {
  None,
  Terrain,
  Wall,
  Fence,
}

sweep_block_reason :: proc(b: Sweep_Block) -> string {
  switch b {
  case .Terrain:
    return "blocked by terrain"
  case .Wall:
    return "blocked by a wall or building"
  case .Fence:
    return "crosses an avoid(!) fence zone"
  case .None:
    return "clear"
  }
  return "clear"
}

// Sweep's object verdict, and the one place it deliberately DISAGREES with the attack-reach oracle.
//
// The reach oracle asks "is the sightline to that mob clear", and answers it with each prop's m_OBB -
// the whole-model silhouette. For a tree that box is the CANOPY: metres wider than the trunk, and it
// reaches the ground, so a knee-height segment passing between two trunks reads as blocked. For reach
// that pessimism is cheap (you skip a mob) - but for a painted lane it is destructive: on any wooded map
// the pre-validation would trim away most of a route you can in fact walk straight down. Reality is that
// you stroll under canopies all day.
//
// So sweep splits the verdict by object type, which is the one signal that actually tracks "solid at
// knee height":
//   OT_CTRL (walls, housing, railings) - solid top to bottom. A HARD block: the lane is trimmed there,
//     which is exactly the "painted through a building" case you want caught.
//   OT_OBJ  (trees, rocks, bushes)     - the silhouette lies. SOFT: the node stays walkable, is flagged
//     so the radar can draw it muted and the arm message can count it, and the runtime hop watchdog
//     (see sweep_tick) skips forward if one of them turns out to be genuinely solid. Recoverable, versus
//     silently deleting half the lane.
//
// (`meshreach on` would answer this exactly, via the client's own IntersectObjLine - but it injects a
// game-code thread per query and is default-OFF for crash reasons, so it is not something a mouse drag
// should be firing per node. See compute_reach's two-stage confirm.)
sweep_obj_block :: proc(session: ^Session, world: uintptr, prev: [3]f32, x, z: f32) -> (hard: bool, soft: bool) {
  if world == 0 || session.ptr_size != 4 {
    return false, false
  }
  knee := prev[1] + 0.4 // the same knee-height segment obj_segment_blocked tests
  for o in collect_area_colliders(session, world, prev[0], prev[2], allow_async = true) {
    if !obb_blocks_segment(o, prev[0], knee, prev[2], x, z) {
      continue
    }
    if o.ty == OT_CTRL {
      return true, soft
    }
    soft = true
  }
  return false, soft
}

// An in-progress stroke, owned by whoever is drawing it (the radar frame loop, or `sweep to`'s straight
// line). Only sweep_arm publishes it into the session, so a half-drawn lane never reaches the watcher.
Sweep_Wip :: struct {
  nodes:   [dynamic]Sweep_Node,
  blocked: bool, // latched by the first failing node - everything after it is flagged invalid
  why:     Sweep_Block, // what stopped that first node
  n_bad:   int, // how many invalid nodes were recorded after the latch (the trim count)
  n_soft:  int, // how many kept nodes thread under an OT_OBJ prop's silhouette (see sweep_obj_block)
}

// --- stroke authoring (pre-validated while you draw) ------------------------------------------

sweep_wip_free :: proc(w: ^Sweep_Wip) {
  delete(w.nodes)
}

sweep_wip_reset :: proc(w: ^Sweep_Wip) {
  clear(&w.nodes)
  w.blocked = false
  w.why = .None
  w.n_bad = 0
  w.n_soft = 0
}

// Start a stroke at the player's feet. The first node is valid by construction - we are standing on it.
sweep_wip_begin :: proc(w: ^Sweep_Wip, ppos: [3]f32) {
  sweep_wip_reset(w)
  append(&w.nodes, Sweep_Node{pos = ppos, valid = true})
}

// Can this node be walked to from <prev>? Four tests, in ascending cost, and only three of them are
// allowed to reject:
//   1. the terrain grid at the node's CELL - NOWALK/NOMOVE/DIE means a walker jams or dies there. It also
//      hands us the true ground height, which becomes the node's y.
//   2. the terrain raycast along the SEGMENT - an invisible wall between the two samples.
//   3. avoid(!) fence zones - write_dest_pos would refuse the hop anyway, so say so while drawing.
//   4. placed-object colliders - see sweep_obj_block: OT_CTRL rejects, OT_OBJ only flags `soft`.
// Everything degrades gracefully when the terrain offsets aren't pinned (world_attr_at reports "can't
// judge" and reach_raycast skips unjudgeable cells), so the object half still works half-configured.
// allow_async inside sweep_obj_block keeps a radar frame off a synchronous ~200ms collider rebuild.
sweep_validate :: proc(
  session: ^Session,
  world: uintptr,
  prev: [3]f32,
  x, z, fallback_y: f32,
) -> (
  y: f32,
  ok: bool,
  soft: bool,
  why: Sweep_Block,
) {
  y = fallback_y
  if wa, wok := world_attr_at(session, world, x, z); wok {
    y = wa.height
    if hattr_blocks_walk(wa.attr) {
      return y, false, false, .Terrain
    }
  }
  if tblocked, _ := reach_raycast(session, world, prev[0], prev[2], x, z); tblocked {
    return y, false, false, .Terrain
  }
  if !fence_move_ok(session.fence, prev, {x, y, z}) {
    return y, false, false, .Fence
  }
  hard, sft := sweep_obj_block(session, world, prev, x, z)
  if hard {
    return y, false, false, .Wall
  }
  return y, true, sft, .None
}

// Extend the stroke toward world point (mx,mz): append resampled nodes every SWEEP_SAMPLE units from the
// last one and pre-validate each. Once a node fails the stroke LATCHES blocked - later nodes are still
// recorded and drawn (so you can see where the cursor went) but flagged invalid and drawn red; sweep_arm
// trims them. <fallback_y> is the player's height, used where the heightmap can't be read.
//
// NOTE (collider cache): the object test anchors the collider set on the SEGMENT START, i.e. it walks
// with the stroke. Dragging a long lane therefore re-centres the cache away from the player and the
// picker pays one synchronous rebuild afterwards. Bounded (a rebuild is ~200ms, and only while you
// actually drag) and self-healing on the next pick, so it's left alone rather than special-cased.
sweep_wip_extend :: proc(session: ^Session, world: uintptr, w: ^Sweep_Wip, mx, mz, fallback_y: f32) {
  if len(w.nodes) == 0 {
    return
  }
  for len(w.nodes) < SWEEP_MAX_NODES {
    last := w.nodes[len(w.nodes) - 1].pos
    dx := mx - last[0]
    dz := mz - last[2]
    d := math.sqrt(dx * dx + dz * dz)
    if d < SWEEP_SAMPLE {
      return // cursor hasn't moved a full sample away yet
    }
    t := SWEEP_SAMPLE / d
    nx := last[0] + dx * t
    nz := last[2] + dz * t
    ny, ok, soft, why := sweep_validate(session, world, last, nx, nz, fallback_y)
    if !ok && !w.blocked {
      w.blocked = true
      w.why = why
    }
    node := Sweep_Node{pos = {nx, ny, nz}, valid = !w.blocked, soft = soft && !w.blocked}
    if !node.valid {
      w.n_bad += 1
    } else if node.soft {
      w.n_soft += 1
    }
    append(&w.nodes, node)
  }
}

// Total horizontal length of a node list (world units).
sweep_len :: proc(nodes: []Sweep_Node) -> f32 {
  total := f32(0)
  for i in 1 ..< len(nodes) {
    total += engine.dist_horizontal(nodes[i - 1].pos, nodes[i].pos)
  }
  return total
}

// Publish a finished stroke as the live lane. Invalid nodes only ever follow the latch, so trimming to
// the last valid node is a prefix scan. Rejects anything too short to be worth walking (and says what
// stopped it). Prints the outcome either way. Caller holds exec_mutex.
sweep_arm :: proc(session: ^Session, w: ^Sweep_Wip) -> bool {
  good := 0
  for nd in w.nodes {
    if !nd.valid {
      break
    }
    good += 1
  }
  nodes := w.nodes[:good]
  total := sweep_len(nodes)
  if good < 2 || total < SWEEP_MIN_LEN {
    if w.blocked {
      fmt.printfln("sweep: nothing to arm - the lane is %s within %.0f units of the start.", sweep_block_reason(w.why), max(total, f32(0)))
    } else {
      fmt.printfln("sweep: stroke too short (%.0f units) - paint at least %.0f.", total, SWEEP_MIN_LEN)
    }
    return false
  }
  clear(&session.sweep_path)
  append(&session.sweep_path, ..nodes)
  now := time.now()._nsec
  session.sweep_on = true
  session.sweep_idx = 0
  session.sweep_walking = false
  session.sweep_wp = {}
  session.sweep_wp_idx = 0
  session.sweep_best = 1e30
  session.sweep_progress_at = now
  session.sweep_clear_since = 0
  session.sweep_started_at = now
  session.sweep_kills_start = session.auto_count
  session.sweep_nodes_total = good

  line := fmt.tprintf("[sweep] armed - %.0f units, %d nodes", total, good)
  trimmed := len(w.nodes) - good
  if trimmed > 0 {
    line = fmt.tprintf("%s (trimmed %d nodes: %s)", line, trimmed, sweep_block_reason(w.why))
  }
  soft := 0
  for nd in nodes {
    if nd.soft {
      soft += 1
    }
  }
  if soft > 0 {
    // Kept on purpose - see sweep_obj_block. Say so, so a lane that visibly crosses a tree doesn't look
    // like the validation simply missed it.
    line = fmt.tprintf("%s, %d under props (kept - you walk under canopies)", line, soft)
  }
  if !session.auto_on {
    line = fmt.tprintf("%s - run 'auto' to start sweeping", line)
  }
  fmt.println(line)
  if !terrain_ready(session) {
    fmt.println("  note: terrain isn't calibrated ('worldscan'), so the lane was validated against placed objects only.")
  }
  if !moveto_configured(session) {
    fmt.println("  note: stepping along the lane needs 'findmove' - until then the paint only erases where you walk yourself.")
  }
  return true
}

// --- live lane state --------------------------------------------------------------------------

// Drop the lane and hand routing back to the normal ladder. Silent: callers own the message, because the
// same teardown is reached from the watcher (needs the "\n... memscan> " prompt dance) and from the
// REPL/radar (plain println). Caller holds exec_mutex.
sweep_clear :: proc(session: ^Session) {
  if session.sweep_walking {
    move_stop(session) // don't leave a hop running into ground we no longer own
  }
  session.sweep_on = false
  session.sweep_walking = false
  session.sweep_idx = 0
  session.sweep_wp_idx = 0
  session.sweep_wp = {}
  session.sweep_clear_since = 0
  session.sweep_nodes_total = 0
  clear(&session.sweep_path)
}

// Remaining lane: the un-eaten node count, the world length they span, and how far through we are.
// O(nodes) with the list capped at SWEEP_MAX_NODES, so it's cheap enough for a per-frame panel read.
sweep_progress :: proc(session: ^Session) -> (pct: f32, units_left: f32, nodes_left: int) {
  total := f32(0)
  for i in 1 ..< len(session.sweep_path) {
    seg := engine.dist_horizontal(session.sweep_path[i - 1].pos, session.sweep_path[i].pos)
    total += seg
    if !session.sweep_path[i].eaten {
      units_left += seg
    }
  }
  for nd in session.sweep_path {
    if !nd.eaten {
      nodes_left += 1
    }
  }
  if total > 0 {
    pct = (1 - units_left / total) * 100
  }
  return
}

// Is world point (x,z) within one brush width of an un-eaten node? The radar's "right-click the lane to
// cancel" hit test - checked BEFORE the start-a-stroke test, so a live lane is always cancellable.
sweep_hit_path :: proc(session: ^Session, x, z, r: f32) -> bool {
  r2 := r * r
  for nd in session.sweep_path {
    if nd.eaten {
      continue
    }
    dx := nd.pos[0] - x
    dz := nd.pos[2] - z
    if dx * dx + dz * dz <= r2 {
      return true
    }
  }
  return false
}

// Erase the paint the circle has passed over: every un-eaten node within <r> of the live player is eaten.
// Runs unconditionally each tick, so doubling back, a side-step, or walking the lane by hand all erase
// paint too - the painted swath always means "ground I have not stood on".
sweep_erase :: proc(session: ^Session, ppos: [3]f32, r: f32, now: i64) {
  r2 := r * r
  for &nd in session.sweep_path {
    if nd.eaten {
      continue
    }
    dx := nd.pos[0] - ppos[0]
    dz := nd.pos[2] - ppos[2]
    if dx * dx + dz * dz <= r2 {
      nd.eaten = true
      nd.eaten_at = now
    }
  }
}

// The lane is done: report and hand routing back to the ladder. Called from the watcher tick.
sweep_finish :: proc(session: ^Session, now: i64) {
  total := sweep_len(session.sweep_path[:])
  kills := session.auto_count - session.sweep_kills_start
  if kills < 0 {
    kills = 0 // auto_stop zeroes auto_count, so a pause/resume re-baselines rather than going negative
  }
  el := now - session.sweep_started_at
  sweep_clear(session)
  fmt.printf("\n[sweep] complete - %.0f units in %s, %d kills\n", total, fmt_elapsed(el), kills)
  fmt.print("memscan> ")
}

// --- the tick ---------------------------------------------------------------------------------

// Sweep's slice of auto_tick, called every ~20ms right after the pause check and BEFORE the look-alive
// approach. Returning true means "I own this tick" (auto_tick returns); false lets the rest of auto_tick
// run, which is how the normal focus-live combat branch and the (sweep-gated) picker still get their say.
//
// The loop is: erase the paint under us -> if something is locked, stop walking and fight it -> once the
// focus has been EMPTY for SWEEP_SETTLE_NS, the circle is clear, so hop one brush width along the lane.
//
// Why the settle window instead of asking "is anything in range?": candidate enumeration is backgrounded
// for stutter (tc_scan_request), so there is no cheap synchronous answer. But focus != 0 IS the
// observable answer - while anything eligible is in range the picker keeps locking it, so focus keeps
// coming back. 400ms of empty focus (against a ~20ms tick and a ~20-60ms scan turnaround) is a solid
// "nothing left in this circle". Worst case we start a short hop while a mob is being picked; the next
// tick sees the focus and halts. If that ever reads badly, RAISE SWEEP_SETTLE_NS - do not try to make the
// in-range check synchronous, that would put the full mover enumeration back on the watcher tick (the
// exact stutter the Phase 6 background-scan fix removed).
sweep_tick :: proc(session: ^Session, now: i64) -> (handled: bool) {
  if !session.sweep_on {
    return false
  }
  if len(session.sweep_path) == 0 {
    sweep_clear(session) // defensive: an empty lane is no lane
    return false
  }
  // Pre-select is off while sweeping: the cache is measured from where the current fight is, and by the
  // time it commits we may have hopped a brush width forward - a stale pick can drift out of the circle.

  _, engage := pick_ranges(session)
  ppos, pok := read_player_pos(session)
  if !pok {
    return true // transient read failure - hold the lane rather than letting the ladder re-steer us
  }
  sweep_erase(session, ppos, engage, now)

  // A live target is locked: halt any hop (a walk would drag us out of our own reach mid-fight) and let
  // auto_tick's normal focus-live branch run the combat/stuck/HP watches.
  if focus, fok := read_focus_ptr(session); fok && focus != 0 && focus_obj_live(session, focus) {
    if session.sweep_walking {
      move_stop(session)
      session.sweep_walking = false
    }
    session.sweep_clear_since = 0
    return false
  }
  // No focus. Let the picker have a look before we believe the circle is empty (see the header).
  if session.sweep_clear_since == 0 {
    session.sweep_clear_since = now
    return false
  }
  if now - session.sweep_clear_since < SWEEP_SETTLE_NS {
    return false
  }
  // Settled: nothing eligible is in range, so step forward. Without char control we can't - the lane
  // still erases wherever you walk it yourself, and normal (in-range-only) targeting keeps running.
  if !moveto_configured(session) {
    return false
  }
  hop := max(engage, SWEEP_HOP_MIN)
  hop_step := max(1, int(hop / SWEEP_SAMPLE))
  if !session.sweep_walking {
    idx := session.sweep_idx
    for idx < len(session.sweep_path) && session.sweep_path[idx].eaten {
      idx += 1 // monotonic, so this whole scan is O(nodes) across the entire sweep
    }
    session.sweep_idx = idx
    if idx >= len(session.sweep_path) {
      sweep_finish(session, now)
      return false // lane cleared - the normal ladder owns routing again from this tick on
    }
    tgt := min(idx + hop_step, len(session.sweep_path) - 1)
    wp := session.sweep_path[tgt].pos
    if !write_dest_pos(session, ppos, wp) {
      // Couldn't issue the walk: a transient unreadable player, or a permanent refusal (an avoid(!)
      // fence zone drawn across the lane AFTER it was painted). Re-arm the settle so we retry at a
      // sane rate, and hand the tick BACK - a lane we can't walk must never stop us from targeting
      // what is already in reach.
      session.sweep_clear_since = 0
      return false
    }
    remote_send_snapshot(session) // broadcast so other clients see a walk, not a teleport
    session.sweep_wp = wp
    session.sweep_wp_idx = tgt
    session.sweep_walking = true
    session.sweep_best = engine.dist_horizontal(ppos, wp)
    session.sweep_progress_at = now
    return true
  }
  d := engine.dist_horizontal(ppos, session.sweep_wp)
  if d <= SWEEP_ARRIVE {
    session.sweep_idx = session.sweep_wp_idx
    session.sweep_walking = false
    session.sweep_clear_since = 0 // re-settle: anything that wandered in during the hop gets fought first
    return true
  }
  // Progress watchdog, same shape as lookalive_approach_tick's.
  if d < session.sweep_best - PROGRESS_EPS {
    session.sweep_best = d
    session.sweep_progress_at = now
    return true
  }
  if now - session.sweep_progress_at >= STUCK_NS {
    // Pre-validation cleared this ground, so whatever is in the way is transient (a mob body, a moving
    // prop, another player). Eat the hop's nodes and step past rather than grinding into it.
    skipped := f32(0)
    for i := session.sweep_idx; i <= session.sweep_wp_idx && i < len(session.sweep_path); i += 1 {
      if i > 0 {
        skipped += engine.dist_horizontal(session.sweep_path[i - 1].pos, session.sweep_path[i].pos)
      }
      session.sweep_path[i].eaten = true
      session.sweep_path[i].eaten_at = now
    }
    session.sweep_idx = session.sweep_wp_idx + 1
    session.sweep_walking = false
    session.sweep_clear_since = 0
    move_stop(session)
    fmt.printf("\n[sweep] hop blocked - skipping %.0f units\n", skipped)
    fmt.print("memscan> ")
  }
  return true
}

// --- CLI --------------------------------------------------------------------------------------

sweep_print_status :: proc(session: ^Session) {
  if !session.sweep_on {
    fmt.println("sweep: no lane armed.")
    fmt.println("  paint one by RIGHT-DRAGGING from inside the green attack-range ring on the radar, or 'sweep to <x,z>'.")
    return
  }
  pct, left, nodes_left := sweep_progress(session)
  total := sweep_len(session.sweep_path[:])
  state := "armed (auto is off - 'auto' to start sweeping)"
  if session.auto_on {
    state = session.sweep_walking ? "WALKING the lane" : "clearing the circle"
  }
  fmt.printfln("sweep: %s", state)
  fmt.printfln(
    "  %.0f%% done - %.0f of %.0f units left (%d/%d nodes), %s elapsed, %d kills",
    pct, left, total, nodes_left, session.sweep_nodes_total,
    fmt_elapsed(time.now()._nsec - session.sweep_started_at),
    max(session.auto_count - session.sweep_kills_start, 0),
  )
  soft := 0
  for nd in session.sweep_path {
    if nd.soft {
      soft += 1
    }
  }
  if soft > 0 {
    fmt.printfln("  %d nodes thread under a tree/rock silhouette (kept on purpose - see 'sweep' in help); drawn olive on the radar.", soft)
  }
  fmt.println("  only mobs already inside attack_range are eligible while a lane is armed. 'sweep off' to drop it.")
  if !moveto_configured(session) {
    fmt.println("  note: 'findmove' isn't pinned, so the lane can't step you forward - run it to walk the lane hands-free.")
  }
}

// sweep                -> status: armed/running, nodes + units left, elapsed, kills this sweep
// sweep off | clear    -> drop the lane; normal ladder targeting resumes
// sweep to <x,z>       -> arm a straight lane from the player to a world point, pre-validated exactly
//                         like a radar stroke. Not just convenience: it makes the whole feature
//                         scriptable through stdin, which is how everything else here gets verified
//                         without a GUI.
cli_sweep :: proc(session: ^Session, args: []string) {
  if len(args) == 0 {
    sweep_print_status(session)
    return
  }
  switch args[0] {
  case "status":
    sweep_print_status(session)

  case "off", "clear", "stop":
    if !session.sweep_on {
      fmt.println("sweep: no lane armed.")
      return
    }
    _, left, _ := sweep_progress(session)
    sweep_clear(session)
    fmt.printfln("sweep: lane dropped (%.0f units unswept) - normal targeting resumed.", left)

  case "to":
    if len(args) < 2 {
      fmt.eprintln("usage: sweep to <x,z>   (arm a straight lane from you to that world point)")
      return
    }
    if session.sweep_on {
      fmt.eprintln("sweep: a lane is already armed - 'sweep off' first.")
      return
    }
    if !session.attached {
      fmt.eprintln("sweep: attach first (the lane is validated against the live world).")
      return
    }
    if session.layout.attack_range <= 0 {
      fmt.eprintln("sweep: attack_range is 0, and it IS the lane's brush width. fix: 'set attack_range <n>'.")
      return
    }
    coords, n, cok := parse_coords(args[1:])
    if !cok || n != 2 {
      fmt.eprintln("sweep to: bad coords - use x,z (e.g. 'sweep to 6800,3300').")
      return
    }
    world, _, ppos, aok := tc_resolve_anchors(session)
    if !aok {
      fmt.eprintln("sweep: couldn't read the world/player anchors - be fully in-game, then run 'setup <name>'.")
      return
    }
    wip: Sweep_Wip
    defer sweep_wip_free(&wip)
    sweep_wip_begin(&wip, ppos)
    sweep_wip_extend(session, world, &wip, f32(coords[0]), f32(coords[1]), ppos[1])
    sweep_arm(session, &wip)

  case:
    fmt.eprintfln("sweep: unknown subcommand '%s' (status|to <x,z>|off)", args[0])
  }
}
