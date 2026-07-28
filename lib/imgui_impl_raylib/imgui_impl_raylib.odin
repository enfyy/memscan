package imgui_impl_raylib

// Dear ImGui platform + renderer backend for raylib, ported from the raylib-extras rlImGui
// (https://github.com/raylib-extras/rlImGui/blob/main/rlImGui.cpp).
//
// This file was in the repo once before (deleted at "Revival starts now. REPL instead of GUI"), against a
// locally vendored lib/raylib and a 2025-era odin-imgui. It is back, retargeted at Odin's own
// `vendor:raylib` (5.5) and odin-imgui 1.91.7. What changed vs. the original:
//   - ImTextureID is a u64 now, not a void*. We store raylib's GL texture id in it directly, so there is
//     no heap-allocated ^rl.Texture2D to keep alive (and no way to leak one).
//   - Clipboard hooks moved off ImGuiIO onto ImGuiPlatformIO in 1.91, and take a ^Context.
//
// Renders through rlgl's immediate-mode API rather than raw GL, so raylib's own batch/state stays
// coherent - the only requirement is that render_draw_data runs inside BeginDrawing/EndDrawing.
//
/* Usage:

import imgui "../../lib/odin-imgui"
import imgui_rl "../../lib/imgui_impl_raylib"

rl.InitWindow(800, 600, "window")
imgui.CreateContext()
imgui_rl.init()
imgui_rl.build_font_atlas()   // AFTER any AddFont* calls
defer imgui_rl.shutdown()
defer imgui.DestroyContext()

for !rl.WindowShouldClose() {
  imgui_rl.begin()
  rl.BeginDrawing()
  rl.ClearBackground(rl.BLACK)
  imgui.ShowDemoWindow()
  imgui_rl.end()
  rl.EndDrawing()
}
*/

import "core:c"
import "core:math"
import "core:mem"

import rl "vendor:raylib"
import rlgl "vendor:raylib/rlgl"

import imgui "../odin-imgui"

// ===========================================================================
// State
// ===========================================================================

current_mouse_cursor: imgui.MouseCursor = imgui.MouseCursor.COUNT
mouse_cursor_map: [imgui.MouseCursor.COUNT]rl.MouseCursor

font_texture: rl.Texture2D

last_frame_focused := false
last_control_pressed := false
last_shift_pressed := false
last_alt_pressed := false
last_super_pressed := false

raylib_key_map: map[rl.KeyboardKey]imgui.Key = {}

// ===========================================================================
// Frame
// ===========================================================================

// Pump input + open the ImGui frame. Call before your own drawing so widget hit-tests see this frame's
// mouse; io.WantCaptureMouse/WantCaptureKeyboard are then valid for gating app input.
begin :: proc() {
  process_events()
  new_frame()
  imgui.NewFrame()
}

// Close the frame and draw it. Must run inside BeginDrawing/EndDrawing.
end :: proc() {
  imgui.Render()
  render_draw_data(imgui.GetDrawData())
}

init :: proc() {
  setup_globals()
  setup_keymap()
  setup_mouse_cursor()
  setup_backend()
}

// Rasterize the atlas into a raylib texture. Call once, AFTER every FontAtlas_AddFont* call and BEFORE
// the first frame - ImGui builds the atlas lazily otherwise, and would do it without us uploading it.
build_font_atlas :: proc() {
  io := imgui.GetIO()

  pixels: ^c.uchar
  width, height: c.int
  imgui.FontAtlas_GetTexDataAsRGBA32(io.Fonts, &pixels, &width, &height, nil)

  image := rl.GenImageColor(width, height, rl.BLANK)
  mem.copy(image.data, pixels, int(width * height * 4))

  if font_texture.id != 0 {
    rl.UnloadTexture(font_texture)
  }
  font_texture = rl.LoadTextureFromImage(image)
  rl.UnloadImage(image)

  // ImTextureID is a u64 that the renderer defines the meaning of. Ours IS the raylib/GL texture id,
  // which is all rlgl.SetTexture wants - so no allocation has to outlive this call.
  io.Fonts.TexID = imgui.TextureID(font_texture.id)
}

shutdown :: proc() {
  if font_texture.id != 0 {
    rl.UnloadTexture(font_texture)
    font_texture = {}
  }
  imgui.GetIO().Fonts.TexID = 0
  delete(raylib_key_map)
  raylib_key_map = {}
}

new_frame :: proc() {
  io := imgui.GetIO()

  if rl.IsWindowFullscreen() {
    monitor := rl.GetCurrentMonitor()
    io.DisplaySize.x = f32(rl.GetMonitorWidth(monitor))
    io.DisplaySize.y = f32(rl.GetMonitorHeight(monitor))
  } else {
    io.DisplaySize.x = f32(rl.GetScreenWidth())
    io.DisplaySize.y = f32(rl.GetScreenHeight())
  }

  io.DisplayFramebufferScale = rl.GetWindowScaleDPI()
  io.DeltaTime = rl.GetFrameTime()

  if io.WantSetMousePos {
    rl.SetMousePosition(c.int(io.MousePos.x), c.int(io.MousePos.y))
  } else {
    mouse_pos := rl.GetMousePosition()
    imgui.IO_AddMousePosEvent(io, mouse_pos.x, mouse_pos.y)
  }

  set_mouse_event :: proc(io: ^imgui.IO, rl_mouse: rl.MouseButton, imgui_mouse: c.int) {
    if rl.IsMouseButtonPressed(rl_mouse) {
      imgui.IO_AddMouseButtonEvent(io, imgui_mouse, true)
    } else if rl.IsMouseButtonReleased(rl_mouse) {
      imgui.IO_AddMouseButtonEvent(io, imgui_mouse, false)
    }
  }

  set_mouse_event(io, rl.MouseButton.LEFT, c.int(imgui.MouseButton.Left))
  set_mouse_event(io, rl.MouseButton.RIGHT, c.int(imgui.MouseButton.Right))
  set_mouse_event(io, rl.MouseButton.MIDDLE, c.int(imgui.MouseButton.Middle))
  set_mouse_event(io, rl.MouseButton.FORWARD, c.int(imgui.MouseButton.Middle) + 1)
  set_mouse_event(io, rl.MouseButton.BACK, c.int(imgui.MouseButton.Middle) + 2)

  wheel := rl.GetMouseWheelMoveV()
  imgui.IO_AddMouseWheelEvent(io, wheel.x, wheel.y)

  if imgui.ConfigFlag.NoMouseCursorChange not_in io.ConfigFlags {
    cursor := imgui.GetMouseCursor()
    if cursor != current_mouse_cursor || io.MouseDrawCursor {
      current_mouse_cursor = cursor
      if io.MouseDrawCursor || cursor == imgui.MouseCursor.None {
        rl.HideCursor()
      } else {
        rl.ShowCursor()
        if c.int(cursor) > -1 && cursor < imgui.MouseCursor.COUNT {
          rl.SetMouseCursor(mouse_cursor_map[cursor])
        } else {
          rl.SetMouseCursor(rl.MouseCursor.DEFAULT)
        }
      }
    }
  }
}

// ===========================================================================
// Renderer (rlgl immediate mode)
// ===========================================================================

render_draw_data :: proc(draw_data: ^imgui.DrawData) {
  rlgl.DrawRenderBatchActive() // flush whatever the app drew, so our scissor/texture changes can't retro-apply
  rlgl.DisableBackfaceCulling()

  command_lists := mem.slice_ptr(draw_data.CmdLists.Data, int(draw_data.CmdLists.Size))
  for command_list in command_lists {
    cmds := mem.slice_ptr(command_list.CmdBuffer.Data, int(command_list.CmdBuffer.Size))
    for cmd in cmds {
      enable_scissor(
        cmd.ClipRect.x - draw_data.DisplayPos.x,
        cmd.ClipRect.y,
        cmd.ClipRect.z - (cmd.ClipRect.x - draw_data.DisplayPos.x),
        cmd.ClipRect.w - (cmd.ClipRect.y - draw_data.DisplayPos.y),
      )

      if cmd.UserCallback != nil {
        cb_cmd := cmd
        cmd.UserCallback(command_list, &cb_cmd)
        continue
      }

      render_triangles(cmd.ElemCount, cmd.IdxOffset, command_list.IdxBuffer, command_list.VtxBuffer, cmd.TextureId)
      rlgl.DrawRenderBatchActive() // one flush per command: the next may bind a different texture/scissor
    }
  }

  rlgl.SetTexture(0)
  rlgl.DisableScissorTest()
  rlgl.EnableBackfaceCulling()
}

@(private)
enable_scissor :: proc(x, y, width, height: f32) {
  rlgl.EnableScissorTest()
  io := imgui.GetIO()
  // GL scissor origin is bottom-left; ImGui clip rects are top-left.
  rlgl.Scissor(
    i32(x * io.DisplayFramebufferScale.x),
    i32((io.DisplaySize.y - math.floor(y + height)) * io.DisplayFramebufferScale.y),
    i32(width * io.DisplayFramebufferScale.x),
    i32(height * io.DisplayFramebufferScale.y),
  )
}

@(private)
render_triangles :: proc(
  count: u32,
  index_start: u32,
  index_buffer: imgui.Vector_DrawIdx,
  vert_buffer: imgui.Vector_DrawVert,
  texture_id: imgui.TextureID,
) {
  if count < 3 {
    return
  }

  tex := u32(texture_id)

  rlgl.Begin(rlgl.TRIANGLES)
  rlgl.SetTexture(tex)

  indices := mem.slice_ptr(index_buffer.Data, int(index_buffer.Size))
  verts := mem.slice_ptr(vert_buffer.Data, int(vert_buffer.Size))

  emit :: proc(v: imgui.DrawVert) {
    col := transmute(rl.Color)v.col
    rlgl.Color4ub(col.r, col.g, col.b, col.a)
    rlgl.TexCoord2f(v.uv.x, v.uv.y)
    rlgl.Vertex2f(v.pos.x, v.pos.y)
  }

  for i: u32 = 0; i <= count - 3; i += 3 {
    // rlgl's batch is fixed-size; when it fills, it flushes and we have to re-open the primitive.
    if rlgl.CheckRenderBatchLimit(3) != 0 {
      rlgl.Begin(rlgl.TRIANGLES)
      rlgl.SetTexture(tex)
    }
    emit(verts[indices[index_start + i]])
    emit(verts[indices[index_start + i + 1]])
    emit(verts[indices[index_start + i + 2]])
  }

  rlgl.End()
}

// ===========================================================================
// Input
// ===========================================================================

is_control_down :: proc() -> bool {
  return rl.IsKeyDown(.RIGHT_CONTROL) || rl.IsKeyDown(.LEFT_CONTROL)
}
is_shift_down :: proc() -> bool {
  return rl.IsKeyDown(.RIGHT_SHIFT) || rl.IsKeyDown(.LEFT_SHIFT)
}
is_alt_down :: proc() -> bool {
  return rl.IsKeyDown(.RIGHT_ALT) || rl.IsKeyDown(.LEFT_ALT)
}
is_super_down :: proc() -> bool {
  return rl.IsKeyDown(.RIGHT_SUPER) || rl.IsKeyDown(.LEFT_SUPER)
}

process_events :: proc() {
  io := imgui.GetIO()

  focused := rl.IsWindowFocused()
  if focused != last_frame_focused {
    imgui.IO_AddFocusEvent(io, focused)
  }
  last_frame_focused = focused

  // Modifiers are submitted explicitly (they gate shortcuts), separately from the key events below.
  ctrl_down := is_control_down()
  if ctrl_down != last_control_pressed {
    imgui.IO_AddKeyEvent(io, imgui.Key.ImGuiMod_Ctrl, ctrl_down)
  }
  last_control_pressed = ctrl_down

  shift_down := is_shift_down()
  if shift_down != last_shift_pressed {
    imgui.IO_AddKeyEvent(io, imgui.Key.ImGuiMod_Shift, shift_down)
  }
  last_shift_pressed = shift_down

  alt_down := is_alt_down()
  if alt_down != last_alt_pressed {
    imgui.IO_AddKeyEvent(io, imgui.Key.ImGuiMod_Alt, alt_down)
  }
  last_alt_pressed = alt_down

  super_down := is_super_down()
  if super_down != last_super_pressed {
    imgui.IO_AddKeyEvent(io, imgui.Key.ImGuiMod_Super, super_down)
  }
  last_super_pressed = super_down

  // Presses come out of raylib's queue in event order.
  key_id := rl.GetKeyPressed()
  for key_id != rl.KeyboardKey.KEY_NULL {
    if key, ok := raylib_key_map[key_id]; ok {
      imgui.IO_AddKeyEvent(io, key, true)
    }
    key_id = rl.GetKeyPressed()
  }

  for key, mapped in raylib_key_map {
    if rl.IsKeyReleased(key) {
      imgui.IO_AddKeyEvent(io, mapped, false)
    }
  }

  // Text input (already layout-translated by the OS), also in order.
  pressed := rl.GetCharPressed()
  for pressed != 0 {
    imgui.IO_AddInputCharacter(io, u32(pressed))
    pressed = rl.GetCharPressed()
  }
}

// ===========================================================================
// Setup
// ===========================================================================

@(private)
setup_globals :: proc() {
  last_frame_focused = rl.IsWindowFocused()
  last_control_pressed = false
  last_shift_pressed = false
  last_alt_pressed = false
  last_super_pressed = false
}

@(private)
setup_keymap :: proc() {
  if len(raylib_key_map) > 0 {
    return
  }
  raylib_key_map[.APOSTROPHE] = .Apostrophe
  raylib_key_map[.COMMA] = .Comma
  raylib_key_map[.MINUS] = .Minus
  raylib_key_map[.PERIOD] = .Period
  raylib_key_map[.SLASH] = .Slash
  raylib_key_map[.ZERO] = ._0
  raylib_key_map[.ONE] = ._1
  raylib_key_map[.TWO] = ._2
  raylib_key_map[.THREE] = ._3
  raylib_key_map[.FOUR] = ._4
  raylib_key_map[.FIVE] = ._5
  raylib_key_map[.SIX] = ._6
  raylib_key_map[.SEVEN] = ._7
  raylib_key_map[.EIGHT] = ._8
  raylib_key_map[.NINE] = ._9
  raylib_key_map[.SEMICOLON] = .Semicolon
  raylib_key_map[.EQUAL] = .Equal
  raylib_key_map[.A] = .A
  raylib_key_map[.B] = .B
  raylib_key_map[.C] = .C
  raylib_key_map[.D] = .D
  raylib_key_map[.E] = .E
  raylib_key_map[.F] = .F
  raylib_key_map[.G] = .G
  raylib_key_map[.H] = .H
  raylib_key_map[.I] = .I
  raylib_key_map[.J] = .J
  raylib_key_map[.K] = .K
  raylib_key_map[.L] = .L
  raylib_key_map[.M] = .M
  raylib_key_map[.N] = .N
  raylib_key_map[.O] = .O
  raylib_key_map[.P] = .P
  raylib_key_map[.Q] = .Q
  raylib_key_map[.R] = .R
  raylib_key_map[.S] = .S
  raylib_key_map[.T] = .T
  raylib_key_map[.U] = .U
  raylib_key_map[.V] = .V
  raylib_key_map[.W] = .W
  raylib_key_map[.X] = .X
  raylib_key_map[.Y] = .Y
  raylib_key_map[.Z] = .Z
  raylib_key_map[.SPACE] = .Space
  raylib_key_map[.ESCAPE] = .Escape
  raylib_key_map[.ENTER] = .Enter
  raylib_key_map[.TAB] = .Tab
  raylib_key_map[.BACKSPACE] = .Backspace
  raylib_key_map[.INSERT] = .Insert
  raylib_key_map[.DELETE] = .Delete
  raylib_key_map[.RIGHT] = .RightArrow
  raylib_key_map[.LEFT] = .LeftArrow
  raylib_key_map[.DOWN] = .DownArrow
  raylib_key_map[.UP] = .UpArrow
  raylib_key_map[.PAGE_UP] = .PageUp
  raylib_key_map[.PAGE_DOWN] = .PageDown
  raylib_key_map[.HOME] = .Home
  raylib_key_map[.END] = .End
  raylib_key_map[.CAPS_LOCK] = .CapsLock
  raylib_key_map[.SCROLL_LOCK] = .ScrollLock
  raylib_key_map[.NUM_LOCK] = .NumLock
  raylib_key_map[.PRINT_SCREEN] = .PrintScreen
  raylib_key_map[.PAUSE] = .Pause
  raylib_key_map[.F1] = .F1
  raylib_key_map[.F2] = .F2
  raylib_key_map[.F3] = .F3
  raylib_key_map[.F4] = .F4
  raylib_key_map[.F5] = .F5
  raylib_key_map[.F6] = .F6
  raylib_key_map[.F7] = .F7
  raylib_key_map[.F8] = .F8
  raylib_key_map[.F9] = .F9
  raylib_key_map[.F10] = .F10
  raylib_key_map[.F11] = .F11
  raylib_key_map[.F12] = .F12
  raylib_key_map[.LEFT_SHIFT] = .LeftShift
  raylib_key_map[.LEFT_CONTROL] = .LeftCtrl
  raylib_key_map[.LEFT_ALT] = .LeftAlt
  raylib_key_map[.LEFT_SUPER] = .LeftSuper
  raylib_key_map[.RIGHT_SHIFT] = .RightShift
  raylib_key_map[.RIGHT_CONTROL] = .RightCtrl
  raylib_key_map[.RIGHT_ALT] = .RightAlt
  raylib_key_map[.RIGHT_SUPER] = .RightSuper
  raylib_key_map[.KB_MENU] = .Menu
  raylib_key_map[.LEFT_BRACKET] = .LeftBracket
  raylib_key_map[.BACKSLASH] = .Backslash
  raylib_key_map[.RIGHT_BRACKET] = .RightBracket
  raylib_key_map[.GRAVE] = .GraveAccent
  raylib_key_map[.KP_0] = .Keypad0
  raylib_key_map[.KP_1] = .Keypad1
  raylib_key_map[.KP_2] = .Keypad2
  raylib_key_map[.KP_3] = .Keypad3
  raylib_key_map[.KP_4] = .Keypad4
  raylib_key_map[.KP_5] = .Keypad5
  raylib_key_map[.KP_6] = .Keypad6
  raylib_key_map[.KP_7] = .Keypad7
  raylib_key_map[.KP_8] = .Keypad8
  raylib_key_map[.KP_9] = .Keypad9
  raylib_key_map[.KP_DECIMAL] = .KeypadDecimal
  raylib_key_map[.KP_DIVIDE] = .KeypadDivide
  raylib_key_map[.KP_MULTIPLY] = .KeypadMultiply
  raylib_key_map[.KP_SUBTRACT] = .KeypadSubtract
  raylib_key_map[.KP_ADD] = .KeypadAdd
  raylib_key_map[.KP_ENTER] = .KeypadEnter
  raylib_key_map[.KP_EQUAL] = .KeypadEqual
}

@(private)
setup_mouse_cursor :: proc() {
  // Indexed by the enum VALUE (the array is sized by MouseCursor.COUNT, not an enumerated array), so
  // these need the qualified name - an implicit `.Arrow` has no type to infer from here.
  mouse_cursor_map[imgui.MouseCursor.Arrow] = .ARROW
  mouse_cursor_map[imgui.MouseCursor.TextInput] = .IBEAM
  mouse_cursor_map[imgui.MouseCursor.Hand] = .POINTING_HAND
  mouse_cursor_map[imgui.MouseCursor.ResizeAll] = .RESIZE_ALL
  mouse_cursor_map[imgui.MouseCursor.ResizeEW] = .RESIZE_EW
  mouse_cursor_map[imgui.MouseCursor.ResizeNESW] = .RESIZE_NESW
  mouse_cursor_map[imgui.MouseCursor.ResizeNS] = .RESIZE_NS
  mouse_cursor_map[imgui.MouseCursor.ResizeNWSE] = .RESIZE_NWSE
  mouse_cursor_map[imgui.MouseCursor.NotAllowed] = .NOT_ALLOWED
}

@(private)
setup_backend :: proc() {
  io := imgui.GetIO()
  io.BackendPlatformName = "imgui_impl_raylib"
  io.BackendFlags |= {imgui.BackendFlag.HasMouseCursors}
  io.MousePos = {0, 0}
  // No imgui.ini: this backend hosts fixed overlays, and a settings file dropped in the user's cwd is
  // pure litter (it would also pin stale window positions across a redesign).
  io.IniFilename = nil

  pio := imgui.GetPlatformIO()
  pio.Platform_SetClipboardTextFn = set_clip_text_callback
  pio.Platform_GetClipboardTextFn = get_clip_text_callback
  pio.Platform_ClipboardUserData = nil
}

@(private)
set_clip_text_callback :: proc "c" (ctx: ^imgui.Context, text: cstring) {
  rl.SetClipboardText(text)
}

@(private)
get_clip_text_callback :: proc "c" (ctx: ^imgui.Context) -> cstring {
  return rl.GetClipboardText()
}
