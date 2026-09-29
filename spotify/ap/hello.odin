// Plaintext access-point handshake framing and the first ClientHello message.
// Schema: librespot/protocol/proto/keyexchange.proto; framing: librespot/docs/connection.md.
// No network, authentication, or encryption happens in this package.
package ap

import varint "core:encoding/varint"

Frame_Status :: enum {
	Incomplete,
	Invalid,
	Complete,
}

MAX_FRAME_SIZE :: 64 * 1024

// ClientHello is the only handshake packet with the two-byte [0, 4] prefix.
// The big-endian length includes the prefix and the four length bytes.
frame_plaintext :: proc(payload: []u8, client_hello: bool) -> [dynamic]u8 {
	header: int = client_hello ? 6 : 4
	if len(payload) + header > MAX_FRAME_SIZE {
		return nil
	}
	size := u32(len(payload) + header)
	frame := make([dynamic]u8, 0, int(size))
	if client_hello {
		append(&frame, 0, 4)
	}
	append(&frame, u8(size >> 24), u8(size >> 16), u8(size >> 8), u8(size))
	append(&frame, ..payload)
	return frame
}

// Returns a view into input (no allocation), plus the consumed byte count.
// Call again with more data when the result is Incomplete.
parse_plaintext :: proc(
	input: []u8,
	client_hello: bool,
) -> (
	payload: []u8,
	consumed: int,
	status: Frame_Status,
) {
	offset := 0
	if client_hello {
		if len(input) >= 1 && input[0] != 0 || len(input) >= 2 && input[1] != 4 {
			return nil, 0, .Invalid
		}
		offset = 2
	}
	if len(input) < offset + 4 {
		return nil, 0, .Incomplete
	}
	size :=
		u32(input[offset]) << 24 |
		u32(input[offset + 1]) << 16 |
		u32(input[offset + 2]) << 8 |
		u32(input[offset + 3])
	if size < u32(offset + 4) || size > MAX_FRAME_SIZE {
		return nil, 0, .Invalid
	}
	if len(input) < int(size) {
		return nil, 0, .Incomplete
	}
	return input[offset + 4:int(size)], int(size), .Complete
}

put_varint :: proc(out: ^[dynamic]u8, value: u64) {
	bytes: [10]u8
	count, _ := varint.encode_uleb128(bytes[:], u128(value))
	append(out, ..bytes[:count])
}

put_number :: proc(out: ^[dynamic]u8, field: u64, value: u64) {
	put_varint(out, field << 3)
	put_varint(out, value)
}

put_bytes :: proc(out: ^[dynamic]u8, field: u64, value: []u8) {
	put_varint(out, field << 3 | 2)
	put_varint(out, u64(len(value)))
	append(out, ..value)
}

// Encodes the subset of ClientHello used by librespot: product=client,
// Shannon cryptosuite, DH public key, 16-byte nonce, and padding.
// The caller supplies its own DH public key and cryptographically random nonce.
client_hello :: proc(public_key, nonce: []u8, platform, version: u64) -> [dynamic]u8 {
	if len(public_key) == 0 || len(nonce) != 16 {
		return nil
	}
	build_info := make([dynamic]u8)
	defer delete(build_info)
	put_number(&build_info, 10, 0) // PRODUCT_CLIENT
	put_number(&build_info, 20, 0) // PRODUCT_FLAG_NONE
	put_number(&build_info, 30, platform)
	put_number(&build_info, 40, version)

	dh := make([dynamic]u8)
	defer delete(dh)
	put_bytes(&dh, 10, public_key)
	put_number(&dh, 20, 1) // server_keys_known
	crypto := make([dynamic]u8)
	defer delete(crypto)
	put_bytes(&crypto, 10, dh[:])

	message := make([dynamic]u8)
	put_bytes(&message, 10, build_info[:])
	put_number(&message, 30, 0) // CRYPTO_SUITE_SHANNON
	put_bytes(&message, 50, crypto[:])
	put_bytes(&message, 60, nonce)
	put_bytes(&message, 70, []u8{0x1e})
	return message
}

// The final plaintext handshake message, before Shannon encryption begins.
client_response :: proc(challenge: []u8) -> [dynamic]u8 {
	if len(challenge) != 20 {return nil}
	dh := make([dynamic]u8)
	defer delete(dh)
	put_bytes(&dh, 10, challenge)
	login := make([dynamic]u8)
	defer delete(login)
	put_bytes(&login, 10, dh[:])
	message := make([dynamic]u8)
	put_bytes(&message, 10, login[:])
	put_bytes(&message, 20, nil) // empty PoWResponseUnion
	put_bytes(&message, 30, nil) // empty CryptoResponseUnion
	return message
}
