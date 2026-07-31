package flyff

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

import imgui "../../lib/odin-imgui"

// ===========================================================================
// The node canvas - the authoring surface for behaviour charts.
//
// Hand-rolled on ImGui draw lists rather than thedmd/imgui-node-editor, which is C++ with no C API:
// using it would mean an extern "C" shim, a rebuild of the vendored prebuilt imgui_windows_x64.lib,
// and hand-written Odin bindings to redo on every imgui bump. This project already hand-draws its
// gauges, its icons and the whole radar; a canvas is the same kind of work.
//
// WHAT THE CANVAS EDITS. A Behaviour_Doc owned by Panel_State - never session.script. The running
// program and the thing you are drawing are separate on purpose: you can edit a chart while it runs,
// and re-running is what picks the edit up. Every node is a Script_Step, so there is no editor-only
// model to keep in sync with the VM's; script_resolve_ids re-derives the jump indices after each
// structural edit and that is the whole "compile" step.
//
// THE ONE THING THAT LOOKS LIKE A RULE BREAK. gui.odin's contract is that the draw phase never
// touches `session` and issues every action as a CLI command. Saving here calls bhv_save directly.
// That is the same call `script export` makes and it touches no session state - the behaviours
// DIRECTORY is not session state, which is exactly why P3 already reads it from this phase (see the
// note atop gui_behaviour.odin). Anything that does reach the session - running the chart, stopping
// it - still goes through panel_enqueue. The rule is about the lock, and a file write is not under it.
//
// WHY THE ARRAY ORDER STILL MATTERS ON A CANVAS. script_next_pc falls through to the next array slot
// when a step names no successor, so "no wire" is not the same as "no edge" - it means "the node
// below me in the file". Hiding that would make the canvas lie about what the walker does, so those
// implicit edges are DRAWN, dimmed and tagged seq. A new node is appended, which is why adding one
// continues the program instead of orphaning it.
// ===========================================================================

// Authored in canvas units - one unit is one pixel at zoom 1 and ui_scale 1.
ED_NODE_W :: f32(210)
ED_NODE_H :: f32(58)
ED_TITLE_H :: f32(21)
ED_PORT_R :: f32(5)
ED_GRID :: f32(28)
ED_ZOOM_MIN :: f32(0.35)
ED_ZOOM_MAX :: f32(2.2)
ED_INSPECTOR_W :: f32(330)
ED_PAL_W :: f32(430) // add-node palette: the list AND its search box, so the popup is one column wide

// What the mouse is doing between press and release. One field instead of three bools because the
// gestures are mutually exclusive and deciding WHICH at press time is the whole trick - it is what
// lets a single background InvisibleButton drive panning, node dragging and wiring without any
// per-node ImGui items fighting each other for the hover.
Ed_Gesture :: enum {
  None,
  Pan,
  Drag,
  Link,
  Box, // shift+drag on empty canvas: rubber-band select
}

Gui_Editor :: struct {
  open:       bool,
  doc:        Behaviour_Doc, // OWNED while open
  shadowing:  bool, // the doc was built from Odin: saving writes a file that shadows the built-in
  dirty:      bool,
  msg:        string, // owned - the last save / validation result
  msg_bad:    bool,
  msg_at:     f64, // rl.GetTime() when it was set, so it can fade
  name_buf:   [64]u8, // the SAVE TARGET; typing a new one here is a save-as, not a rename

  // view
  pan:        [2]f32, // canvas point under the middle of the viewport
  zoom:       f32,

  fit_req:    bool, // ed_focus_all asked for a zoom-to-fit; the canvas does it, it knows the viewport

  // interaction
  //
  // `sel` is the PRIMARY selection - what the inspector edits and the context menu acts on - and
  // `selset` is everything selected including it. Keeping the primary as its own field rather than
  // making the inspector pick one out of a set is what let multi-select arrive without touching the
  // twenty places that already read ed.sel.
  sel:        Node_Id,
  selset:     [dynamic]Node_Id,
  hot:        Node_Id, // hovered this frame - drives the focus dimming and the hover card
  gesture:    Ed_Gesture,
  drag_id:    Node_Id,
  drag_raw:   [2]f32, // un-snapped drag position, so snapping cannot swallow sub-grid mouse movement
  box_from:   [2]f32, // canvas-space anchor of a rubber-band selection
  link_from:  Node_Id,
  link_port:  int,

  // Undo. A ring of whole-document snapshots rather than a log of reversible edits: the document is
  // tens of nodes, a deep copy is trivially cheap at this size, and "clone it before you touch it"
  // cannot get an inverse operation subtly wrong the way a per-edit undo log can.
  undo:       [dynamic]Behaviour_Doc,
  redo:       [dynamic]Behaviour_Doc,

  // add-node palette
  pal_req:    bool, // the toolbar's + asked for it; the CANVAS opens it (see gui_ed_toolbar)
  pal_seed:   bool, // focus the filter box on the frame it opens
  pal_filter: [64]u8,
  pal_at:     [2]f32, // where the created node lands, in canvas units
  pal_wire:   Node_Id, // wire the new node up from this node's port (0 = free-standing)
  pal_port:   int,
  // Which node the new one goes BEHIND in the array - see ed_add_node on why that is control flow and
  // not bookkeeping. Usually the same as pal_wire, but splicing into a FALL-THROUGH sets only this one:
  // there is no wire to re-aim there, the array insert is the whole edit.
  pal_after:  Node_Id,

  // find (Ctrl+F) - same "ask here, open on the canvas" dance as the palette, and for the same reason
  find_req:   bool,
  find_seed:  bool,
  find_buf:   [64]u8,

  // Inspector text buffers. A condition is up to SCRIPT_MAX_CONDITION_ROWS ROWS and each row has two string
  // arguments, so the layout is: [0,1] the action, then [2 ..] the cond's rows, then the until's -
  // see ED_TEXT_CONDITION / ED_TEXT_UNTIL. Re-seeded whenever the selection or a block kind changes, or a
  // row is added or removed; text_buffers_for_node is what detects the first two and options_revision the third.
  text_buffers_for_node:    Node_Id,
  text_buffers:       [ED_TEXT_BUFFERS_PER_STEP][ED_TEXT_BUFFER_SIZE]u8,
  section_buffer:       [64]u8, // the selected node's section name, seeded alongside text_buffers

  // Which string field has its suggestion list open, as a hash of the field's ImGui id - one at a
  // time, across both panels. See the header of gui_fields.odin for why it is latched rather than
  // read live off IsItemActive.
  suggest_field:      u32,
  // What that field is currently offering, HELD rather than recomputed per frame. Half a mob corpus is
  // Gui_Frame.nearby_names, which the radar rebuilds from the live blips every frame - so a mob dying,
  // respawning or walking out of range reordered the list (or dropped a row) between the mouse going
  // down on a suggestion and coming back up, and a press ImGui cannot pair with the same id at the same
  // place is a click that never happened. Rebuilt only when something the USER changed says to: a
  // different field, different text typed, or a badge added or removed.
  suggest_rows:       [dynamic]string, // owned clones - the corpus they came from is temp-allocated
  suggest_for_query:  string, // owned
  suggest_for_badges: int,
  // Which Coord field is being typed as an @name rather than as numbers. Only needed while the
  // expression is still EMPTY - once there is text in it the data says so by itself.
  coord_expression_field: u32,


  // Chart options tab (gui_ed_options).
  //
  // The node inspector gets away with two text buffers because it edits ONE node. The options panel
  // draws every node at once, so every string argument ON SCREEN needs a buffer of its own - hence a
  // grown array indexed (step*3 + payload)*2 + slot, payload 0=action 1=cond 2=until.
  //
  // It is re-seeded from the document only when something OUTSIDE the panel rewrote a step's strings
  // (undo, a block-kind swap, a node added or deleted), tracked by options_revision. Re-seeding every frame
  // would be simpler and wrong: overwriting the buffer under a live ImGui text field moves the caret
  // to the end on every keystroke. Editing here writes straight back into the step, so between those
  // events the two are always in sync and there is nothing to re-seed.
  tab_options:       bool,
  options_filter:        [64]u8,
  options_text_buffers:          [dynamic][ED_TEXT_BUFFER_SIZE]u8,
  options_revision:           int,
  options_seeded_revision:        int, // the options_revision the buffers hold; starts equal, so 0 means "seed me"
  options_seeded_step_count:        int, // step count they were seeded from

  // ed_params: spell the description out under each field (options panel), or leave it in the tooltip
  // (the inspector, which sits next to a canvas you are trying to read).
  param_help_inline: bool,

  // Problems tab (gui_ed_problems) and the trace strip (gui_ed_trace).
  //
  // The problem LIST is deliberately not cached here. gui_node_editor lints once per frame into temp and
  // passes the slice down to the three things that read it - the toolbar badge, the tab, the canvas dots.
  // A cached list would need invalidating on every edit path, and one missed path is a panel confidently
  // reporting problems the chart no longer has, which is worse than having no panel. The lint walks tens
  // of nodes; the canvas beside it re-tessellates every wire in the same frame.
  tab_problems: bool, // one-shot "select the Problems tab", set by the badge
  show_notes:   bool, // notes are legitimate and numerous - hidden until asked for
  trace_open:   bool,
  trace_follow: bool, // stick to the newest row

  // Wire hit-testing (ed_hit_edge). The hovered wire is named by its SOURCE plus the port it leaves,
  // which is the pair ed_wire takes - so cutting one is the same call the inspector's clear button makes.
  hot_edge_from: Node_Id,
  hot_edge_port: int,
  // The wire the CONTEXT MENU is about. A separate latch from hot_edge_*, because the popup is drawn on
  // later frames and by then the cursor has moved off the wire onto the menu.
  ctx_edge_from: Node_Id,
  ctx_edge_port: int,
  ctx_edge_kind: Ed_Edge_Kind,
}

// ===========================================================================
// Lifetime
// ===========================================================================

gui_editor_free :: proc(ed: ^Gui_Editor) {
  if ed.doc.name != "" || ed.doc.steps != nil {
    behaviour_doc_free(&ed.doc)
  }
  ed_history_clear(ed)
  ed_suggest_rows_clear(ed)
  delete(ed.suggest_rows)
  delete(ed.undo)
  delete(ed.redo)
  delete(ed.selset)
  delete(ed.options_text_buffers)
  delete(ed.msg)
  ed^ = {}
}

// ===========================================================================
// Undo / redo
// ===========================================================================

ED_UNDO_MAX :: 32

@(private = "file")
ed_history_clear :: proc(ed: ^Gui_Editor) {
  for &d in ed.undo {
    behaviour_doc_free(&d)
  }
  clear(&ed.undo)
  for &d in ed.redo {
    behaviour_doc_free(&d)
  }
  clear(&ed.redo)
}

// Call BEFORE mutating. Every edit path goes through here, which is why the rule is stated as
// "snapshot, then edit" rather than left to each site to remember an inverse. (Not file-private: the
// badge field in gui_fields.odin is an edit path too, and one that adds and removes whole values.)
ed_snapshot :: proc(ed: ^Gui_Editor) {
  append(&ed.undo, behaviour_doc_clone(ed.doc))
  if len(ed.undo) > ED_UNDO_MAX {
    behaviour_doc_free(&ed.undo[0])
    ordered_remove(&ed.undo, 0)
  }
  // A new edit invalidates the redo branch - the future you could have gone back to no longer follows
  // from the present.
  for &d in ed.redo {
    behaviour_doc_free(&d)
  }
  clear(&ed.redo)
}

@(private = "file")
ed_undo :: proc(ed: ^Gui_Editor) {
  if len(ed.undo) == 0 {
    return
  }
  append(&ed.redo, ed.doc)
  ed.doc = pop(&ed.undo)
  ed_after_history(ed)
}

@(private = "file")
ed_redo :: proc(ed: ^Gui_Editor) {
  if len(ed.redo) == 0 {
    return
  }
  append(&ed.undo, ed.doc)
  ed.doc = pop(&ed.redo)
  ed_after_history(ed)
}

// The document was swapped wholesale, so anything that POINTS INTO it has to be re-derived: the jump
// cache, the inspector's text buffers, and any selection naming a node this version does not have.
@(private = "file")
ed_after_history :: proc(ed: ^Gui_Editor) {
  ed.dirty = true
  ed.text_buffers_for_node = 0
  ed.options_revision += 1
  if ed_step(ed, ed.sel) == nil {
    ed.sel = 0
  }
  for i := len(ed.selset) - 1; i >= 0; i -= 1 {
    if ed_step(ed, ed.selset[i]) == nil {
      ordered_remove(&ed.selset, i)
    }
  }
  if ok, dangling := script_resolve_ids(ed.doc.steps[:]); !ok {
    ed_msg(ed, fmt.tprintf("an edge points at node %d, which no longer exists", u32(dangling)), true)
  }
}

// ===========================================================================
// Selection
// ===========================================================================

@(private = "file")
ed_sel_only :: proc(ed: ^Gui_Editor, id: Node_Id) {
  clear(&ed.selset)
  ed.sel = id
  if id != 0 {
    append(&ed.selset, id)
  }
}

@(private = "file")
ed_sel_toggle :: proc(ed: ^Gui_Editor, id: Node_Id) {
  for v, i in ed.selset {
    if v == id {
      ordered_remove(&ed.selset, i)
      ed.sel = len(ed.selset) > 0 ? ed.selset[0] : 0
      return
    }
  }
  append(&ed.selset, id)
  ed.sel = id
}

@(private = "file")
ed_selected :: proc(ed: ^Gui_Editor, id: Node_Id) -> bool {
  for v in ed.selset {
    if v == id {
      return true
    }
  }
  return false
}

@(private = "file")
ed_msg :: proc(ed: ^Gui_Editor, text: string, bad: bool) {
  delete(ed.msg)
  ed.msg = strings.clone(text)
  ed.msg_bad = bad
  ed.msg_at = rl.GetTime()
}

// Open an existing chart - either kind. bhv_open resolves a saved file before an Odin behaviour, so
// this is the same "which behaviour is this name" answer the browser and `script run` give.
// `options` opens straight onto the Chart options tab. That is the browser's Configure... entry, and
// it is the whole point of having the tab: tuning a chart should not require reading its graph first.
gui_editor_open :: proc(ps: ^Panel_State, name: string, options := false) {
  ed := &ps.ed
  gui_editor_free(ed)
  doc, ok := bhv_open(name)
  if !ok {
    // The file went away between the directory scan and the click. Go back to the browser rather
    // than leaving the user on a bare map with no window and no explanation.
    ps.browser_open = true
    ps.browser_rescan = true
    return
  }
  ed.doc = doc
  ed.shadowing = !bhv_exists(name) && behaviour_def(name) != nil
  ed_begin(ed, name)
  ed.tab_options = options
}

// A blank chart. It exists only in memory until Save - there is no empty file to clean up if the
// user changes their mind, and an empty behaviour could not be run anyway.
gui_editor_new :: proc(ps: ^Panel_State) {
  ed := &ps.ed
  gui_editor_free(ed)
  name := ed_free_name()
  ed.doc = Behaviour_Doc {
    name  = strings.clone(name),
    mode  = .Once,
    steps = make([dynamic]Script_Step),
  }
  ed_begin(ed, name)
  ed_msg(ed, "empty chart - right-click the canvas to add a node", false)
}

@(private = "file")
ed_begin :: proc(ed: ^Gui_Editor, name: string) {
  ed.open = true
  ed.zoom = 1
  panel_buf_set(ed.name_buf[:], name)
  ed_history_clear(ed) // a different chart: undoing into the previous one would be nonsense
  clear(&ed.selset)
  ed.sel = 0
  ed_autolayout_if_stacked(ed)
  ed_focus_all(ed)
}

gui_editor_close :: proc(ps: ^Panel_State) {
  gui_editor_free(&ps.ed)
  ps.browser_open = true // back where you came from
  ps.browser_rescan = true
}

// First unused chartN. Checks BOTH namespaces: a name that matches an Odin behaviour would silently
// shadow it the moment it was saved, which is not what "new" should ever mean.
@(private = "file")
ed_free_name :: proc() -> string {
  for i in 1 ..< 1000 {
    n := fmt.tprintf("chart%d", i)
    if !bhv_exists(n) && behaviour_def(n) == nil {
      return n
    }
  }
  return "chart"
}

// An Odin behaviour has never had a canvas, so every ui_pos is {0,0} and the nodes would open as one
// pile. Only ever runs on a chart that has never been placed - a user's own arrangement is theirs.
@(private = "file")
ed_autolayout_if_stacked :: proc(ed: ^Gui_Editor) {
  if len(ed.doc.steps) < 2 {
    return
  }
  origin := [2]f32{0, 0} // a local: Odin reads a compound literal in an `if` condition as the block
  for s in ed.doc.steps {
    if s.ui_pos != origin {
      return // it has been placed before; never move a user's nodes
    }
  }
  // Not a user edit: an Odin behaviour is rebuilt from source every time it is opened, so there is
  // nothing here to lose and flagging it dirty would put an unsaved-changes marker on a chart nobody
  // has touched.
  ed_layout(ed, mark_dirty = false)
}

// ===========================================================================
// Layout
//
// WHAT WAS HERE BEFORE, AND WHY IT COULD NOT WORK. The old auto-layout walked the array top to bottom
// and indented by STRUCTURED-block depth (If/While/Repeat). But the interesting charts - auto, hunt,
// sweep - are built from the GRAPH family, and .Branch/.Goto never change that depth. So every node
// landed in one column and every wire ran vertically through the nodes between its ends: a correct
// picture of a program that could not be read.
//
// This is a layered (Sugiyama-style) layout instead, over the real flow graph:
//   1. classify back edges with a DFS, so a loop cannot make the ranking circular;
//   2. rank each node by its LONGEST forward path from the entry - longest, not shortest, so a node
//      always sits below everything that can reach it and edges point consistently downward;
//   3. group the ranks into SECTION bands, kept contiguous so a band is one unbroken region;
//   4. order the nodes within a row by the average position of their parents (barycentre), with a
//      branch's true arm pulled left and its fail arm right, which is what stops the wires crossing.
// ===========================================================================

ED_GAP_X :: f32(46) // between columns
ED_GAP_Y :: f32(62) // between rows
ED_BAND_GAP :: f32(46) // extra air between two section bands, where the band label goes
ED_BAND_PAD :: f32(18) // band frame inset around its nodes
ED_COL_GAP :: f32(120) // between columns of bands
// Rows a column takes before the next band wraps. Tuned against `auto`: at 7 the one-row "Look around"
// could not fit the 7-rung ladder beside it and got a whole column to itself, which cost a column and
// therefore cost zoom. Bands only ever break BETWEEN each other, so this is a target, not a limit - a
// single band longer than this still gets its column.
ED_COL_ROWS :: 9

@(private = "file")
Ed_Band :: struct {
  name:  string,
  first: int, // first member's array index - the order the sections were declared in
}

ed_layout :: proc(ed: ^Gui_Editor, mark_dirty := true) {
  n := len(ed.doc.steps)
  if n == 0 {
    return
  }
  idx_of := make(map[Node_Id]int, n, context.temp_allocator)
  for s, i in ed.doc.steps {
    idx_of[s.id] = i
  }
  entry := ed.doc.entry
  if entry == 0 {
    entry = ed.doc.steps[0].id
  }
  e0 := idx_of[entry] or_else 0

  // --- 1. back edges. An iterative DFS: an edge to a node that is still ON THE STACK (grey) closes a
  // cycle, and ranking over it would never terminate. Iterative rather than recursive because the
  // depth is a property of the user's chart, not of anything we control.
  state := make([]u8, n, context.temp_allocator) // 0 white, 1 grey (on stack), 2 black (done)
  seen := make([]int, n, context.temp_allocator) // how many of this node's edges the DFS has taken
  back := make(map[[2]int]bool, context.temp_allocator)
  stack := make([dynamic]int, context.temp_allocator)
  edges: [3]Ed_Edge
  state[e0] = 1
  append(&stack, e0)
  for len(stack) > 0 {
    i := stack[len(stack) - 1]
    m := ed_edges(ed, i, &edges)
    if seen[i] < m {
      e := edges[seen[i]]
      seen[i] += 1
      j, ok := idx_of[e.to]
      if !ok {
        continue
      }
      switch state[j] {
      case 0:
        state[j] = 1
        append(&stack, j)
      case 1:
        back[{i, j}] = true
      }
      continue
    }
    state[i] = 2
    pop(&stack)
  }

  // --- 2. rank by longest forward path. Relaxed repeatedly rather than topologically sorted: the
  // graph is tens of nodes, and a fixpoint loop cannot be tripped up by an edge shape I did not think of.
  rank := make([]int, n, context.temp_allocator)
  for _ in 0 ..< n {
    changed := false
    for i in 0 ..< n {
      if state[i] == 0 {
        continue // not reachable from the entry - placed separately below
      }
      m := ed_edges(ed, i, &edges)
      for e in edges[:m] {
        j, ok := idx_of[e.to]
        if !ok || back[{i, j}] || state[j] == 0 {
          continue
        }
        if rank[j] < rank[i] + 1 {
          rank[j] = rank[i] + 1
          changed = true
        }
      }
    }
    if !changed {
      break
    }
  }
  maxr := 0
  for i in 0 ..< n {
    if state[i] != 0 {
      maxr = max(maxr, rank[i])
    }
  }
  is_watcher := make([]bool, n, context.temp_allocator)
  ed_watcher_mask(ed, is_watcher)
  for i in 0 ..< n {
    if is_watcher[i] {
      rank[i] = 0 // ranked against its own watcher below, not against the chart
    } else if state[i] == 0 {
      rank[i] = maxr + 1 // orphaned: below everything, where it is visibly not part of the program
    }
  }
  // Watchers rank INSIDE the watcher band. A watcher is checked before every step, so "how far can
  // control get by here" - the question the main ranking answers - has no meaning for it; what does
  // have meaning is how far into its own body a node is. Same longest-path relaxation, own little graph.
  for _ in 0 ..< n {
    changed := false
    for i in 0 ..< n {
      if !is_watcher[i] {
        continue
      }
      m := ed_edges(ed, i, &edges)
      for e in edges[:m] {
        j, ok := idx_of[e.to]
        if !ok || !is_watcher[j] || back[{i, j}] {
          continue
        }
        if rank[j] < rank[i] + 1 {
          rank[j] = rank[i] + 1
          changed = true
        }
      }
    }
    if !changed {
      break
    }
  }

  // --- 3. bands, in the order the author DECLARED them.
  //
  // Not by their shallowest rank, which was the obvious choice and is wrong: `approach` fails straight
  // to `skip_target`, so "Give up on it" inherits a rank shallower than "Fight" and the reading order
  // came out Close in -> Give up on it -> Fight. Ranking answers "how far can control get by here",
  // which is not the same question as "which part of the algorithm is this". The section() calls are a
  // statement of the latter, and appending on first sight already records it - so this list is in the
  // right order with no sorting at all.
  bands := make([dynamic]Ed_Band, context.temp_allocator)
  // Watchers band FIRST, whatever order the nodes happen to sit in. They run before every step, so
  // above the program is where they belong - and putting them anywhere else is what let an `.On` node
  // end up sitting where the start node should be.
  for i in 0 ..< n {
    if is_watcher[i] {
      append(&bands, Ed_Band{name = ED_WATCH_BAND, first = i})
      break
    }
  }
  for i in 0 ..< n {
    g := ed_band_name_of(ed, i, is_watcher)
    found := false
    for bd in bands {
      if bd.name == g {
        found = true
        break
      }
    }
    if !found {
      append(&bands, Ed_Band{name = g, first = i})
    }
  }

  // --- 4. the rows each band needs, as its sorted distinct ranks
  brank := make([][dynamic]int, len(bands), context.temp_allocator)
  for bd, bi in bands {
    rs := make([dynamic]int, context.temp_allocator)
    for i in 0 ..< n {
      if ed_band_name_of(ed, i, is_watcher) == bd.name && !slice.contains(rs[:], rank[i]) {
        append(&rs, rank[i])
      }
    }
    slice.sort(rs[:])
    brank[bi] = rs
  }

  // --- 5. flow the bands into COLUMNS.
  //
  // A farm chart is mostly a chain - scan, try each rung, engage, fight, loop - so ranking it honestly
  // produces one node per row and a ribbon twenty rows tall. Fitting that into a landscape canvas means
  // zooming out until nothing is readable, with two thirds of the width empty.
  //
  // So bands wrap like newspaper columns. It only works because sections are explicit: a break between
  // two NAMED parts reads as "continued over there", where a break in the middle of one would just look
  // like the graph had been cut in half. Long edges across a column break are exactly the case the jump
  // chips already name.
  bcol := make([]int, len(bands), context.temp_allocator)
  ncol, rows_in_col := 0, 0
  for bi in 0 ..< len(bands) {
    r := len(brank[bi])
    if rows_in_col > 0 && rows_in_col + r > ED_COL_ROWS {
      ncol += 1
      rows_in_col = 0
    }
    bcol[bi] = ncol
    rows_in_col += r
  }

  // --- 6. place
  posx := make([]f32, n, context.temp_allocator)
  placed := make([]bool, n, context.temp_allocator)
  row := make([dynamic]int, context.temp_allocator)
  colx := f32(0)

  for c in 0 ..= ncol {
    y := f32(0)
    widest := 1
    first_band := true
    for bd, bi in bands {
      if bcol[bi] != c {
        continue
      }
      if !first_band {
        y += ED_BAND_GAP // room for the next band's label
      }
      first_band = false
      for r in brank[bi] {
        clear(&row)
        for i in 0 ..< n {
          if ed_band_name_of(ed, i, is_watcher) == bd.name && rank[i] == r {
            append(&row, i)
          }
        }
        ed_order_row(ed, row[:], posx, placed)
        widest = max(widest, len(row))
        cnt := f32(len(row))
        for i, k in row {
          posx[i] = colx + (f32(k) - (cnt - 1) * 0.5) * (ED_NODE_W + ED_GAP_X)
          placed[i] = true
          ed.doc.steps[i].ui_pos = {posx[i], y}
        }
        y += ED_NODE_H + ED_GAP_Y
      }
    }
    colx += f32(widest) * (ED_NODE_W + ED_GAP_X) + ED_COL_GAP
  }
  if mark_dirty {
    ed.dirty = true
  }
  ed.fit_req = true
}

// Sort one row by the average x of the parents that are already placed, so a node sits under whatever
// leads to it. A branch's arms are nudged apart - true left, false/fail right - because they are the
// one case where the parent's own position says nothing about which way its children should go.
@(private = "file")
ed_order_row :: proc(ed: ^Gui_Editor, row: []int, posx: []f32, placed: []bool) {
  if len(row) < 2 {
    return
  }
  key := make([]f32, len(row), context.temp_allocator)
  edges: [3]Ed_Edge
  for i, k in row {
    id := ed.doc.steps[i].id
    sum, cnt := f32(0), f32(0)
    for p in 0 ..< len(ed.doc.steps) {
      if !placed[p] {
        continue
      }
      m := ed_edges(ed, p, &edges)
      for e in edges[:m] {
        if e.to != id {
          continue
        }
        bias := f32(0)
        #partial switch e.kind {
        case .True:
          bias = -(ED_NODE_W + ED_GAP_X) * 0.5
        case .False, .Fail:
          bias = (ED_NODE_W + ED_GAP_X) * 0.5
        }
        sum += posx[p] + bias
        cnt += 1
      }
    }
    // No placed parent (an entry node, or one only reachable by a back edge): keep the order the
    // program was written in, which is at least stable across re-arranges.
    key[k] = cnt > 0 ? sum / cnt : f32(i) * 0.001
  }
  // Insertion sort: rows are a handful of nodes, and it keeps equal keys in program order.
  for a in 1 ..< len(row) {
    ki, vi := row[a], key[a]
    b := a - 1
    for b >= 0 && key[b] > vi {
      row[b + 1] = row[b]
      key[b + 1] = key[b]
      b -= 1
    }
    row[b + 1] = ki
    key[b + 1] = vi
  }
}

// The canvas-space box every node sits inside.
@(private = "file")
ed_bounds :: proc(ed: ^Gui_Editor) -> (lo, hi: [2]f32) {
  if len(ed.doc.steps) == 0 {
    return {}, {ED_NODE_W, ED_NODE_H}
  }
  lo = ed.doc.steps[0].ui_pos
  hi = lo + {ED_NODE_W, ED_NODE_H}
  banded := false
  for s in ed.doc.steps {
    lo[0] = min(lo[0], s.ui_pos[0])
    lo[1] = min(lo[1], s.ui_pos[1])
    hi[0] = max(hi[0], s.ui_pos[0] + ED_NODE_W)
    hi[1] = max(hi[1], s.ui_pos[1] + ED_NODE_H)
    banded ||= s.group != ""
  }
  // Section frames stand off their nodes and hang a label above the topmost one, so a fit computed
  // from the NODES alone crops the first band's title - the one thing the overview is for.
  if banded {
    lo -= {ED_BAND_PAD, ED_BAND_PAD + 30}
    hi += {ED_BAND_PAD, ED_BAND_PAD}
  }
  return
}

// Centre the view on everything. Only the CENTRING can be done here - fitting the zoom needs the size
// of the canvas rect, which is an ImGui content region and therefore not known until the frame is
// being drawn. So opening a chart asks for a fit (ed.fit_req) and gui_ed_canvas performs it.
@(private = "file")
ed_focus_all :: proc(ed: ^Gui_Editor) {
  lo, hi := ed_bounds(ed)
  ed.pan = (lo + hi) * 0.5
  ed.fit_req = true
}

// Zoom out (never in past 1:1) far enough to hold the whole chart, and centre on it. A chart you have
// to hunt around for is the same problem as a chart you cannot read - the first thing the editor owes
// you when it opens is the shape of the whole program.
@(private = "file")
ed_fit_view :: proc(ed: ^Gui_Editor, v: Ed_View) {
  lo, hi := ed_bounds(ed)
  ed.pan = (lo + hi) * 0.5
  us := gui_ui_scale()
  if v.size.x <= 0 || v.size.y <= 0 || us <= 0 {
    return
  }
  m := px(28) // breathing room, so the outermost node is not flush against the border
  w := (hi[0] - lo[0]) * us
  h := (hi[1] - lo[1]) * us
  if w <= 0 || h <= 0 {
    return
  }
  k := min((v.size.x - m) / w, (v.size.y - m) / h)
  ed.zoom = clamp(k, ED_ZOOM_MIN, 1)
}

// ===========================================================================
// Model edits
//
// Every one of these ends in ed_touch, because an edge is stored as a node IDENTITY and the walker
// reads a derived index. Re-resolving is the entire compile step and skipping it once is a program
// that jumps to where a node used to be.
// ===========================================================================

@(private = "file")
ed_touch :: proc(ed: ^Gui_Editor) {
  ed.dirty = true
  if ok, dangling := script_resolve_ids(ed.doc.steps[:]); !ok {
    ed_msg(ed, fmt.tprintf("an edge points at node %d, which no longer exists", u32(dangling)), true)
  }
}

@(private = "file")
ed_step :: proc(ed: ^Gui_Editor, id: Node_Id) -> ^Script_Step {
  if id == 0 {
    return nil
  }
  for &s in ed.doc.steps {
    if s.id == id {
      return &s
    }
  }
  return nil
}

@(private = "file")
ed_index :: proc(ed: ^Gui_Editor, id: Node_Id) -> int {
  for s, i in ed.doc.steps {
    if s.id == id {
      return i
    }
  }
  return -1
}

@(private = "file")
ed_next_id :: proc(ed: ^Gui_Editor) -> Node_Id {
  hi := Node_Id(0)
  for s in ed.doc.steps {
    hi = max(hi, s.id)
  }
  return hi + 1
}

// Rebuild a step's one-line label from its parsed form. src is presentation only and regenerated,
// never edited - the same rule bhv_deserialize follows, so a label can never disagree with its block.
@(private = "file")
ed_relabel :: proc(s: ^Script_Step) {
  delete(s.src)
  s.src = step_label(s^)
}

// Fill a fresh payload the way an omitted optional argument would be filled. Strings are CLONED
// rather than left as literals: script_step_free deletes them, and freeing rodata corrupts the heap.
@(private = "file")
ed_defaults :: proc(spec: []Param_Spec, nums: ^[4]f64, strs: ^[2]string) {
  for p, i in spec {
    num_slot, str_slot := param_slots(spec, i)
    switch p.kind {
    case .Num, .Duration, .Percent:
      nums[num_slot] = p.optional ? p.def : 0
    case .Coord:
      nums[num_slot] = 0
      nums[num_slot + 1] = 0
      strs[str_slot] = strings.clone("")
    case .Str, .Names, .Mob, .Key, .Var_Name, .Choice:
      strs[str_slot] = strings.clone("")
    }
  }
}

@(private = "file")
ed_set_action_kind :: proc(ed: ^Gui_Editor, s: ^Script_Step, kind: Script_Action_Kind, snapshot := true) {
  if snapshot {
    ed_snapshot(ed)
  }
  delete(s.action.strs[0])
  delete(s.action.strs[1])
  s.action = Script_Action {
    kind = kind,
  }
  if def := action_def(kind); def != nil {
    ed_defaults(def.params, &s.action.nums, &s.action.strs)
  }
  ed_relabel(s)
  ed.text_buffers_for_node = 0 // the payload moved under the inspector's buffers - reseed them
  ed.options_revision += 1 // ... and under the options panel's, which keeps one per node
  ed.dirty = true
}

@(private = "file")
ed_set_event_kind :: proc(ed: ^Gui_Editor, s: ^Script_Step, ev: ^Script_Event, kind: Script_Event_Kind, snapshot := true) {
  if snapshot {
    ed_snapshot(ed)
  }
  negate := ev.negate
  delete(ev.strs[0])
  delete(ev.strs[1])
  ev^ = Script_Event {
    kind   = kind,
    negate = negate,
  }
  if def := event_def(kind); def != nil {
    ed_defaults(def.params, &ev.nums, &ev.strs)
  }
  // s may be nil for a condition that labels no node; every caller today passes one.
  if s != nil {
    ed_relabel(s)
    ed.text_buffers_for_node = 0 // the payload moved under the inspector's buffers - reseed them
    ed.options_revision += 1 // ... and under the options panel's, which keeps one per node
  }
  ed.dirty = true
}

@(private = "file")
// WHERE A NEW NODE LANDS IN THE ARRAY - which is now only about how the chart READS, in `script show`
// and in the file, because control flow stopped depending on array order when documents started naming
// every successor (script_materialize_fallthrough). Adding a node cannot rewire an existing one at all.
//
// <after> keeps a spliced node next to the one it was spliced behind, so a chart written top to bottom
// still lists top to bottom. That is worth having and nothing breaks without it.
ed_add_node :: proc(ed: ^Gui_Editor, op: Script_Op, at: [2]f32, snapshot := true, after: Node_Id = 0) -> Node_Id {
  if snapshot {
    ed_snapshot(ed)
  }
  s := Script_Step {
    id     = ed_next_id(ed),
    op     = op,
    ui_pos = at,
  }
  if op == .Repeat || op == .Loop {
    s.count = 3
  }
  s.src = step_label(s)
  inject_at(&ed.doc.steps, ed_insert_index(ed, after), s)
  ed_touch(ed)
  return s.id
}

@(private = "file")
ed_insert_index :: proc(ed: ^Gui_Editor, after: Node_Id) -> int {
  if after != 0 {
    if i := ed_index(ed, after); i >= 0 {
      return i + 1
    }
  }
  return len(ed.doc.steps)
}

// Removing a node also removes every edge INTO it. Leaving them would produce a document that
// script_resolve_ids refuses, i.e. a chart that cannot be saved or run because of a node that is
// already gone - the failure would be reported nowhere near the delete that caused it.
@(private = "file")
ed_delete_node :: proc(ed: ^Gui_Editor, id: Node_Id, snapshot := true) {
  idx := ed_index(ed, id)
  if idx < 0 {
    return
  }
  if snapshot {
    ed_snapshot(ed)
  }
  for &s in ed.doc.steps {
    if s.goto_id == id {
      s.goto_id = 0
    }
    if s.else_id == id {
      s.else_id = 0
    }
  }
  if ed.doc.entry == id {
    ed.doc.entry = 0
  }
  script_step_free(&ed.doc.steps[idx])
  ordered_remove(&ed.doc.steps, idx)
  if ed.sel == id {
    ed.sel = 0
  }
  for v, i in ed.selset {
    if v == id {
      ordered_remove(&ed.selset, i)
      break
    }
  }
  ed_touch(ed)
}

// Everything selected, in one undoable step - deleting three nodes should cost one Ctrl+Z, not three.
@(private = "file")
ed_delete_selection :: proc(ed: ^Gui_Editor) {
  if len(ed.selset) == 0 {
    return
  }
  ed_snapshot(ed)
  ids := make([]Node_Id, len(ed.selset), context.temp_allocator)
  copy(ids, ed.selset[:])
  for id in ids {
    ed_delete_node(ed, id, snapshot = false)
  }
  ed_sel_only(ed, 0)
}

@(private = "file")
ed_wire :: proc(ed: ^Gui_Editor, from: Node_Id, port: int, to: Node_Id, snapshot := true) {
  s := ed_step(ed, from)
  if s == nil {
    return
  }
  if snapshot {
    ed_snapshot(ed)
  }
  if port == 1 {
    s.else_id = to
  } else {
    s.goto_id = to
  }
  ed_relabel(s) // goto / branch print their edges by node id
  ed_touch(ed)
}

// Drop a saved waypoint set into the OPEN chart as a chain of walk_to nodes - one node per waypoint,
// each in a section named after it, wired in order and ending unwired so the route runs once and stops.
// The chain is not attached to anything already on the canvas: where a route belongs in a chart is a
// decision, and guessing at it would produce edges nobody asked for.
//
// ONE ed_snapshot for the whole batch (every mutator below is called with snapshot = false), so a single
// Ctrl+Z takes back the import rather than one node of it - the same discipline ed_pal_create follows.
@(private = "file")
ed_import_waypoint_set :: proc(ed: ^Gui_Editor, set: Waypoint_Set) -> int {
  if len(set.waypoints) == 0 {
    return 0
  }
  ed_snapshot(ed)
  previous := Node_Id(0)
  for point, i in set.waypoints {
    id := ed_add_node(ed, .Action, {0, 0}, snapshot = false, after = previous)
    step := ed_step(ed, id)
    if step == nil {
      continue // unreachable: ed_add_node just inserted it
    }
    ed_set_action_kind(ed, step, .Walk_To, snapshot = false)
    // PARAMS_WALK_TO is a single .Coord, so the literal lives in the first two num slots and the
    // expression slot stays empty - the same encoding bhv_parse_params writes for a typed-in "x,z".
    step.action.nums[0] = f64(point.position[0])
    step.action.nums[1] = f64(point.position[1])
    delete(step.group)
    step.group = strings.clone(waypoint_label(set, i))
    ed_relabel(step)
    if previous != 0 {
      ed_wire(ed, previous, 0, id, snapshot = false)
    }
    previous = id
  }
  // Every imported node is at {0,0} until this runs; the layout pass ranks the new chain and gives each
  // section its own band, which is the whole reason the sections were stamped.
  ed_layout(ed)
  return len(set.waypoints)
}

// --- self-test: adding a node must not move anybody else's exit -------------------------------------
//
// This is here rather than in script_run.odin because it drives the editor's own private paths, and it
// exists because the bug it guards was invisible: appending a node handed the chart's LAST node a
// fall-through it never had, so creating a block silently rewired a block somewhere else. Nothing on
// the canvas draws array order, so the only way to notice was to run the chart and watch it go wrong.
//
// It still guards it now that documents name every successor, and it is worth keeping in that stronger
// form: it is the test that would fail if materialisation were ever skipped for editor-made nodes.
ed_selftest_insert :: proc() {
  fmt.println("  --- inserting a node ---")
  fails := 0

  // Where control leaves step <i>, by exactly the rule the walker uses (script_next_pc +
  // script_op_falls_through): a named successor, or - for the ops that still fall through - the next
  // array slot, else the program ends.
  successor :: proc(steps: []Script_Step, i: int) -> Node_Id {
    if steps[i].goto_id != 0 {
      return steps[i].goto_id
    }
    if script_op_falls_through(steps[i].op) && i + 1 < len(steps) {
      return steps[i + 1].id
    }
    return 0
  }
  check :: proc(what: string, got, want: Node_Id, fails: ^int) {
    if got != want {
      fmt.eprintfln("  FAIL: %s: went to #%d, expected #%d", what, u32(got), u32(want))
      fails^ += 1
    }
  }

  ed := Gui_Editor {
    doc = Behaviour_Doc{name = strings.clone("t_insert"), mode = .Once, steps = make([dynamic]Script_Step)},
  }
  defer gui_editor_free(&ed)

  // A -> B -> C, each edge NAMED, which is what every document holds now.
  a := ed_add_node(&ed, .Action, {0, 0}, snapshot = false)
  b := ed_add_node(&ed, .Action, {0, 1}, snapshot = false, after = a)
  c := ed_add_node(&ed, .Action, {0, 2}, snapshot = false, after = b)
  ed.doc.entry = a
  ed_wire(&ed, a, 0, b, snapshot = false)
  ed_wire(&ed, b, 0, c, snapshot = false)
  check("A", successor(ed.doc.steps[:], ed_index(&ed, a)), b, &fails)
  check("B", successor(ed.doc.steps[:], ed_index(&ed, b)), c, &fails)
  check("C ends the chart", successor(ed.doc.steps[:], ed_index(&ed, c)), 0, &fails)

  // THE REPORTED BUG. A free-standing node must leave all three alone - in particular C, which ends the
  // chart and used to acquire the new node as a successor purely by being last in the array.
  free_standing := ed_add_node(&ed, .Action, {9, 9}, snapshot = false)
  check("A after a free-standing add", successor(ed.doc.steps[:], ed_index(&ed, a)), b, &fails)
  check("B after a free-standing add", successor(ed.doc.steps[:], ed_index(&ed, b)), c, &fails)
  check("C after a free-standing add", successor(ed.doc.steps[:], ed_index(&ed, c)), 0, &fails)
  // ... and TWO nodes can now both be the end of the chart, which is the thing one overloaded value
  // made impossible: only whatever happened to be last in the array could end.
  check("the free-standing node also ends", successor(ed.doc.steps[:], ed_index(&ed, free_standing)), 0, &fails)

  // Splicing goes through the real palette path, so the old destination has to be carried onto the new
  // node rather than orphaned.
  ed.pal_at = {0, 0.5}
  ed.pal_wire = a
  ed.pal_port = 0
  ed.pal_after = a
  ed_pal_create(&ed, .Action, .Wait, .None)
  spliced := ed.sel
  check("A now -> the spliced node", successor(ed.doc.steps[:], ed_index(&ed, a)), spliced, &fails)
  check("the spliced node -> B", successor(ed.doc.steps[:], ed_index(&ed, spliced)), b, &fails)
  check("B still -> C", successor(ed.doc.steps[:], ed_index(&ed, b)), c, &fails)

  // A CUT STAYS CUT, even with a node sitting right behind it in the array. This is the "I can't tell
  // them otherwise" half of the report: before, cutting B's wire just handed it back C by adjacency.
  ed_wire(&ed, b, 0, 0, snapshot = false)
  check("B after cutting its wire", successor(ed.doc.steps[:], ed_index(&ed, b)), 0, &fails)
  if free_standing == 0 || spliced == 0 {
    fmt.eprintfln("  FAIL: a node was not created")
    fails += 1
  }

  if fails == 0 {
    fmt.println("  PASS: adding a node leaves every exit alone, splicing keeps both ends, a cut stays cut")
  }
}

// ===========================================================================
// Canvas <-> screen
// ===========================================================================

@(private = "file")
Ed_View :: struct {
  origin: imgui.Vec2, // top-left of the canvas rect, screen space
  size:   imgui.Vec2,
  mid:    imgui.Vec2,
  k:      f32, // canvas units -> pixels
}

// v.mid already carries the pan (see gui_ed_canvas), so this is a plain scale-and-offset.
@(private = "file")
ed_c2s :: proc(v: Ed_View, p: [2]f32) -> imgui.Vec2 {
  return {v.mid.x + p[0] * v.k, v.mid.y + p[1] * v.k}
}

@(private = "file")
ed_s2c :: proc(v: Ed_View, s: imgui.Vec2) -> [2]f32 {
  return {(s.x - v.mid.x) / v.k, (s.y - v.mid.y) / v.k}
}

@(private = "file")
ed_node_rect :: proc(v: Ed_View, s: Script_Step) -> (imgui.Vec2, imgui.Vec2) {
  a := ed_c2s(v, s.ui_pos)
  return a, {a.x + ED_NODE_W * v.k, a.y + ED_NODE_H * v.k}
}

// How many DRAGGABLE out ports a node has. Structured blocks get none: their edge names the matching
// End and is owned by the block's own nesting, so rewiring it on a canvas would desync the pair.
// They still DRAW their edges - you can see what an exported built-in does, you just cannot re-aim it.
//
// AN ACTION HAS TWO. A block that fails takes its else_id (script_take_fail_edge), and that edge is
// how the whole targeting ladder is wired: a rung that finds nothing hands over to the next one. The
// canvas used to give an action ONE port and ed_edges never emitted else_id for it, so every one of
// bh_auto's fail edges existed in the program and was drawn nowhere - the ladder, the thing the chart
// is mostly made of, was invisible. Port 0 is "done", port 1 is "failed".
@(private = "file")
ed_out_ports :: proc(op: Script_Op) -> int {
  #partial switch op {
  case .Goto, .On:
    return 1
  case .Action, .Wait_For, .Branch, .Loop:
    return 2
  }
  return 0
}

// port -1 = the in port (top centre); 0/1 = out ports along the bottom.
@(private = "file")
ed_port_pos :: proc(v: Ed_View, s: Script_Step, port: int) -> imgui.Vec2 {
  a, b := ed_node_rect(v, s)
  if port < 0 {
    return {(a.x + b.x) * 0.5, a.y}
  }
  if ed_out_ports(s.op) == 2 {
    return {a.x + (b.x - a.x) * (port == 0 ? 0.30 : 0.70), b.y}
  }
  return {(a.x + b.x) * 0.5, b.y}
}

// ===========================================================================
// Edges
// ===========================================================================

@(private = "file")
Ed_Edge_Kind :: enum {
  Seq, // implicit: the next slot in the array (script_next_pc's fall-through)
  Next,
  True,
  False,
  Fail, // an action's else_id - taken when the block reports .Failed
  Skip, // a block head to just past its matching End
  Loop, // an End back to its head
}

@(private = "file")
Ed_Edge :: struct {
  to:   Node_Id,
  kind: Ed_Edge_Kind,
  port: int, // out port it leaves from; -1 = no port (implicit or structural)
}

// Every edge leaving step <i>, exactly as the walker would take it. This is the single description
// the drawing, the hit-testing and the inspector all read, so what you see is what runs.
@(private = "file")
ed_edges :: proc(ed: ^Gui_Editor, i: int, out: ^[3]Ed_Edge) -> int {
  s := ed.doc.steps[i]
  seq := Node_Id(0)
  if i + 1 < len(ed.doc.steps) {
    seq = ed.doc.steps[i + 1].id
  }
  n := 0
  switch s.op {
  case .Action, .Wait_For:
    // No .Seq fallback: these two do not fall through any more. Every fall-through a document ever had
    // was named when the document was created (script_materialize_fallthrough), so no successor here
    // means the program ends - which is now a thing a node can SAY, rather than something you inferred
    // from being last in an array the canvas never drew.
    if s.goto_id != 0 {
      out[n] = {s.goto_id, .Next, 0}
      n += 1
    }
    // The fail edge. Unwired it is not "fall through" - script_take_fail_edge ends the run - so
    // there is deliberately no Seq fallback here the way port 0 has one.
    if s.else_id != 0 {
      out[n] = {s.else_id, .Fail, 1}
      n += 1
    }
  case .Goto:
    if s.goto_id != 0 {
      out[n] = {s.goto_id, .Next, 0}
      n += 1
    }
  case .Branch:
    if s.goto_id != 0 {
      out[n] = {s.goto_id, .True, 0}
      n += 1
    }
    if s.else_id != 0 {
      out[n] = {s.else_id, .False, 1}
      n += 1
    }
  case .Loop:
    // Port 0 is the body and is drawn as a LOOP edge, not a Next: it is the edge you follow N times,
    // and colouring it like an ordinary successor would hide the only interesting thing about the node.
    if s.goto_id != 0 {
      out[n] = {s.goto_id, .Loop, 0}
      n += 1
    }
    if s.else_id != 0 {
      out[n] = {s.else_id, .Next, 1}
      n += 1
    }
  case .If, .While, .Repeat:
    if seq != 0 {
      out[n] = {seq, .Seq, -1} // the body
      n += 1
    }
    if s.goto_id != 0 {
      out[n] = {s.goto_id, .Skip, -1} // the matching End - control resumes just past it
      n += 1
    }
  case .Else:
    if s.goto_id != 0 {
      out[n] = {s.goto_id, .Skip, -1}
      n += 1
    }
  case .End:
    if s.close == .If {
      if seq != 0 {
        out[n] = {seq, .Seq, -1}
        n += 1
      }
    } else if s.goto_id != 0 {
      out[n] = {s.goto_id, .Loop, -1}
      n += 1
    }
  case .On:
    // A watcher is hoisted out of the instruction stream, so it has no place in the chart's flow - but
    // it DOES own a body, and that edge is the whole reason it is a node rather than a checkbox.
    if s.goto_id != 0 {
      out[n] = {s.goto_id, .Next, 0}
      n += 1
    }
  case .Return:
  // ends an interrupt region; control resumes where the main program was suspended
  }
  return n
}

// Every edge INTO <id>, as {source index, edge}. The edge model is stored on the source node, so this
// is the only way to answer "what leads here" - and "what leads here" is half of understanding any
// node in a graph that loops back on itself as much as a farm chart does.
@(private = "file")
ed_edges_into :: proc(ed: ^Gui_Editor, id: Node_Id, allocator := context.temp_allocator) -> [dynamic]Ed_Edge_In {
  out := make([dynamic]Ed_Edge_In, allocator)
  edges: [3]Ed_Edge
  for i in 0 ..< len(ed.doc.steps) {
    n := ed_edges(ed, i, &edges)
    for e in edges[:n] {
      if e.to == id {
        append(&out, Ed_Edge_In{from = ed.doc.steps[i].id, kind = e.kind})
      }
    }
  }
  return out
}

@(private = "file")
Ed_Edge_In :: struct {
  from: Node_Id,
  kind: Ed_Edge_Kind,
}

// The node under focus plus everything one edge away from it, in either direction. Drawing dims
// whatever is not in here - which is the whole trick for reading a dense graph: you never need to
// trace a wire through the tangle, because the tangle stops being drawn at full strength.
@(private = "file")
ed_focus_ring :: proc(ed: ^Gui_Editor, focus: Node_Id, allocator := context.temp_allocator) -> map[Node_Id]bool {
  ring := make(map[Node_Id]bool, allocator)
  if focus == 0 {
    return ring
  }
  ring[focus] = true
  edges: [3]Ed_Edge
  for i in 0 ..< len(ed.doc.steps) {
    id := ed.doc.steps[i].id
    n := ed_edges(ed, i, &edges)
    for e in edges[:n] {
      if id == focus {
        ring[e.to] = true
      }
      if e.to == focus {
        ring[id] = true
      }
    }
  }
  return ring
}

ED_DIM :: f32(0.22) // how much of its colour a node keeps when something else has the focus

@(private = "file")
ed_edge_color :: proc(kind: Ed_Edge_Kind) -> imgui.Vec4 {
  switch kind {
  case .Seq:
    return tint(COL_TEXT_DIM, 0.55)
  case .Next:
    return tint(COL_ACCENT, 0.85)
  case .True:
    return tint(COL_OK, 0.9)
  case .False:
    return tint(COL_BAD, 0.85)
  case .Fail:
    return tint(COL_BAD, 0.7) // the same idea as a branch's false arm, one shade back
  case .Skip:
    return tint(COL_WARN, 0.7)
  case .Loop:
    return tint(COL_WARN, 0.9)
  }
  return COL_TEXT_DIM
}

// COLOUR SAYS WHAT A NODE IS ABOUT; THE ICON SAYS HOW CONTROL LEAVES IT.
//
// It used to be one thing: colour keyed off Script_Op, which meant all 38 action kinds shared one
// accent and the chart was a wall of identical blue boxes. The op is the poorer of the two signals
// here - it is already legible from the node's ports and its title - so colour now carries the block's
// CATEGORY, and the shape of control flow moved to the icon. Both survive a zoom-out that eats the text.
@(private = "file")
ed_cat_color :: proc(cat: Block_Cat) -> imgui.Vec4 {
  switch cat {
  case .Flow:
    return imgui.Vec4{0.639, 0.522, 0.886, 1} // purple
  case .Sense:
    return imgui.Vec4{0.353, 0.780, 0.760, 1} // teal
  case .Target:
    return COL_WARN // amber
  case .Move:
    return COL_ACCENT // blue
  case .Combat:
    return imgui.Vec4{0.878, 0.400, 0.361, 1} // warm red, a shade off COL_BAD so a fail wire stays distinct
  case .Timing:
    return imgui.Vec4{0.520, 0.600, 0.700, 1} // slate
  case .Vars:
    return COL_OK // green
  case .System:
    return imgui.Vec4{0.941, 0.560, 0.220, 1} // orange
  }
  return COL_TEXT_DIM
}

@(private = "file")
ed_cat_icon :: proc(cat: Block_Cat) -> rune {
  switch cat {
  case .Flow:
    return ICON_CAT_FLOW
  case .Sense:
    return ICON_CAT_SENSE
  case .Target:
    return ICON_CAT_TARGET
  case .Move:
    return ICON_CAT_MOVE
  case .Combat:
    return ICON_CAT_COMBAT
  case .Timing:
    return ICON_CAT_TIMING
  case .Vars:
    return ICON_CAT_VARS
  case .System:
    return ICON_CAT_SYSTEM
  }
  return ICON_CAT_FLOW
}

@(private = "file")
ed_node_color :: proc(s: Script_Step) -> imgui.Vec4 {
  // The structured family keeps one muted colour: they are the shape an Odin behaviour arrives in,
  // scaffolding rather than a step that does something, and colouring them competes with the blocks.
  #partial switch s.op {
  case .If, .Else, .End, .Repeat, .While:
    return COL_TEXT_DIM
  }
  return ed_cat_color(block_cat(s))
}

// An action is what it does; everything else is what it does to CONTROL, which is the more useful
// thing to recognise about it from across the canvas.
@(private = "file")
ed_node_icon :: proc(s: Script_Step) -> rune {
  #partial switch s.op {
  case .Branch, .If, .Else:
    return ICON_CAT_FLOW // a split
  case .While, .Repeat, .Loop:
    return ICON_REPLAY // a loop
  case .Wait_For:
    return ICON_CAT_TIMING
  case .On:
    return ICON_CAT_SENSE // a watcher, off to the side of the program
  case .Goto:
    return ICON_STEP
  case .Return:
    return ICON_REPLAY
  case .End:
    return ICON_STOP
  }
  return ed_cat_icon(block_cat(s))
}

// ===========================================================================
// Jump chips
//
// A wire whose far end is off-screen tells you a jump exists and nothing about where it goes; you
// pan, lose the source, pan back. So an off-screen target also gets a CHIP at the port naming the
// node it lands on - and clicking the chip takes you there. This is the piece that makes a chart with
// back-edges navigable instead of merely honest.
// ===========================================================================

@(private = "file")
Ed_Chip :: struct {
  a, b:  imgui.Vec2, // screen rect
  to:    Node_Id,
  kind:  Ed_Edge_Kind,
  label: string, // temp-allocated
}

@(private = "file")
ed_rect_offscreen :: proc(v: Ed_View, s: Script_Step) -> bool {
  a, b := ed_node_rect(v, s)
  return b.x < v.origin.x || a.x > v.origin.x + v.size.x || b.y < v.origin.y || a.y > v.origin.y + v.size.y
}

// Computed BEFORE the gesture block rather than during drawing, because a chip has to be clickable and
// the click is decided at press time - the draw pass happens far too late to claim it.
@(private = "file")
ed_chips :: proc(ed: ^Gui_Editor, v: Ed_View, allocator := context.temp_allocator) -> [dynamic]Ed_Chip {
  out := make([dynamic]Ed_Chip, allocator)
  fs := imgui.GetFontSize() * ed.zoom * 0.78
  if fs < 7 {
    return out // zoomed out far enough that the whole graph is visible anyway; chips would be noise
  }
  edges: [3]Ed_Edge
  for i in 0 ..< len(ed.doc.steps) {
    s := ed.doc.steps[i]
    if ed_rect_offscreen(v, s) {
      continue // the SOURCE is off-screen too, so there is nothing on screen to hang a chip off
    }
    n := ed_edges(ed, i, &edges)
    for e in edges[:n] {
      t := ed_step(ed, e.to)
      if t == nil || !ed_rect_offscreen(v, t^) {
        continue
      }
      label := fmt.tprintf("%s %s", ed_edge_word(e.kind, s.op), block_title(t^))
      cs := ed_fit(label, fs, ED_NODE_W * v.k * 0.95)
      w := imgui.CalcTextSize(cs).x * (fs / imgui.GetFontSize()) + px(10) * ed.zoom
      h := fs + px(6) * ed.zoom
      p := ed_port_pos(v, s, max(e.port, 0))
      // A two-port node's chips are STACKED, not squeezed side by side: the ports are only 40% of the
      // node's width apart, so fitting both on one row means truncating each to a stub, and "true
      // Count the k" names nothing. A second row costs vertical space the gap between nodes already has.
      a := imgui.Vec2{p.x - w * 0.5, p.y + px(7) * ed.zoom + f32(max(e.port, 0)) * (h + px(3) * ed.zoom)}
      append(&out, Ed_Chip{a = a, b = {a.x + w, a.y + h}, to = e.to, kind = e.kind, label = string(cs)})
    }
  }
  return out
}

@(private = "file")
ed_chip_at :: proc(chips: [dynamic]Ed_Chip, p: imgui.Vec2) -> Node_Id {
  #reverse for c in chips {
    if p.x >= c.a.x && p.x <= c.b.x && p.y >= c.a.y && p.y <= c.b.y {
      return c.to
    }
  }
  return 0
}

// Centre the view on a node without changing the zoom - "take me there", not "reframe everything".
@(private = "file")
ed_go_to :: proc(ed: ^Gui_Editor, id: Node_Id) {
  t := ed_step(ed, id)
  if t == nil {
    return
  }
  ed.pan = t.ui_pos + {ED_NODE_W * 0.5, ED_NODE_H * 0.5}
  ed_sel_only(ed, id)
}

// ===========================================================================
// Hit-testing a wire
//
// The complaint this answers: a wire could be drawn, followed and read, and the only way to REMOVE one
// was to select its source node and find the "clear" button in the inspector's Flow rows - which means
// knowing which end of a wire owns it, on a canvas where the whole point is that you can see both ends.
//
// It walks the same ed_edges description the drawing reads and samples the same cubic ed_bezier draws,
// so what you can click is exactly what you can see. Anything else and the two would drift the first
// time a curve's control points were tuned.
// ===========================================================================

ED_EDGE_SAMPLES :: 24 // enough that the chords are shorter than the grab radius at any sane zoom
ED_EDGE_GRAB :: f32(6) // px

// Which wire, if any, is under <mp>. Nearest wins, so two wires crossing under the cursor resolve to
// the one actually being pointed at rather than to whichever came first in the array.
@(private = "file")
ed_hit_edge :: proc(ed: ^Gui_Editor, v: Ed_View, mp: imgui.Vec2) -> (from: Node_Id, port: int, kind: Ed_Edge_Kind, ok: bool) {
  grab := max(ED_EDGE_GRAB * gui_ui_scale(), 4)
  best := grab * grab // compare squared distances; nothing needs the actual length
  edges: [3]Ed_Edge
  for i in 0 ..< len(ed.doc.steps) {
    s := ed.doc.steps[i]
    n := ed_edges(ed, i, &edges)
    for e in edges[:n] {
      t := ed_step(ed, e.to)
      if t == nil {
        continue
      }
      a := ed_port_pos(v, s, e.port >= 0 ? e.port : 0)
      b := ed_port_pos(v, t^, -1)
      if d := ed_bezier_dist_sq(a, b, mp, max(px(2) * ed.zoom, 1.2)); d < best {
        best = d
        from, port, kind, ok = s.id, e.port, e.kind, true
      }
    }
  }
  return
}

// Squared distance from <p> to the curve ed_bezier would draw between <a> and <b>. Sampled rather than
// solved: the exact nearest point on a cubic is a quartic root-find, and 24 chords is well inside a
// 6px grab radius for anything the canvas actually draws.
@(private = "file")
ed_bezier_dist_sq :: proc(a, b, p: imgui.Vec2, thick: f32) -> f32 {
  c1, c2 := ed_bezier_controls(a, b, thick)
  best := max(f32)
  prev := a
  for i in 1 ..= ED_EDGE_SAMPLES {
    t := f32(i) / f32(ED_EDGE_SAMPLES)
    u := 1 - t
    // The Bernstein form, matching DrawList_AddBezierCubic's own parameterisation.
    cur := imgui.Vec2 {
      u * u * u * a.x + 3 * u * u * t * c1.x + 3 * u * t * t * c2.x + t * t * t * b.x,
      u * u * u * a.y + 3 * u * u * t * c1.y + 3 * u * t * t * c2.y + t * t * t * b.y,
    }
    if d := ed_seg_dist_sq(prev, cur, p); d < best {
      best = d
    }
    prev = cur
  }
  return best
}

// The two control points ed_bezier uses. Factored out of it so the drawing and the hit-testing cannot
// disagree about the shape of a wire - which is the same rule ed_edges follows for which wires exist.
@(private = "file")
ed_bezier_controls :: proc(a, b: imgui.Vec2, thick: f32) -> (c1, c2: imgui.Vec2) {
  dy := b.y - a.y
  d := clamp(abs(dy) * 0.5, thick * 10, thick * 60)
  if dy > thick * 8 {
    return {a.x, a.y + d}, {b.x, b.y - d}
  }
  side := b.x < a.x ? f32(-1) : f32(1)
  off := max(abs(b.x - a.x) * 0.5, thick * 55)
  return {a.x + side * off, a.y + d}, {b.x + side * off, b.y - d}
}

@(private = "file")
ed_seg_dist_sq :: proc(a, b, p: imgui.Vec2) -> f32 {
  dx, dy := b.x - a.x, b.y - a.y
  len_sq := dx * dx + dy * dy
  t := f32(0)
  if len_sq > 0 {
    t = clamp(((p.x - a.x) * dx + (p.y - a.y) * dy) / len_sq, 0, 1)
  }
  qx, qy := a.x + t * dx - p.x, a.y + t * dy - p.y
  return qx * qx + qy * qy
}

// Which wires can be cut at all. Two cannot, and both REFUSE WITH A REASON rather than going dead under
// the cursor - a control that silently does nothing reads as broken:
//
//   .Seq  is not stored anywhere. It IS array order - "the node after me in the file" - so there is no
//         field to clear. You change it by naming an explicit successor, which replaces it.
//   the structural edges of a lowered If/Repeat/While pair (.Skip, .Loop) belong to the pair's nesting,
//         and re-aiming one would desync it from its partner. ed_out_ports already returns 0 for those.
@(private = "file")
ed_edge_cuttable :: proc(kind: Ed_Edge_Kind) -> bool {
  #partial switch kind {
  case .Seq, .Skip, .Loop:
    return false
  }
  return true
}

// Can a node be dropped INTO this edge? A wider set than cuttable, and the difference is the point: a
// fall-through cannot be re-aimed, but a node can be put in the middle of one - that is nothing but an
// array insert, since fall-through is array position. What stays out is the structured pair
// (.Skip/.Loop), where the two ends and the order between them are one block's business.
@(private = "file")
ed_edge_spliceable :: proc(kind: Ed_Edge_Kind) -> bool {
  #partial switch kind {
  case .Skip, .Loop:
    return false
  }
  return true
}

// Where an edge LANDS. Every kind but .Seq names its destination on the node; .Seq is the array
// successor, which is exactly the thing that is nowhere on screen.
@(private = "file")
ed_edge_destination :: proc(ed: ^Gui_Editor, from: Node_Id, port: int, kind: Ed_Edge_Kind) -> Node_Id {
  s := ed_step(ed, from)
  if s == nil {
    return 0
  }
  if kind == .Seq {
    i := ed_index(ed, from)
    if i >= 0 && i + 1 < len(ed.doc.steps) {
      return ed.doc.steps[i + 1].id
    }
    return 0
  }
  return port == 1 ? s.else_id : s.goto_id
}

@(private = "file")
ed_edge_uncuttable_why :: proc(kind: Ed_Edge_Kind) -> string {
  #partial switch kind {
  case .Seq:
    return "this is fall-through, not a wire - it just means \"whatever comes next\". Drag from the port to name a successor instead, or use a 'Stop the run' node to end the chart here."
  case .Skip, .Loop:
    return "this edge belongs to a block and its matching end - re-aiming it would split the pair."
  }
  return ""
}

// The wire context menu. Cut is also a plain left-click; it is repeated here because a menu that only
// offered the two rarer things would read as though clicking did something else.
@(private = "file")
gui_ed_edge_menu :: proc(ed: ^Gui_Editor) {
  if !imgui.BeginPopup("##ededgectx") {
    return
  }
  defer imgui.EndPopup()
  s := ed_step(ed, ed.ctx_edge_from)
  if s == nil {
    return
  }
  to := ed_edge_destination(ed, ed.ctx_edge_from, ed.ctx_edge_port, ed.ctx_edge_kind)
  t := ed_step(ed, to)
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted(fmt.ctprintf(
    "%s  --%s->  %s",
    block_title(s^), ed_edge_word(ed.ctx_edge_kind, s.op), t == nil ? "(nowhere)" : block_title(t^),
  ))
  imgui.PopStyleColor(1)
  imgui.Separator()

  // INSERT, offered ABOVE the cut check on purpose: it is the one thing that also works on a
  // fall-through, and "I need a node between these two" is the reason people right-click a wire. It
  // used to be three operations in the right order (create, re-aim the old wire, wire the new node on),
  // with an appended node quietly stealing somebody's exit in the middle of it.
  if ed_edge_spliceable(ed.ctx_edge_kind) {
    if imgui.Selectable("Insert a node here") {
      at := s.ui_pos + {ED_NODE_W + px(30) / max(ed.zoom, 0.01), 0}
      if t != nil {
        at = (s.ui_pos + t.ui_pos) * 0.5
      }
      ed.pal_at = at
      ed.pal_after = ed.ctx_edge_from
      // A fall-through has no wire to re-aim - the array insert IS the edit, so nothing is wired and
      // the chart stays exactly as explicit as it already was.
      ed.pal_wire = ed.ctx_edge_kind == .Seq ? 0 : ed.ctx_edge_from
      ed.pal_port = ed.ctx_edge_port
      ed.pal_req = true
      imgui.CloseCurrentPopup()
      return
    }
    if imgui.IsItemHovered() {
      imgui.SetTooltip(
        "%s",
        t == nil \
        ? "Add a node on the end of this one" \
        : fmt.ctprintf("Put a new node between %s and %s, wired to both", block_title(s^), block_title(t^)),
      )
    }
  }

  if !ed_edge_cuttable(ed.ctx_edge_kind) {
    imgui.PushStyleColorImVec4(.Text, COL_WARN)
    imgui.TextUnformatted(fmt.ctprintf("%s", ed_edge_uncuttable_why(ed.ctx_edge_kind)))
    imgui.PopStyleColor(1)
    return
  }
  if imgui.Selectable("Cut this wire") {
    ed_wire(ed, ed.ctx_edge_from, ed.ctx_edge_port, 0)
  }
  if t != nil && imgui.Selectable("Go to where it lands") {
    ed_go_to(ed, to)
  }
  if imgui.Selectable("Select both ends") {
    ed_sel_only(ed, ed.ctx_edge_from)
    if t != nil {
      ed_sel_toggle(ed, to)
    }
  }
}

// ===========================================================================
// Drawing helpers
// ===========================================================================

// Text at an explicit size, so node labels scale with the canvas zoom instead of staying pinned to
// the UI font. GetFont() is the merged UI+icons face, the same one every other widget draws with.
@(private = "file")
ed_text :: proc(dl: ^imgui.DrawList, pos: imgui.Vec2, size: f32, col: imgui.Vec4, s: cstring) {
  if size < 5 {
    return // below this it is a grey smear; leave it out rather than draw noise
  }
  imgui.DrawList_AddTextImFontPtr(dl, imgui.GetFont(), size, pos, u32_of(col), s)
}

// Trim <s> from the right until it fits <maxw> pixels when drawn at <size>.
@(private = "file")
ed_fit :: proc(s: string, size: f32, maxw: f32) -> cstring {
  scale := size / imgui.GetFontSize()
  out := fmt.ctprintf("%s", s)
  if imgui.CalcTextSize(out).x * scale <= maxw {
    return out
  }
  for n := len(s) - 1; n > 0; n -= 1 {
    out = fmt.ctprintf("%s...", s[:n])
    if imgui.CalcTextSize(out).x * scale <= maxw {
      return out
    }
  }
  return ""
}

// Every wire leaves the bottom of a node and enters the top of another, so a FORWARD edge is a plain
// vertical S. A BACKWARD one - which is how a loop is drawn, and therefore the case that matters most
// - has to be routed differently: with vertical control points it folds through its own source and
// comes out as an unreadable knot instead of a curve. Bulging it sideways gives the eye something to
// follow all the way round.
@(private = "file")
// <shape_thick> is what the control points are derived from, and it defaults to the drawn thickness.
// The hovered wire passes the UNTHICKENED value: without that, fattening the line would also move the
// curve, so a wire would slide out from under the cursor at the moment you aimed at it.
ed_bezier :: proc(dl: ^imgui.DrawList, a, b: imgui.Vec2, col: imgui.Vec4, thick: f32, shape_thick: f32 = 0) {
  c1, c2 := ed_bezier_controls(a, b, shape_thick > 0 ? shape_thick : thick)
  imgui.DrawList_AddBezierCubic(dl, a, c1, c2, b, u32_of(col), thick, 0)
}

// ===========================================================================
// The frame
// ===========================================================================

gui_node_editor :: proc(ps: ^Panel_State, f: ^Gui_Frame) {
  ed := &ps.ed
  vp := imgui.GetMainViewport()
  imgui.DrawList_AddRectFilled(
    imgui.GetBackgroundDrawList(),
    vp.Pos,
    {vp.Pos.x + vp.Size.x, vp.Pos.y + vp.Size.y},
    u32_of({0.02, 0.03, 0.04, 0.72}),
  )
  m := px(20)
  imgui.SetNextWindowPos({vp.Pos.x + m, vp.Pos.y + m}, .Always)
  imgui.SetNextWindowSize({vp.Size.x - 2 * m, vp.Size.y - 2 * m}, .Always)

  // ### keeps the window's identity stable while the visible title changes with the name and the
  // dirty marker - without it ImGui would treat every rename as a brand new window.
  title := fmt.ctprintf("%s%s###bhvedit", ed.doc.name == "" ? "(unnamed)" : ed.doc.name, ed.dirty ? "  *" : "")
  open := true
  if imgui.Begin(title, &open, {.NoResize, .NoMove, .NoCollapse, .NoSavedSettings, .NoDocking}) {
    // ONCE per frame, into temp, and handed to everything that reads it - see the note on
    // Gui_Editor.tab_problems for why this is not cached on the struct.
    problems := script_lint(&ed.doc)
    gui_ed_toolbar(ps, ed, f, problems)
    // Two lines: the wire key and the node-colour key. Sized from the font rather than a constant so
    // it still clears the text at any ui_scale. The trace strip, when open, takes a third of the height
    // off the canvas rather than off the window - the inspector beside it keeps its full run.
    footer := 2 * imgui.GetTextLineHeightWithSpacing() + px(6)
    canvas_w := -px(ED_INSPECTOR_W) - px(8)
    canvas_h := -footer
    if ed.trace_open {
      // A NEGATIVE child height means "the space available minus this", so the fraction here is the
      // share the LOG gets, not the canvas. Getting that backwards gave the empty log strip more room
      // than the graph it is explaining.
      canvas_h = -(imgui.GetContentRegionAvail().y - footer) * 0.36
    }
    // The canvas and the strip under it are ONE group, so the inspector SameLine's against the pair
    // rather than landing beneath the strip.
    imgui.BeginGroup()
    if imgui.BeginChild("##canvas", {canvas_w, canvas_h}, {.Borders}) {
      gui_ed_canvas(ps, ed, f, problems)
    }
    imgui.EndChild()
    if ed.trace_open {
      if imgui.BeginChild("##trace", {canvas_w, -footer}, {.Borders}) {
        gui_ed_trace(ps, ed, f)
      }
      imgui.EndChild()
    }
    imgui.EndGroup()
    imgui.SameLine(0, px(8))
    if imgui.BeginChild("##inspector", {0, -footer}, {.Borders}) {
      // Two tabs over one pane. "Node" is the canvas's companion - what you clicked. "Chart options"
      // is the whole document's settings in one scroll, and it is the answer to "where do I configure
      // this thing": tuning a chart should never require FINDING the node that happens to hold the
      // number. Both are drawn by the same spec-driven renderer, only at different densities.
      if imgui.BeginTabBar("##edtabs") {
        options_tab_flags: imgui.TabItemFlags
        if ed.tab_options {
          options_tab_flags += {.SetSelected} // a one-shot request from the browser's Configure... entry
          ed.tab_options = false
        }
        // Each tab's body gets its OWN scrolling child, sized to fill what is left. Without that the
        // outer child scrolls instead and takes the tab bar off the top of the screen with it - you
        // scroll down to read a setting and lose the way back to the canvas's node view.
        if imgui.BeginTabItem("Node") {
          if imgui.BeginChild("##nodebody", {0, 0}) {
            gui_ed_inspector(ps, ed, f)
          }
          imgui.EndChild()
          imgui.EndTabItem()
        }
        if imgui.BeginTabItem("Chart options", nil, options_tab_flags) {
          gui_ed_options(ps, ed, f)
          imgui.EndTabItem()
        }
        problems_tab_flags: imgui.TabItemFlags
        if ed.tab_problems {
          problems_tab_flags += {.SetSelected} // a one-shot request from the toolbar badge
          ed.tab_problems = false
        }
        // The COUNT is in the tab label, so the tab itself is the notification - you do not have to open
        // it to learn there is nothing to open it for.
        errors := script_lint_count(problems, .Error)
        warnings := script_lint_count(problems, .Warning)
        label := errors + warnings == 0 ? "Problems" : fmt.ctprintf("Problems (%d)", errors + warnings)
        if imgui.BeginTabItem(label, nil, problems_tab_flags) {
          if imgui.BeginChild("##problembody", {0, 0}) {
            gui_ed_problems(ed, problems)
          }
          imgui.EndChild()
          imgui.EndTabItem()
        }
        imgui.EndTabBar()
      }
    }
    imgui.EndChild()
    gui_ed_legend(ed)
  }
  imgui.End()
  if !open {
    gui_editor_close(ps)
  }
}

// --- toolbar ---------------------------------------------------------------------------------------

// How many DISTINCT blocks in the open chart cannot run right now, and the first reason. Deliberately
// NOT part of script_lint: the linter answers questions about the DOCUMENT, and "the game is not
// attached" is a fact about this minute that would make every chart light up with warnings the moment
// you closed the client. This is a toolbar readout instead, computed from the same Gui_Frame
// runnability snapshot the palette greys with.
@(private = "file")
ed_run_blockers :: proc(ed: ^Gui_Editor, f: ^Gui_Frame) -> (count: int, first_why: string) {
  seen_actions: bit_set[Script_Action_Kind]
  seen_events: bit_set[Script_Event_Kind]
  note_event :: proc(ev: Script_Event, f: ^Gui_Frame, seen: ^bit_set[Script_Event_Kind], count: ^int, first_why: ^string) {
    if ev.kind == .None || ev.kind in seen^ {
      return
    }
    seen^ += {ev.kind}
    if f.event_usable[ev.kind] {
      return
    }
    count^ += 1
    if first_why^ == "" {
      first_why^ = f.event_why_not[ev.kind]
    }
  }
  for s in ed.doc.steps {
    if s.action.kind != .None && s.action.kind not_in seen_actions {
      seen_actions += {s.action.kind}
      if !f.action_usable[s.action.kind] {
        count += 1
        if first_why == "" {
          first_why = f.action_why_not[s.action.kind]
        }
      }
    }
    for i in 0 ..< condition_row_count(s.condition) {
      note_event(condition_row(s.condition, i), f, &seen_events, &count, &first_why)
    }
    if s.has_until {
      note_event(s.until, f, &seen_events, &count, &first_why)
    }
  }
  return
}

@(private = "file")
gui_ed_toolbar :: proc(ps: ^Panel_State, ed: ^Gui_Editor, f: ^Gui_Frame, problems: []Chart_Problem) {
  running := f.script_active && f.script_name == ed.doc.name

  imgui.SetNextItemWidth(px(190))
  imgui.InputTextWithHint("##edname", "chart name", cstring(raw_data(ed.name_buf[:])), len(ed.name_buf))
  name := strings.trim_space(panel_buf_str(ed.name_buf[:]))
  if imgui.IsItemHovered() {
    imgui.SetTooltip("The file this saves to. Typing a different name here is a SAVE AS - use the browser's Rename to rename.")
  }

  // The chart/interrupt combo is GONE. There is one kind of document now: what made a file "an
  // interrupt" was a header, and what makes one now is its content - a watcher node, which you add
  // from the palette like anything else. A document that is nothing BUT watchers says so here, because
  // its play button would otherwise look broken rather than inapplicable.
  watchers_only := ed_watchers_only(ed)
  if watchers_only {
    imgui.SameLine(0, px(8))
    imgui.PushStyleColorImVec4(.Text, COL_WARN)
    imgui.TextUnformatted("watchers only")
    imgui.PopStyleColor(1)
    if imgui.IsItemHovered() {
      imgui.SetTooltip("No start node, so there is nothing to run from the top. Arm it below, or let a chart borrow it from its options tab.")
    }
  }

  imgui.SameLine(0, px(8))
  imgui.SetNextItemWidth(px(96))
  if imgui.BeginCombo("##edmode", ed.doc.mode == .Loop ? "loop" : "once") {
    if imgui.Selectable("once", ed.doc.mode == .Once) {
      ed.doc.mode = .Once
      ed.dirty = true
    }
    if imgui.Selectable("loop", ed.doc.mode == .Loop) {
      ed.doc.mode = .Loop
      ed.dirty = true
    }
    imgui.EndCombo()
  }
  if imgui.IsItemHovered() {
    imgui.SetTooltip("once = the program ends when it runs off the end.  loop = it wraps back to the start node.")
  }

  imgui.SameLine(0, px(12))
  can_save := bhv_name_ok(name) && len(ed.doc.steps) > 0
  if !can_save {
    imgui.BeginDisabled()
  }
  if gui_icon_button("edsave", ICON_SAVE, ed.dirty, ed.dirty ? "Save (unsaved changes)" : "Save", ed.dirty ? COL_WARN : COL_OK) {
    ed_save(ps, ed)
  }
  if !can_save {
    imgui.EndDisabled()
  }

  imgui.SameLine(0, px(6))
  // The run gate, SHOWN rather than only enforced. `script run` refuses a chart whose blocks are not
  // usable yet and prints why - to stderr, which the SHIPPED build does not even have a console for
  // (release main-module is -subsystem:windows), and while working offline it is the answer you most
  // need. So the button carries it:
  // amber with the count and the first reason. It stays CLICKABLE either way, because a chart made only
  // of flow/wait/var blocks genuinely does run with nothing attached (the t_* set is exactly that).
  blocked_count, blocked_why := ed_run_blockers(ed, f)
  run_col := blocked_count > 0 ? COL_WARN : COL_OK
  run_tip := running ? cstring("Restart it with what is saved  ('script run')") : cstring("Save, then run this chart")
  if blocked_count > 0 {
    run_tip = fmt.ctprintf("%d block(s) cannot run yet: %s", blocked_count, blocked_why)
  }
  if gui_icon_button("edrun", ICON_PLAY, running, run_tip, run_col) {
    if ed_save(ps, ed) {
      if running {
        panel_enqueue(ps, "script stop")
      }
      panel_enqueue(ps, fmt.tprintf("script run %s", strings.trim_space(panel_buf_str(ed.name_buf[:]))))
    }
  }
  // TRANSPORT, on the editor's own toolbar rather than only on the dock behind it. Stepping a chart is
  // something you do WHILE looking at the graph - the canvas already highlights the live node, and the
  // strip under it says what each step did - so having to close the editor to reach the dock's buttons
  // made the one view that could explain a run the one view that could not drive it.
  //
  // Every button is an enqueued REPL command, not a direct call: the walker runs on the watcher thread
  // and the deferred queue is how the GUI has always crossed that line (see panel_enqueue).
  if running {
    imgui.SameLine(0, px(6))
    if f.script_paused {
      if gui_icon_button("edresume", ICON_PLAY, true, "Resume  ('script resume')", COL_OK) {
        panel_enqueue(ps, "script resume")
      }
    } else {
      if gui_icon_button("edpause", ICON_PAUSE, false, "Pause - freezes the whole machine, interrupts included  ('script pause')") {
        panel_enqueue(ps, "script pause")
      }
    }
    imgui.SameLine(0, px(6))
    if gui_icon_button("edreset", ICON_REPLAY, false, "Rewind to the start node  ('script reset')") {
      panel_enqueue(ps, "script reset")
    }
  }
  imgui.SameLine(0, px(6))
  // Step works on a chart that is NOT running yet, and that is the whole reason `script run <name> step`
  // exists: two enqueued commands (run, then step) would let the watcher tick in between and the chart
  // would be somewhere else by the time the step landed.
  step_tip := cstring("Single-step: freeze the walker and run one block at a time  ('script step')")
  if running && f.script_step {
    step_tip = "Execute one block  ('script step'; the play button resumes)"
  } else if !running {
    step_tip = "Save, start this chart STOPPED on its first node, and step it from there"
  }
  if gui_icon_button("edstep", ICON_STEP, running && f.script_step, step_tip) {
    if running {
      panel_enqueue(ps, "script step")
    } else if ed_save(ps, ed) {
      panel_enqueue(ps, fmt.tprintf("script run %s step", strings.trim_space(panel_buf_str(ed.name_buf[:]))))
      ed.trace_open = true // stepping with nothing to read the steps in is half a debugger
      ed.trace_follow = true
    }
  }
  if running {
    imgui.SameLine(0, px(6))
    if gui_icon_button("edstop", ICON_STOP, false, "Stop the run  ('script stop')", COL_BAD) {
      panel_enqueue(ps, "script stop")
    }
  }

  imgui.SameLine(0, px(12))
  if gui_icon_button("edtrace", ICON_TRACE, ed.trace_open, ed.trace_open ? "Hide the run log" : "Show the run log - what the chart did, step by step") {
    ed.trace_open = !ed.trace_open
    ed.trace_follow = true
  }

  imgui.SameLine(0, px(6))
  if gui_icon_button("edadd", ICON_ADD, false, "Add a node  (or right-click the canvas)") {
    // NOT imgui.OpenPopup here: a popup's id is seeded from the CURRENT window's id stack, and the
    // palette's BeginPopup runs inside the "##canvas" child - a different window, so a popup opened
    // from this row would carry an id nothing ever matches and would simply never appear. The canvas
    // opens it on the next line of the same frame; this only asks.
    ed.pal_at = ed.pan - [2]f32{ED_NODE_W * 0.5, ED_NODE_H * 0.5}
    ed.pal_wire = 0
    ed.pal_after = 0
    ed.pal_req = true
  }

  // Undo has a BUTTON as well as Ctrl+Z. A shortcut nobody can see is a feature nobody finds, and the
  // pair also says out loud that edits here are reversible - which is the thing that makes a canvas
  // safe to experiment on.
  // LATCHED into a local, and that is a bug fix rather than a tidy-up. `if len(ed.undo) == 0` evaluated
  // twice around a button whose handler POPS ed.undo means: with exactly one snapshot left, the
  // BeginDisabled is skipped (len is 1), the click undoes it, and the closing test now reads len == 0 and
  // calls EndDisabled with nothing open - "Calling EndDisabled() too many times!" and the window dies.
  // Undoing the last edit is not an exotic case; it is what you do after trying one thing.
  imgui.SameLine(0, px(12))
  no_undo := len(ed.undo) == 0
  if no_undo {
    imgui.BeginDisabled()
  }
  if gui_icon_button("edundo", ICON_UNDO, false, "Undo  (Ctrl+Z)") {
    ed_undo(ed)
  }
  if no_undo {
    imgui.EndDisabled()
  }
  imgui.SameLine(0, px(6))
  no_redo := len(ed.redo) == 0
  if no_redo {
    imgui.BeginDisabled()
  }
  if gui_icon_button("edredo", ICON_REDO, false, "Redo  (Ctrl+Y)") {
    ed_redo(ed)
  }
  if no_redo {
    imgui.EndDisabled()
  }

  // Import a route drawn on the map. OpenPopup and BeginPopup both run HERE, in this window - the
  // palette's comment above explains why that matters: a popup's id comes from the current window's id
  // stack, so opening one from a row whose BeginPopup lives in another window silently never appears.
  imgui.SameLine(0, px(6))
  if gui_icon_button("edwaypoints", ICON_FLAG, false, "Insert a waypoint route as walk_to nodes") {
    imgui.OpenPopup("##edwaypointpick")
  }
  if imgui.BeginPopup("##edwaypointpick") {
    names := waypoint_list_names()
    if len(names) == 0 {
      imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
      imgui.TextUnformatted("No saved routes - draw one on the radar (W) and save it.")
      imgui.PopStyleColor(1)
    }
    for set_name in names {
      set, ok := waypoint_read(set_name)
      if !ok {
        continue
      }
      defer waypoint_set_free(&set)
      if len(set.waypoints) == 0 {
        continue // an empty route would insert nothing and read as a broken button
      }
      if imgui.Selectable(fmt.ctprintf("%s  (%d point%s)", set_name, len(set.waypoints), len(set.waypoints) == 1 ? "" : "s")) {
        ed_import_waypoint_set(ed, set)
      }
    }
    imgui.EndPopup()
  }

  imgui.SameLine(0, px(6))
  if gui_icon_button("edarrange", ICON_ARRANGE, false, "Tidy up: re-rank the nodes and stack the sections") {
    // Explicit, never automatic on an already-placed chart: an arrangement you made by hand is a
    // decision, and a layout pass that overwrote it whenever it thought it knew better would be the
    // editor arguing with you. Undoable for the same reason.
    ed_snapshot(ed)
    ed_layout(ed)
  }

  // The node count stays on the controls row: it is two words, it is always true, and it is about the
  // buttons next to it. Anything longer goes in the banner below - see ed_status_banner.
  imgui.SameLine(0, px(12))
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted(fmt.ctprintf("%d node%s", len(ed.doc.steps), len(ed.doc.steps) == 1 ? "" : "s"))
  imgui.PopStyleColor(1)

  // The BADGE. A count you have to open a tab to find is a count nobody finds, and "it's hard to tell
  // what's wrong with a chart" was the complaint - so the answer has to be visible from the canvas.
  // Silent when the chart is clean: a permanent green "0 problems" trains you to stop reading the spot.
  if errors := script_lint_count(problems, .Error); errors + script_lint_count(problems, .Warning) > 0 {
    warnings := script_lint_count(problems, .Warning)
    imgui.SameLine(0, px(12))
    imgui.PushStyleColorImVec4(.Text, errors > 0 ? COL_BAD : COL_WARN)
    text: cstring
    switch {
    case errors > 0 && warnings > 0:
      text = fmt.ctprintf("%d error%s, %d warning%s", errors, errors == 1 ? "" : "s", warnings, warnings == 1 ? "" : "s")
    case errors > 0:
      text = fmt.ctprintf("%d error%s", errors, errors == 1 ? "" : "s")
    case:
      text = fmt.ctprintf("%d warning%s", warnings, warnings == 1 ? "" : "s")
    }
    if imgui.SmallButton(text) {
      ed.tab_problems = true
    }
    imgui.PopStyleColor(1)
    if imgui.IsItemHovered() {
      imgui.SetTooltip("Click for the Problems list - every row jumps to its node.")
    }
  }

  ed_status_banner(ed, running)

  // The ARM row, shown whenever the document HAS a watcher - which is now a property of its content,
  // not of a header. Arming is the third scope: inline is this chart's own business, `uses` is one
  // chart borrowing it, and this is "watch for it whatever is running".
  if ed_watcher_count(ed) > 0 {
    imgui.PushStyleColorImVec4(.Text, COL_WARN)
    imgui.TextUnformatted(fmt.ctprintf("%d watcher%s", ed_watcher_count(ed), ed_watcher_count(ed) == 1 ? "" : "s"))
    imgui.PopStyleColor(1)
    imgui.SameLine(0, px(14))
    on := armed_watcher_enabled_in_frame(f, ed.doc.name)
    if on {
      if imgui.Button("Stop watching", {px(130), 0}) {
        panel_enqueue(ps, fmt.tprintf("interrupt off %s", ed.doc.name))
      }
      imgui.SameLine(0, px(8))
      imgui.PushStyleColorImVec4(.Text, COL_OK)
      imgui.TextUnformatted("ALWAYS WATCHING - armed right now, whatever else is running")
      imgui.PopStyleColor(1)
    } else {
      // Arming reads the FILE, so an unsaved edit would arm something other than what is on screen.
      dis := ed.dirty || !bhv_exists(ed.doc.name)
      if dis {
        imgui.BeginDisabled()
      }
      if imgui.Button("Always watch", {px(130), 0}) {
        panel_enqueue(ps, fmt.tprintf("interrupt on %s", ed.doc.name))
      }
      if dis {
        imgui.EndDisabled()
      }
      imgui.SameLine(0, px(8))
      imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
      imgui.TextUnformatted(dis ? "only inside this chart - save it first to arm it globally" : "only inside this chart")
      imgui.PopStyleColor(1)
    }
  }
  imgui.Separator()
}

// How many watchers this document declares - `.On` nodes with a body wired.
@(private = "file")
ed_watcher_count :: proc(ed: ^Gui_Editor) -> int {
  n := 0
  for s in ed.doc.steps {
    if s.op == .On && s.goto_id != 0 {
      n += 1
    }
  }
  return n
}

// One line of standing status - the save result, or a warning that is true right now - as a tinted
// full-width strip UNDER the controls.
//
// It used to be a bare sentence SameLine'd onto the end of the toolbar, where a long one (the shadow
// warning is the long one) ran to the window edge and read as a stray yellow label floating next to the
// buttons rather than as something the document was telling you. A banner is the shape of that message:
// it owns a row, it is the width of the thing it is about, and it disappears when there is nothing to say.
@(private = "file")
ed_status_banner :: proc(ed: ^Gui_Editor, running: bool) {
  msg: cstring
  col: imgui.Vec4
  switch {
  case ed.msg != "" && rl.GetTime() - ed.msg_at < 8:
    msg, col = fmt.ctprintf("%s", ed.msg), ed.msg_bad ? COL_BAD : COL_OK
  case ed.shadowing:
    msg, col = fmt.ctprintf("built in Odin - saving writes a file that SHADOWS '%s'", ed.doc.name), COL_WARN
  case running && ed.dirty:
    msg, col = "it is running the SAVED version - save and re-run to apply these edits", COL_TEXT_DIM
  case:
    return
  }

  padx, pady := px(10), px(5)
  h := imgui.GetTextLineHeight() + pady * 2
  w := imgui.GetContentRegionAvail().x
  p := imgui.GetCursorScreenPos()
  imgui.Dummy({w, h})

  dl := imgui.GetWindowDrawList()
  r := px(6)
  imgui.DrawList_AddRectFilled(dl, p, {p.x + w, p.y + h}, u32_of(tint(col, 0.12)), r)
  imgui.DrawList_AddRect(dl, p, {p.x + w, p.y + h}, u32_of(tint(col, 0.40)), r)
  imgui.DrawList_AddText(dl, {p.x + padx, p.y + pady}, u32_of(col), msg)
}

// Is <name> one of the enabled global interrupts? Off the Gui_Frame snapshot - the draw phase may not
// read the session, and "which are armed" is session state that the watcher can change under us.
@(private = "file")
armed_watcher_enabled_in_frame :: proc(f: ^Gui_Frame, name: string) -> bool {
  for i in 0 ..< f.armed_watcher_count {
    if f.armed[i].name == name {
      return true
    }
  }
  return false
}

// Write the document out. Returns whether it landed, so "save then run" does not run a stale file.
@(private = "file")
ed_save :: proc(ps: ^Panel_State, ed: ^Gui_Editor) -> bool {
  name := strings.trim_space(panel_buf_str(ed.name_buf[:]))
  if !bhv_name_ok(name) {
    ed_msg(ed, BHV_NAME_RULE, true)
    return false
  }
  if len(ed.doc.steps) == 0 {
    ed_msg(ed, "nothing to save - add a node first", true)
    return false
  }
  if ok, dangling := script_resolve_ids(ed.doc.steps[:]); !ok {
    ed_msg(ed, fmt.tprintf("not saved: an edge points at node %d, which does not exist", u32(dangling)), true)
    return false
  }
  if name != ed.doc.name {
    delete(ed.doc.name)
    ed.doc.name = strings.clone(name)
  }
  if !bhv_save(&ed.doc) {
    ed_msg(ed, "write failed - the console says why", true)
    return false
  }
  ed.dirty = false
  ed.shadowing = behaviour_def(name) != nil
  // THE LINTER, rather than the two checks that used to live here by hand (a blank required argument and
  // a watcher with no body). Both are still reported - script_lint covers them and eight more - and the
  // point of routing through it is that the save message and the Problems tab can never disagree about
  // whether a chart is in good shape.
  //
  // A save is never REFUSED for a lint problem. The chart is yours, half-finished work is a normal state
  // to save in, and a save button that argues would just teach you to distrust it. Notes are left out of
  // the count on purpose: they are true of plenty of finished charts.
  problems := script_lint(&ed.doc)
  errors := script_lint_count(problems, .Error)
  warnings := script_lint_count(problems, .Warning)
  switch {
  case errors > 0:
    ed_msg(ed, fmt.tprintf("saved %s.bhv - %d problem(s) to fix, see the Problems tab", name, errors + warnings), true)
  case warnings > 0:
    ed_msg(ed, fmt.tprintf("saved %s.bhv - %d warning(s), see the Problems tab", name, warnings), true)
  case:
    ed_msg(ed, fmt.tprintf("saved %s.bhv", name), false)
  }
  ps.browser_rescan = true
  return true
}

// --- canvas ------------------------------------------------------------------------------------------

@(private = "file")
gui_ed_canvas :: proc(ps: ^Panel_State, ed: ^Gui_Editor, f: ^Gui_Frame, problems: []Chart_Problem) {
  dl := imgui.GetWindowDrawList()
  v := Ed_View{}
  v.origin = imgui.GetCursorScreenPos()
  v.size = imgui.GetContentRegionAvail()
  if ed.fit_req {
    ed.fit_req = false
    ed_fit_view(ed, v) // needs v.size, which is why it could not happen when the chart was opened
  }
  v.mid = {v.origin.x + v.size.x * 0.5 - ed.pan[0] * ed.zoom * gui_ui_scale(), v.origin.y + v.size.y * 0.5 - ed.pan[1] * ed.zoom * gui_ui_scale()}
  v.k = ed.zoom * gui_ui_scale()

  // One background item drives every gesture. Per-node ImGui items would fight each other for the
  // hover (an item submitted later wins, so a node would steal the press meant for the port on top
  // of it); hit-testing the geometry ourselves is both simpler and exactly ordered.
  imgui.InvisibleButton("##edbg", v.size, {.MouseButtonLeft, .MouseButtonMiddle})
  hovered := imgui.IsItemHovered()
  active := imgui.IsItemActive()
  mp := imgui.GetMousePos()
  hit_node, hit_port := ed_hit(ed, v, mp)

  // --- zoom about the cursor: the canvas point under the mouse must not move
  if hovered && ed.gesture == .None {
    if wheel := imgui.GetIO().MouseWheel; wheel != 0 {
      before := ed_s2c(v, mp)
      ed.zoom = clamp(ed.zoom * math.pow(f32(1.15), wheel), ED_ZOOM_MIN, ED_ZOOM_MAX)
      v.k = ed.zoom * gui_ui_scale()
      v.mid = {v.origin.x + v.size.x * 0.5 - ed.pan[0] * v.k, v.origin.y + v.size.y * 0.5 - ed.pan[1] * v.k}
      after := ed_s2c(v, mp)
      ed.pan += before - after
      v.mid = {v.origin.x + v.size.x * 0.5 - ed.pan[0] * v.k, v.origin.y + v.size.y * 0.5 - ed.pan[1] * v.k}
    }
  }

  // Chips are computed here, after the zoom has settled v but BEFORE the gesture block, because
  // clicking one has to beat panning to the press - and drawing happens far too late to claim it.
  chips := ed_chips(ed, v)

  // A WIRE under the cursor. Same placement and the same reason as the chips: the settled v, and ahead
  // of the gesture block so a click on one can claim the press.
  //
  // Only tested where nothing else is - ed_hit (nodes and ports) wins, so an edge hit beats empty canvas
  // and nothing else. That ordering is what leaves pan and shift+box-select exactly as they were.
  edge_from, edge_port, edge_kind, edge_hit := Node_Id(0), 0, Ed_Edge_Kind.Seq, false
  if hit_node == 0 && hovered && ed.gesture == .None && ed_chip_at(chips, mp) == 0 {
    edge_from, edge_port, edge_kind, edge_hit = ed_hit_edge(ed, v, mp)
  }
  ed.hot_edge_from = edge_hit ? edge_from : 0
  ed.hot_edge_port = edge_port

  // --- gestures
  shift := imgui.IsKeyDown(.LeftShift) || imgui.IsKeyDown(.RightShift)
  if imgui.IsItemActivated() {
    ed.gesture = .Pan
    ed.drag_id = 0
    ed.link_from = 0
    switch {
    case imgui.IsMouseDown(.Middle):
    // middle always pans, whatever is under it
    case ed_chip_at(chips, mp) != 0:
      // "take me to where this jump lands". The press is CONSUMED (gesture .None), or the drag that
      // the same press starts would immediately pan away from the node we just jumped to.
      ed_go_to(ed, ed_chip_at(chips, mp))
      ed.gesture = .None
    case hit_port >= 0:
      ed.gesture = .Link
      ed.link_from = hit_node
      ed.link_port = hit_port
      ed_sel_only(ed, hit_node)
    case edge_hit && ed_edge_cuttable(edge_kind):
      // CUT THE WIRE. Same press-consuming shape as a chip: the gesture goes to .None so the drag this
      // press would otherwise start does not pan the canvas out from under the edit. ed_wire(.., 0) is
      // exactly what the inspector's "clear" button calls, so cutting here and clearing there are one
      // operation with two doors - and it snapshots, so Ctrl+Z brings the wire back.
      ed_wire(ed, edge_from, edge_port, 0)
      ed.gesture = .None
    case hit_node != 0:
      ed.gesture = .Drag
      ed.drag_id = hit_node
      if shift {
        ed_sel_toggle(ed, hit_node)
      } else if !ed_selected(ed, hit_node) {
        ed_sel_only(ed, hit_node) // dragging an already-selected node keeps the whole set
      } else {
        ed.sel = hit_node
      }
      // One snapshot for the whole drag, taken at press: the move is one action however many frames
      // of mouse delta it takes.
      ed_snapshot(ed)
      ed.drag_raw = ed_step(ed, hit_node).ui_pos
    case shift:
      // Shift+drag on empty canvas rubber-bands. Plain drag stays PAN: panning is the thing you do
      // constantly and box-select is the thing you do occasionally, so the bare gesture goes to the
      // common one.
      ed.gesture = .Box
      ed.box_from = ed_s2c(v, mp)
    case:
      ed_sel_only(ed, 0)
    }
  }
  if active {
    d := imgui.GetIO().MouseDelta
    #partial switch ed.gesture {
    case .Pan:
      ed.pan -= [2]f32{d.x, d.y} / v.k
      v.mid = {v.origin.x + v.size.x * 0.5 - ed.pan[0] * v.k, v.origin.y + v.size.y * 0.5 - ed.pan[1] * v.k}
    case .Drag:
      if s := ed_step(ed, ed.drag_id); s != nil && (d.x != 0 || d.y != 0) {
        // The RAW position accumulates the mouse; the node gets the snapped one. Snapping in place
        // would round away every sub-grid movement, so a slow drag would never move at all.
        ed.drag_raw += [2]f32{d.x, d.y} / v.k
        want := ed.drag_raw
        if !imgui.IsKeyDown(.LeftAlt) && !imgui.IsKeyDown(.RightAlt) {
          want = {math.round(want[0] / ED_GRID) * ED_GRID, math.round(want[1] / ED_GRID) * ED_GRID}
        }
        delta := want - s.ui_pos
        if delta != {0, 0} {
          for id in ed.selset {
            if o := ed_step(ed, id); o != nil {
              o.ui_pos += delta
            }
          }
          if !ed_selected(ed, ed.drag_id) {
            s.ui_pos += delta
          }
          ed.dirty = true
        }
      }
    }
  }
  if imgui.IsItemDeactivated() {
    if ed.gesture == .Link && ed.link_from != 0 {
      // Dropped on a node wires it; dropped anywhere else cancels, which is the only way to back out
      // of a wire you started by accident.
      if hit_node != 0 && hit_node != ed.link_from {
        ed_wire(ed, ed.link_from, ed.link_port, hit_node)
      }
    }
    if ed.gesture == .Box {
      ed_box_select(ed, ed.box_from, ed_s2c(v, mp))
    }
    ed.gesture = .None
    ed.link_from = 0
    ed.drag_id = 0
  }

  ed_keyboard(ed, v, hovered)

  // --- the toolbar's + button, cashed in here where the palette's own window is (see gui_ed_toolbar).
  // The node lands in the middle of the view, which is what "add a node" with no click point means.
  // Where the node lands and what it attaches to are the REQUESTER's business now - the toolbar means
  // "in the middle of the view, unattached", the wire menu means "between these two". This only opens
  // the popup, so a new requester cannot have its placement quietly overwritten here.
  if ed.pal_req {
    ed.pal_req = false
    ed.pal_seed = true
    panel_buf_set(ed.pal_filter[:], "")
    imgui.OpenPopup("##edpalette")
  }

  // --- right-click: a node menu, a wire menu, or the add palette on empty canvas
  if hovered && imgui.IsMouseClicked(.Right) {
    if hit_node != 0 {
      if !ed_selected(ed, hit_node) {
        ed_sel_only(ed, hit_node)
      } else {
        ed.sel = hit_node
      }
      imgui.OpenPopup("##ednodectx")
    } else if edge_hit {
      // Latched into ctx_edge_*, not read back off ed.hot_edge_*: the popup is drawn on later frames,
      // by which time the cursor has moved off the wire and the hover has gone.
      ed.ctx_edge_from = edge_from
      ed.ctx_edge_port = edge_port
      ed.ctx_edge_kind = edge_kind
      imgui.OpenPopup("##ededgectx")
    } else {
      ed.pal_at = ed_s2c(v, mp)
      ed.pal_wire = 0
      ed.pal_after = 0
      ed.pal_seed = true
      panel_buf_set(ed.pal_filter[:], "")
      imgui.OpenPopup("##edpalette")
    }
  }

  // Focus follows the mouse, and falls back to the selection so the highlight survives moving the
  // cursor off to the inspector to read what you just clicked on.
  ed.hot = (hovered && ed.gesture == .None) ? hit_node : 0
  focus := ed.hot != 0 ? ed.hot : ed.sel
  ring := ed_focus_ring(ed, focus)

  imgui.DrawList_PushClipRect(dl, v.origin, {v.origin.x + v.size.x, v.origin.y + v.size.y}, true)
  ed_draw_grid(dl, v)
  ed_draw_bands(ed, dl, v)
  ed_draw_edges(ed, dl, v, focus)
  ed_draw_nodes(ed, dl, v, f, focus, ring, problems)
  ed_draw_chips(ed, dl, v, chips, mp)
  if ed.gesture == .Link {
    if s := ed_step(ed, ed.link_from); s != nil {
      col := ed.link_port == 1 ? tint(COL_BAD, 0.9) : tint(COL_ACCENT, 0.9)
      ed_bezier(dl, ed_port_pos(v, s^, ed.link_port), mp, col, max(px(2) * ed.zoom, 1.5))
      imgui.DrawList_AddCircleFilled(dl, mp, ED_PORT_R * v.k, u32_of(col))
    }
  }
  if ed.gesture == .Box {
    a := ed_c2s(v, ed.box_from)
    imgui.DrawList_AddRectFilled(dl, {min(a.x, mp.x), min(a.y, mp.y)}, {max(a.x, mp.x), max(a.y, mp.y)}, u32_of(tint(COL_ACCENT, 0.14)))
    imgui.DrawList_AddRect(dl, {min(a.x, mp.x), min(a.y, mp.y)}, {max(a.x, mp.x), max(a.y, mp.y)}, u32_of(tint(COL_ACCENT, 0.85)), 0, {}, px(1))
  }
  imgui.DrawList_PopClipRect(dl)

  // The hover card. Suppressed while a gesture is in flight - a tooltip that follows the cursor
  // during a drag is in the way of the exact thing you are trying to see.
  if ed.hot != 0 && ed.gesture == .None && ed_chip_at(chips, mp) == 0 {
    if s := ed_step(ed, ed.hot); s != nil {
      ed_hover_card(ed, s)
    }
  } else if edge_hit && ed.gesture == .None {
    ed_edge_hover_card(ed, edge_from, edge_port, edge_kind)
  }

  if ed.find_req {
    ed.find_req = false
    ed.find_seed = true
    panel_buf_set(ed.find_buf[:], "")
    imgui.OpenPopup("##edfind")
  }

  gui_ed_node_menu(ps, ed)
  gui_ed_edge_menu(ed)
  gui_ed_palette(ed, f)
  gui_ed_find(ed)
}

// Names both ends and says what a click will do. The tooltip IS the affordance here: a wire has no
// border to light up and no cursor change to offer, so without this a hovered wire that got thicker
// would be a mystery rather than an invitation.
@(private = "file")
ed_edge_hover_card :: proc(ed: ^Gui_Editor, from: Node_Id, port: int, kind: Ed_Edge_Kind) {
  s := ed_step(ed, from)
  if s == nil {
    return
  }
  to := port == 1 ? s.else_id : s.goto_id
  if kind == .Seq {
    to = 0
  }
  t := ed_step(ed, to)
  imgui.BeginTooltip()
  defer imgui.EndTooltip()
  imgui.PushStyleColorImVec4(.Text, ed_edge_color(kind))
  imgui.TextUnformatted(fmt.ctprintf("%s   --%s->", block_title(s^), ed_edge_word(kind, s.op)))
  imgui.PopStyleColor(1)
  imgui.TextUnformatted(fmt.ctprintf("%s", t == nil ? "the next node in order" : block_title(t^)))
  imgui.PushStyleColorImVec4(.Text, ed_edge_cuttable(kind) ? COL_TEXT_DIM : COL_WARN)
  imgui.TextUnformatted(ed_edge_cuttable(kind) ? "click to cut  -  right-click for more" : fmt.ctprintf("%s", ed_edge_uncuttable_why(kind)))
  imgui.PopStyleColor(1)
}

// Ctrl+F: jump to a node by name. The palette answers "what block could I add"; this answers "where
// in this chart is the thing I am thinking of", which on a chart big enough to need panning is a
// different and more frequent question.
@(private = "file")
gui_ed_find :: proc(ed: ^Gui_Editor) {
  if !imgui.BeginPopup("##edfind") {
    return
  }
  defer imgui.EndPopup()
  if ed.find_seed {
    imgui.SetKeyboardFocusHere()
    ed.find_seed = false
  }
  imgui.SetNextItemWidth(px(320))
  imgui.InputTextWithHint("##findq", "find a node", cstring(raw_data(ed.find_buf[:])), len(ed.find_buf))
  q := strings.to_lower(strings.trim_space(panel_buf_str(ed.find_buf[:])), context.temp_allocator)

  go := Node_Id(0)
  if imgui.BeginChild("##findlist", {px(320), px(240)}, {}) {
    shown := 0
    for s in ed.doc.steps {
      title := block_title(s)
      detail := step_params_line(s)
      if q != "" &&
         !strings.contains(strings.to_lower(title, context.temp_allocator), q) &&
         !strings.contains(strings.to_lower(detail, context.temp_allocator), q) &&
         !strings.contains(strings.to_lower(s.group, context.temp_allocator), q) {
        continue
      }
      shown += 1
      imgui.PushStyleColorImVec4(.Text, ed_node_color(s))
      if imgui.Selectable(fmt.ctprintf("%s##f%d", title, u32(s.id))) {
        go = s.id
      }
      imgui.PopStyleColor(1)
      imgui.SameLine(0, px(8))
      imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
      imgui.TextUnformatted(fmt.ctprintf("#%d   %s", u32(s.id), s.group))
      imgui.PopStyleColor(1)
    }
    if shown == 0 {
      imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
      imgui.TextUnformatted("No node matches that.")
      imgui.PopStyleColor(1)
    }
  }
  imgui.EndChild()
  if go != 0 {
    ed_go_to(ed, go)
    imgui.CloseCurrentPopup()
  }
}

// Everything a node is, in one card: what it does, what it was tuned with, and what leads to and
// away from it BY NAME. The edges are the reason it exists - a bare "#7" in the label was the thing
// that made a jump unfollowable, and naming its destination is most of the fix.
@(private = "file")
ed_hover_card :: proc(ed: ^Gui_Editor, s: ^Script_Step) {
  imgui.BeginTooltip()
  defer imgui.EndTooltip()

  imgui.PushStyleColorImVec4(.Text, ed_node_color(s^))
  imgui.TextUnformatted(fmt.ctprintf("%s", block_title(s^)))
  imgui.PopStyleColor(1)
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted(fmt.ctprintf("#%d   %s   %s", u32(s.id), BLOCK_CAT_NAMES[block_cat(s^)], block_name(s^)))
  imgui.PopStyleColor(1)

  if b := block_blurb(s^); b != "" {
    imgui.Dummy({0, px(4)})
    imgui.PushTextWrapPos(imgui.GetCursorPosX() + px(340))
    imgui.TextUnformatted(fmt.ctprintf("%s", b))
    imgui.PopTextWrapPos()
  }

  // Every argument, INCLUDING the ones the compact node body drops for being at their default - this
  // is where you come to find out what a rung is actually using when the node says nothing.
  ed_card_params(s)

  imgui.Dummy({0, px(4)})
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.Separator()
  imgui.PopStyleColor(1)

  ins := ed_edges_into(ed, s.id)
  for e in ins {
    t := ed_step(ed, e.from)
    imgui.PushStyleColorImVec4(.Text, tint(ed_edge_color(e.kind), 0.85))
    imgui.TextUnformatted(fmt.ctprintf("in   <- %s (#%d)", t == nil ? "?" : block_title(t^), u32(e.from)))
    imgui.PopStyleColor(1)
  }
  i := ed_index(ed, s.id)
  if i >= 0 {
    edges: [3]Ed_Edge
    n := ed_edges(ed, i, &edges)
    for e in edges[:n] {
      t := ed_step(ed, e.to)
      imgui.PushStyleColorImVec4(.Text, ed_edge_color(e.kind))
      imgui.TextUnformatted(fmt.ctprintf("%-9s -> %s (#%d)", ed_edge_word(e.kind, s.op), t == nil ? "?" : block_title(t^), u32(e.to)))
      imgui.PopStyleColor(1)
    }
    if n == 0 && len(ins) == 0 {
      imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
      imgui.TextUnformatted(s.op == .On ? "an interrupt - checked before every step" : "nothing leads here and nothing follows")
      imgui.PopStyleColor(1)
    }
  }
}

@(private = "file")
ed_card_params :: proc(s: ^Script_Step) {
  show :: proc(label: string, spec: []Param_Spec, nums: [4]f64, strs: [2]string) {
    if len(spec) == 0 {
      return
    }
    imgui.Dummy({0, px(4)})
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextUnformatted(fmt.ctprintf("%s", label))
    imgui.PopStyleColor(1)
    for _, i in spec {
      def := param_is_default(spec, i, nums, strs)
      imgui.PushStyleColorImVec4(.Text, def ? COL_TEXT_DIM : COL_TEXT)
      imgui.TextUnformatted(
        fmt.ctprintf(
          "  %-12s %s%s",
          prose_words(spec[i].name),
          param_value_text(spec, i, nums, strs),
          def ? "   (default)" : "",
        ),
      )
      imgui.PopStyleColor(1)
    }
  }
  #partial switch s.op {
  case .Action, .On:
    if d := action_def(s.action.kind); d != nil {
      show("does", d.params, s.action.nums, s.action.strs)
    }
  }
  // Per ROW, each headed by its own event when there is more than one - the card exists to show every
  // argument including the defaulted ones, and a multi-row test has several sets of them.
  #partial switch s.op {
  case .Branch, .If, .While, .Wait_For, .On:
    for i in 0 ..< condition_row_count(s.condition) {
      r := condition_row(s.condition, i)
      if d := event_def(r.kind); d != nil {
        show(condition_row_count(s.condition) == 1 ? "when" : fmt.tprintf("when %s", event_title(r)), d.params, r.nums, r.strs)
      }
    }
  }
  if s.has_until {
    for i in 0 ..< condition_row_count(s.until) {
      r := condition_row(s.until, i)
      if d := event_def(r.kind); d != nil {
        show(fmt.tprintf("until %s", event_title(r)), d.params, r.nums, r.strs)
      }
    }
  }
}

@(private = "file")
ed_draw_chips :: proc(ed: ^Gui_Editor, dl: ^imgui.DrawList, v: Ed_View, chips: [dynamic]Ed_Chip, mp: imgui.Vec2) {
  fs := imgui.GetFontSize() * ed.zoom * 0.78
  for c in chips {
    col := ed_edge_color(c.kind)
    hot := mp.x >= c.a.x && mp.x <= c.b.x && mp.y >= c.a.y && mp.y <= c.b.y
    r := (c.b.y - c.a.y) * 0.5
    imgui.DrawList_AddRectFilled(dl, c.a, c.b, u32_of(tint(imgui.Vec4{0.086, 0.110, 0.145, 1}, hot ? 1 : 0.95)), r)
    imgui.DrawList_AddRect(dl, c.a, c.b, u32_of(tint(col, hot ? 1 : 0.7)), r, {}, hot ? px(1.6) : px(1))
    ed_text(dl, {c.a.x + px(5) * ed.zoom, c.a.y + ((c.b.y - c.a.y) - fs) * 0.5}, fs, tint(col, hot ? 1 : 0.9), fmt.ctprintf("%s", c.label))
  }
}

@(private = "file")
ed_box_select :: proc(ed: ^Gui_Editor, a, b: [2]f32) {
  lo := [2]f32{min(a[0], b[0]), min(a[1], b[1])}
  hi := [2]f32{max(a[0], b[0]), max(a[1], b[1])}
  clear(&ed.selset)
  ed.sel = 0
  for s in ed.doc.steps {
    // INTERSECTS, not contains: asking for a box drawn fully around every node means being careful at
    // the edges, and there is no second meaning for a partly-covered node to have here.
    if s.ui_pos[0] > hi[0] || s.ui_pos[0] + ED_NODE_W < lo[0] {
      continue
    }
    if s.ui_pos[1] > hi[1] || s.ui_pos[1] + ED_NODE_H < lo[1] {
      continue
    }
    append(&ed.selset, s.id)
    if ed.sel == 0 {
      ed.sel = s.id
    }
  }
}

// Keyboard. Gated on the canvas being hovered AND nothing else being active, so a shortcut can never
// fire while a text box in the inspector has the keys.
@(private = "file")
ed_keyboard :: proc(ed: ^Gui_Editor, v: Ed_View, hovered: bool) {
  if imgui.GetIO().WantCaptureKeyboard || imgui.IsAnyItemActive() {
    return
  }
  ctrl := imgui.IsKeyDown(.LeftCtrl) || imgui.IsKeyDown(.RightCtrl)
  shift := imgui.IsKeyDown(.LeftShift) || imgui.IsKeyDown(.RightShift)

  // Undo works whether or not the canvas is under the cursor: it undoes the last edit, and which
  // panel the mouse happens to be over has nothing to do with what that was.
  if ctrl && imgui.IsKeyPressed(.Z) {
    if shift {ed_redo(ed)} else {ed_undo(ed)}
    return
  }
  if ctrl && imgui.IsKeyPressed(.Y) {
    ed_redo(ed)
    return
  }
  if !hovered {
    return
  }

  if imgui.IsKeyPressed(.Escape) {
    ed_sel_only(ed, 0)
    return
  }
  if imgui.IsKeyPressed(.Home) {
    ed_focus_all(ed)
    return
  }
  if ctrl && imgui.IsKeyPressed(.F) {
    ed.find_req = true
    return
  }
  if imgui.IsKeyPressed(.Delete) && len(ed.selset) > 0 {
    ed_delete_selection(ed)
    return
  }
  if ed.sel == 0 {
    return
  }
  if imgui.IsKeyPressed(.F) {
    ed_go_to(ed, ed.sel)
    return
  }
  if ctrl && imgui.IsKeyPressed(.D) {
    ed_duplicate_selection(ed)
    return
  }

  // Arrows nudge by one grid square, or by one canvas unit with Shift for the last bit of alignment.
  nudge := [2]f32{0, 0}
  step := shift ? f32(1) : ED_GRID
  if imgui.IsKeyPressed(.LeftArrow) {nudge[0] -= step}
  if imgui.IsKeyPressed(.RightArrow) {nudge[0] += step}
  if imgui.IsKeyPressed(.UpArrow) {nudge[1] -= step}
  if imgui.IsKeyPressed(.DownArrow) {nudge[1] += step}
  if nudge != {0, 0} {
    ed_snapshot(ed)
    for id in ed.selset {
      if s := ed_step(ed, id); s != nil {
        s.ui_pos += nudge
      }
    }
    ed.dirty = true
  }
}

// Copy the selected nodes, offset a little so the copies are visibly not the originals. Edges BETWEEN
// copied nodes are rewired to the copies; edges leaving the selection are dropped rather than left
// pointing at the originals, because a duplicate that silently rejoins the original program is a
// change to the program, not a copy of part of it.
@(private = "file")
ed_duplicate_selection :: proc(ed: ^Gui_Editor) {
  if len(ed.selset) == 0 {
    return
  }
  ed_snapshot(ed)
  remap := make(map[Node_Id]Node_Id, len(ed.selset), context.temp_allocator)
  next := ed_next_id(ed)
  src := make([]Node_Id, len(ed.selset), context.temp_allocator)
  copy(src, ed.selset[:])
  for id in src {
    remap[id] = next
    next += 1
  }
  for id in src {
    s := ed_step(ed, id)
    if s == nil {
      continue
    }
    c := script_step_clone(s^)
    c.id = remap[id]
    c.ui_pos += {ED_GRID, ED_GRID}
    c.goto_id = remap[s.goto_id] or_else 0
    c.else_id = remap[s.else_id] or_else 0
    append(&ed.doc.steps, c)
  }
  clear(&ed.selset)
  ed.sel = 0
  for id in src {
    append(&ed.selset, remap[id])
    if ed.sel == 0 {
      ed.sel = remap[id]
    }
  }
  ed_touch(ed)
}

// Which node (and which port) the mouse is over. Reverse order so the node drawn LAST - the one
// visually on top - is the one you grab; ports win over the body they sit on.
@(private = "file")
ed_hit :: proc(ed: ^Gui_Editor, v: Ed_View, mp: imgui.Vec2) -> (node: Node_Id, port: int) {
  port = -2
  grab := ED_PORT_R * v.k + px(3)
  #reverse for s in ed.doc.steps {
    for p in 0 ..< ed_out_ports(s.op) {
      pp := ed_port_pos(v, s, p)
      if abs(mp.x - pp.x) <= grab && abs(mp.y - pp.y) <= grab {
        return s.id, p
      }
    }
    a, b := ed_node_rect(v, s)
    if mp.x >= a.x && mp.x <= b.x && mp.y >= a.y && mp.y <= b.y {
      return s.id, -1
    }
  }
  return 0, -2
}

@(private = "file")
ed_draw_grid :: proc(dl: ^imgui.DrawList, v: Ed_View) {
  step := ED_GRID
  for step * v.k < px(16) {
    step *= 2 // coarsen rather than draw a grey wash when zoomed out
  }
  col := u32_of(tint(COL_BORDER, 0.5))
  c0 := ed_s2c(v, v.origin)
  c1 := ed_s2c(v, {v.origin.x + v.size.x, v.origin.y + v.size.y})
  x := math.floor(c0[0] / step) * step
  for n := 0; x <= c1[0] && n < 400; n += 1 {
    sx := ed_c2s(v, {x, 0}).x
    imgui.DrawList_AddLine(dl, {sx, v.origin.y}, {sx, v.origin.y + v.size.y}, col, 1)
    x += step
  }
  y := math.floor(c0[1] / step) * step
  for n := 0; y <= c1[1] && n < 400; n += 1 {
    sy := ed_c2s(v, {0, y}).y
    imgui.DrawList_AddLine(dl, {v.origin.x, sy}, {v.origin.x + v.size.x, sy}, col, 1)
    y += step
  }
}

// The reserved band every watcher lives in. Not a `group` anybody typed - it is never written to a
// file - but it flows through the layout and the band drawing as if it were one, which is what puts
// the watchers in a labelled frame of their own instead of loose at the top of the chart where they
// used to be mistaken for the start.
ED_WATCH_BAND :: "Watchers"

// Text-buffer layout for one step: the action's two string arguments, then two per condition row for
// `cond`, then the same for `until`.
//
// 64 was tight for a command line (`run_cmd`) and for a chat message, and it silently truncated
// rather than refusing. A monster LIST is no longer sized by this at all - the badge widget uses the
// buffer as its search box and keeps the value in the payload string - so this only has to hold one
// value or one search.
ED_TEXT_BUFFER_SIZE :: 128
ED_TEXT_CONDITION :: 2
ED_TEXT_UNTIL :: ED_TEXT_CONDITION + SCRIPT_MAX_CONDITION_ROWS * 2
ED_TEXT_BUFFERS_PER_STEP :: ED_TEXT_UNTIL + SCRIPT_MAX_CONDITION_ROWS * 2

// Per-step: is this an `.On` node or part of one's body? Sized to the doc; caller owns the slice.
@(private = "file")
ed_watcher_mask :: proc(ed: ^Gui_Editor, is_watcher: []bool) {
  script_watcher_body_mask(ed.doc.steps[:], is_watcher)
  for s, i in ed.doc.steps {
    if s.op == .On {
      is_watcher[i] = true
    }
  }
}

// The band a node is drawn in. Watchers override whatever section they were stamped with, because
// "which part of the algorithm is this" has no answer for something that runs at any point in it.
@(private = "file")
ed_band_name_of :: proc(ed: ^Gui_Editor, step_index: int, is_watcher: []bool) -> string {
  return is_watcher[step_index] ? ED_WATCH_BAND : ed.doc.steps[step_index].group
}

// Nothing here but watchers: no main program, so no start node and no play button. Same question the
// VM asks in script_doc_is_watchers_only, asked of the document being edited.
@(private = "file")
ed_watchers_only :: proc(ed: ^Gui_Editor) -> bool {
  return script_doc_is_watchers_only(&ed.doc)
}

// Section frames, drawn UNDER everything. This is the layer that answers "what am I looking at" before
// you have read a single node: a farm chart is five named parts, and until now the canvas showed
// twenty anonymous boxes and left you to infer them.
//
// The box is derived from where the member nodes actually ARE, not from the layout that produced
// them, so dragging a node keeps its band honest instead of leaving a frame around empty space.
@(private = "file")
ed_draw_bands :: proc(ed: ^Gui_Editor, dl: ^imgui.DrawList, v: Ed_View) {
  // The label does NOT scale all the way down with the zoom. Node text is allowed to become
  // unreadable when you pull back - by then you are reading colour and shape, not words - but the
  // band names are the one thing you are pulling back to SEE, and letting them shrink past legibility
  // would delete the overview at exactly the zoom that exists to provide it.
  fs := max(imgui.GetFontSize() * ed.zoom * 0.86, px(12))
  is_watcher := make([]bool, len(ed.doc.steps), context.temp_allocator)
  ed_watcher_mask(ed, is_watcher)
  seen := make([dynamic]string, context.temp_allocator)
  for i0 in 0 ..< len(ed.doc.steps) {
    g0 := ed_band_name_of(ed, i0, is_watcher)
    if g0 == "" || slice.contains(seen[:], g0) {
      continue
    }
    append(&seen, g0)
    lo := [2]f32{max(f32), max(f32)}
    hi := [2]f32{-max(f32), -max(f32)}
    for s, i in ed.doc.steps {
      if ed_band_name_of(ed, i, is_watcher) != g0 {
        continue
      }
      lo[0] = min(lo[0], s.ui_pos[0])
      lo[1] = min(lo[1], s.ui_pos[1])
      hi[0] = max(hi[0], s.ui_pos[0] + ED_NODE_W)
      hi[1] = max(hi[1], s.ui_pos[1] + ED_NODE_H)
    }
    a := ed_c2s(v, lo - ED_BAND_PAD)
    b := ed_c2s(v, hi + ED_BAND_PAD)
    if b.x < v.origin.x || a.x > v.origin.x + v.size.x || b.y < v.origin.y || a.y > v.origin.y + v.size.y {
      continue
    }
    round := max(px(10) * ed.zoom, 3)
    // The watcher band is tinted warm, like the fail edges: everything inside it happens OUT of turn.
    is_watch := g0 == ED_WATCH_BAND
    fill := is_watch ? imgui.Vec4{0.262, 0.200, 0.160, 0.42} : imgui.Vec4{0.160, 0.200, 0.262, 0.42}
    imgui.DrawList_AddRectFilled(dl, a, b, u32_of(fill), round)
    imgui.DrawList_AddRect(dl, a, b, u32_of(is_watch ? tint(COL_WARN, 0.55) : tint(COL_BORDER, 1.0)), round, {}, max(px(1) * ed.zoom, 1))
    // A filled tab rather than bare text: at a wide zoom the label sits over the grid and whatever
    // wire happens to pass behind it, and a header you have to pick out of the background is not a
    // header. Clamped to the viewport top so a band scrolled half off-screen keeps its name on screen.
    // The watcher caption is kept SHORT on purpose: a band label is drawn at the band's left edge with
    // its own width, so a sentence runs past the frame it belongs to and off the canvas. The long form
    // is the hover text on the dock's watcher chips, where there is room for it.
    lc := is_watch ? cstring("Watchers  -  checked before every step") : fmt.ctprintf("%s", g0)
    lw := imgui.CalcTextSize(lc).x * (fs / imgui.GetFontSize()) + px(12)
    ly := max(a.y - fs - px(7), v.origin.y + px(2))
    imgui.DrawList_AddRectFilled(dl, {a.x, ly - px(2)}, {a.x + lw, ly + fs + px(3)}, u32_of(is_watch ? imgui.Vec4{0.262, 0.200, 0.160, 0.95} : imgui.Vec4{0.160, 0.200, 0.262, 0.95}), max(px(5) * ed.zoom, 3))
    ed_text(dl, {a.x + px(6), ly}, fs, is_watch ? tint(COL_WARN, 0.95) : tint(COL_TEXT, 0.95), lc)
  }
}

@(private = "file")
ed_draw_edges :: proc(ed: ^Gui_Editor, dl: ^imgui.DrawList, v: Ed_View, focus: Node_Id) {
  thick := max(px(2) * ed.zoom, 1.2)
  edges: [3]Ed_Edge
  for i in 0 ..< len(ed.doc.steps) {
    s := ed.doc.steps[i]
    n := ed_edges(ed, i, &edges)
    for e in edges[:n] {
      t := ed_step(ed, e.to)
      if t == nil {
        continue
      }
      // An edge is lit when it TOUCHES the focus, not when both ends happen to be in the ring - two
      // neighbours of the focus are often wired to each other, and lighting that wire too would put
      // back exactly the clutter the dimming is there to remove.
      lit := focus == 0 || s.id == focus || e.to == focus
      from := e.port >= 0 ? ed_port_pos(v, s, e.port) : ed_port_pos(v, s, 0)
      to := ed_port_pos(v, t^, -1)
      col := ed_edge_color(e.kind)
      if !lit {
        col = tint(col, ED_DIM)
      }
      w := e.kind == .Seq ? thick * 0.7 : thick
      // The HOVERED wire, drawn bright and fat so "this is the one I am about to cut" is unambiguous
      // before the click rather than after it.
      if ed.hot_edge_from == s.id && ed.hot_edge_port == e.port {
        col = ed_edge_cuttable(e.kind) ? tint(COL_TEXT, 1.0) : tint(COL_WARN, 1.0)
        w = thick * 2.2
      }
      ed_bezier(dl, from, to, col, w, thick)
      // An arrowhead at the destination: without it a back-edge (which is how a loop is drawn) reads
      // the same as a forward one and the direction of the program becomes a guess.
      h := max(px(5) * ed.zoom, 3)
      imgui.DrawList_AddTriangleFilled(dl, {to.x - h, to.y - h * 1.6}, {to.x + h, to.y - h * 1.6}, to, u32_of(col))
    }
  }
}

// The worst thing said about <node>, ignoring notes. Returns marked=false when there is nothing to draw.
@(private = "file")
ed_worst_problem :: proc(problems: []Chart_Problem, node: Node_Id) -> (level: Chart_Problem_Level, marked: bool) {
  for p in problems {
    if p.node != node || p.level == .Note {
      continue
    }
    if !marked || p.level == .Error {
      level, marked = p.level, true
    }
  }
  return
}

@(private = "file")
ed_draw_nodes :: proc(
  ed: ^Gui_Editor,
  dl: ^imgui.DrawList,
  v: Ed_View,
  f: ^Gui_Frame,
  focus: Node_Id,
  ring: map[Node_Id]bool,
  problems: []Chart_Problem,
) {
  chart_running := f.script_active && f.script_name == ed.doc.name
  entry := ed.doc.entry
  if entry == 0 && len(ed.doc.steps) > 0 {
    entry = ed.doc.steps[0].id // 0 means "the first step", and the badge should say so
  }
  // A document that is nothing but watchers has no start at all - it is armed or borrowed, never run
  // from the top. Drawing START on it would be the same lie in a new place.
  watchers_only := ed_watchers_only(ed)
  round := px(7) * ed.zoom
  title_fs := imgui.GetFontSize() * ed.zoom * 0.78
  body_fs := imgui.GetFontSize() * ed.zoom * 0.86
  pad := px(9) * ed.zoom

  for s in ed.doc.steps {
    a, b := ed_node_rect(v, s)
    if b.x < v.origin.x || a.x > v.origin.x + v.size.x || b.y < v.origin.y || a.y > v.origin.y + v.size.y {
      continue // off-screen; the cull matters once a chart is big enough to need panning
    }
    accent := ed_node_color(s)
    selected := ed_selected(ed, s.id)
    live := chart_running && f.script_node == s.id
    // Dimming is drawn, not skipped: an unlit node is still there, still positioned, still shows its
    // shape. You are meant to keep the map of the chart while reading one corner of it.
    lit := focus == 0 || s.id in ring
    fade := lit ? f32(1) : ED_DIM

    imgui.DrawList_AddRectFilled(dl, a, b, u32_of(tint(imgui.Vec4{0.086, 0.110, 0.145, 0.97}, lit ? 1 : 0.55)), round)
    th := a.y + ED_TITLE_H * v.k
    imgui.DrawList_AddRectFilled(dl, a, {b.x, th}, u32_of(tint(accent, 0.26 * fade)), round, imgui.DrawFlags_RoundCornersTop)
    imgui.DrawList_AddLine(dl, {a.x, th}, {b.x, th}, u32_of(tint(accent, 0.45 * fade)), 1)

    border := tint(COL_BORDER, fade)
    bw := f32(1)
    if live {
      border, bw = COL_OK, max(px(2.5) * ed.zoom, 2)
    } else if s.id == focus {
      border, bw = tint(accent, 0.95), max(px(2) * ed.zoom, 1.5)
    } else if selected {
      border, bw = COL_ACCENT, max(px(2) * ed.zoom, 1.5)
    }
    imgui.DrawList_AddRect(dl, a, b, u32_of(border), round, {}, bw)

    // A PROBLEM MARK on the corner of the node, so the Problems tab and the canvas agree without you
    // having to hold a list of node ids in your head. Notes get no mark - they are true of a lot of
    // perfectly good nodes, and a canvas speckled with dots says nothing.
    if level, marked := ed_worst_problem(problems, s.id); marked {
      mr := max(px(5) * ed.zoom, 3.5)
      mc := level == .Error ? COL_BAD : COL_WARN
      imgui.DrawList_AddCircleFilled(dl, {a.x + mr * 0.6, a.y + mr * 0.6}, mr, u32_of(tint(mc, fade)))
      imgui.DrawList_AddCircle(dl, {a.x + mr * 0.6, a.y + mr * 0.6}, mr, u32_of(tint(imgui.Vec4{0, 0, 0, 1}, 0.55 * fade)), 0, max(px(1) * ed.zoom, 1))
    }

    // Title: the block's HUMAN name behind its category icon. Not BHV_OP_NAMES - that says "action"
    // for all 38 action kinds, which is the least informative thing a title bar could say.
    ty := a.y + ED_TITLE_H * v.k * 0.5
    icon_w := title_fs * 1.15
    gui_draw_icon_sized(dl, a.x + pad + icon_w * 0.5, ty, title_fs, ed_node_icon(s), tint(accent, 0.95 * fade))
    idl := fmt.ctprintf("#%d", u32(s.id))
    idw := imgui.CalcTextSize(idl).x * (title_fs / imgui.GetFontSize())
    tx := a.x + pad + icon_w + px(4) * ed.zoom
    ed_text(dl, {tx, ty - title_fs * 0.5}, title_fs, tint(accent, 0.95 * fade), ed_fit(block_title(s), title_fs, b.x - pad - idw - px(6) * ed.zoom - tx))
    ed_text(dl, {b.x - pad - idw, ty - title_fs * 0.5}, title_fs, tint(COL_TEXT_DIM, 0.9 * fade), idl)

    // Body: the arguments this block was actually TUNED with - or, when it has none, what the block
    // DOES. Showing only tuned arguments was right about which values matter and wrong about the
    // result: a farm chart runs almost entirely on configured values, so almost every node drew as a
    // title over an empty box. The fallback is dimmer, because "what this block is" and "what someone
    // set it to" should not read as the same kind of fact.
    if detail, hint := step_body_line(s); detail != "" {
      col := hint ? tint(COL_TEXT_DIM, fade) : tint(COL_TEXT, fade)
      ed_text(dl, {a.x + pad, th + (b.y - th - body_fs) * 0.5}, body_fs, col, ed_fit(detail, body_fs, (b.x - a.x) - pad * 2))
    }

    // ports
    pr := ED_PORT_R * v.k
    if s.op != .On {
      ip := ed_port_pos(v, s, -1)
      imgui.DrawList_AddCircleFilled(dl, ip, pr * 0.8, u32_of(tint(COL_TEXT_DIM, 0.9 * fade)))
    }
    for p in 0 ..< ed_out_ports(s.op) {
      pp := ed_port_pos(v, s, p)
      pc := accent
      if p == 1 {
        // Port 1 is always the "it didn't work" way out - a branch's false arm or an action's fail
        // edge. Dim while unwired so the second port reads as an offer rather than as clutter on
        // every action in the chart.
        pc = s.else_id != 0 ? COL_BAD : tint(COL_TEXT_DIM, 0.55)
      } else if s.op == .Branch {
        pc = COL_OK
      }
      imgui.DrawList_AddCircleFilled(dl, pp, pr, u32_of(tint(pc, fade)))
      imgui.DrawList_AddCircleFilled(dl, pp, pr * 0.45, u32_of(imgui.Vec4{0.086, 0.110, 0.145, 1}))
    }

    // The START anchor: a drawn capsule with a wire into the entry node, not a word floating above it.
    // A label reads as a note ABOUT the node and could sit on a watcher, which is exactly how "which
    // one is the real starting node?" happened. A capsule with an arrow into the node is a thing in its
    // own right, it can only point at one node, and it is the same shape as every other edge on the
    // canvas - so it is read the same way.
    if s.id == entry && !watchers_only {
      cx := (a.x + b.x) * 0.5
      cw := max(px(58) * ed.zoom, px(30))
      ch := title_fs + px(7) * ed.zoom
      cy := a.y - ch - px(16) * ed.zoom
      p0 := imgui.Vec2{cx - cw * 0.5, cy}
      p1 := imgui.Vec2{cx + cw * 0.5, cy + ch}
      imgui.DrawList_AddRectFilled(dl, p0, p1, u32_of(tint(COL_OK, 0.22)), ch * 0.5)
      imgui.DrawList_AddRect(dl, p0, p1, u32_of(tint(COL_OK, 0.85)), ch * 0.5, {}, max(px(1.5) * ed.zoom, 1))
      lw := imgui.CalcTextSize("START").x * (title_fs / imgui.GetFontSize())
      ed_text(dl, {cx - lw * 0.5, cy + (ch - title_fs) * 0.5}, title_fs, COL_OK, "START")
      imgui.DrawList_AddLine(dl, {cx, p1.y}, {cx, a.y}, u32_of(tint(COL_OK, 0.8)), max(px(2) * ed.zoom, 1.2))
      ah := max(px(5) * ed.zoom, 3)
      imgui.DrawList_AddTriangleFilled(dl, {cx - ah, a.y - ah * 1.6}, {cx + ah, a.y - ah * 1.6}, {cx, a.y}, u32_of(tint(COL_OK, 0.9)))
    }
  }
}

// --- node context menu -------------------------------------------------------------------------------

@(private = "file")
gui_ed_node_menu :: proc(ps: ^Panel_State, ed: ^Gui_Editor) {
  if !imgui.BeginPopup("##ednodectx") {
    return
  }
  defer imgui.EndPopup()
  s := ed_step(ed, ed.sel)
  if s == nil {
    return
  }
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted(fmt.ctprintf("#%d  %s", u32(s.id), block_title(s^)))
  imgui.PopStyleColor(1)
  imgui.Separator()
  if imgui.Selectable("Start here") {
    ed_snapshot(ed)
    ed.doc.entry = s.id
    ed.dirty = true
  }
  if s.goto_id != 0 || s.else_id != 0 {
    if imgui.Selectable("Disconnect outputs") {
      ed_snapshot(ed)
      s.goto_id = 0
      s.else_id = 0
      ed_relabel(s)
      ed_touch(ed)
    }
  }
  if imgui.Selectable("Unwire inputs") {
    ed_snapshot(ed)
    id := s.id
    for &o in ed.doc.steps {
      if o.goto_id == id {
        o.goto_id = 0
        ed_relabel(&o)
      }
      if o.else_id == id {
        o.else_id = 0
        ed_relabel(&o)
      }
    }
    ed_touch(ed)
  }
  imgui.Separator()
  if imgui.Selectable(len(ed.selset) > 1 ? fmt.ctprintf("Delete %d nodes", len(ed.selset)) : "Delete") {
    ed_delete_selection(ed)
  }
}

// --- add-node palette --------------------------------------------------------------------------------

// The palette is the ONLY way to create a block node, and it always creates it with its kind already
// set. A node with kind None would render as "?" and fail at run time with "block has no
// implementation", so there is deliberately no way to make one.
@(private = "file")
gui_ed_palette :: proc(ed: ^Gui_Editor, f: ^Gui_Frame) {
  if !imgui.BeginPopup("##edpalette") {
    return
  }
  defer imgui.EndPopup()

  if ed.pal_seed {
    imgui.SetKeyboardFocusHere()
    ed.pal_seed = false
  }
  // Full width of the palette - the same width as the list under it, so the two read as one panel.
  imgui.SetNextItemWidth(px(ED_PAL_W))
  imgui.InputTextWithHint("##palfilter", "search blocks", cstring(raw_data(ed.pal_filter[:])), len(ed.pal_filter))
  q := strings.to_lower(strings.trim_space(panel_buf_str(ed.pal_filter[:])), context.temp_allocator)

  // What was picked, applied AFTER the child ends: creating a node reallocs doc.steps, and doing that
  // in the middle of the list being iterated is the kind of thing that works until it doesn't.
  pick_op := Script_Op.Action
  pick_ak := Script_Action_Kind.None
  pick_ek := Script_Event_Kind.None
  picked := false
  shown := 0

  if imgui.BeginChild("##pallist", {px(ED_PAL_W), px(330)}, {}) {
    imgui.SeparatorText("Flow")
    if ed_pal_row(q, .Flow, "Jump", "goto", "jump to another node - this is how a loop is drawn on a canvas", true, "", &shown) {
      pick_op, picked = .Goto, true
    }
    if ed_pal_row(q, .Flow, "Hand control back", "return", "end an interrupt region and resume the main program where it was suspended", true, "", &shown) {
      pick_op, picked = .Return, true
    }
    if ed_pal_row(q, .Flow, "Repeat N times", "loop", "take the 'each pass' edge a fixed number of times, then leave by 'when done'", true, "", &shown) {
      pick_op, picked = .Loop, true
    }

    imgui.SeparatorText("Actions - what the chart DOES")
    for def in ACTIONS {
      title := def.title != "" ? def.title : prose_title_of_name(def.name)
      if ed_pal_row(q, def.cat, title, script_sig(def.name, def.params), def.blurb, f.action_usable[def.kind], f.action_why_not[def.kind], &shown, !def.not_built) {
        pick_op, pick_ak, picked = .Action, def.kind, true
      }
    }

    imgui.SeparatorText("Events - what it NOTICES (added as a branch)")
    for def in EVENTS {
      title := def.title != "" ? def.title : prose_title_of_name(def.name)
      if ed_pal_row(q, def.cat, title, script_sig(def.name, def.params), def.blurb, f.event_usable[def.kind], f.event_why_not[def.kind], &shown, !def.not_built) {
        pick_op, pick_ek, picked = .Branch, def.kind, true
      }
    }

    if shown == 0 {
      imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
      imgui.TextUnformatted("Nothing matches that.")
      imgui.PopStyleColor(1)
    }
  }
  imgui.EndChild()
  // Wrapped at the palette's width rather than left to its natural length: this footnote is the longest
  // string in the popup, so without the wrap IT decides how wide the popup is, and the search box and the
  // list below it end up visibly short of the edge no matter what they are set to.
  imgui.PushTextWrapPos(imgui.GetCursorPosX() + px(ED_PAL_W))
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted("An event lands as a branch; switch it to wait_for or on in the inspector.")
  imgui.PopStyleColor(1)
  imgui.PopTextWrapPos()

  if picked {
    ed_pal_create(ed, pick_op, pick_ak, pick_ek)
    imgui.CloseCurrentPopup()
  }
}

// Searches the HUMAN name as well as the catalog spelling, so both ways of knowing a block find it -
// typing "densest" and typing "pick_density" have to land on the same row.
@(private = "file")
ed_pal_matches :: proc(q: string, title, sig, blurb: string) -> bool {
  if q == "" {
    return true
  }
  return(
    strings.contains(strings.to_lower(title, context.temp_allocator), q) ||
    strings.contains(strings.to_lower(sig, context.temp_allocator), q) ||
    strings.contains(strings.to_lower(blurb, context.temp_allocator), q) \
  )
}

// One palette row: category icon, human title, then the catalog signature in dim. Both spellings are
// on the row on purpose - the title is how you find the block, the signature is what you would type,
// and this popup is where you learn that they are the same thing.
//
// Hand-drawn over an empty Selectable rather than built from a formatted label, because the two halves
// need different colours; it is the same pattern the attach dialog's process list uses.
//
// A gated block is drawn but NOT clickable, carrying the same reason `script blocks` prints - the
// catalog is the feature's roadmap as well as its dispatch, and hiding the unavailable half would make
// the palette disagree with the console about what exists.
@(private = "file")
// One palette row. TWO independent axes, and keeping them apart is the whole point:
//
//   placeable - is there code behind this block at all (def.not_built). Only this decides whether the
//               row is clickable. A chart is a DOCUMENT: writing "walk to the spot" with the game shut
//               is a perfectly reasonable thing to be doing, and refusing the click was the tool
//               confusing "I cannot do that now" with "that is not a thing".
//   ok        - can it run right now (attached? findmove pinned?). Drives the dim colours and the
//               tooltip only. `script run` is what enforces it.
ed_pal_row :: proc(q: string, cat: Block_Cat, title, sig, blurb: string, ok: bool, why: string, shown: ^int, placeable := true) -> bool {
  if !ed_pal_matches(q, title, sig, blurb) {
    return false
  }
  shown^ += 1
  dl := imgui.GetWindowDrawList()
  p := imgui.GetCursorScreenPos()
  fh := imgui.GetTextLineHeight()
  row := fh + px(5)

  clicked := false
  if placeable {
    clicked = imgui.Selectable(fmt.ctprintf("##pal%s", sig), false, {}, {0, row})
  } else {
    imgui.Dummy({px(ED_PAL_W), row})
  }
  hovered := imgui.IsItemHovered()

  cy := p.y + row * 0.5
  gui_draw_icon(dl, p.x + px(10), cy, ed_cat_icon(cat), ok ? ed_cat_color(cat) : tint(COL_TEXT_DIM, 0.55))
  tc := fmt.ctprintf("%s", title)
  tx := p.x + px(24)
  imgui.DrawList_AddText(dl, {tx, cy - fh * 0.5}, u32_of(ok ? COL_TEXT : tint(COL_TEXT_DIM, 0.7)), tc)
  sx := tx + imgui.CalcTextSize(tc).x + px(10)
  // The suffix distinguishes the two refusals at a glance: "(not built)" is permanent-for-now and the
  // row is dead; a bare dimmed signature means you can place it, it just will not run yet.
  sc := placeable ? fmt.ctprintf("%s", sig) : fmt.ctprintf("%s   (not built)", sig)
  imgui.DrawList_AddText(dl, {sx, cy - fh * 0.5}, u32_of(tint(COL_TEXT_DIM, ok ? 0.85 : 0.55)), sc)

  if hovered {
    switch {
    case ok:
      imgui.SetTooltip("%s", fmt.ctprintf("%s", blurb))
    case !placeable:
      imgui.SetTooltip("%s", fmt.ctprintf("%s\n\nNot built yet: %s", blurb, why))
    case:
      imgui.SetTooltip("%s", fmt.ctprintf("%s\n\nYou can place it - it just cannot RUN yet: %s", blurb, why))
    }
  }
  return clicked
}

@(private = "file")
ed_pal_create :: proc(ed: ^Gui_Editor, op: Script_Op, ak: Script_Action_Kind, ek: Script_Event_Kind) {
  // ONE snapshot for the whole creation. Adding a node, giving it its kind and wiring it up are three
  // mutations that are one action to the person doing it, and three Ctrl+Z presses to undo one click
  // is the kind of undo that makes people stop trusting undo.
  ed_snapshot(ed)
  // WHAT THE PORT ALREADY WENT TO, read before anything is rewired. This is what makes adding a node
  // an INSERTION rather than a hijack: dragging out of a port that already had a wire used to leave the
  // old destination orphaned and the new node a dead end, so "put a node between these two" was three
  // separate operations you had to know to do in the right order.
  splice_to := Node_Id(0)
  if from := ed_step(ed, ed.pal_wire); from != nil {
    splice_to = ed.pal_port == 1 ? from.else_id : from.goto_id
  }
  id := ed_add_node(ed, op, ed.pal_at, snapshot = false, after = ed.pal_after)
  s := ed_step(ed, id)
  if s == nil {
    return
  }
  if ak != .None {
    ed_set_action_kind(ed, s, ak, snapshot = false)
  }
  if ek != .None {
    ed_set_event_kind(ed, s, &s.condition, ek, snapshot = false)
  }
  if ed.pal_wire != 0 {
    ed_wire(ed, ed.pal_wire, ed.pal_port, id, snapshot = false)
    // Carry the old destination onto the new node. Port 0 always, whatever port we came out of: the
    // second port is a FAIL or FALSE arm, and a node spliced into one continues the flow it interrupted
    // rather than starting a second failure path.
    if splice_to != 0 && splice_to != id {
      ed_wire(ed, id, 0, splice_to, snapshot = false)
    }
    ed.pal_wire = 0
  }
  ed.pal_after = 0
  ed_sel_only(ed, id)
}

// --- inspector ---------------------------------------------------------------------------------------

@(private = "file")
gui_ed_inspector :: proc(ps: ^Panel_State, ed: ^Gui_Editor, f: ^Gui_Frame) {
  s := ed_step(ed, ed.sel)
  if s == nil {
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextUnformatted("Nothing selected.")
    imgui.Dummy({0, px(6)})
    imgui.TextUnformatted("Left-click a node to select it.")
    imgui.TextUnformatted("Hover one to see what it does.")
    imgui.TextUnformatted("Drag a node to move it (Alt = no snap).")
    imgui.TextUnformatted("Drag from a bottom dot to wire it.")
    imgui.TextUnformatted("Right-click empty canvas to add a node.")
    imgui.TextUnformatted("Wheel zooms, drag the background pans.")
    imgui.Dummy({0, px(6)})
    imgui.TextUnformatted("Shift+click       add to the selection")
    imgui.TextUnformatted("Shift+drag        box-select")
    imgui.TextUnformatted("Ctrl+Z / Ctrl+Y   undo / redo")
    imgui.TextUnformatted("Ctrl+D            duplicate")
    imgui.TextUnformatted("Ctrl+F            find a node")
    imgui.TextUnformatted("arrows            nudge (Shift = fine)")
    imgui.TextUnformatted("F / Home          focus selection / all")
    imgui.TextUnformatted("Del               delete")
    imgui.PopStyleColor(1)
    return
  }

  if ed.text_buffers_for_node != s.id {
    ed_seed_buffers(ed, s)
  }

  imgui.PushStyleColorImVec4(.Text, ed_node_color(s^))
  imgui.TextUnformatted(fmt.ctprintf("%s  #%d", block_title(s^), u32(s.id)))
  imgui.PopStyleColor(1)
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  // Category and catalog spelling on one line, then the machine form. The spelling is kept visible
  // because every UI action is issued as the command you would type - hiding it would make the editor
  // and the REPL feel like two different tools.
  imgui.TextUnformatted(fmt.ctprintf("%s  -  %s", BLOCK_CAT_NAMES[block_cat(s^)], block_name(s^)))
  imgui.TextUnformatted(fmt.ctprintf("%s", s.src))
  imgui.PopStyleColor(1)
  imgui.Separator()

  // Cond-carrying ops are interchangeable: they hold the same payload and differ only in what they do
  // with it, so switching between them is a one-click edit rather than delete-and-recreate.
  if s.op == .Branch || s.op == .Wait_For || s.op == .On {
    imgui.TextUnformatted("kind")
    imgui.SetNextItemWidth(-1)
    if imgui.BeginCombo("##edop", fmt.ctprintf("%s", BHV_OP_NAMES[s.op])) {
      ed_op_choice(ed, s, .Branch, "branch - test it and take one of two edges")
      ed_op_choice(ed, s, .Wait_For, "wait_for - block here until it is true")
      ed_op_choice(ed, s, .On, "on - an interrupt: checked before EVERY step, anywhere in the chart")
      imgui.EndCombo()
    }
    imgui.Dummy({0, px(4)})
  }

  // --- the condition
  if s.op == .Branch || s.op == .Wait_For || s.op == .On || s.op == .If || s.op == .While {
    imgui.SeparatorText("condition")
    ed_condition_editor(ed, s, &s.condition, f, "cond", ed.text_buffers[ED_TEXT_CONDITION:ED_TEXT_UNTIL])
  }

  // --- the action
  if s.op == .Action || s.op == .On {
    imgui.SeparatorText(s.op == .On ? "interrupt body" : "block")
    ed_action_editor(ed, s, f, ed.text_buffers[0:2])
  }

  if s.op == .Repeat || s.op == .Loop {
    imgui.SeparatorText("iterations")
    n := i32(s.count)
    imgui.SetNextItemWidth(-1)
    if imgui.DragInt("##edcount", &n, 1, 0, 9999) {
      s.count = int(max(0, n))
      ed_relabel(s)
      ed.dirty = true
    }
    if imgui.IsItemActivated() {
      ed_snapshot(ed)
    }
  }

  // --- until (a long-running action can end early)
  if s.op == .Action {
    imgui.SeparatorText("until (optional early-out)")
    has := s.has_until
    if imgui.Checkbox("end this block early when...##eduntil", &has) {
      ed_snapshot(ed)
      s.has_until = has
      if has && s.until.kind == .None {
        ed_set_event_kind(ed, s, &s.until, .Always)
      }
      ed_relabel(s)
      ed.dirty = true
    }
    if s.has_until {
      ed_condition_editor(ed, s, &s.until, f, "until", ed.text_buffers[ED_TEXT_UNTIL:ED_TEXT_BUFFERS_PER_STEP])
    }
  }

  // --- section
  //
  // `group` was read by four things (the canvas bands, find, the layout, the options panel) and
  // written by none: only builder.section() could stamp one, so a chart authored HERE could never be
  // organised at all. It is the same authoring-only annotation as ui_pos - the VM never looks at it -
  // and it is what turns forty nodes into five named parts.
  imgui.SeparatorText("section")
  if ed.text_buffers_for_node == s.id {
    imgui.SetNextItemWidth(-1)
    if imgui.InputTextWithHint("##edgroup", "which part of the chart is this?", cstring(raw_data(ed.section_buffer[:])), len(ed.section_buffer)) {
      delete(s.group)
      s.group = strings.clone(strings.trim_space(panel_buf_str(ed.section_buffer[:])))
      ed.dirty = true
    }
    if imgui.IsItemActivated() {
      ed_snapshot(ed)
    }
    if imgui.IsItemHovered() {
      imgui.SetTooltip("Nodes sharing a section are drawn inside one labelled band, and the options tab groups by it. Blank = no band.")
    }
  }

  // --- edges
  imgui.SeparatorText("flow")
  ed_edge_rows(ed, s)

  imgui.Dummy({0, px(8)})
  // Two ROWS, not one. "starts here (first node in the file)" is a long line, and SameLine'ing the
  // delete button after it pushed the button off the edge of the pane - a destructive action you could
  // see half of and not click.
  entry_now := ed.doc.entry == s.id || (ed.doc.entry == 0 && len(ed.doc.steps) > 0 && ed.doc.steps[0].id == s.id)
  // A watcher, or anything inside one's body, can never be the start. It is not a restriction so much
  // as a fact: control only ever arrives there because the trigger fired, and script_begin partitions
  // those nodes out of the main program entirely. Offering the button was how a chart ended up
  // claiming to start at a node the VM would never run first.
  is_watcher := make([]bool, len(ed.doc.steps), context.temp_allocator)
  ed_watcher_mask(ed, is_watcher)
  i_sel := ed_index(ed, s.id)
  in_watcher := i_sel >= 0 && is_watcher[i_sel]
  if entry_now && !in_watcher {
    imgui.PushStyleColorImVec4(.Text, COL_OK)
    imgui.TextWrapped("%s", ed.doc.entry == 0 ? "starts here (first node in the file)" : "starts here")
    imgui.PopStyleColor(1)
  } else if in_watcher {
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextWrapped(
      "%s",
      s.op == .On \
      ? "a watcher - it is checked before every step, so it is never where the chart starts" \
      : "part of a watcher's body - reached when its trigger fires, never from the start",
    )
    imgui.PopStyleColor(1)
  } else if imgui.Button("Start here", {-1, 0}) {
    ed.doc.entry = s.id
    ed.dirty = true
  }
  imgui.Dummy({0, px(4)})
  imgui.PushStyleColorImVec4(.Button, tint(COL_BAD, 0.25))
  if imgui.Button("Delete node", {-1, 0}) {
    ed_delete_node(ed, ed.sel)
  }
  imgui.PopStyleColor(1)
}

// ===========================================================================
// Chart options - every configurable value in the document, in one scroll
// ===========================================================================
//
// The panel is GENERATED, not written. It walks the document and renders each step's arguments through
// the same spec-driven ed_params the inspector uses, which is why the real work of this feature landed
// in script_blocks.odin rather than here: a knob is only as good as the sentence beside it, and the
// sentence lives in the catalog (script_selftest_meta is what keeps it there).
//
// Steps with nothing to configure are SKIPPED - every pick_* rung, stop, jump, and all the gotos. A
// farm chart is forty nodes and about a dozen numbers; listing the twenty-eight empty ones would bury
// the numbers, which is precisely the problem the panel exists to solve.

// How many editable fields does this step have? Zero means it does not appear in the options panel.
@(private = "file")
ed_step_option_count :: proc(s: Script_Step) -> int {
  // Every ROW of a condition counts: a branch on `always and kills 50` has one settable number even
  // though its first row has none, and skipping the node would hide it from the panel entirely.
  condition_param_count :: proc(c: Script_Condition) -> int {
    n := 0
    for i in 0 ..< condition_row_count(c) {
      if def := event_def(condition_row(c, i).kind); def != nil {
        n += len(def.params)
      }
    }
    return n
  }
  n := 0
  #partial switch s.op {
  case .Action:
    if def := action_def(s.action.kind); def != nil {
      n += len(def.params)
    }
    if s.has_until {
      n += condition_param_count(s.until)
    }
  case .On:
    n += condition_param_count(s.condition)
    if def := action_def(s.action.kind); def != nil {
      n += len(def.params)
    }
  case .Branch, .Wait_For, .If, .While:
    n += condition_param_count(s.condition)
  case .Repeat, .Loop:
    n += 1 // the iteration count
  }
  return n
}

// Does this step match the search box? Matches on everything the panel actually SHOWS - the block's
// title and spelling, its section, and every argument's title and help - so searching "range" finds
// the melee reach whether or not you remember which node holds it.
@(private = "file")
ed_option_match :: proc(s: Script_Step, query: string) -> bool {
  if query == "" {
    return true
  }
  hit :: proc(hay, needle: string) -> bool {
    return strings.contains(strings.to_lower(hay, context.temp_allocator), needle)
  }
  if hit(block_title(s), query) || hit(block_name(s), query) || hit(s.group, query) {
    return true
  }
  spec_hit :: proc(spec: []Param_Spec, query: string) -> bool {
    for p in spec {
      if strings.contains(strings.to_lower(param_title(p), context.temp_allocator), query) ||
         strings.contains(strings.to_lower(p.help, context.temp_allocator), query) ||
         strings.contains(p.name, query) {
        return true
      }
    }
    return false
  }
  if def := action_def(s.action.kind); def != nil && spec_hit(def.params, query) {
    return true
  }
  condition_matches_search :: proc(c: Script_Condition, query: string, spec_hit: proc(spec: []Param_Spec, query: string) -> bool) -> bool {
    for i in 0 ..< condition_row_count(c) {
      if def := event_def(condition_row(c, i).kind); def != nil && spec_hit(def.params, query) {
        return true
      }
    }
    return false
  }
  if condition_matches_search(s.condition, query, spec_hit) {
    return true
  }
  if s.has_until && condition_matches_search(s.until, query, spec_hit) {
    return true
  }
  return false
}

// One text buffer per string argument per node, because the panel draws every node at once. See the
// comment on Gui_Editor.options_text_buffers for why this is re-seeded on a revision counter rather than per frame.
@(private = "file")
ed_seed_options_text_buffers :: proc(ed: ^Gui_Editor) {
  need := len(ed.doc.steps) * ED_TEXT_BUFFERS_PER_STEP
  if ed.options_seeded_revision == ed.options_revision && ed.options_seeded_step_count == len(ed.doc.steps) && len(ed.options_text_buffers) == need {
    return
  }
  resize(&ed.options_text_buffers, need)
  for s, i in ed.doc.steps {
    b := i * ED_TEXT_BUFFERS_PER_STEP
    ed_seed_step_text_buffers(ed.options_text_buffers[b:b + ED_TEXT_BUFFERS_PER_STEP], s)
  }
  ed.options_seeded_revision = ed.options_revision
  ed.options_seeded_step_count = len(ed.doc.steps)
}

// Borrowed watchers: the middle scope. A chart names other behaviours whose watchers it wants hoisted
// into its own run, in priority order - so "always carry the escape hatch while farming" does not mean
// arming it for everything you ever run, and does not mean pasting a copy into every chart either.
//
// It lives in the options tab rather than on the canvas because it is a SETTING of the document, not a
// node: there is nothing to place and nothing to wire. The chips still say what each one watches for,
// because a list of bare filenames would be a list of things you have to go and open.
@(private = "file")
gui_ed_uses :: proc(ps: ^Panel_State, ed: ^Gui_Editor, f: ^Gui_Frame) {
  imgui.SeparatorText("Also watches for")
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextWrapped("Watchers borrowed from other behaviours. They are checked before every step of this chart, in this order, after its own.")
  imgui.PopStyleColor(1)

  drop := -1
  for u, i in ed.doc.uses {
    imgui.PushIDInt(i32(1000 + i))
    if imgui.SmallButton("x") {
      drop = i
    }
    if imgui.IsItemHovered() {
      imgui.SetTooltip("Stop borrowing it")
    }
    imgui.SameLine(0, px(8))
    n := bhv_watcher_count(u)
    imgui.PushStyleColorImVec4(.Text, n > 0 ? COL_TEXT : COL_BAD)
    imgui.TextUnformatted(fmt.ctprintf("%s", u))
    imgui.PopStyleColor(1)
    imgui.SameLine(0, px(8))
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextUnformatted(n > 0 ? fmt.ctprintf("%d watcher%s", n, n == 1 ? "" : "s") : "no watchers - it will be skipped")
    imgui.PopStyleColor(1)
    imgui.PopID()
  }
  if drop >= 0 {
    ed_snapshot(ed)
    delete(ed.doc.uses[drop])
    ordered_remove(&ed.doc.uses, drop)
    ed.dirty = true
  }

  // The picker offers only behaviours that HAVE a watcher, and never this document itself. Borrowing
  // something with nothing to borrow is the sort of no-op that reads as a bug.
  if imgui.SmallButton("+ borrow watchers from...") {
    imgui.OpenPopup("##edusespick")
  }
  if imgui.BeginPopup("##edusespick") {
    any := false
    for name in bhv_list_names() {
      if name == ed.doc.name || slice.contains(ed.doc.uses[:], name) {
        continue
      }
      if bhv_watcher_count(name) == 0 {
        continue
      }
      any = true
      if imgui.Selectable(fmt.ctprintf("%s", name)) {
        ed_snapshot(ed)
        append(&ed.doc.uses, strings.clone(name))
        ed.dirty = true
      }
    }
    if !any {
      imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
      imgui.TextUnformatted("Nothing to borrow - save a behaviour with an 'on' node first.")
      imgui.PopStyleColor(1)
    }
    imgui.EndPopup()
  }
  imgui.Dummy({0, px(4)})
}

// Every ROW's arguments, for the options panel. Which event each row is stays on the canvas - this
// pane sets values - so a multi-row condition contributes each row's numbers, labelled by its own
// block title when there is more than one and it would otherwise be ambiguous.
@(private = "file")
ed_condition_params :: proc(ed: ^Gui_Editor, s: ^Script_Step, id: cstring, condition: ^Script_Condition, text_buffers: [][ED_TEXT_BUFFER_SIZE]u8, f: ^Gui_Frame) {
  n := condition_row_count(condition^)
  for i in 0 ..< n {
    r := condition_row_ptr(condition, i)
    def := event_def(r.kind)
    if def == nil || len(def.params) == 0 {
      continue
    }
    if n > 1 {
      imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
      imgui.TextUnformatted(fmt.ctprintf("%s", event_title(r^)))
      imgui.PopStyleColor(1)
    }
    lo := i * 2
    if lo + 1 >= len(text_buffers) {
      continue
    }
    ed_params(ed, s, fmt.ctprintf("%s%d", id, i), def.params, &r.nums, &r.strs, text_buffers[lo:lo + 2], f)
  }
}

@(private = "file")
gui_ed_options :: proc(ps: ^Panel_State, ed: ^Gui_Editor, f: ^Gui_Frame) {
  ed_seed_options_text_buffers(ed)

  imgui.SetNextItemWidth(-1)
  imgui.InputTextWithHint("##optfilter", "search the settings", cstring(raw_data(ed.options_filter[:])), len(ed.options_filter))
  q := strings.to_lower(strings.trim_space(panel_buf_str(ed.options_filter[:])), context.temp_allocator)

  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextWrapped(
    "%s",
    fmt.ctprintf(
      "%s.  Only nodes with something to set are listed; click a heading to find it on the canvas.",
      ed_watchers_only(ed) \
      ? "Watchers only - nothing to run from the top" \
      : (ed.doc.mode == .Loop ? "Chart, loops forever" : "Chart, runs once"),
    ),
  )
  imgui.PopStyleColor(1)
  imgui.Dummy({0, px(4)})

  // The search box and the summary stay put; only the settings scroll.
  if !imgui.BeginChild("##optlist", {0, 0}) {
    imgui.EndChild()
    return
  }
  defer imgui.EndChild()

  gui_ed_uses(ps, ed, f)

  // The descriptions are spelled out here rather than left in tooltips: this pane IS what you are
  // reading, unlike the inspector, which sits beside a canvas you are reading instead.
  ed.param_help_inline = true
  defer ed.param_help_inline = false

  shown := 0
  last_group := ""
  first := true
  for &s, i in ed.doc.steps {
    if ed_step_option_count(s) == 0 || !ed_option_match(s, q) {
      continue
    }
    shown += 1
    if first || s.group != last_group {
      imgui.Dummy({0, px(6)})
      imgui.SeparatorText(fmt.ctprintf("%s", s.group == "" ? "Settings" : s.group))
      last_group = s.group
      first = false
    }

    // PushID makes every widget inside unique by NODE, so the fixed "##edact" / "cond" / "until" ids
    // the shared editors use can be reused verbatim for all forty of them.
    imgui.PushIDInt(i32(i))
    b := i * 6

    imgui.PushStyleColorImVec4(.Text, ed_node_color(s))
    if imgui.SmallButton(fmt.ctprintf("%s  #%d", block_title(s), u32(s.id))) {
      ed_sel_only(ed, s.id)
      ed_go_to(ed, s.id)
    }
    imgui.PopStyleColor(1)
    if imgui.IsItemHovered() {
      imgui.SetTooltip("Show this node on the canvas")
    }

    // Deliberately NOT ed_action_editor / ed_event_editor: those lead with a combo that swaps the
    // block for a different one, which is a structural edit and belongs on the canvas. This pane is
    // for VALUES. Showing the switcher here would also put two lines of blurb in front of every
    // setting, which is the density the panel exists to avoid.
    #partial switch s.op {
    case .Action:
      if def := action_def(s.action.kind); def != nil {
        ed_params(ed, &s, "act", def.params, &s.action.nums, &s.action.strs, ed.options_text_buffers[b + 0:b + 2], f)
      }
      if s.has_until {
        imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
        imgui.TextUnformatted(fmt.ctprintf("ends early when: %s", condition_title(s.until)))
        imgui.PopStyleColor(1)
        ed_condition_params(ed, &s, "until", &s.until, ed.options_text_buffers[b + ED_TEXT_UNTIL:b + ED_TEXT_BUFFERS_PER_STEP], f)
      }
    case .On:
      ed_condition_params(ed, &s, "cond", &s.condition, ed.options_text_buffers[b + ED_TEXT_CONDITION:b + ED_TEXT_UNTIL], f)
      if def := action_def(s.action.kind); def != nil {
        ed_params(ed, &s, "act", def.params, &s.action.nums, &s.action.strs, ed.options_text_buffers[b + 0:b + 2], f)
      }
    case .Branch, .Wait_For, .If, .While:
      ed_condition_params(ed, &s, "cond", &s.condition, ed.options_text_buffers[b + ED_TEXT_CONDITION:b + ED_TEXT_UNTIL], f)
    case .Repeat, .Loop:
      imgui.TextUnformatted("Times")
      n := i32(s.count)
      imgui.SetNextItemWidth(-1)
      if imgui.DragInt("##optcount", &n, 1, 0, 9999) {
        s.count = int(max(0, n))
        ed_relabel(&s)
        ed.dirty = true
      }
      if imgui.IsItemActivated() {
        ed_snapshot(ed)
      }
      if ed.param_help_inline {
        imgui.PushStyleColorImVec4(.Text, tint(COL_TEXT_DIM, 0.85))
        imgui.TextWrapped("How many passes over the body before control leaves the loop.")
        imgui.PopStyleColor(1)
      }
    }
    imgui.PopID()
    imgui.Dummy({0, px(6)})
  }

  if shown == 0 {
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.Dummy({0, px(8)})
    if q != "" {
      imgui.TextWrapped("%s", fmt.ctprintf("Nothing here matches '%s'.", q))
    } else if len(ed.doc.steps) == 0 {
      imgui.TextWrapped("This chart has no blocks yet. Add one from the canvas and its settings appear here.")
    } else {
      imgui.TextWrapped("Nothing in this chart takes a setting - every block it uses runs on the configured values.")
    }
    imgui.PopStyleColor(1)
  }
}

@(private = "file")
ed_op_choice :: proc(ed: ^Gui_Editor, s: ^Script_Step, op: Script_Op, tip: cstring) {
  if imgui.Selectable(fmt.ctprintf("%s", BHV_OP_NAMES[op]), s.op == op) && s.op != op {
    s.op = op
    if op == .On {
      // A watcher is hoisted out of the instruction stream, so it has no successors to name.
      s.goto_id = 0
      s.else_id = 0
    }
    ed_relabel(s)
    ed_touch(ed)
  }
  if imgui.IsItemHovered() {
    imgui.SetTooltip("%s", tip)
  }
}

// Both spellings in every row, same reason as the palette: the title is what you recognise, the name
// is what you would type on the command line, and they must never look like two different blocks.
@(private = "file")
ed_def_label :: proc(title, name: string) -> cstring {
  t := title != "" ? title : prose_title_of_name(name)
  return fmt.ctprintf("%s   -   %s", t, name)
}

@(private = "file")
ed_action_editor :: proc(ed: ^Gui_Editor, s: ^Script_Step, f: ^Gui_Frame, text_buffers: [][ED_TEXT_BUFFER_SIZE]u8) {
  cur := action_def(s.action.kind)
  imgui.SetNextItemWidth(-1)
  if imgui.BeginCombo("##edact", cur == nil ? "(pick a block)" : ed_def_label(cur.title, cur.name)) {
    for def in ACTIONS {
      // Same split as the palette (see ed_pal_row): only a NOT-BUILT block is unpickable. One that
      // merely needs an attach or a finder is a normal entry, drawn dim, with the reason on hover.
      if def.not_built {
        imgui.PushStyleColorImVec4(.Text, tint(COL_TEXT_DIM, 0.7))
        imgui.TextUnformatted(fmt.ctprintf("[xx] %s", ed_def_label(def.title, def.name)))
        imgui.PopStyleColor(1)
        if imgui.IsItemHovered() {
          imgui.SetTooltip("%s", fmt.ctprintf("%s\n\nNot built yet: %s", def.blurb, def.not_built_why))
        }
        continue
      }
      usable := f.action_usable[def.kind]
      if !usable {
        imgui.PushStyleColorImVec4(.Text, tint(COL_TEXT_DIM, 0.8))
      }
      if imgui.Selectable(ed_def_label(def.title, def.name), def.kind == s.action.kind) {
        ed_set_action_kind(ed, s, def.kind)
      }
      if !usable {
        imgui.PopStyleColor(1)
      }
      if imgui.IsItemHovered() {
        imgui.SetTooltip(
          "%s",
          usable \
          ? fmt.ctprintf("%s", def.blurb) \
          : fmt.ctprintf("%s\n\nCannot RUN yet: %s", def.blurb, f.action_why_not[def.kind]),
        )
      }
    }
    imgui.EndCombo()
  }
  if cur == nil {
    return
  }
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextWrapped("%s", fmt.ctprintf("%s", cur.blurb))
  imgui.PopStyleColor(1)
  ed_params(ed, s, "act", cur.params, &s.action.nums, &s.action.strs, text_buffers, f)
}

// A CONDITION, as rows: an All/Any selector and one line per event, each with its own NOT.
//
// This is what boolean logic looks like here, and why there are no AND/OR nodes on the canvas. A node
// would have meant a second kind of wire - a value feeding a control node - and a reader would have to
// keep both in their head to follow a chart. Rows are how a rule gets written down anyway, they fit in
// the pane that was already there, and they work identically in the four places a condition appears.
@(private = "file")
ed_condition_editor :: proc(ed: ^Gui_Editor, s: ^Script_Step, condition: ^Script_Condition, f: ^Gui_Frame, id: cstring, text_buffers: [][ED_TEXT_BUFFER_SIZE]u8) {
  n := condition_row_count(condition^)
  // The joiner only appears once there is something to join. On a one-row condition it would be a
  // control with no effect, which reads as something being broken.
  if n > 1 {
    imgui.SetNextItemWidth(px(110))
    if imgui.BeginCombo(fmt.ctprintf("##cm%s", id), condition.match_any ? "any of" : "all of") {
      if imgui.Selectable("all of", !condition.match_any) {
        ed_snapshot(ed)
        condition.match_any = false
        if s != nil {
          ed_relabel(s)
        }
        ed.dirty = true
      }
      if imgui.IsItemHovered() {
        imgui.SetTooltip("Every row has to hold.")
      }
      if imgui.Selectable("any of", condition.match_any) {
        ed_snapshot(ed)
        condition.match_any = true
        if s != nil {
          ed_relabel(s)
        }
        ed.dirty = true
      }
      if imgui.IsItemHovered() {
        imgui.SetTooltip("One row holding is enough.")
      }
      imgui.EndCombo()
    }
  }

  drop := -1
  for i in 0 ..< n {
    imgui.PushIDInt(i32(i))
    if n > 1 {
      if imgui.SmallButton("x") {
        drop = i
      }
      if imgui.IsItemHovered() {
        imgui.SetTooltip("Remove this condition")
      }
      imgui.SameLine(0, px(6))
    }
    lo := i * 2
    ed_condition_row_editor(ed, s, condition_row_ptr(condition, i), f, fmt.ctprintf("%s%d", id, i), lo + 1 < len(text_buffers) ? text_buffers[lo:lo + 2] : nil)
    imgui.PopID()
  }
  if drop >= 0 {
    ed_snapshot(ed)
    condition_remove_row(condition, drop)
    if s != nil {
      ed_relabel(s)
      ed.text_buffers_for_node = 0 // the rows shifted under the buffers
    }
    ed.options_revision += 1
    ed.dirty = true
  }
  if n < SCRIPT_MAX_CONDITION_ROWS {
    if imgui.SmallButton(fmt.ctprintf("+ add condition##%s", id)) {
      ed_snapshot(ed)
      condition_add_row(condition, Script_Event{kind = .Always})
      if s != nil {
        ed_relabel(s)
        ed.text_buffers_for_node = 0
      }
      ed.options_revision += 1
      ed.dirty = true
    }
    if imgui.IsItemHovered() {
      imgui.SetTooltip("Add another event to this test. Up to %d.", i32(SCRIPT_MAX_CONDITION_ROWS))
    }
  }
}

@(private = "file")
ed_condition_row_editor :: proc(ed: ^Gui_Editor, s: ^Script_Step, event: ^Script_Event, f: ^Gui_Frame, id: cstring, text_buffers: [][ED_TEXT_BUFFER_SIZE]u8) {
  def := event_def(event.kind)
  negated := event.negate
  if imgui.Checkbox(fmt.ctprintf("not##%s", id), &negated) {
    event.negate = negated
    if s != nil {
      ed_relabel(s)
    }
    ed.dirty = true
  }
  if imgui.IsItemHovered() {
    imgui.SetTooltip("Invert it. The negation lives on the event, so it works the same in every slot it can appear.")
  }
  imgui.SameLine(0, px(8))
  imgui.SetNextItemWidth(-1)
  if imgui.BeginCombo(fmt.ctprintf("##ev%s", id), def == nil ? "(pick an event)" : ed_def_label(def.title, def.name)) {
    for def in EVENTS {
      if def.not_built { // see the action combo above - only "no code behind it" is unpickable
        imgui.PushStyleColorImVec4(.Text, tint(COL_TEXT_DIM, 0.7))
        imgui.TextUnformatted(fmt.ctprintf("[xx] %s", ed_def_label(def.title, def.name)))
        imgui.PopStyleColor(1)
        if imgui.IsItemHovered() {
          imgui.SetTooltip("%s", fmt.ctprintf("%s\n\nNot built yet: %s", def.blurb, def.not_built_why))
        }
        continue
      }
      usable := f.event_usable[def.kind]
      if !usable {
        imgui.PushStyleColorImVec4(.Text, tint(COL_TEXT_DIM, 0.8))
      }
      if imgui.Selectable(fmt.ctprintf("%s##%s", ed_def_label(def.title, def.name), id), def.kind == event.kind) {
        ed_set_event_kind(ed, s, event, def.kind)
      }
      if !usable {
        imgui.PopStyleColor(1)
      }
      if imgui.IsItemHovered() {
        imgui.SetTooltip(
          "%s",
          usable \
          ? fmt.ctprintf("%s", def.blurb) \
          : fmt.ctprintf("%s\n\nCannot RUN yet: %s", def.blurb, f.event_why_not[def.kind]),
        )
      }
    }
    imgui.EndCombo()
  }
  if def == nil {
    return
  }
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextWrapped("%s", fmt.ctprintf("%s", def.blurb))
  imgui.PopStyleColor(1)
  ed_params(ed, s, id, def.params, &event.nums, &event.strs, text_buffers, f)
}

// ONE renderer for every block's arguments, driven by its []Param_Spec. That is what makes adding a
// block to script_blocks.odin the whole change: the catalog row teaches the parser, the printer, the
// availability gate AND this editor about it at once, with no per-block UI code anywhere.
//
// param_slot decides which storage slot each argument lands in - the same derivation the file format
// uses, so what you edit here is what gets written and what the block reads.
@(private = "file")
ed_params :: proc(
  ed: ^Gui_Editor,
  s: ^Script_Step, // nil for a payload that is not a node's (the document's trigger)
  id: cstring,
  spec: []Param_Spec,
  nums: ^[4]f64,
  strs: ^[2]string,
  text_buffers: [][ED_TEXT_BUFFER_SIZE]u8, // exactly the two text buffers this payload's string arguments edit through
  f: ^Gui_Frame,
) {
  // One undo entry per EDITING SESSION of a field, not per value change: a DragFloat fires on every
  // pixel of mouse movement, and thirty snapshots for one drag would bury the edit before it under
  // thirty Ctrl+Z presses. IsItemActivated is the "you started editing this" edge - it needs a widget
  // to be submitted first, hence the check after each one rather than before.
  snap_on_edit_start :: proc(ed: ^Gui_Editor) {
    if imgui.IsItemActivated() {
      ed_snapshot(ed)
    }
  }
  // The label is the catalog's TITLE, not its identifier. The identifier is still reachable - it is in
  // the tooltip, next to the description - because it is what you type at the REPL and what the .bhv
  // file says, and a panel that hid it would leave you unable to connect the two.
  help_tip :: proc(p: Param_Spec, title: string) {
    if !imgui.IsItemHovered() {
      return
    }
    if p.help == "" {
      imgui.SetTooltip("%s", fmt.ctprintf("%s  (%s)", title, p.name))
      return
    }
    imgui.SetTooltip("%s", fmt.ctprintf("%s  (%s)\n\n%s", title, p.name, p.help))
  }

  // Two densities. The inspector keeps ImGui's label-to-the-right form, which is compact and fine next
  // to a canvas. The options panel is a FORM - a narrow column you read top to bottom - so the label
  // goes on its own line above a full-width field, with the description under it.
  inline := ed.param_help_inline
  fieldw := inline ? f32(-1) : px(150)

  for p, i in spec {
    slot := param_slot(spec, i)
    title := param_title(p)
    label := fmt.ctprintf("%s##%s%d", title, id, i)
    if inline {
      imgui.TextUnformatted(fmt.ctprintf("%s", title))
      label = fmt.ctprintf("##%s%d", id, i)
    }
    changed := false
    // An optional argument still at its default is not empty, it is DEFERRING - to the configured
    // attack_range, to "any monster". Drawing it dim says that, where a black 0 would read as a
    // decision somebody made.
    defaulted := param_is_default(spec, i, nums^, strs^)
    if defaulted {
      imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    }
    switch p.kind {
    case .Num:
      // A 0/1 flag is a number to the parser and to the file, but nobody wants to drag a float to set
      // one. The widget is a checkbox; the storage is untouched.
      if p.unit == "bool" {
        on := nums[slot] != 0
        if imgui.Checkbox(label, &on) {
          nums[slot] = on ? 1 : 0
          changed = true
        }
        snap_on_edit_start(ed)
        help_tip(p, title)
      } else {
        val := f32(nums[slot])
        imgui.SetNextItemWidth(fieldw)
        if imgui.DragFloat(label, &val, 0.25, f32(p.min_value), f32(p.max_value), "%.2f") {
          nums[slot] = f64(val)
          changed = true
        }
        snap_on_edit_start(ed)
        help_tip(p, title)
      }
    case .Duration:
      // No unit in the format string: Duration is not always seconds (elapsed takes MINUTES), and the
      // parameter's own title is what says which. Stamping " s" on it would have been a confident lie.
      val := f32(nums[slot])
      imgui.SetNextItemWidth(fieldw)
      if imgui.DragFloat(label, &val, 0.05, f32(p.min_value), f32(p.max_value), "%.3f") {
        nums[slot] = f64(max(0, val))
        changed = true
      }
      snap_on_edit_start(ed)
      help_tip(p, title)
    case .Percent:
      val := f32(nums[slot])
      imgui.SetNextItemWidth(fieldw)
      if imgui.SliderFloat(label, &val, 0, 100, "%.0f%%") {
        nums[slot] = f64(val)
        changed = true
      }
      snap_on_edit_start(ed)
      help_tip(p, title)
    case .Coord:
      // `unit == "rel"` marks the Coord as an OFFSET rather than a place (walk_by, jump_by). Two things
      // change: the axes are signed, and there is NO "Here" button - pasting your absolute world position
      // into a field that means "how far from here" is the one answer that is always wrong.
      relative := p.unit == "rel"
      _, expression_slot := param_slots(spec, i)
      field_id := fmt.ctprintf("%s%d", id, i)
      expression_hash := suggest_id_hash(field_id)
      // Two states, one of them derived: a Coord IS an expression when it holds one. The latch only
      // exists to hold the empty case open - the frame between clicking @ and typing a name, where
      // there is nothing in the data to say which form you asked for.
      as_expression := strs[expression_slot] != "" || ed.coord_expression_field == expression_hash
      if imgui.SmallButton(fmt.ctprintf("%s##%dat", as_expression ? "1,2" : "@", i)) {
        ed_snapshot(ed)
        if as_expression {
          delete(strs[expression_slot])
          strs[expression_slot] = strings.clone("")
          ed.coord_expression_field = 0
        } else {
          ed.coord_expression_field = expression_hash
        }
        ed.text_buffers_for_node = 0 // the slot's text changed under the buffers
        ed.options_revision += 1
        changed = true
        as_expression = !as_expression
      }
      if imgui.IsItemHovered() {
        imgui.SetTooltip(
          "%s",
          as_expression \
          ? "Back to typing the numbers." \
          : "Use a variable instead - @spot, set by a 'Remember this spot' block or by `var spot 6800,3300`. A chart written this way works wherever you start it.",
        )
      }
      imgui.SameLine(0, px(6))
      if as_expression {
        if slot >= 0 && expression_slot < len(text_buffers) {
          // The corpus is every variable the chart sets, not only the ones that look like positions:
          // a name may be copied from another variable or written by the REPL, so deciding statically
          // which ones "are" positions would leave out the interesting cases and buy nothing - a
          // suggestion you do not want costs one glance.
          names := chart_variable_names(&ed.doc)
          referenced := make([]string, len(names), context.temp_allocator)
          for n, k in names {
            referenced[k] = fmt.tprintf("@%s", n)
          }
          if ed_suggest_field(
            ed,
            field_id,
            label,
            &strs[expression_slot],
            text_buffers[expression_slot][:],
            .Str,
            nil,
            "@spot",
            inline ? f32(-1) : px(200),
            f,
            referenced,
          ) {
            changed = true
          }
          snap_on_edit_start(ed)
          help_tip(p, title)
        }
        if !inline {
          imgui.SameLine(0, px(8))
          imgui.TextUnformatted(fmt.ctprintf("%s", title))
          help_tip(p, title)
        }
        break
      }
      x := f32(nums[slot])
      z := f32(nums[slot + 1])
      imgui.SetNextItemWidth(px(90))
      if imgui.DragFloat(fmt.ctprintf("##%s%dx", id, i), &x, 0.5, 0, 0, relative ? "dx %+.1f" : "x %.1f") {
        nums[slot] = f64(x)
        changed = true
      }
      snap_on_edit_start(ed)
      help_tip(p, title)
      imgui.SameLine(0, px(6))
      imgui.SetNextItemWidth(px(90))
      if imgui.DragFloat(fmt.ctprintf("##%s%dz", id, i), &z, 0.5, 0, 0, relative ? "dz %+.1f" : "z %.1f") {
        nums[slot + 1] = f64(z)
        changed = true
      }
      snap_on_edit_start(ed)
      help_tip(p, title)
      if relative {
        imgui.SameLine(0, px(6))
        if imgui.Button(fmt.ctprintf("0,0##%s%d", id, i), {px(52), 0}) {
          nums[slot], nums[slot + 1] = 0, 0
          changed = true
        }
        if imgui.IsItemHovered() {
          imgui.SetTooltip("Back to no offset. An offset of 0,0 means \"walk to where you already are\", i.e. nowhere.")
        }
      } else {
        imgui.SameLine(0, px(6))
        if !f.player_have {
          imgui.BeginDisabled()
        }
        if imgui.Button(fmt.ctprintf("Here##%s%d", id, i), {px(64), 0}) {
          nums[slot] = f64(f.player_pos[0])
          nums[slot + 1] = f64(f.player_pos[2])
          changed = true
        }
        if !f.player_have {
          imgui.EndDisabled()
        }
        if imgui.IsItemHovered() {
          imgui.SetTooltip(
            "%s",
            f.player_have \
            ? fmt.ctprintf("Use where you are standing now (%.1f, %.1f)", f.player_pos[0], f.player_pos[2]) \
            : "Needs a live position - attach and run setup first",
          )
        }
      }
      if !inline {
        imgui.SameLine(0, px(8))
        imgui.TextUnformatted(fmt.ctprintf("%s", title))
        help_tip(p, title)
      }
    case .Str:
      if slot >= 0 && slot < len(text_buffers) {
        imgui.SetNextItemWidth(inline ? f32(-1) : px(200))
        if imgui.InputTextWithHint(label, "", cstring(raw_data(text_buffers[slot][:])), len(text_buffers[slot])) {
          delete(strs[slot])
          strs[slot] = strings.clone(panel_buf_str(text_buffers[slot][:]))
          changed = true
        }
        snap_on_edit_start(ed)
        help_tip(p, title)
      }
    case .Names, .Mob, .Key, .Var_Name, .Choice:
      // Everything the catalog says something about the SHAPE of. Storage is identical to .Str - one
      // string slot - and so is the file; the kind only decides what gets offered while you type.
      if slot >= 0 && slot < len(text_buffers) {
        hint: cstring = ""
        switch p.kind {
        case .Names:
          hint = "blank = any monster"
        case .Mob:
          hint = "monster name"
        case .Key:
          hint = "F1, 1, space, w ..."
        case .Var_Name:
          hint = "name, not @name"
        case .Choice, .Str, .Num, .Duration, .Percent, .Coord:
        }
        if ed_suggest_field(
          ed,
          fmt.ctprintf("%s%d", id, i),
          label,
          &strs[slot],
          text_buffers[slot][:],
          p.kind,
          p.choices,
          hint,
          inline ? f32(-1) : px(200),
          f,
        ) {
          changed = true
        }
        snap_on_edit_start(ed)
        help_tip(p, title)
      }
    }
    if defaulted {
      imgui.PopStyleColor(1)
    }
    // The options panel spells the description out under every field; the node inspector leaves it in
    // the tooltip. Same renderer, two densities - the inspector is a sidebar next to a canvas you are
    // reading, the options panel IS what you are reading.
    if ed.param_help_inline && p.help != "" {
      imgui.PushStyleColorImVec4(.Text, tint(COL_TEXT_DIM, 0.85))
      imgui.TextWrapped("%s", fmt.ctprintf("%s", p.help))
      imgui.PopStyleColor(1)
      imgui.Dummy({0, px(3)})
    }
    if changed {
      if s != nil {
        ed_relabel(s)
      }
      ed.dirty = true
    }
  }
}

// One step's owned strings into one ED_TEXT_BUFFERS_PER_STEP-sized window. Shared by the inspector (which has
// exactly one window) and the options panel (which keeps one per node), so the two can never disagree
// about which slot a row's text lives in.
@(private = "file")
ed_seed_step_text_buffers :: proc(text_buffers: [][ED_TEXT_BUFFER_SIZE]u8, s: Script_Step) {
  if len(text_buffers) < ED_TEXT_BUFFERS_PER_STEP {
    return
  }
  panel_buf_set(text_buffers[0][:], s.action.strs[0])
  panel_buf_set(text_buffers[1][:], s.action.strs[1])
  for i in 0 ..< SCRIPT_MAX_CONDITION_ROWS {
    cs := i < condition_row_count(s.condition) ? condition_row(s.condition, i).strs : [2]string{}
    us := i < condition_row_count(s.until) ? condition_row(s.until, i).strs : [2]string{}
    panel_buf_set(text_buffers[ED_TEXT_CONDITION + i * 2][:], cs[0])
    panel_buf_set(text_buffers[ED_TEXT_CONDITION + i * 2 + 1][:], cs[1])
    panel_buf_set(text_buffers[ED_TEXT_UNTIL + i * 2][:], us[0])
    panel_buf_set(text_buffers[ED_TEXT_UNTIL + i * 2 + 1][:], us[1])
  }
}

// Copy the selected step's owned strings into the widget buffers. Editing writes straight back into
// the step, so this only has to run when the step - or the block occupying it - changes underneath.
@(private = "file")
ed_seed_buffers :: proc(ed: ^Gui_Editor, s: ^Script_Step) {
  ed_seed_step_text_buffers(ed.text_buffers[:], s^)
  panel_buf_set(ed.section_buffer[:], s.group)
  ed.text_buffers_for_node = s.id
}

// The flow section: where control actually goes, spelled out. An implicit fall-through is named as
// such rather than shown as "none", because "none" would be a lie - the walker goes somewhere.
@(private = "file")
ed_edge_rows :: proc(ed: ^Gui_Editor, s: ^Script_Step) {
  i := ed_index(ed, s.id)
  if i < 0 {
    return
  }
  edges: [3]Ed_Edge
  n := ed_edges(ed, i, &edges)
  if n == 0 {
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextUnformatted(s.op == .On ? "an interrupt - checked before every step" : "the program ends here")
    imgui.PopStyleColor(1)
    return
  }
  for e in edges[:n] {
    t := ed_step(ed, e.to)
    // The DESTINATION BY NAME. A bare "#7" was the whole complaint: it names a node you then have to
    // go find, which on a chart that loops back on itself is most of the work of reading it.
    imgui.PushStyleColorImVec4(.Text, ed_edge_color(e.kind))
    imgui.TextUnformatted(fmt.ctprintf("%-9s -> %s", ed_edge_word(e.kind, s.op), t == nil ? "(nowhere)" : block_title(t^)))
    imgui.PopStyleColor(1)
    if imgui.IsItemHovered() && t != nil {
      imgui.SetTooltip("%s", fmt.ctprintf("#%d   %s", u32(t.id), t.src))
    }
    if t != nil {
      imgui.SameLine(0, px(8))
      if imgui.SmallButton(fmt.ctprintf("go##g%d", u32(e.to))) {
        ed_go_to(ed, e.to)
      }
      if imgui.IsItemHovered() {
        imgui.SetTooltip("Centre the canvas on it")
      }
    }
    if e.kind == .Seq {
      imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
      // Wrapped at the panel's own width. Left to its natural length it pushes a horizontal scrollbar
      // into the inspector, which then clips the row above it.
      imgui.PushTextWrapPos(imgui.GetContentRegionAvail().x)
      imgui.TextUnformatted("(the next node in the file - drag a wire to name one)")
      imgui.PopTextWrapPos()
      imgui.PopStyleColor(1)
    }
    if e.port >= 0 {
      imgui.SameLine(0, px(8))
      if imgui.SmallButton(fmt.ctprintf("clear##e%d", e.port)) {
        ed_wire(ed, s.id, e.port, 0)
      }
    }
  }

  // What LEADS here. Only ever visible on the canvas as an arrowhead, which tells you a wire arrives
  // and nothing about where from.
  ins := ed_edges_into(ed, s.id)
  if len(ins) > 0 {
    imgui.Dummy({0, px(4)})
    for e in ins {
      t := ed_step(ed, e.from)
      imgui.PushStyleColorImVec4(.Text, tint(ed_edge_color(e.kind), 0.8))
      imgui.TextUnformatted(fmt.ctprintf("%-9s <- %s", ed_edge_word(e.kind, t == nil ? Script_Op.Action : t.op), t == nil ? "?" : block_title(t^)))
      imgui.PopStyleColor(1)
      imgui.SameLine(0, px(8))
      if imgui.SmallButton(fmt.ctprintf("go##i%d", u32(e.from))) {
        ed_go_to(ed, e.from)
      }
    }
  }
}

// `from` is the op the edge LEAVES, because one edge kind can mean two things: .Loop drawn out of an
// .End is the back-edge of a structured loop ("loop back"), while .Loop drawn out of a .Loop node is
// the body it takes N times ("each pass"). Naming both "loop" was accurate and told you nothing.
@(private = "file")
ed_edge_word :: proc(kind: Ed_Edge_Kind, from: Script_Op = .Action) -> string {
  if from == .Loop {
    return kind == .Loop ? "each pass" : "when done"
  }
  switch kind {
  case .Seq:
    return "next"
  case .Next:
    return "next"
  case .True:
    return "true"
  case .False:
    return "false"
  case .Fail:
    return "failed"
  case .Skip:
    return "skip"
  case .Loop:
    return "loop"
  }
  return "?"
}

// --- problems ----------------------------------------------------------------------------------------
//
// The static half of "what is wrong with this chart" (script_lint.odin has the analysis; this only
// renders it). Every row is a BUTTON that centres the canvas on its node, because a problem you then
// have to go and find is most of the work still left.
//
// Notes are hidden behind a checkbox. They are true and legitimate - the last rung of a ladder has
// nowhere to fall back to, a held key is released when the run ends - and a list where the four things
// that matter sit among fifteen that do not is a list that gets skimmed.

@(private = "file")
gui_ed_problems :: proc(ed: ^Gui_Editor, problems: []Chart_Problem) {
  errors := script_lint_count(problems, .Error)
  warnings := script_lint_count(problems, .Warning)
  notes := script_lint_count(problems, .Note)

  if errors + warnings == 0 {
    imgui.PushStyleColorImVec4(.Text, COL_OK)
    imgui.TextUnformatted("Nothing wrong with this chart.")
    imgui.PopStyleColor(1)
  } else {
    imgui.PushStyleColorImVec4(.Text, errors > 0 ? COL_BAD : COL_WARN)
    imgui.TextUnformatted(fmt.ctprintf("%d error(s), %d warning(s)", errors, warnings))
    imgui.PopStyleColor(1)
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextWrapped("An ERROR means the chart will not do what it looks like it does. A warning means it probably will not do what you meant.")
    imgui.PopStyleColor(1)
  }
  if notes > 0 {
    imgui.Checkbox(fmt.ctprintf("show %d note(s)", notes), &ed.show_notes)
    if imgui.IsItemHovered() {
      imgui.SetTooltip("Things that are true and legitimate, but easy to have not meant - an unwired fail port, a coin flip with no wait in front of it.")
    }
  }
  imgui.Separator()

  shown := 0
  for level in Chart_Problem_Level {
    if level == .Note && !ed.show_notes {
      continue
    }
    for p in problems {
      if p.level != level {
        continue
      }
      shown += 1
      imgui.PushIDInt(i32(shown))
      col := COL_WARN
      switch p.level {
      case .Error:
        col = COL_BAD
      case .Warning:
        col = COL_WARN
      case .Note:
        col = COL_TEXT_DIM
      }
      // The node chip and the text are one clickable row. SmallButton for the chip so the id is obvious
      // and the hit area is the thing you aim at; the sentence beside it is the payload.
      if p.node != 0 {
        imgui.PushStyleColorImVec4(.Text, col)
        if imgui.SmallButton(fmt.ctprintf("#%d", u32(p.node))) {
          ed_go_to(ed, p.node)
        }
        imgui.PopStyleColor(1)
        if imgui.IsItemHovered() {
          imgui.SetTooltip("Go to this node")
        }
        imgui.SameLine(0, px(6))
      } else {
        imgui.PushStyleColorImVec4(.Text, col)
        imgui.TextUnformatted("chart")
        imgui.PopStyleColor(1)
        imgui.SameLine(0, px(6))
      }
      imgui.PushStyleColorImVec4(.Text, col)
      imgui.TextWrapped("%s", fmt.ctprintf("%s", p.text))
      imgui.PopStyleColor(1)
      if p.hint != "" {
        imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
        imgui.TextWrapped("%s", fmt.ctprintf("      %s", p.hint))
        imgui.PopStyleColor(1)
      }
      imgui.Spacing()
      imgui.PopID()
    }
  }
}

// --- the run log -------------------------------------------------------------------------------------
//
// What the machine actually DID, newest last, read out of the session's trace ring (script.odin). The
// gap this closes: every one of these lines already went to the console, and the console is not where
// somebody working in a node editor is looking - so a chart that died on its second node with a printed
// reason looked, from in here, like a chart that never started.
//
// Rows are clickable and centre the canvas on their node, the same as a problem row: the two panels
// answer "what is wrong" and "what happened", and both answers are about a place on the graph.

@(private = "file")
gui_ed_trace :: proc(ps: ^Panel_State, ed: ^Gui_Editor, f: ^Gui_Frame) {
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  if f.trace_count == 0 {
    imgui.TextUnformatted("Run log - empty. Press play, or step, and every block the chart executes appears here.")
  } else {
    imgui.TextUnformatted(fmt.ctprintf("Run log - last %d of %d ('script trace' prints the lot)", f.trace_count, f.trace_total))
  }
  imgui.PopStyleColor(1)
  imgui.SameLine(0, px(12))
  imgui.Checkbox("follow", &ed.trace_follow)
  if imgui.IsItemHovered() {
    imgui.SetTooltip("Keep the newest row in view. Turn it off to scroll back without being yanked forward.")
  }
  // ENQUEUED, not a direct wipe: the ring lives on Session and the watcher thread writes it, so the draw
  // phase clearing it in place would be a write from the wrong side of exec_mutex.
  imgui.SameLine(0, px(12))
  no_rows := f.trace_count == 0
  if no_rows {
    imgui.BeginDisabled()
  }
  if imgui.SmallButton("clear") {
    panel_enqueue(ps, "script trace clear")
  }
  if no_rows {
    imgui.EndDisabled()
  }
  if imgui.IsItemHovered() {
    imgui.SetTooltip("Empty the log. Starting a run clears it anyway - this is for reading one run's worth without the last one above it.")
  }
  imgui.Separator()

  if imgui.BeginChild("##tracerows", {0, 0}) {
    // Relative to the FIRST row shown: what you read off a log is how long the chart sat somewhere, and
    // absolute stamps on a run that started an hour ago are unreadable.
    base := f.trace_count > 0 ? f.trace[0].at : i64(0)
    for i in 0 ..< f.trace_count {
      r := &f.trace[i]
      col := COL_TEXT
      switch r.level {
      case .Step:
        col = tint(COL_TEXT, 0.85)
      case .Note:
        col = COL_ACCENT
      case .Warn:
        col = COL_WARN
      case .Error:
        col = COL_BAD
      }
      imgui.PushIDInt(i32(i))
      imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
      imgui.TextUnformatted(fmt.ctprintf("%7.2fs", f64(r.at - base) / 1e9))
      imgui.PopStyleColor(1)
      imgui.SameLine(0, px(8))
      if r.node != 0 {
        imgui.PushStyleColorImVec4(.Text, tint(col, 0.8))
        if imgui.SmallButton(fmt.ctprintf("#%d", u32(r.node))) {
          ed_go_to(ed, r.node)
        }
        imgui.PopStyleColor(1)
      } else {
        imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
        imgui.TextUnformatted("  --  ")
        imgui.PopStyleColor(1)
      }
      imgui.SameLine(0, px(8))
      imgui.PushStyleColorImVec4(.Text, col)
      imgui.TextUnformatted(fmt.ctprintf("%s", script_trace_text(r)))
      imgui.PopStyleColor(1)
      imgui.PopID()
    }
    if ed.trace_follow {
      imgui.SetScrollHereY(1.0)
    }
  }
  imgui.EndChild()
}

// --- legend ------------------------------------------------------------------------------------------

@(private = "file")
gui_ed_legend :: proc(ed: ^Gui_Editor) {
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted("wires:")
  imgui.PopStyleColor(1)
  ed_legend_chip(.Seq, "falls through")
  ed_legend_chip(.Next, "goto")
  ed_legend_chip(.True, "true")
  ed_legend_chip(.False, "false")
  ed_legend_chip(.Fail, "didn't work")
  ed_legend_chip(.Skip, "block exit")
  ed_legend_chip(.Loop, "loop back")
  imgui.SameLine(0, px(16))
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  // Zoom only. The shortcut list lives in the inspector, where it has room to be complete - spelling a
  // subset of it out here made the strip wider than the window and clipped its own last word.
  imgui.TextUnformatted(fmt.ctprintf("zoom %.0f%%", ed.zoom * 100))
  imgui.PopStyleColor(1)

  // Second row: what the node COLOURS mean. Hovering a chip is not needed - the whole point of the
  // key is that it is readable without interaction - but the icons are repeated from the nodes so the
  // two halves of the encoding (colour and glyph) are learned together.
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted("nodes:")
  imgui.PopStyleColor(1)
  for cat in Block_Cat {
    ed_legend_cat(cat)
  }
}

@(private = "file")
ed_legend_cat :: proc(cat: Block_Cat) {
  imgui.SameLine(0, px(10))
  dl := imgui.GetWindowDrawList()
  p := imgui.GetCursorScreenPos()
  fh := imgui.GetTextLineHeight()
  label := fmt.ctprintf("%s", BLOCK_CAT_NAMES[cat])
  w := px(16) + imgui.CalcTextSize(label).x
  imgui.Dummy({w, fh})
  col := ed_cat_color(cat)
  gui_draw_icon(dl, p.x + px(6), p.y + fh * 0.5, ed_cat_icon(cat), col)
  imgui.DrawList_AddText(dl, {p.x + px(15), p.y}, u32_of(tint(col, 0.9)), label)
}

@(private = "file")
ed_legend_chip :: proc(kind: Ed_Edge_Kind, label: cstring) {
  imgui.SameLine(0, px(10))
  dl := imgui.GetWindowDrawList()
  p := imgui.GetCursorScreenPos()
  fh := imgui.GetTextLineHeight()
  imgui.Dummy({px(16), fh})
  imgui.DrawList_AddLine(dl, {p.x, p.y + fh * 0.5}, {p.x + px(14), p.y + fh * 0.5}, u32_of(ed_edge_color(kind)), px(2))
  imgui.SameLine(0, px(4))
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted(label)
  imgui.PopStyleColor(1)
}
