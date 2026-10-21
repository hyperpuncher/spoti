package audio

import http "../http"
import c "core:c/libc"
import "core:os"
import "core:testing"

@(test)
complete_encrypted_disk_cache_decodes_without_a_cdn_url :: proc(t: ^testing.T) {
	dir, dir_err := os.make_directory_temp("/tmp", "spoti-cached-playback-*", context.allocator)
	testing.expect(t, dir_err == nil)
	if dir_err != nil {return}
	defer {_ = os.remove_all(dir); delete(dir)}
	ogg, err := os.read_entire_file("spotify/audio/testdata/tone.ogg", context.allocator)
	testing.expect(t, err == nil)
	if err != nil {return}
	defer delete(ogg)
	ciphertext := make([]u8, SPOTIFY_OGG_OFFSET + len(ogg))
	defer delete(ciphertext)
	copy(ciphertext[SPOTIFY_OGG_OFFSET:], ogg)
	key: [16]u8
	key[0] = 17
	cipher := init(key)
	process(&cipher, ciphertext)
	reset(&cipher)
	id: [20]u8
	id[0] = 19
	disk := open_disk_cache(id, dir)
	write_disk_range(&disk, 0, len(ciphertext), ciphertext)
	close_disk_cache(&disk)
	media := Seek_Stream {
		key  = key,
		disk = open_disk_cache(id, dir),
	}
	defer close_seek_stream(&media)
	opened := open_seek_stream(&media)
	testing.expect(t, opened, "a complete cache must not require a CDN request")
	if !opened {return}
	testing.expect(t, seek_to_ms(&media, 150))
	pcm: [256]i16
	frames, ok := read_seek_pcm(&media, pcm[:])
	testing.expect(t, ok && frames == 128)
}

@(test)
vorbisfile_seeks_forward_backward_and_to_eof_with_exact_samples :: proc(t: ^testing.T) {
	ogg, err := os.read_entire_file("spotify/audio/testdata/tone.ogg", context.allocator)
	testing.expect(t, err == nil)
	if err != nil {return}
	defer delete(ogg)
	s: Seek_Stream
	// Exercise the real encrypted-file layout and validated range-cache transfer.
	bytes := make([dynamic]u8, SPOTIFY_OGG_OFFSET + len(ogg))
	defer delete(bytes)
	copy(bytes[SPOTIFY_OGG_OFFSET:], ogg)
	cipher := init(s.key)
	process(&cipher, bytes[:])
	reset(&cipher)
	info := http.Range_Info {
		start = 0,
		end   = len(bytes) - 1,
		total = len(bytes),
		valid = true,
	}
	testing.expect(t, cache_seek_range(&s, 0, RANGE_SIZE - 1, info, &bytes))
	defer close_seek_stream(&s)
	opened := open_seek_stream(&s)
	testing.expect(t, opened)
	if !opened {return}
	testing.expect_value(t, s.sample_rate, 44100)
	baseline := make([]i16, 44100 * 2)
	defer delete(baseline)
	frames, ok := read_seek_pcm(&s, baseline)
	testing.expect(t, ok && frames == 13230)
	for target in ([]int{0, 150, 250, 30, 299}) {
		testing.expect(t, seek_to_ms(&s, target))
		position := target * s.sample_rate / 1000
		testing.expect_value(t, seek_frame_position(&s), position)
		pcm: [256]i16
		count, valid := read_seek_pcm(&s, pcm[:])
		testing.expect(t, valid && count == min(128, frames - position))
		for sample, i in pcm[:count * 2] {
			testing.expect_value(t, sample, baseline[position * 2 + i])
		}
	}
	testing.expect(t, seek_to_ms(&s, 300))
	pcm: [256]i16
	count, valid := read_seek_pcm(&s, pcm[:])
	testing.expect(t, valid && count == 0)
	testing.expect(t, !seek_to_ms(&s, -1))
	testing.expect(t, !seek_to_ms(&s, 1000))
}

@(test)
arbitrary_ctr_offsets_match_sequential_decryption :: proc(t: ^testing.T) {
	key: [16]u8
	for &value, i in key {value = u8(i)}
	plain: [4097]u8
	for &value, i in plain {value = u8(i % 251)}
	encrypted := plain
	cipher := init(key)
	process(&cipher, encrypted[:])
	reset(&cipher)
	for start in ([]int{0, 1, 15, 16, 17, 167, 255, 2051, 4095}) {
		part := encrypted
		cipher = init(key, start)
		process(&cipher, part[start:])
		reset(&cipher)
		for value, i in part[start:] {testing.expect_value(t, value, plain[start + i])}
	}
}

@(test)
range_cache_rejects_wrong_offsets_truncation_and_changed_file_size :: proc(t: ^testing.T) {
	for info, index in ([]http.Range_Info{{start = 1, end = 15, total = 1000, valid = true}, {start = 0, end = 15, total = 1000, valid = true}, {start = 0, end = 15, total = 1001, valid = true}}) {
		s := Seek_Stream {
			size = 1000,
		}
		length := index == 1 ? 15 : 16
		bytes := make([dynamic]u8, length)
		defer delete(bytes)
		testing.expect(t, !cache_seek_range(&s, 0, 15, info, &bytes))
		testing.expect(t, s.failed && len(s.cache) == 0 && len(bytes) == length)
	}
}

@(test)
seek_callbacks_reject_out_of_bounds_offsets :: proc(t: ^testing.T) {
	s := Seek_Stream {
		size     = SPOTIFY_OGG_OFFSET + 100,
		position = 25,
	}
	testing.expect_value(t, seek_position(&s, -1, 0), c.int(-1))
	testing.expect_value(t, seek_position(&s, 101, 0), c.int(-1))
	testing.expect_value(t, seek_position(&s, max(i64), 1), c.int(-1))
	testing.expect_value(t, s.position, 25)
	testing.expect_value(t, seek_position(&s, -10, 2), c.int(0))
	testing.expect_value(t, s.position, 90)
}

@(test)
read_errors_reach_vorbisfile_but_clean_eof_does_not :: proc(t: ^testing.T) {
	buffer: [8]u8
	size := SPOTIFY_OGG_OFFSET + 100
	failed := Seek_Stream {
		size   = size,
		failed = true,
	}
	c.errno()^ = 0
	testing.expect_value(t, seek_read(&buffer, 1, len(buffer), &failed), c.size_t(0))
	testing.expect(t, c.errno()^ != 0, "a failed range must abort libvorbisfile")

	cancel := true
	cancelled := Seek_Stream {
		size   = size,
		cancel = &cancel,
	}
	c.errno()^ = 0
	testing.expect_value(t, seek_read(&buffer, 1, len(buffer), &cancelled), c.size_t(0))
	testing.expect(t, c.errno()^ != 0, "cancellation must abort libvorbisfile")

	eof := Seek_Stream {
		size     = size,
		position = size - SPOTIFY_OGG_OFFSET,
	}
	c.errno()^ = 0
	testing.expect_value(t, seek_read(&buffer, 1, len(buffer), &eof), c.size_t(0))
	testing.expect_value(t, c.errno()^, 0)
}
