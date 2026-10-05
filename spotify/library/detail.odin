// A playlist, album, artist or liked-songs page: header metadata plus its rows.
// Like a library page, a detail owns one arena and is released in one call.
package library

import "base:runtime"
import "core:encoding/json"
import "core:fmt"
import "core:mem/virtual"
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
	source:        Source,
	id:            string,
	label:         string, // Album, Playlist, Artist or Liked Songs
	name:          string,
	subtitle:      string,
	image:         string,
	image_small:   string,
	image_preview: string, // selected card cover, retained until hero texture is ready
	total:         int,
	rows:          [dynamic]Track_Row,
	releases:      [dynamic]Entry,
	next_offset:   int,
	has_more:      bool,
	rows_error:    int,
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
		)
		if !header_ok {
			free_detail(&detail)
			return {}, header_status, false
		}
		detail.label = strings.clone("Album", allocator)
		detail.name = strings.clone(header.name, allocator)
		detail.subtitle = joined_artists(header.artists, allocator)
		detail.image = strings.clone(cover_url_largest(header.images), allocator)
		detail.image_small = strings.clone(cover_url_smallest(header.images), allocator)
		detail.total = header.total_tracks
		if len(header.release_date) >= 4 {
			detail.subtitle = fmt.aprintf(
				"%s · %s",
				detail.subtitle,
				header.release_date[:4],
				allocator = allocator,
			)
		}
	case .Artist:
		header, header_status, header_ok := fetch_header(
			Raw_Artist,
			access,
			id,
			"artists",
			reuse = reuse,
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
			fetch_artist_albums(access, id, 0, allocator)
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
	bytes, status, fetched = api_get(access, address, 256 * 1024, reuse)
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
	body, body_status, fetched := fetch_track_body(access, source, id, offset)
	defer delete(body)
	if fetched && source == .Playlist && body_status == 403 && session_access != "" {
		return fetch_playlist_rows(session_access, id, offset, allocator)
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

fetch_track_body :: proc(
	access: string,
	source: Source,
	id: string,
	offset: int,
) -> (
	body: [dynamic]u8,
	status: int,
	ok: bool,
) {
	address: string
	switch source {
	case .Liked:
		address = fmt.aprintf("https://api.spotify.com/v1/me/tracks?limit=50&offset=%d", offset)
	case .Playlist:
		address = fmt.aprintf(
			"https://api.spotify.com/v1/playlists/%s/items?limit=50&offset=%d",
			id,
			offset,
		)
	case .Album:
		address = fmt.aprintf(
			"https://api.spotify.com/v1/albums/%s/tracks?limit=50&offset=%d",
			id,
			offset,
		)
	case .Artist:
		return
	}
	defer delete(address)
	return api_get(access, address, 2 * 1024 * 1024)
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
	body, body_status, fetched := api_get(access, address, 512 * 1024, reuse)
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
				subtitle = len(album.release_date) >= 4 ? strings.clone(album.release_date[:4], allocator) : "",
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
