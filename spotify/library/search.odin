// Catalog search across tracks, albums, artists and playlists. One endpoint
// returns all four types; each becomes a Page that the sidebar renders with
// the same cards as the library. Search keeps Spotify's relevance order and
// is never re-sorted by pins or recents.
package library

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:net"
import "core:strings"

// The schema caps search results at ten per type; larger limits fail.
SEARCH_LIMIT :: 10

// Search artists arrive in an offset page, unlike the cursor window used for
// followed artists. Albums, tracks and playlists share the index shapes.
Raw_Search :: struct {
	tracks:    Offset_Page(Track_Ref),
	albums:    Offset_Page(Album_Ref),
	artists:   Offset_Page(Artist),
	playlists: Offset_Page(Playlist_Ref),
}

fetch_search :: proc(
	access, query: string,
	reuse: rawptr = nil,
) -> (
	pages: [Kind]Page,
	status: int,
	ok: bool,
) {
	trimmed := strings.trim_space(query)
	if len(trimmed) == 0 || len(trimmed) > 256 {return}
	encoded := net.percent_encode(trimmed)
	defer delete(encoded)
	address := fmt.aprintf(
		"https://api.spotify.com/v1/search?q=%s&type=track,album,artist,playlist&limit=%d",
		encoded,
		SEARCH_LIMIT,
	)
	defer delete(address)
	bytes, code, fetched := api_get(access, address, 2 * 1024 * 1024, reuse)
	if !fetched {return {}, code, false}
	defer delete(bytes)
	if code != 200 {return {}, code, false}
	parsed, parsed_ok := parse_search(bytes[:])
	return parsed, code, parsed_ok
}

build_search_page :: proc(
	page: ^Page,
	window: Offset_Page($T),
	append_one: proc(items: ^[dynamic]Entry, row: T, allocator: runtime.Allocator),
) -> bool {
	if virtual.arena_init_growing(&page.arena) != nil {return false}
	page.ready = true
	allocator := virtual.arena_allocator(&page.arena)
	page.total = window.total
	page.has_more = false
	page.next_offset = window.offset + len(window.items)
	if !sane_page(page.total, len(window.items), page.next_offset) {
		free_page(page)
		return false
	}
	page.items = make([dynamic]Entry, 0, len(window.items), allocator)
	for row in window.items {append_one(&page.items, row, allocator)}
	return true
}

parse_search :: proc(body: []u8) -> (pages: [Kind]Page, ok: bool) {
	decoded: Raw_Search
	if json.unmarshal(body, &decoded, allocator = context.temp_allocator) != nil {return}
	if !build_search_page(&pages[.Playlists], decoded.playlists, append_playlist_entry) ||
	   !build_search_page(&pages[.Albums], decoded.albums, append_album_entry) ||
	   !build_search_page(&pages[.Artists], decoded.artists, append_artist_entry) ||
	   !build_search_page(&pages[.Tracks], decoded.tracks, append_track_entry) {
		for &page in pages {free_page(&page)}
		return {}, false
	}
	return pages, true
}

free_search_pages :: proc(pages: ^[Kind]Page) {
	for &page in pages {free_page(&page)}
}
