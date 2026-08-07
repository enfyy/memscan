package flyff

import "core:fmt"
import "../engine"

// ===========================================================================
// Flyff module registration + hooks.
//
// The generic engine host (engine/repl.odin, engine/hotkey.odin, engine
// attach/detach) calls into flyff only through the function-pointer hooks
// registered here, so the engine never imports flyff. Each hook is handed a
// ^engine.Session and recovers the full ^flyff.Session with flyff_of (valid
// because engine.Session is the first field of flyff.Session - see session.odin).
// ===========================================================================

PAUSE_VK :: u32(0x79) // F10 - default key that stops/starts the auto-farm (full toggle, see module_tick)

// Recover the flyff Session from the embedded engine.Session pointer (offset-0 cast).
flyff_of :: #force_inline proc(es: ^engine.Session) -> ^Session {
  return cast(^Session)es
}

// Wire the flyff module into the engine session (called by session_init). flyff is active from
// startup, so the whole command suite works headlessly; `module flyff` (Phase 3) opens its UI.
flyff_register :: proc(session: ^Session) {
  session.module_active = true
  session.module_name = "flyff"
  session.module_dispatch = module_dispatch
  session.module_tick = module_tick
  session.module_help = module_help
  session.on_attach = on_attach
  session.on_detach = on_detach
  session.on_close = on_close
  session.open_ui = open_ui_hook
}

// `module flyff` (Phase 3) opens the radar with its control panel. Entered under exec_mutex (the REPL
// holds it around dispatch), exactly like the `radar` command - cli_radar releases the lock per frame so
// the watcher keeps farming while the panel is open. Both entry points open the same paneled window.
open_ui_hook :: proc(es: ^engine.Session) {
  cli_radar(flyff_of(es), {})
}

// The flyff command set - reached by engine.dispatch when it doesn't recognise a command. Returns
// false for anything not ours (so the engine reports "unknown command").
module_dispatch :: proc(es: ^engine.Session, cmd: string, args: []string) -> (handled: bool) {
  s := flyff_of(es)
  switch cmd {
  case "auto":
    cli_auto(s, args)
  case "meshreach":
    cli_meshreach(s, args)
  case "sfx":
    cli_sfx(s, args)
  case "alert":
    cli_alert(s, args)
  case "fxlaser":
    cli_fxlaser(s, args)
  case "trail":
    cli_trail(s, args)
  case "hillshade":
    cli_hillshade(s, args)
  case "nowalk":
    cli_nowalk(s, args)
  case "collwatch":
    cli_collwatch(s, args)
  case "setup":
    cli_setup(s, args)
  case "offsets", "layout":
    cli_offsets(s, args)
  case "status", "doctor", "diag":
    cli_status(s, args)
  case "set":
    cli_set(s, args)
  case "findsettarget":
    cli_findsettarget(s, args)
  case "findaii":
    cli_findaii(s, args)
  case "findprop":
    cli_findprop(s, args)
  case "srvsync":
    cli_srvsync(s, args)
  case "findpenya":
    cli_findpenya(s, args)
  case "findinv":
    cli_findinv(s, args)
  case "inv":
    cli_inv(s, args)
  case "mobs":
    cli_mobs(s, args)
  case "mark":
    cli_mark(s, args)
  case "ring":
    cli_ring(s, args)
  case "draw_range", "drawrange":
    cli_draw_range(s, args)
  case "markmobs":
    cli_markmobs(s, args)
  case "findparticle":
    cli_findparticle(s, args)
  case "warmtype":
    cli_warmtype(s, args)
  case "worldscan":
    cli_worldscan(s, args)
  case "objects":
    cli_objects(s, args)
  case "collscan":
    cli_collscan(s, args)
  case "collignore":
    cli_collignore(s, args)
  case "collmem":
    cli_collmem(s, args)
  case "reach":
    cli_reach(s, args)
  case "attackable", "canhit":
    cli_attackable(s, args)
  case "reachdbg":
    cli_reachdbg(s, args)
  case "findobjline":
    cli_findobjline(s, args)
  case "findcam":
    cli_findcam(s, args)
  case "radar":
    cli_radar(s, args)
  case "fence":
    cli_fence(s, args)
  case "waypoints", "wp":
    cli_waypoints(s, args)
  case "sweep":
    cli_sweep(s, args)
  case "moveto", "walkto", "go":
    cli_moveto(s, args)
  case "jump":
    cli_jump(s, args)
  case "findmove":
    cli_findmove(s, args)
  case "findactive":
    cli_findactive(s, args)
  case "bgkeys":
    cli_bgkeys(s, args)
  case "leaderboard", "lb":
    cli_leaderboard(s, args)
  case "script", "sc":
    cli_script(s, args)
  case "interrupt", "irq":
    cli_interrupt(s, args)
  case "key":
    cli_key(s, args)
  case:
    return false
  }
  return true
}

// Per-watcher-loop background work: the default F10 stop/start binding, the auto-farm advance, and
// the attack-range overlay redraw. Runs under exec_mutex (the engine watcher holds it).
module_tick :: proc(es: ^engine.Session) {
  s := flyff_of(es)
  // Default F10 binding: a FULL auto toggle. Running -> 'auto off'; off -> re-arm with the last-used
  // target spec (or any-monster). The re-arm goes through cli_auto, so it starts ARMED-paused exactly
  // like typing the command (first manual kill kicks it off). 'pause' is still typeable, just unbound.
  toggle_down := engine.hotkey_key_down(PAUSE_VK)
  if toggle_down && !s.pause_key_prev {
    if s.attached && es.exec_line != nil {
      if s.auto_on {
        fmt.printf("\n[F10] auto off\n")
        es.exec_line(es, "auto off")
      } else {
        cmd := auto_rearm_command(s)
        fmt.printf("\n[F10] %s\n", cmd)
        es.exec_line(es, cmd)
      }
      fmt.print("memscan> ")
    }
  }
  s.pause_key_prev = toggle_down
  // The behaviour machine OWNS routing now. `auto` is a chart it runs (bh_auto in behaviours.odin), so
  // there is no second farm tick beside it - the flag-precedence chain that used to live in auto_tick
  // is the chart's graph.
  // Before the behaviour tick: a chart's key_down is worthless if the client's input pass is still gated
  // off this frame, and re-asserting the flag is a single read (plus a write only when it actually flipped).
  active_flag_scan_tick(s) // findactive's self-sampling narrowing pass (inert unless armed)
  active_flag_tick(s)
  behaviour_tick(s)
  penya_tick(s) // accrue penya total + record gains for the radar (works with the radar closed)
  range_ring_tick(s) // attack-range circle overlay (ring / draw_range) - non-blocking
}

// Per-process setup after attach: load the persisted layout + reset per-process caches, srvsync default.
on_attach :: proc(es: ^engine.Session) {
  s := flyff_of(es)
  // Fresh flyff caches for the new process (the generic scan reset already ran).
  delete(s.tc_recent)
  s.tc_recent = nil
  s.collider_cache_valid = false
  s.collider_job.gen += 1 // orphan any in-flight collider rebuild from the previous process
  collider_memory_reset(s) // remembered obstacles belong to one process's world, never carry them over
  // A painted lane belongs to the world it was drawn in - never carry one across processes. The walk flag
  // is dropped FIRST so sweep_clear's halt-the-hop write can't fire into the new process with the old
  // (about to be reloaded) layout; the previous process is gone, so there is no walk left to stop.
  s.sweep_walking = false
  sweep_clear(s)

  // Re-load the persisted Flyff layout (flyff.cfg next to memscan.exe) fresh over defaults, so a
  // patched build just needs 'calibrate' once. Absent file -> built-in defaults. session_init already
  // read it at startup (a detached session needs the preferences half); this is the PER-PROCESS
  // re-read, and it resets first so offsets derived for the previous client cannot survive into this one.
  s.layout = flyff_layout_default()
  cfg := flyff_cfg_path()
  if flyff_load_cfg(&s.layout, cfg) {
    fmt.printfln("layout: loaded %s", cfg)
  } else {
    fmt.println("layout: built-in defaults (run 'setup <name>' if the game was patched).")
  }
  // Derive the global-interrupt runtime half from the names the cfg just restored: read each file's
  // trigger and arm it. Has to happen after the whole cfg is in, and after layout defaults, because
  // it is a function of layout.interrupts.
  armed_watcher_reload(s)
  if s.armed_watcher_count > 0 {
    fmt.printfln("interrupt: %d armed - 'interrupt list'.", s.armed_watcher_count)
    engine.ensure_hotkey_thread(&s.eng) // they are evaluated on the watcher tick
  }

  // Runtime-toggle mirrors: the session bools stay authoritative at runtime; the layout copies exist
  // only so they persist through flyff.cfg. Load them into the live session here; their CLI toggles
  // (preselect / lookalive / reachgate / hunt) write both sides + save. sfx/fxlaser live on the layout only.
  s.preselect_on = s.layout.preselect_on
  s.lookalive_on = s.layout.lookalive_on
  s.reach_gate_on = s.layout.reach_gate_on
  s.bgkeys_on = s.layout.bgkeys_on
  s.hunt_on = s.layout.hunt_on
  s.combat_watch_on = s.layout.combat_watch_on
  s.auto_stuck_on = s.layout.auto_stuck_on
  s.aggro_first_on = s.layout.aggro_first_on
  s.melee_first_on = s.layout.melee_first_on
  s.pocket_on = s.layout.pocket_on

  // srvsync defaults ON now that the anti-DC path is proven - it's always needed. It stays inert
  // (notify_server_target no-ops) until sendsettarget_rva/objid_off are set on a 32-bit client, so
  // enabling it unconditionally is safe. 'srvsync off' still disables it for the rest of the session.
  s.srvsync_on = true

  // Fresh penya/kill juice state for the new process (the total is per-session).
  s.penya_total = 0
  s.penya_last = 0
  s.penya_seeded = false
  s.penya_seq = 0
  clear(&s.penya_events)
  s.kill_seq = 0
  clear(&s.kill_events)
  s.last_kill_ns = 0
  s.manual_kill_obj = 0
  s.manual_kill_recorded = false

  // Fresh behaviour-machine baselines for the new process (see behaviour.odin) - kill/penya sequence
  // counters and the HP anchor belong to the process that produced them.
  behaviour_reset(s)

  // Fresh leaderboard recording span for the new process (see leaderboard.odin).
  lb_run_reset(s)
  s.lb_net_busy = false
  s.lb_status_buf[0] = 0

  if s.ptr_size == 4 && s.layout.sendsettarget_rva != 0 && s.layout.objid_off != 0 {
    fmt.println("srvsync: ON (default). 'srvsync off' to disable.")
  } else {
    fmt.println("srvsync: ON (default) but inert until configured - run 'findsettarget' on the 32-bit Neuz.exe.")
  }
}

// Per-process teardown before the handle is closed (detach, re-attach, or app close). Stops auto,
// clears the range overlay, and frees the remote RWX pages on the still-open handle.
on_detach :: proc(es: ^engine.Session) {
  s := flyff_of(es)
  auto_stop(s) // stop auto-farm + clear its run state when the process goes away
  range_ring_stop(s) // stop the attack-range overlay
  s.srvsync_on = false
  remote_free_shim(s)
  remote_free_spawn_page(s)
  remote_free_objline_page(s)
  remote_free_actmsg_page(s)
  remote_free_dplay_page(s)
  s.collider_cache_valid = false // stale across processes
  s.collider_job.gen += 1 // discard a collider rebuild still running against the detached process
  collider_memory_reset(s) // the remembered map goes with the process it was scanned from
  // Stop a running script BEFORE the baselines are reset: it goes through the state machine, so the
  // in-flight action's Exit still runs against the process it was issued in (halting a walk while
  // there is still something to halt). Same reasoning as sweep_walking being dropped on attach.
  script_stop(s)
  // After the script, for the same reason and one level wider: script_teardown released whatever the
  // chart was holding, this catches a key held by hand (`key hold w`) that no run owns. Still on the
  // live window, so the client actually sees the WM_KEYUP.
  keys_release_all(s)
  behaviour_reset(s) // drop the sense baselines with the process they were measured against
}

// Session-end teardown: free the remote pages (if still attached) + all flyff lifetime-owned data.
on_close :: proc(es: ^engine.Session) {
  s := flyff_of(es)
  if s.attached {
    remote_free_shim(s)
    remote_free_spawn_page(s)
    remote_free_objline_page(s)
    remote_free_actmsg_page(s)
    remote_free_dplay_page(s)
  }
  script_run_free(&s.script) // owned steps + watchers
  armed_watcher_free_all(s) // global interrupts: each holds an owned trigger + name
  behaviour_scratch_free(s)
  delete(s.active_cands) // findactive's narrowing set
  fence_destroy(&s.fence)
  waypoint_destroy(s) // the live route + both history stacks
  delete(s.sweep_path)
  auto_free_names(s)
  for n in s.last_auto_names {
    delete(n)
  }
  delete(s.last_auto_names)
  tc_scan_invalidate(s) // free an unconsumed background batch; an in-flight worker self-discards
  lb_run_free(s) // free the leaderboard run's monster-name map + keys
  delete(s.lb_board)
  delete(s.penya_events)
  delete(s.kill_events)
  delete(s.tc_recent)
  delete(s.auto_blocked)
  delete(s.world_cal)
  delete(s.collider_cache)
  delete(s.collider_memory)
}

module_help :: proc() {
  fmt.println(HELP_FLYFF)
}

@(private = "file")
HELP_FLYFF :: `
====== FLYFF (Neuz.exe - offsets live in flyff.cfg, read at startup + fresh on every attach) ======
typical use: attach Neuz -> auto -> hold your attack key.   after a patch: 'setup <name>' in the field.
check the setup anytime with 'status'.

farming (day to day)
  target_closest <name>... (tc)  select nearest mover named <name>; repeat to advance.
                             several names ok: tc 'Aibatt', 'Captain Aibatt'
  target_at <addr>    (tat)  select the EXACT object at <addr> (a live CObj*, e.g. an address from
                             'mobs'). the primitive behind the radar's click-to-target
  auto [name]...             hands-free farm: starts ARMED (paused) - kill the first mob to begin, then it
                             re-targets on each kill. no name = ANY monster; names comma-separated. 'auto off' stops
  pause                      toggle pause (auto stays on, stops advancing). killing the targeted mob
                             resumes. F10 = full auto stop/start toggle (re-arms the last target spec)
  timer <minutes>            auto-disable 'auto' after N minutes (e.g. 'timer 60'); 'timer off' cancels
  kills <n>                  auto-disable 'auto' after N confirmed kills (e.g. 'kills 100'); 'kills off' cancels
  priority                   show the target PRIORITY LADDER - the ordered rungs auto picks by. the first
                             rung that finds an eligible mob wins; each optional rung toggles independently
  priority aggro on|off      rung 1: a mob that is coming for YOU outranks everything, at any distance
  priority melee on|off|<r>  rung 2: a mob within <r> units of you outranks pack-stickiness (default 3)
  priority pocket on|off     rung 3: inside attack_range, prefer the mob nearest your last kill (pack sticky)
  preset [name]              apply a whole playstyle at once (tower|tanky|ranged|quest|boss); bare 'preset'
                             lists them and marks the one your current settings match
  aggro [radius]             diagnostic: which nearby mobs are targeting YOU (their m_idDest vs your objid).
                             read-only - use it to confirm rung 1 sees what you expect
  stuck [on|off]             toggle reactive obstacle skip-detection (on by default; 'stuck off' for ranged/standing)
  combatwatch [on|off|<s>]   never drop a target whose HP is falling - fixes high-HP mobs being skipped mid-fight
                             by the stuck/reach fallbacks (on by default; <s> = seconds since the last hit that
                             still count as fighting, default 4 - raise it above your slowest attack/cast interval)
  density [on|off]           cluster steering: OFF (default) = target the plain nearest mob (v0.4.0 behaviour).
                             ON commits to a mob pack until it's wiped; a farther pack steals the pick only past the gates below
  density mingain <n>        gate 1: extra pack members a farther pack needs to steal the pick (default 3)
  density detour <n>         gate 2: max extra walk distance (world units) for that detour (default 20)
  density hue [on|off]       radar display only: tint monster dots by local pack size (lone red -> dense green)
  preselect [on|off]         precompute the next target while fighting so auto advances instantly on kill (on by default)
  lookalive [on|off]         human-like farming (opt-in): hesitation + jumps + intermediate steps + max-range approach (walk behaviors need findmove)
  lookalive hesitate|jump|step|maxrange on|off   enable/disable one sub-behavior independently
  lookalive hold <min> <max> hesitation window (s, delayed lock-on); lookalive jump <min> <max> jump interval (s); lookalive chance <0-100> jump-fire odds
  lookalive step chance <0-100> odds an advance detours via one offset step; step spread <units> waypoint sideways range; maxrange <units> shrinking-hop distance
  lookalive show             print the current enables + tuning
  reachgate [on|off]         proactively skip mobs behind walls/trees/buildings when auto-picks a target
  hunt [on|off]              hunt mode: commit to one target (giant/quest), never drop it for being far/unreachable; side-step around blocks (needs findmove)
  sfx [on|off]               radar sound effects (penya chime + kill zap); persisted to flyff.cfg
  alert <sev> <text> [secs]  raise a visual alert over the radar: coloured border + banner. sev is
                             info/warn/danger; a trailing number is the duration (0 = until cleared).
                             'alert clear' takes it down, 'alert' alone reports what is up.
                             Border strength is 'set alert_scale' (0 = banner only).
  fxlaser [on|off]           radar kill laser-beam effect; persisted to flyff.cfg
  set ui_scale <n>           UI scale (0.6..3.0, default 1). The font atlas is baked when the window
                             opens, so re-open the radar for it to take effect.
  meshreach [on|off]         confirm OBB-blocked mobs with the client's IntersectObjLine (opt-in; injects, crash-prone)
                             inert until 'findobjline' pins intersectobjline_rva (re-run it after a game patch)
  findobjline                re-pin intersectobjline_rva by signature so meshreach / objline / reachcmp work again
  mobs <name>                list nearby <name> movers by distance (hp, model, address)
  radar [seconds]            open the WINDOW (live top-down map + the Dear ImGui control surface);
                             wheel=zoom, titlebar X closes it (ESC no longer does). raylib+imgui are
                             statically linked (no dll). seconds>0 auto-closes. Does NOT need an attached
                             process: with none it opens on the Attach dialog (defaults to 'neuz'), and
                             'Work offline' there gets you the browser and the chart EDITOR with no game
                             running - browse, edit, lint and save charts, then Attach when you want to
                             run one. Every block is placeable offline; only the ones with no code behind
                             them yet are not ('script blocks' marks those [xx]).
                             LEFT-CLICK a mob to target it; SHIFT+LEFT-CLICK the ground to walk there
                             (needs 'findmove'); a '+penya' pops on each pickup (needs 'findpenya').
                             toolbar (top-left): setup traffic light -> the Setup dialog (checklist +
                             attack_range), the BEHAVIOUR BROWSER (every chart, Odin and saved; left-click
                             runs, right-click duplicates/renames/deletes), zone/fence editor (E), camera
                             follow (L, ON by default), no-walk overlay (N), mute, and - once
                             leaderboard_url is set - LEADERBOARDS (the trophy). While a chart runs, a
                             transport strip (play/pause, rewind, step, stop + the current block) sits
                             top-centre. Unlock the camera and a recenter button appears bottom-right (C
                             also works); penya + bag gauges sit bottom-left. auto and the targeting
                             options are CLI-only for now.
  hillshade [on|off]         radar display only: colourless terrain shaded-relief backdrop (key H).
                             needs 'worldscan'; depth/light are 'set hillshade_z' / 'set hillshade_light'
  nowalk [on|off]            radar display only: paint the walk-blocking terrain cells the reach oracle
                             tests - orange NOWALK (fly-only), red NOMOVE (wall), magenta DIE (key N).
                             needs 'worldscan'. This is how you SEE an invisible wall before auto hits it
  module flyff               same window as 'radar'.
  fence [sub]                geo-fence: never target mobs outside a drawn area. no arg = status. subs:
                             add circle <r>|<x,z> <r> [-|!] / add rect <halfx,halfz>|<min> <max> [-|!] /
                             poly start|point|end / undo / erase <x,z> / clear / on / off / test <x,z> /
                             save <name> / load <name> / list. trailing tag: '+' include (default), '-' exclude
                             (carve-out; don't target inside), '!' AVOID (a hard no-go: don't target inside OR
                             behind it, and the player never walks through it - e.g. a tower teleport pad).
                             adding a shape auto-activates the gate; 'fence off' overrides without clearing.
  waypoints [sub]   (wp)     WAYPOINT SETS - an ordered, named route you draw on the map and import into
                             a chart. Place flags on the radar in W mode (left-click places, drag moves,
                             right-click a flag for name/order/delete, Ctrl+Z undoes), or add them from
                             here as you walk. Order IS the list order: deleting one closes its own gap.
                             no arg = status. subs: show / add [<x,z>] [name...] (no coords = at your
                             feet) / rename <n> <name...> / move <n> <to> / delete <n> / clear / undo /
                             redo / save [name] / load <name> / list / erase <name> / import <set> [as
                             <chart>]. Indices are 1-based. 'import' writes a NEW chart of walk_to nodes,
                             one per waypoint, each in a section named after it - it runs once and stops,
                             so wire the last node yourself. It refuses to overwrite an existing chart.
                             A set remembers which map it was drawn on and says so when that is not the
                             map you are standing on (needs 'worldscan' for the map id).
  sweep [sub]                SWEEP MODE - paint a route and clear it lane by lane. RIGHT-DRAG from inside
                             the green attack-range ring on the radar to paint a swath the width of your
                             reach; release and auto clears the circle it stands in, steps forward along
                             the stroke, clears again (a lawnmower pass). The paint erases behind you, so
                             you can see what's left. While a lane is armed the picker will ONLY take mobs
                             already inside attack_range, so nothing can pull you off the route (hunt and
                             the look-alive walk behaviors are suppressed until it ends). The stroke is
                             validated as you draw it: terrain walls, avoid(!) fence zones and OT_CTRL
                             walls/buildings turn the rest of it red and are trimmed on release. Tree and
                             rock silhouettes do NOT trim - their OBB is the whole canopy, not the trunk,
                             and you walk under canopies - so those stretches stay, tinted olive, and the
                             hop watchdog steps past one that turns out to be solid.
                             RIGHT-CLICK the lane to cancel. Needs 'findmove'.
                             no arg = status. subs: to <x,z> (straight lane from you - scriptable) / off
  ring [radius] [Ns]         draw your attack_range as a cyan circle on the ground (follows you, ~30s,
                             non-blocking); attack a mob to see if the ring reaches it. 'ring off' stops
  draw_range                 toggle a PERSISTENT range circle that live-tracks attack_range (so
                             'set attack_range 1.75' updates it instantly); run again to stop
  srvsync [on|off]           mirror each select to the server (stops the after-N-kills DC);
                             ON by default on attach
  srvtest                    fire one server SendSetTarget at the current target

character control (no keypress simulation; run 'findmove' once to pin it)
  moveto <x,z> | <x,y,z>     walk to a world point - writes CMover's dest fields, so the client walks
                             there itself (like a ground click). Y defaults to your height. aliases: walkto, go
  key <name>                 press one game hotkey now (1-9, a-z, f1-f12, space...). posts to the
                             game window, so it does NOT need focus. the primitive behind press_key
  key hold <name>            push a key down and LEAVE it down (walking, hold-to-attack); the
                             primitive behind key_down. 'key release [<name>]' lets go of one or all.
                             released automatically when a script ends or on detach
  jump                       jump (sends the client's own OBJMSG_JUMP; all in-game jump guards apply)
  position (pos)             print your world position (copy-paste x,y,z for moveto / findpos)
  findmove                   pin the move/jump config (dest-field offsets + sendactmsg_rva via the
                             actmover vtable + actmover_off + jump_msg); re-run after a game patch. saves flyff.cfg


behaviour scripts (build your own farming behaviour out of blocks; 'auto' becomes one script among many)
  script blocks              THE CATALOG: every action + event, with [OK] / [--] and what a missing
                             one still needs. this is both the reference and the roadmap
  script list                every behaviour: the ones written in Odin (flyff/behaviours.odin) and the
                             ones saved as files. A SAVED one wins over an Odin one of the same name
  script show <name>         print the blocks it builds, without running it
  script run <name> [once|loop]   validate every block, then run it
  script                     status: which step, how long, which interrupts are armed
  script pause | resume      freeze the whole machine / let it go again. PAUSED means nothing runs at
                             all, not even interrupts, so you come back to exactly what you left
  script reset               rewind to the start node without rebuilding: loop stack, kill tally,
                             interrupt latches and clocks all reset, and the in-flight step is torn down
  script step [off]          debug: freeze the run and execute ONE block at a time ('off' resumes).
                             interrupts keep running while stepping, so you can still break out
  script stop                end the run - whatever was in flight gets torn down (a walk halts)
  script export <b> [as <n>]  build an Odin behaviour and write it out as an editable file - this is how
                             a built-in becomes something you can open and change
  script save <name>         snapshot the RUNNING program to a file
  script nocollision <name> [on|off]   run that chart with the reach check OFF: pick, approach and hold
                             without asking whether the path is clear. for maps whose floor props do not
                             really block (most dungeons) - it ignores REAL walls too, so it is per-chart
  script delete <name>       /  script rename <old> <new>
  behaviours are DATA: <exe-dir>/behaviours/<name>.bhv, written by 'export'/'save' and by the editor.
  there is no text language to learn and no 'script load' - 'show' and 'run' take a saved name directly.
  authoring is either plain Odin (builder.odin - Odin's own control flow runs at BUILD time and
  disappears, so only real runtime decisions cost a node) or the visual editor.

behaviour machine (the declared state machine that will replace the hardcoded 'auto' - see behaviour.odin)
  sense                      one-shot: what the machine can SEE right now (target, kills, penya, HP, bag).
                             read-only - a sense can never change what the bot does
  sense on|off               continuous sensing on the background tick (off by default; costs a few
                             small reads per tick, the enumerating ones are throttled)
  sense list                 every sense, what it means, and how often it is polled

setup & health (run once after a game patch)
  setup <name> [hp]          ONE-STEP setup: stand in a field on the ground with a few DISTINCT monster
                             species on screen, then run it (no target needed). Anchors on your character
                             NAME (no /position to type) and runs the whole pipeline (core + srvsync +
                             focus + prop-gate + coll-filter + terrain), ending with a checklist of
                             anything that still needs a different spot. Re-runnable. saves flyff.cfg
  status              (doctor)  health-check: what's configured, what's missing, and how to fix it
  offsets [save|load|reset] (layout)  no-arg = status; or persist/restore the layout
  set <field> <value>        set one layout field (see 'status'); auto-saves flyff.cfg

offset finders (one-time; each fills part of the layout)
  findfocus                  click a mob, then run: derives focus_off
  hpwatch                    target a mob and hit it: the field that drops is currentHP (hp_off)
  findsettarget              derive the srvsync offsets by signature (setup does this too)
  findprop                   stand where a few DISTINCT monsters are on screen, then run (no target needed):
                             derives the any-monster gate (species MoverProp array -> GetProp()->dwAI==
                             AII_MONSTER). Excludes pets / eggs / NPCs / players / bosses. Re-run after a patch.
  findaii                    diagnostic: dump a mover's AI-region fields / find pet tags (RE only)

terrain / obstacle reach oracle ('setup' pins these; commands below are for standalone use / diagnostics)
  worldscan [reset]          pin the terrain-grid offsets from your ground height (stand on solid
                             ground; if ambiguous, walk to a different-height spot and re-run)
  findcull                   locate the on-screen object array (legacy; reach no longer needs it - colliders full-scan)
  findcam                    locate the render camera (CWorld::m_pCamera); drives the radar's camera frustum (F)
  attr [x,z]                 terrain attribute at your feet (or a world point): NONE/NOWALK/NOMOVE/DIE
  attrmap [radius] [step]    ASCII map of terrain attributes around you (reveals invisible walls)
  objects [radius]           list nearby CObj of any type + locate m_OBB (props the grid misses)
  collscan [radius]          per nearby prop: model .o3d filename + collision-mesh type (NORMAL vs ERROR)
  collwatch [secs] [radius] [all]  catch a TRANSIENT collider (respawn VFX): polls + logs each SOLID
                             box the instant it appears (mobs/items hidden unless 'all'). [COLLIDER] = culprit
  collmem [on|off|map|clear]  persistent obstacle memory (on by default; radar key M): props STAY on the
                             radar once seen instead of popping out past 120 units. 'map' remembers the
                             whole current map for the session; otherwise boxes evict past
                             collider_memory_range (default 1200, 'set collider_memory_range <n>').
                             DRAW-ONLY - reach / target selection / sweep still use the live 120-unit set.
  reach [x,z]                is the straight path player->point (or ->selected target) walkable?
  attackable          (canhit)  is the SELECTED mob reachable to attack? (terrain + object obstacles,
                             within attack_range). select a mob, stand behind cover, run it.
  objline [x,z]              client's own IntersectObjLine (mesh-accurate) vs our OBB oracle for one segment
  reachcmp [n]               compare OBB oracle vs client IntersectObjLine over the nearest n mobs (finds false blocks)

deep recon (rarely needed)
  findpos <x,y,z> [eps]      addresses whose 3 f32 match a position
  findhp <name>              guess hp_off statistically (prefer hpwatch)
  idscan <name>              find m_objid across <name> movers
  findpacket [objid]         scan for the outgoing SETTARGET packet id
  packetwatch                snapshot, click a mob, catch the fresh SETTARGET packet
  deathscan <name>           find a corpse despawn-countdown field
  objscan <value> <name>     find offsets holding <value> across <name> movers
  findpenya <penya> [span]   pin penya_off (your gold field) by its value -> radar '+penya' pop.
                             read your penya off the UI; if ambiguous, kill a mob + re-run w/ the new value
  findinv [slots]            auto-pin inv_off + item_stride (no value needed) -> enables 'inv'
  inv                        report inventory fill (used/free/capacity, FULL); needs 'findinv'

leaderboards (submit a timed farm run to a self-hosted backend)
  set leaderboard_url <url>  point the client at your backend (e.g. https://host/); enables everything below.
                             'set leaderboard_url -' (or "" / off) clears it. saves flyff.cfg
  leaderboard start   (lb)   begin a recording span: kills, penya collected, peak local density, and the set
                             of monster species farmed accrue while it runs
  leaderboard stop           freeze the span (keeps the numbers for inspection / submit)
  leaderboard status         span progress + whether the 5-min minimum is met + last network result
  leaderboard submit <name>  finalize + POST the run under <name> (needs >=5 min). Uploads your farming
                             setup (behavior keys only, never memory offsets). Runs off the main loop (no UI hitch)
  leaderboard top [sort]     fetch + print the board. sort: penya|kills|kpm (default penya)
  leaderboard getcfg <id> [path]  download entry <id>'s flyff.cfg (to path, or flyff_<id>.cfg)
  set lb_penya_cap <n>       anti-cheat: penya counts ONLY gains paired with a recent kill AND <= <n> (default
                             10M) - for BOTH the panel "penya:" total and a submission. A 100M Perin is ignored.
                             cheat-proofing is layered + honest: build-hash gate + HMAC signing + server-side
                             plausibility (>=5 min, rate caps) + rate limiting. A memory tool's self-reported
                             stats are still spoofable by a determined attacker - this raises the bar, not anti-cheat.
  every one of the above is also a button: once leaderboard_url is set, a trophy joins the radar toolbar
  and opens the board + the run recorder (it lights up while a run is recording).`
