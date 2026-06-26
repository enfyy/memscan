### Memscan

A small Cheat-Engine-style memory scanner for Windows, written in Odin. Attaches to a
running process and lets you scan, refine, read and write its memory from an interactive
CLI. Built to tinker with an old DirectX-9 game (see the project goal below).

## Requirements

- [Odin](https://odin-lang.org/docs/install) (no other dependencies)

## Build

On Windows:
```
build.bat debug      # or: build.bat release
```
Produces `.out/debug/memscan.exe`. (Or directly: `odin build src -out:.out/memscan.exe -debug`.)

## Usage

`memscan` is an interactive REPL. It also reads commands from stdin, so sessions can be
scripted (`memscan.exe < script.txt`).

```
attach <name|pid>          open a process for read/write
info                       show attached process details
vtype <t>                  default value type: u8 i8 u16 i16 u32 i32 u64 i64 f32 f64
scan [t] <value>           exact-value scan
snapshot [t]               capture memory for an unknown-initial search
next <op> [value]          refine; op = eq ne gt lt changed unchanged inc dec
list [n] / count           inspect the current match set
peek [i] / poke [i] <v>    read / write match #i live
read <addr> [t]            read at an absolute address
write <addr> <v> [t]       write at an absolute address
deref <addr> [off ...]     follow a pointer chain
ptrsize <4|8>              pointer width used by deref
```

Typical "find an unknown value" loop: `snapshot` → change the value in the target →
`next changed` → repeat until the match set collapses to the address you want.

## Project goal

Locate the game's **currently-selected combat target** in memory and set it
programmatically (then enumerate nearby entities). See the plan/notes for details.

## ToDos

- Stable pointer paths (static base + offsets) so addresses survive restarts
- Pointer scanning
- Byte-pattern / string scanning in the refine engine
- Incremental scans & undo / browse previous scans
- Explicit 32-bit target ergonomics
