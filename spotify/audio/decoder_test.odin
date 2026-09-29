package audio

import "core:os"
import "core:testing"

@(test)
vorbis_push_decoder_handles_split_ogg_pages :: proc(t: ^testing.T) {
	// Generated sine wave: ffmpeg -f lavfi -i sine=frequency=440:sample_rate=44100
	// -t 0.3 -ac 2 -c:a libvorbis -q:a 4 tone.ogg
	file, err := os.read_entire_file("spotify/audio/testdata/tone.ogg", context.allocator)
	testing.expect(t, err == nil)
	if err != nil {return}
	defer delete(file)
	decoder: Decoder
	defer close_decoder(&decoder)
	pcm := make([dynamic]i16)
	defer delete(pcm)
	for start := 0; start < len(file); start += 37 {
		end := min(len(file), start + 37)
		if !decode_chunk(&decoder, file[start:end], &pcm) {
			testing.expect(t, false, "push decoder rejected a valid Ogg stream")
			return
		}
	}
	testing.expect(t, decoder.handle != nil && decoder.sample_rate == 44100)
	testing.expect(t, len(pcm) > 10000 && len(pcm) < 40000)
}
