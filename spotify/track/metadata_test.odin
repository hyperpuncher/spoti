package track

import "core:testing"

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
	track, ok := parse_metadata(payload, id)
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
	best, selected := parse_metadata(with_high_quality[:], id)
	testing.expect(t, selected && best.format == .Vorbis_320 && best.file_id[0] == 'Z')
	_, ok = parse_metadata(payload[:len(payload) - 1], id)
	testing.expect(t, !ok)
	id[0] = 0
	_, ok = parse_metadata(payload, id)
	testing.expect(t, !ok)
}
