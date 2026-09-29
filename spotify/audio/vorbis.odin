package audio

import c "core:c/libc"

// Only the streaming (pushdata) stb_vorbis ABI. C decoder source is bundled
// with the installed Odin compiler and built locally by build-vorbis.sh.
foreign import stb "../../build/stb_vorbis.a"

Vorbis :: struct {}
Vorbis_Info :: struct {
	sample_rate:                c.uint,
	channels:                   c.int,
	setup_memory_required:      c.uint,
	setup_temp_memory_required: c.uint,
	temp_memory_required:       c.uint,
	max_frame_size:             c.int,
}

@(default_calling_convention = "c", link_prefix = "stb_vorbis_")
foreign stb {
	open_pushdata :: proc(data: [^]u8, count: c.int, used: ^c.int, err: ^c.int, alloc: rawptr) -> ^Vorbis ---
	decode_frame_pushdata :: proc(v: ^Vorbis, data: [^]u8, count: c.int, channels: ^c.int, samples: ^[^]^f32, frames: ^c.int) -> c.int ---
	get_info :: proc(v: ^Vorbis) -> Vorbis_Info ---
	get_error :: proc(v: ^Vorbis) -> c.int ---
	close :: proc(v: ^Vorbis) ---
}
