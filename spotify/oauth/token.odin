package oauth

import http "../http"
import "core:crypto"
import "core:encoding/json"
import "core:fmt"
import "core:net"
import "core:strings"

Token_Result :: enum {
	Network_Error,
	Rejected,
	Invalid_Response,
	Authorized,
}

Tokens :: struct {
	access:  string,
	refresh: string,
}

wipe_tokens :: proc(tokens: ^Tokens) {
	crypto.zero_explicit(raw_data(tokens.access), len(tokens.access))
	crypto.zero_explicit(raw_data(tokens.refresh), len(tokens.refresh))
	delete(tokens.access)
	delete(tokens.refresh)
}

Token_Response :: struct {
	access_token:  string,
	refresh_token: string,
	scope:         string,
}

// Parsed into temporary memory. No response body or token is ever logged.
decode_token :: proc(
	status: int,
	body: []u8,
	require_scope := true,
	required_scope: string = "streaming",
) -> (
	tokens: Tokens,
	result: Token_Result,
) {
	if status == 400 || status == 401 || status == 403 {return {}, .Rejected}
	if status != 200 {return {}, .Network_Error}
	reply: Token_Response
	if json.unmarshal(body, &reply, allocator = context.temp_allocator) != nil ||
	   len(reply.access_token) == 0 {
		return {}, .Invalid_Response
	}
	if require_scope || len(reply.scope) > 0 {
		found := false
		for scope in strings.split(reply.scope, " ", context.temp_allocator) {
			if scope == required_scope {found = true; break}
		}
		if !found {return {}, .Rejected}
	}
	return {
			access = strings.clone(reply.access_token),
			refresh = strings.clone(reply.refresh_token),
		},
		.Authorized
}

// One-use authorization code + PKCE exchange. TLS verification is libcurl's
// default; redirects, verbose logs, disk storage and client secrets are unused.
exchange_code :: proc(
	code, verifier: string,
	grant: Grant = PLAYBACK_GRANT,
) -> (
	Tokens,
	Token_Result,
) {
	encoded_code := net.percent_encode(code)
	defer {crypto.zero_explicit(raw_data(encoded_code), len(encoded_code)); delete(encoded_code)}
	encoded_redirect := net.percent_encode(grant.redirect_uri)
	defer delete(encoded_redirect)
	encoded_verifier := net.percent_encode(verifier)
	defer {crypto.zero_explicit(raw_data(encoded_verifier), len(encoded_verifier))
		delete(encoded_verifier)}
	form := fmt.aprintf(
		"grant_type=authorization_code&client_id=%s&code=%s&redirect_uri=%s&code_verifier=%s",
		grant.client_id,
		encoded_code,
		encoded_redirect,
		encoded_verifier,
	)
	defer {crypto.zero_explicit(raw_data(form), len(form)); delete(form)}
	return token_request(form, true, grant.required_scope)
}

refresh :: proc(refresh_token: string, grant: Grant = PLAYBACK_GRANT) -> (Tokens, Token_Result) {
	encoded := net.percent_encode(refresh_token)
	defer {crypto.zero_explicit(raw_data(encoded), len(encoded)); delete(encoded)}
	form := fmt.aprintf(
		"grant_type=refresh_token&client_id=%s&refresh_token=%s",
		grant.client_id,
		encoded,
	)
	defer {crypto.zero_explicit(raw_data(form), len(form)); delete(form)}
	return token_request(form, false, grant.required_scope)
}

token_request :: proc(
	form: string,
	require_scope: bool,
	required_scope: string,
) -> (
	Tokens,
	Token_Result,
) {
	response, status, fetched := http.post_form("https://accounts.spotify.com/api/token", form)
	defer {crypto.zero_explicit(raw_data(response), len(response)); delete(response)}
	if !fetched {return {}, .Network_Error}
	return decode_token(status, response[:], require_scope, required_scope)
}
