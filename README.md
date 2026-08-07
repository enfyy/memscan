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
`memscan-2.0.0-beta-release-flyff.exe`. The version comes straight from `src/version.odin`, so the
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
build.bat release flyff    # -> .out/release/memscan-2.0.0-beta-release-flyff.exe
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
