package track

import "core:testing"

// Append one metadata.proto AudioFile {file_id, format} to a Track message.
append_audio_file :: proc(message: ^[dynamic]u8, file_id: u8, format: u8) {
	append(message, 0x62, 0x18, 0x0a, 0x14)
	for _ in 0 ..< 20 {append(message, file_id)}
	append(message, 0x10, format)
}

// Append one AudioFilesExtensionResponse.files ExtendedAudioFile {file}.
append_extended_audio_file :: proc(message: ^[dynamic]u8, file_id: u8, format: u8) {
	audio_file := make([dynamic]u8)
	defer delete(audio_file)
	append(&audio_file, 0x0a, 0x14) // AudioFile.file_id
	for _ in 0 ..< 20 {append(&audio_file, file_id)}
	append(&audio_file, 0x10, format) // AudioFile.format
	extended := make([dynamic]u8)
	defer delete(extended)
	append(&extended, 0x0a, u8(len(audio_file))) // ExtendedAudioFile.file
	append(&extended, ..audio_file[:])
	append(message, 0x0a, u8(len(extended))) // AudioFilesExtensionResponse.files
	append(message, ..extended[:])
}

// A minimal valid Track: gid, name and duration, then the audio files.
build_track :: proc(id: [16]u8, formats: []u8) -> [dynamic]u8 {
	message := make([dynamic]u8)
	append(&message, 0x0a, 0x10)
	for byte in id {append(&message, byte)}
	name := []u8{'t', 'e', 's', 't', ' ', 't', 'r', 'a', 'c', 'k'}
	append(&message, 0x12, u8(len(name)))
	append(&message, ..name)
	append(&message, 0x38, 0x80, 0xb5, 0x18) // duration_ms = 200000
	for format in formats {append_audio_file(&message, 'Z', format)}
	return message
}

// Attach a relinked recording as Track.alternative (field 13).
append_alternative :: proc(message: ^[dynamic]u8, alternative: []u8) {
	append(message, 0x6a, u8(len(alternative)))
	append(message, ..alternative)
}

@(test)
track_metadata_matches_protoc :: proc(t: ^testing.T) {
	// protoc --encode=spotify.metadata.Track against metadata.proto.
	payload := []u8 {
		0x0a,
		0x10,
		0x30,
		0x31,
		0x32,
		0x33,
		0x34,
		0x35,
		0x36,
		0x37,
		0x38,
		0x39,
		0x61,
		0x62,
		0x63,
		0x64,
		0x65,
		0x66,
		0x12,
		0x0a,
		0x74,
		0x65,
		0x73,
		0x74,
		0x20,
		0x74,
		0x72,
		0x61,
		0x63,
		0x6b,
		0x38,
		0x80,
		0xb5,
		0x18,
		0x62,
		0x18,
		0x0a,
		0x14,
		0x61,
		0x62,
		0x63,
		0x64,
		0x65,
		0x66,
		0x67,
		0x68,
		0x69,
		0x6a,
		0x6b,
		0x6c,
		0x6d,
		0x6e,
		0x6f,
		0x70,
		0x71,
		0x72,
		0x73,
		0x74,
		0x10,
		0x01,
	}
	id := [16]u8 {
		0x30,
		0x31,
		0x32,
		0x33,
		0x34,
		0x35,
		0x36,
		0x37,
		0x38,
		0x39,
		0x61,
		0x62,
		0x63,
		0x64,
		0x65,
		0x66,
	}
	track, ok := parse_track(payload, id)
	testing.expect(t, ok && track.name == "test track" && track.duration_ms == 200000)
	testing.expect(
		t,
		track.format == .Vorbis_160 && track.file_id[0] == 'a' && track.file_id[19] == 't',
	)
	with_high_quality := make([dynamic]u8)
	defer delete(with_high_quality)
	append(&with_high_quality, ..payload)
	append(&with_high_quality, 0x62, 0x18, 0x0a, 0x14) // another AudioFile
	for _ in 0 ..< 20 {append(&with_high_quality, 'Z')}
	append(&with_high_quality, 0x10, 0x02) // OGG_VORBIS_320
	best, selected := parse_track(with_high_quality[:], id)
	testing.expect(t, selected && best.format == .Vorbis_320 && best.file_id[0] == 'Z')
	_, ok = parse_track(payload[:len(payload) - 1], id)
	testing.expect(t, !ok)
	id[0] = 0
	_, ok = parse_track(payload, id)
	testing.expect(t, !ok)
}

@(test)
audio_format_picks_the_highest_vorbis_quality :: proc(t: ^testing.T) {
	id: [16]u8
	for &byte, i in id {byte = u8(i)}
	// A file we cannot decode leaves no file selected even when it is the only one.
	message := build_track(id, []u8{8}) // AAC only
	undecodable, _ := parse_track(message[:], id)
	testing.expect(t, undecodable.file_id == {}, "undecodable format leaves no file")
	delete(message)
	// Worst to best: Vorbis 320 must win.
	message = build_track(id, []u8{0, 1, 2})
	track, selected := parse_track(message[:], id)
	testing.expect(t, selected && track.format == .Vorbis_320)
	delete(message)
	// MP3 files are out of scope and stay unselected.
	message = build_track(id, []u8{6, 5, 3, 4})
	track, selected = parse_track(message[:], id)
	testing.expect(t, selected && track.file_id == {}, "mp3 files are ignored")
	delete(message)
}

@(test)
audio_format_falls_back_to_a_relinked_recording_alternative :: proc(t: ^testing.T) {
	id: [16]u8
	for &byte, i in id {byte = u8(i)}
	// The primary has only an undecodable file; the alternative has Vorbis 320.
	message := build_track(id, []u8{8})
	defer delete(message)
	unsupported := build_track(id, []u8{8})
	defer delete(unsupported)
	append_alternative(&message, unsupported[:])
	append(&message, 0x1a, 0) // an unrelated Album between alternatives
	alternative := build_track(id, []u8{2})
	defer delete(alternative)
	append_alternative(&message, alternative[:])
	track, selected := parse_track(message[:], id)
	testing.expect(t, selected && track.format == .Vorbis_320 && track.name == "test track")
	// A primary file wins even when it follows the alternatives on the wire.
	append_audio_file(&message, 'P', 1)
	track, selected = parse_track(message[:], id)
	testing.expect(t, selected && track.format == .Vorbis_160 && track.file_id[0] == 'P')
}

@(test)
audio_files_extension_selects_the_best_file :: proc(t: ^testing.T) {
	message := make([dynamic]u8)
	defer delete(message)
	append_extended_audio_file(&message, 'A', 8) // AAC_24, undecodable
	append_extended_audio_file(&message, 'B', 1) // Vorbis 160
	append_extended_audio_file(&message, 'C', 2) // Vorbis 320
	track: Metadata
	testing.expect(t, parse_audio_files(message[:], &track))
	testing.expect(t, track.format == .Vorbis_320 && track.file_id[0] == 'C')
}

@(test)
global_unavailability_preserves_unknown_and_relinked_tracks :: proc(t: ^testing.T) {
	// Track.restriction { countries_allowed: "" }, as returned for removed tracks.
	testing.expect(t, unavailable_everywhere([]u8{0x5a, 2, 0x12, 0}))
	testing.expect(t, !unavailable_everywhere(nil))
	testing.expect(t, !unavailable_everywhere([]u8{0x5a, 0}))
	// A catalogue condition is not a global restriction.
	testing.expect(t, !unavailable_everywhere([]u8{0x5a, 4, 0x12, 0, 0x08, 1}))
	// Alternatives must retain the existing relinking path.
	testing.expect(t, !unavailable_everywhere([]u8{0x5a, 2, 0x12, 0, 0x6a, 0}))
}
