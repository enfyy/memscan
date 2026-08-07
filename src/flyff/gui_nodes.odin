package flyff

import "core:fmt"
import "core:math"
import "core:slice"
import "core:strings"
import rl "vendor:raylib"

import imgui "../../lib/odin-imgui"

// ===========================================================================
// The behaviour editor - the authoring surface for a rule list.
//
// THERE WAS A CANVAS HERE. ~1,900 lines of it: a hand-rolled node graph on ImGui draw lists, with
// Sugiyama auto-layout, bezier wires, wire hit-testing, box-select, pan and zoom. It went with the
// graph itself - see script_rules.odin for the argument, and BACKLOG.md for the corpus measurement
// that settled it. What is left is the half that was never about drawing: the typed argument fields,
// the condition rows, the Problems tab, the run log. Those all edit a Script_Step and a
// Script_Condition, which is what a rule is made of, so they carried over untouched.
//
// WHAT IT EDITS. A Behaviour_Doc owned by Panel_State - never session.script. The running behaviour
// and the thing you are editing are separate on purpose: you can edit one while it runs, and
// re-running is what picks the edit up. There is no compile step at all now; a rule's steps are a
// numbered list, so an insert moves nothing that anything else points at.
//
// THE ONE THING THAT LOOKS LIKE A RULE BREAK. gui.odin's contract is that the draw phase never
// touches `session` and issues every action as a CLI command. Saving here calls bhv_save directly.
// That is the same call `script export` makes and it touches no session state - the behaviours
// DIRECTORY is not session state, which is exactly why P3 already reads it from this phase (see the
// note atop gui_behaviour.odin). Anything that does reach the session - running the behaviour,
// stopping it - still goes through panel_enqueue. The rule is about the lock, and a file write is not
// under it.
// ===========================================================================

ED_INSPECTOR_W :: f32(330)

Gui_Editor :: struct {
  open:       bool,
  doc:        Behaviour_Doc, // OWNED while open
  dirty:      bool,
  msg:        string, // owned - the last save / validation result
  msg_bad:    bool,
  msg_at:     f64, // rl.GetTime() when it was set, so it can fade
  name_buf:   [64]u8, // the SAVE TARGET; typing a new one here is a save-as, not a rename

  // `sel` is the PRIMARY selection - what the inspector edits - and `selset` is everything selected
  // including it. Either may name a RULE or a STEP; they share the Node_Id space, and the inspector
  // asks which it is (see gui_ed_inspector).
  sel:        Node_Id,
  selset:     [dynamic]Node_Id,

  // Undo. A ring of whole-document snapshots rather than a log of reversible edits: the document is
  // tens of rows, a deep copy is trivially cheap at this size, and "clone it before you touch it"
  // cannot get an inverse operation subtly wrong the way a per-edit undo log can.
  undo:       [dynamic]Behaviour_Doc,
  redo:       [dynamic]Behaviour_Doc,

  // Inspector text buffers. A condition is up to SCRIPT_MAX_CONDITION_ROWS ROWS and each row has two string
  // arguments, so the layout is: [0,1] the action, then [2 ..] the cond's rows, then the until's -
  // see ED_TEXT_CONDITION / ED_TEXT_UNTIL. Re-seeded whenever the selection or a block kind changes, or a
  // row is added or removed; text_buffers_for_node is what detects the first two and options_revision the third.
  text_buffers_for_node:    Node_Id,
  text_buffers:       [ED_TEXT_BUFFERS_PER_STEP][ED_TEXT_BUFFER_SIZE]u8,
  // The RULE's own label, and the behaviour's description - the two bits of chart-level prose. Seeded
  // when the selection or the document changes (rule_label_for / desc_buffer_for), the same trigger
  // text_buffers uses.
  rule_label_buffer:    [96]u8,
  rule_label_for:       Node_Id,
  desc_buffer:          [128]u8,
  desc_buffer_for:      string, // temp-allocated; compared by value, never freed

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
  // The inspector gets away with one window of text buffers because it edits ONE row. The rule list
  // draws every row at once, so every string argument ON SCREEN needs a buffer of its own - hence a
  // grown array of ED_TEXT_BUFFERS_PER_STEP-sized windows, one per rule's WHEN and one per step.
  //
  // It is re-seeded from the document only when something OUTSIDE the list rewrote a row's strings
  // (undo, a block-kind swap, a row added or deleted), tracked by options_revision. Re-seeding every
  // frame would be simpler and wrong: overwriting the buffer under a live ImGui text field moves the
  // caret to the end on every keystroke. Editing here writes straight back into the step, so between
  // those events the two are always in sync and there is nothing to re-seed.
  tab_options:       bool, // the Options tab is selected (what the behaviour IS, not what it does)
  options_text_buffers:          [dynamic][ED_TEXT_BUFFER_SIZE]u8,
  options_revision:           int,
  options_seeded_revision:        int, // the options_revision the buffers hold; starts equal, so 0 means "seed me"
  options_seeded_step_count:        int, // window count they were seeded from

  // ed_params: spell the description out under each field (the rule list), or leave it in the tooltip
  // (the inspector, which sits beside the list you are trying to read).
  param_help_inline: bool,

  // Problems tab (gui_ed_problems) and the trace strip (gui_ed_trace).
  //
  // The problem LIST is deliberately not cached here. gui_node_editor lints once per frame into temp and
  // passes the slice down to the things that read it - the toolbar badge and the tab. A cached list
  // would need invalidating on every edit path, and one missed path is a panel confidently reporting
  // problems the behaviour no longer has, which is worse than having no panel.
  tab_problems: bool, // one-shot "select the Problems tab", set by the badge
  show_notes:   bool, // notes are legitimate and numerous - hidden until asked for
  trace_open:   bool,
  trace_follow: bool, // stick to the newest row

  // The row a click in the trace strip or the Problems tab asked to be shown. Consumed by gui_ed_rules
  // on the next frame - a request rather than a scroll position, because the list is rebuilt each frame.
  scroll_to: Node_Id,
}

// ===========================================================================
// Lifetime
// ===========================================================================

gui_editor_free :: proc(ed: ^Gui_Editor) {
  if ed.doc.name != "" || ed.doc.rules != nil {
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

// The document was swapped wholesale, so anything that POINTS INTO it has to be re-derived: the
// inspector's text buffers, and any selection naming a row this version does not have.
@(private = "file")
ed_after_history :: proc(ed: ^Gui_Editor) {
  ed.dirty = true
  ed.text_buffers_for_node = 0
  ed.options_revision += 1
  alive :: proc(ed: ^Gui_Editor, id: Node_Id) -> bool {
    return ed_step(ed, id) != nil || ed_rule(ed, id) != nil
  }
  if !alive(ed, ed.sel) {
    ed.sel = 0
  }
  for i := len(ed.selset) - 1; i >= 0; i -= 1 {
    if !alive(ed, ed.selset[i]) {
      ordered_remove(&ed.selset, i)
    }
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
  ed_begin(ed, name)
  ed.tab_options = options
}

// A blank behaviour. It exists only in memory until Save - there is no empty file to clean up if the
// user changes their mind, and an empty behaviour could not be run anyway.
//
// It starts with ONE RULE rather than nothing. An empty list has no affordance on it that says what a
// behaviour is made of, and the first row - `WHEN always DO (nothing yet)` - is the shape of the whole
// language, so the editor opens on an example of itself.
gui_editor_new :: proc(ps: ^Panel_State) {
  ed := &ps.ed
  gui_editor_free(ed)
  name := ed_free_name()
  ed.doc = Behaviour_Doc {
    name  = strings.clone(name),
    rules = make([dynamic]Rule),
  }
  ed_begin(ed, name)
  ed.sel = ed_add_rule(ed, snapshot = false)
  ed.dirty = false // the seeded rule is the empty state, not an edit to be warned about on close
  ed_msg(ed, "new behaviour - set the rule's WHEN, then add what it should DO", false)
}

@(private = "file")
ed_begin :: proc(ed: ^Gui_Editor, name: string) {
  ed.open = true
  panel_buf_set(ed.name_buf[:], name)
  ed_history_clear(ed) // a different behaviour: undoing into the previous one would be nonsense
  clear(&ed.selset)
  ed.sel = 0
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

// ===========================================================================
// Model edits
//
// Every edit is "snapshot, then mutate" - ed_snapshot clones the whole document into the undo ring
// before anything moves. That is the rule rather than an inverse-operation per edit, because a
// document is tens of rows and a deep copy at this size costs nothing next to getting an inverse
// subtly wrong.
//
// THERE IS NOTHING TO RE-RESOLVE ANY MORE. Every edit used to end in ed_touch, which re-derived the
// jump indices from the node identities - the editor's entire compile step, and one that could not be
// skipped without producing a program that jumped to where a node used to be. A rule's steps are a
// numbered list, so an insert or a delete moves nothing that anything else points at.
// ===========================================================================

@(private = "file")
ed_touch :: proc(ed: ^Gui_Editor) {
  ed.dirty = true
  ed.options_revision += 1
}

// The rule <id> names, or nil. A rule and a step share the Node_Id space, so the two finders are
// separate lookups over the same numbers rather than one that returns a union.
@(private = "file")
ed_rule :: proc(ed: ^Gui_Editor, id: Node_Id) -> ^Rule {
  if id == 0 {
    return nil
  }
  for &r in ed.doc.rules {
    if r.id == id {
      return &r
    }
  }
  return nil
}

@(private = "file")
ed_rule_index :: proc(ed: ^Gui_Editor, id: Node_Id) -> int {
  for r, i in ed.doc.rules {
    if r.id == id {
      return i
    }
  }
  return -1
}

@(private = "file")
ed_step :: proc(ed: ^Gui_Editor, id: Node_Id) -> ^Script_Step {
  if id == 0 {
    return nil
  }
  for &r in ed.doc.rules {
    for &s in r.steps {
      if s.id == id {
        return &s
      }
    }
  }
  return nil
}

// Which rule owns step <id>, and where in its list it sits. Both, because every edit that acts on a
// step needs the owner too - deleting one, moving one, or inserting next to one.
@(private = "file")
ed_step_home :: proc(ed: ^Gui_Editor, id: Node_Id) -> (rule: int, index: int) {
  for r, ri in ed.doc.rules {
    for s, si in r.steps {
      if s.id == id {
        return ri, si
      }
    }
  }
  return -1, -1
}

// Next free id across BOTH namespaces. Rules and steps share it because everything downstream - the
// trace ring, the Problems tab, the editor's own selection - addresses rows by a single Node_Id and
// would otherwise have to carry which kind of thing each one was.
@(private = "file")
ed_next_id :: proc(ed: ^Gui_Editor) -> Node_Id {
  hi := Node_Id(0)
  for r in ed.doc.rules {
    hi = max(hi, r.id)
    for s in r.steps {
      hi = max(hi, s.id)
    }
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
    case .Str, .Names, .Mob, .Key, .Var_Name, .Choice, .Chart_Name:
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
  ed_touch(ed)
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
  // s is nil for a RULE's condition, which labels no step - see the same nilable parameter on
  // ed_params. Only a step has a caption to rebuild.
  if s != nil {
    ed_relabel(s)
    ed.text_buffers_for_node = 0
  }
  ed_touch(ed)
}

// --- rules ------------------------------------------------------------------------------------------

// Add a rule, at the BOTTOM. Position is urgency in this model, so a new rule arriving at the top
// would silently outrank everything already there; the bottom is the one end where arriving changes
// nothing about what the existing rules do.
@(private = "file")
ed_add_rule :: proc(ed: ^Gui_Editor, snapshot := true) -> Node_Id {
  if snapshot {
    ed_snapshot(ed)
  }
  rule := Rule {
    id      = ed_next_id(ed),
    label   = strings.clone("New rule"),
    steps   = make([dynamic]Script_Step),
    enabled = true,
  }
  // Seeded with `always` rather than left blank. A rule with no condition is an ERROR the linter
  // reports immediately, and greeting a new row with a red badge is a worse introduction than a row
  // that works and needs narrowing.
  condition_row_ptr(&rule.condition, 0)^ = Script_Event{kind = .Always}
  rule.condition.row_count = 1
  append(&ed.doc.rules, rule)
  ed_touch(ed)
  return rule.id
}

@(private = "file")
ed_delete_rule :: proc(ed: ^Gui_Editor, id: Node_Id, snapshot := true) {
  index := ed_rule_index(ed, id)
  if index < 0 {
    return
  }
  if snapshot {
    ed_snapshot(ed)
  }
  rule_free(&ed.doc.rules[index])
  ordered_remove(&ed.doc.rules, index)
  if ed.sel == id {
    ed.sel = 0
  }
  ed_touch(ed)
}

// Move a rule up or down the list. This is the one edit that CHANGES BEHAVIOUR without touching a
// single value - position is urgency, so a rule moved above another now interrupts it.
@(private = "file")
ed_move_rule :: proc(ed: ^Gui_Editor, id: Node_Id, delta: int) {
  from := ed_rule_index(ed, id)
  if from < 0 {
    return
  }
  to := clamp(from + delta, 0, len(ed.doc.rules) - 1)
  if to == from {
    return
  }
  ed_snapshot(ed)
  moved := ed.doc.rules[from]
  ordered_remove(&ed.doc.rules, from)
  inject_at(&ed.doc.rules, to, moved)
  ed_touch(ed)
}

// --- steps ------------------------------------------------------------------------------------------

// Add a step to <rule_id>, after <after> when it names one of that rule's steps and at the end
// otherwise. Returns 0 when the rule is gone, which is what the palette checks before selecting the
// new row.
@(private = "file")
ed_add_step :: proc(ed: ^Gui_Editor, rule_id: Node_Id, op: Script_Op, snapshot := true, after: Node_Id = 0) -> Node_Id {
  index := ed_rule_index(ed, rule_id)
  if index < 0 {
    return 0
  }
  if snapshot {
    ed_snapshot(ed)
  }
  s := Script_Step {
    id = ed_next_id(ed),
    op = op,
  }
  s.src = step_label(s)
  rule := &ed.doc.rules[index]
  at := len(rule.steps)
  if after != 0 {
    for existing, i in rule.steps {
      if existing.id == after {
        at = i + 1
        break
      }
    }
  }
  inject_at(&rule.steps, at, s)
  ed_touch(ed)
  return s.id
}

@(private = "file")
ed_delete_step :: proc(ed: ^Gui_Editor, id: Node_Id, snapshot := true) {
  rule, index := ed_step_home(ed, id)
  if rule < 0 {
    return
  }
  if snapshot {
    ed_snapshot(ed)
  }
  script_step_free(&ed.doc.rules[rule].steps[index])
  ordered_remove(&ed.doc.rules[rule].steps, index)
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

// Move a step within its own rule. It cannot move BETWEEN rules: a step belongs to the condition that
// selects it, and a drag that quietly re-homed one would be the easiest way in this editor to change
// what a behaviour does without noticing.
@(private = "file")
ed_move_step :: proc(ed: ^Gui_Editor, id: Node_Id, delta: int) {
  rule, from := ed_step_home(ed, id)
  if rule < 0 {
    return
  }
  steps := &ed.doc.rules[rule].steps
  to := clamp(from + delta, 0, len(steps) - 1)
  if to == from {
    return
  }
  ed_snapshot(ed)
  moved := steps[from]
  ordered_remove(steps, from)
  inject_at(steps, to, moved)
  ed_touch(ed)
}

// Everything selected, in one undoable step - deleting three rows should cost one Ctrl+Z, not three.
@(private = "file")
ed_delete_selection :: proc(ed: ^Gui_Editor) {
  if len(ed.selset) == 0 {
    return
  }
  ed_snapshot(ed)
  ids := make([]Node_Id, len(ed.selset), context.temp_allocator)
  copy(ids, ed.selset[:])
  for id in ids {
    // A step and a rule share the id space, so which one this is decides which delete runs. Steps
    // first: deleting a rule takes its steps with it, and a selection can hold both.
    if _, index := ed_step_home(ed, id); index >= 0 {
      ed_delete_step(ed, id, snapshot = false)
    } else {
      ed_delete_rule(ed, id, snapshot = false)
    }
  }
  ed_sel_only(ed, 0)
}

// Drop a saved waypoint set into the OPEN behaviour: it becomes the ROUTE, plus a rule that patrols it
// if nothing already does.
//
// It used to paste one walk_to step per waypoint, wired in a chain. That is exactly the shape the
// redesign was aimed at - 123 of the old corpus's 322 nodes were a route wearing graph clothes - and a
// route has a better editor than any list could be, because you draw it on the map.
@(private = "file")
ed_import_waypoint_set :: proc(ed: ^Gui_Editor, set: Waypoint_Set) -> int {
  if len(set.waypoints) == 0 || set.name == "" {
    return 0
  }
  ed_snapshot(ed)
  delete(ed.doc.route)
  ed.doc.route = strings.clone(set.name)
  patrols := false
  for r in ed.doc.rules {
    for s in r.steps {
      if s.op == .Action && s.action.kind == .Patrol {
        patrols = true
      }
    }
  }
  if !patrols {
    id := ed_add_rule(ed, snapshot = false)
    if rule := ed_rule(ed, id); rule != nil {
      delete(rule.label)
      rule.label = strings.clone("Walk the route")
    }
    if step_id := ed_add_step(ed, id, .Action, snapshot = false); step_id != 0 {
      if step := ed_step(ed, step_id); step != nil {
        ed_set_action_kind(ed, step, .Patrol, snapshot = false)
      }
    }
  }
  ed_touch(ed)
  return len(set.waypoints)
}
// --- category colours and icons ------------------------------------------------------------------
//
// These outlived the canvas: a rule row is tinted by its block's category exactly as a node was.
// Colour was never a canvas idea - it says what a step is ABOUT, and a list needs that as much as a
// graph did.

// accent and the chart was a wall of identical blue boxes. The op is the poorer of the two signals
// here - it is already legible from the node's ports and its title - so colour now carries the block's
// CATEGORY, and the shape of control flow moved to the icon. Both survive a zoom-out that eats the text.
//
// Package-visible, not file-private: the browser tints a block's tile with .Sub too, and a second copy
// of that colour is how the tile and the node it becomes would drift apart.
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
  case .Sub:
    return imgui.Vec4{0.925, 0.435, 0.729, 1} // magenta - the one hue no catalog category uses, so a
    // block you made yourself never reads as one that shipped with the tool
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
  case .Sub:
    return ICON_CAT_SUB
  }
  return ICON_CAT_FLOW
}

@(private = "file")
ed_node_color :: proc(s: Script_Step) -> imgui.Vec4 {
  return ed_cat_color(block_cat(s))
}

@(private = "file")
ed_node_icon :: proc(s: Script_Step) -> rune {
  if s.op == .Wait_For {
    return ICON_CAT_TIMING
  }
  return ed_cat_icon(block_cat(s))
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
    // Sized from the font rather than a constant so it still clears the text at any ui_scale. The trace
    // strip, when open, takes a third of the height off the LIST rather than off the window - the
    // inspector beside it keeps its full run.
    footer := 2 * imgui.GetTextLineHeightWithSpacing() + px(6)
    list_w := -px(ED_INSPECTOR_W) - px(8)
    list_h := -footer
    if ed.trace_open {
      // A NEGATIVE child height means "the space available minus this", so the fraction here is the
      // share the LOG gets, not the list. Getting that backwards gave the empty log strip more room
      // than the behaviour it is explaining.
      list_h = -(imgui.GetContentRegionAvail().y - footer) * 0.36
    }
    // The list and the strip under it are ONE group, so the inspector SameLine's against the pair
    // rather than landing beneath the strip.
    imgui.BeginGroup()
    if imgui.BeginChild("##rules", {list_w, list_h}, {.Borders}) {
      gui_ed_rules(ps, ed, f)
    }
    imgui.EndChild()
    if ed.trace_open {
      if imgui.BeginChild("##trace", {list_w, -footer}, {.Borders}) {
        gui_ed_trace(ps, ed, f)
      }
      imgui.EndChild()
    }
    imgui.EndGroup()
    imgui.SameLine(0, px(8))
    if imgui.BeginChild("##inspector", {0, -footer}, {.Borders}) {
      // Two tabs over one pane. "Node" is the list's companion - whatever row you clicked, rule or
      // step. "Options" is what the behaviour IS: its description, its route, and whether it trusts
      // the collision gate.
      if imgui.BeginTabBar("##edtabs") {
        options_tab_flags: imgui.TabItemFlags
        if ed.tab_options {
          options_tab_flags += {.SetSelected} // a one-shot request from the browser's Configure... entry
          ed.tab_options = false
        }
        // Each tab's body gets its OWN scrolling child, sized to fill what is left. Without that the
        // outer child scrolls instead and takes the tab bar off the top of the screen with it - you
        // scroll down to read a setting and lose the way back to the other tab.
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
  }
  imgui.End()
  if !open {
    gui_editor_close(ps)
    return
  }
}

// --- toolbar ---------------------------------------------------------------------------------------

// How many DISTINCT blocks in the open behaviour cannot run right now, and the first reason.
// Deliberately NOT part of script_lint: the linter answers questions about the DOCUMENT, and "the game
// is not attached" is a fact about this minute that would make every behaviour light up with warnings
// the moment you closed the client. This is a toolbar readout instead, computed from the same
// Gui_Frame runnability snapshot the palette greys with.
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
  note_condition :: proc(c: Script_Condition, f: ^Gui_Frame, seen: ^bit_set[Script_Event_Kind], count: ^int, first_why: ^string) {
    for i in 0 ..< condition_row_count(c) {
      note_event(condition_row(c, i), f, seen, count, first_why)
    }
  }
  for rule in ed.doc.rules {
    note_condition(rule.condition, f, &seen_events, &count, &first_why)
    for s in rule.steps {
      if s.action.kind != .None && s.action.kind not_in seen_actions {
        seen_actions += {s.action.kind}
        if !f.action_usable[s.action.kind] {
          count += 1
          if first_why == "" {
            first_why = f.action_why_not[s.action.kind]
          }
        }
      }
      note_condition(s.condition, f, &seen_events, &count, &first_why)
      if s.has_until {
        note_condition(s.until, f, &seen_events, &count, &first_why)
      }
    }
  }
  return
}

@(private = "file")
gui_ed_toolbar :: proc(ps: ^Panel_State, ed: ^Gui_Editor, f: ^Gui_Frame, problems: []Chart_Problem) {
  running := f.script_active && f.script_name == ed.doc.name

  imgui.SetNextItemWidth(px(190))
  imgui.InputTextWithHint("##edname", "behaviour name", cstring(raw_data(ed.name_buf[:])), len(ed.name_buf))
  name := strings.trim_space(panel_buf_str(ed.name_buf[:]))
  if imgui.IsItemHovered() {
    imgui.SetTooltip("The file this saves to. Typing a different name here is a SAVE AS - use the browser's Rename to rename.")
  }

  // THE MODE COMBO IS GONE, and so is the "watchers only" badge beside it. A rule list always loops -
  // "read the list every tick" has no end condition - and every list is armable, so neither question
  // has two answers to pick between any more.

  imgui.SameLine(0, px(12))
  can_save := bhv_name_ok(name) && len(ed.doc.rules) > 0
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
  // TRANSPORT, on the editor's own toolbar rather than only on the dock behind it. Watching a run is
  // something you do WHILE looking at the list - the log strip under it says which rule took over and
  // why - so having to close the editor to reach the dock's buttons made the one view that could
  // explain a run the one view that could not drive it.
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
  // THE STEP BUTTON IS GONE. Single-stepping froze the pc walker and advanced it one instruction at a
  // time, which is a coherent thing to do to a program parked at a node and an incoherent one to do to
  // a list that re-arbitrates every tick: freezing the walk would leave arbitration running and hand
  // control to a different rule between your steps. The run log is what replaced it - it says which
  // rule took over and why, which is the question stepping was being used to answer.
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
  // The rule count stays on the controls row: it is two words, it is always true, and it is about the
  // buttons next to it. Anything longer goes in the banner below - see ed_status_banner.
  imgui.SameLine(0, px(12))
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted(fmt.ctprintf("%d rule%s", len(ed.doc.rules), len(ed.doc.rules) == 1 ? "" : "s"))
  imgui.PopStyleColor(1)

  // The BADGE. A count you have to open a tab to find is a count nobody finds, and "it's hard to tell
  // what's wrong with a chart" was the complaint - so the answer has to be visible from the list.
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

  // The ARM row. Shown for EVERY behaviour now: arming one puts its rules above whatever is running,
  // and there is no separate kind of document that is allowed to be armed. It used to be gated on the
  // document containing a watcher node, which was the shape a "watcher-only" file had.
  if len(ed.doc.rules) > 0 {
    on := armed_watcher_enabled_in_frame(f, ed.doc.name)
    if on {
      if imgui.Button("Stop watching", {px(130), 0}) {
        panel_enqueue(ps, fmt.tprintf("interrupt off %s", ed.doc.name))
      }
      imgui.SameLine(0, px(8))
      imgui.PushStyleColorImVec4(.Text, COL_OK)
      imgui.TextUnformatted("ALWAYS WATCHING - these rules are read above whatever else is running")
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
      imgui.TextUnformatted(dis ? "runs only when you start it - save it first to arm it" : "runs only when you start it")
      imgui.PopStyleColor(1)
    }
  }
  imgui.Separator()
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
  if len(ed.doc.rules) == 0 {
    ed_msg(ed, "nothing to save - add a rule first", true)
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

ED_TEXT_BUFFER_SIZE :: 128
ED_TEXT_CONDITION :: 2
ED_TEXT_UNTIL :: ED_TEXT_CONDITION + SCRIPT_MAX_CONDITION_ROWS * 2
ED_TEXT_BUFFERS_PER_STEP :: ED_TEXT_UNTIL + SCRIPT_MAX_CONDITION_ROWS * 2

// --- inspector ---------------------------------------------------------------------------------------
//
// Edits whatever is selected, and the selection can be a RULE or a STEP - they share the Node_Id
// space, so the panel asks which it is and draws the matching form. A rule's form is its label, its
// WHEN and how it fires; a step's is its block and that block's arguments.

@(private = "file")
gui_ed_inspector :: proc(ps: ^Panel_State, ed: ^Gui_Editor, f: ^Gui_Frame) {
  if rule := ed_rule(ed, ed.sel); rule != nil {
    gui_ed_rule_inspector(ed, rule, f)
    return
  }
  s := ed_step(ed, ed.sel)
  if s == nil {
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextUnformatted("Nothing selected.")
    imgui.Dummy({0, px(6)})
    imgui.TextWrapped("A behaviour is an ordered list of rules. Every tick the list is read from the top and the FIRST rule whose WHEN holds runs its steps.")
    imgui.Dummy({0, px(6)})
    imgui.TextWrapped("A rule higher in the list interrupts one lower down, and the lower one resumes where it was - so the order is what decides urgency.")
    imgui.Dummy({0, px(8)})
    imgui.TextUnformatted("Click a rule or a step to edit it.")
    imgui.Dummy({0, px(6)})
    imgui.TextUnformatted("Ctrl+Z / Ctrl+Y   undo / redo")
    imgui.TextUnformatted("Del               delete what is selected")
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

  // The two shapes a step can be. Interchangeable in one click rather than delete-and-recreate,
  // because they hold the same kind of payload and differ only in what is done with it.
  imgui.TextUnformatted("kind")
  imgui.SetNextItemWidth(-1)
  if imgui.BeginCombo("##edop", fmt.ctprintf("%s", BHV_OP_NAMES[s.op])) {
    ed_op_choice(ed, s, .Action, "action - do something")
    ed_op_choice(ed, s, .Wait_For, "wait_for - stay on this step until the condition holds")
    imgui.EndCombo()
  }
  imgui.Dummy({0, px(4)})

  switch s.op {
  case .Wait_For:
    imgui.SeparatorText("condition")
    ed_condition_editor(ed, s, &s.condition, f, "cond", ed.text_buffers[ED_TEXT_CONDITION:ED_TEXT_UNTIL])
  case .Action:
    imgui.SeparatorText("block")
    ed_action_editor(ed, s, f, ed.text_buffers[0:2])
    // A long-running action can end early. Only an action: a wait_for IS its condition.
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

  imgui.Dummy({0, px(8)})
  // Where it sits in ITS OWN rule. A step cannot move to a different rule - it belongs to the
  // condition that selects it - so there is no target to offer, only up and down.
  if _, index := ed_step_home(ed, s.id); index >= 0 {
    imgui.SeparatorText("order")
    if imgui.Button("Move up", {-1, 0}) {
      ed_move_step(ed, s.id, -1)
    }
    imgui.Dummy({0, px(4)})
    if imgui.Button("Move down", {-1, 0}) {
      ed_move_step(ed, s.id, 1)
    }
    if imgui.IsItemHovered() {
      imgui.SetTooltip("Steps run in order, and one that fails stops the rest of this rule.")
    }
  }

  imgui.Dummy({0, px(8)})
  imgui.PushStyleColorImVec4(.Button, tint(COL_BAD, 0.25))
  if imgui.Button("Delete step", {-1, 0}) {
    ed_delete_step(ed, ed.sel)
  }
  imgui.PopStyleColor(1)
}

// The RULE form: what selects it, whether it fires once or runs while true, and where it sits.
@(private = "file")
gui_ed_rule_inspector :: proc(ed: ^Gui_Editor, rule: ^Rule, f: ^Gui_Frame) {
  index := ed_rule_index(ed, rule.id)
  imgui.PushStyleColorImVec4(.Text, COL_ACCENT)
  imgui.TextUnformatted(fmt.ctprintf("Rule %d of %d  #%d", index + 1, len(ed.doc.rules), u32(rule.id)))
  imgui.PopStyleColor(1)
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextWrapped("%s", fmt.ctprintf("%s", condition_title(rule.condition)))
  imgui.PopStyleColor(1)
  imgui.Separator()

  imgui.SeparatorText("name")
  if ed.rule_label_for != rule.id {
    panel_buf_set(ed.rule_label_buffer[:], rule.label)
    ed.rule_label_for = rule.id
  }
  imgui.SetNextItemWidth(-1)
  if imgui.InputTextWithHint("##edrulelabel", "what is this rule for?", cstring(raw_data(ed.rule_label_buffer[:])), len(ed.rule_label_buffer)) {
    delete(rule.label)
    rule.label = strings.clone(strings.trim_space(panel_buf_str(ed.rule_label_buffer[:])))
    ed.dirty = true
  }
  if imgui.IsItemActivated() {
    ed_snapshot(ed)
  }
  if imgui.IsItemHovered() {
    imgui.SetTooltip("A sentence for the list and the run log. It is what the dock's chips and the trace say when this rule takes over.")
  }

  imgui.SeparatorText("when")
  // The SAME editor a step's condition gets, which is the whole reason the rule model cost so little
  // UI: a rule's WHEN is a Script_Condition, so every widget already knew how to edit one. It passes
  // nil for the step, which ed_params documents as the case where there is no caption to rebuild.
  ed_condition_editor(ed, nil, &rule.condition, f, "rulecond", ed.text_buffers[ED_TEXT_CONDITION:ED_TEXT_UNTIL])

  imgui.SeparatorText("how it fires")
  once := rule.fire_on_edge
  if imgui.RadioButton("once, when it starts", once) && !once {
    ed_snapshot(ed)
    rule.fire_on_edge = true
    ed.dirty = true
  }
  if imgui.IsItemHovered() {
    imgui.SetTooltip("Fires on the rising edge and runs its steps to the end, even if the condition goes false underneath it. Re-arms when the condition goes false.")
  }
  if imgui.RadioButton("while it's true", !once) && once {
    ed_snapshot(ed)
    rule.fire_on_edge = false
    ed.dirty = true
  }
  if imgui.IsItemHovered() {
    imgui.SetTooltip("Runs for as long as the condition holds, and is stopped the moment it does not.")
  }

  imgui.SeparatorText("order")
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextWrapped("Position is urgency: this rule interrupts every rule below it, and waits for every rule above.")
  imgui.PopStyleColor(1)
  imgui.Dummy({0, px(4)})
  if index <= 0 {
    imgui.BeginDisabled()
  }
  if imgui.Button("Move up", {-1, 0}) {
    ed_move_rule(ed, rule.id, -1)
  }
  if index <= 0 {
    imgui.EndDisabled()
  }
  imgui.Dummy({0, px(4)})
  if index >= len(ed.doc.rules) - 1 {
    imgui.BeginDisabled()
  }
  if imgui.Button("Move down", {-1, 0}) {
    ed_move_rule(ed, rule.id, 1)
  }
  if index >= len(ed.doc.rules) - 1 {
    imgui.EndDisabled()
  }

  imgui.Dummy({0, px(8)})
  enabled := rule.enabled
  if imgui.Checkbox("on##edruleon", &enabled) {
    ed_snapshot(ed)
    rule.enabled = enabled
    ed.dirty = true
  }
  if imgui.IsItemHovered() {
    imgui.SetTooltip("Off, the rule is skipped entirely - the way to isolate one without deleting it.")
  }

  imgui.Dummy({0, px(8)})
  imgui.PushStyleColorImVec4(.Button, tint(COL_BAD, 0.25))
  if imgui.Button("Delete rule", {-1, 0}) {
    ed_delete_rule(ed, rule.id)
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
// Steps with nothing to configure are SKIPPED. Listing the empty ones would bury the numbers, which is
// precisely the problem the panel exists to solve.

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
  switch s.op {
  case .Action:
    if def := action_def(s.action.kind); def != nil {
      n += len(def.params)
    }
    if s.has_until {
      n += condition_param_count(s.until)
    }
  case .Wait_For:
    n += condition_param_count(s.condition)
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
  if hit(block_title(s), query) || hit(block_name(s), query) {
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
  // Rules contribute one WINDOW per rule (its WHEN) plus one per step of its DO, laid out in the same
  // flat array and in the same reading order. Counting them the same way it indexes them is what keeps
  // the stride honest - getting those two out of step is the bug this seeding already carries a comment
  // about (a stride of 6 against a seed of 18 showed every row its neighbour's arguments).
  count := ed_option_slot_count(ed)
  need := count * ED_TEXT_BUFFERS_PER_STEP
  if ed.options_seeded_revision == ed.options_revision && ed.options_seeded_step_count == count && len(ed.options_text_buffers) == need {
    return
  }
  resize(&ed.options_text_buffers, need)
  slot := 0
  window :: proc(ed: ^Gui_Editor, slot: int) -> [][ED_TEXT_BUFFER_SIZE]u8 {
    b := slot * ED_TEXT_BUFFERS_PER_STEP
    return ed.options_text_buffers[b:b + ED_TEXT_BUFFERS_PER_STEP]
  }
  for &rule in ed.doc.rules {
    ed_seed_condition_text_buffers(window(ed, slot), rule.condition)
    slot += 1
    for s in rule.steps {
      ed_seed_step_text_buffers(window(ed, slot), s)
      slot += 1
    }
  }
  ed.options_seeded_revision = ed.options_revision
  ed.options_seeded_step_count = count
}

// How many text-buffer windows this document needs. ONE definition, used by the seeding above and by
// the indexing in gui_ed_rules - see the stride note there.
@(private = "file")
ed_option_slot_count :: proc(ed: ^Gui_Editor) -> int {
  n := 0
  for rule in ed.doc.rules {
    n += 1 + len(rule.steps) // the WHEN, then each step of the DO
  }
  return n
}


// Every ROW's arguments, for the rule list. Which event each row IS is chosen in the inspector - this
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
// THE RULE LIST, as the editor draws it: a WHEN column and a numbered DO beside it, top to bottom, in
// priority order. This is the whole authoring surface for a rule-list behaviour - there is no canvas,
// because there is nothing to place and nothing to wire.
//
// It is deliberately built out of the SAME editors the options panel uses (ed_condition_params,
// ed_params, ed_call_args). That is not code reuse for its own sake: a rule's WHEN is a
// Script_Condition and a rule's step is a Script_Step, exactly as they were, so any widget that could
// edit one before can edit one now. What changed is the container, and only the container.
gui_ed_rules :: proc(ps: ^Panel_State, ed: ^Gui_Editor, f: ^Gui_Frame) {
  ed_seed_options_text_buffers(ed)

  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextWrapped(
    "%s",
    fmt.ctprintf(
      "Read top to bottom every tick: the first rule whose WHEN holds runs its DO. A rule higher in the list interrupts one lower down, and the lower one resumes where it was.%s",
      ed.doc.route == "" ? "" : fmt.tprintf("  Route: %s.", ed.doc.route),
    ),
  )
  imgui.PopStyleColor(1)
  imgui.Dummy({0, px(4)})

  if !imgui.BeginChild("##rulelist", {0, 0}) {
    imgui.EndChild()
    return
  }
  defer imgui.EndChild()

  // Descriptions inline: this pane IS what you are reading, unlike the inspector beside it.
  ed.param_help_inline = true
  defer ed.param_help_inline = false

  // Structural edits are DEFERRED to the end of the frame. Adding or deleting a row re-allocates
  // ed.doc.rules, and doing that mid-walk would leave the `for &rule` loop holding a pointer into
  // freed memory - the same reason the browser's open request is honoured after its list ends.
  add_step_to := Node_Id(0)
  add_rule := false

  slot := 0
  for &rule, ri in ed.doc.rules {
    imgui.PushIDInt(i32(ri))
    imgui.Dummy({0, px(8)})
    imgui.SeparatorText(fmt.ctprintf("%d.  %s", ri + 1, rule.label == "" ? "(unnamed rule)" : rule.label))
    // A click in the trace strip or the Problems tab asked for this row. Honoured after the heading is
    // submitted, because SetScrollHereY works off the item just drawn.
    if ed.scroll_to != 0 && ed.scroll_to == rule.id {
      imgui.SetScrollHereY(0.2)
      ed.scroll_to = 0
    }

    // --- WHEN ---
    imgui.PushStyleColorImVec4(.Text, ed_cat_color(.Sense))
    if imgui.SmallButton(fmt.ctprintf("WHEN  %s", condition_title(rule.condition))) {
      ed_sel_only(ed, rule.id) // the inspector edits the RULE: its label, its WHEN, where it sits
    }
    imgui.PopStyleColor(1)
    if imgui.IsItemHovered() {
      imgui.SetTooltip("Edit this rule - its name, what selects it, and whether it fires once or runs while true.")
    }
    b := slot * ED_TEXT_BUFFERS_PER_STEP
    ed_condition_params(ed, nil, "when", &rule.condition, ed.options_text_buffers[b + ED_TEXT_CONDITION:b + ED_TEXT_UNTIL], f)
    slot += 1

    // Once vs while, per row. The verb supplies the default when a rule is authored; this is the
    // override, and it is the visible form of Condition_State.latched.
    edge := rule.fire_on_edge
    if imgui.Checkbox("once, when it starts", &edge) {
      ed_snapshot(ed)
      rule.fire_on_edge = edge
      ed.dirty = true
    }
    if imgui.IsItemHovered() {
      imgui.SetTooltip("On: fires on the rising edge and runs to completion. Off: runs for as long as the condition holds, and stops the moment it does not.")
    }

    // --- DO ---
    imgui.Dummy({0, px(4)})
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextUnformatted("DO")
    imgui.PopStyleColor(1)
    for &s, si in rule.steps {
      imgui.PushIDInt(i32(si))
      sb := slot * ED_TEXT_BUFFERS_PER_STEP
      // Icon AND colour, both off the block's category. Two signals for one fact is not redundancy
      // here: colour is what you see scanning the list, and the icon is what survives at a glance on a
      // row whose title you have not read yet.
      imgui.PushStyleColorImVec4(.Text, ed_node_color(s))
      if imgui.SmallButton(fmt.ctprintf("  %r  %d. %s", ed_node_icon(s), si + 1, block_title(s))) {
        ed_sel_only(ed, s.id)
      }
      imgui.PopStyleColor(1)
      if ed.scroll_to != 0 && ed.scroll_to == s.id {
        imgui.SetScrollHereY(0.2)
        ed.scroll_to = 0
      }
      #partial switch s.op {
      case .Action:
        if def := action_def(s.action.kind); def != nil {
          ed_params(ed, &s, "act", def.params, &s.action.nums, &s.action.strs, ed.options_text_buffers[sb + 0:sb + 2], f)
        }
        if s.has_until {
          imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
          imgui.TextUnformatted(fmt.ctprintf("ends early when: %s", condition_title(s.until)))
          imgui.PopStyleColor(1)
          ed_condition_params(ed, &s, "until", &s.until, ed.options_text_buffers[sb + ED_TEXT_UNTIL:sb + ED_TEXT_BUFFERS_PER_STEP], f)
        }
      case .Wait_For:
        ed_condition_params(ed, &s, "cond", &s.condition, ed.options_text_buffers[sb + ED_TEXT_CONDITION:sb + ED_TEXT_UNTIL], f)
      }
      imgui.PopID()
      slot += 1
    }
    if len(rule.steps) == 0 {
      imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
      imgui.TextUnformatted("  (nothing yet)")
      imgui.PopStyleColor(1)
    }
    imgui.Dummy({0, px(2)})
    if imgui.SmallButton("+ step") {
      add_step_to = rule.id
    }
    if imgui.IsItemHovered() {
      imgui.SetTooltip("Add a step to this rule's DO. Steps run in order, and one that fails stops the rest.")
    }
    imgui.PopID()
  }

  if len(ed.doc.rules) == 0 {
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.Dummy({0, px(8)})
    imgui.TextWrapped("This behaviour has no rules yet. A rule is one WHEN and what to DO about it.")
    imgui.PopStyleColor(1)
  }

  imgui.Dummy({0, px(10)})
  if imgui.Button("+ rule", {px(120), 0}) {
    add_rule = true
  }
  if imgui.IsItemHovered() {
    imgui.SetTooltip("Add a rule at the BOTTOM of the list. Move it up to make it more urgent than the ones above it.")
  }

  // The deferred edits, now that nothing holds a pointer into the arrays.
  if add_rule {
    ed_sel_only(ed, ed_add_rule(ed))
  } else if add_step_to != 0 {
    // Selected as it is created, so the inspector is already showing the block picker - a new step is
    // `action` with no block chosen, and the next thing you have to do is choose one.
    if id := ed_add_step(ed, add_step_to, .Action); id != 0 {
      ed_sel_only(ed, id)
    }
  }
}

// The OPTIONS tab: what the behaviour is, rather than what it does.
//
// It used to be a generated list of every settable value in the document, because the values lived on
// nodes scattered across a canvas and there was nowhere else to see them all. The rule list IS that
// view now - gui_ed_rules draws each rule's arguments inline under its own row - so what is left here
// is the handful of facts that belong to the document as a whole and to no rule in particular.
gui_ed_options :: proc(ps: ^Panel_State, ed: ^Gui_Editor, f: ^Gui_Frame) {
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextWrapped("What this behaviour IS. The rules themselves - and every value they take - are on the Rules tab.")
  imgui.PopStyleColor(1)
  imgui.Dummy({0, px(6)})

  if !imgui.BeginChild("##optlist", {0, 0}) {
    imgui.EndChild()
    return
  }
  defer imgui.EndChild()

  imgui.SeparatorText("Description")
  if ed.desc_buffer_for != ed.doc.name {
    panel_buf_set(ed.desc_buffer[:], ed.doc.desc)
    ed.desc_buffer_for = strings.clone(ed.doc.name, context.temp_allocator)
  }
  imgui.SetNextItemWidth(-1)
  if imgui.InputTextWithHint("##eddesc", "one line: what does this behaviour do?", cstring(raw_data(ed.desc_buffer[:])), len(ed.desc_buffer)) {
    delete(ed.doc.desc)
    ed.doc.desc = strings.clone(strings.trim_space(panel_buf_str(ed.desc_buffer[:])))
    ed.dirty = true
  }
  if imgui.IsItemActivated() {
    ed_snapshot(ed)
  }
  imgui.PushStyleColorImVec4(.Text, tint(COL_TEXT_DIM, 0.85))
  imgui.TextWrapped("Shown next to this behaviour's name in the browser. Without one, its tile is a bare filename.")
  imgui.PopStyleColor(1)

  // THE ROUTE. Beside the rules rather than inside them, because a route is the one genuinely ORDERED
  // thing in this domain and it already has a better editor than any list could be - you draw it on the
  // map. `patrol` walks whatever is named here, one stop per turn, so anything more urgent gets its go
  // between stops.
  imgui.Dummy({0, px(10)})
  imgui.SeparatorText("Route")
  routes := waypoint_list_names()
  label := ed.doc.route == "" ? cstring("(none)") : fmt.ctprintf("%s", ed.doc.route)
  imgui.SetNextItemWidth(-1)
  if imgui.BeginCombo("##edroute", label) {
    if imgui.Selectable("(none)", ed.doc.route == "") {
      ed_snapshot(ed)
      delete(ed.doc.route)
      ed.doc.route = strings.clone("")
      ed.dirty = true
    }
    for name in routes {
      if imgui.Selectable(fmt.ctprintf("%s", name), name == ed.doc.route) {
        ed_snapshot(ed)
        delete(ed.doc.route)
        ed.doc.route = strings.clone(name)
        ed.dirty = true
      }
    }
    imgui.EndCombo()
  }
  imgui.PushStyleColorImVec4(.Text, tint(COL_TEXT_DIM, 0.85))
  if len(routes) == 0 {
    imgui.TextWrapped("No saved routes. Draw one on the radar (mode W), then 'waypoints save <name>'.")
  } else {
    imgui.TextWrapped("The waypoint set a 'patrol' step walks. Recorded on the radar and saved with 'waypoints save <name>'.")
  }
  imgui.PopStyleColor(1)

  imgui.Dummy({0, px(10)})
  imgui.SeparatorText("Collision")
  ignore := ed.doc.ignore_collision
  if imgui.Checkbox("ignore collision##edcoll", &ignore) {
    ed_snapshot(ed)
    ed.doc.ignore_collision = ignore
    ed.dirty = true
  }
  imgui.PushStyleColorImVec4(.Text, tint(COL_TEXT_DIM, 0.85))
  imgui.TextWrapped(
    "Pick and approach monsters without checking the path is clear. For a map whose floor props do not " +
    "really block - most dungeons. Everywhere else it will happily walk you into a wall.",
  )
  imgui.PopStyleColor(1)
  imgui.Dummy({0, px(6)})
}

@(private = "file")
ed_op_choice :: proc(ed: ^Gui_Editor, s: ^Script_Step, op: Script_Op, tip: cstring) {
  if imgui.Selectable(fmt.ctprintf("%s", BHV_OP_NAMES[op]), s.op == op) && s.op != op {
    s.op = op
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
// This is what boolean logic looks like here, and why there was never an AND/OR node even when there
// was a canvas: a node would have meant a second kind of wire - a value feeding a control node - and a
// reader would have to keep both in their head. Rows are how a rule gets written down anyway, and they
// work identically in the three places a condition appears: a rule's WHEN, a wait_for, and an `until`.
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
    case .Names, .Mob, .Key, .Var_Name, .Choice, .Chart_Name:
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
        case .Chart_Name:
          hint = "one of your blocks"
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
// A RULE'S WHEN gets a window of its own, seeded into the same condition slots a step's condition uses
// - so ed_condition_params can be handed either one without knowing which it got.
ed_seed_condition_text_buffers :: proc(text_buffers: [][ED_TEXT_BUFFER_SIZE]u8, condition: Script_Condition) {
  if len(text_buffers) < ED_TEXT_BUFFERS_PER_STEP {
    return
  }
  for i in 0 ..< SCRIPT_MAX_CONDITION_ROWS {
    cs := i < condition_row_count(condition) ? condition_row(condition, i).strs : [2]string{}
    panel_buf_set(text_buffers[ED_TEXT_CONDITION + i * 2 + 0][:], cs[0])
    panel_buf_set(text_buffers[ED_TEXT_CONDITION + i * 2 + 1][:], cs[1])
  }
}

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
  ed.text_buffers_for_node = s.id
}


// --- problems ----------------------------------------------------------------------------------------
//
// The static half of "what is wrong with this behaviour" (script_lint.odin has the analysis; this only
// renders it). Every row is a BUTTON that scrolls the list to the row it is about, because a problem
// you then have to go and find is most of the work still left.
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
// Rows are clickable and scroll the list to their row, the same as a problem row: the two panels
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
      // Space flag: Odin pads a number with '0' without it, so 1.5s rendered as "0001.50s".
      imgui.TextUnformatted(fmt.ctprintf("% 7.2fs", f64(r.at - base) / 1e9))
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


// --- finding a row ------------------------------------------------------------------------------------

// Scroll to the row for <id>. On a canvas this panned and centred a viewport; in a list it is a scroll,
// which is the whole of what "go to that node" ever meant to the trace strip and the Problems tab -
// both of which already addressed rows by Node_Id and never by position.
ed_go_to :: proc(ed: ^Gui_Editor, id: Node_Id) {
  ed.scroll_to = id
}
