package ap

import "core:crypto"

// authentication.proto (librespot protocol). OAuth bearer tokens are sent in
// the first encrypted AP packet as AUTHENTICATION_SPOTIFY_TOKEN, not in the
// plaintext handshake. Never log the input or the encoded packet.
client_login_token :: proc(token, device_id: string) -> [dynamic]u8 {
	if len(token) == 0 || len(device_id) == 0 {return nil}
	credentials := make([dynamic]u8)
	defer {
		crypto.zero_explicit(raw_data(credentials), len(credentials))
		delete(credentials)
	}
	put_number(&credentials, 20, 3) // AUTHENTICATION_SPOTIFY_TOKEN
	put_bytes(&credentials, 30, transmute([]u8)token)

	system := make([dynamic]u8)
	defer delete(system)
	put_number(&system, 10, 2) // CPU_X86_64
	put_number(&system, 60, 5) // OS_LINUX
	system_information: string = "spoti-odin"
	put_bytes(&system, 90, transmute([]u8)system_information)
	put_bytes(&system, 100, transmute([]u8)device_id)

	message := make([dynamic]u8)
	put_bytes(&message, 10, credentials[:])
	put_bytes(&message, 50, system[:])
	version: string = "spoti 0.1"
	put_bytes(&message, 70, transmute([]u8)version)
	return message
}

Login_Reply :: enum {
	Invalid,
	Welcome,
	Failure,
}

// The returned username is a view into authenticated packet bytes; callers
// must keep those bytes alive while using it. Failure codes are from
// keyexchange.proto; do not display the server's arbitrary error_description.
parse_login_reply :: proc(
	command: u8,
	payload: []u8,
) -> (
	username: string,
	error_code: u64,
	kind: Login_Reply,
) {
	switch command {
	case 0xac:
		// APWelcome (authentication.proto)
		name, found, valid := get_bytes(payload, 10)
		if !found || !valid || len(name) == 0 {return "", 0, .Invalid}
		_, found, valid = get_number(payload, 20)
		if !found || !valid {return "", 0, .Invalid}
		_, found, valid = get_number(payload, 25)
		if !found || !valid {return "", 0, .Invalid}
		_, found, valid = get_number(payload, 30)
		if !found || !valid {return "", 0, .Invalid}
		_, found, valid = get_bytes(payload, 40)
		if !found || !valid {return "", 0, .Invalid}
		return string(name), 0, .Welcome
	case 0xad:
		// AuthFailure (keyexchange.proto)
		code, found, valid := get_number(payload, 10)
		if !found || !valid {return "", 0, .Invalid}
		return "", code, .Failure
	}
	return "", 0, .Invalid
}
