# Plan: Tell the server about our target (PACKETTYPE_SETTARGET) via the client's own code

## STATUS (2026-07-04) - SendSetTarget FOUND via in-process disasm

The SoM client renumbered the packet and CRC32-checksums the wire, so codescan-for-0x00ff0023 and
memory packet-scans (findpacket/packetwatch) all failed. Cracked it instead by **static disasm inside
memscan** (new `disasm` / `func` / `codescan xref` / `+rva` tools; NO Cheat Engine/debugger - the
client detects those, see [[no-cheatengine-no-debuggers]]):
- `codescan xref 0x5888DC` (world global) -> a select handler that calls `world->SetObjFocus(pObj,1)`.
- **`CWorld::SetObjFocus` = RVA `0x432090`.** On focus->mover it runs `push 2; push [pObj+0x2F0];
  call 0xF50AA0`.
- **`SendSetTarget` = RVA `0x190AA0`** - a free `__stdcall(idTarget, bClear)` (`ret 8`): builds packet
  **type `0x78`**, CRC32s it (table at abs `0x13361D0`), sends via g_DPlay (`0x1343A50`) internally.
  So NO g_DPlay/objid/thiscall needed by us - just call `0xF50AA0(id, 2)`.
- **idTarget = `[pObj + 0x2F0]`** (the network mover-id, e.g. 1574749) - NOT the `0x22F8` GetId.

Wired + saved to flyff.cfg: `sendsettarget_rva=0x190AA0`, `objid_off=0x2F0` (gdplay unused).
`notify_server_target` now calls `remote_thiscall32(fn=base+0x190AA0, this=0, [id,2])`.

**CONFIRMED WORKING (2026-07-04):** `srvtest` injected cleanly (client survived, thread returned);
then `srvsync on` + `auto` farming past the old ~5-min/N-kill point with **no DC** - "working
flawlessly" per the user. G1 north-star (programmatic targeting without the DC) achieved.
Follow-up (optional): reuse one VirtualAllocEx'd shim page instead of alloc/inject/free per kill, to
cut the per-advance CreateRemoteThread/RWX churn (AC surface). RVAs/offset are patch-specific;
re-find via the disasm tools after a patch.

## STATUS (2026-07-03)

Phase-1 scaffolding is **built and compiling** (memscan builds clean):
- `src/remotecall.odin` — `remote_thiscall32` (32-bit thiscall shim via VirtualAllocEx +
  CreateRemoteThread into the WOW64 target) and `notify_server_target`.
- `src/core.odin` — sentinel constants `FLYFF_SENDSETTARGET_RVA` / `FLYFF_GDPLAY_RVA` /
  `FLYFF_OBJID_OFF` (all `0` = not found yet), plus recon helpers `codescan_u32` /
  `codescan_calls`.
- `src/cli.odin` — commands `codescan`, `idscan`, `srvsync [on|off]`, `srvtest`; `srvsync_on`
  gate wired into `tc_select` after the focus write. `srvsync`/`srvtest` refuse to run while the
  constants are `0`.

**Layout is now RUNTIME (2026-07-03):** all offsets/RVAs live in `Session.layout` (flyff.cfg),
re-derived by `calibrate` — no rebuild on a patch. The packet-layer fields `objid_off` /
`sendsettarget_rva` / `gdplay_rva` are layout fields too; set them with `set <field> <value>`
(auto-saves) instead of editing constants. See the calibrate workflow note in project memory.

**Prerequisite (the game was PATCHED):** first re-derive the core offsets —
`attach Neuz`, then `calibrate <x,y,z> <name> [hp]` (x,y,z from /position). Confirm with
`mobs <mob>`.

**Then Phase 0 recon (needs the live game):** `codescan 0xff0023` → find SendSetTarget entry;
`codescan call <entry>` → read `mov ecx, imm32` = &g_DPlay; `idscan <mob>` → m_objid offset.
`set sendsettarget_rva/gdplay_rva/objid_off ...`, then `srvtest` / `srvsync on` to verify the DC
stops (Phase-1 go/no-go).

## Context

memscan can already select a combat target locally (write `m_pObjFocus`) and F2 attacks it.
The remaining wall is **server-side**: after killing enough mobs, the client gets **disconnected**.

Root cause is now confirmed from the base-fork source (`F:\FORMAT-2026\Flyff\Meruem Flyff\Source\`):

- Clicking a mob runs `CWorld::SetObjFocus(pObj, bSend=TRUE)` (`_Common/World.cpp:253`), which calls
  **`g_DPlay.SendSetTarget(idTarget, 2)`** (`World.cpp:331`) - a real client->server packet
  **`PACKETTYPE_SETTARGET = 0x00ff0023`** (`_Network/MsgHdr.h:1459`), payload `ar << idTarget << bClear`
  (4-byte OBJID + 1-byte flag; `Neuz/DPClient.cpp:10918`).
- The server handler `CDPSrvr::OnSetTarget` (`WORLDSERVER/DPSrvr.cpp:5246`) on `bClear==2` simply does
  `pUser->m_idSetTarget = idTarget;` (`DPSrvr.cpp:5257`, field `User.h:112` "this user's held target").
- **memscan writes `m_pObjFocus` directly, so `SendSetTarget` never fires** -> the server's `m_idSetTarget`
  is never updated -> killing targets the server never registered trips a sanity check -> DC.

The wire is classic Flyff plaintext framing - `'^' (0x5E)` header mark + size + the `CAr` payload
(`_Network/Net2/include/buffer.h:13`, `dpmng.h`) - with **no encryption layer and no per-packet serial**
visible in Net2. (Must still be re-verified against the *modded* `Neuz.exe`, which may differ.)

**Decision (user):** don't reverse/forge packets externally. Instead make the **client send the packet
itself** by calling its own `SendSetTarget` from a remote thread (no DLL). Game does all
framing/encryption/sequencing for free -> immune to whatever the modded fork changed, byte-identical to a
real click. **Start with a minimal proof-of-concept** that confirms one SETTARGET packet stops the DC
before building it into the farm loop.

## Approach: Path 3 - invoke the client's own `SendSetTarget` via `CreateRemoteThread`

Additive and low-risk: keep the existing local focus write exactly as-is (proven; F2 still attacks
instantly). **Add** a server notification - when we select a mob, also call the game's own
`SendSetTarget(idTarget, 2)` so `pUser->m_idSetTarget` matches what we attack.

`SendSetTarget` only touches the network layer (no world/UI mutation) -> safest function to call from a
foreign thread. (Fallback if we'd rather not pass an OBJID: call `SetObjFocus(world, obj, TRUE)` instead,
which needs only the `CWorld*`+`CObj*` we already have and does focus+send together - but it mutates
world/UI state, so reentrancy risk is higher and we must NOT pre-write focus or the `pObj != m_pObjFocus`
guard skips the send.)

### Phase 0 - runtime recon (find 2 addresses + 1 offset in the live modded `Neuz.exe`)

Use memscan's own read commands; all are base-relative (resolve base at runtime, per existing code).

1. **`SendSetTarget` address** - scan the module's executable region for the immediate **`0x00ff0023`**
   (very distinctive; `BEFORESENDSOLE` emits it). The enclosing function is `SendSetTarget`. Add a
   read-only `codescan <u32>` helper (mirror `scan u32` but over the image's `.text`/exec pages from
   `collect_regions`) if needed.
2. **`&g_DPlay` address** - the `this` for the thiscall. `g_DPlay` is a global `CDPClient` instance
   (`Neuz/Network.cpp:10`). Find it from the `mov ecx, <imm32>` that precedes calls to `SendSetTarget`
   (callers load `ecx`=`&g_DPlay`), or from another known `g_DPlay.SendXxx` callsite. Treat as a stable
   `Neuz.exe+RVA` (verify across a restart, like the existing focus/player RVAs).
3. **`m_objid` offset** - `OBJID GetId(){ return m_objid; }` (`_Common/Ctrl.h:58`). Confirm the live
   offset by reading a known mob (cross-check that `prj.GetMover(id)`-style id is unique per mob; correlate
   against the already-known fields near `+0x174 m_dwIndex`). Bake as `FLYFF_OBJID_OFF` once found.

Record all three in `src/core.odin` alongside `FLYFF_WORLD_RVA` etc. and in project memory
([[flyff-target-data-model]]).

### Phase 1 - PoC: one remote `SendSetTarget` call, gated behind a toggle

New file **`src/remotecall.odin`**:
- `remote_thiscall(handle, fn_addr, this_ptr, args: []u32) -> bool`:
  `VirtualAllocEx(RWX)` a tiny x86 thiscall stub, `WriteProcessMemory` it, `CreateRemoteThread` on it,
  `WaitForSingleObject`, then free. Stub shape (finalize encoding in impl):
  ```
  mov ecx, <this>        ; B9 imm32        (=&g_DPlay)
  push <bClear=2>        ; 6A 02
  push <idTarget>        ; 68 imm32
  mov eax, <SendSetTarget>; B8 imm32
  call eax               ; FF D0           (thiscall: callee cleans its 2 args)
  ret 4                  ; C2 04 00        (clean the thread-proc lpParameter)
  ```
- `notify_server_target(session, obj_ptr) -> bool`: read `idTarget = [obj_ptr + FLYFF_OBJID_OFF]`, resolve
  `&g_DPlay` and `SendSetTarget` (base+RVA), call `remote_thiscall`.

Wire-in (mirror the existing `refocus` experiment toggle, `cli.odin:1402-1458`):
- `Session.srvsync_on: bool` (cleared on detach/close).
- CLI command `srvsync [on|off]` toggling it.
- In `tc_select` right after the focus write (`cli.odin:~1229`) and in `auto` advances, if `srvsync_on`,
  call `notify_server_target(session, chosen.obj)`.

**Verify the theory (the whole point of the PoC):** build; `attach Neuz`; `srvsync on`; `auto Augu` and
hold F2 to farm normally. Previously the DC came after N kills (~5 min). With `srvsync on`, confirm the
session **survives well past that** (farm 15-20+ min / 2-3x the old kill count). Watch for any new
instability from the remote thread (see Risks). If it still DCs at the same rate -> the missing-select
theory was wrong (it's the 5% case: raw-write detection or attack-side validation) and we stop before
building more; re-open the `refocus`/range-cap diagnostics from the earlier analysis.

### Phase 2 - productionize (only if Phase 1 confirms)

- Make it default-on (drop the toggle, or keep an off-switch) once stable.
- **Clear-on-switch:** the game's own death-clear `SetObjFocus(NULL)` already sends `SendSetTarget(old,1)`
  (default `bSend=TRUE`, `World.h:360`) when the player kills via F2 - verify the server stays in sync
  across auto-advances; if our memory-write path ever leaves a stale `m_idSetTarget`, also emit
  `SendSetTarget(old, 1)` before selecting the new one (matches `World.cpp:314-316`).
- **Robustness of the remote call:** reuse one VirtualAllocEx'd stub (patch the two imm32s per call)
  instead of alloc/free each time; bound `CreateRemoteThread` failures gracefully (don't crash the REPL).

## Critical files

- New: `src/remotecall.odin` (remote thiscall + `notify_server_target`).
- `src/core.odin` - add `FLYFF_OBJID_OFF`, `FLYFF_SENDSETTARGET_RVA`, `FLYFF_GDPLAY_RVA`; optional
  `codescan`/exec-region scan helper.
- `src/cli.odin` - `srvsync` command + `Session.srvsync_on`; call site in `tc_select` (~1229) and the
  `auto_tick` advance (~1314). Reuse the `refocus` toggle pattern (1402-1458).
- `src/main.odin` - `Session` field + reset on `session_close`/detach.

## Risks / caveats

- **Thread-safety:** `CreateRemoteThread` runs concurrently with the game's main thread. `SendSetTarget`
  only writes the net send buffer (low blast radius), but a shared-buffer race is possible. Selection is
  infrequent (once per target switch) so collision odds are low; if it destabilizes, escalate to
  **main-thread hijack** (Suspend/GetThreadContext -> point EIP at the stub -> restore) to run the call
  inline on the game thread. Avoid the heavier `SetObjFocus` call from a foreign thread for this reason.
- **AC footprint:** `VirtualAllocEx`/`CreateRemoteThread` are themselves detectable by a process-watching
  anti-cheat. A modded private-server AC is usually server-side behavioral, but if a client AC flags
  thread creation, switch to the thread-hijack variant (no new thread, no RWX page if we reuse existing
  code-cave space).
- **Modded-fork drift:** offsets/RVAs are for the no-source modded build - all found at runtime; never
  bake absolute bases (resolve `proc_info.base` + RVA, as the code already does).
- **Theory is ~95%, not 100%:** Phase 1 is explicitly the cheap go/no-go test before further investment.

## Alternative considered (rejected for now)

**Path 2 - external MITM forgery** (WinDivert/relay splicing a crafted `'^'+size+dpid+0x00ff0023+id+2`
packet). Same end result, but ~1-2+ weeks, must first verify the modded wire isn't encrypted/serialized
(if it is, must read the key from client memory and/or rewrite the stream's serials), and anomalous
packets are exactly what server AC watches. Strictly more work and more fragile than letting the client
emit the packet itself. Keep as the pure-external fallback only if in-process code execution must be
eliminated entirely.
