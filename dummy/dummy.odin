package dummy

import "core:fmt"
import "core:os"

@(rodata)
some_string_ro := "STRING RO DATA"

global_string := "global string"
global_i32: i32 = 69
global_i64: i64 = 69
global_pointer: ^i64 = &global_i64

main :: proc() {
  stack_string := "stack string"
  stack_i32: i32 = 69
  stack_i64: i64 = 69
  stack_pointer: ^i64 = &stack_i64

  buf: [32]byte
  fmt.println("PRESS ANY KEY TO EXIT")
  _, _ = os.read(os.stdin, buf[:])
}
