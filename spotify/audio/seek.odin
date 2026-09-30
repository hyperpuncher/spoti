package audio

import http "../http"
import "base:runtime"
import c "core:c/libc"
import "core:crypto"
import "core:fmt"
import "core:mem"
import "core:sync"

SPOTIFY_OGG_OFFSET :: 0xa7
RANGE_SIZE :: 64 * 1024

foreign import vorbisfile {"../../build/vorbisfile.a", "system:vorbisfile"}
Vorbis_File :: struct {}
Vorbis_Callbacks :: struct {
	read:  proc "c" (_: rawptr, _: c.size_t, _: c.size_t, _: rawptr) -> c.size_t,
	seek:  proc "c" (_: rawptr, _: i64, _: c.int) -> c.int,
	close: proc "c" (_: rawptr) -> c.int,
	tell:  proc "c" (_: rawptr) -> c.long,
}
@(default_calling_convention = "c")
foreign vorbisfile {
	spoti_vorbis_open :: proc(_: rawptr, _: Vorbis_Callbacks) -> ^Vorbis_File ---
	spoti_vorbis_close :: proc(_: ^Vorbis_File) ---
	spoti_vorbis_rate :: proc(_: ^Vorbis_File) -> c.int ---
	spoti_vorbis_read :: proc(_: ^Vorbis_File, _: [^]i16, _: c.int) -> c.int ---
	ov_pcm_seek :: proc(_: ^Vorbis_File, _: i64) -> c.int ---
	ov_pcm_tell :: proc(_: ^Vorbis_File) -> i64 ---
}

// Must not move after opening: libvorbisfile borrows this address for callbacks.
// Only one decrypted 64-KiB range is retained, regardless of file/seek size.
Seek_Stream :: struct {
	url:                          string,
	key:                          [16]u8,
	cancel:                       ^bool,
	handle:                       ^Vorbis_File,
	sample_rate:                  int,
	size, position, cache_offset: int,
	cache:                        [dynamic]u8,
	failed:                       bool,
	allocator:                    mem.Allocator,
	file_id:                      [20]u8,
	disk:                         Disk_Cache,
}

load_seek_range :: proc(s: ^Seek_Stream, start: int) -> bool {
	if s.cancel != nil && sync.atomic_load(s.cancel) {s.failed = true; return false}
	end := start + RANGE_SIZE - 1
	if s.size > 0 {end = min(end, s.size - 1)}
	if bytes, found := read_disk_range(&s.disk, start); found {
		defer delete(bytes)
		info := http.Range_Info {
			start = start,
			end   = start + len(bytes) - 1,
			total = s.disk.total,
			valid = true,
		}
		return cache_seek_range(s, start, end, info, &bytes)
	}
	range := fmt.aprintf("%d-%d", start, end)
	defer delete(range)
	info: http.Range_Info
	bytes, status, ok := http.get(
		s.url,
		{range = range, limit = RANGE_SIZE, range_info = &info, cancel = s.cancel},
	)
	defer delete(bytes)
	if !ok || status != 206 || (s.cancel != nil && sync.atomic_load(s.cancel)) {
		s.failed = true
		return false
	}
	return cache_seek_range(s, start, end, info, &bytes)
}

// Validate range identity/length before transferring and decrypting the buffer.
cache_seek_range :: proc(
	s: ^Seek_Stream,
	start, end: int,
	info: http.Range_Info,
	bytes: ^[dynamic]u8,
) -> bool {
	if !info.valid ||
	   info.start != start ||
	   info.end != min(end, info.total - 1) ||
	   len(bytes^) != info.end - start + 1 ||
	   len(bytes^) > RANGE_SIZE ||
	   info.total <= SPOTIFY_OGG_OFFSET ||
	   (s.size > 0 && info.total != s.size) ||
	   (s.cancel != nil && sync.atomic_load(s.cancel)) {
		s.failed = true
		return false
	}
	write_disk_range(&s.disk, start, info.total, bytes^[:])
	if len(s.cache) > 0 {crypto.zero_explicit(raw_data(s.cache), len(s.cache))}
	delete(s.cache)
	s.cache = bytes^
	bytes^ = nil
	s.cache_offset, s.size = start, info.total
	decryptor := init(s.key, start)
	defer reset(&decryptor)
	process(&decryptor, s.cache[:])
	return true
}

seek_read :: proc "c" (dst: rawptr, size, count: c.size_t, source: rawptr) -> c.size_t {
	context = runtime.default_context()
	s := (^Seek_Stream)(source)
	context.allocator = s.allocator
	if size == 0 || count == 0 || count > c.size_t(max(int)) / size {return 0}
	buffer := ([^]u8)(dst)[:int(size * count)]
	copied := 0
	for copied < len(buffer) && s.position < s.size - SPOTIFY_OGG_OFFSET {
		if s.cancel != nil && sync.atomic_load(s.cancel) {s.failed = true; break}
		absolute := s.position + SPOTIFY_OGG_OFFSET
		if absolute < s.cache_offset || absolute >= s.cache_offset + len(s.cache) {
			if !load_seek_range(s, absolute / RANGE_SIZE * RANGE_SIZE) {break}
		}
		index := absolute - s.cache_offset
		length := min(len(buffer) - copied, len(s.cache) - index)
		copy(buffer[copied:copied + length], s.cache[index:index + length])
		s.position += length
		copied += length
	}
	return c.size_t(copied) / size
}

seek_position :: proc "c" (source: rawptr, offset: i64, whence: c.int) -> c.int {
	context = runtime.default_context()
	s := (^Seek_Stream)(source)
	length := s.size - SPOTIFY_OGG_OFFSET
	base: int
	switch whence {
	case 0:
		base = 0
	case 1:
		base = s.position
	case 2:
		base = length
	case:
		return -1
	}
	if offset < -i64(base) || offset > i64(length - base) {return -1}
	s.position = base + int(offset)
	return 0
}

seek_tell :: proc "c" (source: rawptr) -> c.long {
	return c.long((^Seek_Stream)(source).position)
}

open_seek_stream :: proc(s: ^Seek_Stream) -> bool {
	s.allocator = context.allocator
	if s.disk.path == "" {s.disk = open_disk_cache(s.file_id)}
	if s.size == 0 && !load_seek_range(s, 0) {return false}
	s.handle = spoti_vorbis_open(s, {read = seek_read, seek = seek_position, tell = seek_tell})
	if s.handle == nil || s.failed {return false}
	s.sample_rate = int(spoti_vorbis_rate(s.handle))
	return true
}

close_seek_stream :: proc(s: ^Seek_Stream) {
	if s.handle != nil {spoti_vorbis_close(s.handle); s.handle = nil}
	close_disk_cache(&s.disk)
	crypto.zero_explicit(&s.key, size_of(s.key))
	if len(s.cache) > 0 {crypto.zero_explicit(raw_data(s.cache), len(s.cache))}
	delete(s.cache)
	s.cache = nil
}

seek_to_ms :: proc(s: ^Seek_Stream, position_ms: int) -> bool {
	return(
		position_ms >= 0 &&
		ov_pcm_seek(s.handle, i64(position_ms) * i64(s.sample_rate) / 1000) == 0 &&
		!s.failed \
	)
}

read_seek_pcm :: proc(s: ^Seek_Stream, dst: []i16) -> (frames: int, ok: bool) {
	if len(dst) == 0 || len(dst) % 2 != 0 {return 0, false}
	for frames < len(dst) / 2 {
		count := spoti_vorbis_read(s.handle, &dst[frames * 2], c.int(len(dst) / 2 - frames))
		if count < 0 || s.failed {return 0, false}
		if count == 0 {break}
		frames += int(count)
	}
	return frames, true
}

seek_frame_position :: proc(s: ^Seek_Stream) -> int {
	return int(ov_pcm_tell(s.handle))
}
