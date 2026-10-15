// Catalog search across tracks, albums, artists and playlists. One endpoint
// returns all four types; each becomes a Page that the sidebar renders with
// the same cards as the library. Search keeps Spotify's relevance order and
// is never re-sorted by pins or recents.
package library

import "core:encoding/json"
import "core:fmt"
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

parse_search :: proc(body: []u8) -> (pages: [Kind]Page, ok: bool) {
	decoded: Raw_Search
	if json.unmarshal(body, &decoded, allocator = context.temp_allocator) != nil {return}
	if !build_page(&pages[.Playlists], decoded.playlists) ||
	   !build_page(&pages[.Albums], decoded.albums) ||
	   !build_page(&pages[.Artists], decoded.artists) ||
	   !build_page(&pages[.Tracks], decoded.tracks) {
		for &page in pages {free_page(&page)}
		return {}, false
	}
	// Search keeps the returned relevance window and does not load more.
	for &page in pages {page.has_more = false}
	return pages, true
}

free_search_pages :: proc(pages: ^[Kind]Page) {
	for &page in pages {free_page(&page)}
}
