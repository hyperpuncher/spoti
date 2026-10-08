// Private reads use the streaming grant, never the user's Web API grant.
package library

import oauth "../oauth"
import session "../session"
import "base:runtime"
import "core:sync"

PLAYLIST_AUTH_REQUIRED :: -3

// interactive=false never starts a browser sign-in; it only reuses a live or
// stored streaming grant. Sections that ride along with a page use it so an
// open never blocks on approval.
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
	)
	if status == 401 && !sync.atomic_load(&client.cancel) {
		if !authorize_session(
			client,
			tokens,
			true,
		) {return nil, 0, 0, false, PLAYLIST_AUTH_REQUIRED, false}
		return fetch_playlist_rows(tokens.access, id, offset, allocator)
	}
	return
}
