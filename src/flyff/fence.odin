package flyff

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"

// ===========================================================================
// Geo-fence: a target-selection boundary. A fence is a FLAT LIST of shapes, each tagged include(+)
// or exclude(-). A world point is inside when it is inside ANY + shape AND inside NO - shape (a fence
// with only - shapes carves out of the whole map). The auto/manual picker gates candidate mobs on
// fence_contains (see tc_cand_skip in target.odin), so the player never targets mobs outside the area.
//
// Authoring: draw shapes on the live radar (mouse editor in radar.odin) OR the walk-and-place text
// commands here (`fence add ...` at the player's feet, or explicit world coords). Serializable to
// <exe-dir>/fences/<name>.fence. See [[flyff-target-data-model]] / BACKLOG.md (Geo-fence).
// ===========================================================================

Fence_Kind :: enum {
  Circle,
  Rect, // axis-aligned (min/max); a "box" (center + half-extent) is just a Rect
  Polygon,
}

Fence_Shape :: struct {
  kind:                   Fence_Kind,
  include:                bool, // + (true, inclusion) / - (false, carve-out)
  cx, cz, r:              f32, // Circle: center + radius
  minx, minz, maxx, maxz: f32, // Rect: bounds
  verts:                  [dynamic][2]f32, // Polygon: world (x,z) vertices
}

Fence :: struct {
  active:   bool, // gate live? (adding a shape auto-activates; `fence off` disables without clearing)
  shapes:   [dynamic]Fence_Shape,
  poly_wip: [dynamic][2]f32, // in-progress polygon vertices from `fence poly point` (text authoring)
}

// ===========================================================================
// Membership
// ===========================================================================

// Standard ray-cast point-in-polygon for a simple polygon (any winding). <3 verts -> false.
point_in_poly :: proc(verts: [][2]f32, x, z: f32) -> bool {
  n := len(verts)
  if n < 3 {
    return false
  }
  inside := false
  j := n - 1
  for i in 0 ..< n {
    xi := verts[i][0]
    zi := verts[i][1]
    xj := verts[j][0]
    zj := verts[j][1]
    if (zi > z) != (zj > z) {
      xint := (xj - xi) * (z - zi) / (zj - zi) + xi
      if x < xint {
        inside = !inside
      }
    }
    j = i
  }
  return inside
}

fence_shape_contains :: proc(s: Fence_Shape, x, z: f32) -> bool {
  switch s.kind {
  case .Circle:
    dx := x - s.cx
    dz := z - s.cz
    return dx * dx + dz * dz <= s.r * s.r
  case .Rect:
    return x >= s.minx && x <= s.maxx && z >= s.minz && z <= s.maxz
  case .Polygon:
    return point_in_poly(s.verts[:], x, z)
  }
  return false
}

// Geometric membership, ignoring the active flag: inside ANY + AND inside NO -. Empty (or all-minus)
// shape set -> the base region is the whole map. Used by `fence test` and, via fence_contains, the gate.
fence_geom_contains :: proc(f: Fence, x, z: f32) -> bool {
  if len(f.shapes) == 0 {
    return true
  }
  has_plus := false
  inside_plus := false
  for s in f.shapes {
    if s.include {
      has_plus = true
      if fence_shape_contains(s, x, z) {
        inside_plus = true
      }
    }
  }
  base := has_plus ? inside_plus : true // only - shapes -> carve out of the whole map
  if !base {
    return false
  }
  for s in f.shapes {
    if !s.include && fence_shape_contains(s, x, z) {
      return false // inside a carve-out
    }
  }
  return true
}

// The gate predicate: an inactive fence lets everything through.
fence_contains :: proc(f: Fence, x, z: f32) -> bool {
  if !f.active {
    return true
  }
  return fence_geom_contains(f, x, z)
}

// ===========================================================================
// Lifetime
// ===========================================================================

// Drop all shapes + any in-progress polygon and deactivate; keeps the backing arrays for reuse.
fence_reset :: proc(f: ^Fence) {
  for &s in f.shapes {
    delete(s.verts)
  }
  clear(&f.shapes)
  clear(&f.poly_wip)
  f.active = false
}

// Free everything (session_close).
fence_destroy :: proc(f: ^Fence) {
  for &s in f.shapes {
    delete(s.verts)
  }
  delete(f.shapes)
  delete(f.poly_wip)
}

// Remove the last shape (freeing a polygon's verts). Returns false if there was nothing to undo.
fence_pop_shape :: proc(f: ^Fence) -> bool {
  n := len(f.shapes)
  if n == 0 {
    return false
  }
  delete(f.shapes[n - 1].verts)
  ordered_remove(&f.shapes, n - 1)
  return true
}

// Index of the TOPMOST (last-drawn, so visually on top) shape containing (x,z), or -1. Used by the radar
// eraser tool to pick the shape under the cursor.
fence_shape_at :: proc(f: Fence, x, z: f32) -> int {
  #reverse for s, i in f.shapes {
    if fence_shape_contains(s, x, z) {
      return i
    }
  }
  return -1
}

// Delete the topmost shape containing (x,z) (the eraser). Returns false when the point hits no shape.
fence_erase_at :: proc(f: ^Fence, x, z: f32) -> bool {
  i := fence_shape_at(f^, x, z)
  if i < 0 {
    return false
  }
  delete(f.shapes[i].verts)
  ordered_remove(&f.shapes, i)
  return true
}

// ===========================================================================
// Serialization  (<exe-dir>/fences/<name>.fence, line-based like flyff.cfg)
// ===========================================================================

fence_dir_path :: proc(allocator := context.temp_allocator) -> string {
  exe := os.args[0]
  slash := strings.last_index_any(exe, "\\/")
  dir := slash >= 0 ? exe[:slash] : "."
  return fmt.aprintf("%s/fences", dir, allocator = allocator)
}

fence_file_path :: proc(name: string, allocator := context.temp_allocator) -> string {
  return fmt.aprintf("%s/%s.fence", fence_dir_path(allocator), name, allocator = allocator)
}

fence_serialize :: proc(f: ^Fence, b: ^strings.Builder) {
  fmt.sbprintln(b, "# memscan fence")
  fmt.sbprintfln(b, "active %d", f.active ? 1 : 0)
  for s in f.shapes {
    tag := s.include ? "+" : "-"
    switch s.kind {
    case .Circle:
      fmt.sbprintfln(b, "circle %s %v %v %v", tag, s.cx, s.cz, s.r)
    case .Rect:
      fmt.sbprintfln(b, "rect %s %v %v %v %v", tag, s.minx, s.minz, s.maxx, s.maxz)
    case .Polygon:
      fmt.sbprintf(b, "poly %s", tag)
      for v in s.verts {
        fmt.sbprintf(b, " %v %v", v[0], v[1])
      }
      fmt.sbprintln(b)
    }
  }
}

fence_f32 :: proc(s: string) -> f32 {
  v, _ := strconv.parse_f64(s)
  return f32(v)
}

// Replace f's contents from a serialized fence. Tolerant: skips malformed lines.
fence_deserialize :: proc(f: ^Fence, content: string) {
  fence_reset(f)
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
    case "active":
      if len(fields) >= 2 && fields[1] == "1" {
        f.active = true
      }
    case "circle":
      if len(fields) >= 5 {
        append(
          &f.shapes,
          Fence_Shape {
            kind = .Circle,
            include = fields[1] != "-",
            cx = fence_f32(fields[2]),
            cz = fence_f32(fields[3]),
            r = fence_f32(fields[4]),
          },
        )
      }
    case "rect":
      if len(fields) >= 6 {
        append(
          &f.shapes,
          Fence_Shape {
            kind = .Rect,
            include = fields[1] != "-",
            minx = fence_f32(fields[2]),
            minz = fence_f32(fields[3]),
            maxx = fence_f32(fields[4]),
            maxz = fence_f32(fields[5]),
          },
        )
      }
    case "poly":
      if len(fields) >= 2 {
        s := Fence_Shape {
          kind    = .Polygon,
          include = fields[1] != "-",
        }
        i := 2
        for i + 1 < len(fields) {
          append(&s.verts, [2]f32{fence_f32(fields[i]), fence_f32(fields[i + 1])})
          i += 2
        }
        if len(s.verts) >= 3 {
          append(&f.shapes, s)
        } else {
          delete(s.verts)
        }
      }
    }
  }
}

// ===========================================================================
// Text commands  (fence <subcommand>) - dispatched from cli.odin
// ===========================================================================

// Pops a trailing "+"/"-" tag from args; returns the remaining args + the include flag (default +).
fence_pop_tag :: proc(args: []string) -> (rest: []string, include: bool) {
  include = true
  rest = args
  if len(args) > 0 {
    switch args[len(args) - 1] {
    case "-":
      include = false
      rest = args[:len(args) - 1]
    case "+":
      rest = args[:len(args) - 1]
    }
  }
  return
}

parse_vec2_literal :: proc(s: string) -> (v: [2]f32, ok: bool) {
  parts := strings.split(s, ",", context.temp_allocator)
  if len(parts) != 2 {
    return {}, false
  }
  for p, i in parts {
    fv, fok := strconv.parse_f64(strings.trim_space(p))
    if !fok {
      return {}, false
    }
    v[i] = f32(fv)
  }
  return v, true
}

fence_shape_desc :: proc(s: Fence_Shape, allocator := context.temp_allocator) -> string {
  tag := s.include ? "+" : "-"
  switch s.kind {
  case .Circle:
    return fmt.aprintf("%s circle  center (%.1f, %.1f)  r %.1f", tag, s.cx, s.cz, s.r, allocator = allocator)
  case .Rect:
    return fmt.aprintf(
      "%s rect    x [%.1f..%.1f]  z [%.1f..%.1f]",
      tag,
      s.minx,
      s.maxx,
      s.minz,
      s.maxz,
      allocator = allocator,
    )
  case .Polygon:
    return fmt.aprintf("%s polygon %d verts", tag, len(s.verts), allocator = allocator)
  }
  return "?"
}

fence_print_status :: proc(session: ^Session) {
  f := &session.fence
  fmt.printfln("fence: %s, %d shape(s)%s", f.active ? "ACTIVE" : "off", len(f.shapes), len(f.poly_wip) > 0 ? fmt.tprintf(", polygon in progress (%d pts)", len(f.poly_wip)) : "")
  for s, i in f.shapes {
    fmt.printfln("  [%d] %s", i, fence_shape_desc(s))
  }
  if len(f.shapes) == 0 {
    fmt.println("  (no shapes - all mobs are eligible)")
  }
}

// Center for an "at the player" add. Returns false (and prints why) if the player pos isn't readable.
fence_player_xz :: proc(session: ^Session) -> (x, z: f32, ok: bool) {
  if !session.attached {
    fmt.eprintln("fence: attach first, or give explicit coords.")
    return 0, 0, false
  }
  pp, pok := read_player_pos(session)
  if !pok {
    fmt.eprintln("fence: could not read player position - run 'setup <name>'.")
    return 0, 0, false
  }
  return pp[0], pp[2], true
}

cli_fence :: proc(session: ^Session, args: []string) {
  f := &session.fence
  if len(args) == 0 {
    fence_print_status(session)
    return
  }
  switch args[0] {
  case "status":
    fence_print_status(session)

  case "on":
    f.active = true
    fmt.println("fence: ACTIVE.")
  case "off":
    f.active = false
    fmt.println("fence: off (shapes kept; 'fence on' re-enables).")

  case "clear":
    fence_reset(f)
    fmt.println("fence: cleared.")

  case "undo":
    if len(f.poly_wip) > 0 {
      pop(&f.poly_wip)
      fmt.printfln("fence: dropped last polygon vertex (%d left).", len(f.poly_wip))
    } else if fence_pop_shape(f) {
      fmt.printfln("fence: removed last shape (%d left).", len(f.shapes))
    } else {
      fmt.println("fence: nothing to undo.")
    }

  case "add":
    fence_cmd_add(session, args[1:])

  case "poly":
    fence_cmd_poly(session, args[1:])

  case "test":
    if len(args) < 2 {
      fmt.eprintln("usage: fence test <x,z>")
      return
    }
    p, ok := parse_vec2_literal(args[1])
    if !ok {
      fmt.eprintln("fence test: bad coords (want x,z).")
      return
    }
    inside := fence_geom_contains(f^, p[0], p[1])
    fmt.printfln("fence test (%.1f, %.1f): %s  [fence %s]", p[0], p[1], inside ? "INSIDE" : "outside", f.active ? "active" : "off")

  case "erase":
    if len(args) < 2 {
      fmt.eprintln("usage: fence erase <x,z>  (deletes the topmost shape containing that point)")
      return
    }
    p, ok := parse_vec2_literal(args[1])
    if !ok {
      fmt.eprintln("fence erase: bad coords (want x,z).")
      return
    }
    if fence_erase_at(f, p[0], p[1]) {
      fmt.printfln("fence: erased the shape at (%.1f, %.1f) (%d left).", p[0], p[1], len(f.shapes))
    } else {
      fmt.printfln("fence: no shape contains (%.1f, %.1f).", p[0], p[1])
    }

  case "save":
    if len(args) < 2 {
      fmt.eprintln("usage: fence save <name>")
      return
    }
    fence_cmd_save(session, args[1])
  case "load":
    if len(args) < 2 {
      fmt.eprintln("usage: fence load <name>")
      return
    }
    fence_cmd_load(session, args[1])
  case "list":
    fence_cmd_list()

  case:
    fmt.eprintfln("fence: unknown subcommand '%s' (status|add|poly|undo|erase|clear|on|off|save|load|list|test)", args[0])
  }
}

// fence add circle <r> [-]            | fence add circle <x,z> <r> [-]
// fence add rect   <halfx,halfz> [-]  | fence add rect   <minx,minz> <maxx,maxz> [-]
fence_cmd_add :: proc(session: ^Session, args: []string) {
  f := &session.fence
  if len(args) == 0 {
    fmt.eprintln("usage: fence add circle|rect ...")
    return
  }
  rest, include := fence_pop_tag(args[1:])
  switch args[0] {
  case "circle":
    cx, cz, r: f32
    switch len(rest) {
    case 1: // <r> at the player
      px, pz, ok := fence_player_xz(session)
      if !ok {return}
      rv, rok := strconv.parse_f64(rest[0])
      if !rok || rv <= 0 {
        fmt.eprintln("fence add circle: bad radius.")
        return
      }
      cx, cz, r = px, pz, f32(rv)
    case 2: // <x,z> <r>
      c, cok := parse_vec2_literal(rest[0])
      rv, rok := strconv.parse_f64(rest[1])
      if !cok || !rok || rv <= 0 {
        fmt.eprintln("fence add circle: want <x,z> <r>.")
        return
      }
      cx, cz, r = c[0], c[1], f32(rv)
    case:
      fmt.eprintln("usage: fence add circle <r> [-]  |  fence add circle <x,z> <r> [-]")
      return
    }
    append(&f.shapes, Fence_Shape{kind = .Circle, include = include, cx = cx, cz = cz, r = r})
    f.active = true
    fmt.printfln("fence: + %s circle center (%.1f, %.1f) r %.1f  (%d shapes, ACTIVE)", include ? "" : "EXCLUDE", cx, cz, r, len(f.shapes))

  case "rect":
    minx, minz, maxx, maxz: f32
    switch len(rest) {
    case 1: // <halfx,halfz> box at the player
      h, hok := parse_vec2_literal(rest[0])
      px, pz, ok := fence_player_xz(session)
      if !hok || !ok {
        if !hok {fmt.eprintln("fence add rect: want <halfx,halfz>.")}
        return
      }
      minx, maxx = px - h[0], px + h[0]
      minz, maxz = pz - h[1], pz + h[1]
    case 2: // <minx,minz> <maxx,maxz>
      a, aok := parse_vec2_literal(rest[0])
      b, bok := parse_vec2_literal(rest[1])
      if !aok || !bok {
        fmt.eprintln("fence add rect: want <minx,minz> <maxx,maxz>.")
        return
      }
      minx, maxx = min(a[0], b[0]), max(a[0], b[0])
      minz, maxz = min(a[1], b[1]), max(a[1], b[1])
    case:
      fmt.eprintln("usage: fence add rect <halfx,halfz> [-]  |  fence add rect <minx,minz> <maxx,maxz> [-]")
      return
    }
    append(&f.shapes, Fence_Shape{kind = .Rect, include = include, minx = minx, minz = minz, maxx = maxx, maxz = maxz})
    f.active = true
    fmt.printfln("fence: + %s rect x[%.1f..%.1f] z[%.1f..%.1f]  (%d shapes, ACTIVE)", include ? "" : "EXCLUDE", minx, maxx, minz, maxz, len(f.shapes))

  case:
    fmt.eprintfln("fence add: unknown shape '%s' (circle|rect; polygon via 'fence poly')", args[0])
  }
}

// fence poly start | fence poly point | fence poly end [-]
fence_cmd_poly :: proc(session: ^Session, args: []string) {
  f := &session.fence
  if len(args) == 0 {
    fmt.eprintln("usage: fence poly start|point|end")
    return
  }
  switch args[0] {
  case "start":
    clear(&f.poly_wip)
    fmt.println("fence poly: started - walk to each corner and 'fence poly point', then 'fence poly end'.")
  case "point":
    x, z, ok := fence_player_xz(session)
    if !ok {return}
    append(&f.poly_wip, [2]f32{x, z})
    fmt.printfln("fence poly: vertex %d at (%.1f, %.1f).", len(f.poly_wip), x, z)
  case "end":
    if len(f.poly_wip) < 3 {
      fmt.eprintfln("fence poly end: need >=3 vertices (have %d).", len(f.poly_wip))
      return
    }
    _, include := fence_pop_tag(args[1:])
    s := Fence_Shape {
      kind    = .Polygon,
      include = include,
    }
    append(&s.verts, ..f.poly_wip[:])
    append(&f.shapes, s)
    clear(&f.poly_wip)
    f.active = true
    fmt.printfln("fence: + %s polygon %d verts  (%d shapes, ACTIVE)", include ? "" : "EXCLUDE", len(s.verts), len(f.shapes))
  case:
    fmt.eprintfln("fence poly: unknown '%s' (start|point|end)", args[0])
  }
}

fence_cmd_save :: proc(session: ^Session, name: string) {
  dir := fence_dir_path()
  os.make_directory(dir) // ignore "already exists"
  path := fence_file_path(name)
  b := strings.builder_make(context.temp_allocator)
  fence_serialize(&session.fence, &b)
  if err := os.write_entire_file(path, transmute([]byte)strings.to_string(b)); err != nil {
    fmt.eprintfln("fence save: write failed (%v): %s", err, path)
    return
  }
  fmt.printfln("fence: saved %d shape(s) -> %s", len(session.fence.shapes), path)
}

fence_cmd_load :: proc(session: ^Session, name: string) {
  path := fence_file_path(name)
  data, err := os.read_entire_file(path, context.temp_allocator)
  if err != nil {
    fmt.eprintfln("fence load: cannot read %s (%v). 'fence list' to see saved fences.", path, err)
    return
  }
  fence_deserialize(&session.fence, string(data))
  session.fence.active = true
  fmt.printfln("fence: loaded %d shape(s) from %s (ACTIVE).", len(session.fence.shapes), name)
}

fence_cmd_list :: proc() {
  dir := fence_dir_path()
  infos, err := os.read_all_directory_by_path(dir, context.temp_allocator)
  if err != nil {
    fmt.printfln("fence: no saved fences yet (%s).", dir)
    return
  }
  n := 0
  fmt.printfln("saved fences in %s:", dir)
  for fi in infos {
    if strings.has_suffix(fi.name, ".fence") {
      fmt.printfln("  %s", strings.trim_suffix(fi.name, ".fence"))
      n += 1
    }
  }
  if n == 0 {
    fmt.println("  (none)")
  }
}
