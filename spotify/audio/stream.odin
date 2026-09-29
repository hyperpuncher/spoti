package audio

import http "../http"
import "core:crypto"
import "core:fmt"

// Spotify Vorbis files start with a 167-byte encrypted custom Ogg page. Once
// decrypted, the regular Ogg stream starts at this byte offset.
SPOTIFY_OGG_OFFSET :: 0xa7
RANGE_SIZE :: 64 * 1024

Stream :: struct {
	url:       string, // signed CDN URL, borrowed from the storage response
	decryptor: Decryptor,
	decoder:   Decoder,
	offset:    int,
	skip:      int,
	pcm:       [dynamic]i16,
	eof:       bool,
}

new_stream :: proc(address: string, key: [16]u8) -> Stream {
	return {
		url = address,
		decryptor = init(key),
		skip = SPOTIFY_OGG_OFFSET,
		pcm = make([dynamic]i16),
	}
}

close_stream :: proc(s: ^Stream) {
	reset(&s.decryptor)
	close_decoder(&s.decoder)
	crypto.zero_explicit(raw_data(s.pcm), len(s.pcm) * size_of(i16))
	delete(s.pcm)
}

// Must receive contiguous file ranges in order. Decoding happens entirely in
// RAM; ciphertext never reaches disk or the audio device.
consume_range :: proc(s: ^Stream, ciphertext: []u8) -> bool {
	process(&s.decryptor, ciphertext)
	data := ciphertext
	if s.skip > 0 {
		count := min(s.skip, len(data))
		s.skip -= count
		data = data[count:]
	}
	if len(data) == 0 {return true}
	return decode_chunk(&s.decoder, data, &s.pcm)
}

// GETs one encrypted 64-KiB CDN range, decrypts and decodes it. Spotify's
// signed URLs are never logged, and no account token is forwarded to the CDN.
fetch_range :: proc(s: ^Stream) -> bool {
	if s.eof {return true}
	range := fmt.aprintf("%d-%d", s.offset, s.offset + RANGE_SIZE - 1)
	defer delete(range)
	bytes, status, fetched := http.get(s.url, {range = range, limit = RANGE_SIZE})
	if !fetched {return false}
	defer {
		crypto.zero_explicit(raw_data(bytes), len(bytes))
		delete(bytes)
	}
	if status == 416 {s.eof = true; return true}
	if status != 206 || len(bytes) == 0 || len(bytes) > RANGE_SIZE {return false}
	s.offset += len(bytes)
	if len(bytes) < RANGE_SIZE {s.eof = true}
	return consume_range(s, bytes[:])
}

// Fill one stereo PCM packet, zero-padding only at EOF. This may block
// on CDN requests, so call it on the fetch/decode worker, not the UI thread.
// Returns (frames with audio, ok).
fill_pcm :: proc(s: ^Stream, dst: []i16) -> (frames: int, ok: bool) {
	if len(dst) == 0 || len(dst) % 2 != 0 {return 0, false}
	for len(s.pcm) < len(dst) && !s.eof {
		if !fetch_range(s) {return 0, false}
	}
	available := min(len(dst), len(s.pcm))
	copy(dst[:available], s.pcm[:available])
	for i in available ..< len(dst) {dst[i] = 0}
	remove_range(&s.pcm, 0, available)
	return available / 2, true
}
