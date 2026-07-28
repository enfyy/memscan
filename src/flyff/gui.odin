package flyff

import "core:fmt"
import "core:math"
import "core:strings"
import "core:sync"
import "core:thread"
import rl "vendor:raylib"

import "../engine"

import imgui_rl "../../lib/imgui_impl_raylib"
import imgui "../../lib/odin-imgui"

// ===========================================================================
// THE UI. Dear ImGui over the radar window - replaced raygui wholesale in the v1 redesign.
//
// Everything here is a floating overlay on top of the map; there is no side panel. The surface is
// deliberately small: a toolbar (setup traffic light, zone editor, camera follow, no-walk overlay, mute),
// a recenter puck that only exists while the camera is free, two gauges (penya, bag), and two dialogs
// (attach, setup). Everything else the old panel carried - the auto section, the Options modal,
// leaderboards - is REPL-only for now and comes back with the scripting UI.
//
// Window convention: a dialog is closed by the X in its own titlebar and nothing else. No in-body Close
// buttons, and ESC is not a close key anywhere (raylib's ESC-quits-the-window default is off - see
// cli_radar), so a stray ESC can never take the map down with it.
//
// The contract from the raygui era is unchanged and load-bearing: this code runs in cli_radar's
// exec_mutex-UNLOCKED draw phase, so it must never touch `session`. It reads a Gui_Frame snapshot taken
// while locked, and every action it wants to perform is APPENDED to Panel_State.pending as a plain CLI
// command string, which cli_radar drains through exec_line after re-locking. A widget that mutates the
// session directly is a race with the watcher thread - don't.
// ===========================================================================

// ===========================================================================
// Fonts + icons
// ===========================================================================

// Embedded so the exe stays a single file (build.bat's `resources` copy is not involved). Fredoka is the
// UI face; Material Icons is MERGED into the same atlas, so an icon is just another codepoint in the
// current font and needs no PushFont/PopFont dance at the call site.
@(rodata)
FONT_UI := #load("../../resource/font/fredoka/fredoka.ttf")
@(rodata)
FONT_ICONS := #load("../../resource/font/material/material_icons.otf")

// Material Icons codepoints. Kept as RUNES rather than as literal private-use characters in the source:
// those are invisible in an editor (and easy to mangle), and every icon is drawn through gui_draw_icon,
// which wants the codepoint anyway. Only the ones we actually draw are baked - the full private-use block
// is ~7000 glyphs and would blow the atlas up for nothing.
ICON_VOLUME_OFF :: rune(0xe04f) // volume_off   - muted
ICON_VOLUME_UP :: rune(0xe050) // volume_up    - sound on
ICON_CAMERA :: rune(0xe04b) // videocam     - the map camera (follow the player / free)
ICON_BLOCKED :: rune(0xe14b) // block        - the no-walk terrain overlay
ICON_ZONE :: rune(0xe162) // select_all   - the zone editor (an area, not a pen)
ICON_INVENTORY :: rune(0xf19c) // backpack     - bag gauge (0xe1a1 'inventory_2' read as an archive box)
ICON_PENYA :: rune(0xe263) // monetization - penya gauge
ICON_LOCATION :: rune(0xe55c) // my_location  - recenter on the player (the map convention)
ICON_SETTINGS :: rune(0xe8b8) // settings     - the setup traffic light
// behaviour surface (transport + browser)
ICON_PLAY :: rune(0xe037) // play_arrow
ICON_PAUSE :: rune(0xe034) // pause
ICON_REPLAY :: rune(0xe042) // replay       - rewind to the start node
ICON_STEP :: rune(0xe044) // skip_next    - execute one block
ICON_STOP :: rune(0xe047) // stop
ICON_CHARTS :: rune(0xe97a) // account_tree - the behaviour browser
ICON_DELETE :: rune(0xe872) // delete
ICON_COPY :: rune(0xe14d) // content_copy - duplicate a chart
ICON_EDIT :: rune(0xe3c9) // edit         - rename
ICON_FILE :: rune(0xe873) // description  - a saved chart
ICON_CODE :: rune(0xe86f) // code         - a chart defined in Odin (read-only)
// node editor (gui_nodes.odin)
ICON_ADD :: rune(0xe145) // add          - the add-node palette / the browser's New tile
ICON_SAVE :: rune(0xe161) // save         - write the edited chart to its .bhv

// The single source of truth for what gets baked: icon_ranges is DERIVED from this at init, so adding an
// icon above is the entire change - a glyph can never be referenced but missing from the atlas. gui_init
// also verifies every entry actually exists in the font, so a wrong codepoint says so instead of drawing
// an invisible button.
@(rodata)
ICON_ALL := [?]rune {
  ICON_VOLUME_OFF,
  ICON_VOLUME_UP,
  ICON_CAMERA,
  ICON_BLOCKED,
  ICON_ZONE,
  ICON_INVENTORY,
  ICON_PENYA,
  ICON_LOCATION,
  ICON_SETTINGS,
  ICON_PLAY,
  ICON_PAUSE,
  ICON_REPLAY,
  ICON_STEP,
  ICON_STOP,
  ICON_CHARTS,
  ICON_DELETE,
  ICON_COPY,
  ICON_EDIT,
  ICON_FILE,
  ICON_CODE,
  ICON_ADD,
  ICON_SAVE,
}

// Glyph ranges for the merge: inclusive pairs, zero-terminated (one degenerate pair per icon). MUST
// outlive the atlas build (ImGui keeps the pointer), hence a package global rather than a gui_init local.
@(private = "file")
icon_ranges: [2 * len(ICON_ALL) + 1]imgui.Wchar

// The vertical ink extent shared by the WHOLE icon set, measured off the built atlas in gui_init.
// gui_draw_icon centres on this rather than on each glyph's own box - see there for why.
@(private = "file")
icon_ink_y0, icon_ink_y1: f32

// Final optical nudge, in px at scale 1, positive = down. Zero because the geometry is now exact (see
// the FontGlyph note in lib/odin-imgui/imgui.odin - the binding used to report the wrong rect, which is
// what made every icon sit high). Kept as one named knob so a future optical tweak is one number for the
// whole set rather than a per-call-site fudge.
ICON_NUDGE_Y :: f32(0)

// ===========================================================================
// Theme
// ===========================================================================

// Flat and dark, sitting on the radar's {12,16,22} clear colour. One accent, three status colours, and
// almost no chrome - the complexity budget belongs to the scripting graph, not to this shell.
COL_SURFACE :: imgui.Vec4{0.070, 0.090, 0.118, 0.94}
COL_BORDER :: imgui.Vec4{0.161, 0.200, 0.251, 1.0}
COL_TEXT :: imgui.Vec4{0.788, 0.820, 0.855, 1.0}
COL_TEXT_DIM :: imgui.Vec4{0.431, 0.478, 0.533, 1.0}
COL_ACCENT :: imgui.Vec4{0.353, 0.663, 0.902, 1.0}
COL_OK :: imgui.Vec4{0.247, 0.702, 0.498, 1.0}
COL_WARN :: imgui.Vec4{0.910, 0.698, 0.227, 1.0}
COL_BAD :: imgui.Vec4{0.878, 0.322, 0.322, 1.0}
COL_TRACK :: imgui.Vec4{0.106, 0.133, 0.173, 1.0}

// Authored at scale 1. imgui.Style_ScaleAllSizes handles the STYLE's own metrics, but every size this
// file passes explicitly has to be multiplied by gui_scale itself - hence px().
TOOLBAR_PAD :: f32(10) // margin from the window edge for the toolbar / gauge overlays
ICON_BTN :: f32(34) // icon button side
FAB_BTN :: f32(44) // floating action button side (the bottom-right recenter puck)
GAUGE_W :: f32(190) // gauge bar width
GAUGE_H :: f32(22)
GAUGE_ICON_W :: f32(22) // icon gutter left of a gauge bar

// layout.ui_scale, latched when the window opened (the font atlas is baked at this size, so it cannot
// change while the window is up). Package-local, single-window - the radar is never opened twice at once.
@(private = "file")
gui_scale := f32(1)

// Package-visible (not file-private) because the behaviour surface in gui_behaviour.odin / gui_nodes.odin
// authors its sizes at scale 1 too, and every one of them has to go through here.
px :: #force_inline proc(v: f32) -> f32 {
  return math.round(v * gui_scale)
}

// The raw factor behind px(), for the one place that needs it UNROUNDED: the node canvas composes it
// with its own zoom, and rounding the two separately makes a node's box and its text drift apart.
gui_ui_scale :: #force_inline proc() -> f32 {
  return gui_scale
}

PENYA_CAP :: i64(2_147_483_647) // max(i32) - the in-game penya ceiling; farmed penya past it is LOST
PENYA_WARN :: PENYA_CAP - 25_000_000 // start screaming 25M short of it

// ===========================================================================
// Types
// ===========================================================================

// Everything the (unlocked) draw needs, snapshotted under exec_mutex by cli_radar. Nothing in here is a
// pointer into session-owned memory that the watcher can realloc.
Gui_Frame :: struct {
  // process / session
  attached:      bool,
  ptr_size:      int,
  pid:           u32,
  proc_name:     string,
  // setup checklist
  groups:        [10]Setup_Group,
  opins:         [4]Setup_Group,
  setup_running: bool,
  setup_step:    int,
  // gauges
  penya_show:    bool,
  penya_cur:     i64,
  inv_have:      bool,
  inv_used:      int,
  inv_cap:       int,
  // toolbar state
  sfx_on:        bool,
  nowalk_on:     bool,
  // tunables shown in a dialog
  attack_range:  f32,
  // fence menu
  fence_active:  bool,
  fence_shapes:  int,
  // behaviour run state (Script_Run, snapshotted - the watcher owns the real one)
  script_active: bool,
  script_paused: bool,
  script_step:   bool, // single-step debug mode is on
  script_irq:    bool, // an interrupt region is executing
  script_name:   string, // temp-allocated copies; they outlive the draw, not the frame
  script_pc:     int, // 1-based, for display
  script_len:    int, // main program length (regions are not part of the count)
  script_line:   string,
  script_node:   Node_Id, // the current step's identity - what the editor highlights

  // Block availability, evaluated under the lock because def.avail reads the session. The node
  // editor's palette and inspector gate on this - same source as `script blocks`, so a block the
  // catalog lists as [--] is the same block the palette draws as unusable. The `why` strings are
  // rodata literals from the avail procs, so holding them past the frame is safe.
  // Enabled global interrupts (interrupt.odin), snapshotted so the browser's checkboxes and the
  // editor's arm/disarm button can read "is this one armed" without touching the session.
  irq:           [FLYFF_MAX_INTERRUPTS]Gui_Irq_Row,
  irq_n:         int,

  // Where the character is standing, for the node editor's "Here" button on a Coord argument -
  // typing a waypoint by hand is exactly the thing you have the game open to avoid.
  player_have:   bool,
  player_pos:    [3]f32,

  act_ok:        [Script_Action_Kind]bool,
  act_why:       [Script_Action_Kind]string,
  ev_ok:         [Script_Event_Kind]bool,
  ev_why:        [Script_Event_Kind]string,
}

// One armed global interrupt, as the draw phase sees it. Strings are temp-allocated clones taken
// under the lock: the watcher owns the real ones and irq_reload frees them.
Gui_Irq_Row :: struct {
  name:    string,
  trigger: string,
  fires:   int,
  ok:      bool,
  why:     string,
}

// Radar-local view state the toolbar drives directly (these are cli_radar stack locals, not session
// state, so the draw phase may write them - the watcher never sees them).
Gui_View :: struct {
  edit:     ^bool,
  cam_lock: ^bool,
  recenter: ^bool, // set to true by the recenter button; cli_radar consumes + clears it
  tool:     ^Radar_Tool,
  tag:      ^int, // fence draw tag: 0 = include(+), 1 = exclude(-), 2 = avoid(!)
}

// Per-window UI state: the deferred command queue plus the widget buffers. A cli_radar LOCAL (like
// poly_wip), never a package global - a shared global would be the forbidden Radar struct. `pending` and
// the process rows are heap-owned and freed on close.
Panel_State :: struct {
  pending:          [dynamic]string, // deferred CLI commands, drained under exec_mutex after each frame

  // attach dialog
  attach_filter:    [64]u8,
  attach_seeded:    bool,
  attach_rows:      [dynamic]Gui_Proc_Row,
  attach_scan_at:   f64, // rl.GetTime() of the last process scan (throttled)
  attach_scanned:   string, // the filter the current rows were scanned with (heap-owned)

  // setup dialog
  setup_open:       bool,
  setup_name:       [64]u8,
  setup_hp:         [16]u8,
  setup_penya:      [24]u8,
  ar_slider:        f32, // attack_range while dragging; re-seeded from the snapshot whenever it is not
  ar_active:        bool,

  // behaviour browser (gui_behaviour.odin)
  browser_open:     bool,
  browser_filter:   [64]u8,
  browser_rows:     [dynamic]Gui_Bhv_Row,
  browser_scan_at:  f64, // rl.GetTime() of the last directory scan (throttled, like the attach dialog)
  browser_rescan:   bool, // force a scan next frame - set after anything that changes the directory
  rename_from:      string, // heap-owned; "" = the rename prompt is closed
  rename_buf:       [64]u8,
  dup_from:         string, // heap-owned; "" = the duplicate prompt is closed
  dup_buf:          [64]u8,

  // node editor (gui_nodes.odin) - owns a Behaviour_Doc while it is open
  ed:               Gui_Editor,
}

// One row in the attach dialog. Owned copies: find_process_id_by_name hands back a window_title that is
// TEMP-allocated regardless of the allocator you pass it, so both strings are cloned here.
Gui_Proc_Row :: struct {
  pid:   u32,
  name:  string,
  title: string,
}

// ===========================================================================
// Lifecycle
// ===========================================================================

// Create the ImGui context, build the font atlas and apply the theme. Call once after InitWindow.
// `scale` is layout.ui_scale: the atlas is rasterized at that size, so it is fixed for the window's life.
gui_init :: proc(scale: f32) {
  s := clamp(scale, UI_SCALE_MIN, UI_SCALE_MAX)
  gui_scale = s

  imgui.CHECKVERSION()
  imgui.CreateContext()
  imgui_rl.init()

  fonts := imgui.GetIO().Fonts
  ui_cfg := gui_font_config()
  font := imgui.FontAtlas_AddFontFromMemoryTTF(fonts, raw_data(FONT_UI), i32(len(FONT_UI)), math.round(17 * s), &ui_cfg)

  for r, i in ICON_ALL {
    icon_ranges[i * 2] = imgui.Wchar(r) // one degenerate (single-codepoint) inclusive pair per icon
    icon_ranges[i * 2 + 1] = imgui.Wchar(r)
  }
  icon_ranges[len(icon_ranges) - 1] = 0 // the terminator ImGui scans for
  icon_cfg := gui_font_config()
  icon_cfg.MergeMode = true
  // No GlyphOffset / GlyphMinAdvanceX nudging: those shifted the icons off-centre (down and right) in
  // every button. Placement is gui_draw_icon's job now - it centres the glyph's real ink box.
  imgui.FontAtlas_AddFontFromMemoryTTF(fonts, raw_data(FONT_ICONS), i32(len(FONT_ICONS)), math.round(18 * s), &icon_cfg, &icon_ranges[0])

  imgui_rl.build_font_atlas()
  gui_apply_theme(s)

  // A codepoint that isn't in the font rasterizes as nothing, i.e. a blank button that still works - the
  // kind of bug you only notice by squinting. Say it out loud once instead. (The icons were MERGED into
  // the UI font, so they are glyphs of `font`; the check runs post-build, when the atlas is populated.)
  //
  // The same pass measures the set's shared vertical ink box, which gui_draw_icon centres every icon on.
  // It has to be measured rather than derived from the font's metrics: the merge bakes the icons at a
  // different size than the UI face, so where their ink lands relative to the text line is a property of
  // the built atlas, not of either font on its own.
  icon_ink_y0, icon_ink_y1 = max(f32), -max(f32)
  for r in ICON_ALL {
    g := imgui.Font_FindGlyphNoFallback(font, imgui.Wchar(r))
    if g == nil {
      fmt.eprintfln("radar UI: icon glyph U+%04X is missing from material_icons.otf (its button will be blank).", u32(r))
      continue
    }
    icon_ink_y0 = min(icon_ink_y0, g.Y0)
    icon_ink_y1 = max(icon_ink_y1, g.Y1)
  }
  if icon_ink_y0 > icon_ink_y1 { // every glyph missing - keep the centre finite so nothing draws at NaN
    icon_ink_y0, icon_ink_y1 = 0, 0
  }
  when #config(ICONDBG, false) {
    fmt.eprintfln(
      "[icondbg] FontSize=%v Ascent=%v Descent=%v  set ink y=[%v..%v] mid=%v",
      font.FontSize, font.Ascent, font.Descent, icon_ink_y0, icon_ink_y1, (icon_ink_y0 + icon_ink_y1) * 0.5,
    )
    for r in ICON_ALL {
      g := imgui.Font_FindGlyphNoFallback(font, imgui.Wchar(r))
      if g == nil {continue}
      fmt.eprintfln(
        "[icondbg]  U+%04X  x=[%v..%v] y=[%v..%v] adv=%v  own_mid=%v",
        u32(r), g.X0, g.X1, g.Y0, g.Y1, g.AdvanceX, (g.Y0 + g.Y1) * 0.5,
      )
    }
  }
}

gui_shutdown :: proc() {
  imgui_rl.shutdown()
  imgui.DestroyContext()
}

// ImFontConfig's C++ defaults are not all zero; a zeroed struct rasterizes an invisible/garbage font.
@(private = "file")
gui_font_config :: proc() -> imgui.FontConfig {
  return imgui.FontConfig {
    // #load data lives in the binary's rodata - the atlas must NOT try to free it.
    FontDataOwnedByAtlas = false,
    OversampleH = 2,
    OversampleV = 1,
    GlyphMaxAdvanceX = max(f32),
    RasterizerMultiply = 1,
    RasterizerDensity = 1,
  }
}

@(private = "file")
gui_apply_theme :: proc(scale: f32) {
  style := imgui.GetStyle()
  imgui.StyleColorsDark(style)

  style.WindowRounding = 10
  style.ChildRounding = 8
  style.FrameRounding = 7
  style.PopupRounding = 8
  style.WindowBorderSize = 1
  style.FrameBorderSize = 1
  style.WindowPadding = {14, 12}
  style.FramePadding = {10, 6}
  style.ItemSpacing = {8, 8}
  style.ItemInnerSpacing = {6, 6}
  style.ScrollbarSize = 10
  style.ScrollbarRounding = 5
  style.WindowTitleAlign = {0.0, 0.5}
  // Every circle in this UI is a rounded FRAME, not an AddCircle: the icon buttons are squares with
  // FrameRounding = side/2 (see gui_icon_button). ImGui picks the corner-arc segment count from this
  // error budget, and the 0.30px default visibly facets a 17px radius. This is NOT a size, so
  // Style_ScaleAllSizes leaves it alone - it stays an absolute pixel error at every ui_scale.
  style.CircleTessellationMaxError = 0.10

  c := &style.Colors
  c[imgui.Col.Text] = COL_TEXT
  c[imgui.Col.TextDisabled] = COL_TEXT_DIM
  c[imgui.Col.WindowBg] = COL_SURFACE
  c[imgui.Col.ChildBg] = {0, 0, 0, 0}
  c[imgui.Col.PopupBg] = COL_SURFACE
  c[imgui.Col.Border] = COL_BORDER
  c[imgui.Col.BorderShadow] = {0, 0, 0, 0}
  c[imgui.Col.FrameBg] = COL_TRACK
  c[imgui.Col.FrameBgHovered] = {0.145, 0.184, 0.239, 1.0}
  c[imgui.Col.FrameBgActive] = {0.176, 0.224, 0.290, 1.0}
  c[imgui.Col.TitleBg] = COL_TRACK
  c[imgui.Col.TitleBgActive] = COL_TRACK
  c[imgui.Col.TitleBgCollapsed] = COL_TRACK
  c[imgui.Col.Button] = {0.129, 0.165, 0.216, 1.0}
  c[imgui.Col.ButtonHovered] = {0.184, 0.239, 0.310, 1.0}
  c[imgui.Col.ButtonActive] = {0.235, 0.310, 0.400, 1.0}
  c[imgui.Col.Header] = {0.129, 0.165, 0.216, 1.0}
  c[imgui.Col.HeaderHovered] = {0.184, 0.239, 0.310, 1.0}
  c[imgui.Col.HeaderActive] = {0.235, 0.310, 0.400, 1.0}
  c[imgui.Col.Separator] = COL_BORDER
  c[imgui.Col.CheckMark] = COL_ACCENT
  c[imgui.Col.ModalWindowDimBg] = {0.02, 0.03, 0.04, 0.65}

  // Sizes are authored at scale 1 above; this multiplies them all in one shot (the FONT was already
  // rasterized at scale in gui_init, so text and chrome grow together).
  imgui.Style_ScaleAllSizes(style, scale)
}

// ===========================================================================
// Deferred command queue (the whole UI talks to the session through this)
// ===========================================================================

// Queue a CLI command for cli_radar to run under exec_mutex after this frame. The string is HEAP-owned:
// it must outlive the frame's temp free_all, which runs before the drain.
panel_enqueue :: proc(ps: ^Panel_State, cmd: string) {
  append(&ps.pending, strings.clone(cmd))
}

// Run <cmds> on a one-shot worker thread instead of the per-frame drain. For the setup pipeline only:
// it takes seconds, and draining it inline would freeze the window for the whole run. The worker takes
// exec_mutex around the commands; cli_setup yields the lock between steps so the radar keeps drawing.
Panel_Async_Job :: struct {
  session: ^Session,
  cmds:    [dynamic]string,
}

panel_run_async :: proc(session: ^Session, cmds: []string) {
  job := new(Panel_Async_Job)
  job.session = session
  job.cmds = make([dynamic]string)
  for c in cmds {
    append(&job.cmds, strings.clone(c))
  }
  thread.create_and_start_with_data(job, proc(data: rawptr) {
    j := cast(^Panel_Async_Job)data
    sync.mutex_lock(&j.session.exec_mutex)
    for c in j.cmds {
      if j.session.exec_line != nil {
        j.session.exec_line(&j.session.eng, c)
      }
    }
    sync.mutex_unlock(&j.session.exec_mutex)
    for c in j.cmds {
      delete(c)
    }
    delete(j.cmds)
    free(j)
  }, nil, .Normal, true) // self_cleanup: fire-and-forget
}

// ===========================================================================
// Small widgets
// ===========================================================================

u32_of :: proc(v: imgui.Vec4) -> u32 {
  return imgui.ColorConvertFloat4ToU32(v)
}

tint :: proc(v: imgui.Vec4, a: f32) -> imgui.Vec4 {
  return {v.x, v.y, v.z, v.w * a}
}

// Draw one icon glyph centred on (cx,cy).
//
// This exists because ImGui centres a button's label by its ADVANCE width and draws it from the text
// baseline - and for an icon font neither matches where the glyph's pixels actually are, which is what
// left every toolbar icon sitting low and off to one side. FindGlyph hands back the real ink rect
// (X0/Y0..X1/Y1, relative to the pen), so we can place the pen ourselves instead.
//
// The icons used to sit ~2px high. That was NOT this maths - it was the FontGlyph binding reporting the
// wrong rect (see the note in lib/odin-imgui/imgui.odin); `.Y0` was handing back the real Y1 and `.Y1` a
// texture V coordinate, so the "centre" was computed from two unrelated numbers. With the layout fixed
// the ink rect is real and centring on it is exact.
//
// x uses this glyph's own ink; y uses the ink box of the WHOLE icon set (icon_ink_y0/y1, measured once
// in gui_init). For Material Icons the two are the same number - every glyph in ICON_ALL measures a
// vertical mid of exactly 5.0 at scale 1, because the font centres each icon in a shared design box.
// The set box is used anyway so that one odd glyph (a future icon from another font, or one drawn off
// its box) shifts itself rather than breaking the row's alignment.
// Rounded to whole pixels so the icon stays crisp instead of half-covering two.
gui_draw_icon :: proc(dl: ^imgui.DrawList, cx, cy: f32, icon: rune, col: imgui.Vec4) {
  g := imgui.Font_FindGlyph(imgui.GetFont(), imgui.Wchar(icon))
  if g == nil {
    return
  }
  pen := imgui.Vec2 {
    math.round(cx - (g.X0 + g.X1) * 0.5),
    math.round(cy - (icon_ink_y0 + icon_ink_y1) * 0.5 + px(ICON_NUDGE_Y)),
  }
  imgui.DrawList_AddText(dl, pen, u32_of(col), fmt.ctprintf("%r", icon))
}

// A square icon button, rounded into a pill. `active` gives it the accent fill (used for toggles that
// are currently ON). The label is empty and the glyph is drawn over the frame by hand - see gui_draw_icon
// for why. `side_px` overrides the standard toolbar size (0 = ICON_BTN); it is pre-scaled by px() here.
// Returns true on click.
gui_icon_button :: proc(id: cstring, icon: rune, active: bool, tip: cstring, col: Maybe(imgui.Vec4) = nil, side_px: f32 = 0) -> bool {
  side := px(side_px > 0 ? side_px : ICON_BTN)
  accent := col.? or_else COL_ACCENT

  if active {
    imgui.PushStyleColorImVec4(.Button, tint(accent, 0.22))
    imgui.PushStyleColorImVec4(.ButtonHovered, tint(accent, 0.34))
    imgui.PushStyleColorImVec4(.ButtonActive, tint(accent, 0.46))
    imgui.PushStyleColorImVec4(.Border, tint(accent, 0.75))
    imgui.PushStyleColorImVec4(.Text, accent)
  } else {
    imgui.PushStyleColorImVec4(.Button, tint(COL_TRACK, 0.85))
    imgui.PushStyleColorImVec4(.ButtonHovered, {0.184, 0.239, 0.310, 1.0})
    imgui.PushStyleColorImVec4(.ButtonActive, {0.235, 0.310, 0.400, 1.0})
    imgui.PushStyleColorImVec4(.Border, COL_BORDER)
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  }
  imgui.PushStyleVar(.FrameRounding, side * 0.5)
  imgui.PushID(id)
  clicked := imgui.Button("##b", {side, side})
  imgui.PopID()
  imgui.PopStyleVar(1)
  // The glyph is drawn AFTER the frame (so it sits on top) but the colour has to be read while the style
  // stack is still pushed - Text is what carries the active/idle tint.
  ink := imgui.GetStyleColorVec4(.Text)^
  imgui.PopStyleColor(5)
  rmin := imgui.GetItemRectMin()
  rmax := imgui.GetItemRectMax()
  gui_draw_icon(imgui.GetWindowDrawList(), (rmin.x + rmax.x) * 0.5, (rmin.y + rmax.y) * 0.5, icon, ink)

  if tip != nil && imgui.IsItemHovered() {
    imgui.SetTooltip("%s", tip)
  }
  return clicked
}

// A filled bar with its value printed INSIDE. The text carries a 1px near-black shadow so it stays
// legible over both the filled and the empty half at any fill level - that readability is the whole
// reason this is hand-drawn instead of an imgui.ProgressBar (whose overlay text has no such guarantee).
@(private = "file")
gui_gauge :: proc(icon: rune, fraction: f32, value: cstring, fill: imgui.Vec4, pulse: f32) {
  dl := imgui.GetWindowDrawList()

  w := px(GAUGE_W)
  h := px(GAUGE_H)

  // icon gutter: a fixed-width slot with the glyph centred on the BAR's midline (not on a text baseline),
  // so the icon and its bar read as one row.
  gw := px(GAUGE_ICON_W)
  gp := imgui.GetCursorScreenPos()
  imgui.Dummy({gw, h})
  gui_draw_icon(dl, gp.x + gw * 0.5, gp.y + h * 0.5, icon, tint(fill, 0.9))
  imgui.SameLine(0, px(8))

  p := imgui.GetCursorScreenPos()
  imgui.Dummy({w, h})

  f := clamp(fraction, 0, 1)
  bar := fill
  if pulse > 0 {
    // Alarm state: swing the fill toward white so it reads as flashing, not just coloured.
    bar = {
      fill.x + (1 - fill.x) * pulse,
      fill.y + (1 - fill.y) * pulse,
      fill.z + (1 - fill.z) * pulse,
      1,
    }
  }

  // A slab, not a pill: at a low fill a full-height corner radius collapses the bar into a dot.
  r := px(6)
  imgui.DrawList_AddRectFilled(dl, p, {p.x + w, p.y + h}, u32_of(COL_TRACK), r)
  if f > 0 {
    imgui.DrawList_AddRectFilled(dl, p, {p.x + max(f * w, px(8)), p.y + h}, u32_of(tint(bar, 0.85)), r)
  }
  imgui.DrawList_AddRect(dl, p, {p.x + w, p.y + h}, u32_of(tint(COL_BORDER, 0.9)), r)

  ts := imgui.CalcTextSize(value)
  tp := imgui.Vec2{p.x + (w - ts.x) * 0.5, p.y + (h - ts.y) * 0.5}
  imgui.DrawList_AddText(dl, {tp.x + 1, tp.y + 1}, u32_of({0, 0, 0, 0.75}), value)
  imgui.DrawList_AddText(dl, tp, u32_of({0.96, 0.98, 1, 1}), value)
}

// A checklist row: coloured dot + label, with the fix-it hint on hover.
@(private = "file")
gui_check_row :: proc(g: Setup_Group) {
  dl := imgui.GetWindowDrawList()
  col := g.ok ? COL_OK : (g.required ? COL_BAD : COL_WARN)
  p := imgui.GetCursorScreenPos()
  fh := imgui.GetTextLineHeight()
  imgui.Dummy({px(14), fh})
  imgui.DrawList_AddCircleFilled(dl, {p.x + px(5), p.y + fh * 0.5}, px(4.5), u32_of(col))
  imgui.SameLine(0, px(6))
  imgui.PushStyleColorImVec4(.Text, g.ok ? COL_TEXT : COL_TEXT_DIM)
  imgui.TextUnformatted(fmt.ctprintf("%s", g.label))
  imgui.PopStyleColor(1)
  if !g.ok && imgui.IsItemHovered() {
    imgui.SetTooltip("%s", fmt.ctprintf("%s", g.need))
  }
}

// Begin a centred dialog window over a dimmed backdrop. Not an ImGui popup on purpose: the attach dialog
// must be up unconditionally whenever we are detached, which is a state, not an event, and popup-stack
// bookkeeping for that is more failure modes than it is worth. Callers pair this with imgui.End().
//
// `open` is the window's own bool: pass it and the titlebar gets the X that closes the dialog (ImGui
// clears the bool for us). That X is THE way to close a window in this UI - no in-body Close buttons, and
// no ESC (raylib's ESC-quits binding is off; see cli_radar). Pass nil for a dialog that has no way out,
// which today means only the attach dialog: closing it would leave a window with nothing in it.
gui_begin_dialog :: proc(title: cstring, w, h: f32, open: ^bool = nil) -> bool {
  vp := imgui.GetMainViewport()
  imgui.DrawList_AddRectFilled(
    imgui.GetBackgroundDrawList(),
    vp.Pos,
    {vp.Pos.x + vp.Size.x, vp.Pos.y + vp.Size.y},
    u32_of({0.02, 0.03, 0.04, 0.72}),
  )
  imgui.SetNextWindowPos({vp.Pos.x + vp.Size.x * 0.5, vp.Pos.y + vp.Size.y * 0.5}, .Always, {0.5, 0.5})
  imgui.SetNextWindowSize({px(w), px(h)}, .Always)
  return imgui.Begin(title, open, {.NoResize, .NoMove, .NoCollapse, .NoSavedSettings, .NoDocking})
}

// ===========================================================================
// Frame
// ===========================================================================

// Draw the whole UI for one frame. Runs in cli_radar's UNLOCKED draw phase - reads `f` (the snapshot),
// writes only `ps` (widget state + the deferred queue) and `view` (radar-local view bools).
gui_frame :: proc(session: ^Session, ps: ^Panel_State, f: ^Gui_Frame, view: Gui_View) {
  // Both dialogs are genuinely modal: they return instead of falling through, so the toolbar and the
  // fence menu are not merely dimmed behind them but absent. (The dim is drawn on the BACKGROUND draw
  // list, which is behind every window - leaving the HUD up would also leave it clickable.)
  if !f.attached {
    gui_attach_dialog(ps, f)
    return
  }
  if ps.setup_open {
    gui_setup_dialog(session, ps, f)
    return
  }
  // The editor is checked BEFORE the browser: it is opened from the browser and covers it, and the
  // browser's throttled directory scan has no business running underneath a full-screen canvas.
  if ps.ed.open {
    gui_node_editor(ps, f)
    return
  }
  if ps.browser_open {
    gui_behaviour_browser(ps, f)
    return
  }

  gui_toolbar(ps, f, view)
  gui_gauges(f)
  gui_recenter_fab(view)
  gui_behaviour_transport(ps, f)
  if view.edit^ {
    gui_fence_menu(ps, f, view)
  }
}

// Is a dialog swallowing input this frame? cli_radar ORs this with io.WantCaptureMouse to gate map
// input, so a click that lands NEXT TO (not on) an open dialog can't also target a mob behind it.
gui_modal_up :: proc(ps: ^Panel_State, attached: bool) -> bool {
  return !attached || ps.setup_open || ps.browser_open || ps.ed.open
}

// ===========================================================================
// Toolbar (top-left, over the map)
// ===========================================================================

@(private = "file")
gui_toolbar :: proc(ps: ^Panel_State, f: ^Gui_Frame, view: Gui_View) {
  vp := imgui.GetMainViewport()
  imgui.SetNextWindowPos({vp.Pos.x + px(TOOLBAR_PAD), vp.Pos.y + px(TOOLBAR_PAD)}, .Always)
  imgui.PushStyleVarImVec2(.WindowPadding, {px(8), px(8)})
  if imgui.Begin("##toolbar", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoSavedSettings, .AlwaysAutoResize, .NoNavInputs, .NoDocking}) {
    // --- setup traffic light: green = everything pinned, yellow = only optional pins missing,
    // red = a REQUIRED group missing. Reads the same setup_groups/optional_pins that `status` prints,
    // so the light can never drift from the checklist. Click opens the Setup dialog.
    state, tip := gui_setup_state(f)
    light := state == .Ok ? COL_OK : (state == .Warn ? COL_WARN : COL_BAD)
    if f.setup_running {
      light = COL_ACCENT
      tip = fmt.ctprintf("Setup running... step %d/9", f.setup_step)
    }
    if gui_icon_button("tl", ICON_SETTINGS, true, tip, light) {
      ps.setup_open = true
    }
    imgui.SameLine(0, px(6))

    // Behaviours. Highlighted while something is running, so the toolbar answers "is the bot doing
    // anything" without the transport strip having to be read.
    if gui_icon_button("charts", ICON_CHARTS, f.script_active, f.script_active ? fmt.ctprintf("Running '%s' - click for the chart browser", f.script_name) : "Behaviour charts  ('script list')") {
      ps.browser_open = true
      ps.browser_rescan = true
    }
    imgui.SameLine(0, px(6))

    if gui_icon_button("edit", ICON_ZONE, view.edit^, view.edit^ ? "Zone editor: ON  (E)" : "Zone editor - draw where farming is allowed  (E)") {
      view.edit^ = !view.edit^
    }
    imgui.SameLine(0, px(6))

    // Camera FOLLOW, not a padlock: on = the view tracks the player, off = free pan. When it is off the
    // recenter puck appears bottom-right (gui_recenter_fab), so this button never needs a twin up here.
    if gui_icon_button("cam", ICON_CAMERA, view.cam_lock^, view.cam_lock^ ? "Camera follows the player  (L)" : "Camera free - drag to pan  (L)") {
      view.cam_lock^ = !view.cam_lock^
    }
    imgui.SameLine(0, px(6))

    if gui_icon_button("nowalk", ICON_BLOCKED, f.nowalk_on, f.nowalk_on ? "No-walk overlay: ON  (N)" : "Show terrain you cannot walk through  (N)") {
      panel_enqueue(ps, f.nowalk_on ? "nowalk off" : "nowalk on")
    }
    imgui.SameLine(0, px(6))

    if gui_icon_button("mute", f.sfx_on ? ICON_VOLUME_UP : ICON_VOLUME_OFF, f.sfx_on, f.sfx_on ? "Sound: on  (chime on penya, zap on kill)" : "Sound: muted") {
      panel_enqueue(ps, f.sfx_on ? "sfx off" : "sfx on")
    }
  }
  imgui.End()
  imgui.PopStyleVar(1)
}

// ===========================================================================
// Recenter puck (bottom-right, over the map)
// ===========================================================================

// The map convention: while the camera follows the player there is nothing to recenter, so the control
// is not there at all. Pan away (which implies unlocking the camera) and it appears in the corner
// furthest from the toolbar and the gauges, where a thumb - or a mouse that just finished dragging -
// already is. C does the same thing from the keyboard.
@(private = "file")
gui_recenter_fab :: proc(view: Gui_View) {
  if view.cam_lock^ {
    return
  }
  vp := imgui.GetMainViewport()
  imgui.SetNextWindowPos(
    {vp.Pos.x + vp.Size.x - px(TOOLBAR_PAD), vp.Pos.y + vp.Size.y - px(TOOLBAR_PAD)},
    .Always,
    {1, 1}, // pivot: bottom-right corner of the window onto the bottom-right corner of the viewport
  )
  imgui.PushStyleVarImVec2(.WindowPadding, {0, 0})
  imgui.PushStyleVar(.WindowBorderSize, 0)
  imgui.PushStyleColorImVec4(.WindowBg, {0, 0, 0, 0}) // the puck IS the window - no panel behind it
  if imgui.Begin("##recenter", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoSavedSettings, .AlwaysAutoResize, .NoNavInputs, .NoDocking}) {
    if gui_icon_button("rc", ICON_LOCATION, false, "Recenter on the player  (C)", side_px = FAB_BTN) {
      view.recenter^ = true
    }
  }
  imgui.End()
  imgui.PopStyleColor(1)
  imgui.PopStyleVar(2)
}

// The fence editor's four draw tools, in the order their number keys run (1..4).
Gui_Fence_Tool :: struct {
  label: cstring,
  tool:  Radar_Tool,
  key:   cstring,
}

@(rodata)
FENCE_TOOLS := [4]Gui_Fence_Tool {
  {"Circle", .Circle, "1"},
  {"Rect", .Rect, "2"},
  {"Poly", .Polygon, "3"},
  {"Erase", .Eraser, "4"},
}

Gui_Setup_State :: enum {
  Bad, // a required group is missing -> auto cannot run
  Warn, // required all pinned, something optional is not
  Ok, // everything, including the optional pins
}

@(private = "file")
gui_setup_state :: proc(f: ^Gui_Frame) -> (Gui_Setup_State, cstring) {
  missing_req, missing_opt := 0, 0
  first_req, first_opt := "", ""
  for g in f.groups {
    if g.ok {
      continue
    }
    if g.required {
      missing_req += 1
      if first_req == "" {first_req = g.label}
    } else {
      missing_opt += 1
      if first_opt == "" {first_opt = g.label}
    }
  }
  for g in f.opins {
    if !g.ok {
      missing_opt += 1
      if first_opt == "" {first_opt = g.label}
    }
  }
  switch {
  case missing_req > 0:
    return .Bad, fmt.ctprintf("NOT READY - %d required missing (%s). Click to set up.", missing_req, first_req)
  case missing_opt > 0:
    return .Warn, fmt.ctprintf("Ready to farm - %d optional missing (%s). Click for details.", missing_opt, first_opt)
  case:
    return .Ok, "Fully set up. Click to review."
  }
}

// ===========================================================================
// Gauges (bottom-left, over the map)
// ===========================================================================

@(private = "file")
gui_gauges :: proc(f: ^Gui_Frame) {
  if !f.penya_show && !f.inv_have {
    return
  }
  vp := imgui.GetMainViewport()
  imgui.SetNextWindowPos({vp.Pos.x + TOOLBAR_PAD, vp.Pos.y + vp.Size.y - TOOLBAR_PAD}, .Always, {0, 1})
  imgui.PushStyleVarImVec2(.WindowPadding, {px(10), px(9)})
  if imgui.Begin("##gauges", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoSavedSettings, .AlwaysAutoResize, .NoNavInputs, .NoDocking, .NoMouseInputs}) {
    if f.penya_show {
      // Fill is LINEAR over 0 .. max(i32). The cap is the only ceiling penya actually has, and the bar
      // should read as "how close am I to losing money to overflow" - so a normal balance being a sliver
      // is the honest answer, not a bug. (A log scale was tried and lied: it showed a fifth of a bar for
      // a few million, which reads as "a fifth of the way to the cap" when it is nowhere near.)
      pulse := f32(0)
      col := imgui.Vec4{1.0, 0.816, 0.251, 1.0}
      if f.penya_cur >= PENYA_WARN {
        pulse = f32(0.5 + 0.5 * math.sin(rl.GetTime() * 9.0))
        col = COL_BAD
      }
      frac := f32(f64(clamp(f.penya_cur, 0, PENYA_CAP)) / f64(PENYA_CAP))
      gui_gauge(ICON_PENYA, frac, fmt.ctprintf("%s", commafy(f.penya_cur)), col, pulse)
    }
    if f.inv_have {
      pulse := f32(0)
      col := COL_ACCENT
      if f.inv_used >= f.inv_cap && f.inv_cap > 0 {
        pulse = f32(0.5 + 0.5 * math.sin(rl.GetTime() * 8.0))
        col = imgui.Vec4{0.941, 0.471, 0.118, 1.0}
      }
      frac := f.inv_cap > 0 ? f32(f.inv_used) / f32(f.inv_cap) : 0
      gui_gauge(ICON_INVENTORY, frac, fmt.ctprintf("%d / %d", f.inv_used, f.inv_cap), col, pulse)
    }
  }
  imgui.End()
  imgui.PopStyleVar(1)
}

// ===========================================================================
// Fence edit menu (top-left, under the toolbar; edit mode only)
// ===========================================================================

@(private = "file")
gui_fence_menu :: proc(ps: ^Panel_State, f: ^Gui_Frame, view: Gui_View) {
  vp := imgui.GetMainViewport()
  imgui.SetNextWindowPos({vp.Pos.x + TOOLBAR_PAD, vp.Pos.y + TOOLBAR_PAD + ICON_BTN + 26}, .Always)
  imgui.PushStyleVarImVec2(.WindowPadding, {px(10), px(10)})
  if imgui.Begin("##fence", nil, {.NoTitleBar, .NoResize, .NoMove, .NoScrollbar, .NoSavedSettings, .AlwaysAutoResize, .NoNavInputs, .NoDocking}) {
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextUnformatted(fmt.ctprintf("FENCE  %d shape%s", f.fence_shapes, f.fence_shapes == 1 ? "" : "s"))
    imgui.PopStyleColor(1)

    for t, i in FENCE_TOOLS {
      if i > 0 {
        imgui.SameLine(0, px(4))
      }
      on := view.tool^ == t.tool
      if on {
        imgui.PushStyleColorImVec4(.Button, tint(COL_ACCENT, 0.28))
        imgui.PushStyleColorImVec4(.Text, COL_ACCENT)
      } else {
        imgui.PushStyleColorImVec4(.Button, tint(COL_TRACK, 0.85))
        imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
      }
      if imgui.Button(t.label) {
        view.tool^ = t.tool
      }
      imgui.PopStyleColor(2)
      if imgui.IsItemHovered() {
        imgui.SetTooltip("%s", fmt.ctprintf("%s tool  (%s)", t.label, t.key))
      }
    }

    // tag cycles include(+) -> exclude(-) -> avoid(!)
    tag_label: cstring = view.tag^ == 0 ? "+ include" : (view.tag^ == 1 ? "- exclude" : "! avoid")
    tag_col := view.tag^ == 0 ? COL_OK : (view.tag^ == 1 ? imgui.Vec4{0.906, 0.494, 0.133, 1} : imgui.Vec4{0.878, 0.157, 0.376, 1})
    imgui.PushStyleColorImVec4(.Text, tag_col)
    if imgui.Button(tag_label, {px(110), 0}) {
      view.tag^ = (view.tag^ + 1) % 3
    }
    imgui.PopStyleColor(1)
    if imgui.IsItemHovered() {
      imgui.SetTooltip("What the next shape does  (Tab)")
    }
    imgui.SameLine(0, px(6))
    if imgui.Button(f.fence_active ? "On" : "Off", {px(56), 0}) {
      panel_enqueue(ps, f.fence_active ? "fence off" : "fence on")
    }
    if imgui.IsItemHovered() {
      imgui.SetTooltip("Enforce the fence when picking targets  (A)")
    }
    imgui.SameLine(0, px(6))
    if imgui.Button("Undo", {px(66), 0}) {
      panel_enqueue(ps, "fence undo")
    }
    imgui.SameLine(0, px(6))
    if imgui.Button("Clear", {px(68), 0}) {
      panel_enqueue(ps, "fence clear")
    }

    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextUnformatted("drag to draw   Enter closes a poly")
    imgui.PopStyleColor(1)
  }
  imgui.End()
  imgui.PopStyleVar(1)
}

// ===========================================================================
// Attach dialog (the only thing on screen while detached)
// ===========================================================================

@(private = "file")
gui_attach_dialog :: proc(ps: ^Panel_State, f: ^Gui_Frame) {
  if !ps.attach_seeded {
    // "neuz" by default because that IS the target; clearing the box lists everything.
    panel_buf_set(ps.attach_filter[:], "neuz")
    ps.attach_seeded = true
    ps.attach_scan_at = -1
  }

  filter := panel_buf_str(ps.attach_filter[:])
  // Re-scan on any filter change, and otherwise once a second so a freshly-launched client shows up.
  if filter != ps.attach_scanned || rl.GetTime() >= ps.attach_scan_at + 1.0 {
    gui_scan_processes(ps, filter)
  }

  if gui_begin_dialog("Attach to a process", 520, 420) {
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextUnformatted("memscan is not attached. Pick the game client to control.")
    imgui.PopStyleColor(1)
    imgui.Dummy({0, 4})

    imgui.SetNextItemWidth(-1)
    imgui.InputTextWithHint(
      "##filter",
      "search by process name or window title",
      cstring(raw_data(ps.attach_filter[:])),
      len(ps.attach_filter),
    )
    imgui.Dummy({0, 2})

    if imgui.BeginChild("##procs", {0, -px(36)}, {.Borders}) {
      if len(ps.attach_rows) == 0 {
        imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
        imgui.TextUnformatted(filter == "" ? "no processes found" : fmt.ctprintf("nothing matches '%s'", filter))
        imgui.PopStyleColor(1)
      }
      for row, i in ps.attach_rows {
        imgui.PushID(fmt.ctprintf("p%d", i))
        // One tile per process: the name is what you searched for, the window title is what tells two
        // Neuz clients apart (it carries the character name). The Selectable itself is unlabelled - it
        // is the hit box; both lines of text are drawn into its rect below.
        if imgui.Selectable("##sel", false, {}, {0, px(38)}) {
          // Routed through the deferred queue like every other action, so the attach runs on the REPL
          // thread under exec_mutex - exactly as if it had been typed.
          panel_enqueue(ps, fmt.tprintf("attach %d", row.pid))
        }
        rmin := imgui.GetItemRectMin()
        dl := imgui.GetWindowDrawList()
        imgui.DrawList_AddText(dl, {rmin.x + px(8), rmin.y + px(3)}, u32_of(COL_TEXT), fmt.ctprintf("%s", row.name))
        imgui.DrawList_AddText(
          dl,
          {rmin.x + px(8), rmin.y + px(3) + imgui.GetTextLineHeight()},
          u32_of(COL_TEXT_DIM),
          fmt.ctprintf("pid %d   %s", row.pid, row.title == "" ? "(no window)" : row.title),
        )
        imgui.PopID()
      }
    }
    imgui.EndChild()

    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextUnformatted("Flyff automation needs the 32-bit Neuz.exe.")
    imgui.PopStyleColor(1)
  }
  imgui.End()
}

@(private = "file")
gui_scan_processes :: proc(ps: ^Panel_State, filter: string) {
  gui_free_proc_rows(ps)
  // Both strings are cloned: find_process_id_by_name's window_title always comes back TEMP-allocated
  // (it defaults that allocator internally), and these rows must survive the frame's free_all.
  for r in engine.find_process_id_by_name(filter, context.temp_allocator) {
    append(&ps.attach_rows, Gui_Proc_Row{pid = r.process_id, name = strings.clone(r.process_name), title = strings.clone(r.window_title)})
  }
  delete(ps.attach_scanned)
  ps.attach_scanned = strings.clone(filter)
  ps.attach_scan_at = rl.GetTime()
}

@(private = "file")
gui_free_proc_rows :: proc(ps: ^Panel_State) {
  for r in ps.attach_rows {
    delete(r.name)
    delete(r.title)
  }
  clear(&ps.attach_rows)
}

// ===========================================================================
// Setup dialog
// ===========================================================================

@(private = "file")
gui_setup_dialog :: proc(session: ^Session, ps: ^Panel_State, f: ^Gui_Frame) {
  if gui_begin_dialog("Setup", 520, 560, &ps.setup_open) {
    // who we're attached to + the way back out
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextUnformatted(fmt.ctprintf("%s  -  pid %d  -  %d-bit", f.proc_name == "" ? "(process)" : f.proc_name, f.pid, f.ptr_size * 8))
    imgui.PopStyleColor(1)
    imgui.SameLine(0, px(10))
    if imgui.Button("Detach", {px(80), 0}) {
      panel_enqueue(ps, "detach")
      ps.setup_open = false
    }
    if f.ptr_size != 4 {
      imgui.PushStyleColorImVec4(.Text, COL_BAD)
      imgui.TextUnformatted("This is not the 32-bit Neuz.exe - Flyff automation will not run.")
      imgui.PopStyleColor(1)
    }
    imgui.Separator()

    // --- the pipeline
    imgui.TextUnformatted("Stand in a field, on the ground, with a few distinct monsters on screen.")
    imgui.Dummy({0, 2})

    imgui.SetNextItemWidth(px(220))
    imgui.InputTextWithHint("Character name", "your character's name", cstring(raw_data(ps.setup_name[:])), len(ps.setup_name))
    imgui.SetNextItemWidth(px(220))
    imgui.InputTextWithHint("Current HP (optional)", "e.g. 1234", cstring(raw_data(ps.setup_hp[:])), len(ps.setup_hp), {.CharsDecimal})
    imgui.SetNextItemWidth(px(220))
    imgui.InputTextWithHint("Current penya (optional)", "e.g. 1240500", cstring(raw_data(ps.setup_penya[:])), len(ps.setup_penya), {.CharsDecimal})

    imgui.Dummy({0, 4})
    name := strings.trim_space(panel_buf_str(ps.setup_name[:]))
    hp := strings.trim_space(panel_buf_str(ps.setup_hp[:]))
    penya := strings.trim_space(panel_buf_str(ps.setup_penya[:]))

    if f.setup_running {
      step_lbl := f.setup_step >= 1 && f.setup_step <= len(SETUP_STEP_LABELS) ? SETUP_STEP_LABELS[f.setup_step - 1] : "starting..."
      imgui.PushStyleColorImVec4(.Text, COL_ACCENT)
      imgui.TextUnformatted(fmt.ctprintf("Running... step %d/9  -  %s", f.setup_step, step_lbl))
      imgui.PopStyleColor(1)
    } else {
      can_run := name != "" && f.ptr_size == 4
      if !can_run {
        imgui.BeginDisabled()
      }
      if imgui.Button("Run setup", {px(130), 0}) {
        cmds := make([dynamic]string, context.temp_allocator)
        append(&cmds, hp == "" ? fmt.tprintf("setup '%s'", name) : fmt.tprintf("setup '%s' %s", name, hp))
        if penya != "" {
          append(&cmds, fmt.tprintf("findpenya %s", penya))
        }
        // Async, not the per-frame drain: the pipeline is a multi-second run and the window has to keep
        // drawing (cli_setup yields exec_mutex between steps precisely so this stays live).
        panel_run_async(session, cmds[:])
      }
      if !can_run {
        imgui.EndDisabled()
      }
      if penya != "" {
        imgui.SameLine(0, px(8))
        if imgui.Button("Find penya only", {px(150), 0}) {
          panel_enqueue(ps, fmt.tprintf("findpenya %s", penya))
        }
      }
      if name == "" {
        imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
        imgui.TextUnformatted("Enter your character name to enable Run setup.")
        imgui.PopStyleColor(1)
      }
    }

    imgui.Dummy({0, 4})
    imgui.Separator()

    // --- attack_range. The one tunable that belongs in a SETUP dialog rather than an options panel:
    // it is your character's physical reach, so it is calibration, not preference - and it is
    // double-duty (the picker's engage range AND the sweep brush width), which is why getting it wrong
    // silently spreads targeting. The green ring on the map is the live readout while you drag.
    imgui.SeparatorText("Your reach")
    if !ps.ar_active { // re-seed whenever the user is not dragging: reflects an external `set attack_range`
      ps.ar_slider = f.attack_range
    }
    imgui.SetNextItemWidth(px(220))
    imgui.SliderFloat("attack_range", &ps.ar_slider, 0, 30, "%.2f")
    ps.ar_active = imgui.IsItemActive()
    // Commit ONLY on release. The slider quantizes to pixels, so a value written every frame creeps
    // upward every time the dialog is opened - that silent drift is what once bloated attack_range to
    // ~17 and spread the auto-picker's engage range.
    if imgui.IsItemDeactivatedAfterEdit() {
      panel_enqueue(ps, fmt.tprintf("set attack_range %.3f", ps.ar_slider))
    }
    imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
    imgui.TextUnformatted("Melee is roughly 1.5-2. The green circle on the map is this radius.")
    imgui.PopStyleColor(1)

    imgui.Dummy({0, 4})
    imgui.Separator()

    // --- the checklist that used to live in the sidebar. Same data `status` prints.
    if imgui.BeginChild("##checklist", {0, 0}, {}) {
      imgui.SeparatorText("Required + recommended")
      for g in f.groups {
        gui_check_row(g)
      }
      imgui.Dummy({0, 4})
      imgui.SeparatorText("Optional pins (own finder each)")
      for g in f.opins {
        gui_check_row(g)
      }
    }
    imgui.EndChild()
  }
  imgui.End()
}

// ===========================================================================
// Buffer helpers (shared by both dialogs)
// ===========================================================================

// Write <s> into a NUL-terminated widget byte buffer, tail-zeroed.
panel_buf_set :: proc(buf: []u8, s: string) {
  n := min(len(s), len(buf) - 1)
  copy(buf, s[:n])
  for i in n ..< len(buf) {
    buf[i] = 0
  }
}

// Read a NUL-terminated widget buffer back out as a string (borrowed, not owned).
panel_buf_str :: proc(buf: []u8) -> string {
  for b, i in buf {
    if b == 0 {
      return string(buf[:i])
    }
  }
  return string(buf[:])
}

// Free everything Panel_State owns. Called on radar window close.
panel_state_free :: proc(ps: ^Panel_State) {
  for c in ps.pending {
    delete(c)
  }
  delete(ps.pending)
  gui_free_proc_rows(ps)
  delete(ps.attach_rows)
  delete(ps.attach_scanned)
  gui_free_bhv_rows(ps)
  delete(ps.browser_rows)
  delete(ps.rename_from)
  delete(ps.dup_from)
  gui_editor_free(&ps.ed)
}

// Format an integer with thousands separators (e.g. 1240 -> "1,240"), temp-allocated.
commafy :: proc(n: i64) -> string {
  s := fmt.tprintf("%d", n)
  neg := len(s) > 0 && s[0] == '-'
  if neg {
    s = s[1:]
  }
  b := strings.builder_make(context.temp_allocator)
  if neg {
    strings.write_byte(&b, '-')
  }
  L := len(s)
  for i in 0 ..< L {
    if i > 0 && (L - i) % 3 == 0 {
      strings.write_byte(&b, ',')
    }
    strings.write_byte(&b, s[i])
  }
  return strings.to_string(b)
}
