package track

import ap "../ap"

// Decodable Spotify audio formats. metadata.proto AudioFile.Format. The MP3,
// AAC, XHE-AAC, MP4 and FLAC values are deliberately absent: the streaming
// decoder only handles Vorbis, which is what the service serves.
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

// Quality ranking, best first. Zero marks a format this client cannot decode,
// so it is never selected.
format_rank :: proc(format: u64) -> int {
	if format > u64(Audio_Format.Vorbis_320) {return 0}
	return int(format) + 1
}

// Keep the best ranked file of an AudioFile message seen so far.
select_file :: proc(bytes: []u8, track: ^Metadata, best: ^int) {
	file_id, found, file_valid := ap.get_bytes(bytes, 1)
	if !found || !file_valid || len(file_id) != 20 {return}
	format: u64
	format, found, file_valid = ap.get_number(bytes, 2)
	if !found || !file_valid {return}
	rank := format_rank(format)
	if rank <= best^ {return}
	copy(track.file_id[:], file_id)
	track.format = Audio_Format(format)
	best^ = rank
}

// Diagnostic for a rejected Track message. Reports which identifying fields
// were present and every audio-file format, including alternatives. Format
// numbers are codec IDs, never track or file identifiers.
Metadata_Diagnosis :: struct {
	gid, name, duration: bool,
	entries:             int,
	alternatives:        int,
	fields:              [dynamic]u64,
	formats:             [dynamic]u64,
}

diagnose_metadata :: proc(message: []u8) -> Metadata_Diagnosis {
	pos := 0
	diagnosis: Metadata_Diagnosis
	for pos < len(message) {
		field, wire, bytes, _, valid := ap.next_field(message, &pos)
		if !valid {break}
		append(&diagnosis.fields, field)
		switch field {
		case 1:
			diagnosis.gid = true
		case 2:
			diagnosis.name = true
		case 7:
			diagnosis.duration = true
		case 12:
			if wire == 2 {diagnosis_file(bytes, &diagnosis)}
		case 13:
			if wire != 2 {continue}
			diagnosis.alternatives += 1
			cursor := 0
			for cursor < len(bytes) {
				alt_field, alt_wire, alt, _, alt_valid := ap.next_field(bytes, &cursor)
				if !alt_valid {break}
				if alt_field == 12 && alt_wire == 2 {diagnosis_file(alt, &diagnosis)}
			}
		}
	}
	return diagnosis
}

diagnosis_file :: proc(bytes: []u8, diagnosis: ^Metadata_Diagnosis) {
	diagnosis.entries += 1
	if format, found, file_valid := ap.get_number(bytes, 2); found && file_valid {
		append(&diagnosis.formats, format)
	}
}

// metadata.proto Track from the private metadata service. Identity is
// required; a file is optional because the dedicated AUDIO_FILES extension
// carries it for tracks the Track message leaves without a file list. A
// relinked recording has no files on the primary Track and carries them on
// an alternative, so those are consulted only when the primary has none.
parse_track :: proc(message: []u8, expected_id: [16]u8) -> (track: Metadata, ok: bool) {
	pos := 0
	gid: []u8
	seen_name, seen_duration := false, false
	best := 0
	alternative_tail: []u8
	for pos < len(message) {
		start := pos
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
			select_file(bytes, &track, &best)
		case 13:
			if wire != 2 {return {}, false}
			if alternative_tail == nil {alternative_tail = message[start:]}
		}
	}
	if len(gid) != len(expected_id) || !seen_name || !seen_duration {return {}, false}
	for i in 0 ..< 16 {if gid[i] != expected_id[i] {return {}, false}}
	if best == 0 {
		// The outer fields are already validated. Revisit only the tail
		// with alternatives instead of allocating a list of message views.
		pos = 0
		for pos < len(alternative_tail) {
			outer_field, _, alternative, _, _ := ap.next_field(alternative_tail, &pos)
			if outer_field != 13 {continue}
			cursor := 0
			for cursor < len(alternative) {
				field, wire, bytes, _, valid := ap.next_field(alternative, &cursor)
				if !valid {return {}, false}
				if field == 12 && wire == 2 {select_file(bytes, &track, &best)}
			}
			if best > 0 {break}
		}
	}
	return track, true
}

// AudioFilesExtensionResponse: repeated ExtendedAudioFile.files (field 1),
// each wrapping an AudioFile (field 1). The dedicated file list, present even
// when the Track message has no files.
parse_audio_files :: proc(message: []u8, track: ^Metadata) -> bool {
	best := 0
	if track.file_id != {} {best = format_rank(u64(track.format))}
	pos := 0
	for pos < len(message) {
		field, wire, bytes, _, valid := ap.next_field(message, &pos)
		if !valid {return track.file_id != {}}
		if field != 1 || wire != 2 {continue}
		file, found, file_valid := ap.get_bytes(bytes, 1)
		if !found || !file_valid {continue}
		select_file(file, track, &best)
	}
	return track.file_id != {}
}
