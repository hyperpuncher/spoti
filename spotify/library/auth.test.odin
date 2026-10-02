package library

import "core:testing"

@(test)
client_id_is_only_a_public_hex_identifier :: proc(t: ^testing.T) {
	testing.expect(t, valid_client_id("0123456789abcdef0123456789ABCDEF"))
	testing.expect(t, !valid_client_id(""))
	testing.expect(t, !valid_client_id("0123456789abcdef0123456789abcdeg"))
	testing.expect(t, !valid_client_id("0123456789abcdef0123456789abcde"))
}
