package ap

import "core:encoding/hex"
import "core:slice"
import "core:testing"

@(test)
keys_match_hmac_sha1_reference :: proc(t: ^testing.T) {
	// Wire-format hello and reply fixtures from the preceding protocol tests.
	wire: string =
		"00040000003d520e5000a00100f00108c002e2ca9c3bf0010092030a52085203010203a00101e20310000102030405060708090a0b0c0d0e0fb204011e" +
		"00000033522f520f520d5203010203a00101f20102aabba20100f20100c202025200920310000102030405060708090a0b0c0d0e0f"
	transcript, ok := hex.decode(transmute([]u8)wire)
	defer delete(transcript)
	testing.expect(t, ok)
	keys, valid := derive_keys([]u8{1, 2, 3, 4}, transcript)
	testing.expect(t, valid)
	// Independent HMAC-SHA1 reference (node:crypto), not the Odin implementation.
	challenge_hex: string = "92a3c6fd85e13ebfd5bc934b01e49812e369e50f"
	send_hex: string = "9d2dec66033066e9177c651bc9b277c8866cba001036d0fde7cf1dce7dadef44"
	receive_hex: string = "0ee4673c9f95a7086bf5b3a328c00ce9fbf621967cecac9d3e9607f37f8ef9da"
	challenge, _ := hex.decode(transmute([]u8)challenge_hex)
	defer delete(challenge)
	send, _ := hex.decode(transmute([]u8)send_hex)
	defer delete(send)
	receive, _ := hex.decode(transmute([]u8)receive_hex)
	defer delete(receive)
	testing.expect(t, slice.equal(keys.challenge[:], challenge))
	testing.expect(t, slice.equal(keys.send[:], send))
	testing.expect(t, slice.equal(keys.receive[:], receive))
}

@(test)
keys_reject_missing_inputs :: proc(t: ^testing.T) {
	_, ok := derive_keys(nil, []u8{1})
	testing.expect(t, !ok)
	_, ok = derive_keys([]u8{1}, nil)
	testing.expect(t, !ok)
}
