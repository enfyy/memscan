package flyff

import "core:mem/virtual"
import rl "vendor:raylib"

import "../engine"

// The flyff automation session. It EMBEDS the generic engine.Session as its first field so all
// the generic scan/process/watcher state is shared, and adds the Flyff-specific automation state
// on top. engine.Session must stay first (offset 0): the module hooks are handed a ^engine.Session
// and recover this struct with an offset-0 cast (see flyff_of in module.odin).
Session :: struct {
  using eng: engine.Session,

  // Should not be here probably but this codebase is atrocious anyways because claude made it..
  alert_sound: rl.Sound,

  // Live Flyff memory layout (RVAs + offsets). Seeded from flyff_layout_default(), overwritten
  // by flyff.cfg on attach, re-derived by `calibrate`. See flyff.odin Flyff_Layout / layout.odin.
  layout:        Flyff_Layout,
  tc_recent:     [dynamic]TC_Recent, // objs target_closest picked recently (skip just-killed)

  // Auto-farm mode (see cli_auto). auto_on means "the farm chart is running" - it and session.script
  // are kept in step in both directions, so status and F10 can never disagree with what is actually
  // driving. An empty auto_names list means "any monster" (name gate off; player is still excluded).
  auto_on:       bool,
  auto_names:    [dynamic]string, // cloned target names; empty = any monster. Freed on toggle/close.
  auto_last:     i64, // time.now()._nsec of the last advance attempt (throttle)
  auto_count:    int, // targets selected since auto turned on (reset on each toggle-on)
  auto_start:    i64, // time.now()._nsec when auto turned on (origin for the run timer)

  // Obstacle / stuck detection (see auto_monitor in target.odin). Tracks progress toward the
  // focused mob; if player->target distance plateaus while still far, the mob is blacklisted
  // (auto_blocked, skipped for BLOCKED_NS) and focus is cleared so the next tick re-acquires.
  auto_blocked:     [dynamic]TC_Recent, // mobs flagged unreachable; skipped by the picker for BLOCKED_NS
  auto_avoid_dir:   [2]f32, // horizontal (x,z) player->last-stuck-mob delta; one-shot steer-away hint
  auto_avoid_on:    bool, // next auto pick prefers a mob on the opposite side (dot < 0) from auto_avoid_dir

  // Mesh-accurate reach confirm (see compute_reach / remote_intersect_objline). When on, a candidate the
  // loose OBB marks BLOCKED is re-tested with the client's own IntersectObjLine (OBB + triangle mesh) and
  // treated as Clear if the client can reach it - recovers mobs the whole-silhouette OBB false-blocks.
  // Injects a game-code thread per OBB-blocked candidate (OBB-clear is trusted, so no injection there).
  // Inert unless intersectobjline_rva is set + its prologue matches. Default OFF - the injected call walks
  // the live collision linkmaps and correlated with more crashes under sustained farming; 'meshreach on'.
  mesh_reach_on:    bool,

  // Geo-fence target boundary (see fence.odin / cli_fence). A flat list of +/- shapes; when active the
  // picker gates candidate mobs on fence_contains (tc_cand_skip) so the player never targets outside the
  // area. Authored by the radar mouse editor or the 'fence' text commands; serialized to fences/*.fence.
  // Mutated only under exec_mutex (REPL/radar) and read only under it (watcher picker) - no extra lock.
  fence:            Fence,

  // Waypoint sets (see waypoints.odin / cli_waypoints). ONE active ordered route plus many saved by
  // name, exactly the fence arrangement. Order is array position - there is no index field - so a
  // delete closes its own gap. Authored by the radar's flag editor (mode W) or the 'waypoints' text
  // commands; serialized to waypoints/*.waypoints, and importable into a chart as walk_to nodes.
  // Mutated only under exec_mutex (REPL/radar); nothing on the watcher side reads it at all.
  waypoint_set:     Waypoint_Set,
  // Whole-set undo snapshots, like the chart editor's (gui_nodes.odin), NOT the fence's pop-the-last:
  // this editor renames and reorders in place, and there is no popping a rename.
  waypoint_undo:    [dynamic]Waypoint_Set,
  waypoint_redo:    [dynamic]Waypoint_Set,

  // Bow-range retarget anchor (see tc_select). While a shootable mob is in bow range, the auto picker
  // ranks by nearest-to-the-last-kill's-spot instead of nearest-to-you, so a ranger stays on the pack.
  auto_sel_pos:     [3]f32, // world pos of the current auto target when it was selected (pending anchor)
  auto_sel_obj:     uintptr, // the auto target's object ptr, to confirm it actually died (vs deselected)
  auto_sel_set:     bool,
  last_kill_pos:    [3]f32, // selection pos of the last mob actually killed - the in-range retarget anchor
  last_kill_set:    bool,

  // Cluster commitment (density feature; see cluster_advance + the cluster stage in tc_pick_one). When
  // a pick lands in a real mob pack, auto commits to that pack and keeps killing members until none are
  // eligible - cluster_origin_pos is where the commitment started (the leash reference, so a line-spawn
  // can't chain-drag the commitment across the map). Mutated only by the pick paths under exec_mutex;
  // forced false whenever density is off.
  cluster_committed:  bool,
  cluster_origin_pos: [3]f32,

  pause_key_prev:   bool, // F10 edge-detection state for the default auto-toggle binding (see module_tick)

  // Last-used auto target spec, for the F10 full toggle (see module_tick / auto_rearm_command). Set on
  // every 'auto <spec>' start/switch; survives 'auto off' so F10 re-arms the same hunt. Freed on close.
  last_auto_names: [dynamic]string,
  last_auto_set:   bool,

  // Background candidate-collect job (see tc_scan_request / tc_scan_worker in target.odin). The
  // expensive enumeration (full region walk + parallel value scan) runs on a one-shot worker thread
  // WITHOUT exec_mutex; only the publish takes the lock. The scan_mobs block consumes res_* on a later
  // tick, so the watcher never blocks the radar's frame pump on a kill (the kill-tick stutter fix).
  scan_job: Scan_Job,

  // Async setup progress (see cli_setup / setup_step_mark). setup_running guards re-entry (one run at
  // a time, REPL or panel); setup_step (1..9, 0 = idle) feeds the radar panel's live step counter.
  setup_running: bool,
  setup_step:    int,

  // Penya gain tracking (Phase 6 C1). penya_tick (watcher tick + radar frame) watches the live penya
  // field. penya_last always tracks the live balance (a rise or fall re-baselines it), so the bottom-left
  // HUD shows real gold. A rise is only counted as EARNED - added to penya_total, bumps penya_seq, appends
  // a Penya_Event for the radar "+penya" pop + chime - when it pairs with a recent kill and is under
  // lb_penya_cap (see penya_tick); a Perin conversion / sale / trade moves the balance but isn't income.
  // penya_total accrues even with the radar closed. Events are seq-tagged so the radar only replays ones
  // newer than when it opened, and pruned after PENYA_EVENT_TTL. Reset on attach, freed on close.
  penya_total:   i64, // session penya EARNED (kill-paired), shown as "penya:" in the panel
  penya_last:    i64, // last-seen live penya = current gold balance (delta baseline + HUD readout)
  penya_seeded:  bool,
  penya_seq:     i64, // monotonic id of the latest penya-gain event
  penya_events:  [dynamic]Penya_Event,

  // Kill events (Phase 6 C2): appended at each confirmed kill (both kill sites) for the radar's laser
  // beam + zap. Seq-tagged + pruned like penya_events. Reset on attach, freed on close.
  kill_seq:      i64,
  kill_events:   [dynamic]Kill_Event,
  last_kill_ns:  i64, // time.now()._nsec of the last confirmed kill (auto OR manual); penya_tick only counts a
  // penya gain as EARNED (session total + radar pop) if it lands within LB_PENYA_KILL_WINDOW_NS of this, so
  // wallet manipulation (Perin conversion, sales) bumps your gold but not your farming stats. Set in record_kill_event.

  // Manual-kill watch (kill_watch_tick): while auto is OFF, watch the player's own selected target so a
  // hand-killed mob still fires the radar laser/zap (auto_tick only detects kills while auto is running).
  manual_kill_obj:      uintptr, // the focus currently being watched (0 = none)
  manual_kill_pos:      [3]f32, // its last-known position (the death spot)
  manual_kill_recorded: bool, // already fired the event for this obj's death (guard against re-firing per tick)

  // Timestamp (nsec) of the last CONFIRMED jump - set by cli_jump and lookalive_do_jump on success, so
  // the radar can play a dot-hop animation for every jump (manual + autonomous look-alive). 0 = none.
  jump_fired_at: i64,

  // The visual alert currently raised, if any (see alert.odin). Written by the `alert` block under
  // exec_mutex, snapshotted into Gui_Frame and drawn unlocked. Pure POD and self-expiring: the
  // timestamps on it decide what is on screen, so nothing has to tick it and a stale one costs nothing.
  alert:         Alert_State,

  // Leaderboard recording + backend (see leaderboard.odin). lb_run is an explicit Start/Stop span that
  // accumulates the farm stats to submit; lb_cur_name / lb_cur_pack carry the committed target's identity
  // + local pack size forward from the pick sites (target.odin / auto_commit_pick) so the kill sites can
  // attribute a kill's monster name + density even after the object is freed. Network results (submit /
  // board fetch) land in lb_status_buf + lb_board, written under exec_mutex by the async workers and read
  // by both the CLI and the radar. Reset on attach, freed on close.
  lb_run:        Leaderboard_Run,
  lb_cur_name:   [64]u8, // last committed auto target's name (NUL-terminated); the kill-attribution fallback
  lb_cur_pack:   int,    // last committed auto target's local pack size (feeds lb_run.max_density on kill)
  lb_net_busy:   bool,   // a submit/fetch worker is in flight (guards concurrent network calls)
  lb_status_buf: [128]u8, // last network status line (NUL-terminated), e.g. "submitted #42" / "rejected: ..."
  lb_board:      [dynamic]Lb_Row, // last fetched leaderboard page (value rows; drawn by the radar dialog)
  lb_board_sort: int,    // which sort key lb_board currently reflects (index into LB_SORTS)

  // Pre-select / precompute-next (see tc_precompute_next / auto_tick). While a target is focused, auto
  // precomputes the mob it will advance to next, so it can be committed the INSTANT focus clears on a
  // kill - removing the ~0.5s post-kill enumeration gap. One precompute per locked target: auto_next_for
  // is the focus obj the cache was computed against. The cached pick is re-validated at commit time
  // (focus_set_obj); if it went stale, auto falls back to the reactive tc_select scan. Default on.

  // Sweep mode (see sweep.odin / cli_sweep): a painted lane the character clears circle-by-circle. While
  // sweep_on, the picker short-circuits to "nearest mob already inside attack_range" (tc_pick_one) so
  // selection can never propose a walk, and sweep_tick owns the route - it erases the paint under us,
  // halts on engage, and hops one brush width forward once the circle has been clear for SWEEP_SETTLE_NS.
  // Same mutex discipline as `fence`: mutated and read only under exec_mutex. Cleared on attach, freed on
  // close. Deliberately NOT persisted - a lane is per-run state. auto_stop keeps the path + cursor (so an
  // F10 pause/resume continues where it left off) and resets only the walk bookkeeping.
  sweep_on:          bool, // a lane is armed / running
  sweep_path:        [dynamic]Sweep_Node,
  sweep_idx:         int, // cursor: the node we have swept up to
  sweep_walking:     bool, // a hop is currently issued (drives the halt-on-engage)
  sweep_wp:          [3]f32, // the hop waypoint we are walking to
  sweep_wp_idx:      int, // its node index (so an arrival / a blocked-hop skip lands the cursor exactly)
  sweep_best:        f32, // closest distance seen to sweep_wp (progress watchdog)
  sweep_progress_at: i64, // nsec of the last real progress toward sweep_wp
  sweep_clear_since: i64, // nsec since focus went empty (the "circle is clear" settle); 0 = not empty
  sweep_started_at:  i64, // nsec the lane was armed (the run timer)
  sweep_kills_start: int, // auto_count when it was armed - the completion message's kill delta
  sweep_nodes_total: int, // node count at arm time (the progress readout's denominator)
  hunt_side_flip:      bool, // which side the next side-step offsets to (flips every HUNT_SIDESTEP_FLIP stalls)

  // Behaviour machine (see behaviour.odin): the declared state machine that will eventually own
  // routing and replace auto's implicit flag-precedence chain. bh_state is the durable, printable
  // state tag - the live State_Function is rebuilt from it every tick and never stored. bh_board is
  // this tick's sense latch (cleared and refilled inside one exec_mutex hold, so a REPL reader always
  // sees a complete board). The bh_*_seen / bh_hp_* fields are observation baselines only: senses
  // read the game and compare against these, and never write game or auto state. All reset by
  // behaviour_reset on attach/detach - a sequence counter belongs to the process that produced it.
  bh_state:          Behaviour_State,
  bh_state_at:       i64, // nsec the current state was entered (the state timer)
  bh_entered:        bool, // has the STARTING state's Enter run? (a self-return is not a transition,
  // so state_machine_tick would never enter the first state - behaviour_tick does it once, see there)
  bh_board:          Behaviour_Board,
  bh_sense_on:       bool, // continuous sensing on the watcher tick ('sense on'); off = on-demand only
  bh_sense_next:     [Behaviour_Event]i64, // per-event throttle deadline (Sense_Def.poll_ns)
  bh_raised:         bit_set[Behaviour_Event], // signals an ACTION raised, published next tick
  bh_raised_sig:     [Behaviour_Event]Behaviour_Signal,
  bh_kill_seq_seen:  i64, // last kill_seq observed (kill sense baseline)
  bh_penya_seq_seen: i64, // last penya_seq observed (penya sense baseline)
  bh_hp_last:        i64, // last player HP observed (hp_fell sense baseline)
  bh_hp_seeded:      bool, // the first HP observation is a baseline, not a drop
  // Scratch arena for the senses that enumerate (see behaviour_scratch). NOT context.temp_allocator:
  // nothing frees temp on the watcher tick, so a per-tick temp allocation there grows forever.
  bh_scratch:        virtual.Arena,
  bh_scratch_ok:     bool,

  // Behaviour scripts (see script.odin / script_run.odin / script_blocks.odin). `script` is the live
  // run - owned steps, hoisted interrupt watchers, the program counter, and the loop stack. Freed in
  // on_close; the run is stopped in on_detach. There is no authoring buffer here on purpose: authoring
  // happens in Odin (builder.odin) or in the editor, and a saved behaviour is a file (behaviour_io.odin).
  script: Script_Run,

  // What the run just did, as a ring (see Script_Trace in script.odin). Session-scoped rather than
  // run-scoped on purpose: the run is freed the moment it ends, and "why did it stop" is asked after.
  // Pure observation - nothing reads it back to make a decision - so it is never reset on attach.
  script_trace: Script_Trace,

  // Keys the tool is currently HOLDING DOWN, indexed by virtual-key code (see keys.odin). Only
  // key_down/`key hold` put anything in here: a plain press is a down/up pair inside one step, but a
  // HELD key deliberately outlives the step that pressed it, so this is the record that lets every
  // teardown path (run end, detach) let go of it again.
  keys_held:     [KEY_VK_COUNT]bool,

  // Global interrupts, RUNTIME half - derived from layout.interrupts (the persisted enabled-set) by
  // armed_watcher_reload, which is the only thing that writes it. Holds each one's trigger and its edge latch;
  // the latch is why this cannot just be re-derived per tick. Freed in on_close.
  armed_watchers: [FLYFF_MAX_ARMED_WATCHERS]Armed_Watcher,
  armed_watcher_count:  int,
  // Which global row has control, -1 when none, plus its position within that row's steps. On the
  // SESSION rather than on Script_Run because the globals outlive any one behaviour: they are watching
  // whether or not something is running, which is the whole point of a global. See globals_tick.
  global_active:  int,
  global_pc:      int,
  global_entered: bool,

  // Terrain calibration (see cli_worldscan in terrain.odin): surviving terrain-offset hypotheses,
  // narrowed across `worldscan` samples until one remains and is pinned into layout. Session-only.
  world_cal:     [dynamic]World_Cal_Cand,

  // Server target-sync (see notify_server_target / cli_srvsync). When on, each focus select
  // also fires the client's own SendSetTarget(objid, 2) so the server's m_idSetTarget matches
  // what we attack - the anti-DC fix. Defaults ON on attach (inert until configured); cleared on
  // detach/close and re-enabled on the next attach. 'srvsync off' disables it for the session.
  // `bgkeys` (see cli_bgkeys / active_flag_tick in move.odin): hold the client's m_bActiveNeuz TRUE so its
  // own input pass keeps running while the window is in the background, which is what makes key_down W/A/S/D
  // actually move and TURN. Session-scoped rather than persisted-on by default: it is a continuous write
  // into the game, so it starts off and you turn it on deliberately.
  bgkeys_on:     bool,
  // findactive's differential narrowing set. Survives between invocations because the derivation IS two or
  // three passes with a focus change in between - see the note atop cli_findactive.
  // Dynamic, NOT a fixed array: the first cut capped this at 8192 and the seed hit the cap exactly, which
  // silently truncated the candidate set - so the flag might not have been in it at all and a unique
  // survivor was partly luck. Freed in on_close.
  active_cands:      [dynamic]uintptr,
  active_cand_count: int,
  active_scan_on:    bool,
  active_saw_fg:     int, // foreground samples taken; BOTH counts must be >0 before pinning
  active_saw_bg:     int,
  active_confirming:    bool, // one survivor left, now proving itself across ACTIVE_CONFIRM_FLIPS transitions
  active_confirm_flips: int,
  active_confirm_last:  bool, // the focus state of the previous sample, to count transitions not samples

  srvsync_on:    bool,
  srv_shim:      uintptr, // cached RWX shim page in the target (remote_send_settarget); 0 = none

  // Attack-range circle overlay (see range_ring_tick / cli_ring / cli_draw_range). The watcher thread
  // redraws it around the player each tick (pure overlay writes), so it never blocks the REPL. radius 0
  // live-tracks attack_range (draw_range); until 0 = indefinite toggle, else a deadline (ring [Ns]).
  range_ring_on:     bool,
  range_ring_until:  i64,
  range_ring_radius: f32,
  range_ring_last:   i64,

  // Cached RWX page for particle-marker injection (remote_spawn_particles). Reused across refreshes
  // so a fast tracking overlay doesn't VirtualAllocEx/Free every tick; grown when a batch needs more.
  // Freed with the other remote pages on detach/close. 0 = none.
  spawn_page:      uintptr,
  spawn_page_size: uint,

  // Cached RWX page for the client-IntersectObjLine remote call (remote_intersect_objline). Layout is
  // fixed-size (input vecs + result slot + shim), so it's allocated once and reused per query. 0 = none.
  objline_page: uintptr,

  // Cached RWX page for the jump remote call (remote_send_actmsg). Fixed small layout (result slot +
  // shim), allocated once and reused. Freed with the other remote pages on detach/close. 0 = none.
  actmsg_page: uintptr,

  // Cached RWX page for g_DPlay method calls (remote_send_snapshot - moveto's server-sync flush). moveto
  // field-writes the destpos then injects SendSnapshot(TRUE) so other clients see a walk. 0 = none.
  dplay_page: uintptr,

  // Camera-independent nearby-collider cache (see collect_area_colliders). Built by walking the player's
  // tile + neighbours' flat CLandscape object arrays (m_apObject), so reach sees off-camera obstacles the
  // render cull list misses. Static props don't move, so it's refreshed only when the player leaves the
  // cached area (moves > COLLIDER_CACHE_MOVE from center). Reach then tests segments against these OBBs.
  collider_cache:        [dynamic]Obb,
  collider_cache_center: [3]f32,
  collider_cache_valid:  bool,

  // Off-frame-thread collider-cache rebuild (see collider_refresh_async / collider_scan_worker in
  // terrain.odin). The radar's reach visualization must not block on the ~200ms full-scan rebuild, so
  // when it finds the cache stale it kicks this one-shot worker and keeps serving the (slightly stale)
  // cache; the worker publishes the fresh cache under exec_mutex. The picker's own reach gate is
  // unaffected - it stays synchronous/accurate (it already runs off-thread via scan_job).
  collider_job:          Collider_Job,

  // Persistent DRAW-ONLY obstacle memory (see collider_publish / collider_memory_merge in terrain.odin).
  // collider_cache above is a 120-unit window that is thrown away every ~16 units of walking, so props
  // popped in and out of the radar as you moved. This store keeps every collider we have already scanned
  // on the current map, evicted by distance (collider_memory_range) unless collider_memory_map keeps the
  // whole map for the session. It NEVER feeds reach / target gating / sweep validation - those stay on
  // collider_cache, because a remembered box the client has since unloaded must not be able to mark ground
  // unreachable. Bound to one map: collect_area_colliders resets it when the world identity changes.
  collider_memory:       [dynamic]Obb,
  collider_memory_bound: bool, // the store currently belongs to a map (the two ids below are meaningful)
  collider_memory_map:   u32, // CWorld::m_dwWorldID it belongs to (valid only when collider_memory_map_ok)
  collider_memory_map_ok: bool, // false when landwidth_off isn't pinned - then the CObj* below is the identity
  collider_memory_world: uintptr, // CWorld* fallback identity for when the map id can't be read
}

#assert(offset_of(Session, eng) == 0) // module hooks recover ^Session from ^engine.Session (offset-0 cast)

// Initialise a fresh Session: the generic engine state, then the Flyff automation defaults, then
// register the flyff module (hooks). Returns false if the engine arena can't be created.
session_init :: proc(session: ^Session) -> bool {
  session.global_active = -1 // no global rule has control (0 would claim row 0 does)
  if !engine.session_init(&session.eng) {
    return false
  }
  // Mesh-accurate reach confirm defaults OFF: it injects a game-code thread (IntersectObjLine) per
  // OBB-blocked candidate, which walks the live collision linkmaps concurrently with the main thread -
  // a real race that correlated with more client crashes during sustained farming. The zero-injection
  // decorative filter (collscan) delivers most of the benefit safely. Opt in per session with 'meshreach on'.
  session.mesh_reach_on = false
  session.layout = flyff_layout_default()
  // flyff.cfg at STARTUP, not only on attach. The file holds two kinds of thing under one roof: memory
  // offsets, which genuinely belong to a process, and tool preferences (ui_scale, sfx, trail, the
  // leaderboard URL, attack_range) which do not. Loading only on attach meant a detached session ran on
  // built-in defaults for both - so the offline chart editor opened at ui_scale 1.0 whatever you had
  // set, and any flyff_save_cfg reached while detached wrote those defaults straight over your file.
  // on_attach still re-reads it fresh over defaults per process; this is the floor under that.
  flyff_load_cfg(&session.layout, flyff_cfg_path()) // absent file = built-in defaults, and that is fine
  flyff_register(session)
  return true
}

// Thin wrapper: engine.session_close stops the watcher, runs the module on_close hook (which frees
// the flyff remote pages + lifetime-owned data), closes the handle, and frees generic state.
session_close :: proc(session: ^Session) {
  engine.session_close(&session.eng)
}
