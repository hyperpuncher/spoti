package track

import ap "../ap"

Audio_Format :: enum u64 {
	Vorbis_96  = 0,
	Vorbis_160 = 1,
	Vorbis_320 = 2,
}

Metadata :: struct {
	name:        string, // view into the authenticated protobuf response
	file_id:     [20]u8,
	format:      Audio_Format,
	duration_ms: int,
}

// metadata.proto Track. Prefer the highest available Vorbis bitrate (320,
// then 160, then 96). Never use preview files or select a codec we cannot
// decode. Lossless FLAC is not supported by the current streaming decoder.
parse_metadata :: proc(message: []u8, expected_id: [16]u8) -> (track: Metadata, ok: bool) {
	pos := 0
	gid: []u8
	seen_name, seen_duration := false, false
	best := -1
	for pos < len(message) {
		field, wire, bytes, number, valid := ap.next_field(message, &pos)
		if !valid {return {}, false}
		switch field {
		case 1:
			if gid != nil || wire != 2 || len(bytes) != 16 {return {}, false}
			gid = bytes
		case 2:
			if seen_name || wire != 2 || len(bytes) == 0 {return {}, false}
			track.name, seen_name = string(bytes), true
		case 7:
			if seen_duration ||
			   wire != 0 ||
			   number & 1 != 0 ||
			   number >> 1 > u64(max(i32)) {return {}, false}
			track.duration_ms, seen_duration = int(number >> 1), true
		case 12:
			if wire != 2 {return {}, false}
			file_id, found, valid := ap.get_bytes(bytes, 1)
			if !found || !valid || len(file_id) != 20 {continue}
			format: u64
			format, found, valid = ap.get_number(bytes, 2)
			if !found || !valid || format > 2 {continue}
			preference := format == 2 ? 3 : format == 1 ? 2 : 1
			if preference > best {
				copy(track.file_id[:], file_id)
				track.format = Audio_Format(format)
				best = preference
			}
		}
	}
	if len(gid) != len(expected_id) || best < 0 || !seen_name || !seen_duration {return {}, false}
	for i in 0 ..< 16 {if gid[i] != expected_id[i] {return {}, false}}
	return track, true
}
