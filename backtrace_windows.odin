package main

import c "core:c/libc"

// Windows has no execinfo backtrace; the Clay error still logs, just
// without the trace. Signatures match backtrace_unix.odin.
backtrace :: proc(buffer: [^]rawptr, size: c.int) -> c.int {return 0}
backtrace_symbols :: proc(buffer: [^]rawptr, size: c.int) -> [^]cstring {return nil}
