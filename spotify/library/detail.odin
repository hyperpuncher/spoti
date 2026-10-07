// A playlist, album, artist or liked-songs page: header metadata plus its rows.
// Like a library page, a detail owns one arena and is released in one call.
package library

import http "../http"
import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
import "core:net"
import "core:strings"

Source :: enum {
	Liked,
	Playlist,
	Album,
	Artist,
}

Track_Row :: struct {
	uri:         string,
	name:        string,
	artists:     string,
	duration_ms: int,
	image:       string,
	image_small: string,
}

Detail :: struct {
	arena:         virtual.Arena,
	ready:         bool,
	liked:         bool, // in the account library; hero heart state
	source:        Source,
	id:            string,
	label:         string, // Album, Playlist, Artist or Liked Songs
	name:          string,
	subtitle:      string,
	year:          string, // album release year, e.g. "2024"
	image:         string,
	image_small:   string,
	image_preview: string, // selected card cover, retained until hero texture is ready
	total:         int,
	rows:          [dynamic]Track_Row,
	releases:      [dynamic]Entry,
	next_offset:   int,
	has_more:      bool,
	rows_error:    int,
	more_failures: int, // consecutive failed page fetches; the auto-chain stops at 3
	generation:    uint, // a reopened page keeps its URI but never its generation
}

free_detail :: proc(detail: ^Detail) {
	virtual.arena_destroy(&detail.arena)
	detail^ = {}
}

// Transferring the arena does not update allocator pointers inside its arrays.
move_detail :: proc(destination, source: ^Detail) {
	free_detail(destination)
	destination^ = source^
	allocator := virtual.arena_allocator(&destination.arena)
	destination.rows.allocator = allocator
	destination.releases.allocator = allocator
	source^ = {}
}

clone_row :: proc(row: Track_Row, allocator: runtime.Allocator) -> Track_Row {
	return {
		uri = strings.clone(row.uri, allocator),
		name = strings.clone(row.name, allocator),
		artists = strings.clone(row.artists, allocator),
		duration_ms = row.duration_ms,
		image = strings.clone(row.image, allocator),
		image_small = strings.clone(row.image_small, allocator),
	}
}

Raw_Artist :: struct {
	name:   string,
	images: []Image,
}

// Header and the first page of rows, so a page opens with one cached round trip
// per Spotify resource. Never follow a server-supplied pagination URL.
fetch_detail :: proc(
	access: string,
	source: Source,
	id: string,
	session_access: string = "",
	reuse: rawptr = nil,
	cache_only: bool = false,
) -> (
	detail: Detail,
	status: int,
	ok: bool,
) {
	if virtual.arena_init_growing(&detail.arena) != nil {return {}, 0, false}
	detail.ready = true
	allocator := virtual.arena_allocator(&detail.arena)
	detail.source = source
	switch source {
	case .Liked:
		detail.label = strings.clone("Playlist", allocator)
		detail.name = strings.clone("Liked Songs", allocator)
		detail.subtitle = strings.clone("Your saved songs", allocator)
	case .Playlist:
		header, header_status, header_ok := fetch_header(
			Playlist_Ref,
			access,
			id,
			"playlists",
			reuse = reuse,
			cache_only = cache_only,
		)
		if !header_ok {
			free_detail(&detail)
			return {}, header_status, false
		}
		detail.label = strings.clone("Playlist", allocator)
		detail.name = strings.clone(header.name, allocator)
		detail.subtitle = strings.clone(header.owner.display_name, allocator)
		detail.image = strings.clone(cover_url_largest(header.images), allocator)
		detail.image_small = strings.clone(cover_url_smallest(header.images), allocator)
		detail.total = header.items.total
	case .Album:
		header, header_status, header_ok := fetch_header(
			Album_Ref,
			access,
			id,
			"albums",
			reuse = reuse,
			cache_only = cache_only,
		)
		if !header_ok {
			free_detail(&detail)
			return {}, header_status, false
		}
		detail.label = strings.clone("Album", allocator)
		detail.name = strings.clone(header.name, allocator)
		detail.subtitle = joined_artists(header.artists, allocator)
		detail.year = release_year(header.release_date, allocator)
		detail.image = strings.clone(cover_url_largest(header.images), allocator)
		detail.image_small = strings.clone(cover_url_smallest(header.images), allocator)
		detail.total = header.total_tracks
	case .Artist:
		header, header_status, header_ok := fetch_header(
			Raw_Artist,
			access,
			id,
			"artists",
			reuse = reuse,
			cache_only = cache_only,
		)
		if !header_ok {
			free_detail(&detail)
			return {}, header_status, false
		}
		detail.label = strings.clone("Artist", allocator)
		detail.name = strings.clone(header.name, allocator)
		detail.subtitle = strings.clone("Artist", allocator)
		detail.image = strings.clone(cover_url_largest(header.images), allocator)
		detail.image_small = strings.clone(cover_url_smallest(header.images), allocator)
	}
	detail.id = strings.clone(id, allocator)
	if source == .Artist {
		releases, total, next_offset, has_more, releases_status, releases_ok :=
			fetch_artist_albums(access, id, 0, allocator, cache_only = cache_only)
		if !releases_ok {
			free_detail(&detail)
			return {}, releases_status, false
		}
		detail.releases = releases
		detail.total = total
		detail.next_offset = next_offset
		detail.has_more = has_more
		return detail, 200, true
	}
	rows, total, next_offset, has_more, rows_status, rows_ok := fetch_track_page(
		access,
		source,
		id,
		0,
		allocator,
		session_access,
		reuse,
		cache_only,
	)
	if !rows_ok {
		if source == .Playlist {
			detail.rows_error = rows_status != 0 ? rows_status : -1
			return detail, 200, true
		}
		free_detail(&detail)
		return {}, rows_status, false
	}
	if detail.total == 0 {detail.total = total}
	detail.rows = rows
	detail.next_offset = next_offset
	detail.has_more = has_more
	if source == .Liked && len(detail.rows) > 0 {
		detail.image = strings.clone(detail.rows[0].image, allocator)
		detail.image_small = strings.clone(detail.rows[0].image_small, allocator)
	}
	return detail, 200, true
}

fetch_header :: proc(
	$T: typeid,
	access, id, resource: string,
	reuse: rawptr = nil,
	cache_only: bool = false,
) -> (
	header: T,
	status: int,
	ok: bool,
) {
	if !safe_id(id) {return {}, 0, false}
	address := fmt.aprintf("https://api.spotify.com/v1/%s/%s", resource, id)
	defer delete(address)
	bytes: [dynamic]u8
	fetched: bool
	bytes, status, fetched = api_get(access, address, 256 * 1024, reuse, cache_only = cache_only)
	if !fetched {return {}, status, false}
	defer delete(bytes)
	if status != 200 {return {}, status, false}
	if json.unmarshal(bytes[:], &header, allocator = context.temp_allocator) !=
	   nil {return {}, status, false}
	if len(header.name) == 0 {return {}, status, false}
	return header, status, true
}

fetch_track_page :: proc(
	access: string,
	source: Source,
	id: string,
	offset: int,
	allocator: runtime.Allocator,
	session_access: string = "",
	reuse: rawptr = nil,
	cache_only: bool = false,
) -> (
	rows: [dynamic]Track_Row,
	total: int,
	next_offset: int,
	has_more: bool,
	status: int,
	ok: bool,
) {
	if offset < 0 || offset > 1_000_000 || !safe_id(id) {return}
	if source == .Artist {return}
	body, body_status, fetched := fetch_track_body(access, source, id, offset, reuse, cache_only)
	defer delete(body)
	if fetched && source == .Playlist && body_status == 403 && session_access != "" {
		return fetch_playlist_rows(session_access, id, offset, allocator, reuse)
	}
	if !fetched || body_status != 200 {return nil, 0, 0, false, body_status, false}
	switch source {
	case .Album:
		return parse_album_tracks(body[:], allocator)
	case .Playlist:
		return parse_playlist_items(body[:], allocator)
	case .Liked:
		return parse_saved_tracks(body[:], allocator)
	case .Artist:
	}
	return
}

// Rows only need identity, artists and covers; the shape is unchanged,
// but a full track object per item costs most of every page's bytes.
// Playlist items carry the object under `item`; `track` is deprecated and
// comes back unusable, so select `item` here, not `track`.
TRACK_FIELDS :: "uri,name,duration_ms,artists(name),album(images)"

track_page_address :: proc(
	source: Source,
	id: string,
	offset: int,
) -> (
	address: string,
	ok: bool,
) {
	switch source {
	case .Liked:
		address = fmt.aprintf(
			"https://api.spotify.com/v1/me/tracks?limit=50&offset=%d&fields=total,offset,next,items(track(%s))",
			offset,
			TRACK_FIELDS,
		)
	case .Playlist:
		address = fmt.aprintf(
			"https://api.spotify.com/v1/playlists/%s/items?limit=50&offset=%d&fields=total,offset,next,items(item(%s))",
			id,
			offset,
			TRACK_FIELDS,
		)
	case .Album:
		address = fmt.aprintf(
			"https://api.spotify.com/v1/albums/%s/tracks?limit=50&offset=%d&fields=total,offset,next,items(uri,name,duration_ms,artists(name))",
			id,
			offset,
		)
	case .Artist:
		return
	}
	return address, true
}

fetch_track_body :: proc(
	access: string,
	source: Source,
	id: string,
	offset: int,
	reuse: rawptr = nil,
	cache_only: bool = false,
) -> (
	body: [dynamic]u8,
	status: int,
	ok: bool,
) {
	address, addressed := track_page_address(source, id, offset)
	if !addressed {return}
	defer delete(address)
	return api_get(access, address, 2 * 1024 * 1024, reuse, cache_only = cache_only)
}

parse_saved_tracks :: proc(
	body: []u8,
	allocator: runtime.Allocator,
) -> (
	rows: [dynamic]Track_Row,
	total: int,
	next_offset: int,
	has_more: bool,
	status: int,
	ok: bool,
) {
	decoded: Offset_Page(Saved_Track)
	if json.unmarshal(body, &decoded, allocator = context.temp_allocator) != nil {return}
	return saved_track_rows(
		decoded.items,
		decoded.total,
		decoded.offset,
		len(decoded.next) > 0,
		allocator,
	)
}

parse_playlist_items :: proc(
	body: []u8,
	allocator: runtime.Allocator,
) -> (
	rows: [dynamic]Track_Row,
	total: int,
	next_offset: int,
	has_more: bool,
	status: int,
	ok: bool,
) {
	decoded: Offset_Page(Playlist_Item)
	if json.unmarshal(body, &decoded, allocator = context.temp_allocator) != nil {return}
	if !sane_page(decoded.total, len(decoded.items), decoded.offset) {return}
	rows = make([dynamic]Track_Row, 0, len(decoded.items), allocator)
	for item in decoded.items {
		row, valid := track_row(item.item, allocator)
		if !valid {continue}
		append(&rows, row)
	}
	return rows,
		decoded.total,
		decoded.offset + len(decoded.items),
		len(decoded.next) > 0 && len(decoded.items) > 0,
		200,
		true
}

parse_album_tracks :: proc(
	body: []u8,
	allocator: runtime.Allocator,
) -> (
	rows: [dynamic]Track_Row,
	total: int,
	next_offset: int,
	has_more: bool,
	status: int,
	ok: bool,
) {
	decoded: Offset_Page(Track_Ref)
	if json.unmarshal(body, &decoded, allocator = context.temp_allocator) != nil {return}
	if !sane_page(decoded.total, len(decoded.items), decoded.offset) {return}
	rows = make([dynamic]Track_Row, 0, len(decoded.items), allocator)
	for track in decoded.items {
		row, valid := track_row(track, allocator)
		if !valid {continue}
		append(&rows, row)
	}
	return rows,
		decoded.total,
		decoded.offset + len(decoded.items),
		len(decoded.next) > 0 && len(decoded.items) > 0,
		200,
		true
}

fetch_artist_albums :: proc(
	access, id: string,
	offset: int,
	allocator: runtime.Allocator,
	reuse: rawptr = nil,
	cache_only: bool = false,
) -> (
	releases: [dynamic]Entry,
	total: int,
	next_offset: int,
	has_more: bool,
	status: int,
	ok: bool,
) {
	if !safe_id(id) || offset < 0 || offset > 1_000_000 {return}
	address := fmt.aprintf(
		"https://api.spotify.com/v1/artists/%s/albums?limit=10&offset=%d",
		id,
		offset,
	)
	defer delete(address)
	body, body_status, fetched := api_get(
		access,
		address,
		512 * 1024,
		reuse,
		cache_only = cache_only,
	)
	if !fetched || body_status != 200 {delete(body); return {}, 0, 0, false, body_status, false}
	defer delete(body)
	return parse_artist_albums(body[:], allocator)
}

parse_artist_albums :: proc(
	body: []u8,
	allocator: runtime.Allocator,
) -> (
	releases: [dynamic]Entry,
	total: int,
	next_offset: int,
	has_more: bool,
	status: int,
	ok: bool,
) {
	decoded: Offset_Page(Album_Ref)
	if json.unmarshal(body, &decoded, allocator = context.temp_allocator) != nil {return}
	if !sane_page(decoded.total, len(decoded.items), decoded.offset, limit = 10) {return}
	releases = make([dynamic]Entry, 0, len(decoded.items), allocator)
	for album in decoded.items {
		if len(album.name) == 0 || len(album.uri) == 0 || len(album.uri) > 128 {continue}
		append(
			&releases,
			Entry {
				name = strings.clone(album.name, allocator),
				uri = strings.clone(album.uri, allocator),
				image = strings.clone(cover_url(album.images), allocator),
				subtitle = release_year(album.release_date, allocator),
				total = album.total_tracks,
			},
		)
	}
	return releases,
		decoded.total,
		decoded.offset + len(decoded.items),
		len(decoded.next) > 0 && len(decoded.items) > 0,
		200,
		true
}

saved_track_rows :: proc(
	items: []Saved_Track,
	total, offset: int,
	next: bool,
	allocator: runtime.Allocator,
) -> (
	rows: [dynamic]Track_Row,
	out_total: int,
	next_offset: int,
	has_more: bool,
	status: int,
	ok: bool,
) {
	if !sane_page(total, len(items), offset) {return}
	rows = make([dynamic]Track_Row, 0, len(items), allocator)
	for item in items {
		row, valid := track_row(item.track, allocator)
		if !valid {continue}
		append(&rows, row)
	}
	return rows, total, offset + len(items), next && len(items) > 0, 200, true
}

track_row :: proc(track: Track_Ref, allocator: runtime.Allocator) -> (row: Track_Row, ok: bool) {
	if len(track.name) == 0 || len(track.uri) > 128 || track.duration_ms < 0 {return}
	return {
			uri = strings.clone(track.uri, allocator),
			name = strings.clone(track.name, allocator),
			artists = joined_artists(track.artists, allocator),
			duration_ms = track.duration_ms,
			image = strings.clone(cover_url(track.album.images), allocator),
			image_small = strings.clone(cover_url_smallest(track.album.images), allocator),
		},
		true
}

safe_id :: proc(id: string) -> bool {
	if len(id) == 0 || len(id) > 64 {return false}
	for ch in transmute([]u8)id {
		if !(ch >= '0' && ch <= '9' ||
			   ch >= 'a' && ch <= 'z' ||
			   ch >= 'A' && ch <= 'Z') {return false}
	}
	return true
}

// Library membership for the hero heart through the unified /me/library
// endpoints: GET contains to check, PUT to save, DELETE to remove. Liked
// Songs has no membership to check. Spotify IDs are alphanumeric, but the
// full URI still rides percent-encoded in the query string.
library_uri :: proc(source: Source, id: string, allocator := context.allocator) -> string {
	if !safe_id(id) {return ""}
	#partial switch source {
	case .Playlist:
		return fmt.aprintf("spotify:playlist:%s", id, allocator = allocator)
	case .Album:
		return fmt.aprintf("spotify:album:%s", id, allocator = allocator)
	case .Artist:
		return fmt.aprintf("spotify:artist:%s", id, allocator = allocator)
	}
	return ""
}

saved_check_url :: proc(source: Source, id: string, allocator := context.allocator) -> string {
	uri := library_uri(source, id, allocator)
	if len(uri) == 0 {return ""}
	defer delete(uri, allocator)
	encoded := net.percent_encode(uri)
	defer delete(encoded)
	return fmt.aprintf(
		"https://api.spotify.com/v1/me/library/contains?uris=%s",
		encoded,
		allocator = allocator,
	)
}

like_url :: proc(uri: string, allocator := context.allocator) -> string {
	if len(uri) == 0 {return ""}
	encoded := net.percent_encode(uri)
	defer delete(encoded)
	return fmt.aprintf(
		"https://api.spotify.com/v1/me/library?uris=%s",
		encoded,
		allocator = allocator,
	)
}

// Reads through the shared worker handle but never the GET cache, so a
// just-toggled collection reports its new state on reopen. `known` is false
// when the check itself failed, which must not read as "not saved".
fetch_saved :: proc(
	access: string,
	source: Source,
	id: string,
	reuse: rawptr = nil,
) -> (
	liked: bool,
	known: bool,
) {
	address := saved_check_url(source, id)
	if len(address) == 0 {return false, false}
	defer delete(address)
	body, status, ok := http.get(address, {bearer = access, limit = 1024}, reuse)
	defer delete(body)
	if !ok || status != 200 {return false, false}
	flags: [dynamic]bool
	if json.unmarshal(body[:], &flags, allocator = context.temp_allocator) !=
	   nil {return false, false}
	if len(flags) == 0 {return false, false}
	return flags[0], true
}

set_saved :: proc(
	access, uri: string,
	liked: bool,
	reuse: rawptr = nil,
) -> (
	status: int,
	ok: bool,
) {
	address := like_url(uri)
	if len(address) == 0 {return 0, false}
	defer delete(address)
	status, ok = http.write(liked ? "PUT" : "DELETE", address, {bearer = access}, reuse)
	// A completed exchange is not a save: a 403 or a 429 must not flip the
	// heart while Spotify kept nothing.
	return status, ok && status >= 200 && status < 300
}
