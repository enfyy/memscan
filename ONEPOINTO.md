# Version 1.0

This lists the changes needed from "0.2.2" -> 1.0.0

flyff module gets fully seperated out from the core engine:
flyff module has a ui and is fully controlled by the ui. 
engine still has a REPL and opens the flyff ui with command "module flyff'
The ui has everything needed for controlling everything. 

- The ui will be based on the current radar.

- it has a side panel overlay with a traditional ui menu probably using raygui.
    the menu lets you do the things that the commands did thus far (by calling them internally):
    - setup [status indicator light with hover tooltip explaining whats missing]
    - auto on/off [Select monsters from static list, and add as many as you want]
    - When auto is on: All the stats are displayed.
    - configure: attack_range slider
    - the current radar/geofence ui becomes less hotkey heavy and more toolbar button reliant


[DONE]- its possible to move when clicking the radar -> the game issues a move command.

[PARTIAL]- its possible to jump -> we get the player position height. and the player dot enlarges simulating a jump. and we send the Spacebar command to the game.

[PARTIAL]- You can even target monsters by clicking on them.
We make a literal mini Idle game out of it. We also display penya drop effects when killing a monster, imagine league of legends minion money gain sfx.

[MISSING/BUGGED]- We add the density feature.

[DONE]- We add the one-shot-mode feautre (pretarget).

[MISSING/UI]- We add the look-alive feature set.

[MISSING]- We optionally display the terrain as a coloured heightmap background

---

Phase 6: Making it good
Ok scratch the heightmap background for now that will be the very last thing we do. Focus is on polish and bug fixes.
We kind of sprinted through phases 1-5 and left most tweaking for later which is now.
This is the list of all the things that have to be adjusted still.

[DONE]- The jumping thing only made it in as a command
    -> Add the visual in the radar (0.6s dot-hop + ground shadow; fires on manual AND look-alive jumps)
    -> Add the button/hotkey for the radar (Space hotkey + "Jump (Space)" panel button)

- For the ui:
    [DONE]- Set up needs a loading indicator (async setup + live step N/8 counter in the panel)
    [DONE]- Set up needs to be able to do penya find individually ("Find penya only" button in the dialog)
    [DONE]- Stats need to be larger, distance can be dropped (17px, dist_3d dropped from the panel; CLI keeps it)
    [DONE]- Slider/toggle for density (MODES row toggle + mingain/detour in the Options modal)
    [DONE]- Toggle for pre-select (MODES row; persisted to flyff.cfg now)
    [DONE]- Ui for look alive mode (MODES row toggle; persisted)
    [DONE]- Remove the radar text and replace it with something nicer (see legend item below)
    [DONE]- Add total penya display (Session.penya_total; accrues even with the radar closed; panel line under PLAY)
    [DONE]- attack range slider needs to update the circle in real-time as well as the range needs to be read not only on startup (stale layout-snapshot bug fixed)
    [DONE]- Filter needs to be labeled better ("farm targets (empty = any monster)")

- Density feature sucks ass still
  [DEFERRED - live-test the cluster-commitment rework first, then revisit with tdbg reversals data]
    -> Ping-ponging bug is still alive we need to prefer not turning around too often maybe (its also unnatural af for human gameplay)
    -> only consider density if the last mob we kill
    has really low score in comparison to something else that is not too far away 
    -> If we have a monster targeted that has is part of a large cluster we need to absolutely stick with it until the cluster is wiped out fully
    -> weight config is un-intuitive af (what does the number mean)
    [DONE 2026-07-18]-> in-range mobs ALWAYS win now: the pocket stage was hoisted above cluster
    commitment, so the anchor only leaves attack_range when nothing eligible is inside it

[DONE]- Dont only consider reachability on targeting, sometimes we target then it immediately goes unreachable after and we still go after it and get stuck
    -> Watch reachability while targeted (0.5s probes + 1s debounce -> "unreachable - skipping")

[DONE]- Fence ui should be not in the sidebar but a floating toolbar over the map, visible in edit mode
  (shape tools + tag/on/clear/undo; sidebar keeps only Edit/Camera/Reach/Recenter)

[DONE]- We add a subtle sound effect for the penya gain thing (synthesized coin chime, no asset files)
  and we add a subtle laser beam effect or something on kill (magenta beam, ~0.4s, player->kill spot)
    -> make them both toggle-able (`sfx`/`fxlaser` toggles + Options buttons; Sound and Laser FX are separate)

[DONE]- Add a 'legend' in top right that is tooltip only as replacement for radar text ("?" badge)

[DONE]- Change the hover effect for targets in the radar to be colored differently than selection (cyan-blue ring vs yellow selection)

[DONE]- F10 should stop/start instead of pause (full toggle; re-arms the last target spec)

[DONE]- The name of the selected/hovered entity should be displayed in the radar somehwere (drawn beside each ring)

[DONE]- A option dialog panel that lets you set all the config values (including attack range)
  (tunables + toggles; raw RVAs/offsets stay CLI-only on purpose)

[DONE]- fix noticeable stutter on kill for the radar (candidate scan moved off the lock onto a worker)

See BACKLOG.md "Phase 6 Batches 3+4 action plan" for the full spec of the remaining items
+ the live verification checklist for everything shipped 2026-07-18.