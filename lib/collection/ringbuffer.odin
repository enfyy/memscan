package collection

Ring_Buffer :: struct($T: typeid) {
  items:    []T,
  head:     int,
  count:    int,
  capacity: int,
  on_drop:  proc(_: T),
}

Ring_Buffer_Iterator :: struct($T: typeid) {
  buffer: Ring_Buffer(T),
  index:  int,
}

Ring_Buffer_Iterator_Reverse :: struct($T: typeid) {
  buffer: Ring_Buffer(T),
  index:  int,
}

ringbuffer_create :: proc {
  ringbuffer_create_with_buffer,
  ringbuffer_create_with_cap,
}

ringbuffer_create_with_cap :: proc($T: typeid, capacity: int, allocator := context.allocator) -> Ring_Buffer(T) {
  rb := Ring_Buffer(T) {
    capacity = capacity,
    items    = make([]T, capacity, allocator),
  }
  return rb
}

ringbuffer_create_with_buffer :: proc($T: typeid, buffer: []T) -> Ring_Buffer(T) {
  rb := Ring_Buffer(T) {
    capacity = len(buffer),
    items    = buffer,
  }
  return rb
}

ringbuffer_push :: proc(rb: ^Ring_Buffer($T), item: T) {
  if rb.count == 0 {
    rb.head = 0
  }

  replace_index: int
  if rb.count < rb.capacity {
    replace_index = rb.head + 1
    if replace_index == rb.capacity {
      replace_index = 0
    }
  } else {
    replace_index = ringbuffer_tail_index(rb^)
    dropped := rb.items[replace_index]
    if rb.on_drop != nil do rb.on_drop(dropped)
  }

  rb.items[replace_index] = item
  rb.head = replace_index

  if rb.count < rb.capacity {
    rb.count += 1
  }
}

ringbuffer_pop :: proc(rb: ^Ring_Buffer($T)) -> (res: T, ok: bool) #optional_ok {
  if rb == nil || rb.count == 0 do return
  res, ok = ringbuffer_get(rb^, 0)
  rb.count -= 1
  rb.head -= 1
  if rb.head == -1 do rb.head = rb.capacity - 1
  return
}

ringbuffer_get :: proc(rb: Ring_Buffer($T), index: int) -> (res: T, ok: bool) #optional_ok {
  i := ringbuffer_get_index_internal(rb, index) or_return
  return rb.items[i], true
}

ringbuffer_get_ref :: proc(rb: Ring_Buffer($T), index: int) -> (res: ^T, ok: bool) #optional_ok {
  i := ringbuffer_get_index_internal(rb, index) or_return
  return &rb.items[i], true
}

ringbuffer_iterator :: proc(rb: Ring_Buffer($T)) -> Ring_Buffer_Iterator(T) {
  return {buffer = rb, index = -1}
}

ringbuffer_iterate :: proc(it: ^Ring_Buffer_Iterator($T), by_ref := false) -> (val: T, idx: int, cond: bool) {
  it.index += 1
  ok: bool
  val, ok = ringbuffer_get(it.buffer, it.index)
  assert(ok)
  idx = it.index
  cond = idx < it.buffer.count
  return
}

ringbuffer_iterator_reverse :: proc(rb: Ring_Buffer($T)) -> Ring_Buffer_Iterator_Reverse(T) {
  return {buffer = rb}
}

ringbuffer_iterate_reversed :: proc(
  it: ^Ring_Buffer_Iterator_Reverse($T),
  by_ref := false,
) -> (
  val: T,
  idx: int,
  cond: bool,
) {
  idx = it.index
  val, cond = ringbuffer_get(it.buffer, it.buffer.count - 1 - idx)
  if cond do it.index += 1
  return
}

ringbuffer_destroy :: proc(rb: Ring_Buffer($T)) {
  delete(rb.items)
}

@(private)
ringbuffer_get_index_internal :: proc(rb: Ring_Buffer($T), index: int) -> (int, bool) {
  if index < 0 do return 0, false
  if rb.count == 0 do return 0, false

  i := (rb.head + (index % rb.capacity) * -1) % rb.capacity
  if i < 0 {
    i += rb.capacity
  }
  return i, true
}

@(private)
ringbuffer_tail_index :: proc(rb: Ring_Buffer($T)) -> int {
  i, _ := ringbuffer_get_index_internal(rb, rb.count - 1)
  return i
}
