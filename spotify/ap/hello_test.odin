package ap

import "core:encoding/hex"
import "core:slice"
import "core:testing"

@(test)
client_hello_matches_protoc :: proc(t: ^testing.T) {
	// Generated with protoc --encode=ClientHello from librespot's keyexchange.proto.
	fixture: string = "520e5000a00100f00108c002e2ca9c3bf0010092030a52085203010203a00101e20310000102030405060708090a0b0c0d0e0fb204011e"
	expected, ok := hex.decode(transmute([]u8)fixture)
	defer delete(expected)
	testing.expect(t, ok)
	nonce := [16]u8{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15}
	message := client_hello([]u8{1, 2, 3}, nonce[:], 8, 124200290)
	defer delete(message)
	testing.expect(t, slice.equal(message[:], expected))

	frame := frame_plaintext(message[:], true)
	defer delete(frame)
	testing.expect(t, slice.equal(frame[:6], []u8{0, 4, 0, 0, 0, 61}))
	payload, consumed, status := parse_plaintext(frame[:], true)
	testing.expect(t, status == .Complete && consumed == len(frame))
	testing.expect(t, slice.equal(payload, expected))
}

@(test)
client_response_matches_protoc :: proc(t: ^testing.T) {
	fixture: string = "5218521652140102030405060708090a0b0c0d0e0f1011121314a20100f20100"
	expected, ok := hex.decode(transmute([]u8)fixture)
	defer delete(expected)
	testing.expect(t, ok)
	challenge := [20]u8{1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20}
	response := client_response(challenge[:])
	defer delete(response)
	testing.expect(t, slice.equal(response[:], expected))
	frame := frame_plaintext(response[:], false)
	defer delete(frame)
	testing.expect(t, slice.equal(frame[:4], []u8{0, 0, 0, 36}))
}

@(test)
frames_handle_partial_invalid_and_concatenated_input :: proc(t: ^testing.T) {
	frame := frame_plaintext([]u8{0x08, 0x01}, false)
	defer delete(frame)
	_, consumed, status := parse_plaintext(frame[:3], false)
	testing.expect(t, status == .Incomplete && consumed == 0)
	_, consumed, status = parse_plaintext([]u8{0, 0, 0, 3}, false)
	testing.expect(t, status == .Invalid && consumed == 0)
	_, consumed, status = parse_plaintext([]u8{0xff, 0xff, 0xff, 0xff}, false)
	testing.expect(t, status == .Invalid && consumed == 0)

	joined := make([dynamic]u8)
	defer delete(joined)
	append(&joined, ..frame[:])
	append(&joined, ..frame[:])
	payload: []u8
	payload, consumed, status = parse_plaintext(joined[:], false)
	testing.expect(t, status == .Complete && consumed == len(frame))
	testing.expect(t, slice.equal(payload, []u8{0x08, 0x01}))
	_, _, status = parse_plaintext([]u8{0, 5}, true)
	testing.expect(t, status == .Invalid)
	_, _, status = parse_plaintext([]u8{0, 4, 0, 0, 0}, true)
	testing.expect(t, status == .Incomplete)
}

@(test)
hello_rejects_missing_key_or_nonce :: proc(t: ^testing.T) {
	testing.expect(t, client_hello(nil, []u8{1}, 8, 124200290) == nil)
	testing.expect(t, client_hello([]u8{1}, []u8{1}, 8, 124200290) == nil)
	oversized := make([]u8, MAX_FRAME_SIZE)
	defer delete(oversized)
	testing.expect(t, frame_plaintext(oversized, true) == nil)
}
