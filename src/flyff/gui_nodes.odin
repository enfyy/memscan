package flyff

import "core:fmt"
import "core:math"
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
ED_LAYOUT_DY :: f32(112) // vertical pitch used by the auto-layout - wide enough that a wire is a wire
ED_LAYOUT_DX :: f32(58) // horizontal indent per nesting level
ED_INSPECTOR_W :: f32(330)

// What the mouse is doing between press and release. One field instead of three bools because the
// gestures are mutually exclusive and deciding WHICH at press time is the whole trick - it is what
// lets a single background InvisibleButton drive panning, node dragging and wiring without any
// per-node ImGui items fighting each other for the hover.
Ed_Gesture :: enum {
  None,
  Pan,
  Drag,
  Link,
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

  // interaction
  sel:        Node_Id,
  gesture:    Ed_Gesture,
  drag_id:    Node_Id,
  link_from:  Node_Id,
  link_port:  int,

  // add-node palette
  pal_seed:   bool, // focus the filter box on the frame it opens
  pal_filter: [64]u8,
  pal_at:     [2]f32, // where the created node lands, in canvas units
  pal_wire:   Node_Id, // wire the new node up from this node's port (0 = free-standing)
  pal_port:   int,

  // Inspector text buffers, indexed [payload*2 + slot] where payload is 0=action, 1=cond, 2=until.
  // Re-seeded whenever the selection or a block kind changes; buf_for is what detects that.
  buf_for:    Node_Id,
  sbuf:       [6][64]u8,

  // The trigger's own buffers. Separate from sbuf because the trigger belongs to the DOCUMENT, not to
  // whichever node happens to be selected - it must survive a selection change, and it has to be
  // seeded even when nothing is selected at all.
  tbuf:       [2][64]u8,
  tbuf_ok:    bool,
}

// ===========================================================================
// Lifetime
// ===========================================================================

gui_editor_free :: proc(ed: ^Gui_Editor) {
  if ed.doc.name != "" || ed.doc.steps != nil {
    behaviour_doc_free(&ed.doc)
  }
  delete(ed.msg)
  ed^ = {}
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
gui_editor_open :: proc(ps: ^Panel_State, name: string) {
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
// pile. Lay them out in program order, indented by block depth - the same depth walk script_render
// does - so an exported built-in reads on the canvas the way `script show` reads in the console.
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
  depth := 0
  y := f32(0)
  for &s in ed.doc.steps {
    #partial switch s.op {
    case .End, .Else:
      depth = max(0, depth - 1)
    }
    s.ui_pos = {f32(depth) * ED_LAYOUT_DX, y}
    y += ED_LAYOUT_DY
    #partial switch s.op {
    case .If, .Repeat, .While, .Else:
      depth += 1
    }
  }
}

// Centre the view on everything, and zoom out (never in) far enough to hold it.
@(private = "file")
ed_focus_all :: proc(ed: ^Gui_Editor) {
  if len(ed.doc.steps) == 0 {
    ed.pan = {ED_NODE_W * 0.5, ED_NODE_H * 0.5}
    return
  }
  lo := ed.doc.steps[0].ui_pos
  hi := lo + [2]f32{ED_NODE_W, ED_NODE_H}
  for s in ed.doc.steps {
    lo[0] = min(lo[0], s.ui_pos[0])
    lo[1] = min(lo[1], s.ui_pos[1])
    hi[0] = max(hi[0], s.ui_pos[0] + ED_NODE_W)
    hi[1] = max(hi[1], s.ui_pos[1] + ED_NODE_H)
  }
  ed.pan = (lo + hi) * 0.5
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
    slot := param_slot(spec, i)
    switch p.kind {
    case .Num, .Duration, .Percent:
      nums[slot] = p.optional ? p.def : 0
    case .Coord:
      nums[slot] = 0
      nums[slot + 1] = 0
    case .Str, .Names:
      strs[slot] = strings.clone("")
    }
  }
}

@(private = "file")
ed_set_action_kind :: proc(ed: ^Gui_Editor, s: ^Script_Step, kind: Script_Action_Kind) {
  delete(s.action.strs[0])
  delete(s.action.strs[1])
  s.action = Script_Action {
    kind = kind,
  }
  if def := action_def(kind); def != nil {
    ed_defaults(def.params, &s.action.nums, &s.action.strs)
  }
  ed_relabel(s)
  ed.buf_for = 0 // the payload moved under the inspector's buffers - reseed them
  ed.dirty = true
}

@(private = "file")
ed_set_event_kind :: proc(ed: ^Gui_Editor, s: ^Script_Step, ev: ^Script_Event, kind: Script_Event_Kind) {
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
  // s is nil when the event edited is the DOCUMENT's trigger, which labels no node.
  if s != nil {
    ed_relabel(s)
    ed.buf_for = 0 // the payload moved under the inspector's buffers - reseed them
  } else {
    ed.tbuf_ok = false
  }
  ed.dirty = true
}

@(private = "file")
ed_add_node :: proc(ed: ^Gui_Editor, op: Script_Op, at: [2]f32) -> Node_Id {
  s := Script_Step {
    id     = ed_next_id(ed),
    op     = op,
    ui_pos = at,
  }
  if op == .Repeat {
    s.count = 3
  }
  s.src = step_label(s)
  append(&ed.doc.steps, s)
  ed_touch(ed)
  return s.id
}

// Removing a node also removes every edge INTO it. Leaving them would produce a document that
// script_resolve_ids refuses, i.e. a chart that cannot be saved or run because of a node that is
// already gone - the failure would be reported nowhere near the delete that caused it.
@(private = "file")
ed_delete_node :: proc(ed: ^Gui_Editor, id: Node_Id) {
  idx := ed_index(ed, id)
  if idx < 0 {
    return
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
  ed_touch(ed)
}

@(private = "file")
ed_wire :: proc(ed: ^Gui_Editor, from: Node_Id, port: int, to: Node_Id) {
  s := ed_step(ed, from)
  if s == nil {
    return
  }
  if port == 1 {
    s.else_id = to
  } else {
    s.goto_id = to
  }
  ed_relabel(s) // goto / branch print their edges by node id
  ed_touch(ed)
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
@(private = "file")
ed_out_ports :: proc(op: Script_Op) -> int {
  #partial switch op {
  case .Action, .Wait_For, .Goto:
    return 1
  case .Branch:
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
    if s.goto_id != 0 {
      out[n] = {s.goto_id, .Next, 0}
      n += 1
    } else if seq != 0 {
      out[n] = {seq, .Seq, 0}
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
  // an interrupt watcher: hoisted out of the instruction stream, so it has no flow edge at all
  case .Return:
  // ends an interrupt region; control resumes where the main program was suspended
  }
  return n
}

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
  case .Skip:
    return tint(COL_WARN, 0.7)
  case .Loop:
    return tint(COL_WARN, 0.9)
  }
  return COL_TEXT_DIM
}

// Colour carries the op, so a chart is readable at a zoom where the title text is not. The structured
// family deliberately shares one muted colour: they are the shape an Odin behaviour arrives in, not
// something you author here.
@(private = "file")
ed_op_color :: proc(op: Script_Op) -> imgui.Vec4 {
  switch op {
  case .Action:
    return COL_ACCENT
  case .Branch:
    return COL_WARN
  case .Wait_For:
    return imgui.Vec4{0.353, 0.780, 0.760, 1}
  case .On:
    return imgui.Vec4{0.941, 0.471, 0.118, 1}
  case .Goto:
    return imgui.Vec4{0.639, 0.522, 0.886, 1}
  case .Return:
    return COL_BAD
  case .If, .Else, .End, .Repeat, .While:
    return COL_TEXT_DIM
  }
  return COL_TEXT_DIM
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
ed_bezier :: proc(dl: ^imgui.DrawList, a, b: imgui.Vec2, col: imgui.Vec4, thick: f32) {
  dy := b.y - a.y
  d := clamp(abs(dy) * 0.5, thick * 10, thick * 60)
  if dy > thick * 8 {
    imgui.DrawList_AddBezierCubic(dl, a, {a.x, a.y + d}, {b.x, b.y - d}, b, u32_of(col), thick, 0)
    return
  }
  side := b.x < a.x ? f32(-1) : f32(1)
  off := max(abs(b.x - a.x) * 0.5, thick * 55)
  imgui.DrawList_AddBezierCubic(dl, a, {a.x + side * off, a.y + d}, {b.x + side * off, b.y - d}, b, u32_of(col), thick, 0)
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
    gui_ed_toolbar(ps, ed, f)
    footer := imgui.GetTextLineHeightWithSpacing() + px(6)
    if imgui.BeginChild("##canvas", {-px(ED_INSPECTOR_W) - px(8), -footer}, {.Borders}) {
      gui_ed_canvas(ps, ed, f)
    }
    imgui.EndChild()
    imgui.SameLine(0, px(8))
    if imgui.BeginChild("##inspector", {0, -footer}, {.Borders}) {
      gui_ed_inspector(ps, ed, f)
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

@(private = "file")
gui_ed_toolbar :: proc(ps: ^Panel_State, ed: ^Gui_Editor, f: ^Gui_Frame) {
  running := f.script_active && f.script_name == ed.doc.name

  imgui.SetNextItemWidth(px(190))
  imgui.InputTextWithHint("##edname", "chart name", cstring(raw_data(ed.name_buf[:])), len(ed.name_buf))
  name := strings.trim_space(panel_buf_str(ed.name_buf[:]))
  if imgui.IsItemHovered() {
    imgui.SetTooltip("The file this saves to. Typing a different name here is a SAVE AS - use the browser's Rename to rename.")
  }

  // Chart vs interrupt. One control, because they are the same document - an interrupt just carries a
  // condition and is armed instead of started.
  imgui.SameLine(0, px(8))
  imgui.SetNextItemWidth(px(110))
  if imgui.BeginCombo("##edkind", ed.doc.kind == .Interrupt ? "interrupt" : "chart") {
    if imgui.Selectable("chart", ed.doc.kind == .Chart) {
      ed.doc.kind = .Chart
      ed.dirty = true
    }
    if imgui.IsItemHovered() {
      imgui.SetTooltip("Something you run: 'script run <name>', or the play button.")
    }
    if imgui.Selectable("interrupt", ed.doc.kind == .Interrupt) {
      ed.doc.kind = .Interrupt
      // A trigger of None would save as a file that could never fire, so seed one that at least
      // means something. `always` is also the honest default: armed, and it fires immediately.
      if ed.doc.trigger.kind == .None {
        ed_set_event_kind(ed, nil, &ed.doc.trigger, .Always)
      }
      ed.dirty = true
    }
    if imgui.IsItemHovered() {
      imgui.SetTooltip("Something you ARM: it watches its trigger whatever else is running, and takes over when it fires.")
    }
    imgui.EndCombo()
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
  if gui_icon_button("edrun", ICON_PLAY, running, running ? "Restart it with what is saved  ('script run')" : "Save, then run this chart", COL_OK) {
    if ed_save(ps, ed) {
      if running {
        panel_enqueue(ps, "script stop")
      }
      panel_enqueue(ps, fmt.tprintf("script run %s", strings.trim_space(panel_buf_str(ed.name_buf[:]))))
    }
  }
  if running {
    imgui.SameLine(0, px(6))
    if gui_icon_button("edstop", ICON_STOP, false, "Stop the run  ('script stop')", COL_BAD) {
      panel_enqueue(ps, "script stop")
    }
  }

  imgui.SameLine(0, px(6))
  if gui_icon_button("edadd", ICON_ADD, false, "Add a node  (or right-click the canvas)") {
    ed.pal_at = ed.pan - [2]f32{ED_NODE_W * 0.5, ED_NODE_H * 0.5}
    ed.pal_wire = 0
    ed.pal_seed = true
    panel_buf_set(ed.pal_filter[:], "")
    imgui.OpenPopup("##edpalette")
  }

  // --- status: the save result, or the standing warnings that are true right now
  imgui.SameLine(0, px(12))
  imgui.BeginGroup()
  if ed.msg != "" && rl.GetTime() - ed.msg_at < 8 {
    imgui.PushStyleColorImVec4(.Text, ed.msg_bad ? COL_BAD : COL_OK)
    imgui.TextUnformatted(fmt.ctprintf("%s", ed.msg))
    imgui.PopStyleColor(1)
  } else if ed.shadowing {
    imgui.PushStyleColorImVec4(.Text, COL_WARN)
    imgui.TextUnformatted(fmt.ctprintf("built in Odin - saving writes a file that SHADOWS '%s'", ed.doc.name))
    imgui.PopStyleColor(1)
  } else if running && ed.dirty {
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextUnformatted("it is running the SAVED version - save and re-run to apply these edits")
    imgui.PopStyleColor(1)
  } else {
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextUnformatted(fmt.ctprintf("%d node%s", len(ed.doc.steps), len(ed.doc.steps) == 1 ? "" : "s"))
    imgui.PopStyleColor(1)
  }
  imgui.EndGroup()

  // The trigger gets its own row: it is the single most important thing about an interrupt (it is the
  // whole reason the file exists), and it does not belong squeezed between two combos.
  if ed.doc.kind == .Interrupt {
    if !ed.tbuf_ok {
      panel_buf_set(ed.tbuf[0][:], ed.doc.trigger.strs[0])
      panel_buf_set(ed.tbuf[1][:], ed.doc.trigger.strs[1])
      ed.tbuf_ok = true
    }
    // The arm control shares the LABEL's line, not the event editor's: the editor is a multi-line
    // group ending in a full-width combo, so anything SameLine'd after it lands off the window edge.
    imgui.PushStyleColorImVec4(.Text, COL_WARN)
    imgui.TextUnformatted("fires when")
    imgui.PopStyleColor(1)
    imgui.SameLine(0, px(14))
    on := irq_gui_enabled(f, ed.doc.name)
    if on {
      if imgui.Button("Disarm", {px(90), 0}) {
        panel_enqueue(ps, fmt.tprintf("interrupt off %s", ed.doc.name))
      }
      imgui.SameLine(0, px(8))
      imgui.PushStyleColorImVec4(.Text, COL_OK)
      imgui.TextUnformatted("ARMED - watching right now, whatever else is running")
      imgui.PopStyleColor(1)
    } else {
      // Arming reads the FILE, so an unsaved edit would arm something other than what is on screen.
      dis := ed.dirty || !bhv_exists(ed.doc.name)
      if dis {
        imgui.BeginDisabled()
      }
      if imgui.Button("Arm", {px(90), 0}) {
        panel_enqueue(ps, fmt.tprintf("interrupt on %s", ed.doc.name))
      }
      if dis {
        imgui.EndDisabled()
      }
      imgui.SameLine(0, px(8))
      imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
      imgui.TextUnformatted(dis ? "not armed - save it first, then Arm" : "not armed")
      imgui.PopStyleColor(1)
    }
    ed_event_editor(ed, nil, &ed.doc.trigger, f, "trig", ed.tbuf[0:2])
  }
  imgui.Separator()
}

// Is <name> one of the enabled global interrupts? Off the Gui_Frame snapshot - the draw phase may not
// read the session, and "which are armed" is session state that the watcher can change under us.
@(private = "file")
irq_gui_enabled :: proc(f: ^Gui_Frame, name: string) -> bool {
  for i in 0 ..< f.irq_n {
    if f.irq[i].name == name {
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
  // bhv_deserialize refuses this file, so writing it would produce something that cannot be read
  // back. Catch it at the point the user can still do something about it.
  if ed.doc.kind == .Interrupt && ed.doc.trigger.kind == .None {
    ed_msg(ed, "not saved: an interrupt needs a trigger - pick one in 'fires when'", true)
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
  // A blank REQUIRED argument saves and reloads fine, but the block it belongs to will do nothing
  // useful - `var` with no name sets nothing. Worth saying out loud at the moment you save, because
  // it is invisible on the canvas: the node looks finished.
  if blanks := ed_blank_required(ed); blanks > 0 {
    ed_msg(ed, fmt.tprintf("saved %s.bhv - but %d required argument(s) are still blank", name, blanks), true)
  } else {
    ed_msg(ed, fmt.tprintf("saved %s.bhv", name), false)
  }
  ps.browser_rescan = true
  return true
}

// How many required string arguments are still empty across the whole chart.
@(private = "file")
ed_blank_required :: proc(ed: ^Gui_Editor) -> int {
  n := 0
  count :: proc(spec: []Param_Spec, strs: [2]string) -> int {
    out := 0
    for p, i in spec {
      if p.optional {
        continue
      }
      if p.kind == .Str || p.kind == .Names {
        if strs[param_slot(spec, i)] == "" {
          out += 1
        }
      }
    }
    return out
  }
  for s in ed.doc.steps {
    if def := action_def(s.action.kind); def != nil {
      n += count(def.params, s.action.strs)
    }
    if def := event_def(s.cond.kind); def != nil {
      n += count(def.params, s.cond.strs)
    }
    if s.has_until {
      if def := event_def(s.until.kind); def != nil {
        n += count(def.params, s.until.strs)
      }
    }
  }
  return n
}

// --- canvas ------------------------------------------------------------------------------------------

@(private = "file")
gui_ed_canvas :: proc(ps: ^Panel_State, ed: ^Gui_Editor, f: ^Gui_Frame) {
  dl := imgui.GetWindowDrawList()
  v := Ed_View{}
  v.origin = imgui.GetCursorScreenPos()
  v.size = imgui.GetContentRegionAvail()
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

  // --- gestures
  if imgui.IsItemActivated() {
    ed.gesture = .Pan
    ed.drag_id = 0
    ed.link_from = 0
    switch {
    case imgui.IsMouseDown(.Middle):
    // middle always pans, whatever is under it
    case hit_port >= 0:
      ed.gesture = .Link
      ed.link_from = hit_node
      ed.link_port = hit_port
      ed.sel = hit_node
    case hit_node != 0:
      ed.gesture = .Drag
      ed.drag_id = hit_node
      ed.sel = hit_node
    case:
      ed.sel = 0
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
        s.ui_pos += [2]f32{d.x, d.y} / v.k
        ed.dirty = true
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
    ed.gesture = .None
    ed.link_from = 0
    ed.drag_id = 0
  }

  // --- keyboard: Delete removes the selection, but never while a text box has focus
  if hovered && ed.sel != 0 && !imgui.IsAnyItemActive() && imgui.IsKeyPressed(.Delete) {
    ed_delete_node(ed, ed.sel)
  }

  // --- right-click: a node menu, or the add palette on empty canvas
  if hovered && imgui.IsMouseClicked(.Right) {
    if hit_node != 0 {
      ed.sel = hit_node
      imgui.OpenPopup("##ednodectx")
    } else {
      ed.pal_at = ed_s2c(v, mp)
      ed.pal_wire = 0
      ed.pal_seed = true
      panel_buf_set(ed.pal_filter[:], "")
      imgui.OpenPopup("##edpalette")
    }
  }

  imgui.DrawList_PushClipRect(dl, v.origin, {v.origin.x + v.size.x, v.origin.y + v.size.y}, true)
  ed_draw_grid(dl, v)
  ed_draw_edges(ed, dl, v)
  ed_draw_nodes(ed, dl, v, f)
  if ed.gesture == .Link {
    if s := ed_step(ed, ed.link_from); s != nil {
      col := ed.link_port == 1 ? tint(COL_BAD, 0.9) : tint(COL_ACCENT, 0.9)
      ed_bezier(dl, ed_port_pos(v, s^, ed.link_port), mp, col, max(px(2) * ed.zoom, 1.5))
      imgui.DrawList_AddCircleFilled(dl, mp, ED_PORT_R * v.k, u32_of(col))
    }
  }
  imgui.DrawList_PopClipRect(dl)

  gui_ed_node_menu(ps, ed)
  gui_ed_palette(ed, f)
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

@(private = "file")
ed_draw_edges :: proc(ed: ^Gui_Editor, dl: ^imgui.DrawList, v: Ed_View) {
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
      from := e.port >= 0 ? ed_port_pos(v, s, e.port) : ed_port_pos(v, s, 0)
      to := ed_port_pos(v, t^, -1)
      col := ed_edge_color(e.kind)
      w := e.kind == .Seq ? thick * 0.7 : thick
      ed_bezier(dl, from, to, col, w)
      // An arrowhead at the destination: without it a back-edge (which is how a loop is drawn) reads
      // the same as a forward one and the direction of the program becomes a guess.
      h := max(px(5) * ed.zoom, 3)
      imgui.DrawList_AddTriangleFilled(dl, {to.x - h, to.y - h * 1.6}, {to.x + h, to.y - h * 1.6}, to, u32_of(col))
    }
  }
}

@(private = "file")
ed_draw_nodes :: proc(ed: ^Gui_Editor, dl: ^imgui.DrawList, v: Ed_View, f: ^Gui_Frame) {
  chart_running := f.script_active && f.script_name == ed.doc.name
  entry := ed.doc.entry
  if entry == 0 && len(ed.doc.steps) > 0 {
    entry = ed.doc.steps[0].id // 0 means "the first step", and the badge should say so
  }
  round := px(7) * ed.zoom
  title_fs := imgui.GetFontSize() * ed.zoom * 0.78
  body_fs := imgui.GetFontSize() * ed.zoom * 0.86
  pad := px(9) * ed.zoom

  for s in ed.doc.steps {
    a, b := ed_node_rect(v, s)
    if b.x < v.origin.x || a.x > v.origin.x + v.size.x || b.y < v.origin.y || a.y > v.origin.y + v.size.y {
      continue // off-screen; the cull matters once a chart is big enough to need panning
    }
    accent := ed_op_color(s.op)
    selected := s.id == ed.sel
    live := chart_running && f.script_node == s.id

    imgui.DrawList_AddRectFilled(dl, a, b, u32_of(imgui.Vec4{0.086, 0.110, 0.145, 0.97}), round)
    th := a.y + ED_TITLE_H * v.k
    imgui.DrawList_AddRectFilled(dl, a, {b.x, th}, u32_of(tint(accent, 0.26)), round, imgui.DrawFlags_RoundCornersTop)
    imgui.DrawList_AddLine(dl, {a.x, th}, {b.x, th}, u32_of(tint(accent, 0.45)), 1)

    border := COL_BORDER
    bw := f32(1)
    if live {
      border, bw = COL_OK, max(px(2.5) * ed.zoom, 2)
    } else if selected {
      border, bw = COL_ACCENT, max(px(2) * ed.zoom, 1.5)
    }
    imgui.DrawList_AddRect(dl, a, b, u32_of(border), round, {}, bw)

    // title: the OP, because the op is what decides the node's ports and how control leaves it
    ed_text(dl, {a.x + pad, a.y + (ED_TITLE_H * v.k - title_fs) * 0.5}, title_fs, tint(accent, 0.95), ed_fit(BHV_OP_NAMES[s.op], title_fs, (b.x - a.x) - pad * 2 - px(34) * ed.zoom))
    idl := fmt.ctprintf("#%d", u32(s.id))
    idw := imgui.CalcTextSize(idl).x * (title_fs / imgui.GetFontSize())
    ed_text(dl, {b.x - pad - idw, a.y + (ED_TITLE_H * v.k - title_fs) * 0.5}, title_fs, tint(COL_TEXT_DIM, 0.9), idl)

    // body: the one-line label, the same string `script step` and the transport strip print
    ed_text(dl, {a.x + pad, th + (b.y - th - body_fs) * 0.5}, body_fs, COL_TEXT, ed_fit(s.src, body_fs, (b.x - a.x) - pad * 2))

    // ports
    pr := ED_PORT_R * v.k
    if s.op != .On {
      ip := ed_port_pos(v, s, -1)
      imgui.DrawList_AddCircleFilled(dl, ip, pr * 0.8, u32_of(tint(COL_TEXT_DIM, 0.9)))
    }
    for p in 0 ..< ed_out_ports(s.op) {
      pp := ed_port_pos(v, s, p)
      pc := accent
      if s.op == .Branch {
        pc = p == 0 ? COL_OK : COL_BAD
      }
      imgui.DrawList_AddCircleFilled(dl, pp, pr, u32_of(pc))
      imgui.DrawList_AddCircleFilled(dl, pp, pr * 0.45, u32_of(imgui.Vec4{0.086, 0.110, 0.145, 1}))
    }

    if s.id == entry {
      ed_text(dl, {a.x + pad, a.y - title_fs - px(2) * ed.zoom}, title_fs, COL_OK, "START")
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
  imgui.TextUnformatted(fmt.ctprintf("#%d  %s", u32(s.id), s.src))
  imgui.PopStyleColor(1)
  imgui.Separator()
  if imgui.Selectable("Start here") {
    ed.doc.entry = s.id
    ed.dirty = true
  }
  if s.goto_id != 0 || s.else_id != 0 {
    if imgui.Selectable("Disconnect outputs") {
      s.goto_id = 0
      s.else_id = 0
      ed_relabel(s)
      ed_touch(ed)
    }
  }
  if imgui.Selectable("Unwire inputs") {
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
  if imgui.Selectable("Delete") {
    ed_delete_node(ed, ed.sel)
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
  imgui.SetNextItemWidth(px(300))
  imgui.InputTextWithHint("##palfilter", "search blocks", cstring(raw_data(ed.pal_filter[:])), len(ed.pal_filter))
  q := strings.to_lower(strings.trim_space(panel_buf_str(ed.pal_filter[:])), context.temp_allocator)

  // What was picked, applied AFTER the child ends: creating a node reallocs doc.steps, and doing that
  // in the middle of the list being iterated is the kind of thing that works until it doesn't.
  pick_op := Script_Op.Action
  pick_ak := Script_Action_Kind.None
  pick_ek := Script_Event_Kind.None
  picked := false
  shown := 0

  if imgui.BeginChild("##pallist", {px(430), px(330)}, {}) {
    imgui.SeparatorText("Flow")
    if ed_pal_row(q, "goto", "jump to another node - this is how a loop is drawn on a canvas", true, "", &shown) {
      pick_op, picked = .Goto, true
    }
    if ed_pal_row(q, "return", "end an interrupt region and resume the main program where it was suspended", true, "", &shown) {
      pick_op, picked = .Return, true
    }

    imgui.SeparatorText("Actions - what the chart DOES")
    for def in ACTIONS {
      if ed_pal_row(q, script_sig(def.name, def.params), def.blurb, f.act_ok[def.kind], f.act_why[def.kind], &shown) {
        pick_op, pick_ak, picked = .Action, def.kind, true
      }
    }

    imgui.SeparatorText("Events - what it NOTICES (added as a branch)")
    for def in EVENTS {
      if ed_pal_row(q, script_sig(def.name, def.params), def.blurb, f.ev_ok[def.kind], f.ev_why[def.kind], &shown) {
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
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted("An event lands as a branch; switch it to wait_for or on in the inspector.")
  imgui.PopStyleColor(1)

  if picked {
    ed_pal_create(ed, pick_op, pick_ak, pick_ek)
    imgui.CloseCurrentPopup()
  }
}

@(private = "file")
ed_pal_matches :: proc(q: string, name, blurb: string) -> bool {
  if q == "" {
    return true
  }
  return(
    strings.contains(strings.to_lower(name, context.temp_allocator), q) ||
    strings.contains(strings.to_lower(blurb, context.temp_allocator), q) \
  )
}

// One palette row. A gated block is drawn but NOT clickable, carrying the same reason `script blocks`
// prints - the catalog is the feature's roadmap as well as its dispatch, and hiding the unavailable
// half would make the palette disagree with the console about what exists.
@(private = "file")
ed_pal_row :: proc(q: string, sig: string, blurb: string, ok: bool, why: string, shown: ^int) -> bool {
  if !ed_pal_matches(q, sig, blurb) {
    return false
  }
  shown^ += 1
  clicked := false
  if ok {
    clicked = imgui.Selectable(fmt.ctprintf("%s##pal%s", sig, sig))
  } else {
    imgui.PushStyleColorImVec4(.Text, tint(COL_TEXT_DIM, 0.7))
    imgui.TextUnformatted(fmt.ctprintf("[--] %s", sig))
    imgui.PopStyleColor(1)
  }
  if imgui.IsItemHovered() {
    imgui.SetTooltip("%s", ok ? fmt.ctprintf("%s", blurb) : fmt.ctprintf("%s\n\nNot usable yet: %s", blurb, why))
  }
  return clicked
}

@(private = "file")
ed_pal_create :: proc(ed: ^Gui_Editor, op: Script_Op, ak: Script_Action_Kind, ek: Script_Event_Kind) {
  id := ed_add_node(ed, op, ed.pal_at)
  s := ed_step(ed, id)
  if s == nil {
    return
  }
  if ak != .None {
    ed_set_action_kind(ed, s, ak)
  }
  if ek != .None {
    ed_set_event_kind(ed, s, &s.cond, ek)
  }
  if ed.pal_wire != 0 {
    ed_wire(ed, ed.pal_wire, ed.pal_port, id)
    ed.pal_wire = 0
  }
  ed.sel = id
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
    imgui.TextUnformatted("Drag a node to move it.")
    imgui.TextUnformatted("Drag from a bottom dot to wire it.")
    imgui.TextUnformatted("Right-click empty canvas to add a node.")
    imgui.TextUnformatted("Wheel zooms, drag the background pans.")
    imgui.PopStyleColor(1)
    return
  }

  if ed.buf_for != s.id {
    ed_seed_buffers(ed, s)
  }

  imgui.PushStyleColorImVec4(.Text, ed_op_color(s.op))
  imgui.TextUnformatted(fmt.ctprintf("%s  #%d", BHV_OP_NAMES[s.op], u32(s.id)))
  imgui.PopStyleColor(1)
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
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
    ed_event_editor(ed, s, &s.cond, f, "cond", ed.sbuf[2:4])
  }

  // --- the action
  if s.op == .Action || s.op == .On {
    imgui.SeparatorText(s.op == .On ? "interrupt body" : "block")
    ed_action_editor(ed, s, f)
  }

  if s.op == .Repeat {
    imgui.SeparatorText("iterations")
    n := i32(s.count)
    imgui.SetNextItemWidth(-1)
    if imgui.DragInt("##edcount", &n, 1, 0, 9999) {
      s.count = int(max(0, n))
      ed_relabel(s)
      ed.dirty = true
    }
  }

  // --- until (a long-running action can end early)
  if s.op == .Action {
    imgui.SeparatorText("until (optional early-out)")
    has := s.has_until
    if imgui.Checkbox("end this block early when...##eduntil", &has) {
      s.has_until = has
      if has && s.until.kind == .None {
        ed_set_event_kind(ed, s, &s.until, .Always)
      }
      ed_relabel(s)
      ed.dirty = true
    }
    if s.has_until {
      ed_event_editor(ed, s, &s.until, f, "until", ed.sbuf[4:6])
    }
  }

  // --- edges
  imgui.SeparatorText("flow")
  ed_edge_rows(ed, s)

  imgui.Dummy({0, px(8)})
  entry_now := ed.doc.entry == s.id || (ed.doc.entry == 0 && len(ed.doc.steps) > 0 && ed.doc.steps[0].id == s.id)
  if entry_now {
    imgui.PushStyleColorImVec4(.Text, COL_OK)
    imgui.TextUnformatted(ed.doc.entry == 0 ? "starts here (first node in the file)" : "starts here")
    imgui.PopStyleColor(1)
  } else if imgui.Button("Start here", {px(120), 0}) {
    ed.doc.entry = s.id
    ed.dirty = true
  }
  imgui.SameLine(0, px(8))
  imgui.PushStyleColorImVec4(.Button, tint(COL_BAD, 0.25))
  if imgui.Button("Delete node", {px(130), 0}) {
    ed_delete_node(ed, ed.sel)
  }
  imgui.PopStyleColor(1)
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

@(private = "file")
ed_action_editor :: proc(ed: ^Gui_Editor, s: ^Script_Step, f: ^Gui_Frame) {
  cur := action_def(s.action.kind)
  imgui.SetNextItemWidth(-1)
  if imgui.BeginCombo("##edact", cur == nil ? "(pick a block)" : fmt.ctprintf("%s", cur.name)) {
    for def in ACTIONS {
      if !f.act_ok[def.kind] {
        imgui.PushStyleColorImVec4(.Text, tint(COL_TEXT_DIM, 0.7))
        imgui.TextUnformatted(fmt.ctprintf("[--] %s", def.name))
        imgui.PopStyleColor(1)
        if imgui.IsItemHovered() {
          imgui.SetTooltip("%s", fmt.ctprintf("%s\n\nNot usable yet: %s", def.blurb, f.act_why[def.kind]))
        }
        continue
      }
      if imgui.Selectable(fmt.ctprintf("%s", def.name), def.kind == s.action.kind) {
        ed_set_action_kind(ed, s, def.kind)
      }
      if imgui.IsItemHovered() {
        imgui.SetTooltip("%s", fmt.ctprintf("%s", def.blurb))
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
  ed_params(ed, s, "act", cur.params, &s.action.nums, &s.action.strs, ed.sbuf[0:2], f)
}

@(private = "file")
ed_event_editor :: proc(ed: ^Gui_Editor, s: ^Script_Step, ev: ^Script_Event, f: ^Gui_Frame, id: cstring, bufs: [][64]u8) {
  cur := event_def(ev.kind)
  neg := ev.negate
  if imgui.Checkbox(fmt.ctprintf("not##%s", id), &neg) {
    ev.negate = neg
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
  if imgui.BeginCombo(fmt.ctprintf("##ev%s", id), cur == nil ? "(pick an event)" : fmt.ctprintf("%s", cur.name)) {
    for def in EVENTS {
      if !f.ev_ok[def.kind] {
        imgui.PushStyleColorImVec4(.Text, tint(COL_TEXT_DIM, 0.7))
        imgui.TextUnformatted(fmt.ctprintf("[--] %s", def.name))
        imgui.PopStyleColor(1)
        if imgui.IsItemHovered() {
          imgui.SetTooltip("%s", fmt.ctprintf("%s\n\nNot usable yet: %s", def.blurb, f.ev_why[def.kind]))
        }
        continue
      }
      if imgui.Selectable(fmt.ctprintf("%s##%s", def.name, id), def.kind == ev.kind) {
        ed_set_event_kind(ed, s, ev, def.kind)
      }
      if imgui.IsItemHovered() {
        imgui.SetTooltip("%s", fmt.ctprintf("%s", def.blurb))
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
  ed_params(ed, s, id, cur.params, &ev.nums, &ev.strs, bufs, f)
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
  bufs: [][64]u8, // exactly the two text buffers this payload's string arguments edit through
  f: ^Gui_Frame,
) {
  for p, i in spec {
    slot := param_slot(spec, i)
    label := fmt.ctprintf("%s%s##%s%d", p.name, p.optional ? " (opt)" : "", id, i)
    changed := false
    switch p.kind {
    case .Num:
      val := f32(nums[slot])
      imgui.SetNextItemWidth(px(150))
      if imgui.DragFloat(label, &val, 0.25, 0, 0, "%.2f") {
        nums[slot] = f64(val)
        changed = true
      }
    case .Duration:
      // No unit in the format string: Duration is not always seconds (elapsed takes MINUTES), and the
      // parameter's own name is what says which. Stamping " s" on it would have been a confident lie.
      val := f32(nums[slot])
      imgui.SetNextItemWidth(px(150))
      if imgui.DragFloat(label, &val, 0.05, 0, 0, "%.3f") {
        nums[slot] = f64(max(0, val))
        changed = true
      }
    case .Percent:
      val := f32(nums[slot])
      imgui.SetNextItemWidth(px(150))
      if imgui.SliderFloat(label, &val, 0, 100, "%.0f%%") {
        nums[slot] = f64(val)
        changed = true
      }
    case .Coord:
      x := f32(nums[slot])
      z := f32(nums[slot + 1])
      imgui.SetNextItemWidth(px(90))
      if imgui.DragFloat(fmt.ctprintf("##%s%dx", id, i), &x, 0.5, 0, 0, "x %.1f") {
        nums[slot] = f64(x)
        changed = true
      }
      imgui.SameLine(0, px(6))
      imgui.SetNextItemWidth(px(90))
      if imgui.DragFloat(fmt.ctprintf("##%s%dz", id, i), &z, 0.5, 0, 0, "z %.1f") {
        nums[slot + 1] = f64(z)
        changed = true
      }
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
      imgui.SameLine(0, px(8))
      imgui.TextUnformatted(fmt.ctprintf("%s", p.name))
    case .Str, .Names:
      if slot >= 0 && slot < len(bufs) {
        imgui.SetNextItemWidth(px(200))
        if imgui.InputTextWithHint(label, p.kind == .Names ? "blank = any monster" : "", cstring(raw_data(bufs[slot][:])), len(bufs[slot])) {
          delete(strs[slot])
          strs[slot] = strings.clone(panel_buf_str(bufs[slot][:]))
          changed = true
        }
      }
    }
    if changed {
      if s != nil {
        ed_relabel(s)
      }
      ed.dirty = true
    }
  }
}

// Copy the selected step's owned strings into the widget buffers. Editing writes straight back into
// the step, so this only has to run when the step - or the block occupying it - changes underneath.
@(private = "file")
ed_seed_buffers :: proc(ed: ^Gui_Editor, s: ^Script_Step) {
  panel_buf_set(ed.sbuf[0][:], s.action.strs[0])
  panel_buf_set(ed.sbuf[1][:], s.action.strs[1])
  panel_buf_set(ed.sbuf[2][:], s.cond.strs[0])
  panel_buf_set(ed.sbuf[3][:], s.cond.strs[1])
  panel_buf_set(ed.sbuf[4][:], s.until.strs[0])
  panel_buf_set(ed.sbuf[5][:], s.until.strs[1])
  ed.buf_for = s.id
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
    imgui.PushStyleColorImVec4(.Text, ed_edge_color(e.kind))
    imgui.TextUnformatted(fmt.ctprintf("%-6s -> #%d", ed_edge_word(e.kind), u32(e.to)))
    imgui.PopStyleColor(1)
    if imgui.IsItemHovered() && t != nil {
      imgui.SetTooltip("%s", fmt.ctprintf("%s", t.src))
    }
    if e.kind == .Seq {
      imgui.SameLine(0, px(8))
      imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
      imgui.TextUnformatted("(the next node in the file - drag a wire to name one)")
      imgui.PopStyleColor(1)
    }
    if e.port >= 0 {
      imgui.SameLine(0, px(8))
      if imgui.Button(fmt.ctprintf("clear##e%d", e.port), {px(58), 0}) {
        ed_wire(ed, s.id, e.port, 0)
      }
    }
  }
}

@(private = "file")
ed_edge_word :: proc(kind: Ed_Edge_Kind) -> string {
  switch kind {
  case .Seq:
    return "next"
  case .Next:
    return "next"
  case .True:
    return "true"
  case .False:
    return "false"
  case .Skip:
    return "skip"
  case .Loop:
    return "loop"
  }
  return "?"
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
  ed_legend_chip(.Skip, "block exit")
  ed_legend_chip(.Loop, "loop back")
  imgui.SameLine(0, px(16))
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted(fmt.ctprintf("zoom %.0f%%   -   Del removes the selected node", ed.zoom * 100))
  imgui.PopStyleColor(1)
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
