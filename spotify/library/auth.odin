// Separate Web API approval for account library reads and likes.
package library

import diagnostic "../../diagnostic"
import credential "../credential"
import oauth "../oauth"
import "core:crypto"
import "core:fmt"
import "core:os"
import "core:strings"
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

// The app key lives in the system keyring after the in-app setup; the
// environment overrides it for headless and development use. The caller
// owns the returned id.
resolve_client_id :: proc(allocator := context.allocator) -> (id: string, ok: bool) {
	env := os.get_env("WEB_CLIENT_ID", allocator)
	if valid_client_id(env) {return env, true}
	delete(env)
	stored, have := credential.load(.Library_Client)
	defer delete(stored)
	if !have || !valid_client_id(stored) {return "", false}
	return strings.clone(stored, allocator), true
}

// Tokens belong to the caller and must be wiped with oauth.wipe_tokens.
// A browser approval persists its refresh grant in the system keyring, so
// later launches refresh silently; rotation re-saves over the same entry.
authorize :: proc(cancel: ^bool = nil) -> (tokens: oauth.Tokens, result: Auth_Result) {
	client_id, key_ok := resolve_client_id()
	defer delete(client_id)
	if !key_ok {return {}, .Missing_Client_ID}
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
	response: oauth.Wait_Result
	status: oauth.Token_Result
	tokens, response, status = oauth.authorize(grant, .Library, cancel)
	if response == .Bind_Failed {
		fmt.eprintln("cannot listen for library browser approval")
		diagnostic.write("library authorize listen-failed")
		return {}, .Unavailable
	}
	diagnostic.writef("library browser=%v", response)
	if response == .Cancelled {return {}, .Cancelled}
	if response != .Authorized {return {}, .Unavailable}
	if status != .Authorized {return {}, .Unavailable}
	if len(tokens.refresh) > 0 && !credential.save(tokens.refresh, .Library) {
		fmt.eprintln("system keyring unavailable; library approval will be needed next time")
	}
	return tokens, .Ready
}
