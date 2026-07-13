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


- its possible to move when clicking the radar -> the game issues a move command.

- its possible to jump -> we get the player position height. and the player dot enlarges simulating a jump. and we send the Spacebar command to the game.

- You can even target monsters by clicking on them.
We make a literal mini Idle game out of it. We also display penya drop effects when killing a monster, imagine league of legends minion money gain sfx.

- We add the density feature.

- We add the one-shot-mode feautre (pretarget).

- We add the look-alive feature set.

- We optionally display the terrain as a coloured heightmap background

---

That's the full scope.
anything else is out of scope.

# 2.0 (not happening unless i change my mind)

-> we port the ui to my game engine and make a tiny adorable 3d game out of it.