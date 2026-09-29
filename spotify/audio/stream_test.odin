package audio

import "core:os"
import "core:testing"

@(test)
spotify_header_and_encrypted_chunks_feed_stream_decoder :: proc(t: ^testing.T) {
	ogg, err := os.read_entire_file("spotify/audio/testdata/tone.ogg", context.allocator)
	testing.expect(t, err == nil)
	if err != nil {return}
	defer delete(ogg)
	file := make([]u8, SPOTIFY_OGG_OFFSET + len(ogg))
	defer delete(file)
	copy(file[SPOTIFY_OGG_OFFSET:], ogg)
	key: [16]u8
	for i in 0 ..< 16 {key[i] = u8(i)}
	encrypt := init(key)
	process(&encrypt, file)
	reset(&encrypt)
	stream := new_stream("", key)
	defer close_stream(&stream)
	for start := 0; start < len(file); start += 79 {
		if !consume_range(&stream, file[start:min(start + 79, len(file))]) {
			testing.expect(t, false, "decryption and Ogg streaming failed")
			return
		}
	}
	testing.expect(t, stream.skip == 0 && stream.decoder.sample_rate == 44100)
	testing.expect(t, len(stream.pcm) > 10000)
}

@(test)
fill_pcm_preserves_remaining_samples_and_pads_eof :: proc(t: ^testing.T) {
	stream := Stream {
		eof = true,
	}
	append(&stream.pcm, 1, 2, 3, 4, 5, 6, 7, 8)
	defer close_stream(&stream)

	first: [4]i16
	frames, ok := fill_pcm(&stream, first[:])
	testing.expect(t, ok && frames == 2)
	for sample, i in first {testing.expect_value(t, sample, i16(i + 1))}
	testing.expect_value(t, len(stream.pcm), 4)

	last: [8]i16 = 99
	frames, ok = fill_pcm(&stream, last[:])
	testing.expect(t, ok && frames == 2)
	for sample, i in last {testing.expect_value(t, sample, i < 4 ? i16(i + 5) : 0)}
	testing.expect_value(t, len(stream.pcm), 0)

	frames, ok = fill_pcm(&stream, first[:])
	testing.expect(t, ok && frames == 0 && first == 0)
}
