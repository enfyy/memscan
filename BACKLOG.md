# Backlog

Planned-but-not-yet-built work. Newest/most-actionable first. Done work lives in git history
and the project memory STATUS notes, not here.

---

## Obstacle / block detection for auto-farm  (next up)

**Why:** `auto <name>` advances `m_pObjFocus` to the *straight-line nearest* matching mob, so it
will lock a mob on the far side of a wall / cliff / water. Under held-F2 the character jams into
the obstacle and the farm stalls. The game shows a system notice ("This action has been blocked by
an obstacle..") in that case. Goal: detect the current target is unreachable and **skip to another
mob** (memscan stays a target-picker; it does not move the character).

**Recon already done (shapes the approach):** read the base-fork C++ source at
`F:\FORMAT [2026]\Flyff\Meruem Flyff\Source\`.
- No readable "blocked" flag and no single hardcoded message string — the message is a
  text-resource lookup (`prj.GetText(TID_...)`) rendered to chat. (`MoverAttack.cpp`
  `GetHitType()`→`HITTYPE_FAIL`; `ActionMoverMsg.cpp`.)
- Chat = `CWndChat::m_wndText.m_string` (`CEditString : CString`); only freshness signal is MFC
  `CArray` growth (`m_adwLineOffset`, `g_WndMng.m_aChatColor`) — heavy/fragile to reverse.
- ⇒ **Behavioral stuck-detection is the committed mechanism**; message-detection is an optional
  live recon spike (Phase 2).

### Phase 1 — behavioral (ship this)
Reuses the existing `auto_tick` loop (watcher thread, ~20 ms, `exec_mutex`), `tc_select`, and the
`tc_recent` cooldown pattern.

1. **`Session` fields** (`src/main.odin`): `auto_focus_obj: uintptr`, `auto_best_dist: f32`,
   `auto_progress_at: i64`, `auto_blocked: [dynamic]TC_Recent`. Clear in `session_close` / on detach.
2. **Blocked blacklist** (`src/cli.odin`): `obj_blocked_recently` / `mark_blocked` mirroring
   `tc_seen_recently` / `tc_mark_recent` (~cli.odin:956–976) against `auto_blocked` with
   `BLOCKED_NS :: 20s`.
3. **Skip blocked when picking** (`tc_select`): in the candidate pick loop, also skip
   `obj_blocked_recently(...)` alongside `tc_seen_recently(...)`.
4. **Progress monitor** (`src/cli.odin`): restructure `auto_tick` so the `auto_last` throttle gates
   only the rescan; when a live target is focused, call a new `auto_monitor(session, focus, now)`
   every tick. Constants: `STUCK_NS :: 2.5s`, `ARRIVE_DIST :: 3.0`, `PROGRESS_EPS :: 0.5`.
   `auto_monitor` reads player pos (new `read_player_pos`: `[base+FLYFF_PLAYER_RVA]` → `+FLYFF_POS_OFF`)
   and target pos (`focus+FLYFF_POS_OFF`), computes `dist_3d`. If distance keeps dropping → progress
   (reset timer). If it plateaus while `d > ARRIVE_DIST` for `STUCK_NS` → `mark_blocked(focus)`,
   write focus=0, reset tracking, `auto_last=0` so the next tick re-acquires a reachable mob; print
   `[auto] '<name>' blocked (...) — skipping`. Reaching/attacking keeps `d <= ARRIVE_DIST` so combat
   is never flagged; a kill still clears focus → normal advance.

Reuses: `tc_recent` pattern, `tc_select`/`tc_collect_cands` + crash guards, `read_vec3`/`dist_3d`,
`read_focus_ptr`/`focus_obj_live`, `read_value`/`write_value`, watcher thread + `exec_mutex`.
`src/hotkey.odin` unchanged (`auto_tick` already wired).

**Verify:** build, `attach Neuz` → `auto Augu`, stand so nearest Augu is across a wall, hold F2 →
after ~2.5 s it prints "blocked — skipping" and picks a reachable Augu; blocked mob not re-picked
for ~20 s; no false trigger while running toward a reachable mob or standing in melee. Tune
`STUCK_NS`/`ARRIVE_DIST` live.

**Caveat:** behavioral is ideal for melee run-and-hit; it can false-positive for ranged standing
attacks — keep it tunable / disable-able.

### Phase 2 — obstacle-message detection (optional, live recon spike)
Only if behavioral misses close-range/thin-wall LoS blocks. Using memscan's own commands:
1. Trigger the message in-game; capture exact wording.
2. `find "<substring>"` → locate it (chat `CEditString` / text resource).
3. Isolate a per-message freshness counter: `snapshot u32` → cause one chat line → `next inc`,
   repeat until one counter remains (likely `m_adwLineOffset`/`m_aChatColor` size); `dump`/`read`
   to confirm.
4. In `auto_monitor`: when that counter ticks while a target is focused and the latest line matches
   the obstacle text/system color → `mark_blocked` + skip. Same reaction, faster + range-independent.

---

## Other deferred items

- **Instant enumeration via `CWorld::m_aobjCull` render-list** — read the game's render list instead
  of the ~0.5 s full-writable rescan; makes `auto` advances near-instant (kills the post-kill gap).
- **Geofence / max-range cap** — don't pull mobs beyond a radius / outside a defined farm area.

## Done (recent)

- **TOCTOU crash fix** — `tc_select` now re-checks `obj_is_selectable` immediately before the focus
  write, so a mob freed/reallocated between enumeration and the write (NULL `m_pModel`) is no longer
  selected. Root-caused from a CrashRpt SIGSEGV (Neuz.exe+0x3C5422) + `tc_targets.log` showing the
  last target's `m_pModel`=0.
- **Debug-only logging** — `log_target` (`tc_targets.log`) is gated behind `when ODIN_DEBUG`; release
  builds write no log.
