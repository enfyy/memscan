# memscan

A small cross-process memory scanner for Windows, written in [Odin], with automation for the
game Flyff (`Neuz.exe`) layered on top. Attach to a running process and scan, refine,
read and write its memory from an interactive REPL. On Flyff it can find and set the selected
combat target, enumerate nearby mobs, and hands-free farm.

Do not ask for a binary. if you cant figure out how to build it by yourself by reading this document, then tough luck.

## Requirements

- [Odin] (no other dependencies)

raylib comes from Odin's own `vendor:raylib`; Dear ImGui is vendored in `lib/odin-imgui` with a
prebuilt static lib and a raylib backend in `lib/imgui_impl_raylib`. Both link statically, and the two
UI fonts are embedded in the exe - there is nothing to install and no dll to ship.

## Build

On Windows:

```
build.bat debug      # -> .out/debug/memscan-<version>-debug.exe
build.bat release    # -> .out/release/memscan-<version>-release.exe
```

The exe is named after what it is - `memscan-<version>-<mode>[-<module>][-tracy].exe`, e.g.
`memscan-1.4.0-release-flyff.exe`. The version comes straight from `src/version.odin`, so the
filename always matches what the `version` command prints, and the variants never overwrite (or
lock) each other.

Or invoke the compiler directly:

```
odin build src -out:.out/memscan.exe -ignore-unknown-attributes -vet-shadowing -error-pos-style:unix -debug
```

### Main-module builds (UI on start, no REPL)

Naming a module as an extra build argument hands it the process at startup: it opens its own UI
immediately and the exe quits when that window closes, so the REPL is never launched.

```
build.bat release flyff    # -> .out/release/memscan-1.4.0-release-flyff.exe
odin build src ... -define:MAIN_MODULE=flyff
```

Leave the argument off for the normal REPL build - that is the fallback whenever the define is
missing. An unknown module name fails the build rather than silently reverting to the REPL.
Everything the window can't do is still CLI-only, so keep a REPL build around for setup and recon.
`tracy` and a module name can be given together, in any order.

**Console.** `release` + a module is the one build with no console window: it is the exe you ship, the
UI opens at startup and there is no REPL to type into, so the console was only ever carrying the log
(`-subsystem:windows`). The trade is that the log then has nowhere to go - every `fmt.print` writes to
a dead handle and is discarded, which is harmless but silent. The other three builds keep their
console: the debug ones because the log is the point, and the release REPL because it *is* the REPL.

## Run

`memscan` is an interactive REPL. It also reads commands from stdin, so a whole session can be
scripted:

```
memscan-1.4.0-release.exe             # interactive
memscan-1.4.0-release.exe < script    # scripted
```

Type `help` for the command list and `quit` to exit. Chain commands on one line with `;` or `&&`.

- **Find an unknown value:** `snapshot` -> change the value in the target -> `next changed`, and
  repeat until the match set collapses to the address you want.
- **Flyff farming:** `attach Neuz`, then `calibrate <x,y,z> <name>` once (offsets persist in
  `flyff.cfg` next to the exe), then `auto` and hold your attack key. `status` health-checks the setup.

## The window

`radar` opens the UI (Dear ImGui over a raylib-drawn map). It does **not** need an attached process:
with none it opens on the Attach dialog, which searches for `neuz` by default - clear the box to list
everything, then click a tile to attach.

That dialog also has a **Work offline** button, and behind it is the whole chart surface with no game
running: the behaviour browser, the node editor, the linter, save/load. Browsing and authoring a
chart is document work and never needed the client. What offline does not get you is a *run* - the
editor's play button turns amber and its tooltip names the first block that is waiting on a process.
Every block is placeable offline; the only ones that are not are the ones with no code behind them
yet, which `script blocks` marks `[xx]` (as opposed to `[--]`, "built, but not usable right now").
The **Attach** button in the top-left corner takes you back to the process list.

Once attached the map fills the window and the chrome floats over it:

- **top-left toolbar** - a setup traffic light (green = every pin resolved, yellow = only optional
  ones missing, red = a required one missing) that opens the Setup dialog; the behaviour browser
  (highlighted while a chart is running); the zone editor toggle (`E`); camera follow (`L`, on by
  default); the no-walk overlay (`N`); mute.
- **behaviour browser** - every chart in one grid: the ones written in Odin
  (`src/flyff/behaviours.odin`) and the ones saved as `behaviours/*.bhv` files. Left-click runs one,
  right-click gives Duplicate / Rename / Delete. A saved chart wins over an Odin one of the same
  name, so duplicating a built-in is how you get an editable copy; delete it to get the original back.
- **transport strip** (top-centre, only while a chart is running) - play/pause, rewind, single-step,
  stop, plus the current step and the block executing right now. Pause freezes the whole machine,
  interrupts included; single-step keeps servicing them so a kill-switch can still break you out.
- **Setup dialog** - the pipeline (character name, HP, penya), an `attack_range` slider, and the pin
  checklist. `attack_range` lives here rather than in an options panel because it is your character's
  physical reach, i.e. calibration and not preference: it is both the picker's engage range and the
  sweep brush width, so the green circle on the map is the live readout while you drag it.
- **bottom-right** - a recenter puck, which only exists while the camera is free: turn following off,
  pan somewhere, and it appears to take you back (`C` does the same). Nothing to recenter, no button.
- **bottom-left gauges** - penya and bag slots, value printed inside the bar. The penya bar runs
  linearly over the full `0 .. max(i32)` range, because the only thing it can usefully warn you about
  is the cap (past it, farmed penya is lost) - a normal balance really is a sliver. Both flash when
  they matter: penya near the cap, bag when it is full.
- **map** - left-click a mob to target it, shift+left-click the ground to walk there, right-drag to
  pan, wheel to zoom. `N` paints the terrain you cannot walk through (orange = fly-only, red = wall,
  magenta = instant death) - the same attribute grid targeting uses to skip unreachable mobs, so it
  shows you the invisible walls before auto finds them the hard way. `H` adds shaded relief. Both
  need `worldscan` pinned.

Windows close with the X in their own titlebar - there are no in-body Close buttons, and `ESC` is not
a close key anywhere (it used to quit the whole window out from under you).

Every widget runs the same commands you would type, so nothing in the UI is a private code path.
`set ui_scale <n>` scales the whole thing (re-open the window to apply).

Auto-farm, the targeting options and leaderboards are CLI-only right now - they were deliberately left
out of the redesigned shell and return as the behaviour surface grows.

## Commands

Output of `help`:

```
memscan - cross-process memory scanner with Flyff (Neuz.exe) automation on top.
(aliases in parens; run any command with wrong args to see its usage)

============================ GENERAL (any process) ============================

process & session
  ps [filter]                list processes (optionally filter by name)
  attach <name|pid>          open a process for read/write
  detach                     close the attached process
  info                       show attached process details
  vtype <t>          (type)  default value type: u8 i8 u16 i16 u32 i32 u64 i64 f32 f64
  ptrsize <4|8>              pointer width for deref (auto-set on attach)

scan for a value
  scan [t] <value>     (s)   exact-value scan (starts/replaces the match set)
  snapshot [t]      (snap)   capture memory for an unknown-value search
  next <op> [value]    (n)   refine matches: eq ne gt lt changed unchanged inc dec
  list [n]            (ls)   show first n matches (default 20)
  count                      how many matches
  pointers           (ptr)   keep only matches that are valid heap pointers
  clearmatches        (cm)   drop matches, keep the snapshot
  reset                      clear all scan state

read / write / inspect
  read  <addr> [t]     (r)   read a value at an address
  write <addr> <val> [t] (w) write a value at an address
  peek  [i]                  read match #i live (default 0)
  poke  [i] <value>          write to match #i (default 0)
  deref <addr> [off ...] (d) follow a pointer chain to the final address+value
  dump  <addr|[i]> [len] (x) hex dump (default 128 bytes) with an f32 column
  find  <text>               search memory for a string (ASCII + UTF-16)
  dist  <a> <b>              distance between two vec3 (3x f32) positions
  nearest <mode> ...  (near) enumerate entities by distance to player;
                             modes: list | array | matches (run for the exact args)
  target <focus|[i]> <rank>  write nearest[rank]'s pointer into a focus address

disassembly / code recon
  disasm <addr> [count] (u)  disassemble count instructions (default 24)
  func <addr>                disassemble the whole enclosing function
  codescan <u32>             find a 4-byte immediate in executable pages
  codescan call <addr>       find direct CALL sites targeting <addr>
  codescan xref <rva>        find code referencing a base-relative global

automation
  hotkey <command>    (hk)   bind a key (when prompted) to run <command>, even backgrounded;
                             also: hotkey list | hotkey clear

====== FLYFF (Neuz.exe - offsets live in flyff.cfg, read at startup + fresh on every attach) ======
typical use: attach Neuz -> auto -> hold your attack key.   after a patch: select a mob, calibrate.
check the setup anytime with 'status'.

farming (day to day)
  target_closest <name>... (tc)  select nearest mover named <name>; repeat to advance.
                             several names ok: tc 'Aibatt', 'Captain Aibatt'
  auto [name]...             hands-free farm: re-target the next mob on each kill (hold your attack key).
                             no name = ANY monster; names comma-separated. re-issue / 'auto off' to stop
  timer <minutes>            auto-disable 'auto' after N minutes (e.g. 'timer 60'); 'timer off' cancels
  kills <n>                  auto-disable 'auto' after N confirmed kills (e.g. 'kills 100'); 'kills off' cancels
  stuck [on|off]             toggle obstacle skip-detection (on by default; 'stuck off' for ranged/standing)
  mobs <name>                list nearby <name> movers by distance (hp, model, address)
  srvsync [on|off]           mirror each select to the server (stops the after-N-kills DC);
                             ON by default on attach
  srvtest                    fire one server SendSetTarget at the current target

setup & health (run once after a game patch)
  status              (doctor)  health-check: what's configured, what's missing, and how to fix it
  calibrate <x,y,z> <name> [hp]  (cal) re-derive the whole layout from /position + your
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
  findprop                   a few distinct monsters on screen (no target needed), run: derives the
                             any-monster gate (species MoverProp array -> GetProp()->dwAI==AII_MONSTER).
                             one-time; skips pets/eggs/NPCs/players/bosses. re-run after a game patch.

terrain / obstacle recon (spike)
  worldscan [reset]          pin the terrain-grid offsets from your ground height (stand on solid
                             ground; if ambiguous, walk to a different-height spot and re-run)
  attr [x,z]                 terrain attribute at your feet (or a world point): NONE/NOWALK/NOMOVE/DIE
  reach [x,z]                is the straight path player->point (or ->selected target) walkable?

deep recon (rarely needed)
  findpos <x,y,z> [eps]      addresses whose 3 f32 match a position
  findhp <name>              guess hp_off statistically (prefer hpwatch)
  idscan <name>              find m_objid across <name> movers
  findpacket [objid]         scan for the outgoing SETTARGET packet id
  packetwatch                snapshot, click a mob, catch the fresh SETTARGET packet
  deathscan <name>           find a corpse despawn-countdown field
  objscan <value> <name>     find offsets holding <value> across <name> movers
  refocus                    detection test: rewrite focus to itself every ~200ms

============================================================================
  help (?)   this list         quit (q)   exit
```

[Odin]: https://odin-lang.org/docs/install
