// Bounded pages of real account library entries from Spotify's Web API.
// Each page owns one arena; strings and slices live there and are released in
// a single arena_destroy, the idiom from core:mem/virtual's own doc example.
package library

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:hash"
import "core:mem/virtual"
import "core:net"
import "core:strings"

Kind :: enum {
	Playlists,
	Tracks,
	Albums,
	Artists,
}

// One library card: a playlist, album or artist with its cover and metadata.
Entry :: struct {
	name:     string,
	uri:      string,
	image:    string, // cover URL; never a token or signed CDN URL
	subtitle: string, // owner or artists
	total:    int, // track count where Spotify reports one
}

Page :: struct {
	arena:       virtual.Arena,
	ready:       bool,
	items:       [dynamic]Entry,
	total:       int,
	next_offset: int,
	cursor:      string,
	has_more:    bool,
}

free_page :: proc(page: ^Page) {
	virtual.arena_destroy(&page.arena)
	page^ = {}
}

clone_entry :: proc(entry: Entry, allocator: runtime.Allocator) -> Entry {
	return {
		name = strings.clone(entry.name, allocator),
		uri = strings.clone(entry.uri, allocator),
		image = strings.clone(entry.image, allocator),
		subtitle = strings.clone(entry.subtitle, allocator),
		total = entry.total,
	}
}

Image :: struct {
	url:    string,
	width:  int,
	height: int,
}

Artist :: struct {
	id:     string,
	name:   string,
	uri:    string,
	images: []Image,
}

Owner :: struct {
	id:           string,
	display_name: string,
}

Count :: struct {
	total: int,
}

Album_Ref :: struct {
	id:           string,
	name:         string,
	uri:          string,
	images:       []Image,
	artists:      []Artist,
	release_date: string,
	total_tracks: int,
}

Track_Ref :: struct {
	id:          string,
	name:        string,
	uri:         string,
	duration_ms: int,
	artists:     []Artist,
	album:       Album_Ref,
}

Playlist_Ref :: struct {
	id:          string,
	name:        string,
	uri:         string,
	images:      []Image,
	owner:       Owner,
	description: string,
	items:       Count,
}

Saved_Track :: struct {
	added_at: string,
	track:    Track_Ref,
}

Playlist_Item :: struct {
	added_at: string,
	item:     Track_Ref,
}

Saved_Album :: struct {
	added_at: string,
	album:    Album_Ref,
}

Artist_Cursor :: struct {
	after: string,
}

Artist_Window :: struct {
	items:   []Artist,
	total:   int,
	next:    string,
	cursors: Artist_Cursor,
}

Offset_Page :: struct($T: typeid) {
	items:  []T,
	total:  int,
	offset: int,
	next:   string,
}

Raw_Followed_Artists :: struct {
	artists: Artist_Window,
}

// Prefer a roughly card-sized cover; Spotify orders images largest first.
cover_url :: proc(images: []Image) -> string {
	best := ""
	best_distance := 1 << 30
	for image in images {
		if len(image.url) == 0 ||
		   len(image.url) > 512 ||
		   !strings.has_prefix(image.url, "https://") {continue}
		width := image.width
		if width <= 0 {width = 640}
		distance := width > 300 ? width - 300 : 300 - width
		if best == "" || distance < best_distance {
			best, best_distance = image.url, distance
		}
	}
	return best
}

// The smallest valid image is enough for the compact now-playing cover.
cover_url_smallest :: proc(images: []Image) -> string {
	best := ""
	best_width := 1 << 30
	for image in images {
		if len(image.url) == 0 ||
		   len(image.url) > 512 ||
		   !strings.has_prefix(image.url, "https://") {continue}
		width := image.width
		if width <= 0 {width = 640}
		if best == "" || width < best_width {
			best, best_width = image.url, width
		}
	}
	return best
}

// The largest valid image is used for detail heroes. Spotify orders images
// widest first, but choose by dimensions so malformed ordering is harmless.
cover_url_largest :: proc(images: []Image) -> string {
	best := ""
	best_width := -1
	for image in images {
		if len(image.url) == 0 ||
		   len(image.url) > 512 ||
		   !strings.has_prefix(image.url, "https://") {continue}
		width := image.width
		if width <= 0 {width = 1}
		if best == "" || width > best_width {
			best, best_width = image.url, width
		}
	}
	return best
}

// Artist names joined into one display string, allocated on `allocator`.
joined_artists :: proc(artists: []Artist, allocator: runtime.Allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	for artist, index in artists {
		if index > 0 {strings.write_string(&builder, ", ")}
		strings.write_string(&builder, artist.name)
	}
	return strings.to_string(builder)
}

fetch_index :: proc(
	access: string,
	kind: Kind,
	offset: int = 0,
	cursor: string = "",
) -> (
	page: Page,
	status: int,
	ok: bool,
) {
	if offset < 0 || offset > 1_000_000 || len(cursor) > 128 {return}
	endpoint := "playlists"
	switch kind {
	case .Tracks:
		endpoint = "tracks"
	case .Albums:
		endpoint = "albums"
	case .Artists:
		endpoint = "following"
	case .Playlists:
	}
	query: string
	if kind == .Artists {
		query = fmt.aprintf("?type=artist&limit=36")
		if len(cursor) > 0 {
			encoded := net.percent_encode(cursor)
			defer delete(encoded)
			delete(query)
			query = fmt.aprintf("?type=artist&limit=36&after=%s", encoded)
		}
	} else {
		query = fmt.aprintf("?limit=36&offset=%d", offset)
	}
	defer delete(query)
	address := fmt.aprintf("https://api.spotify.com/v1/me/%s%s", endpoint, query)
	defer delete(address)
	bytes: [dynamic]u8
	fetched: bool
	bytes, status, fetched = api_get(access, address, 512 * 1024)
	if !fetched {return {}, status, false}
	defer delete(bytes)
	if status != 200 {return {}, status, false}
	page, ok = parse_index(bytes[:], kind)
	return page, status, ok
}

parse_index :: proc(body: []u8, kind: Kind) -> (page: Page, ok: bool) {
	arena_error := virtual.arena_init_growing(&page.arena)
	if arena_error != nil {return {}, false}
	page.ready = true
	allocator := virtual.arena_allocator(&page.arena)
	switch kind {
	case .Playlists:
		ok = parse_playlists(body, &page, allocator)
	case .Albums:
		ok = parse_albums(body, &page, allocator)
	case .Artists:
		ok = parse_artists(body, &page, allocator)
	case .Tracks:
		ok = parse_tracks(body, &page, allocator)
	}
	if !ok {free_page(&page)}
	return page, ok
}

parse_playlists :: proc(body: []u8, page: ^Page, allocator: runtime.Allocator) -> bool {
	decoded: Offset_Page(Playlist_Ref)
	if json.unmarshal(body, &decoded, allocator = context.temp_allocator) != nil {return false}
	page.total = decoded.total
	page.has_more = len(decoded.next) > 0
	page.next_offset = decoded.offset + len(decoded.items)
	if !sane_page(page.total, len(decoded.items), page.next_offset) {return false}
	page.items = make([dynamic]Entry, 0, len(decoded.items), allocator)
	for row in decoded.items {
		total := row.items.total
		image := cover_url(row.images)
		if len(row.name) == 0 || len(row.uri) > 128 || image == "" {continue}
		append(
			&page.items,
			Entry {
				name = strings.clone(row.name, allocator),
				uri = strings.clone(row.uri, allocator),
				image = strings.clone(image, allocator),
				subtitle = strings.clone(row.owner.display_name, allocator),
				total = total,
			},
		)
	}
	return true
}

parse_albums :: proc(body: []u8, page: ^Page, allocator: runtime.Allocator) -> bool {
	decoded: Offset_Page(Saved_Album)
	if json.unmarshal(body, &decoded, allocator = context.temp_allocator) != nil {return false}
	page.total = decoded.total
	page.has_more = len(decoded.next) > 0
	page.next_offset = decoded.offset + len(decoded.items)
	if !sane_page(page.total, len(decoded.items), page.next_offset) {return false}
	page.items = make([dynamic]Entry, 0, len(decoded.items), allocator)
	for row in decoded.items {
		image := cover_url(row.album.images)
		if len(row.album.name) == 0 || len(row.album.uri) > 128 || image == "" {continue}
		append(
			&page.items,
			Entry {
				name = strings.clone(row.album.name, allocator),
				uri = strings.clone(row.album.uri, allocator),
				image = strings.clone(image, allocator),
				subtitle = joined_artists(row.album.artists, allocator),
				total = row.album.total_tracks,
			},
		)
	}
	return true
}

parse_artists :: proc(body: []u8, page: ^Page, allocator: runtime.Allocator) -> bool {
	decoded: Raw_Followed_Artists
	if json.unmarshal(body, &decoded, allocator = context.temp_allocator) != nil {return false}
	window := decoded.artists
	page.total = window.total
	page.has_more = len(window.next) > 0 && len(window.cursors.after) > 0
	if page.has_more {page.cursor = strings.clone(window.cursors.after, allocator)}
	page.next_offset = len(window.items)
	if !sane_page(page.total, len(window.items), page.next_offset) {return false}
	page.items = make([dynamic]Entry, 0, len(window.items), allocator)
	for row in window.items {
		if len(row.name) == 0 || len(row.id) == 0 {continue}
		uri := row.uri
		if len(uri) ==
		   0 {uri = fmt.aprintf("spotify:artist:%s", row.id, allocator = context.temp_allocator)}
		append(
			&page.items,
			Entry {
				name = strings.clone(row.name, allocator),
				uri = strings.clone(uri, allocator),
				image = strings.clone(cover_url(row.images), allocator),
				subtitle = strings.clone("Artist", allocator),
			},
		)
	}
	return true
}

// Saved songs are shown as a track list, not as cards.
parse_tracks :: proc(body: []u8, page: ^Page, allocator: runtime.Allocator) -> bool {
	decoded: Offset_Page(Saved_Track)
	if json.unmarshal(body, &decoded, allocator = context.temp_allocator) != nil {return false}
	page.total = decoded.total
	page.has_more = len(decoded.next) > 0
	page.next_offset = decoded.offset + len(decoded.items)
	if !sane_page(page.total, len(decoded.items), page.next_offset) {return false}
	page.items = make([dynamic]Entry, 0, len(decoded.items), allocator)
	for row in decoded.items {
		track := row.track
		if len(track.name) == 0 || len(track.uri) > 128 {continue}
		append(
			&page.items,
			Entry {
				name = strings.clone(track.name, allocator),
				uri = strings.clone(track.uri, allocator),
				image = strings.clone(cover_url(track.album.images), allocator),
				subtitle = joined_artists(track.artists, allocator),
			},
		)
	}
	return true
}

// Stable cache key for a cover URL on the UI side.
url_key :: proc(url: string) -> u64 {
	return hash.fnv64a(transmute([]u8)url)
}

sane_page :: proc(total, rows, offset: int, limit := 50) -> bool {
	return total >= 0 && total <= 1_000_000 && rows <= limit && offset >= 0
}
