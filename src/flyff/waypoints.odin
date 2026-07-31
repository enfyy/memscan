package flyff

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// ===========================================================================
// Waypoint sets: an ordered list of named map positions, drawn as flags on the radar and importable
// into a behaviour chart as a chain of walk_to nodes.
//
// WHY IT EXISTS: `walk_to` has always taken a coordinate, but the only ways to get one into a chart
// were to type it or to stand on the spot and press Here. Authoring a route therefore meant walking
// the whole route in game, adding a node at every stop, and copying numbers by hand. The radar
// already draws the map; the route belongs on it.
//
// ORDER IS ARRAY POSITION. A waypoint carries no index field, and that is the whole reason this file
// is small: "set the index" is a move within the array, "delete" is ordered_remove, and the gap the
// user was promised would close closes because there was never an index to leave behind. Everything
// displayed is 1-based; everything stored is 0-based.
//
// Y IS NOT STORED. position_text (script_blocks.odin) drops it for the same reason: act_walk_common
// takes Y from the live player position when the block runs, and the client re-derives ground height
// from the heightmap. A stored Y would only be a stale number to be wrong about later.
//
// Authoring: the radar flag editor (mode W, radar.odin) or the walk-and-place text commands here
// (`waypoints add` at the player's feet, or explicit world coords). Serialized to
// <exe-dir>/waypoints/<name>.waypoints, one file per named set, exactly like fences.
// ===========================================================================

WAYPOINT_EXT :: ".waypoints"

// Undo depth. Same number as the chart editor's ED_UNDO_MAX, and for the same reason: a set is a
// handful of positions and names, so a whole-set clone is far cheaper than being clever.
WAYPOINT_UNDO_MAX :: 32

Waypoint :: struct {
  position: [2]f32, // world (x, z)
  name:     string, // owned; "" means unnamed - waypoint_label falls back to the ordinal
}

Waypoint_Set :: struct {
  name:      string, // owned; the file basename, "" until saved or loaded
  map_id:    u32, // CWorld::m_dwWorldID the positions were recorded on
  map_known: bool, // false when landwidth_off is unpinned - then map_id means nothing and is not shown
  waypoints: [dynamic]Waypoint,
}

// ===========================================================================
// Lifetime
// ===========================================================================

waypoint_set_clone :: proc(set: Waypoint_Set) -> (out: Waypoint_Set) {
  out = set
  out.name = set.name == "" ? "" : strings.clone(set.name)
  out.waypoints = make([dynamic]Waypoint, 0, len(set.waypoints))
  for point in set.waypoints {
    append(&out.waypoints, Waypoint{position = point.position, name = point.name == "" ? "" : strings.clone(point.name)})
  }
  return
}

waypoint_set_free :: proc(set: ^Waypoint_Set) {
  for point in set.waypoints {
    delete(point.name)
  }
  delete(set.waypoints)
  delete(set.name)
  set^ = {}
}

// Empty the set's points but keep its name and map binding - the "clear and draw a new route on the
// same map" case. waypoint_set_free is the one that forgets which set this was.
waypoint_set_reset :: proc(set: ^Waypoint_Set) {
  for point in set.waypoints {
    delete(point.name)
  }
  clear(&set.waypoints)
}

// Free the live set and both history stacks. Called from on_close alongside fence_destroy.
waypoint_destroy :: proc(session: ^Session) {
  waypoint_history_clear(session)
  delete(session.waypoint_undo)
  delete(session.waypoint_redo)
  session.waypoint_undo = nil
  session.waypoint_redo = nil
  waypoint_set_free(&session.waypoint_set)
}

// ===========================================================================
// Undo / redo
//
// Whole-set snapshots rather than a log of reversible edits, copying the chart editor (ed_snapshot in
// gui_nodes.odin). The fence's undo is a bare pop of the last shape, which is enough when the only
// edit is an append; this editor renames and reorders in place, and there is no popping a rename.
// ===========================================================================

waypoint_history_clear :: proc(session: ^Session) {
  for &set in session.waypoint_undo {
    waypoint_set_free(&set)
  }
  clear(&session.waypoint_undo)
  for &set in session.waypoint_redo {
    waypoint_set_free(&set)
  }
  clear(&session.waypoint_redo)
}

// Call BEFORE mutating. Every mutator below takes a `snapshot := true` parameter so a batch edit can
// call this once itself and pass false down - the same convention as ed_add_node / ed_delete_node,
// and what makes one Ctrl+Z undo a whole imported batch instead of one node of it.
waypoint_snapshot :: proc(session: ^Session) {
  append(&session.waypoint_undo, waypoint_set_clone(session.waypoint_set))
  if len(session.waypoint_undo) > WAYPOINT_UNDO_MAX {
    waypoint_set_free(&session.waypoint_undo[0])
    ordered_remove(&session.waypoint_undo, 0)
  }
  for &set in session.waypoint_redo {
    waypoint_set_free(&set)
  }
  clear(&session.waypoint_redo)
}

waypoint_undo :: proc(session: ^Session) -> bool {
  if len(session.waypoint_undo) == 0 {
    return false
  }
  append(&session.waypoint_redo, session.waypoint_set)
  session.waypoint_set = pop(&session.waypoint_undo)
  return true
}

waypoint_redo :: proc(session: ^Session) -> bool {
  if len(session.waypoint_redo) == 0 {
    return false
  }
  append(&session.waypoint_undo, session.waypoint_set)
  session.waypoint_set = pop(&session.waypoint_redo)
  return true
}

// ===========================================================================
// Mutators - the single code path. The radar's flag editor calls these directly (it runs under
// exec_mutex); the CLI calls them; the radar's context menu reaches them THROUGH the CLI, as a
// deferred command, so the menu and the command line can never drift apart.
// ===========================================================================

waypoint_index_ok :: proc(set: Waypoint_Set, index: int) -> bool {
  return index >= 0 && index < len(set.waypoints)
}

// The map the client has us on right now. ok=false when we are detached or worldscan has not pinned
// landwidth_off - then a set simply has no map binding and nothing warns about one.
waypoint_current_map :: proc(session: ^Session) -> (id: u32, ok: bool) {
  if !session.attached {
    return 0, false
  }
  world, _, _, resolved := tc_resolve_anchors(session)
  if !resolved || world == 0 {
    return 0, false
  }
  return world_map_id(session, world)
}

// Stamp the live map onto the set. Only meaningful while it is EMPTY: once it holds positions they
// belong to whatever map they were placed on, and re-stamping would relabel them as somewhere else.
waypoint_bind_map :: proc(session: ^Session) {
  if len(session.waypoint_set.waypoints) > 0 {
    return
  }
  if id, ok := waypoint_current_map(session); ok {
    session.waypoint_set.map_id = id
    session.waypoint_set.map_known = true
  } else {
    session.waypoint_set.map_known = false
  }
}

// Append a waypoint. Returns its 0-based index.
waypoint_place :: proc(session: ^Session, position: [2]f32, name := "", snapshot := true) -> int {
  if snapshot {
    waypoint_snapshot(session)
  }
  waypoint_bind_map(session)
  append(&session.waypoint_set.waypoints, Waypoint{position = position, name = name == "" ? "" : strings.clone(name)})
  return len(session.waypoint_set.waypoints) - 1
}

waypoint_rename :: proc(session: ^Session, index: int, name: string, snapshot := true) -> bool {
  if !waypoint_index_ok(session.waypoint_set, index) {
    return false
  }
  if snapshot {
    waypoint_snapshot(session)
  }
  point := &session.waypoint_set.waypoints[index]
  delete(point.name)
  point.name = name == "" ? "" : strings.clone(name)
  return true
}

waypoint_reposition :: proc(session: ^Session, index: int, position: [2]f32, snapshot := true) -> bool {
  if !waypoint_index_ok(session.waypoint_set, index) {
    return false
  }
  if snapshot {
    waypoint_snapshot(session)
  }
  session.waypoint_set.waypoints[index].position = position
  return true
}

// Move a waypoint to a new position in the order. Everything between the two slots shuffles by one,
// so the visible effect is "this one is now Nth" with no gap anywhere - which is the whole promise of
// storing order as array position.
waypoint_move_to_index :: proc(session: ^Session, from: int, to: int, snapshot := true) -> bool {
  set := &session.waypoint_set
  if !waypoint_index_ok(set^, from) || !waypoint_index_ok(set^, to) || from == to {
    return false
  }
  if snapshot {
    waypoint_snapshot(session)
  }
  moved := set.waypoints[from]
  ordered_remove(&set.waypoints, from)
  inject_at(&set.waypoints, to, moved)
  return true
}

waypoint_delete :: proc(session: ^Session, index: int, snapshot := true) -> bool {
  set := &session.waypoint_set
  if !waypoint_index_ok(set^, index) {
    return false
  }
  if snapshot {
    waypoint_snapshot(session)
  }
  delete(set.waypoints[index].name)
  ordered_remove(&set.waypoints, index) // the gap closes here; there is no index field to renumber
  return true
}

waypoint_clear :: proc(session: ^Session, snapshot := true) {
  if snapshot {
    waypoint_snapshot(session)
  }
  waypoint_set_reset(&session.waypoint_set)
}

// The nearest waypoint within <radius> world units of (x, z), or ok=false. Ties break toward the
// LATER waypoint: flags stack up as you place them, and the one on top is the one you just dropped.
waypoint_pick_at :: proc(set: Waypoint_Set, x, z: f32, radius: f32) -> (index: int, ok: bool) {
  best := radius * radius
  index = -1
  for point, i in set.waypoints {
    dx := point.position[0] - x
    dz := point.position[1] - z
    d2 := dx * dx + dz * dz
    if d2 <= best {
      best = d2
      index = i
      ok = true
    }
  }
  return
}

// What to call waypoint <index> in prose and on the canvas. An unnamed one is still a place you can
// point at, so it gets an ordinal rather than a blank.
waypoint_label :: proc(set: Waypoint_Set, index: int, allocator := context.temp_allocator) -> string {
  if waypoint_index_ok(set, index) && set.waypoints[index].name != "" {
    return set.waypoints[index].name
  }
  return fmt.aprintf("Waypoint %d", index + 1, allocator = allocator)
}

// ===========================================================================
// Serialization  (<exe-dir>/waypoints/<name>.waypoints, line-based like fences)
// ===========================================================================

waypoint_dir_path :: proc(allocator := context.temp_allocator) -> string {
  exe := os.args[0]
  slash := strings.last_index_any(exe, "\\/")
  dir := slash >= 0 ? exe[:slash] : "."
  return fmt.aprintf("%s/waypoints", dir, allocator = allocator)
}

waypoint_file_path :: proc(name: string, allocator := context.temp_allocator) -> string {
  return fmt.aprintf("%s/%s%s", waypoint_dir_path(allocator), name, WAYPOINT_EXT, allocator = allocator)
}

waypoint_serialize :: proc(set: ^Waypoint_Set, b: ^strings.Builder) {
  fmt.sbprintln(b, "# memscan waypoints")
  if set.map_known {
    fmt.sbprintfln(b, "map %d", set.map_id)
  }
  for point in set.waypoints {
    // The name is the REST OF THE LINE, so waypoint names may contain spaces - they become chart
    // section names, and `group Run in a circle` already does. Only the SET name has to survive
    // strings.fields, because only it is also a command argument and a filename.
    if point.name == "" {
      fmt.sbprintfln(b, "point %v %v", point.position[0], point.position[1])
    } else {
      fmt.sbprintfln(b, "point %v %v %s", point.position[0], point.position[1], point.name)
    }
  }
}

@(private = "file")
waypoint_f32 :: proc(s: string) -> f32 {
  v, _ := strconv.parse_f64(s)
  return f32(v)
}

// Everything after the first <count> whitespace-separated tokens, verbatim. strings.fields would
// collapse a name's internal spacing; this keeps "Big  Rock" as it was typed.
@(private = "file")
waypoint_rest_after :: proc(line: string, count: int) -> string {
  rest := line
  for _ in 0 ..< count {
    rest = strings.trim_left_space(rest)
    end := strings.index_any(rest, " \t")
    if end < 0 {
      return ""
    }
    rest = rest[end:]
  }
  return strings.trim_space(rest)
}

// Replace the set's contents from a serialized set. Tolerant: skips malformed lines, like fences.
waypoint_deserialize :: proc(set: ^Waypoint_Set, content: string) {
  waypoint_set_reset(set)
  set.map_known = false
  set.map_id = 0
  lines := strings.split(content, "\n", context.temp_allocator)
  for raw in lines {
    line := strings.trim_space(raw)
    if line == "" || line[0] == '#' {
      continue
    }
    fields := strings.fields(line, context.temp_allocator)
    if len(fields) == 0 {
      continue
    }
    switch fields[0] {
    case "map":
      if len(fields) >= 2 {
        if id, ok := strconv.parse_u64(fields[1]); ok {
          set.map_id = u32(id)
          set.map_known = true
        }
      }
    case "point":
      if len(fields) >= 3 {
        name := waypoint_rest_after(line, 3)
        append(
          &set.waypoints,
          Waypoint {
            position = {waypoint_f32(fields[1]), waypoint_f32(fields[2])},
            name = name == "" ? "" : strings.clone(name),
          },
        )
      }
    }
  }
}

waypoint_save :: proc(session: ^Session, name: string) -> bool {
  if !bhv_name_ok(name) {
    fmt.eprintfln("waypoints save: '%s' is not a usable name - %s.", name, BHV_NAME_RULE)
    return false
  }
  dir := waypoint_dir_path()
  os.make_directory(dir) // ignore "already exists"
  b := strings.builder_make(context.temp_allocator)
  waypoint_serialize(&session.waypoint_set, &b)
  path := waypoint_file_path(name)
  if err := os.write_entire_file(path, transmute([]byte)strings.to_string(b)); err != nil {
    fmt.eprintfln("waypoints save: write failed (%v): %s", err, path)
    return false
  }
  delete(session.waypoint_set.name)
  session.waypoint_set.name = strings.clone(name)
  return true
}

// Read a saved set WITHOUT touching the live one - what `list` and the chart import use.
waypoint_read :: proc(name: string) -> (set: Waypoint_Set, ok: bool) {
  path := waypoint_file_path(name)
  data, err := os.read_entire_file(path, context.temp_allocator)
  if err != nil {
    return {}, false
  }
  set.name = strings.clone(name)
  waypoint_deserialize(&set, string(data))
  return set, true
}

waypoint_load :: proc(session: ^Session, name: string) -> bool {
  set, ok := waypoint_read(name)
  if !ok {
    fmt.eprintfln("waypoints load: cannot read %s. 'waypoints list' to see saved sets.", waypoint_file_path(name))
    return false
  }
  waypoint_snapshot(session) // loading over an unsaved route is exactly the mistake undo is for
  waypoint_set_free(&session.waypoint_set)
  session.waypoint_set = set
  return true
}

waypoint_exists :: proc(name: string) -> bool {
  return os.exists(waypoint_file_path(name))
}

// Every saved set, in the order the directory hands them over. Names are TEMP-allocated.
waypoint_list_names :: proc(allocator := context.temp_allocator) -> []string {
  out := make([dynamic]string, allocator)
  infos, err := os.read_all_directory_by_path(waypoint_dir_path(), context.temp_allocator)
  if err != nil {
    return out[:]
  }
  for info in infos {
    if strings.has_suffix(info.name, WAYPOINT_EXT) {
      append(&out, strings.clone(strings.trim_suffix(info.name, WAYPOINT_EXT), allocator))
    }
  }
  return out[:]
}

// ===========================================================================
// Chart import: a set becomes a run of walk_to nodes, one per waypoint, each in a section named
// after its waypoint. The chain runs ONCE and stops - the last node names no successor, so what
// happens after the route is something the author wires rather than something this decides.
// ===========================================================================

waypoint_build_chart :: proc(set: Waypoint_Set, chart_name: string) -> (doc: Behaviour_Doc, ok: bool) {
  if len(set.waypoints) == 0 {
    fmt.eprintln("waypoints import: the set is empty.")
    return {}, false
  }
  b := builder_begin(chart_name, .Once)
  s := seq(b)
  for point, i in set.waypoints {
    section(b, waypoint_label(set, i))
    walk(&s, {point.position[0], 0, point.position[1]}) // Y is re-derived at run time, see the header
  }
  steps, mode, build_errors := builder_end(b)
  if len(build_errors) > 0 {
    fmt.eprintfln("waypoints import: %d authoring problem(s):", len(build_errors))
    for problem in build_errors {
      fmt.eprintfln("  %s", problem)
    }
    script_steps_free(&steps)
    return {}, false
  }
  doc.name = strings.clone(chart_name)
  doc.mode = mode
  doc.steps = steps
  doc.uses = make([dynamic]string)
  doc.entry = doc.steps[0].id
  // `seq` lets adjacency carry the flow, which is the right way to WRITE a program and the wrong way
  // to EDIT one. Materializing turns each fall-through into a real goto so the canvas can draw the
  // route as wired nodes - and leaves the LAST node with no successor, which is the "runs once" half.
  script_materialize_fallthrough(doc.steps[:])
  return doc, true
}

// ===========================================================================
// Text commands  (waypoints <subcommand>) - dispatched from module_dispatch
// ===========================================================================

WAYPOINT_USAGE :: `waypoints subcommands:
  (no args) | status         the current set: name, count, map
  show                       list the waypoints in order
  add [<x,z>] [name...]      append one; no coords = at your feet
  rename <n> <name...>       name waypoint <n>
  move <n> <to>              reorder; the others close up around it
  delete <n>                 remove waypoint <n> (no gaps left behind)
  clear                      remove them all
  undo | redo
  save [name] | load <name> | list | erase <name>
  import <set> [as <chart>]  generate a walk_to chart from a saved set`

waypoint_print_status :: proc(session: ^Session) {
  set := &session.waypoint_set
  name := set.name == "" ? "(unsaved)" : set.name
  where_at := ""
  if set.map_known {
    if live, ok := waypoint_current_map(session); ok && live != set.map_id {
      where_at = fmt.tprintf(", map %d - YOU ARE ON MAP %d", set.map_id, live)
    } else {
      where_at = fmt.tprintf(", map %d", set.map_id)
    }
  }
  fmt.printfln("waypoints: %s, %d point(s)%s", name, len(set.waypoints), where_at)
}

waypoint_print_show :: proc(session: ^Session) {
  set := &session.waypoint_set
  waypoint_print_status(session)
  for point, i in set.waypoints {
    named := point.name == "" ? "" : fmt.tprintf("  %s", point.name)
    fmt.printfln("  [%d] (%.1f, %.1f)%s", i + 1, point.position[0], point.position[1], named)
  }
  if len(set.waypoints) == 0 {
    fmt.println("  (no waypoints - place flags on the radar in W mode, or 'waypoints add')")
  }
}

// Parse a 1-based index argument into a 0-based one, printing why if it is not usable.
@(private = "file")
waypoint_parse_index :: proc(session: ^Session, arg: string, what: string) -> (index: int, ok: bool) {
  n, parsed := strconv.parse_int(arg)
  if !parsed {
    fmt.eprintfln("waypoints %s: '%s' is not a number (indices are 1-based, see 'waypoints show').", what, arg)
    return 0, false
  }
  index = n - 1
  if !waypoint_index_ok(session.waypoint_set, index) {
    fmt.eprintfln("waypoints %s: no waypoint %d (there are %d).", what, n, len(session.waypoint_set.waypoints))
    return 0, false
  }
  return index, true
}

cli_waypoints :: proc(session: ^Session, args: []string) {
  if len(args) == 0 {
    waypoint_print_status(session)
    return
  }
  switch args[0] {
  case "status":
    waypoint_print_status(session)

  case "show", "list-points":
    waypoint_print_show(session)

  case "add":
    waypoint_cmd_add(session, args[1:])

  case "rename":
    if len(args) < 2 {
      fmt.eprintln("usage: waypoints rename <n> <name...>   (no name clears it)")
      return
    }
    index, ok := waypoint_parse_index(session, args[1], "rename")
    if !ok {
      return
    }
    // No name at all clears it back to unnamed. The context menu's empty name box says it this way,
    // and there has to be SOME spelling of "it does not need a name after all".
    name := len(args) >= 3 ? strings.join(args[2:], " ", context.temp_allocator) : ""
    waypoint_rename(session, index, name)
    fmt.printfln("waypoints: [%d] is now '%s'.", index + 1, waypoint_label(session.waypoint_set, index))

  case "move":
    if len(args) < 3 {
      fmt.eprintln("usage: waypoints move <n> <to>")
      return
    }
    from, from_ok := waypoint_parse_index(session, args[1], "move")
    if !from_ok {
      return
    }
    to, to_ok := waypoint_parse_index(session, args[2], "move")
    if !to_ok {
      return
    }
    if !waypoint_move_to_index(session, from, to) {
      fmt.printfln("waypoints: [%d] is already there.", from + 1)
      return
    }
    fmt.printfln("waypoints: moved [%d] to [%d].", from + 1, to + 1)

  case "delete", "del":
    if len(args) < 2 {
      fmt.eprintln("usage: waypoints delete <n>   ('waypoints erase <name>' removes a saved SET)")
      return
    }
    index, ok := waypoint_parse_index(session, args[1], "delete")
    if !ok {
      return
    }
    label := strings.clone(waypoint_label(session.waypoint_set, index), context.temp_allocator)
    waypoint_delete(session, index)
    fmt.printfln("waypoints: deleted '%s' (%d left).", label, len(session.waypoint_set.waypoints))

  case "clear":
    waypoint_clear(session)
    fmt.println("waypoints: cleared ('waypoints undo' brings it back).")

  case "undo":
    if waypoint_undo(session) {
      fmt.printfln("waypoints: undone (%d point(s)).", len(session.waypoint_set.waypoints))
    } else {
      fmt.println("waypoints: nothing to undo.")
    }

  case "redo":
    if waypoint_redo(session) {
      fmt.printfln("waypoints: redone (%d point(s)).", len(session.waypoint_set.waypoints))
    } else {
      fmt.println("waypoints: nothing to redo.")
    }

  case "save":
    name := len(args) >= 2 ? args[1] : session.waypoint_set.name
    if name == "" {
      fmt.eprintln("usage: waypoints save <name>   (this set has no name yet)")
      return
    }
    if waypoint_save(session, name) {
      fmt.printfln("waypoints: saved %d point(s) -> %s", len(session.waypoint_set.waypoints), waypoint_file_path(name))
    }

  case "load":
    if len(args) < 2 {
      fmt.eprintln("usage: waypoints load <name>")
      return
    }
    if waypoint_load(session, args[1]) {
      waypoint_print_status(session)
    }

  case "list":
    waypoint_cmd_list(session)

  case "erase":
    if len(args) < 2 {
      fmt.eprintln("usage: waypoints erase <name>   ('waypoints delete <n>' removes one WAYPOINT)")
      return
    }
    path := waypoint_file_path(args[1])
    if !waypoint_exists(args[1]) {
      fmt.eprintfln("waypoints erase: no saved set '%s'.", args[1])
      return
    }
    if err := os.remove(path); err != nil {
      fmt.eprintfln("waypoints erase: could not remove %s (%v).", path, err)
      return
    }
    fmt.printfln("waypoints: erased %s.", path)

  case "import":
    waypoint_cmd_import(session, args[1:])

  case "help":
    fmt.println(WAYPOINT_USAGE)

  case:
    fmt.eprintfln("waypoints: unknown '%s'.", args[0])
    fmt.println(WAYPOINT_USAGE)
  }
}

waypoint_cmd_add :: proc(session: ^Session, args: []string) {
  position: [2]f32
  rest := args
  // An explicit "x,z" first argument wins; otherwise place at the player's feet, the same
  // walk-and-place gesture `fence add` offers.
  if len(args) >= 1 {
    if p, ok := parse_vec2_literal(args[0]); ok {
      position = p
      rest = args[1:]
    } else {
      x, z, player_ok := waypoint_player_xz(session)
      if !player_ok {
        return
      }
      position = {x, z}
    }
  } else {
    x, z, player_ok := waypoint_player_xz(session)
    if !player_ok {
      return
    }
    position = {x, z}
  }
  name := len(rest) > 0 ? strings.join(rest, " ", context.temp_allocator) : ""
  index := waypoint_place(session, position, name)
  fmt.printfln("waypoints: [%d] %s at (%.1f, %.1f)", index + 1, waypoint_label(session.waypoint_set, index), position[0], position[1])
}

// Where to drop an "at the player" waypoint. Prints why if the position is not readable.
@(private = "file")
waypoint_player_xz :: proc(session: ^Session) -> (x, z: f32, ok: bool) {
  if !session.attached {
    fmt.eprintln("waypoints: attach first, or give explicit coords (waypoints add <x,z>).")
    return 0, 0, false
  }
  position, position_ok := read_player_pos(session)
  if !position_ok {
    fmt.eprintln("waypoints: could not read player position - run 'setup <name>'.")
    return 0, 0, false
  }
  return position[0], position[2], true
}

waypoint_cmd_list :: proc(session: ^Session) {
  dir := waypoint_dir_path()
  names := waypoint_list_names()
  if len(names) == 0 {
    fmt.printfln("waypoints: no saved sets yet (%s).", dir)
    return
  }
  live_map, live_ok := waypoint_current_map(session)
  fmt.printfln("saved waypoint sets in %s:", dir)
  for name in names {
    set, ok := waypoint_read(name)
    if !ok {
      fmt.printfln("  %-24s (unreadable)", name)
      continue
    }
    elsewhere := ""
    if set.map_known && live_ok && set.map_id != live_map {
      elsewhere = fmt.tprintf("  [map %d - not the map you are on]", set.map_id)
    }
    fmt.printfln("  %-24s %d point(s)%s", name, len(set.waypoints), elsewhere)
    waypoint_set_free(&set)
  }
}

waypoint_cmd_import :: proc(session: ^Session, args: []string) {
  if len(args) < 1 {
    fmt.eprintln("usage: waypoints import <set> [as <chart>]")
    return
  }
  set_name := args[0]
  chart_name := set_name
  if len(args) >= 3 && args[1] == "as" {
    chart_name = args[2]
  } else if len(args) == 2 {
    chart_name = args[1]
  }
  set, ok := waypoint_read(set_name)
  if !ok {
    fmt.eprintfln("waypoints import: no saved set '%s'. 'waypoints list' to see them.", set_name)
    return
  }
  defer waypoint_set_free(&set)
  if !bhv_name_ok(chart_name) {
    fmt.eprintfln("waypoints import: '%s' is not a usable chart name - %s.", chart_name, BHV_NAME_RULE)
    return
  }
  // Refuse rather than overwrite: a chart is hand-edited work, and "import" is not a word anyone
  // expects to destroy some. `as <name>` is the way to say where it should go instead.
  if bhv_exists(chart_name) {
    fmt.eprintfln("waypoints import: chart '%s' already exists - use 'waypoints import %s as <chart>'.", chart_name, set_name)
    return
  }
  if set.map_known {
    if live, live_ok := waypoint_current_map(session); live_ok && live != set.map_id {
      fmt.printfln("waypoints import: NOTE - '%s' was recorded on map %d and you are on map %d; the coordinates will not mean the same place.", set_name, set.map_id, live)
    }
  }
  doc, built := waypoint_build_chart(set, chart_name)
  if !built {
    return
  }
  defer behaviour_doc_free(&doc)
  if !bhv_save(&doc) {
    return
  }
  fmt.printfln("waypoints: imported %d point(s) -> chart '%s'. 'script show %s' to read it.", len(set.waypoints), chart_name, chart_name)
}
