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

PAUSE_VK :: u32(0x79) // F10 - default key that toggles the auto-farm pause

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
}

// The flyff command set - reached by engine.dispatch when it doesn't recognise a command. Returns
// false for anything not ours (so the engine reports "unknown command").
module_dispatch :: proc(es: ^engine.Session, cmd: string, args: []string) -> (handled: bool) {
  s := flyff_of(es)
  switch cmd {
  case "target_closest", "tc", "get":
    cli_target_closest(s, args)
  case "tdbg", "tmap":
    cli_tdbg(s, args)
  case "auto":
    cli_auto(s, args)
  case "timer":
    cli_timer(s, args)
  case "kills":
    cli_kills(s, args)
  case "stuck":
    cli_stuck(s, args)
  case "reachgate":
    cli_reachgate(s, args)
  case "meshreach":
    cli_meshreach(s, args)
  case "pause":
    cli_pause(s, args)
  case "setup":
    cli_setup(s, args)
  case "calibrate", "cal":
    cli_calibrate(s, args)
  case "calibrate_house", "calh":
    cli_calibrate_house(s, args)
  case "offsets", "layout":
    cli_offsets(s, args)
  case "status", "doctor", "diag":
    cli_status(s, args)
  case "set":
    cli_set(s, args)
  case "findpos":
    cli_findpos(s, args)
  case "findplayer":
    cli_findplayer(s, args)
  case "findfocus":
    cli_findfocus(s, args)
  case "findhp":
    cli_findhp(s, args)
  case "hpwatch":
    cli_hpwatch(s, args)
  case "findpacket":
    cli_findpacket(s, args)
  case "packetwatch":
    cli_packetwatch(s, args)
  case "idscan":
    cli_idscan(s, args)
  case "findsettarget":
    cli_findsettarget(s, args)
  case "findaii":
    cli_findaii(s, args)
  case "findprop":
    cli_findprop(s, args)
  case "srvsync":
    cli_srvsync(s, args)
  case "srvtest":
    cli_srvtest(s, args)
  case "deathscan":
    cli_deathscan(s, args)
  case "objscan":
    cli_objscan(s, args)
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
  case "attr":
    cli_attr(s, args)
  case "attrmap":
    cli_attrmap(s, args)
  case "objects":
    cli_objects(s, args)
  case "collscan":
    cli_collscan(s, args)
  case "linkscan":
    cli_linkscan(s, args)
  case "reach":
    cli_reach(s, args)
  case "attackable", "canhit":
    cli_attackable(s, args)
  case "reachdbg":
    cli_reachdbg(s, args)
  case "findobjline":
    cli_findobjline(s, args)
  case "objline":
    cli_objline(s, args)
  case "reachcmp":
    cli_reachcmp(s, args)
  case "findcull":
    cli_findcull(s, args)
  case "findcam":
    cli_findcam(s, args)
  case "radar":
    cli_radar(s, args)
  case "fence":
    cli_fence(s, args)
  case:
    return false
  }
  return true
}

// Per-watcher-loop background work: the default F10 pause binding, the auto-farm advance, and the
// attack-range overlay redraw. Runs under exec_mutex (the engine watcher holds it).
module_tick :: proc(es: ^engine.Session) {
  s := flyff_of(es)
  // Default pause binding: F10 toggles the auto-farm pause (only while auto is on, so a stray press
  // off the clock does nothing).
  pause_down := engine.hotkey_key_down(PAUSE_VK)
  if pause_down && !s.pause_key_prev {
    if s.auto_on && es.exec_line != nil {
      fmt.printf("\n[F10] pause\n")
      es.exec_line(es, "pause")
      fmt.print("memscan> ")
    }
  }
  s.pause_key_prev = pause_down
  auto_tick(s) // hands-free farm: advance focus when the target dies
  range_ring_tick(s) // attack-range circle overlay (ring / draw_range) - non-blocking
}

// Per-process setup after attach: load the persisted layout + reset per-process caches, srvsync default.
on_attach :: proc(es: ^engine.Session) {
  s := flyff_of(es)
  // Fresh flyff caches for the new process (the generic scan reset already ran).
  delete(s.tc_recent)
  s.tc_recent = nil
  s.collider_cache_valid = false

  // Load the persisted Flyff layout (flyff.cfg next to memscan.exe) fresh over defaults, so a
  // patched build just needs 'calibrate' once. Absent file -> built-in defaults.
  s.layout = flyff_layout_default()
  cfg := flyff_cfg_path()
  if flyff_load_cfg(&s.layout, cfg) {
    fmt.printfln("layout: loaded %s", cfg)
  } else {
    fmt.println("layout: built-in defaults (run 'calibrate' if the game was patched).")
  }

  // srvsync defaults ON now that the anti-DC path is proven - it's always needed. It stays inert
  // (notify_server_target no-ops) until sendsettarget_rva/objid_off are set on a 32-bit client, so
  // enabling it unconditionally is safe. 'srvsync off' still disables it for the rest of the session.
  s.srvsync_on = true
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
  s.collider_cache_valid = false // stale across processes
}

// Session-end teardown: free the remote pages (if still attached) + all flyff lifetime-owned data.
on_close :: proc(es: ^engine.Session) {
  s := flyff_of(es)
  if s.attached {
    remote_free_shim(s)
    remote_free_spawn_page(s)
    remote_free_objline_page(s)
  }
  fence_destroy(&s.fence)
  auto_free_names(s)
  delete(s.tc_recent)
  delete(s.auto_blocked)
  delete(s.world_cal)
}

module_help :: proc() {
  fmt.println(HELP_FLYFF)
}

@(private = "file")
HELP_FLYFF :: `
============ FLYFF (Neuz.exe - offsets live in flyff.cfg, loaded on attach) ============
typical use: attach Neuz -> auto -> hold your attack key.   after a patch: 'setup <name>' in the field.
check the setup anytime with 'status'.

farming (day to day)
  target_closest <name>... (tc)  select nearest mover named <name>; repeat to advance.
                             several names ok: tc 'Aibatt', 'Captain Aibatt'
  auto [name]...             hands-free farm: starts ARMED (paused) - kill the first mob to begin, then it
                             re-targets on each kill. no name = ANY monster; names comma-separated. 'auto off' stops
  pause                      toggle pause (default key: F10). killing the targeted mob resumes
  timer <minutes>            auto-disable 'auto' after N minutes (e.g. 'timer 60'); 'timer off' cancels
  kills <n>                  auto-disable 'auto' after N confirmed kills (e.g. 'kills 100'); 'kills off' cancels
  stuck [on|off]             toggle reactive obstacle skip-detection (on by default; 'stuck off' for ranged/standing)
  reachgate [on|off]         proactively skip mobs behind walls/trees/buildings when auto-picks a target
  meshreach [on|off]         confirm OBB-blocked mobs with the client's IntersectObjLine (opt-in; injects, crash-prone)
                             inert until 'findobjline' pins intersectobjline_rva (re-run it after a game patch)
  findobjline                re-pin intersectobjline_rva by signature so meshreach / objline / reachcmp work again
  mobs <name>                list nearby <name> movers by distance (hp, model, address)
  tdbg [label] [zoom] (tmap)  write a top-down radar map of the PREDICTED auto kill-order
                             (tc_map[_label].html) + a console factor table; diagnoses target order.
                             label tags the file ('tdbg cloakia' vs 'tdbg tower'); a trailing number is
                             the view radius in world units ('tdbg tower 30' to zoom in)
  radar [seconds]            open a LIVE top-down radar window (player + mobs + obstacles); wheel=zoom,
                             ESC=close. raylib is statically linked (no dll). seconds>0 auto-closes.
                             press E in-window to draw a geo-fence (see 'fence').
  fence [sub]                geo-fence: never target mobs outside a drawn area. no arg = status. subs:
                             add circle <r>|<x,z> <r> [-] / add rect <halfx,halfz>|<min> <max> [-] /
                             poly start|point|end / undo / erase <x,z> / clear / on / off / test <x,z> /
                             save <name> / load <name> / list. a trailing '-' makes a carve-out (exclude).
                             adding a shape auto-activates the gate; 'fence off' overrides without clearing.
  ring [radius] [Ns]         draw your attack_range as a cyan circle on the ground (follows you, ~30s,
                             non-blocking); attack a mob to see if the ring reaches it. 'ring off' stops
  draw_range                 toggle a PERSISTENT range circle that live-tracks attack_range (so
                             'set attack_range 1.75' updates it instantly); run again to stop
  srvsync [on|off]           mirror each select to the server (stops the after-N-kills DC);
                             ON by default on attach
  srvtest                    fire one server SendSetTarget at the current target

setup & health (run once after a game patch)
  setup <name> [hp]          ONE-STEP setup: stand in a field on the ground, target your PET with
                             monsters on screen, then run it. Anchors on your character NAME (no
                             /position to type) and runs the whole pipeline (core + srvsync + focus +
                             prop-gate + coll-filter + terrain), ending with a checklist of anything
                             that still needs a different spot. Re-runnable. saves flyff.cfg
  status              (doctor)  health-check: what's configured, what's missing, and how to fix it
  calibrate <x,y,z> <name> [hp]  (cal) manual/fallback: re-derive the layout from /position + your
                             character name; also finds srvsync offsets, and focus_off if a mob
                             is selected. select a mob first for full setup. saves flyff.cfg
  calibrate_house <name> [hp]  (calh) same, from your house's fixed spawn (no /position; but no
                             mobs in the house, so focus_off is kept - pin it later in the field)
  offsets [save|load|reset] (layout)  no-arg = status; or persist/restore the layout
  set <field> <value>        set one layout field (see 'status'); auto-saves flyff.cfg

offset finders (one-time; each fills part of the layout)
  findfocus                  click a mob, then run: derives focus_off
  hpwatch                    target a mob and hit it: the field that drops is currentHP (hp_off)
  findsettarget              derive the srvsync offsets by signature (calibrate does this too)
  findprop                   target your PET (monsters on screen), then run: derives the any-monster gate
                             (species MoverProp array -> GetProp()->dwAI==AII_MONSTER). Excludes pets /
                             eggs / NPCs / players / bosses. One-time; re-run after a game patch.
  findaii                    diagnostic: dump a mover's AI-region fields / find pet tags (RE only)

terrain / obstacle reach oracle ('setup' pins these; commands below are for standalone use / diagnostics)
  worldscan [reset]          pin the terrain-grid offsets from your ground height (stand on solid
                             ground; if ambiguous, walk to a different-height spot and re-run)
  findcull                   locate the on-screen object array (legacy; reach no longer needs it - colliders full-scan)
  findcam                    locate the render camera (CWorld::m_pCamera); lets tdbg draw the cull cone / blind spot
  attr [x,z]                 terrain attribute at your feet (or a world point): NONE/NOWALK/NOMOVE/DIE
  attrmap [radius] [step]    ASCII map of terrain attributes around you (reveals invisible walls)
  objects [radius]           list nearby CObj of any type + locate m_OBB (props the grid misses)
  collscan [radius]          per nearby prop: model .o3d filename + collision-mesh type (NORMAL vs ERROR)
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
  objscan <value> <name>     find offsets holding <value> across <name> movers`
