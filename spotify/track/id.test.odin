package track

import "core:slice"
import "core:testing"

@(test)
spotify_link_decodes_to_binary_id :: proc(t: ^testing.T) {
	expected := [16]u8 {
		0x3e,
		0x28,
		0xfa,
		0x7f,
		0x7e,
		0x45,
		0x4a,
		0x1d,
		0x9f,
		0xed,
		0xb9,
		0xd1,
		0xd5,
		0xd4,
		0xe2,
		0x54,
	}
	cases := []string {
		"https://open.spotify.com/track/1TifAMm1r1MascYZ5xGiQk",
		"spotify:track:1TifAMm1r1MascYZ5xGiQk",
		"1TifAMm1r1MascYZ5xGiQk",
		"https://open.spotify.com/track/1TifAMm1r1MascYZ5xGiQk?si=demo",
	}
	for input in cases {
		got, ok := parse_id(input)
		testing.expect(t, ok && slice.equal(got[:], expected[:]))
	}
	_, ok := parse_id("spotify:track:zzzzzzzzzzzzzzzzzzzzzz") // overflows u128
	testing.expect(t, !ok)
	_, ok = parse_id("spotify:track:1TifAMm1r1MascYZ5xGiQ!")
	testing.expect(t, !ok)
	_, ok = parse_id("https://open.spotify.com/album/1TifAMm1r1MascYZ5xGiQk")
	testing.expect(t, !ok)
	_, ok = parse_id("spotify:episode:1TifAMm1r1MascYZ5xGiQk")
	testing.expect(t, !ok)
	_, ok = parse_id("https://example.com/track/1TifAMm1r1MascYZ5xGiQk")
	testing.expect(t, !ok)
}

@(test)
binary_id_encodes_back_to_base62 :: proc(t: ^testing.T) {
	raw, ok := parse_id("1TifAMm1r1MascYZ5xGiQk")
	testing.expect(t, ok)
	encoded := base62_id(raw)
	testing.expect_value(t, encoded, "1TifAMm1r1MascYZ5xGiQk")
	delete(encoded)

	zero := base62_id({})
	testing.expect_value(t, zero, "0000000000000000000000")
	delete(zero)
}
