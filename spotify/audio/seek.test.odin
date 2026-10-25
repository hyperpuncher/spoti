package audio

import http "../http"
import "core:os"
import "core:testing"

@(test)
cached_audio_seeks_to_exact_samples :: proc(t: ^testing.T) {
	for fixture in ([]struct {
			path:                   string,
			rate, channels, frames: int,
			targets_ms:             []int,
		}{{"spotify/audio/testdata/tone.ogg", 44100, 2, 13230, {0, 150, 250, 30, 299, 300}}, {"spotify/audio/testdata/mono-96.ogg", 32000, 1, 1440000, {0, 31000, 11471, 44999, 1200, 42000, 1, 45000}}}) {
		dir, dir_err := os.make_directory_temp("", "spoti-cached-playback-*", context.allocator)
		if !testing.expect(t, dir_err == nil) {return}
		defer {_ = os.remove_all(dir); delete(dir)}
		ogg, err := os.read_entire_file(fixture.path, context.allocator)
		if !testing.expect(t, err == nil) {return}
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
		for start := 0; start < len(ciphertext); start += RANGE_SIZE {
			write_disk_range(
				&disk,
				start,
				len(ciphertext),
				ciphertext[start:min(start + RANGE_SIZE, len(ciphertext))],
			)
		}
		close_disk_cache(&disk)
		s := Seek_Stream {
			key  = key,
			disk = open_disk_cache(id, dir),
		}
		defer close_seek_stream(&s)
		if !testing.expect(
			t,
			open_seek_stream(&s),
			"a complete encrypted cache must not require a CDN URL",
		) {return}
		testing.expect_value(t, s.sample_rate, fixture.rate)
		testing.expect_value(t, s.channels, fixture.channels)
		testing.expect_value(t, s.total_frames, fixture.frames)
		baseline := make([]i16, (fixture.frames + 128) * 2)
		defer delete(baseline)
		frames, ok := read_seek_pcm(&s, baseline)
		if !testing.expect(t, ok && frames == fixture.frames) {return}
		for target in fixture.targets_ms {
			if !testing.expect(t, seek_to_ms(&s, target)) {return}
			position := target * s.sample_rate / 1000
			testing.expect_value(t, seek_frame_position(&s), position)
			pcm: [256]i16
			count, valid := read_seek_pcm(&s, pcm[:])
			testing.expect(t, valid && count == min(128, frames - position))
			for sample, i in pcm[:count * 2] {
				testing.expect_value(t, sample, baseline[position * 2 + i])
				if fixture.channels == 1 {testing.expect_value(t, sample, pcm[i / 2 * 2])}
			}
			testing.expect_value(t, seek_frame_position(&s), position + count)
		}
		testing.expect(t, !seek_to_ms(&s, -1))
		testing.expect(t, !seek_to_ms(&s, max(int)))
	}
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
failed_and_cancelled_range_reads_are_not_clean_eof :: proc(t: ^testing.T) {
	buffer: [8]u8
	size := SPOTIFY_OGG_OFFSET + 100
	failed := Seek_Stream {
		size   = size,
		failed = true,
	}
	testing.expect_value(t, read_seek_bytes(&failed, buffer[:]), -1)
	cancel := true
	cancelled := Seek_Stream {
		size   = size,
		cancel = &cancel,
	}
	testing.expect_value(t, read_seek_bytes(&cancelled, buffer[:]), -1)
	testing.expect(t, cancelled.failed)
	eof := Seek_Stream {
		size     = size,
		position = size - SPOTIFY_OGG_OFFSET,
	}
	testing.expect_value(t, read_seek_bytes(&eof, buffer[:]), 0)
	testing.expect(t, !eof.failed)
}

@(test)
corrupt_or_truncated_final_ogg_page_does_not_open :: proc(t: ^testing.T) {
	ogg, err := os.read_entire_file("spotify/audio/testdata/tone.ogg", context.allocator)
	testing.expect(t, err == nil)
	if err != nil {return}
	defer delete(ogg)
	for truncated in ([]bool{false, true}) {
		s: Seek_Stream
		length := len(ogg) - (truncated ? 17 : 0)
		bytes := make([dynamic]u8, SPOTIFY_OGG_OFFSET + length)
		defer delete(bytes)
		copy(bytes[SPOTIFY_OGG_OFFSET:], ogg[:length])
		if !truncated {bytes[len(bytes) - 1] ~= 1}
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
		testing.expect(t, !open_seek_stream(&s))
	}
}
