// Private reads use the streaming grant, never the user's Web API grant.
package library

import oauth "../oauth"
import session "../session"
import "base:runtime"
import "core:encoding/json"
import "core:mem/virtual"
import "core:sync"

PLAYLIST_AUTH_REQUIRED :: -3
PATHFINDER_QUERY_ADDRESS :: "https://api-partner.spotify.com/pathfinder/v2/query"

persisted_query_request :: proc(operation, hash: string, variables: $T) -> ([]u8, bool) {
	request := struct {
		operation_name: string `json:"operationName"`,
		variables:      T,
		extensions:     struct {
			query: struct {
				version: int,
				hash:    string `json:"sha256Hash"`,
			} `json:"persistedQuery"`,
		},
	} {
		operation_name = operation,
		variables = variables,
		extensions = {query = {version = 1, hash = hash}},
	}
	encoded, err := json.marshal(request, allocator = context.temp_allocator)
	return encoded, err == nil
}

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

// Artist artwork, listeners and Popular rows share the response arena.
// This optional read never starts browser approval.
read_artist_overview :: proc(
	client: ^Client,
	tokens: ^oauth.Tokens,
	detail: ^Detail,
	reuse: rawptr = nil,
) {
	if !authorize_session(client, tokens, interactive = false) {return}
	code := session.cached_country()
	country := ""
	if code != {} {country = string(code[:])}
	if fetch_artist_overview(tokens.access, detail, country, reuse, &client.cancel) {return}
	rows, _, ok := fetch_artist_top_tracks(
		tokens.access,
		detail.id,
		virtual.arena_allocator(&detail.arena),
		reuse,
		country = country,
	)
	if ok {detail.rows = rows}
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
