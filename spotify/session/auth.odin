// Streaming approval is separate from the user's Web API grant.
package session

import credential "../credential"
import oauth "../oauth"
import "core:crypto"
import "core:fmt"
import "core:net"
import "core:strings"
import "core:sync"
import "core:time"

// Playback and playlist workers must not open competing listeners on port 8898.
authorization_mutex: sync.Mutex
authorization_tokens: oauth.Tokens

clone_authorization :: proc(tokens: oauth.Tokens) -> oauth.Tokens {
	return {
		access = strings.clone(tokens.access),
		refresh = strings.clone(tokens.refresh),
		expires_at = tokens.expires_at,
	}
}

clear_authorization :: proc() {
	clear_connection()
	sync.mutex_guard(&authorization_mutex)
	oauth.wipe_tokens(&authorization_tokens)
}

authorize :: proc(
	keyring_mode: Keyring_Mode,
	cancel: ^bool = nil,
	refresh_token: string = "",
	force: bool = false,
	interactive: bool = true,
) -> (
	tokens: oauth.Tokens,
	ok: bool,
) {
	// Connect and library startup can reuse the same grant at the same
	// time. Wait for its owner instead of reporting a missing grant.
	for !sync.try_lock(&authorization_mutex) {
		if cancelled(cancel) {return}
		time.sleep(10 * time.Millisecond)
	}
	defer sync.unlock(&authorization_mutex)
	if cancel != nil && sync.atomic_load(cancel) {return}
	if !force && authorization_tokens.access != "" && !oauth.expired(authorization_tokens) {
		return clone_authorization(authorization_tokens), true
	}
	defer if ok {
		oauth.wipe_tokens(&authorization_tokens)
		authorization_tokens = clone_authorization(tokens)
	}
	stored: string
	found := false
	if keyring_mode != .None {stored, found = credential.load()}
	defer {crypto.zero_explicit(raw_data(stored), len(stored)); delete(stored)}
	refresh :=
		authorization_tokens.refresh != "" ? authorization_tokens.refresh : refresh_token != "" ? refresh_token : stored
	if refresh != "" {
		fresh, result := oauth.refresh(refresh)
		switch result {
		case .Authorized:
			if fresh.refresh == "" {fresh.refresh = strings.clone(refresh)}
			if keyring_mode != .None && !credential.save(fresh.refresh) {
				fmt.eprintln("keyring did not save rotated streaming sign-in")
			}
			return fresh, true
		case .Rejected:
			if found && refresh == stored {credential.clear()}
			authorization_tokens.expires_at = time.now()
		case .Network_Error, .Invalid_Response:
			fmt.eprintln(
				"could not refresh streaming sign-in; try again when Spotify is reachable",
			)
			return
		}
	}
	if cancel != nil && sync.atomic_load(cancel) {return}
	// A stored grant that would not refresh must not open a browser here;
	// callers that need the user present pass the default interactive=true.
	if !interactive {return}
	listener, ready := oauth.listen()
	if !ready {fmt.eprintln("cannot listen on 127.0.0.1:8898 (is another player using it?)"); return}
	defer net.close(listener)
	flow := oauth.begin()
	defer {
		oauth.publish_prompt(.Playback, "")
		crypto.zero_explicit(raw_data(flow.verifier), len(flow.verifier))
		delete(flow.verifier)
		delete(flow.state)
		delete(flow.url)
	}
	oauth.publish_prompt(.Playback, flow.url)
	code, result := oauth.wait_for_code(listener, flow.state, cancel)
	if result != .Authorized {
		if result != .Cancelled {fmt.eprintln("browser approval did not complete:", result)}
		return
	}
	defer {crypto.zero_explicit(raw_data(code), len(code)); delete(code)}
	status: oauth.Token_Result
	tokens, status = oauth.exchange_code(code, flow.verifier)
	if status != .Authorized {fmt.eprintln("token exchange did not complete:", status); return}
	if keyring_mode != .None && (tokens.refresh == "" || !credential.save(tokens.refresh)) {
		fmt.eprintln("system keyring unavailable; browser approval will be needed next time")
	}
	return tokens, true
}
