package main

import "core:fmt"
import "core:strings"

// ===========================================================================
// Minimal 32-bit x86 disassembler (read-only static analysis; no debugger).
//
// Goal is not a complete disassembler but: (1) always advance by the correct
// instruction length so the stream stays aligned, and (2) render the instructions
// this reverse-engineering needs in a readable way - call/jmp with resolved
// targets, `mov reg, imm32` (finding globals like g_DPlay), `mov [reg+disp], reg`
// (the m_pObjFocus write), and absolute [disp32] memory refs (the world global).
// Unrecognized opcodes still get a correct length and print as `db`/raw.
// ===========================================================================

R32 := [8]string{"eax", "ecx", "edx", "ebx", "esp", "ebp", "esi", "edi"}
R16 := [8]string{"ax", "cx", "dx", "bx", "sp", "bp", "si", "di"}
R8 := [8]string{"al", "cl", "dl", "bl", "ah", "ch", "dh", "bh"}
CC := [16]string{"o", "no", "b", "ae", "e", "ne", "be", "a", "s", "ns", "p", "np", "l", "ge", "le", "g"}

reg_name :: proc(idx: int, size: int) -> string {
  switch size {
  case 1:
    return R8[idx & 7]
  case 2:
    return R16[idx & 7]
  }
  return R32[idx & 7]
}

rd_u32 :: proc(b: []byte, p: int) -> u32 {
  if p + 4 > len(b) {
    return 0
  }
  return u32(b[p]) | u32(b[p + 1]) << 8 | u32(b[p + 2]) << 16 | u32(b[p + 3]) << 24
}

// Classify a one-byte opcode: does it carry a ModRM byte, and what immediate.
// imm codes: 0 none, 1 ib(1), 2 iw(2), 3 iz(opsize), 4 far ptr(iz+2), 5 enter(3),
// 6 grp3-byte (F6: ib only if reg field 0/1), 7 grp3-z (F7: iz only if reg 0/1).
classify_one :: proc(op: u8) -> (modrm: bool, imm: u8) {
  switch op {
  case 0x00 ..= 0x03, 0x08 ..= 0x0B, 0x10 ..= 0x13, 0x18 ..= 0x1B, 0x20 ..= 0x23, 0x28 ..= 0x2B, 0x30 ..= 0x33, 0x38 ..= 0x3B:
    return true, 0
  case 0x04, 0x0C, 0x14, 0x1C, 0x24, 0x2C, 0x34, 0x3C:
    return false, 1
  case 0x05, 0x0D, 0x15, 0x1D, 0x25, 0x2D, 0x35, 0x3D:
    return false, 3
  case 0x62, 0x63:
    return true, 0
  case 0x68:
    return false, 3
  case 0x69:
    return true, 3
  case 0x6A:
    return false, 1
  case 0x6B:
    return true, 1
  case 0x70 ..= 0x7F:
    return false, 1
  case 0x80, 0x82, 0x83:
    return true, 1
  case 0x81:
    return true, 3
  case 0x84 ..= 0x8F:
    return true, 0
  case 0x90 ..= 0x99, 0x9B ..= 0x9F:
    return false, 0
  case 0x9A:
    return false, 4
  case 0xA0 ..= 0xA3:
    return false, 8 // moffs: 4-byte absolute address (NOT a far pointer)
  case 0xA4 ..= 0xA7, 0xAA ..= 0xAF:
    return false, 0
  case 0xA8:
    return false, 1
  case 0xA9:
    return false, 3
  case 0xB0 ..= 0xB7:
    return false, 1
  case 0xB8 ..= 0xBF:
    return false, 3
  case 0xC0, 0xC1:
    return true, 1
  case 0xC2:
    return false, 2
  case 0xC3, 0xC9, 0xCB, 0xCC, 0xCE, 0xCF:
    return false, 0
  case 0xC4, 0xC5:
    return true, 0
  case 0xC6:
    return true, 1
  case 0xC7:
    return true, 3
  case 0xC8:
    return false, 5
  case 0xCA:
    return false, 2
  case 0xCD:
    return false, 1
  case 0xD0 ..= 0xD3, 0xD8 ..= 0xDF:
    return true, 0
  case 0xD4, 0xD5:
    return false, 1
  case 0xD6, 0xD7:
    return false, 0
  case 0xE0 ..= 0xE7:
    return false, 1
  case 0xE8, 0xE9:
    return false, 3
  case 0xEA:
    return false, 4
  case 0xEB:
    return false, 1
  case 0xEC ..= 0xEF, 0xF1, 0xF4, 0xF5, 0xF8 ..= 0xFD:
    return false, 0
  case 0xF6:
    return true, 6
  case 0xF7:
    return true, 7
  case 0xFE, 0xFF:
    return true, 0
  }
  return false, 0
}

classify_0f :: proc(op: u8) -> (modrm: bool, imm: u8) {
  switch op {
  case 0x80 ..= 0x8F:
    return false, 3 // jcc rel z
  case 0x70 ..= 0x73, 0xA4, 0xAC, 0xBA, 0xC2, 0xC4, 0xC5, 0xC6:
    return true, 1
  case 0xA0 ..= 0xA2, 0xA8 ..= 0xAA, 0xC8 ..= 0xCF:
    return false, 0 // push/pop seg, cpuid, rsm, bswap
  }
  return true, 0 // the vast majority of 0F ops are modrm, no imm
}

// Length of the ModRM byte plus any SIB/displacement (32-bit addressing).
modrm_len :: proc(code: []byte, pos: int) -> int {
  if pos >= len(code) {
    return 1
  }
  m := code[pos]
  mod := m >> 6
  rm := m & 7
  n := 1
  disp := 0
  sib := 0
  if mod == 3 {
    return n
  }
  if rm == 4 {
    sib = 1
    if mod == 0 && pos + 1 < len(code) && (code[pos + 1] & 7) == 5 {
      disp = 4
    }
  }
  switch mod {
  case 0:
    if rm == 5 {
      disp = 4
    }
  case 1:
    disp = 1
  case 2:
    disp = 4
  }
  return n + sib + disp
}

// Build the r/m operand text for a ModRM at `pos` (32-bit addressing). Also returns the
// reg field index and total bytes consumed.
modrm_operand :: proc(code: []byte, pos: int, opsize: int) -> (rm: string, reg: int, used: int) {
  if pos >= len(code) {
    return "?", 0, 1
  }
  m := code[pos]
  mod := int(m >> 6)
  reg = int((m >> 3) & 7)
  rmf := int(m & 7)
  used = modrm_len(code, pos)
  if mod == 3 {
    return reg_name(rmf, opsize), reg, used
  }
  sb := strings.builder_make(context.temp_allocator)
  base_str := ""
  index_str := ""
  disp_at := pos + 1
  if rmf == 4 {
    // SIB
    sib := code[pos + 1] if pos + 1 < len(code) else 0
    scale := 1 << (sib >> 6)
    idx := int((sib >> 3) & 7)
    bse := int(sib & 7)
    disp_at = pos + 2
    if idx != 4 {
      index_str = fmt.tprintf(" + %s*%d", R32[idx], scale)
    }
    if bse == 5 && mod == 0 {
      base_str = "" // pure disp32
    } else {
      base_str = R32[bse]
    }
  } else if rmf == 5 && mod == 0 {
    base_str = "" // [disp32]
  } else {
    base_str = R32[rmf]
  }
  // displacement
  disp: i64 = 0
  has_disp := false
  if rmf == 5 && mod == 0 || (rmf == 4 && mod == 0 && (code[pos + 1] & 7) == 5) {
    disp = i64(rd_u32(code, disp_at))
    has_disp = true
    base_str = "" // absolute
  } else if mod == 1 {
    if disp_at < len(code) {
      disp = i64(i8(code[disp_at]))
    }
    has_disp = true
  } else if mod == 2 {
    disp = i64(i32(rd_u32(code, disp_at)))
    has_disp = true
  }

  fmt.sbprint(&sb, "[")
  if base_str == "" && index_str == "" {
    fmt.sbprintf(&sb, "0x%X", u32(disp))
  } else {
    fmt.sbprint(&sb, base_str)
    fmt.sbprint(&sb, index_str)
    if has_disp && disp != 0 {
      if disp < 0 {
        fmt.sbprintf(&sb, " - 0x%X", u32(-disp))
      } else {
        fmt.sbprintf(&sb, " + 0x%X", u32(disp))
      }
    }
  }
  fmt.sbprint(&sb, "]")
  return strings.to_string(sb), reg, used
}

// Disassemble one instruction from `code` (which starts at address `ip`).
// Returns byte length and rendered text.
disasm_one :: proc(code: []byte, ip: u32) -> (length: int, text: string) {
  if len(code) == 0 {
    return 1, "??"
  }
  i := 0
  opsize := 4
  rep := ""
  lock := ""
  prefix: for i < len(code) {
    switch code[i] {
    case 0x66:
      opsize = 2
      i += 1
    case 0x67, 0x2E, 0x36, 0x3E, 0x26, 0x64, 0x65:
      i += 1
    case 0xF0:
      lock = "lock "
      i += 1
    case 0xF2:
      rep = "repne "
      i += 1
    case 0xF3:
      rep = "rep "
      i += 1
    case:
      break prefix
    }
  }
  if i >= len(code) {
    return i + 1, "??"
  }

  op := code[i]
  i += 1

  // ---- two-byte 0F opcodes (only the ones we care to name; rest generic) ----
  if op == 0x0F {
    if i >= len(code) {
      return i, "0f ??"
    }
    op2 := code[i]
    i += 1
    modrm, imm := classify_0f(op2)
    if op2 >= 0x80 && op2 <= 0x8F {
      rel := i32(rd_u32(code, i))
      i += 4
      tgt := u32(i64(ip) + i64(i) + i64(rel))
      return i, fmt.tprintf("j%s 0x%X", CC[op2 & 0xF], tgt)
    }
    rms, reg, used := "", 0, 0
    if modrm {
      rms, reg, used = modrm_operand(code, i, opsize)
      i += used
    }
    if imm == 1 {i += 1}
    // a few useful names
    switch op2 {
    case 0xB6, 0xB7:
      return i, fmt.tprintf("movzx %s, %s", R32[reg], rms)
    case 0xBE, 0xBF:
      return i, fmt.tprintf("movsx %s, %s", R32[reg], rms)
    case 0xAF:
      return i, fmt.tprintf("imul %s, %s", R32[reg], rms)
    case 0x1F:
      return i, "nop"
    }
    if modrm {
      return i, fmt.tprintf("op0f_%02X %s", op2, rms)
    }
    return i, fmt.tprintf("op0f_%02X", op2)
  }

  // ---- one-byte opcodes ----
  modrm, imm := classify_one(op)
  mpos := i
  rms := ""
  reg := 0
  if modrm {
    used := 0
    rms, reg, used = modrm_operand(code, i, opsize)
    i += used
  }
  imm_at := i
  isz := 0
  switch imm {
  case 1:
    isz = 1
  case 2:
    isz = 2
  case 3:
    isz = opsize
  case 4:
    isz = opsize + 2
  case 5:
    isz = 3
  case 6:
    if modrm && mpos < len(code) && ((code[mpos] >> 3) & 7) <= 1 {isz = 1}
  case 7:
    if modrm && mpos < len(code) && ((code[mpos] >> 3) & 7) <= 1 {isz = opsize}
  case 8:
    isz = 4
  }
  i += isz

  imm_val: i64 = 0
  if isz == 1 {
    imm_val = i64(i8(code[imm_at])) if imm_at < len(code) else 0
  } else if isz == 2 {
    imm_val = i64(u32(code[imm_at]) | u32(code[imm_at + 1]) << 8) if imm_at + 2 <= len(code) else 0
  } else if isz >= 4 {
    imm_val = i64(rd_u32(code, imm_at))
  }

  pre := fmt.tprintf("%s%s", lock, rep)
  switch op {
  case 0x50 ..= 0x57:
    return i, fmt.tprintf("%spush %s", pre, R32[op - 0x50])
  case 0x58 ..= 0x5F:
    return i, fmt.tprintf("%spop %s", pre, R32[op - 0x58])
  case 0x40 ..= 0x47:
    return i, fmt.tprintf("inc %s", R32[op - 0x40])
  case 0x48 ..= 0x4F:
    return i, fmt.tprintf("dec %s", R32[op - 0x48])
  case 0x68:
    return i, fmt.tprintf("push 0x%X", u32(imm_val))
  case 0x6A:
    return i, fmt.tprintf("push 0x%X", u32(imm_val))
  case 0xB8 ..= 0xBF:
    return i, fmt.tprintf("mov %s, 0x%X", R32[op - 0xB8], u32(imm_val))
  case 0xB0 ..= 0xB7:
    return i, fmt.tprintf("mov %s, 0x%X", R8[op - 0xB0], u32(imm_val) & 0xFF)
  case 0x88:
    return i, fmt.tprintf("mov %s, %s", rms, reg_name(reg, 1))
  case 0x89:
    return i, fmt.tprintf("mov %s, %s", rms, R32[reg])
  case 0x8A:
    return i, fmt.tprintf("mov %s, %s", reg_name(reg, 1), rms)
  case 0x8B:
    return i, fmt.tprintf("mov %s, %s", R32[reg], rms)
  case 0x8D:
    return i, fmt.tprintf("lea %s, %s", R32[reg], rms)
  case 0xC6:
    return i, fmt.tprintf("mov %s, 0x%X", rms, u32(imm_val) & 0xFF)
  case 0xC7:
    return i, fmt.tprintf("mov %s, 0x%X", rms, u32(imm_val))
  case 0xA1:
    return i, fmt.tprintf("mov eax, [0x%X]", u32(imm_val))
  case 0xA3:
    return i, fmt.tprintf("mov [0x%X], eax", u32(imm_val))
  case 0xE8:
    return i, fmt.tprintf("call 0x%X", u32(i64(ip) + i64(i) + imm_val))
  case 0xE9:
    return i, fmt.tprintf("jmp 0x%X", u32(i64(ip) + i64(i) + imm_val))
  case 0xEB:
    return i, fmt.tprintf("jmp 0x%X", u32(i64(ip) + i64(i) + imm_val))
  case 0x70 ..= 0x7F:
    return i, fmt.tprintf("j%s 0x%X", CC[op & 0xF], u32(i64(ip) + i64(i) + imm_val))
  case 0xC3:
    return i, "ret"
  case 0xC2:
    return i, fmt.tprintf("ret 0x%X", u32(imm_val) & 0xFFFF)
  case 0xC9:
    return i, "leave"
  case 0xCC:
    return i, "int3"
  case 0x90:
    return i, "nop"
  case 0x84:
    return i, fmt.tprintf("test %s, %s", rms, reg_name(reg, 1))
  case 0x85:
    return i, fmt.tprintf("test %s, %s", rms, R32[reg])
  case 0x3B:
    return i, fmt.tprintf("cmp %s, %s", R32[reg], rms)
  case 0x39:
    return i, fmt.tprintf("cmp %s, %s", rms, R32[reg])
  case 0x83:
    return i, fmt.tprintf("%s %s, 0x%X", grp1_name((code[mpos] >> 3) & 7), rms, u32(imm_val))
  case 0x81:
    return i, fmt.tprintf("%s %s, 0x%X", grp1_name((code[mpos] >> 3) & 7), rms, u32(imm_val))
  case 0xFF:
    sub := (code[mpos] >> 3) & 7
    switch sub {
    case 2:
      return i, fmt.tprintf("call %s", rms)
    case 4:
      return i, fmt.tprintf("jmp %s", rms)
    case 6:
      return i, fmt.tprintf("push %s", rms)
    case 0:
      return i, fmt.tprintf("inc %s", rms)
    case 1:
      return i, fmt.tprintf("dec %s", rms)
    }
    return i, fmt.tprintf("ff/%d %s", sub, rms)
  }

  if modrm {
    return i, fmt.tprintf("op_%02X %s%s", op, rms, isz > 0 ? fmt.tprintf(", 0x%X", u32(imm_val)) : "")
  }
  if isz > 0 {
    return i, fmt.tprintf("op_%02X 0x%X", op, u32(imm_val))
  }
  return i, fmt.tprintf("op_%02X", op)
}

grp1_name :: proc(sub: u8) -> string {
  switch sub {
  case 0:
    return "add"
  case 1:
    return "or"
  case 2:
    return "adc"
  case 3:
    return "sbb"
  case 4:
    return "and"
  case 5:
    return "sub"
  case 6:
    return "xor"
  case 7:
    return "cmp"
  }
  return "?"
}

// func <addr> -> find the enclosing function (scan back to the start after int3 padding) and
// disassemble the whole thing. Painless way to read a function you landed inside via codescan.
cli_func :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: func <addr>")
    return
  }
  addr, ok := resolve_operand(session, args[0])
  if !ok {
    fmt.eprintfln("invalid address: %s", args[0])
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  PRE :: 0x800
  pre := make([]byte, PRE + 16, context.temp_allocator)
  read_into(handle, addr - PRE, pre) // pre[j] is the byte at addr-PRE+j; addr is at index PRE
  // Function start = nearest byte <= addr preceded by >=2 int3 (MSVC inter-function padding).
  start := addr
  for j := PRE; j >= 2; j -= 1 {
    if pre[j - 1] == 0xCC && pre[j - 2] == 0xCC {
      start = addr - PRE + uintptr(j)
      break
    }
  }
  SPAN :: 0x700
  code := make([]byte, SPAN + 16, context.temp_allocator)
  n, rok := read_into(handle, start, code[:SPAN])
  if !rok || n == 0 {
    fmt.eprintfln("read failed at 0x%X", start)
    return
  }
  fmt.printfln("function start 0x%X (Neuz.exe+0x%X):", start, start - base)
  off := 0
  ip := u32(start)
  passed := false
  for k := 0; k < 500 && off < int(n); k += 1 {
    length, text := disasm_one(code[off:], ip + u32(off))
    if length <= 0 {
      length = 1
    }
    a := start + uintptr(off)
    mark := (a <= addr && addr < a + uintptr(length)) ? "  <== focus write" : ""
    sb := strings.builder_make(context.temp_allocator)
    for b in 0 ..< min(length, 8) {
      fmt.sbprintf(&sb, "%02X ", code[off + b])
    }
    fmt.printfln("  +0x%X  %-22s %-30s%s", a - base, strings.to_string(sb), text, mark)
    if a >= addr {
      passed = true
    }
    // stop at the final ret (a ret/ret-imm immediately followed by int3 padding), once past addr
    if passed && (code[off] == 0xC3 || code[off] == 0xC2) && off + length < int(n) && code[off + length] == 0xCC {
      break
    }
    off += length
  }
}

// disasmtest -> decode a hand-built instruction stream with known lengths (offline decoder check).
cli_disasmtest :: proc() {
  // push ebp; mov ebp,esp; mov ecx,0x016688DC; push 2; push 0x11223344; call +5;
  // mov [ecx+0x20],edx; mov eax,[ecx+0x20]; mov eax,[0x016688DC]; mov [ebp-4],0;
  // cmp eax,5; je +5; ret 8; ret; int3   (+ zero padding so the decoder never reads OOB)
  buf := [?]byte {
    0x55,
    0x8B, 0xEC,
    0xB9, 0xDC, 0x88, 0x66, 0x01,
    0x6A, 0x02,
    0x68, 0x44, 0x33, 0x22, 0x11,
    0xE8, 0x00, 0x00, 0x00, 0x00,
    0x89, 0x51, 0x20,
    0x8B, 0x41, 0x20,
    0xA1, 0xDC, 0x88, 0x66, 0x01,
    0xC7, 0x45, 0xFC, 0x00, 0x00, 0x00, 0x00,
    0x83, 0xF8, 0x05,
    0x74, 0x05,
    0xC2, 0x08, 0x00,
    0xC3,
    0xCC,
    0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
  }
  real := 47 // bytes before the padding
  off := 0
  ip := u32(0x401000)
  for off < real {
    length, text := disasm_one(buf[off:], ip + u32(off))
    sb := strings.builder_make(context.temp_allocator)
    for b in 0 ..< length {
      fmt.sbprintf(&sb, "%02X ", buf[off + b])
    }
    fmt.printfln("  0x%X  len=%d  %-16s %s", ip + u32(off), length, strings.to_string(sb), text)
    off += length
  }
}

// disasm <addr> [count]  -> disassemble `count` instructions (default 24) at an absolute address.
cli_disasm :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: disasm <addr> [count]")
    return
  }
  addr, ok := resolve_operand(session, args[0])
  if !ok {
    fmt.eprintfln("invalid address: %s", args[0])
    return
  }
  count := 24
  if len(args) >= 2 {
    if v, vok := parse_addr(args[1]); vok {
      count = int(v)
    }
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  mod_end := base + uintptr(session.proc_info.module_size)
  sz := count * 16 + 16
  buf := make([]byte, sz + 16, context.temp_allocator) // 16-byte zero pad so decode never reads OOB
  n, rok := read_into(handle, addr, buf[:sz])
  if !rok || n == 0 {
    fmt.eprintfln("read failed at 0x%X", addr)
    return
  }
  code := buf
  off := 0
  ip := u32(addr)
  for k := 0; k < count && off < int(n); k += 1 {
    length, text := disasm_one(code[off:], ip + u32(off))
    if length <= 0 {
      length = 1
    }
    // raw bytes column
    sb := strings.builder_make(context.temp_allocator)
    for b in 0 ..< min(length, 8) {
      fmt.sbprintf(&sb, "%02X ", code[off + b])
    }
    a := addr + uintptr(off)
    tag := (a >= base && a < mod_end) ? fmt.tprintf("+0x%X", a - base) : ""
    fmt.printfln("  0x%X %-8s %-22s %s", a, tag, strings.to_string(sb), text)
    off += length
  }
}

