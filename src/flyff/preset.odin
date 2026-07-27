package flyff

import "core:fmt"
import "core:strings"

// Playstyle presets: one command that sets a whole coherent group of behavior settings, so a new farm
// spot doesn't mean remembering which six toggles to flip. A preset is nothing but a named list of
// (setting, value) pairs applied through the same session fields + cfg mirrors the individual commands
// write, then saved - there is no separate "preset mode" state, and nothing here is authoritative after
// the fact. Change any setting afterwards and you simply no longer match that preset.
//
// HARD RULE: presets touch BEHAVIOR only, never a memory offset/RVA. Offsets are per-game-build and come
// from `setup`; writing them from a canned table would drive memory writes at wrong addresses. Same
// default-deny discipline as the leaderboard's shareable-config filter (LB_SHAREABLE_KEYS).

// One preset's settings. Every field is applied on `preset <name>`; the set is deliberately explicit
// (no "leave as-is" holes) so applying a preset always lands you in a fully known state.
Preset :: struct {
  name:         string,
  blurb:        string, // one line, shown by `preset` and as the Options dropdown's help
  aggro_first:  bool,
  melee_first:  bool,
  melee_range:  f32,
  pocket:       bool,
  density:      bool,
  stuck:        bool,
  combat_watch: bool,
  combat_grace: f32,
  preselect:    bool,
  lookalive:    bool,
  hunt:         bool,
}

// The built-in presets. Ordered most-common-first; the radar dropdown renders them in this order.
PRESETS := [?]Preset {
  {
    name = "tower",
    blurb = "dense grind: fast kills, stay on the pack, never walk away from a mob in range",
    aggro_first = true, melee_first = true, melee_range = 3.0, pocket = true,
    density = false, stuck = true, combat_watch = true, combat_grace = 3.0,
    preselect = true, lookalive = false, hunt = false,
  },
  {
    name = "tanky",
    blurb = "high-HP mobs: long fights never get mistaken for being stuck",
    aggro_first = true, melee_first = true, melee_range = 3.0, pocket = true,
    density = false, stuck = true, combat_watch = true, combat_grace = 6.0,
    preselect = true, lookalive = false, hunt = false,
  },
  {
    name = "ranged",
    blurb = "stand and shoot: no stuck-skips from standing still, in-range mobs first",
    aggro_first = true, melee_first = true, melee_range = 3.0, pocket = true,
    density = false, stuck = false, combat_watch = true, combat_grace = 4.0,
    preselect = true, lookalive = false, hunt = false,
  },
  {
    name = "quest",
    blurb = "low-spawn quest mobs: human-like pacing, deliberately less efficient",
    aggro_first = true, melee_first = true, melee_range = 3.0, pocket = true,
    density = false, stuck = true, combat_watch = true, combat_grace = 4.0,
    preselect = false, lookalive = true, hunt = false,
  },
  {
    name = "boss",
    blurb = "one big target: commit to it, never drop it, never get distracted",
    aggro_first = true, melee_first = false, melee_range = 3.0, pocket = false,
    density = false, stuck = true, combat_watch = true, combat_grace = 8.0,
    preselect = false, lookalive = false, hunt = true,
  },
}

// Apply <p> to the live session + its cfg mirrors. Mirrors exactly what the individual CLI toggles do
// (session field authoritative, layout copy for the flyff.cfg round-trip), so a preset and hand-flipping
// the same switches leave identical state. Saving is the caller's job (cli_preset does it attach-gated).
preset_apply :: proc(session: ^Session, p: Preset) {
  session.aggro_first_on = p.aggro_first
  session.melee_first_on = p.melee_first
  session.pocket_on = p.pocket
  session.auto_stuck_on = p.stuck
  session.combat_watch_on = p.combat_watch
  session.preselect_on = p.preselect
  session.lookalive_on = p.lookalive
  session.hunt_on = p.hunt

  session.layout.aggro_first_on = p.aggro_first
  session.layout.melee_first_on = p.melee_first
  session.layout.melee_range = p.melee_range
  session.layout.pocket_on = p.pocket
  session.layout.auto_stuck_on = p.stuck
  session.layout.combat_watch_on = p.combat_watch
  session.layout.combat_grace = p.combat_grace
  session.layout.preselect_on = p.preselect
  session.layout.lookalive_on = p.lookalive
  session.layout.hunt_on = p.hunt

  if session.layout.density_on != p.density {
    session.layout.density_on = p.density
    session.cluster_committed = false // density changed - drop any commitment, like cli_density does
    session.cluster_origin_pos = {}
  }
}

// Does the live config match <p> exactly? Used to mark the active preset in listings, so the UI can say
// "you are on tower" instead of leaving you to compare ten switches by eye. Float compares are exact on
// purpose: these values are only ever written from the preset table or typed in whole, and a near-match
// is still not the preset.
preset_matches :: proc(session: ^Session, p: Preset) -> bool {
  return(
    session.aggro_first_on == p.aggro_first &&
    session.melee_first_on == p.melee_first &&
    session.pocket_on == p.pocket &&
    session.auto_stuck_on == p.stuck &&
    session.combat_watch_on == p.combat_watch &&
    session.preselect_on == p.preselect &&
    session.lookalive_on == p.lookalive &&
    session.hunt_on == p.hunt &&
    session.layout.density_on == p.density &&
    session.layout.melee_range == p.melee_range &&
    session.layout.combat_grace == p.combat_grace \
  )
}

// Index of the preset the live config matches, or -1 for "custom".
preset_current :: proc(session: ^Session) -> int {
  for p, i in PRESETS {
    if preset_matches(session, p) {
      return i
    }
  }
  return -1
}

// preset          -> list the presets, marking the one the current settings match
// preset <name>   -> apply it (and persist)
cli_preset :: proc(session: ^Session, args: []string) {
  if len(args) == 0 {
    cur := preset_current(session)
    fmt.println("playstyle presets - 'preset <name>' applies one; every setting stays editable after:")
    for p, i in PRESETS {
      fmt.printfln("  %s %-8s %s", i == cur ? "*" : " ", p.name, p.blurb)
    }
    if cur < 0 {
      fmt.println("  (current settings: custom - they don't match any preset)")
    } else {
      fmt.printfln("  * = your current settings match '%s'.", PRESETS[cur].name)
    }
    fmt.println("see the resulting target order with 'priority'.")
    return
  }
  want := strings.to_lower(args[0])
  for p in PRESETS {
    if p.name != want {
      continue
    }
    preset_apply(session, p)
    if session.attached {
      flyff_save_cfg(session.layout, flyff_cfg_path()) // attach-gated (see cli_preselect note)
    }
    fmt.printfln("preset '%s' applied - %s", p.name, p.blurb)
    fmt.printfln(
      "  priority: aggro %s, melee %s (%.1f), pocket %s, density %s",
      p.aggro_first ? "on" : "off", p.melee_first ? "on" : "off", p.melee_range,
      p.pocket ? "on" : "off", p.density ? "on" : "off",
    )
    fmt.printfln(
      "  safety:   stuck %s, combat-watch %s (%.1fs), reach-gate unchanged, hunt %s",
      p.stuck ? "on" : "off", p.combat_watch ? "on" : "off", p.combat_grace, p.hunt ? "ON" : "off",
    )
    fmt.printfln("  pacing:   preselect %s, look-alive %s", p.preselect ? "on" : "off", p.lookalive ? "ON" : "off")
    return
  }
  fmt.eprintf("unknown preset '%s'. available:", want)
  for p in PRESETS {
    fmt.eprintf(" %s", p.name)
  }
  fmt.eprintln("   (bare 'preset' describes each one)")
}
