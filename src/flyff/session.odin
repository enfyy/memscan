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

  // Pause (see pause_tick / cli_pause). auto_paused holds a running auto without advancing; killing the
  // watched mob resumes it. 'auto' starts paused (armed), so the first kill kicks off farming.
  auto_paused:      bool,
  pause_obj:        uintptr, // mob watched for a kill while paused (0 = none)
  pause_key_prev:   bool, // F10 edge-detection state for the default pause binding (see module_tick)

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
