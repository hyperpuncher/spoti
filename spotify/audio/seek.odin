package audio

import diagnostic "../../diagnostic"
import http "../http"
import "core:c"
import "core:crypto"
import "core:fmt"
import "core:math"
import "core:sync"
import stb "vendor:stb/vorbis"

SPOTIFY_OGG_OFFSET :: 0xa7
RANGE_SIZE :: 64 * 1024
MAX_OGG_PAGE_BYTES :: 65307
SEEK_PREROLL_SECONDS :: 4

// Keep one decrypted range and one bounded decoder input buffer.
// stb owns the planar PCM frame; it remains valid until the next decode.
Seek_Stream :: struct {
	url:                                   string,
	key:                                   [16]u8,
	cancel:                                ^bool,
	handle:                                ^stb.vorbis,
	sample_rate, channels:                 int,
	duration_ms:                           int,
	size, position, cache_offset:          int,
	cache:                                 [dynamic]u8,
	input:                                 []u8,
	input_first, input_count:              int,
	total_frames, pcm_position:            int,
	output:                                [^]^f32,
	frame_first, frame_count, frame_start: int,
	failed, sync_needed:                   bool,
	file_id:                               [20]u8,
	disk:                                  Disk_Cache,
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

// A failed or cancelled read is not EOF. Every decoder loop must either
// consume input, fetch more bytes, or return.
read_seek_bytes :: proc(s: ^Seek_Stream, buffer: []u8) -> int {
	if s.failed || (s.cancel != nil && sync.atomic_load(s.cancel)) {s.failed = true; return -1}
	copied := 0
	for copied < len(buffer) && s.position < s.size - SPOTIFY_OGG_OFFSET {
		absolute := s.position + SPOTIFY_OGG_OFFSET
		if absolute < s.cache_offset || absolute >= s.cache_offset + len(s.cache) {
			if !load_seek_range(s, absolute / RANGE_SIZE * RANGE_SIZE) {return -1}
		}
		index := absolute - s.cache_offset
		length := min(len(buffer) - copied, len(s.cache) - index)
		copy(buffer[copied:copied + length], s.cache[index:index + length])
		s.position += length
		copied += length
	}
	return copied
}

reset_seek_input :: proc(s: ^Seek_Stream, position: int) {
	s.input_first, s.input_count, s.position = 0, 0, position
	s.frame_first, s.frame_count = 0, 0
}

fill_seek_input :: proc(s: ^Seek_Stream) -> bool {
	if s.input_count == len(s.input) {s.failed = true; return false}
	copy(s.input, s.input[s.input_first:s.input_first + s.input_count])
	s.input_first = 0
	count := read_seek_bytes(s, s.input[s.input_count:min(s.input_count + 8192, len(s.input))])
	if count < 0 {return false}
	s.input_count += count
	return count > 0
}

restart_seek_decoder :: proc(s: ^Seek_Stream) -> bool {
	if s.handle != nil {stb.close(s.handle); s.handle = nil}
	reset_seek_input(s, 0)
	for fill_seek_input(s) {
		used: c.int
		error: stb.Error
		s.handle = stb.open_pushdata(raw_data(s.input), c.int(s.input_count), &used, &error, nil)
		if s.handle != nil {
			info := stb.get_info(s.handle)
			s.sample_rate, s.channels = int(info.sample_rate), int(info.channels)
			if s.sample_rate <= 0 ||
			   (s.channels != 1 && s.channels != 2) {s.failed = true; return false}
			s.input_first, s.input_count = int(used), s.input_count - int(used)
			s.pcm_position, s.sync_needed = 0, false
			return true
		}
		if error != .need_more_data {s.failed = true; return false}
	}
	return false
}

// Scanning and decoding use the same input and error handling. Channels
// come from get_info; the push API does not need to return them again.
push_seek_input :: proc(s: ^Seek_Stream) -> (used, samples: int) {
	count: c.int
	used = int(
		stb.decode_frame_pushdata(
			s.handle,
			raw_data(s.input[s.input_first:]),
			c.int(s.input_count),
			nil,
			&s.output,
			&count,
		),
	)
	s.input_first += used
	s.input_count -= used
	error := stb.Error(stb.get_error(s.handle))
	if error != .none && error != .need_more_data {s.failed = true; return used, -1}
	return used, int(count)
}

// Use stb's CRC-checked page scanner, not an application-owned Ogg parser.
probe_seek_page :: proc(s: ^Seek_Stream, position: int) -> int {
	stb.flush_pushdata(s.handle)
	s.sync_needed = true
	reset_seek_input(s, position)
	padded := false
	for {
		used, samples := push_seek_input(s)
		if samples < 0 {return -1}
		if sample := stb.get_sample_offset(s.handle); sample >= 0 {
			if padded {s.input_count -= 3}
			return int(sample)
		}
		if used == 0 && !fill_seek_input(s) {
			if s.failed || padded {return -1}
			// The scanner needs three lookahead bytes to finish the CRC at
			// EOF. Do not count them as file data or pass them to decoding.
			for &value in s.input[s.input_count:s.input_count + 3] {value = 0}
			s.input_count += 3
			padded = true
		}
	}
}

read_seek_frame :: proc(s: ^Seek_Stream) -> bool {
	for {
		used, samples := push_seek_input(s)
		if samples < 0 {return false}
		if samples > 0 {
			s.frame_first, s.frame_count = 0, samples
			s.frame_start = int(stb.get_sample_offset(s.handle)) - samples
			if s.sync_needed {
				// Short/long block transitions can make the first page's
				// running offset inaccurate after a flush. Its final packet
				// restores the exact granule position.
				if s.input_count < 4 &&
				   s.position < s.size - SPOTIFY_OGG_OFFSET {_ = fill_seek_input(s)}
				if s.failed {return false}
				boundary :=
					s.position - s.input_count == s.size - SPOTIFY_OGG_OFFSET ||
					s.input_count >= 4 &&
						string(s.input[s.input_first:s.input_first + 4]) == "OggS"
				if !boundary {continue}
				s.sync_needed = false
			}
			return true
		}
		if used == 0 && !fill_seek_input(s) {return false}
	}
}

probe_seek_sample :: proc(s: ^Seek_Stream, position: int) -> int {
	if probe_seek_page(s, position) < 0 || !read_seek_frame(s) {return -1}
	return s.frame_start + s.frame_count
}

open_seek_stream :: proc(s: ^Seek_Stream) -> bool {
	if s.disk.path == "" {s.disk = open_disk_cache(s.file_id)}
	if s.size == 0 && !load_seek_range(s, 0) {return false}
	if s.input == nil {s.input = make([]u8, RANGE_SIZE)}
	if !restart_seek_decoder(s) {return false}
	// A complete final page fits in this tail window. Scan each complete
	// page to obtain the exact final granule without fetching the track.
	last_end := max(0, s.size - SPOTIFY_OGG_OFFSET - MAX_OGG_PAGE_BYTES)
	s.total_frames = -1
	for {
		position := probe_seek_page(s, last_end)
		if position < 0 {break}
		s.total_frames = position
		last_end = s.position - s.input_count
	}
	end := s.size - SPOTIFY_OGG_OFFSET
	if s.failed {return false}
	if s.total_frames < 0 || last_end != end {
		if s.duration_ms <= 0 || s.sample_rate <= 0 {return false}
		expected := s.duration_ms * s.sample_rate / 1000
		if s.total_frames < 0 {
			s.total_frames = expected
		} else if abs(s.total_frames - expected) > 2 * s.sample_rate {
			return false
		}
		diagnostic.writef(
			"audio tail fallback frames=%d last_end=%d end=%d duration_ms=%d",
			s.total_frames,
			last_end,
			end,
			s.duration_ms,
		)
	}
	return restart_seek_decoder(s)
}

close_seek_stream :: proc(s: ^Seek_Stream) {
	if s.handle != nil {stb.close(s.handle); s.handle = nil}
	close_disk_cache(&s.disk)
	crypto.zero_explicit(&s.key, size_of(s.key))
	if len(s.cache) > 0 {crypto.zero_explicit(raw_data(s.cache), len(s.cache))}
	if len(s.input) > 0 {crypto.zero_explicit(raw_data(s.input), len(s.input))}
	delete(s.cache)
	delete(s.input)
	s.cache, s.input = nil, nil
}

seek_to_ms :: proc(s: ^Seek_Stream, position_ms: int) -> bool {
	if s.handle == nil ||
	   s.failed ||
	   s.sample_rate <= 0 ||
	   position_ms < 0 ||
	   position_ms > s.total_frames * 1000 / s.sample_rate ||
	   (s.cancel != nil && sync.atomic_load(s.cancel)) {return false}
	target := position_ms * s.sample_rate / 1000
	if target == s.total_frames {
		s.frame_first, s.frame_count, s.pcm_position = 0, 0, target
		return true
	}
	lo, hi := 0, s.size - SPOTIFY_OGG_OFFSET
	if target <= s.sample_rate {hi = 0}
	positioned := false
	for attempt := 0; hi - lo > RANGE_SIZE; attempt += 1 {
		mid := lo + (hi - lo) / 2
		if attempt == 0 {
			// Allow page recovery before the target. This is only an
			// estimate; exact positions and binary search handle VBR.
			ratio := clamp(
				f64(target - SEEK_PREROLL_SECONDS * s.sample_rate) / f64(s.total_frames),
				0.01,
				0.99,
			)
			mid = lo + int(f64(hi - lo) * ratio)
		}
		position := probe_seek_sample(s, mid)
		if position < 0 {
			if s.failed {return false}
			hi, positioned = mid, false
			continue
		}
		positioned = position <= target
		if positioned {
			lo = mid
			if target - position <= SEEK_PREROLL_SECONDS * s.sample_rate {break}
		} else {hi = mid}
	}
	if lo == 0 {
		if !restart_seek_decoder(s) {return false}
	} else if !positioned && probe_seek_sample(s, lo) < 0 {return false}
	for read_seek_frame(s) {
		if s.frame_start > target {return false}
		if s.frame_start + s.frame_count > target {
			s.frame_first = target - s.frame_start
			s.pcm_position = target
			return true
		}
	}
	return false
}

read_seek_pcm :: proc(s: ^Seek_Stream, dst: []i16) -> (frames: int, ok: bool) {
	if s.handle == nil ||
	   len(dst) == 0 ||
	   len(dst) % 2 != 0 ||
	   s.failed ||
	   (s.cancel != nil && sync.atomic_load(s.cancel)) {return 0, false}
	for frames < len(dst) / 2 && s.pcm_position < s.total_frames {
		if s.frame_first == s.frame_count && !read_seek_frame(s) {s.failed = true; return 0, false}
		count := min(s.frame_count - s.frame_first, len(dst) / 2 - frames)
		for i in 0 ..< count {
			for channel in 0 ..< 2 {
				sample := ([^]f32)(s.output[min(channel, s.channels - 1)])[s.frame_first + i]
				dst[(frames + i) * 2 + channel] = i16(
					clamp(math.round(sample * 32768), -32768, 32767),
				)
			}
		}
		s.frame_first += count
		s.pcm_position += count
		frames += count
	}
	return frames, true
}

seek_frame_position :: proc(s: ^Seek_Stream) -> int {
	return s.pcm_position
}
