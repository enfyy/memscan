package engine

import "core:fmt"
import "core:mem"
import "core:strconv"

// ===========================================================================
// Value types
// ===========================================================================

Value_Type :: enum u8 {
  U8,
  I8,
  U16,
  I16,
  U32,
  I32,
  U64,
  I64,
  F32,
  F64,
}

// A value is stored as up to 8 raw little-endian bytes.
Value :: [8]byte

value_size :: proc(t: Value_Type) -> int {
  switch t {
  case .U8, .I8:
    return 1
  case .U16, .I16:
    return 2
  case .U32, .I32, .F32:
    return 4
  case .U64, .I64, .F64:
    return 8
  }
  return 0
}

value_type_name :: proc(t: Value_Type) -> string {
  switch t {
  case .U8:
    return "u8"
  case .I8:
    return "i8"
  case .U16:
    return "u16"
  case .I16:
    return "i16"
  case .U32:
    return "u32"
  case .I32:
    return "i32"
  case .U64:
    return "u64"
  case .I64:
    return "i64"
  case .F32:
    return "f32"
  case .F64:
    return "f64"
  }
  return "?"
}

is_float :: proc(t: Value_Type) -> bool {
  return t == .F32 || t == .F64
}

is_signed :: proc(t: Value_Type) -> bool {
  return t == .I8 || t == .I16 || t == .I32 || t == .I64
}

bytes_to_value :: proc(b: []byte) -> (out: Value) {
  n := min(len(b), 8)
  copy(out[:n], b[:n])
  return
}

value_as_u64 :: proc(t: Value_Type, v: Value) -> u64 {
  n := value_size(t)
  out: u64 = 0
  for i in 0 ..< n {
    out |= u64(v[i]) << uint(8 * i)
  }
  return out
}

value_as_i64 :: proc(t: Value_Type, v: Value) -> i64 {
  n := value_size(t)
  u := value_as_u64(t, v)
  shift := uint(64 - 8 * n)
  return i64(u << shift) >> shift
}

value_as_f64 :: proc(t: Value_Type, v: Value) -> f64 {
  if t == .F32 {
    return f64(transmute(f32)u32(value_as_u64(t, v)))
  }
  return transmute(f64)value_as_u64(t, v)
}

// Parse a textual value of the given type into raw little-endian bytes.
// Integers accept decimal or 0x / 0o / 0b prefixes (and a leading '-').
parse_value :: proc(t: Value_Type, s: string) -> (out: Value, ok: bool) {
  if is_float(t) {
    f := strconv.parse_f64(s) or_return
    if t == .F32 {
      u := transmute(u32)f32(f)
      for i in 0 ..< 4 {
        out[i] = byte(u >> uint(8 * i))
      }
    } else {
      u := transmute(u64)f
      for i in 0 ..< 8 {
        out[i] = byte(u >> uint(8 * i))
      }
    }
    return out, true
  }
  i := strconv.parse_i64(s) or_return
  u := u64(i)
  n := value_size(t)
  for k in 0 ..< n {
    out[k] = byte(u >> uint(8 * k))
  }
  return out, true
}

format_value :: proc(t: Value_Type, v: Value) -> string {
  if is_float(t) {
    return fmt.tprintf("%v", value_as_f64(t, v))
  } else if is_signed(t) {
    return fmt.tprintf("%d (0x%X)", value_as_i64(t, v), value_as_u64(t, v))
  }
  uv := value_as_u64(t, v)
  return fmt.tprintf("%d (0x%X)", uv, uv)
}

// ===========================================================================
// Comparison
// ===========================================================================

Compare_Op :: enum {
  Eq,
  Ne,
  Gt,
  Lt,
  Changed,
  Unchanged,
  Increased,
  Decreased,
}

// Compares a freshly-read value `new_v` against a reference `ref_v`. For Eq/Ne/
// Gt/Lt the reference is a user-supplied target; for Changed/Unchanged/Increased/
// Decreased it is the value from the previous scan.
compare_values :: proc(t: Value_Type, new_v, ref_v: Value, op: Compare_Op) -> bool {
  size := value_size(t)
  a := new_v
  b := ref_v
  switch op {
  case .Eq, .Unchanged:
    return mem.compare(a[:size], b[:size]) == 0
  case .Ne, .Changed:
    return mem.compare(a[:size], b[:size]) != 0
  case .Gt, .Lt, .Increased, .Decreased:
    if is_float(t) {
      a := value_as_f64(t, new_v)
      b := value_as_f64(t, ref_v)
      #partial switch op {
      case .Gt, .Increased:
        return a > b
      case .Lt, .Decreased:
        return a < b
      }
    } else if is_signed(t) {
      a := value_as_i64(t, new_v)
      b := value_as_i64(t, ref_v)
      #partial switch op {
      case .Gt, .Increased:
        return a > b
      case .Lt, .Decreased:
        return a < b
      }
    } else {
      a := value_as_u64(t, new_v)
      b := value_as_u64(t, ref_v)
      #partial switch op {
      case .Gt, .Increased:
        return a > b
      case .Lt, .Decreased:
        return a < b
      }
    }
  }
  return false
}
