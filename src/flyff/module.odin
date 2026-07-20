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
  case "target_closest", "tc", "get":
    cli_target_closest(s, args)
  case "target_at", "tat":
    cli_target_at(s, args)
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
  case "preselect":
    cli_preselect(s, args)
  case "lookalive":
    cli_lookalive(s, args)
  case "density":
    cli_density(s, args)
  case "reachgate":
    cli_reachgate(s, args)
  case "hunt":
    cli_hunt(s, args)
  case "meshreach":
    cli_meshreach(s, args)
  case "sfx":
    cli_sfx(s, args)
  case "fxlaser":
    cli_fxlaser(s, args)
  case "trail":
    cli_trail(s, args)
  case "collwatch":
    cli_collwatch(s, args)
  case "pause":
    cli_pause(s, args)
  case "setup":
    cli_setup(s, args)
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
  case "moveto", "walkto", "go":
    cli_moveto(s, args)
  case "jump":
    cli_jump(s, args)
  case "position", "pos", "/position":
    cli_position(s, args)
  case "findmove":
    cli_findmove(s, args)
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
  auto_tick(s) // hands-free farm: advance focus when the target dies
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

  // Load the persisted Flyff layout (flyff.cfg next to memscan.exe) fresh over defaults, so a
  // patched build just needs 'calibrate' once. Absent file -> built-in defaults.
  s.layout = flyff_layout_default()
  cfg := flyff_cfg_path()
  if flyff_load_cfg(&s.layout, cfg) {
    fmt.printfln("layout: loaded %s", cfg)
  } else {
    fmt.println("layout: built-in defaults (run 'setup <name>' if the game was patched).")
  }

  // Runtime-toggle mirrors: the session bools stay authoritative at runtime; the layout copies exist
  // only so they persist through flyff.cfg. Load them into the live session here; their CLI toggles
  // (preselect / lookalive / reachgate / hunt) write both sides + save. sfx/fxlaser live on the layout only.
  s.preselect_on = s.layout.preselect_on
  s.lookalive_on = s.layout.lookalive_on
  s.reach_gate_on = s.layout.reach_gate_on
  s.hunt_on = s.layout.hunt_on

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
  s.manual_kill_obj = 0
  s.manual_kill_recorded = false

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
  fence_destroy(&s.fence)
  auto_free_names(s)
  for n in s.last_auto_names {
    delete(n)
  }
  delete(s.last_auto_names)
  tc_scan_invalidate(s) // free an unconsumed background batch; an in-flight worker self-discards
  delete(s.penya_events)
  delete(s.kill_events)
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
  target_at <addr>    (tat)  select the EXACT object at <addr> (a live CObj*, e.g. an address from
                             'mobs'). the primitive behind the radar's click-to-target
  auto [name]...             hands-free farm: starts ARMED (paused) - kill the first mob to begin, then it
                             re-targets on each kill. no name = ANY monster; names comma-separated. 'auto off' stops
  pause                      toggle pause (auto stays on, stops advancing). killing the targeted mob
                             resumes. F10 = full auto stop/start toggle (re-arms the last target spec)
  timer <minutes>            auto-disable 'auto' after N minutes (e.g. 'timer 60'); 'timer off' cancels
  kills <n>                  auto-disable 'auto' after N confirmed kills (e.g. 'kills 100'); 'kills off' cancels
  stuck [on|off]             toggle reactive obstacle skip-detection (on by default; 'stuck off' for ranged/standing)
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
  fxlaser [on|off]           radar kill laser-beam effect; persisted to flyff.cfg
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
                             LEFT-CLICK a mob to target it; SHIFT+LEFT-CLICK the ground to walk there
                             (needs 'findmove'); a '+penya' pops on each pickup (needs 'findpenya').
                             press E in-window to draw a geo-fence (see 'fence').
  module flyff               open the radar with the CONTROL PANEL: setup status lights (hover for the
                             fix), a Setup dialog, the auto-farm toggle, a mob search + chip picker, the
                             attack_range slider, and fence/view buttons. same window as 'radar'.
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

character control (no keypress simulation; run 'findmove' once to pin it)
  moveto <x,z> | <x,y,z>     walk to a world point - writes CMover's dest fields, so the client walks
                             there itself (like a ground click). Y defaults to your height. aliases: walkto, go
  jump                       jump (sends the client's own OBJMSG_JUMP; all in-game jump guards apply)
  position (pos)             print your world position (copy-paste x,y,z for moveto / findpos)
  findmove                   pin the move/jump config (dest-field offsets + sendactmsg_rva via the
                             actmover vtable + actmover_off + jump_msg); re-run after a game patch. saves flyff.cfg

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
  findcam                    locate the render camera (CWorld::m_pCamera); lets tdbg draw the cull cone / blind spot
  attr [x,z]                 terrain attribute at your feet (or a world point): NONE/NOWALK/NOMOVE/DIE
  attrmap [radius] [step]    ASCII map of terrain attributes around you (reveals invisible walls)
  objects [radius]           list nearby CObj of any type + locate m_OBB (props the grid misses)
  collscan [radius]          per nearby prop: model .o3d filename + collision-mesh type (NORMAL vs ERROR)
  collwatch [secs] [radius] [all]  catch a TRANSIENT collider (respawn VFX): polls + logs each SOLID
                             box the instant it appears (mobs/items hidden unless 'all'). [COLLIDER] = culprit
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
  inv                        report inventory fill (used/free/capacity, FULL); needs 'findinv'`
