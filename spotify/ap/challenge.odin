package ap

import varint "core:encoding/varint"

// Bytes in this struct are views into the original packet. They are untrusted
// until the server's signature over public_key is verified.
Challenge :: struct {
	public_key:    []u8,
	signature:     []u8,
	signature_key: u32,
	server_nonce:  []u8,
}

Response_Kind :: enum {
	Invalid,
	Challenge,
	Upgrade_Required,
	Login_Failed,
}

read_varint :: proc(data: []u8, pos: ^int) -> (value: u64, ok: bool) {
	if pos^ >= len(data) {
		return 0, false
	}
	v, count, err := varint.decode_uleb128(data[pos^:])
	if err != .None || count > 10 || v > u128(max(u64)) {
		return 0, false
	}
	pos^ += count
	return u64(v), true
}

// Walk one protobuf field, including wire types we don't use so newer optional
// fields can be ignored safely. Groups (wire types 3 and 4) are unsupported.
next_field :: proc(
	data: []u8,
	pos: ^int,
) -> (
	field: u64,
	wire: u64,
	bytes: []u8,
	number: u64,
	ok: bool,
) {
	key, valid := read_varint(data, pos)
	if !valid || key >> 3 == 0 {
		return
	}
	field, wire = key >> 3, key & 7
	switch wire {
	case 0:
		number, ok = read_varint(data, pos)
	case 1:
		if len(data) - pos^ < 8 {return}
		pos^ += 8
		ok = true
	case 2:
		length, length_valid := read_varint(data, pos)
		if !length_valid || length > u64(len(data) - pos^) {return}
		bytes = data[pos^:pos^ + int(length)]
		pos^ += int(length)
		ok = true
	case 5:
		if len(data) - pos^ < 4 {return}
		pos^ += 4
		ok = true
	}
	return
}

get_bytes :: proc(data: []u8, wanted: u64) -> (value: []u8, found, valid: bool) {
	pos := 0
	for pos < len(data) {
		field, wire, bytes, _, ok := next_field(data, &pos)
		if !ok {return nil, false, false}
		if field == wanted {
			if found || wire != 2 {return nil, false, false}
			value, found = bytes, true
		}
	}
	return value, found, true
}

get_number :: proc(data: []u8, wanted: u64) -> (value: u64, found, valid: bool) {
	pos := 0
	for pos < len(data) {
		field, wire, _, number, ok := next_field(data, &pos)
		if !ok {return 0, false, false}
		if field == wanted {
			if found || wire != 0 {return 0, false, false}
			value, found = number, true
		}
	}
	return value, found, true
}

// Decode APResponseMessage -> APChallenge -> LoginCryptoChallengeUnion ->
// LoginCryptoDiffieHellmanChallenge from keyexchange.proto. Failure and upgrade
// replies are distinguished without treating their payloads as a challenge.
parse_response :: proc(data: []u8) -> (challenge: Challenge, kind: Response_Kind) {
	pos := 0
	body: []u8
	kind = .Invalid
	for pos < len(data) {
		field, wire, bytes, _, ok := next_field(data, &pos)
		if !ok {return {}, .Invalid}
		switch field {
		case 10:
			if wire != 2 || kind != .Invalid {return {}, .Invalid}
			body, kind = bytes, .Challenge
		case 20:
			if wire != 2 || kind != .Invalid {return {}, .Invalid}
			kind = .Upgrade_Required
		case 30:
			if wire != 2 || kind != .Invalid {return {}, .Invalid}
			kind = .Login_Failed
		}
	}
	if kind != .Challenge {return {}, kind}
	login, found, valid := get_bytes(body, 10)
	if !found || !valid {return {}, .Invalid}
	challenge.server_nonce, found, valid = get_bytes(body, 50)
	if !found || !valid || len(challenge.server_nonce) != 16 {return {}, .Invalid}
	dh: []u8
	dh, found, valid = get_bytes(login, 10)
	if !found || !valid {return {}, .Invalid}
	challenge.public_key, found, valid = get_bytes(dh, 10)
	if !found || !valid || len(challenge.public_key) == 0 {return {}, .Invalid}
	challenge.signature, found, valid = get_bytes(dh, 30)
	if !found || !valid || len(challenge.signature) == 0 {return {}, .Invalid}
	key: u64
	key, found, valid = get_number(dh, 20)
	if !found || !valid || key > u64(max(u32)) {return {}, .Invalid}
	challenge.signature_key = u32(key)
	return challenge, .Challenge
}
