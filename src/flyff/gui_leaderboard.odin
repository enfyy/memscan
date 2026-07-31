package flyff

import "core:fmt"
import "core:math"
import "core:strings"
import rl "vendor:raylib"

import imgui "../../lib/odin-imgui"

// ===========================================================================
// The leaderboards surface: a run recorder and the board it submits to.
//
// Same contract as the rest of the UI (see the header of gui.odin) - this runs in cli_radar's
// exec_mutex-UNLOCKED draw phase, so it reads the Gui_Frame snapshot and issues every action as a CLI
// command through panel_enqueue. There is not one thing in this dialog you could not type: Start/Stop are
// `leaderboard start|stop`, the sort tabs and Refresh are `leaderboard refresh <key>`, Submit is
// `leaderboard submit <name>` and a row's download button is `leaderboard getcfg <id>`.
//
// The whole feature is gated on `leaderboard_url` being set: with no backend the toolbar trophy is not
// drawn at all (gui_toolbar), which is why nothing in here has to handle an unconfigured backend beyond
// naming it in the footer.
//
// Sorting is penya / kills / kpm and nothing else - what a farm run IS, is how much you made, how much
// you killed, and how fast. The rows still CARRY peak-density and species (they are recorded and
// submitted), they are just not columns you can rank by. See LB_SORTS in leaderboard.odin.
// ===========================================================================

LB_DIALOG_W :: f32(700)
LB_DIALOG_H :: f32(720)

LB_ROW_PAD :: f32(11) // inside padding of a board row, all four sides
LB_ROW_GUTTER :: f32(46) // the rank-medal column, between the left padding and the text column
LB_ROW_LINE_GAP :: f32(4) // between a row's two text lines
LB_MEDAL_R :: f32(14) // rank medal radius
LB_DOWNLOAD_BTN :: f32(28) // the per-row "download this setup" button
LB_BAR_H :: f32(10) // the minimum-run progress bar

// The podium. Only the top three get a coloured medal; from 4th down the rank sits in the same circle
// drawn in the surface's own track colour, so the list reads as one shape with three highlights rather
// than as a gradient nobody can rank by eye.
LB_GOLD :: imgui.Vec4{0.851, 0.718, 0.302, 1.0}
LB_SILVER :: imgui.Vec4{0.722, 0.753, 0.804, 1.0}
LB_BRONZE :: imgui.Vec4{0.722, 0.502, 0.318, 1.0}
LB_RECORD :: imgui.Vec4{0.898, 0.365, 0.400, 1.0} // the recording dot - a record light, not an error

// ===========================================================================
// The toolbar trophy's state
// ===========================================================================

// Colour + tooltip for the toolbar button, which doubles as the recording light. Three states, because
// there are exactly three things the feature can be doing to you:
//
//   recording  - red, and the tooltip carries the live numbers, so "is it counting, and how is it going"
//                is answered by hovering rather than by opening anything.
//   submittable - green: a finished span that is long enough and has not been sent yet. This is the state
//                that used to be invisible, and the one where forgetting costs you the run.
//   idle       - dim, just a way in.
gui_leaderboard_button_state :: proc(f: ^Gui_Frame) -> (imgui.Vec4, cstring) {
  if f.leaderboard_recording {
    return LB_RECORD, fmt.ctprintf(
      "Recording %s  -  %d kills  -  %s penya  -  %.1f kpm\nClick for the board.",
      fmt_elapsed(i64(f.leaderboard_elapsed_sec) * 1_000_000_000),
      f.leaderboard_kills,
      commafy(f.leaderboard_penya),
      f.leaderboard_kpm,
    )
  }
  if f.leaderboard_has_run && !f.leaderboard_submitted && f.leaderboard_elapsed_sec >= LB_MIN_SEC {
    return COL_OK, fmt.ctprintf(
      "Run finished and READY to submit: %s, %d kills, %s penya.\nClick to put it on the board.",
      fmt_elapsed(i64(f.leaderboard_elapsed_sec) * 1_000_000_000),
      f.leaderboard_kills,
      commafy(f.leaderboard_penya),
    )
  }
  return COL_ACCENT, "Leaderboards - record a timed farm run and rank it"
}

// ===========================================================================
// The dialog
// ===========================================================================

gui_leaderboard_dialog :: proc(ps: ^Panel_State, f: ^Gui_Frame) {
  // One-shot on open: adopt whatever sort the board already holds, seed the submit name from the
  // character (never over what was typed before), and fetch, so the dialog is never empty on arrival.
  if !ps.leaderboard_seeded {
    ps.leaderboard_seeded = true
    ps.leaderboard_sort = clamp(f.leaderboard_sort, 0, len(LB_SORTS) - 1)
    if panel_buf_str(ps.leaderboard_name[:]) == "" && f.player_name != "" {
      panel_buf_set(ps.leaderboard_name[:], f.player_name)
    }
    if !f.leaderboard_busy {
      panel_enqueue(ps, fmt.tprintf("leaderboard refresh %s", LB_SORTS[ps.leaderboard_sort]))
    }
  }

  if !gui_begin_dialog("Leaderboards", LB_DIALOG_W, LB_DIALOG_H, &ps.leaderboard_open) {
    imgui.End()
    return
  }
  defer imgui.End()

  gui_leaderboard_recorder(ps, f)
  imgui.Dummy({0, px(4)})
  gui_leaderboard_sort_row(ps, f)
  imgui.Dummy({0, px(2)})
  gui_leaderboard_board(ps, f)
  gui_leaderboard_footer(f)
}

// ===========================================================================
// The recorder card
// ===========================================================================

// Your own run, at the top, in one bordered card. AutoResizeY rather than a fixed height: the font is
// rasterized at ui_scale and everything in here is text, so a constant would clip at the large end.
@(private = "file")
gui_leaderboard_recorder :: proc(ps: ^Panel_State, f: ^Gui_Frame) {
  if !imgui.BeginChild("##lbrec", {0, 0}, {.Borders, .AutoResizeY}) {
    imgui.EndChild()
    return
  }
  defer imgui.EndChild()

  // --- state line: a record dot, the state word, the clock, and the Start/Stop button on the right.
  dl := imgui.GetWindowDrawList()
  line_h := imgui.GetTextLineHeight()
  dot := imgui.GetCursorScreenPos()
  imgui.Dummy({px(16), line_h})
  if f.leaderboard_recording {
    // Pulsing, like the gauges' alarm state: a still red dot reads as a status colour, a breathing one
    // reads as "this is running right now".
    pulse := f32(0.55 + 0.45 * math.sin(rl.GetTime() * 3.2))
    imgui.DrawList_AddCircleFilled(dl, {dot.x + px(6), dot.y + line_h * 0.5}, px(5), u32_of(tint(LB_RECORD, pulse)))
  } else {
    imgui.DrawList_AddCircleFilled(dl, {dot.x + px(6), dot.y + line_h * 0.5}, px(4), u32_of(tint(COL_TEXT_DIM, 0.6)))
  }
  imgui.SameLine(0, px(4))

  state: cstring = f.leaderboard_recording ? "RECORDING" : (f.leaderboard_has_run ? "STOPPED" : "IDLE")
  imgui.PushStyleColorImVec4(.Text, f.leaderboard_recording ? LB_RECORD : COL_TEXT_DIM)
  imgui.TextUnformatted(state)
  imgui.PopStyleColor(1)
  imgui.SameLine(0, px(12))
  imgui.TextUnformatted(fmt.ctprintf("%s", fmt_elapsed(i64(f.leaderboard_elapsed_sec) * 1_000_000_000)))

  // Start / Stop, right-aligned on the same line so the card's heading and its one verb read together.
  start_label: cstring = f.leaderboard_recording ? "Stop recording" : "Start recording"
  start_w := gui_text_button_w(start_label, 16)
  imgui.SameLine(0, 0)
  imgui.SetCursorPosX(imgui.GetCursorPosX() + max(0, imgui.GetContentRegionAvail().x - start_w))
  if gui_text_button(
    "lbrec",
    start_label,
    26,
    16,
    f.leaderboard_recording,
    f.leaderboard_recording ? "Freeze the span - the numbers stay for submitting  ('leaderboard stop')" : "Begin a timed run: kills, penya, peak density and species accrue from now  ('leaderboard start')",
    f.leaderboard_recording ? LB_RECORD : COL_OK,
  ) {
    panel_enqueue(ps, f.leaderboard_recording ? "leaderboard stop" : "leaderboard start")
  }

  // --- the numbers. The three rankable ones first and bright, the two that are only ever context dim
  // underneath - the same split the board rows use, so the card reads as "your row, not yet submitted".
  imgui.TextUnformatted(
    fmt.ctprintf(
      "%s penya      %d kills      %.1f kpm",
      commafy(f.leaderboard_penya),
      f.leaderboard_kills,
      f.leaderboard_kpm,
    ),
  )
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted(
    fmt.ctprintf("peak-density %d  -  %d species", f.leaderboard_peak_density, f.leaderboard_species),
  )
  imgui.PopStyleColor(1)

  // --- the 5-minute gate, as a bar. It used to be a sentence you had to read; a run that is not yet
  // long enough to submit is the single most common state this dialog is opened in.
  gui_leaderboard_min_bar(f)

  // --- submit: the name it goes on the board under, then the button, then WHY it is disabled.
  imgui.SetNextItemWidth(px(220))
  imgui.InputTextWithHint(
    "##lbname",
    "name for the board",
    cstring(raw_data(ps.leaderboard_name[:])),
    len(ps.leaderboard_name),
  )
  name := strings.trim_space(panel_buf_str(ps.leaderboard_name[:]))
  blocker := gui_leaderboard_submit_blocker(f, name)
  imgui.SameLine(0, px(8))
  if blocker != "" {
    imgui.BeginDisabled()
  }
  if gui_text_button("lbsubmit", "Submit run", 26, 18, true, "Sign and POST this run, with your farming setup attached  ('leaderboard submit <name>')") {
    panel_enqueue(ps, fmt.tprintf("leaderboard submit %s", name))
  }
  if blocker != "" {
    imgui.EndDisabled()
  }
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted(blocker != "" ? blocker : "Uploads your farming setup too (behaviour keys only - never your memory offsets).")
  imgui.PopStyleColor(1)
}

// A slab bar filled elapsed/LB_MIN_SEC, with the remaining time - or READY - written inside it. Same
// hand-drawn construction as gui_gauge, and for the same reason: the label has to stay legible over both
// the filled and the empty half.
@(private = "file")
gui_leaderboard_min_bar :: proc(f: ^Gui_Frame) {
  dl := imgui.GetWindowDrawList()
  w := imgui.GetContentRegionAvail().x
  h := px(LB_BAR_H)
  p := imgui.GetCursorScreenPos()
  imgui.Dummy({w, h})

  ready := f.leaderboard_elapsed_sec >= LB_MIN_SEC
  fraction := clamp(f32(f.leaderboard_elapsed_sec) / f32(LB_MIN_SEC), 0, 1)
  fill := ready ? COL_OK : COL_ACCENT
  r := px(4)
  imgui.DrawList_AddRectFilled(dl, p, {p.x + w, p.y + h}, u32_of(COL_TRACK), r)
  if fraction > 0 {
    imgui.DrawList_AddRectFilled(dl, p, {p.x + max(fraction * w, px(6)), p.y + h}, u32_of(tint(fill, 0.85)), r)
  }
  imgui.DrawList_AddRect(dl, p, {p.x + w, p.y + h}, u32_of(tint(COL_BORDER, 0.9)), r)

  remaining := LB_MIN_SEC - f.leaderboard_elapsed_sec
  imgui.PushStyleColorImVec4(.Text, ready ? COL_OK : COL_TEXT_DIM)
  imgui.TextUnformatted(
    ready \
    ? fmt.ctprintf("long enough to submit (minimum %d min)", LB_MIN_SEC / 60) \
    : fmt.ctprintf("%d:%02d more recording before this run can be submitted", remaining / 60, remaining % 60),
  )
  imgui.PopStyleColor(1)
}

// Why Submit is disabled, or "" when it is not. The same ladder the CLI walks in lb_cli_submit, in the
// same order - a disabled button that will not say what it wants is the worst version of this control.
@(private = "file")
gui_leaderboard_submit_blocker :: proc(f: ^Gui_Frame, name: string) -> cstring {
  switch {
  case !f.leaderboard_has_run:
    return "Start a recording first - there is no run to submit."
  case f.leaderboard_submitted:
    return "This run is already on the board. Start a new one to submit again."
  case f.leaderboard_busy:
    return "A request is still in flight - wait for it."
  case name == "":
    return "Type the name this run should appear under."
  case f.leaderboard_elapsed_sec < LB_MIN_SEC:
    return fmt.ctprintf("Too short - %d:%02d more recording needed.", (LB_MIN_SEC - f.leaderboard_elapsed_sec) / 60, (LB_MIN_SEC - f.leaderboard_elapsed_sec) % 60)
  }
  return ""
}

// ===========================================================================
// Sort tabs
// ===========================================================================

// Three tabs and a refresh, driven straight off LB_SORTS / LB_SORT_LABELS so the lit tab and the fetched
// board share one index space. Picking a tab REFETCHES rather than re-sorting locally: the server ranks
// the whole table and hands back the top of it, so a client-side sort of the page you happen to be
// holding would silently show you the wrong hundred rows.
@(private = "file")
gui_leaderboard_sort_row :: proc(ps: ^Panel_State, f: ^Gui_Frame) {
  if f.leaderboard_busy {
    imgui.BeginDisabled()
  }
  for label, i in LB_SORT_LABELS {
    if i > 0 {
      imgui.SameLine(0, px(6))
    }
    if gui_text_button(
      fmt.ctprintf("lbsort%d", i),
      label,
      28,
      18,
      ps.leaderboard_sort == i,
      fmt.ctprintf("Rank the board by %s", LB_SORTS[i]),
    ) {
      ps.leaderboard_sort = i
      panel_enqueue(ps, fmt.tprintf("leaderboard refresh %s", LB_SORTS[i]))
    }
  }
  imgui.SameLine(0, 0)
  imgui.SetCursorPosX(imgui.GetCursorPosX() + max(0, imgui.GetContentRegionAvail().x - px(ICON_BTN)))
  if gui_icon_button("lbrefresh", ICON_REFRESH, false, "Fetch the board again", nil, 28) {
    panel_enqueue(ps, fmt.tprintf("leaderboard refresh %s", LB_SORTS[clamp(ps.leaderboard_sort, 0, len(LB_SORTS) - 1)]))
  }
  if f.leaderboard_busy {
    imgui.EndDisabled()
  }
}

// ===========================================================================
// The board
// ===========================================================================

// A row's height: two lines of text plus the padding, measured rather than constant (same reasoning as
// gui_bhv_tile_h - the font is baked at ui_scale).
@(private = "file")
gui_leaderboard_row_h :: proc() -> f32 {
  return px(LB_ROW_PAD) * 2 + imgui.GetTextLineHeight() * 2 + px(LB_ROW_LINE_GAP)
}

@(private = "file")
gui_leaderboard_board :: proc(ps: ^Panel_State, f: ^Gui_Frame) {
  footer := imgui.GetTextLineHeightWithSpacing()
  if imgui.BeginChild("##lbboard", {0, -footer}, {}) {
    if len(f.leaderboard_rows) == 0 {
      imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
      imgui.TextUnformatted(
        f.leaderboard_busy \
        ? "loading..." \
        : "No entries yet - record a run of at least 5 minutes and be the first one on it.",
      )
      imgui.PopStyleColor(1)
    }
    // The name in the submit box is what marks a row as yours. It is the only identity the board has -
    // entries carry no account - so it is also exactly the right one.
    mine := strings.trim_space(panel_buf_str(ps.leaderboard_name[:]))
    for i in 0 ..< len(f.leaderboard_rows) {
      row := &f.leaderboard_rows[i]
      gui_leaderboard_row(ps, f, row, i + 1, mine != "" && panel_buf_str(row.name[:]) == mine)
    }
  }
  imgui.EndChild()
}

// One entry. Drawn the same way the behaviour tiles are - an unlabelled Button for the frame and hit box,
// with everything painted over it - because ImGui's own layout cannot right-align a metric on the first
// of two lines, and that alignment is the whole readability of a ranked list.
//
//   pad | medal | name .................................. <sorted metric> | pad | [dl]
//   pad |       | the other two metrics, duration - density - species     | pad |
@(private = "file")
gui_leaderboard_row :: proc(ps: ^Panel_State, f: ^Gui_Frame, r: ^Lb_Row, rank: int, mine: bool) {
  imgui.PushID(fmt.ctprintf("lb%d", r.id))
  defer imgui.PopID()

  row_h := gui_leaderboard_row_h()
  gap := px(8)
  btn := px(LB_DOWNLOAD_BTN)
  row_w := imgui.GetContentRegionAvail().x - btn - gap

  if mine {
    imgui.PushStyleColorImVec4(.Button, blend(COL_TRACK, COL_ACCENT, 0.14, 0.92))
    imgui.PushStyleColorImVec4(.ButtonHovered, blend(COL_TRACK, COL_ACCENT, 0.24, 0.96))
    imgui.PushStyleColorImVec4(.ButtonActive, blend(COL_TRACK, COL_ACCENT, 0.34, 1.0))
    imgui.PushStyleColorImVec4(.Border, tint(COL_ACCENT, 0.7))
  } else {
    imgui.PushStyleColorImVec4(.Button, tint(COL_TRACK, 0.85))
    imgui.PushStyleColorImVec4(.ButtonHovered, {0.184, 0.239, 0.310, 1.0})
    imgui.PushStyleColorImVec4(.ButtonActive, {0.235, 0.310, 0.400, 1.0})
    imgui.PushStyleColorImVec4(.Border, COL_BORDER)
  }
  imgui.Button("##lbrow", {row_w, row_h})
  imgui.PopStyleColor(4)
  hovered := imgui.IsItemHovered()
  rmin := imgui.GetItemRectMin()
  rmax := imgui.GetItemRectMax()

  name := panel_buf_str(r.name[:])
  build := panel_buf_str(r.build[:])
  gui_leaderboard_row_body(rmin, rmax, r, rank, name, ps.leaderboard_sort)

  if hovered {
    imgui.SetTooltip(
      "%s",
      fmt.ctprintf(
        "%s\n\n%s penya   %d kills   %.1f kpm\n%s   peak-density %d   %d species\nbuild %s\n\nThe button on the right downloads this run's farming setup.",
        name,
        commafy(r.penya),
        r.kills,
        f64(r.kpm),
        fmt_elapsed(i64(r.dur_sec) * 1_000_000_000),
        r.max_density,
        r.monsters,
        build == "" ? "(unknown)" : build,
      ),
    )
  }

  // --- the download button, vertically centred against the row.
  //
  // The SetCursorPosY nudge is immediately followed by an item, which is the condition ImGui asks for: a
  // cursor move that no item validates is what asserts at EndChild (see the same note in
  // gui_behaviour.odin's tile Load button).
  imgui.SameLine(0, gap)
  imgui.SetCursorPosY(imgui.GetCursorPosY() + (row_h - btn) * 0.5)
  if f.leaderboard_busy {
    imgui.BeginDisabled()
  }
  if gui_icon_button(
    "lbget",
    ICON_DOWNLOAD,
    false,
    fmt.ctprintf("Download this setup as flyff_%d.cfg  ('leaderboard getcfg %d')", r.id, r.id),
    nil,
    LB_DOWNLOAD_BTN,
  ) {
    panel_enqueue(ps, fmt.tprintf("leaderboard getcfg %d", r.id))
  }
  if f.leaderboard_busy {
    imgui.EndDisabled()
  }
}

// THE only place a row's contents are positioned. The metric on the title line is whichever column the
// board is sorted by, and the other two drop to the second line - which is what makes the sort tabs feel
// like they did something rather than merely reordering the same wall of numbers.
@(private = "file")
gui_leaderboard_row_body :: proc(rmin, rmax: imgui.Vec2, r: ^Lb_Row, rank: int, name: string, sort: int) {
  dl := imgui.GetWindowDrawList()
  pad := px(LB_ROW_PAD)
  line_h := imgui.GetTextLineHeight()
  tx := rmin.x + pad + px(LB_ROW_GUTTER)
  y0 := rmin.y + pad
  y1 := y0 + line_h + px(LB_ROW_LINE_GAP)
  right := rmax.x - pad

  // --- medal
  medal, ink := gui_leaderboard_medal(rank)
  centre := imgui.Vec2{rmin.x + pad + px(LB_ROW_GUTTER) * 0.5, (rmin.y + rmax.y) * 0.5}
  imgui.DrawList_AddCircleFilled(dl, centre, px(LB_MEDAL_R), u32_of(medal))
  rank_text := fmt.ctprintf("%d", rank)
  rank_size := imgui.CalcTextSize(rank_text)
  imgui.DrawList_AddText(dl, {centre.x - rank_size.x * 0.5, centre.y - rank_size.y * 0.5}, u32_of(ink), rank_text)

  // --- title line: the name, with the ranked metric claiming its width on the right first
  primary, secondary := gui_leaderboard_metrics(r, sort)
  name_room := right - tx
  metric := fmt.ctprintf("%s", primary)
  metric_w := imgui.CalcTextSize(metric).x
  imgui.DrawList_AddText(dl, {right - metric_w, y0}, u32_of(rank <= 3 ? medal : COL_TEXT), metric)
  name_room -= metric_w + px(14)
  imgui.DrawList_AddText(dl, {tx, y0}, u32_of(COL_TEXT), gui_fit(name == "" ? "(unnamed)" : name, name_room))

  // --- second line: the two metrics that are not ranked, the duration, then the context tail
  imgui.DrawList_AddText(
    dl,
    {tx, y1},
    u32_of(tint(COL_TEXT_DIM, 0.95)),
    gui_fit(
      fmt.tprintf(
        "%s   %s   -   dens %d   -   %d species",
        secondary,
        fmt_elapsed(i64(r.dur_sec) * 1_000_000_000),
        r.max_density,
        r.monsters,
      ),
      right - tx,
    ),
  )
}

// The medal fill and the ink that reads on it. Ranks past third get the surface's own track colour, so
// the podium is three highlights rather than a gradient.
@(private = "file")
gui_leaderboard_medal :: proc(rank: int) -> (imgui.Vec4, imgui.Vec4) {
  dark := imgui.Vec4{0.055, 0.075, 0.102, 1.0} // reads on all three metals
  switch rank {
  case 1:
    return LB_GOLD, dark
  case 2:
    return LB_SILVER, dark
  case 3:
    return LB_BRONZE, dark
  }
  return tint(COL_TRACK, 0.9), COL_TEXT_DIM
}

// The row's ranked metric and the two that fall to the second line, split by the current sort. Temp
// allocated (fmt.tprintf), like everything else drawn this frame.
@(private = "file")
gui_leaderboard_metrics :: proc(r: ^Lb_Row, sort: int) -> (primary: string, secondary: string) {
  penya := fmt.tprintf("%s penya", commafy(r.penya))
  kills := fmt.tprintf("%d kills", r.kills)
  kpm := fmt.tprintf("%.1f kpm", f64(r.kpm))
  // sort is an index into LB_SORTS: 0 penya, 1 kills, 2 kpm.
  switch sort {
  case 1:
    return kills, fmt.tprintf("%s   %s", penya, kpm)
  case 2:
    return kpm, fmt.tprintf("%s   %s", penya, kills)
  }
  return penya, fmt.tprintf("%s   %s", kills, kpm)
}

// ===========================================================================
// Footer
// ===========================================================================

// The async worker's last word on the left, the backend it talked to on the right. lb_status_buf is the
// ONLY place a submit/fetch/getcfg result surfaces in the window - the worker's own printf goes to the
// console, which nobody driving this dialog is looking at.
@(private = "file")
gui_leaderboard_footer :: proc(f: ^Gui_Frame) {
  status := f.leaderboard_status
  if status != "" {
    bad := strings.has_prefix(status, "rejected") || strings.has_prefix(status, "network error") || strings.has_prefix(status, "bad server") || strings.has_prefix(status, "write failed")
    imgui.PushStyleColorImVec4(.Text, bad ? COL_BAD : COL_OK)
    imgui.TextUnformatted(fmt.ctprintf("%s", status))
    imgui.PopStyleColor(1)
    imgui.SameLine(0, px(12))
  }
  // Trimmed from the LEFT: a long URL's informative half is its tail (the host and port).
  url := f.leaderboard_url == "" ? "(no backend set)" : f.leaderboard_url
  fitted := gui_fit_right(url, imgui.GetContentRegionAvail().x)
  imgui.SetCursorPosX(imgui.GetCursorPosX() + max(0, imgui.GetContentRegionAvail().x - imgui.CalcTextSize(fitted).x))
  imgui.PushStyleColorImVec4(.Text, COL_TEXT_DIM)
  imgui.TextUnformatted(fitted)
  imgui.PopStyleColor(1)
}
