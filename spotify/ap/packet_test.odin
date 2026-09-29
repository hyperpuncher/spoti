package ap

import "core:slice"
import "core:testing"

@(test)
encrypted_packet_matches_librespot_cipher :: proc(t: ^testing.T) {
	key: [32]u8
	for i in 0 ..< 32 {key[i] = u8(i)}
	sender := packet_cipher(key[:])
	wire := seal_packet(&sender, 0xab, []u8{1, 2, 3, 4, 5})
	defer delete(wire)
	testing.expect(
		t,
		slice.equal(
			wire[:],
			[]u8{0x61, 0x7d, 0xec, 0x2a, 0x9c, 0xcd, 0x37, 0x45, 0xa5, 0x68, 0x60, 0x3b},
		),
	)
	ciphertext := [5]u8{0x2a, 0x9c, 0xcd, 0x37, 0x45}
	receiver := packet_cipher(key[:])
	cmd, length, ok := open_header(&receiver, [3]u8{0x61, 0x7d, 0xec})
	testing.expect(t, ok && cmd == 0xab && length == 5)
	testing.expect(t, open_payload(&receiver, ciphertext[:], []u8{0xa5, 0x68, 0x60, 0x3b}))
	testing.expect(t, slice.equal(ciphertext[:], []u8{1, 2, 3, 4, 5}))
}

@(test)
encrypted_packet_rejects_bad_mac :: proc(t: ^testing.T) {
	key: [32]u8
	for i in 0 ..< 32 {key[i] = u8(i)}
	receiver := packet_cipher(key[:])
	_, _, ok := open_header(&receiver, [3]u8{0x61, 0x7d, 0xec})
	testing.expect(t, ok)
	ciphertext := [5]u8{0x2a, 0x9c, 0xcd, 0x37, 0x45}
	testing.expect(t, !open_payload(&receiver, ciphertext[:], []u8{0, 0, 0, 0}))
	testing.expect(t, slice.equal(ciphertext[:], []u8{0, 0, 0, 0, 0}))
}
