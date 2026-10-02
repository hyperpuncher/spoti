package ap

import "core:slice"
import "core:testing"

@(test)
mercury_get_matches_protoc_header :: proc(t: ^testing.T) {
	packet := mercury_get("hm://metadata/4/track/test", 0)
	defer delete(packet)
	want := []u8 {
		0,
		8,
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		0,
		1,
		0,
		1,
		0,
		33,
		0x0a,
		0x1a,
		0x68,
		0x6d,
		0x3a,
		0x2f,
		0x2f,
		0x6d,
		0x65,
		0x74,
		0x61,
		0x64,
		0x61,
		0x74,
		0x61,
		0x2f,
		0x34,
		0x2f,
		0x74,
		0x72,
		0x61,
		0x63,
		0x6b,
		0x2f,
		0x74,
		0x65,
		0x73,
		0x74,
		0x1a,
		0x03,
		0x47,
		0x45,
		0x54,
	}
	testing.expect(t, slice.equal(packet[:], want))
}

@(test)
mercury_final_response_requires_sequence_and_complete_parts :: proc(t: ^testing.T) {
	// Mercury Header{status_code: 200} encoded by protoc: 20 90 03.
	packet := []u8{0, 8, 0, 0, 0, 0, 0, 0, 0, 0, 1, 0, 2, 0, 3, 0x20, 0x90, 0x03, 0, 2, 0xaa, 0xbb}
	body, status, ok := mercury_body(packet, 0)
	testing.expect(t, ok && status == 200 && slice.equal(body, []u8{0xaa, 0xbb}))
	_, _, ok = mercury_body(packet, 1)
	testing.expect(t, !ok)
	_, _, ok = mercury_body(packet[:len(packet) - 1], 0)
	testing.expect(t, !ok)
	partial := [22]u8{}
	copy(partial[:], packet)
	partial[10] = 2 // partial: never return an incomplete response as metadata
	_, _, ok = mercury_body(partial[:], 0)
	testing.expect(t, !ok)
}
