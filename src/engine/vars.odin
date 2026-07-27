package engine

import "core:fmt"
import "core:strings"

// ===========================================================================
// Session variables + @name interpolation.
//
// `var lane_x 6800` then `moveto @lane_x,3300`. Interpolation is expanded in
// execute_line BEFORE the line is split on ';', so it reaches EVERY command -
// generic ones (`read @addr`, `poke 0 @val`), flyff ones, hotkey bindings, the
// radar's deferred queue, and behaviour scripts - through one code path.
//
// This lives in engine rather than flyff on purpose: a memory scanner wants
// `var base 0x400000` regardless of which module is loaded, and the flyff
// behaviour scripts then read/write the same map instead of owning a second one.
//
// Deliberately untyped (string in, string out, substituted textually). Each
// command already parses its own arguments - re-parsing here would just mean two
// places to disagree about what "0x1F" means.
//
// NOTE (`set` vs `var`): flyff's `set` writes LAYOUT fields (memory offsets/RVAs)
// and is intentionally NOT overloaded to also create variables - a mistyped offset
// key silently becoming a variable is a memory-write bug waiting to happen. See the
// unknown-field hint in flyff/layout.odin cli_set.
// ===========================================================================

VAR_MAX_EXPANSIONS :: 64 // per line, so a self-referential value can't loop forever

// Set a variable (empty value unsets it). Both key and value are cloned into the process heap;
// the previous entry's strings are freed, so a rebind never leaks.
session_var_set :: proc(session: ^Session, name: string, value: string) {
  if session.vars == nil {
    session.vars = make(map[string]string)
  }
  if old_key, old_val, found := session_var_entry(session, name); found {
    delete_key(&session.vars, name)
    delete(old_key)
    delete(old_val)
  }
  if value == "" {
    return // unset
  }
  session.vars[strings.clone(name)] = strings.clone(value)
}

// The stored key/value strings for <name> (so a rebind can free the exact allocations it replaces).
@(private = "file")
session_var_entry :: proc(session: ^Session, name: string) -> (key: string, value: string, found: bool) {
  for k, v in session.vars {
    if k == name {
      return k, v, true
    }
  }
  return "", "", false
}

session_var_get :: proc(session: ^Session, name: string) -> (value: string, ok: bool) {
  v, found := session.vars[name]
  return v, found
}

session_vars_clear :: proc(session: ^Session) {
  for k, v in session.vars {
    delete(k)
    delete(v)
  }
  clear(&session.vars)
}

session_vars_free :: proc(session: ^Session) {
  session_vars_clear(session)
  delete(session.vars)
  session.vars = nil
}

// Substitute @name references in <line>. A name runs to the first character that can't be part of
// an identifier, so `@lane_x,3300` and `moveto @a @b` both work without delimiters. `@@` emits a
// literal '@'.
//
// An UNKNOWN @name is a hard error (ok=false) rather than passing through: `poke 0 @typo` reaching
// a command as the literal text "@typo" is how you write to the wrong place. The caller reports it
// and abandons the line.
expand_vars :: proc(session: ^Session, line: string, allocator := context.temp_allocator) -> (out: string, ok: bool, bad_name: string) {
  if !strings.contains(line, "@") {
    return line, true, "" // nothing to do - hand back the input unchanged (no allocation)
  }
  b := strings.builder_make(allocator)
  expansions := 0
  i := 0
  for i < len(line) {
    c := line[i]
    if c != '@' {
      strings.write_byte(&b, c)
      i += 1
      continue
    }
    if i + 1 < len(line) && line[i + 1] == '@' {
      strings.write_byte(&b, '@') // escaped literal
      i += 2
      continue
    }
    j := i + 1
    for j < len(line) && var_name_byte(line[j]) {
      j += 1
    }
    if j == i + 1 {
      strings.write_byte(&b, '@') // a bare '@' with no name after it - leave it alone
      i += 1
      continue
    }
    name := line[i + 1:j]
    val, found := session_var_get(session, name)
    if !found {
      return "", false, name
    }
    expansions += 1
    if expansions > VAR_MAX_EXPANSIONS {
      return "", false, name
    }
    strings.write_string(&b, val)
    i = j
  }
  return strings.to_string(b), true, ""
}

@(private = "file")
var_name_byte :: proc(c: byte) -> bool {
  return c == '_' || (c >= '0' && c <= '9') || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// var                    -> list
// var <name>             -> show one
// var <name> <value...>  -> set (value may contain spaces; '-' unsets)
// var clear              -> drop them all
cmd_var :: proc(session: ^Session, args: []string) {
  if len(args) == 0 {
    cmd_var_list(session)
    return
  }
  if args[0] == "clear" && len(args) == 1 {
    n := len(session.vars)
    session_vars_clear(session)
    fmt.printfln("%d variable(s) cleared.", n)
    return
  }
  name := args[0]
  if !var_name_ok(name) {
    fmt.eprintfln("bad variable name '%s' - letters, digits and _ only (referenced as @%s).", name, name)
    return
  }
  if len(args) == 1 {
    if v, ok := session_var_get(session, name); ok {
      fmt.printfln("var %s = %s", name, v)
    } else {
      fmt.eprintfln("var '%s' is not set. usage: var %s <value>", name, name)
    }
    return
  }
  value := strings.trim_space(strings.join(args[1:], " ", context.temp_allocator))
  if value == "-" || value == `""` || value == "''" {
    session_var_set(session, name, "")
    fmt.printfln("var %s unset.", name)
    return
  }
  session_var_set(session, name, value)
  fmt.printfln("var %s = %s   (use it as @%s)", name, value, name)
}

@(private = "file")
cmd_var_list :: proc(session: ^Session) {
  if len(session.vars) == 0 {
    fmt.println("no variables set. usage: var <name> <value>   then reference it as @<name>")
    return
  }
  fmt.printfln("%d variable(s):", len(session.vars))
  for k, v in session.vars {
    fmt.printfln("  %-16s %s", k, v)
  }
}

@(private = "file")
var_name_ok :: proc(name: string) -> bool {
  if name == "" {
    return false
  }
  for i in 0 ..< len(name) {
    if !var_name_byte(name[i]) {
      return false
    }
  }
  return true
}
