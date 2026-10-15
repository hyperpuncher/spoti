package library

import "core:mem/virtual"
import "core:strings"

// Resolve an album before writing. Playlist endpoints accept tracks, not albums.
// Fetch and write share the library worker's handle; the UI keeps its page.
add_playlist_entry :: proc(
	access, playlist_id, uri: string,
	reuse: rawptr = nil,
	fetch: type_of(fetch_track_page) = fetch_track_page,
	write: type_of(edit_playlist_items) = edit_playlist_items,
) -> (
	status: int,
	ok: bool,
	added: int,
) {
	if !strings.has_prefix(uri, "spotify:album:") {
		status, ok = write(access, playlist_id, []string{uri}, reuse)
		return status, ok, ok ? 1 : 0
	}
	id := uri[len("spotify:album:"):]
	if !safe_id(id) {return}
	arena: virtual.Arena
	if virtual.arena_init_growing(&arena) != nil {return}
	defer virtual.arena_destroy(&arena)
	allocator := virtual.arena_allocator(&arena)
	uris := make([dynamic]string, allocator)
	offset := 0
	for {
		rows, _, next, more, code, fetched := fetch(
			access,
			.Album,
			id,
			offset,
			allocator,
			reuse = reuse,
		)
		if !fetched {return code, false, 0}
		for row in rows {
			if strings.has_prefix(row.uri, "spotify:track:") {append(&uris, row.uri)}
		}
		if !more {break}
		if next <= offset {return PLAYLIST_INVALID_RESPONSE, false, 0}
		offset = next
	}
	if len(uris) == 0 {return}
	for first := 0; first < len(uris); first += ADD_ITEMS_MAX {
		last := min(first + ADD_ITEMS_MAX, len(uris))
		status, ok = write(access, playlist_id, uris[first:last], reuse)
		if !ok {return status, false, added}
		added += last - first
	}
	return status, true, added
}
