package ap

import "core:encoding/hex"
import "core:slice"
import "core:testing"

@(test)
response_extracts_untrusted_challenge :: proc(t: ^testing.T) {
	// Generated with protoc --encode=APResponseMessage from keyexchange.proto.
	fixture: string = "522f520f520d5203010203a00101f20102aabba20100f20100c202025200920310000102030405060708090a0b0c0d0e0f"
	data, ok := hex.decode(transmute([]u8)fixture)
	defer delete(data)
	testing.expect(t, ok)

	packet := frame_plaintext(data, false)
	defer delete(packet)
	payload, used, status := parse_plaintext(packet[:], false)
	testing.expect(t, status == .Complete && used == len(packet))
	challenge, kind := parse_response(payload)
	testing.expect(t, kind == .Challenge)
	testing.expect(t, slice.equal(challenge.public_key, []u8{1, 2, 3}))
	testing.expect(t, slice.equal(challenge.signature, []u8{0xaa, 0xbb}))
	testing.expect(t, challenge.signature_key == 1)
	nonce := [16]u8{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
	testing.expect(t, slice.equal(challenge.server_nonce, nonce[:]))
	// This fixture is structurally valid but its fake server signature is not.
	testing.expect(t, !verify_server_signature(challenge))
	fake_signature := make([]u8, 256)
	defer delete(fake_signature)
	challenge.signature = fake_signature
	testing.expect(t, !verify_server_signature(challenge))

	// Unknown protobuf fields can be skipped without changing the challenge.
	extended := make([dynamic]u8)
	defer delete(extended)
	append(&extended, ..data)
	append(&extended, 0xf8, 0x07, 1) // field 127, varint
	append(&extended, 0xf9, 0x07, 0, 0, 0, 0, 0, 0, 0, 0) // fixed64
	append(&extended, 0xfd, 0x07, 0, 0, 0, 0) // fixed32
	_, kind = parse_response(extended[:])
	testing.expect(t, kind == .Challenge)
}

@(test)
response_rejects_malformed_and_distinguishes_errors :: proc(t: ^testing.T) {
	_, kind := parse_response([]u8{0xa2, 0x01, 0}) // upgrade required
	testing.expect(t, kind == .Upgrade_Required)
	_, kind = parse_response([]u8{0xf2, 0x01, 0}) // login failed
	testing.expect(t, kind == .Login_Failed)
	_, kind = parse_response([]u8{0xa2, 0x01, 0, 0xf2, 0x01, 0}) // ambiguous
	testing.expect(t, kind == .Invalid)
	_, kind = parse_response([]u8{0x52, 0x04, 0x52}) // truncated nested message
	testing.expect(t, kind == .Invalid)
	_, kind = parse_response([]u8{0x80}) // incomplete varint
	testing.expect(t, kind == .Invalid)
	_, kind = parse_response([]u8{0x0b}) // unsupported protobuf group
	testing.expect(t, kind == .Invalid)

	fixture: string = "522f520f520d5203010203a00101f20102aabba20100f20100c202025200920310000102030405060708090a0b0c0d0e0f"
	data, ok := hex.decode(transmute([]u8)fixture)
	defer delete(data)
	testing.expect(t, ok)
	data[11] = 0xa2 // signature key field must be a varint, not bytes
	_, kind = parse_response(data)
	testing.expect(t, kind == .Invalid)
}
