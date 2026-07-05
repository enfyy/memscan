# memscan

A small cross-process memory scanner for Windows, written in [Odin], with automation for the
game Flyff (`Neuz.exe`) layered on top. Attach to a running process and scan, refine,
read and write its memory from an interactive REPL. On Flyff it can find and set the selected
combat target, enumerate nearby mobs, and hands-free farm.

Do not ask for a binary. if you cant figure out how to build it by yourself by reading this document, then tough luck.

## Requirements

- [Odin] (no other dependencies)

## Build

On Windows:

```
build.bat debug      # -> .out/debug/memscan.exe
build.bat release    # -> .out/release/memscan.exe
```

Or invoke the compiler directly:

```
odin build src -out:.out/memscan.exe -ignore-unknown-attributes -vet-shadowing -error-pos-style:unix -debug
```

## Run

`memscan` is an interactive REPL. It also reads commands from stdin, so a whole session can be
scripted:

```
memscan.exe             # interactive
memscan.exe < script    # scripted
```

Type `help` for the command list and `quit` to exit. Chain commands on one line with `;` or `&&`.

- **Find an unknown value:** `snapshot` -> change the value in the target -> `next changed`, and
  repeat until the match set collapses to the address you want.
- **Flyff farming:** `attach Neuz`, then `calibrate <x,y,z> <name>` once (offsets persist in
  `flyff.cfg` next to the exe), then `auto` and hold your attack key. `status` health-checks the setup.

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

============ FLYFF (Neuz.exe - offsets live in flyff.cfg, loaded on attach) ============
typical use: attach Neuz -> auto -> hold your attack key.   after a patch: select a mob, calibrate.
check the setup anytime with 'status'.

farming (day to day)
  target_closest <name>... (tc)  select nearest mover named <name>; repeat to advance.
                             several names ok: tc 'Aibatt', 'Captain Aibatt'
  auto [name]...             hands-free farm: re-target the next mob on each kill (hold your attack key).
                             no name = ANY monster; names comma-separated. re-issue / 'auto off' to stop
  timer <minutes>            auto-disable 'auto' after N minutes (e.g. 'timer 60'); 'timer off' cancels
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
  findowner <pet-name>       summon your pet, run: excludes YOUR pet from any-monster auto
  findmobflag <pet-name>     find the monster-category field so any-monster auto skips ALL
                             pets/players/NPCs (needs 2+ monster species on screen)

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
