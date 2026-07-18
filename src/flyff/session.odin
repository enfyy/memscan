package flyff

import "../engine"

// The flyff automation session. It EMBEDS the generic engine.Session as its first field so all
// the generic scan/process/watcher state is shared, and adds the Flyff-specific automation state
// on top. engine.Session must stay first (offset 0): the module hooks are handed a ^engine.Session
// and recover this struct with an offset-0 cast (see flyff_of in module.odin).
Session :: struct {
  using eng: engine.Session,

  // Live Flyff memory layout (RVAs + offsets). Seeded from flyff_layout_default(), overwritten
  // by flyff.cfg on attach, re-derived by `calibrate`. See flyff.odin Flyff_Layout / layout.odin.
  layout:        Flyff_Layout,
  tc_recent:     [dynamic]TC_Recent, // objs target_closest picked recently (skip just-killed)

  // Auto-farm mode (see auto_tick / cli_auto in target.odin). When on, the watcher thread
  // advances the focus to the next fresh mob matching auto_names whenever m_pObjFocus clears.
  // An empty auto_names list means "any monster" (name gate off; player is still excluded).
  auto_on:       bool,
  auto_names:    [dynamic]string, // cloned target names; empty = any monster. Freed on toggle/close.
  auto_last:     i64, // time.now()._nsec of the last advance attempt (throttle)
  auto_count:    int, // targets selected since auto turned on (reset on each toggle-on)
  auto_start:    i64, // time.now()._nsec when auto turned on (origin for the run timer)
  auto_timer_at: i64, // nsec deadline at which 'auto' auto-disables ('timer' cmd); 0 = disarmed
  auto_count_limit: int, // kill quota at which 'auto' auto-disables ('count' cmd); 0 = disarmed

  // Obstacle / stuck detection (see auto_monitor in target.odin). Tracks progress toward the
  // focused mob; if player->target distance plateaus while still far, the mob is blacklisted
  // (auto_blocked, skipped for BLOCKED_NS) and focus is cleared so the next tick re-acquires.
  auto_focus_obj:   uintptr, // obj currently being monitored (0 = none / just changed)
  auto_best_dist:   f32, // closest player->target distance seen this approach
  auto_progress_at: i64, // time.now()._nsec of the last real progress (start of the STUCK_NS window)
  auto_blocked:     [dynamic]TC_Recent, // mobs flagged unreachable; skipped by the picker for BLOCKED_NS
  auto_stuck_on:    bool, // stuck-detection enabled (default on; 'stuck off' disables, e.g. for ranged)
  auto_avoid_dir:   [2]f32, // horizontal (x,z) player->last-stuck-mob delta; one-shot steer-away hint
  auto_avoid_on:    bool, // next auto pick prefers a mob on the opposite side (dot < 0) from auto_avoid_dir

  // Proactive reach gate (see cand_reachable / tc_select). When on, auto skips candidate mobs whose
  // straight approach is blocked by terrain OR a placed-object OBB (the reach oracle) BEFORE selecting -
  // complements the reactive stuck-monitor. Inert unless the fast object path (aobjcull_rva) is set, so
  // it never triggers the slow scan in the pick loop. Default on; 'reachgate off' disables.
  reach_gate_on:    bool,

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

  // Pause (see pause_tick / cli_pause). auto_paused holds a running auto without advancing; killing the
  // watched mob resumes it. 'auto' starts paused (armed), so the first kill kicks off farming.
  auto_paused:      bool,
  pause_obj:        uintptr, // mob watched for a kill while paused (0 = none)
  pause_key_prev:   bool, // F10 edge-detection state for the default auto-toggle binding (see module_tick)

  // Last-used auto target spec, for the F10 full toggle (see module_tick / auto_rearm_command). Set on
  // every 'auto <spec>' start/switch; survives 'auto off' so F10 re-arms the same hunt. Freed on close.
  last_auto_names: [dynamic]string,
  last_auto_set:   bool,

  // Background candidate-collect job (see tc_scan_request / tc_scan_worker in target.odin). The
  // expensive enumeration (full region walk + parallel value scan) runs on a one-shot worker thread
  // WITHOUT exec_mutex; only the publish takes the lock. auto_tick consumes res_* on a later tick, so
  // the watcher never blocks the radar's frame pump on a kill (the kill-tick stutter fix).
  scan_job: Scan_Job,

  // Reach re-watch while a target is locked (see auto_reach_watch). Probes the straight approach every
  // REACH_RECHECK_NS; consecutive blocked probes (debounce) skip the mob like a stuck-skip.
  auto_reach_obj:        uintptr, // focus the current debounce window belongs to (0 = none)
  auto_reach_next_check: i64, // nsec of the next scheduled reach probe
  auto_reach_fail_count: int, // consecutive blocked probes so far

  // Async setup progress (see cli_setup / setup_step_mark). setup_running guards re-entry (one run at
  // a time, REPL or panel); setup_step (1..8, 0 = idle) feeds the radar panel's live step counter.
  setup_running: bool,
  setup_step:    int,

  // Penya gain tracking (Phase 6 C1). penya_tick (watcher tick + radar frame) watches the live penya
  // field: a rise adds to penya_total, bumps penya_seq, and appends a Penya_Event the radar drains into
  // a "+penya" pop + chime; a fall (spend) just re-baselines. penya_total accrues even with the radar
  // closed. Events are seq-tagged so the radar only replays ones newer than when it opened, and pruned
  // after PENYA_EVENT_TTL. Reset on attach, freed on close.
  penya_total:   i64,
  penya_last:    i64, // last-seen live penya (delta baseline)
  penya_seeded:  bool,
  penya_seq:     i64, // monotonic id of the latest penya-gain event
  penya_events:  [dynamic]Penya_Event,

  // Kill events (Phase 6 C2): appended at each confirmed kill (both kill sites) for the radar's laser
  // beam + zap. Seq-tagged + pruned like penya_events. Reset on attach, freed on close.
  kill_seq:      i64,
  kill_events:   [dynamic]Kill_Event,

  // Manual-kill watch (kill_watch_tick): while auto is OFF, watch the player's own selected target so a
  // hand-killed mob still fires the radar laser/zap (auto_tick only detects kills while auto is running).
  manual_kill_obj:      uintptr, // the focus currently being watched (0 = none)
  manual_kill_pos:      [3]f32, // its last-known position (the death spot)
  manual_kill_recorded: bool, // already fired the event for this obj's death (guard against re-firing per tick)

  // Timestamp (nsec) of the last CONFIRMED jump - set by cli_jump and lookalive_do_jump on success, so
  // the radar can play a dot-hop animation for every jump (manual + autonomous look-alive). 0 = none.
  jump_fired_at: i64,

  // Pre-select / precompute-next (see tc_precompute_next / auto_tick). While a target is focused, auto
  // precomputes the mob it will advance to next, so it can be committed the INSTANT focus clears on a
  // kill - removing the ~0.5s post-kill enumeration gap. One precompute per locked target: auto_next_for
  // is the focus obj the cache was computed against. The cached pick is re-validated at commit time
  // (focus_set_obj); if it went stale, auto falls back to the reactive tc_select scan. Default on.
  preselect_on:     bool,
  auto_next_obj:    uintptr, // the precomputed next target (0 / auto_next_set=false = none cached)
  auto_next_pos:    [3]f32, // its world pos (seeds the kill-anchor bookkeeping on commit)
  auto_next_set:    bool,
  auto_next_for:    uintptr, // the focused obj this cache is for (re-arm the precompute when focus changes)
  auto_next_stage:  TC_Stage, // which cascade stage produced the cached pick (drives cluster_advance on commit)
  auto_next_pack:   int, // the cached pick's local pack size (drives cluster_advance on commit)
  auto_next_anchor: [3]f32, // the stand-point the cache was measured from (re-arm if the fight drags away)

  // Look-alive mode (see cli_lookalive + the lookalive_* hooks in auto_tick). Opt-in human-like farming
  // for low-spawn quest grinds: a randomized hesitation before engaging each new target (delayed lock-on,
  // which also holds the pre-select fast-commit) and occasional jumps while travelling to a far target.
  // Deliberately less efficient than the snappy loop, so default OFF. Jumps reuse the 'findmove' primitive
  // and are skipped when char-control isn't configured. RNG = core:math/rand (see lookalive_rand_ns).
  lookalive_on:         bool,
  lookalive_hold_until: i64, // nsec deadline for the post-kill hesitation (0 = no active hold)
  lookalive_jump_at:    i64, // nsec of the next scheduled travel-jump attempt (0 = (re)seed on next tick)

  // Terrain calibration (see cli_worldscan in terrain.odin): surviving terrain-offset hypotheses,
  // narrowed across `worldscan` samples until one remains and is pinned into layout. Session-only.
  world_cal:     [dynamic]World_Cal_Cand,

  // Server target-sync (see notify_server_target / cli_srvsync). When on, each focus select
  // also fires the client's own SendSetTarget(objid, 2) so the server's m_idSetTarget matches
  // what we attack - the anti-DC fix. Defaults ON on attach (inert until configured); cleared on
  // detach/close and re-enabled on the next attach. 'srvsync off' disables it for the session.
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
}

#assert(offset_of(Session, eng) == 0) // module hooks recover ^Session from ^engine.Session (offset-0 cast)

// Initialise a fresh Session: the generic engine state, then the Flyff automation defaults, then
// register the flyff module (hooks). Returns false if the engine arena can't be created.
session_init :: proc(session: ^Session) -> bool {
  if !engine.session_init(&session.eng) {
    return false
  }
  session.auto_stuck_on = true // obstacle/stuck detection on by default (see auto_monitor)
  session.reach_gate_on = true // proactive reach gate on by default (inert until findcull sets aobjcull_rva)
  session.preselect_on = true // precompute the next target during combat -> instant advance on kill
  // Mesh-accurate reach confirm defaults OFF: it injects a game-code thread (IntersectObjLine) per
  // OBB-blocked candidate, which walks the live collision linkmaps concurrently with the main thread -
  // a real race that correlated with more client crashes during sustained farming. The zero-injection
  // decorative filter (collscan) delivers most of the benefit safely. Opt in per session with 'meshreach on'.
  session.mesh_reach_on = false
  session.layout = flyff_layout_default()
  flyff_register(session)
  return true
}

// Thin wrapper: engine.session_close stops the watcher, runs the module on_close hook (which frees
// the flyff remote pages + lifetime-owned data), closes the handle, and frees generic state.
session_close :: proc(session: ^Session) {
  engine.session_close(&session.eng)
}
