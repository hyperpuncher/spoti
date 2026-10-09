#+build linux, darwin
package main

import c "core:c/libc"

foreign import backtrace_libc "system:c"

// execinfo backtraces exist in glibc and macOS libSystem. Windows has no
// equivalent symbol, so it gets a stub in backtrace_windows.odin.
@(default_calling_convention = "c")
foreign backtrace_libc {
	backtrace :: proc(buffer: [^]rawptr, size: c.int) -> c.int ---
	backtrace_symbols :: proc(buffer: [^]rawptr, size: c.int) -> [^]cstring ---
}
