package audio

import c "core:c/libc"

// Decrypt and strip Spotify's 167-byte custom Ogg header before feeding bytes
// to this push decoder. A decoder receives contiguous Ogg bytes, in order.
Decoder :: struct {
	handle:      ^Vorbis,
	pending:     [dynamic]u8,
	sample_rate: int,
}

close_decoder :: proc(d: ^Decoder) {
	if d.handle != nil {close(d.handle); d.handle = nil}
	delete(d.pending)
}

// Add encrypted-file bytes after decryption. Writes interleaved stereo 16-bit
// PCM (mono is duplicated). Returns false on corrupt/unsupported input. It
// buffers at most 256 KiB of undecoded Ogg data; it never caches the file.
decode_chunk :: proc(d: ^Decoder, input: []u8, pcm: ^[dynamic]i16) -> bool {
	if len(d.pending) + len(input) > 256 * 1024 {return false}
	append(&d.pending, ..input)
	if d.handle == nil {
		if len(d.pending) == 0 {return true}
		consumed: c.int
		err: c.int
		d.handle = open_pushdata(raw_data(d.pending), c.int(len(d.pending)), &consumed, &err, nil)
		if d.handle == nil {return err == 1} 	// VORBIS_need_more_data
		info := get_info(d.handle)
		if info.sample_rate < 8000 ||
		   info.sample_rate > 192000 ||
		   info.channels < 1 ||
		   info.channels > 2 {return false}
		d.sample_rate = int(info.sample_rate)
		if consumed < 0 || int(consumed) > len(d.pending) {return false}
		remove_range(&d.pending, 0, consumed)
	}
	for len(d.pending) > 0 {
		channels, frames: c.int
		planar: [^]^f32
		used := decode_frame_pushdata(
			d.handle,
			raw_data(d.pending),
			c.int(len(d.pending)),
			&channels,
			&planar,
			&frames,
		)
		if used < 0 || int(used) > len(d.pending) || frames < 0 || frames > 8192 {return false}
		if frames > 0 {
			if channels < 1 ||
			   channels > 2 ||
			   planar == nil ||
			   len(pcm^) + int(frames) * 2 > 512 * 1024 {return false}
			for i in 0 ..< int(frames) {
				left := ([^]f32)(planar[0])[i]
				right := channels == 2 ? ([^]f32)(planar[1])[i] : left
				append(pcm, pcm16(left), pcm16(right))
			}
		}
		remove_range(&d.pending, 0, used)
		if used == 0 {break} 	// needs more input, no busy loop
	}
	return true
}

pcm16 :: proc(value: f32) -> i16 {
	return i16(i32(max(-1.0, min(1.0, value)) * 32767))
}
