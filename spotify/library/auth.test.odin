package library

import oauth "../oauth"
import "core:os"
import "core:strings"
import "core:testing"
import "core:time"

// The environment wins when it holds a valid key, so headless and
// development use keeps working after the in-app setup stores a key.
@(test)
env_client_id_overrides_the_stored_key :: proc(t: ^testing.T) {
	os.set_env("WEB_CLIENT_ID", "0123456789abcdef0123456789ABCDEF")
	defer os.unset_env("WEB_CLIENT_ID")
	id, found := resolve_client_id()
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

// A network failure keeps the grant for the next request. A rejected grant
// (which also clears the keyring, so it is not exercised here) returns 401.
@(test)
token_renewal_keeps_the_grant_after_a_network_failure :: proc(t: ^testing.T) {
	os.set_env("WEB_CLIENT_ID", "0123456789abcdef0123456789ABCDEF")
	defer os.unset_env("WEB_CLIENT_ID")
	client: Client
	tokens := oauth.Tokens {
		refresh    = strings.clone("grant"),
		expires_at = time.unix(1, 0),
	}
	defer oauth.wipe_tokens(&tokens)
	offline :: proc(_: string, _: oauth.Grant) -> (oauth.Tokens, oauth.Token_Result) {
		return {}, .Network_Error
	}
	testing.expect_value(t, ensure_tokens(&client, &tokens, offline), -1)
	testing.expect_value(t, tokens.refresh, "grant")
	tokens.expires_at = {}
	testing.expect_value(t, ensure_tokens(&client, &tokens, offline), 200)
	oauth.wipe_tokens(&tokens)
	tokens.expires_at = time.unix(1, 0)
	testing.expect_value(t, ensure_tokens(&client, &tokens, offline), 401)
}
