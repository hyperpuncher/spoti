package library

import "core:os"
import "core:testing"

// The environment wins when it holds a valid key, so headless and
// development use keeps working after the in-app setup stores a key.
@(test)
env_client_id_overrides_the_stored_key :: proc(t: ^testing.T) {
	os.set_env("WEB_CLIENT_ID", "0123456789abcdef0123456789ABCDEF")
	defer os.unset_env("WEB_CLIENT_ID")
	id, found := resolve_client_id(context.temp_allocator)
	if !testing.expect(t, found) {return}
	defer delete(id)
	testing.expect_value(t, id, "0123456789abcdef0123456789ABCDEF")
}

@(test)
client_id_is_only_a_public_hex_identifier :: proc(t: ^testing.T) {
	testing.expect(t, valid_client_id("0123456789abcdef0123456789ABCDEF"))
	testing.expect(t, !valid_client_id(""))
	testing.expect(t, !valid_client_id("0123456789abcdef0123456789abcdeg"))
	testing.expect(t, !valid_client_id("0123456789abcdef0123456789abcde"))
}
