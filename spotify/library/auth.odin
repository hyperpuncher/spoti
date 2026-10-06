// Separate Web API approval for account library reads and likes.
package library

import diagnostic "../../diagnostic"
import credential "../credential"
import oauth "../oauth"
import "core:crypto"
import "core:fmt"
import "core:net"
import "core:os"
import "core:sync"

Auth_Result :: enum {
	Ready,
	Missing_Client_ID,
	Unavailable,
	Cancelled,
}

valid_client_id :: proc(id: string) -> bool {
	if len(id) != 32 {return false}
	for ch in transmute([]u8)id {
		if !(ch >= '0' && ch <= '9' ||
			   ch >= 'a' && ch <= 'f' ||
			   ch >= 'A' && ch <= 'F') {return false}
	}
	return true
}

// Tokens belong to the caller and must be wiped with oauth.wipe_tokens.
// The refresh grant is saved only after explicit opt-in via `just remember`.
authorize :: proc(
	remember: bool,
	cancel: ^bool = nil,
) -> (
	tokens: oauth.Tokens,
	result: Auth_Result,
) {
	client_id := os.get_env("WEB_CLIENT_ID", context.allocator)
	defer delete(client_id)
	if !valid_client_id(client_id) {return {}, .Missing_Client_ID}
	grant := oauth.web_grant(client_id)
	saved, found := credential.load(.Library)
	diagnostic.writef("library authorize saved=%v", found)
	if found {
		fresh, status := oauth.refresh(saved, grant)
		crypto.zero_explicit(raw_data(saved), len(saved))
		delete(saved)
		diagnostic.writef("library refresh=%v", status)
		switch status {
		case .Authorized:
			if len(fresh.refresh) > 0 && !credential.save(fresh.refresh, .Library) {
				fmt.eprintln("could not save rotated library sign-in")
			}
			return fresh, .Ready
		case .Rejected:
			credential.clear(.Library)
		case .Network_Error, .Invalid_Response:
			return {}, .Unavailable
		}
	}
	if cancel != nil && sync.atomic_load(cancel) {return {}, .Cancelled}
	listener, listening := oauth.listen(int(grant.port))
	if !listening {
		fmt.eprintln("cannot listen for library browser approval")
		diagnostic.write("library authorize listen-failed")
		return {}, .Unavailable
	}
	defer net.close(listener)
	flow := oauth.begin(grant)
	defer {
		crypto.zero_explicit(raw_data(flow.verifier), len(flow.verifier))
		delete(flow.verifier)
		delete(flow.state)
		delete(flow.url)
	}
	fmt.println("Open this URL in your browser to allow Spotify library access:")
	fmt.println(flow.url)
	code, response := oauth.wait_for_code(listener, flow.state, cancel)
	diagnostic.writef("library browser=%v", response)
	if response == .Cancelled {return {}, .Cancelled}
	if response != .Authorized {return {}, .Unavailable}
	defer {crypto.zero_explicit(raw_data(code), len(code)); delete(code)}
	status: oauth.Token_Result
	tokens, status = oauth.exchange_code(code, flow.verifier, grant)
	if status != .Authorized {return {}, .Unavailable}
	if remember && len(tokens.refresh) > 0 && !credential.save(tokens.refresh, .Library) {
		fmt.eprintln("system keyring unavailable; library approval will be needed next time")
	}
	return tokens, .Ready
}
