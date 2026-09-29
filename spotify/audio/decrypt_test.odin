package audio

import "core:slice"
import "core:testing"

@(test)
audio_ctr_matches_openssl_across_chunk_boundaries :: proc(t: ^testing.T) {
	key: [16]u8
	for i in 0 ..< 16 {key[i] = u8(i)}
	ciphertext := [32]u8 {
		0xf1,
		0xd5,
		0x3b,
		0xbd,
		0x35,
		0xe6,
		0x25,
		0x9b,
		0x05,
		0xd0,
		0x5b,
		0x52,
		0x41,
		0x72,
		0xca,
		0xcf,
		0xab,
		0x00,
		0x36,
		0xb4,
		0x4f,
		0x0a,
		0xdb,
		0xd1,
		0x0a,
		0xcc,
		0x53,
		0x52,
		0xcc,
		0xde,
		0x23,
		0xa7,
	}
	// OpenSSL: openssl enc -aes-128-ctr -nosalt -K 000102...0f
	// -iv 72e067fbddcbcf77ebe8bc643f630d93
	stream := init(key)
	defer reset(&stream)
	process(&stream, ciphertext[:3])
	process(&stream, ciphertext[3:19])
	process(&stream, ciphertext[19:])
	expected: string = "OggS0123456789abcdef0123456789ab"
	testing.expect(t, slice.equal(ciphertext[:], transmute([]u8)expected))
}
