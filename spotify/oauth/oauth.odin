// Spotify browser authorization (authorization code + PKCE, no client secret).
package oauth

import "core:crypto"
import "core:crypto/hash"
import "core:encoding/base64"
import "core:fmt"
import "core:net"
import "core:strings"

// This public client ID and redirect are the streaming-only grant used by
// Spotifast. A personal Web API developer app is not needed for this grant.
PLAYBACK_CLIENT_ID :: "65b708073fc0480ea92a077233ca87bd"
REDIRECT_URI :: "http://127.0.0.1:8898/login"
WEB_REDIRECT_URI :: "http://127.0.0.1:8989/login"

Grant :: struct {
	client_id:      string,
	redirect_uri:   string,
	port:           u16,
	scopes:         string,
	required_scope: string,
}

PLAYBACK_GRANT :: Grant{PLAYBACK_CLIENT_ID, REDIRECT_URI, 8898, "streaming", "streaming"}
// The caller supplies its own registered Web API client ID. Never use the
// playback identity or another app's shared Web API grant for account reads.
// Writes (hero heart) need the modify set; sessions approved without it
// re-approve once through the required-scope check below.
web_grant :: proc(client_id: string) -> Grant {
	return {
		client_id,
		WEB_REDIRECT_URI,
		8989,
		"playlist-read-private playlist-read-collaborative user-library-read user-follow-read user-library-modify user-follow-modify playlist-modify-public",
		"user-library-modify",
	}
}

Flow :: struct {
	state:    string,
	verifier: string,
	url:      string,
}

// Base64url without padding, as required by RFC 7636.
encode_url :: proc(input: []u8) -> string {
	encoded := base64.encode(input, base64.ENC_URL_TABLE)
	if !strings.has_suffix(encoded, "=") {return encoded}
	trimmed := strings.clone(strings.trim_right(encoded, "="))
	delete(encoded)
	return trimmed
}

challenge :: proc(verifier: string) -> string {
	digest: [32]u8
	hash.hash_string_to_buffer(.SHA256, verifier, digest[:])
	return encode_url(digest[:])
}

begin :: proc(grant: Grant = PLAYBACK_GRANT) -> Flow {
	secret: [32]u8
	crypto.rand_bytes(secret[:])
	verifier := encode_url(secret[:])
	crypto.rand_bytes(secret[:])
	state := encode_url(secret[:])
	crypto.zero_explicit(&secret, size_of(secret))
	redirect := net.percent_encode(grant.redirect_uri)
	defer delete(redirect)
	pkce := challenge(verifier)
	defer delete(pkce)
	encoded_scopes := net.percent_encode(grant.scopes)
	defer delete(encoded_scopes)
	address := fmt.aprintf(
		"https://accounts.spotify.com/authorize?response_type=code&client_id=%s&redirect_uri=%s&scope=%s&code_challenge_method=S256&code_challenge=%s&state=%s",
		grant.client_id,
		redirect,
		encoded_scopes,
		pkce,
		state,
	)
	return {state = state, verifier = verifier, url = address}
}

Callback :: enum {
	Ignored,
	Rejected,
	Denied,
	Authorized,
}

// Only accept the one localhost redirect with an exact random state. Other
// browser requests (including favicon and old redirects) can be ignored.
parse_callback :: proc(request_line, expected_state: string) -> (code: string, result: Callback) {
	if !strings.has_prefix(request_line, "GET ") {return "", .Ignored}
	rest := request_line[4:]
	space := strings.index_byte(rest, ' ')
	if space == -1 {return "", .Ignored}
	target := rest[:space]
	if !strings.has_prefix(target, "/login?") {return "", .Ignored}
	query := target[len("/login?"):]
	seen_state, seen_code, denied := false, false, false
	state, authorization_code: string
	for len(query) > 0 {
		separator := strings.index_byte(query, '&')
		pair := query
		if separator !=
		   -1 {pair, query = query[:separator], query[separator + 1:]} else {query = ""}
		equals := strings.index_byte(pair, '=')
		if equals == -1 {return "", .Rejected}
		value, ok := net.percent_decode(pair[equals + 1:], context.temp_allocator)
		if !ok {return "", .Rejected}
		switch pair[:equals] {
		case "state":
			if seen_state {return "", .Rejected}
			seen_state, state = true, value
		case "code":
			if seen_code {return "", .Rejected}
			seen_code, authorization_code = true, value
		case "error":
			denied = true
		}
	}
	if !seen_state ||
	   crypto.compare_constant_time(transmute([]u8)state, transmute([]u8)expected_state) != 1 {
		return "", .Rejected
	}
	if denied {return "", .Denied}
	if !seen_code || len(authorization_code) == 0 {return "", .Rejected}
	return strings.clone(authorization_code), .Authorized
}
