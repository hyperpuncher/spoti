// Bounded pages of real account library entries from Spotify's Web API.
// Each page owns one arena; strings and slices live there and are released in
// a single arena_destroy, the idiom from core:mem/virtual's own doc example.
package library

import session "../session"
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
	name:          string,
	uri:           string,
	image:         string, // cover URL; never a token or signed CDN URL
	subtitle:      string, // owner or artists
	year:          string, // album release year, e.g. "2024"
	saved:         bool, // came from a library tab, so membership needs no check
	total:         int, // track count where Spotify reports one
	album:         string, // track entries only, for the footer link
	album_uri:     string, // track entries only, for the footer link
	first_artist:  string, // track entries only, for the footer link
	artist_uri:    string, // track entries only, for the footer link
	owner_id:      string, // playlist entries only; who can add items
	collaborative: bool, // playlist entries only; collaborators can add items
}

Page :: struct {
	arena:       virtual.Arena,
	account:     string, // rootlist pagination belongs to this streaming account
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
		year = strings.clone(entry.year, allocator),
		saved = entry.saved,
		total = entry.total,
		album = strings.clone(entry.album, allocator),
		album_uri = strings.clone(entry.album_uri, allocator),
		first_artist = strings.clone(entry.first_artist, allocator),
		artist_uri = strings.clone(entry.artist_uri, allocator),
		owner_id = strings.clone(entry.owner_id, allocator),
		collaborative = entry.collaborative,
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
	album_type:   string,
}

Track_Ref :: struct {
	id:          string,
	name:        string,
	uri:         string,
	duration_ms: int,
	artists:     []Artist,
	album:       Album_Ref,
	is_playable: json.Value, // absent/null means availability is unknown
}

Playlist_Ref :: struct {
	id:            string,
	name:          string,
	uri:           string,
	images:        []Image,
	owner:         Owner,
	description:   string,
	collaborative: bool,
	banner:        string,
	items:         Count,
}

Saved_Track :: struct {
	track: Track_Ref,
}

Playlist_Item :: struct {
	added_at: string,
	item:     Track_Ref,
}

Saved_Album :: struct {
	album: Album_Ref,
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

Cover_Size :: enum {
	Card,
	Smallest,
	Largest,
}

// Cover choice shares URL validation and keeps the first image on ties.
// Missing dimensions count as 640 for cards/player, but 1 for heroes.
cover_url :: proc(images: []Image, size: Cover_Size = .Card) -> string {
	best := ""
	best_score := max(int)
	for image in images {
		if image.url == "" ||
		   len(image.url) > 512 ||
		   !strings.has_prefix(image.url, "https://") {continue}
		width := image.width
		if width <= 0 {width = size == .Largest ? 1 : 640}
		score := abs(width - 300)
		switch size {
		case .Card:
		case .Smallest:
			score = width
		case .Largest:
			score = -width
		}
		if best == "" || score < best_score {
			best, best_score = image.url, score
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

// Shared card builder for library and search grids. Missing artwork does
// not remove a saved collection; the grid draws its normal placeholder.
append_card_entry :: proc(
	items: ^[dynamic]Entry,
	name, uri, image, subtitle, year: string,
	total: int,
	allocator: runtime.Allocator,
	owner_id: string = "",
	collaborative: bool = false,
) {
	if len(name) == 0 ||
	   len(uri) == 0 ||
	   len(uri) > 128 ||
	   !strings.has_prefix(uri, "spotify:") {return}
	append(
		items,
		Entry {
			name = strings.clone(name, allocator),
			uri = strings.clone(uri, allocator),
			image = strings.clone(image, allocator),
			subtitle = strings.clone(subtitle, allocator),
			year = release_year(year, allocator),
			total = total,
			owner_id = strings.clone(owner_id, allocator),
			collaborative = collaborative,
		},
	)
}

// Spotify sends a full release date; the hero and the cards only show a year.
release_year :: proc(date: string, allocator: runtime.Allocator) -> string {
	if len(date) < 4 {return ""}
	return strings.clone(date[:4], allocator)
}

append_playlist_entry :: proc(
	items: ^[dynamic]Entry,
	row: Playlist_Ref,
	allocator: runtime.Allocator,
) {
	append_card_entry(
		items,
		row.name,
		row.uri,
		cover_url(row.images),
		row.owner.display_name,
		"",
		row.items.total,
		allocator,
		owner_id = row.owner.id,
		collaborative = row.collaborative,
	)
}

append_album_entry :: proc(
	items: ^[dynamic]Entry,
	album: Album_Ref,
	allocator: runtime.Allocator,
) {
	append_saved_album(items, Saved_Album{album = album}, allocator)
}

append_saved_album :: proc(
	items: ^[dynamic]Entry,
	row: Saved_Album,
	allocator: runtime.Allocator,
) {
	album := row.album
	append_card_entry(
		items,
		album.name,
		album.uri,
		cover_url(album.images),
		joined_artists(album.artists, context.temp_allocator),
		album.release_date,
		album.total_tracks,
		allocator,
	)
}

append_artist_entry :: proc(items: ^[dynamic]Entry, row: Artist, allocator: runtime.Allocator) {
	if len(row.id) == 0 {return}
	uri := row.uri
	if len(uri) ==
	   0 {uri = fmt.aprintf("spotify:artist:%s", row.id, allocator = context.temp_allocator)}
	append_card_entry(items, row.name, uri, cover_url(row.images), "Artist", "", 0, allocator)
}

track_available :: proc(track: Track_Ref) -> bool {
	if playable, reported := track.is_playable.(bool); reported && !playable {return false}
	return !session.track_unavailable(track.uri)
}

append_track_entry :: proc(
	items: ^[dynamic]Entry,
	track: Track_Ref,
	allocator: runtime.Allocator,
) {
	if !track_available(track) || len(track.name) == 0 || len(track.uri) > 128 {return}
	first_artist, artist_uri := "", ""
	if len(track.artists) > 0 {
		first_artist = strings.clone(track.artists[0].name, allocator)
		artist_uri = strings.clone(track.artists[0].uri, allocator)
	}
	append(
		items,
		Entry {
			name = strings.clone(track.name, allocator),
			uri = strings.clone(track.uri, allocator),
			image = strings.clone(cover_url(track.album.images), allocator),
			subtitle = joined_artists(track.artists, allocator),
			album = strings.clone(track.album.name, allocator),
			album_uri = strings.clone(track.album.uri, allocator),
			first_artist = first_artist,
			artist_uri = artist_uri,
		},
	)
}

fetch_index :: proc(
	access: string,
	kind: Kind,
	offset: int = 0,
	cursor: string = "",
	reuse: rawptr = nil,
	retry_after: ^int = nil,
	refresh: bool = false,
	cache_only: bool = false,
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
	bytes, status, fetched = api_get(
		access,
		address,
		512 * 1024,
		reuse,
		retry_after,
		PAGE_TTL,
		refresh = refresh,
		cache_only = cache_only,
	)
	if !fetched {return {}, status, false}
	defer delete(bytes)
	if status != 200 {return {}, status, false}
	page, ok = parse_index(bytes[:], kind)
	return page, status, ok
}

build_offset_page :: proc(
	page: ^Page,
	window: Offset_Page($T),
	append_one: proc(items: ^[dynamic]Entry, row: T, allocator: runtime.Allocator),
) -> bool {
	if virtual.arena_init_growing(&page.arena) != nil {return false}
	page.ready = true
	allocator := virtual.arena_allocator(&page.arena)
	page.total = window.total
	page.has_more = window.next != ""
	page.next_offset = window.offset + len(window.items)
	if !sane_page(page.total, len(window.items), page.next_offset) {
		free_page(page)
		return false
	}
	page.items = make([dynamic]Entry, 0, len(window.items), allocator)
	for row in window.items {append_one(&page.items, row, allocator)}
	return true
}

parse_offset_page :: proc(
	body: []u8,
	page: ^Page,
	$T: typeid,
	append_one: proc(items: ^[dynamic]Entry, row: T, allocator: runtime.Allocator),
) -> bool {
	decoded: Offset_Page(T)
	if json.unmarshal(body, &decoded, allocator = context.temp_allocator) != nil {return false}
	return build_offset_page(page, decoded, append_one)
}

parse_index :: proc(body: []u8, kind: Kind) -> (page: Page, ok: bool) {
	switch kind {
	case .Playlists:
		ok = parse_offset_page(body, &page, Playlist_Ref, append_playlist_entry)
	case .Albums:
		ok = parse_offset_page(body, &page, Saved_Album, append_saved_album)
	case .Tracks:
		ok = parse_offset_page(body, &page, Saved_Track, append_saved_track)
	case .Artists:
		if virtual.arena_init_growing(&page.arena) != nil {return}
		page.ready = true
		ok = parse_artists(body, &page, virtual.arena_allocator(&page.arena))
	}
	if !ok {free_page(&page); return}
	for &entry in page.items {entry.saved = true}
	return
}

append_saved_track :: proc(
	items: ^[dynamic]Entry,
	row: Saved_Track,
	allocator: runtime.Allocator,
) {
	append_track_entry(items, row.track, allocator)
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
	for row in window.items {append_artist_entry(&page.items, row, allocator)}
	return true
}

// Stable cache key for a cover URL on the UI side.
url_key :: proc(url: string) -> u64 {
	return hash.fnv64a(transmute([]u8)url)
}

sane_page :: proc(total, rows, offset: int, limit := 50) -> bool {
	return total >= 0 && total <= 1_000_000 && rows <= limit && offset >= 0
}
