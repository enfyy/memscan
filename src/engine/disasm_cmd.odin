package engine

import "core:fmt"
import "core:strings"

// ===========================================================================
// Disassembly / code-recon CLI commands (generic; any process). The decoder
// itself lives in engine/disasm.odin; these are the REPL wrappers.
// ===========================================================================

// func <addr> -> find the enclosing function (scan back to the start after int3 padding) and
// disassemble the whole thing. Painless way to read a function you landed inside via codescan.
cmd_func :: proc(session: ^Session, args: []string) {
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
cmd_disasmtest :: proc() {
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
cmd_disasm :: proc(session: ^Session, args: []string) {
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

cmd_codescan :: proc(session: ^Session, args: []string) {
  if !session.attached {
    fmt.eprintln("not attached.")
    return
  }
  if len(args) < 1 {
    fmt.eprintln("usage: codescan <u32>   |   codescan call <addr>   |   codescan xref <rva>")
    return
  }
  handle := session.proc_info.handle
  base := session.proc_info.base
  hits: [dynamic]uintptr
  if args[0] == "call" {
    if len(args) < 2 {
      fmt.eprintln("usage: codescan call <addr>")
      return
    }
    dest, dok := parse_addr(args[1])
    if !dok {
      fmt.eprintfln("invalid address: %s", args[1])
      return
    }
    hits = codescan_calls(handle, dest, context.temp_allocator)
    fmt.printfln("codescan call 0x%X: %d site(s)", dest, len(hits))
  } else if args[0] == "xref" {
    // Find code that references a base-relative global (e.g. the world at world_rva). Resolves
    // base+rva at runtime so no manual base math even when the module rebases.
    if len(args) < 2 {
      fmt.eprintln("usage: codescan xref <rva>   (e.g. codescan xref 0x5888DC for the world global)")
      return
    }
    rva, rok := parse_addr(args[1])
    if !rok {
      fmt.eprintfln("invalid rva: %s", args[1])
      return
    }
    target := base + rva
    hits = codescan_u32(handle, u32(target), context.temp_allocator)
    fmt.printfln("codescan xref Neuz.exe+0x%X (abs 0x%X): %d hit(s)", rva, target, len(hits))
  } else {
    v, vok := parse_addr(args[0])
    if !vok {
      fmt.eprintfln("invalid value: %s", args[0])
      return
    }
    hits = codescan_u32(handle, u32(v), context.temp_allocator)
    fmt.printfln("codescan 0x%X: %d hit(s)", u32(v), len(hits))
  }
  shown := 0
  for h in hits {
    if shown >= 32 {
      fmt.printfln("  ... (%d more)", len(hits) - shown)
      break
    }
    wb: [20]byte
    rn, _ := read_into(handle, h - 4, wb[:])
    sb := strings.builder_make(context.temp_allocator)
    for i in 0 ..< int(rn) {
      if i == 4 {
        fmt.sbprint(&sb, "| ") // marker: bytes at/after the hit
      }
      fmt.sbprintf(&sb, "%02X ", wb[i])
    }
    fmt.printfln("  0x%X (Neuz.exe+0x%X)  %s", h, h - base, strings.to_string(sb))
    shown += 1
  }
}
