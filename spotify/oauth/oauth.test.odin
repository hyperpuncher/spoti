package oauth

import "core:strings"
import "core:testing"
import "core:time"

@(test)
pkce_rfc7636_vector :: proc(t: ^testing.T) {
	// RFC 7636 Appendix B, independent of Spotify and the browser.
	verifier := "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"
	got := challenge(verifier)
	defer delete(got)
	testing.expect(t, got == "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
}

@(test)
authorization_uses_pkce_and_fresh_state :: proc(t: ^testing.T) {
	first := begin()
	defer {delete(first.state); delete(first.verifier); delete(first.url)}
	second := begin()
	defer {delete(second.state); delete(second.verifier); delete(second.url)}
	testing.expect(t, first.state != second.state && first.verifier != second.verifier)
	testing.expect(t, len(first.state) == 43 && len(first.verifier) == 43)
	testing.expect(t, strings.contains(first.url, "scope=streaming"))
	testing.expect(t, strings.contains(first.url, "code_challenge_method=S256"))
	testing.expect(
		t,
		strings.contains(first.url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A8898%2Flogin"),
	)
	testing.expect(t, !strings.contains(first.url, first.verifier))
}

@(test)
web_grant_is_separate_and_write_capable :: proc(t: ^testing.T) {
	grant := web_grant("example-public-client-id")
	flow := begin(grant)
	defer {delete(flow.url); delete(flow.state); delete(flow.verifier)}
	testing.expect(t, strings.contains(flow.url, "client_id=example-public-client-id"))
	testing.expect(
		t,
		strings.contains(flow.url, "redirect_uri=http%3A%2F%2F127.0.0.1%3A8989%2Flogin"),
	)
	testing.expect(t, strings.contains(flow.url, "user-library-read"))
	testing.expect(t, strings.contains(flow.url, "user-library-modify"))
	// Sessions approved without the write scopes re-approve once.
	old: string = `{"access_token":"fake","scope":"playlist-read-private user-library-read"}`
	_, old_result := decode_token(200, transmute([]u8)old, true, grant.required_scope)
	testing.expect(t, old_result == .Rejected)
	fresh: string = `{"access_token":"fake","scope":"playlist-read-private user-library-read user-library-modify"}`
	tokens, result := decode_token(200, transmute([]u8)fresh, true, grant.required_scope)
	defer wipe_tokens(&tokens)
	testing.expect(t, result == .Authorized)
}

@(test)
token_requires_streaming_scope_and_successful_response :: proc(t: ^testing.T) {
	body: string = `{"access_token":"fake-test-token","refresh_token":"fake-refresh","token_type":"Bearer","scope":"streaming","expires_in":3600}`
	tokens, result := decode_token(200, transmute([]u8)body)
	defer wipe_tokens(&tokens)
	testing.expect(
		t,
		result == .Authorized &&
		tokens.access == "fake-test-token" &&
		tokens.refresh == "fake-refresh",
	)
	testing.expect(t, tokens.expires_at != time.Time{} && !expired(tokens))
	tokens.expires_at = time.time_add(time.now(), -time.Second)
	testing.expect(t, expired(tokens))
	_, result = decode_token(401, transmute([]u8)body)
	testing.expect(t, result == .Rejected)
	wrong_scope: string = `{"access_token":"fake-test-token","scope":"user-read-private"}`
	_, result = decode_token(200, transmute([]u8)wrong_scope)
	testing.expect(t, result == .Rejected)
	invalid_json: string = `not json`
	_, result = decode_token(200, transmute([]u8)invalid_json)
	testing.expect(t, result == .Invalid_Response)
	refreshed: string = `{"access_token":"fake-new-token"}`
	new_tokens: Tokens
	new_tokens, result = decode_token(200, transmute([]u8)refreshed, false)
	defer wipe_tokens(&new_tokens)
	testing.expect(
		t,
		result == .Authorized && new_tokens.access == "fake-new-token" && new_tokens.refresh == "",
	)
}

@(test)
waiting_for_browser_can_be_cancelled :: proc(t: ^testing.T) {
	cancel := true
	_, result := wait_for_code({}, "state", &cancel)
	testing.expect(t, result == .Cancelled)
}

@(test)
callback_rejects_forgery_and_accepts_authorization :: proc(t: ^testing.T) {
	code, status := parse_callback("GET /login?state=correct&code=one%2Btwo HTTP/1.1", "correct")
	defer delete(code)
	testing.expect(t, status == .Authorized && code == "one+two")
	_, status = parse_callback("GET /login?state=wrong&code=secret HTTP/1.1", "correct")
	testing.expect(t, status == .Rejected)
	_, status = parse_callback(
		"GET /login?state=correct&state=correct&code=secret HTTP/1.1",
		"correct",
	)
	testing.expect(t, status == .Rejected)
	_, status = parse_callback(
		"GET /login?state=correct&code=secret&code=secret HTTP/1.1",
		"correct",
	)
	testing.expect(t, status == .Rejected)
	_, status = parse_callback("GET /login?state=correct&error=access_denied HTTP/1.1", "correct")
	testing.expect(t, status == .Denied)
	_, status = parse_callback("GET /favicon.ico HTTP/1.1", "correct")
	testing.expect(t, status == .Ignored)
	_, status = parse_callback("GET /login?state=correct&code=%zz HTTP/1.1", "correct")
	testing.expect(t, status == .Rejected)
}

@(test)
web_grant_requests_library_write_scopes :: proc(t: ^testing.T) {
	grant := web_grant("0123456789abcdef0123456789abcdef")
	for scope in ([]string{"user-library-modify", "user-follow-modify", "playlist-modify-public"}) {
		testing.expect(t, strings.contains(grant.scopes, scope), scope)
	}
	testing.expect_value(t, grant.required_scope, "user-library-modify")
}
