// Private reads use the streaming grant, never the user's Web API grant.
package library

import oauth "../oauth"
import session "../session"
import "base:runtime"
import "core:sync"

PLAYLIST_AUTH_REQUIRED :: -3

// interactive=false never starts browser approval. It reuses a live or
// saved grant, or waits for a grant another worker is already obtaining.
authorize_session :: proc(
	client: ^Client,
	tokens: ^oauth.Tokens,
	force: bool = false,
	interactive: bool = true,
) -> bool {
	if sync.atomic_load(&client.cancel) {return false}
	if !force && tokens.access != "" && !oauth.expired(tokens^) {return true}
	fresh, ok := session.authorize(
		.Remember,
		&client.cancel,
		tokens.refresh,
		force,
		interactive = interactive,
	)
	if !ok {return false}
	oauth.wipe_tokens(tokens)
	tokens^ = fresh
	return !sync.atomic_load(&client.cancel)
}

// Keep an initial account name alive through the request. Later pages
// borrow the account carried by their request and must not free it here.
read_session_rootlist :: proc(
	client: ^Client,
	tokens: ^oauth.Tokens,
	request: Request,
	reuse: rawptr = nil,
	get_account: type_of(session.account_name) = session.account_name,
	fetch: type_of(fetch_rootlist) = fetch_rootlist,
) -> (
	page: Page,
	status: int,
	ok: bool,
) {
	if !authorize_session(client, tokens, interactive = false) {return}
	account := request.account
	if account == "" {account = get_account(tokens.access, &client.cancel)}
	defer if request.account == "" {delete(account)}
	return fetch(tokens.access, account, request.offset, reuse, request.refresh)
}

// Artist top tracks, non-interactive: the section is optional, so it never
// prompts and simply stays hidden when no streaming grant is at hand.
read_artist_top_tracks :: proc(
	client: ^Client,
	tokens: ^oauth.Tokens,
	id: string,
	allocator: runtime.Allocator,
	reuse: rawptr = nil,
) -> (
	rows: [dynamic]Track_Row,
	status: int,
	ok: bool,
) {
	if !authorize_session(client, tokens, interactive = false) {return nil, 0, false}
	return fetch_artist_top_tracks(
		tokens.access,
		id,
		allocator,
		reuse,
		country = session.cached_country(),
	)
}

// Called only after the official playlist-items endpoint returns 403. Renew
// once on 401; other errors remain visible rather than triggering more logins.
read_session_playlist :: proc(
	client: ^Client,
	tokens: ^oauth.Tokens,
	id: string,
	offset: int,
	allocator: runtime.Allocator,
	reuse: rawptr = nil,
) -> (
	rows: [dynamic]Track_Row,
	total, next_offset: int,
	has_more: bool,
	status: int,
	ok: bool,
) {
	if !authorize_session(client, tokens) {return nil, 0, 0, false, PLAYLIST_AUTH_REQUIRED, false}
	rows, total, next_offset, has_more, status, ok = fetch_playlist_rows(
		tokens.access,
		id,
		offset,
		allocator,
		reuse,
	)
	if status == 401 && !sync.atomic_load(&client.cancel) {
		if !authorize_session(
			client,
			tokens,
			true,
		) {return nil, 0, 0, false, PLAYLIST_AUTH_REQUIRED, false}
		return fetch_playlist_rows(tokens.access, id, offset, allocator, reuse)
	}
	return
}
