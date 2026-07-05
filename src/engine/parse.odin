package engine

import "core:strconv"
import "core:strings"

parse_addr :: proc(s: string) -> (uintptr, bool) {
  if strings.has_prefix(s, "0x") || strings.has_prefix(s, "0X") {
    v, ok := strconv.parse_u64_of_base(s[2:], 16)
    return uintptr(v), ok
  }
  if v, ok := strconv.parse_u64_of_base(s, 10); ok {
    return uintptr(v), true
  }
  v, ok := strconv.parse_u64_of_base(s, 16)
  return uintptr(v), ok
}

parse_offset :: proc(s: string) -> (i64, bool) {
  ss := s
  if strings.has_prefix(ss, "+") {
    ss = ss[1:]
  }
  neg := false
  if strings.has_prefix(ss, "-") {
    neg = true
    ss = ss[1:]
  }
  v: u64
  ok: bool
  if strings.has_prefix(ss, "0x") || strings.has_prefix(ss, "0X") {
    v, ok = strconv.parse_u64_of_base(ss[2:], 16)
  } else {
    v, ok = strconv.parse_u64_of_base(ss, 10)
  }
  if !ok {
    return 0, false
  }
  r := i64(v)
  if neg {
    r = -r
  }
  return r, true
}
