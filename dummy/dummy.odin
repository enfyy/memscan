package dummy

import "core:fmt"
import "core:os"

@(rodata)
some_string_ro := "STRING RO DATA"

global_string := "global string"
global_i32: i32 = 69
global_i64: i64 = 69
second_global_i64: i64 = 42
global_pointer: ^i64 = &global_i64

main :: proc() {
  stack_string := "stack string"
  stack_i32: i32 = 71
  stack_i64: i64 = 71
  stack_pointer: ^i64 = &stack_i64
  global_i32 = 72
  global_i64 = 72

  buf: [32]byte
  fmt.println("PRESS ANY KEY TO EDIT VALUES")
  _, _ = os.read(os.stdin, buf[:])
  stack_string = "new stack string"
  stack_i32 = 74
  stack_i64 = 74
  global_i32 = 75
  global_i64 = 75
  global_pointer = &second_global_i64
  stack_pointer = &global_i64

  fmt.println("PRESS ANY KEY TO EXIT")
  _, _ = os.read(os.stdin, buf[:])
}
