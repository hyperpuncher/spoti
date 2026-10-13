// Read-only internal playlist windows and batched track metadata.
// References: playlist4_external.proto, extended_metadata.proto and metadata.proto.
// All intermediate strings are views or temporary allocations. Only Track_Row
// values, cloned into the caller's response arena, leave the worker.
package library

import diagnostic "../../diagnostic"
import ap "../ap"
import http "../http"
import track "../track"
import "base:runtime"
import "core:encoding/hex"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"
import "core:time"

PLAYLIST_PAGE_SIZE :: 50
PLAYLIST_INVALID_RESPONSE :: -2

Playlist_Window :: struct {
	uris:        []string,
	total:       int,
	next_offset: int,
}

fetch_playlist_rows :: proc(
	access, id: string,
	offset: int,
	allocator: runtime.Allocator,
	reuse: rawptr = nil,
	refresh: bool = false,
) -> (
	rows: [dynamic]Track_Row,
	total, next_offset: int,
	has_more: bool,
	status: int,
	ok: bool,
) {
	if len(id) != 22 || offset < 0 || offset > 1_000_000 {return}
	if _, valid := track.parse_id(id); !valid {return}
	// AP rows cache exactly like Web API bodies: a fresh pair parses
	// straight off disk, a failed fetch falls back to the stale pair.
	if !refresh {
		if cached_rows, cached_total, cached_next, cached_more, cached := read_playlist_cache(
			id,
			offset,
			allocator,
			PAGE_TTL,
		); cached {
			return cached_rows, cached_total, cached_next, cached_more, 200, true
		}
	}
	body, code, fetched := fetch_playlist_body(access, id, offset, reuse, refresh)
	defer delete(body)
	if !fetched || code != 200 {
		if cached_rows, cached_total, cached_next, cached_more, cached := read_playlist_cache(
			id,
			offset,
			allocator,
			API_STALE,
		); cached {
			diagnostic.writef("playlist reused stale rows offset=%d", offset)
			return cached_rows, cached_total, cached_next, cached_more, 200, true
		}
		return nil, 0, 0, false, code, false
	}
	window, valid := parse_playlist_window(body[:], offset)
	if !valid {return nil, 0, 0, false, PLAYLIST_INVALID_RESPONSE, false}
	request := playlist_metadata_request(window.uris)
	defer delete(request)
	if len(request) == 0 {
		window_key := playlist_cache_key("ap-playlist-window", id, offset)
		defer delete(window_key)
		cache_write("api", window_key, body[:])
		return nil, window.total, window.next_offset, window.next_offset < window.total, 200, true
	}
	metadata, metadata_code, received := http.post_protobuf(
		"https://spclient.wg.spotify.com/extended-metadata/v0/extended-metadata",
		request[:],
		{bearer = access, limit = 2 * 1024 * 1024},
		reuse,
	)
	defer delete(metadata)
	if !received || metadata_code != 200 {
		if cached_rows, cached_total, cached_next, cached_more, cached := read_playlist_cache(
			id,
			offset,
			allocator,
			API_STALE,
		); cached {
			diagnostic.writef("playlist reused stale rows offset=%d", offset)
			return cached_rows, cached_total, cached_next, cached_more, 200, true
		}
		return nil, 0, 0, false, metadata_code, false
	}
	rows, valid = parse_playlist_metadata(metadata[:], window.uris, allocator)
	if !valid {return nil, 0, 0, false, PLAYLIST_INVALID_RESPONSE, false}
	write_playlist_cache(id, offset, body[:], metadata[:])
	return rows, window.total, window.next_offset, window.next_offset < window.total, 200, true
}

fetch_playlist_body :: proc(
	access, id: string,
	offset: int,
	reuse: rawptr = nil,
	refresh: bool = false,
) -> (
	body: [dynamic]u8,
	status: int,
	ok: bool,
) {
	address := fmt.aprintf(
		"https://spclient.wg.spotify.com/playlist/v2/playlist/%s?decorate=revision,length,attributes,owner&from=%d&length=%d",
		id,
		offset,
		PLAYLIST_PAGE_SIZE,
		allocator = context.temp_allocator,
	)
	return api_get(access, address, 512 * 1024, reuse, ttl = PAGE_TTL, refresh = refresh)
}

// Read the title, artwork and rows from the same session. The row cache
// already retains this header body, so opening a warm page adds no request.
fetch_session_playlist_detail :: proc(
	access, id: string,
	reuse: rawptr = nil,
	refresh: bool = false,
) -> (
	detail: Detail,
	status: int,
	ok: bool,
) {
	if virtual.arena_init_growing(&detail.arena) != nil {return}
	defer if !ok {free_detail(&detail)}
	allocator := virtual.arena_allocator(&detail.arena)
	rows_ok: bool
	detail.rows, detail.total, detail.next_offset, detail.has_more, status, rows_ok =
		fetch_playlist_rows(access, id, 0, allocator, reuse, refresh)
	if !rows_ok {return}
	key := playlist_cache_key("ap-playlist-window", id, 0)
	defer delete(key)
	body, hit := cache_read("api", key, API_STALE)
	if !hit {
		fetched: bool
		body, status, fetched = fetch_playlist_body(access, id, 0, reuse)
		if !fetched || status != 200 {delete(body); return}
	}
	defer delete(body)
	attributes, _, valid := ap.get_bytes(body[:], 3)
	owner, _, owner_valid := ap.get_bytes(body[:], 16)
	if !valid || !owner_valid {status = PLAYLIST_INVALID_RESPONSE; return}
	header, parsed := playlist_attributes(attributes)
	if !parsed || header.name == "" {status = PLAYLIST_INVALID_RESPONSE; return}
	detail.ready, detail.source = true, .Playlist
	detail.id = strings.clone(id, allocator)
	detail.label = strings.clone("Playlist", allocator)
	detail.name = strings.clone(header.name, allocator)
	detail.owner_id, detail.subtitle =
		strings.clone(string(owner), allocator), strings.clone(string(owner), allocator)
	detail.collaborative = header.collaborative
	detail.image = strings.clone(cover_url_largest(header.images), allocator)
	detail.image_small = strings.clone(cover_url_smallest(header.images), allocator)
	return detail, 200, true
}

playlist_cache_key :: proc(prefix, id: string, offset: int) -> string {
	return fmt.aprintf("%s:%s:%d", prefix, id, offset)
}

read_playlist_cache :: proc(
	id: string,
	offset: int,
	allocator: runtime.Allocator,
	ttl: time.Duration,
) -> (
	rows: [dynamic]Track_Row,
	total, next_offset: int,
	has_more: bool,
	ok: bool,
) {
	window_key := playlist_cache_key("ap-playlist-window", id, offset)
	defer delete(window_key)
	window_body, window_hit := cache_read("api", window_key, ttl)
	if !window_hit {return}
	defer delete(window_body)
	window, valid := parse_playlist_window(window_body[:], offset)
	if !valid {return {}, 0, 0, false, false}
	playable := false
	for uri in window.uris {
		if _, supported := playlist_track_id(uri); supported {playable = true; break}
	}
	if !playable {
		return nil, window.total, window.next_offset, window.next_offset < window.total, true
	}
	meta_key := playlist_cache_key("ap-playlist-meta", id, offset)
	defer delete(meta_key)
	meta_body, meta_hit := cache_read("api", meta_key, ttl)
	if !meta_hit {return}
	defer delete(meta_body)
	parsed, parsed_ok := parse_playlist_metadata(meta_body[:], window.uris, allocator)
	if !parsed_ok {return {}, 0, 0, false, false}
	return parsed, window.total, window.next_offset, window.next_offset < window.total, true
}

write_playlist_cache :: proc(id: string, offset: int, window, metadata: []u8) {
	window_key := playlist_cache_key("ap-playlist-window", id, offset)
	defer delete(window_key)
	meta_key := playlist_cache_key("ap-playlist-meta", id, offset)
	defer delete(meta_key)
	cache_write("api", window_key, window)
	cache_write("api", meta_key, metadata)
}

parse_playlist_window :: proc(body: []u8, offset: int) -> (window: Playlist_Window, ok: bool) {
	length, found, length_valid := ap.get_number(body, 2)
	if !length_valid || !found || length > 1_000_000 || offset < 0 || offset > 1_000_000 {return}
	contents, present, readable := ap.get_bytes(body, 5)
	if !readable || !present {return}
	position, seen, parsed := ap.get_number(contents, 1)
	if !parsed || !seen || position != u64(offset) {return}
	truncated, marked, decoded := ap.get_number(contents, 2)
	if !decoded || !marked || truncated > 1 {return}
	uris := make([dynamic]string, 0, PLAYLIST_PAGE_SIZE, context.temp_allocator)
	pos := 0
	for pos < len(contents) {
		field, wire, item, _, field_valid := ap.next_field(contents, &pos)
		if !field_valid {return}
		if field != 3 {continue}
		if wire != 2 || len(uris) >= PLAYLIST_PAGE_SIZE {return}
		uri, uri_found, item_valid := ap.get_bytes(item, 1)
		if !item_valid || !uri_found || len(uri) == 0 || len(uri) > 512 {return}
		append(&uris, string(uri))
	}
	window.total = int(length)
	window.next_offset = offset + len(uris)
	if len(uris) < PLAYLIST_PAGE_SIZE && window.next_offset < window.total {return}
	if len(uris) > 0 && window.next_offset > window.total {return}
	window.uris = uris[:]
	return window, true
}

playlist_track_id :: proc(uri: string) -> (id: [16]u8, ok: bool) {
	if !strings.has_prefix(uri, "spotify:track:") ||
	   len(uri) != len("spotify:track:") + 22 {return}
	return track.parse_id(uri)
}

playlist_metadata_request :: proc(uris: []string) -> [dynamic]u8 {
	request := make([dynamic]u8)
	asked := make(map[string]bool, context.temp_allocator)
	for uri in uris {
		if _, supported := playlist_track_id(uri); !supported || uri in asked {continue}
		asked[uri] = true
		ap.extension_request(&request, uri, ap.TRACK_V4)
	}
	return request
}

Playlist_Answer :: struct {
	seen: bool,
	row:  Track_Row,
}

parse_playlist_metadata :: proc(
	body: []u8,
	uris: []string,
	allocator: runtime.Allocator,
) -> (
	rows: [dynamic]Track_Row,
	ok: bool,
) {
	answers := make(map[string]Playlist_Answer, context.temp_allocator)
	for uri in uris {
		if _, supported := playlist_track_id(uri); supported {answers[uri] = {}}
	}
	pos := 0
	for pos < len(body) {
		array_field, array_wire, array, _, array_valid := ap.next_field(body, &pos)
		if !array_valid {return}
		if array_field != 2 {continue}
		if array_wire != 2 {return}
		kind, _, kind_valid := ap.get_number(array, 2)
		if !kind_valid {return}
		if kind != 10 {continue}
		provider, provider_valid := ap.extension_status(array)
		if !provider_valid || provider != 0 && provider != 200 {return}
		cursor := 0
		for cursor < len(array) {
			entity_field, entity_wire, entity, _, entity_valid := ap.next_field(array, &cursor)
			if !entity_valid {return}
			if entity_field != 3 {continue}
			if entity_wire != 2 {return}
			uri_bytes, present, uri_valid := ap.get_bytes(entity, 2)
			if !present || !uri_valid {return}
			uri := string(uri_bytes)
			answer, requested := &answers[uri]
			if !requested || answer.seen {return}
			code, status_valid := ap.extension_status(entity)
			if !status_valid {return}
			answer.seen = true
			if code == 404 || code == 451 {continue} 	// unavailable tracks are not playable
			if code != 0 && code != 200 {return}
			any, has_data, data_valid := ap.get_bytes(entity, 3)
			if !has_data || !data_valid {return}
			metadata, has_payload, payload_valid := ap.get_bytes(any, 2)
			if !has_payload || !payload_valid {return}
			row, row_valid := playlist_track_row(metadata, uri, allocator)
			if !row_valid {return}
			answer.row = row
		}
	}
	for _, answer in answers {
		if !answer.seen {return}
	}
	rows = make([dynamic]Track_Row, 0, len(uris), allocator)
	for uri in uris {
		answer, present := answers[uri]
		if present && answer.row.uri != "" {append(&rows, answer.row)}
	}
	return rows, true
}

// Decode the display fields, then use the same row/cover conversion as the Web API.
// Audio files are resolved only when the user actually plays a track.
playlist_track_row :: proc(
	body: []u8,
	uri: string,
	allocator: runtime.Allocator,
) -> (
	row: Track_Row,
	ok: bool,
) {
	id, id_valid := playlist_track_id(uri)
	if !id_valid {return}
	gid, found, gid_valid := ap.get_bytes(body, 1)
	if !found || !gid_valid || len(gid) != 16 {return}
	for b, i in gid {if b != id[i] {return}}
	name, present, readable := ap.get_bytes(body, 2)
	if !present || !readable {return}
	duration, _, decoded := ap.get_number(body, 7)
	if !decoded || duration & 1 != 0 || duration >> 1 > u64(max(i32)) {return}
	ref := Track_Ref {
			uri         = uri,
			name        = string(name),
			duration_ms = int(duration >> 1),
		}
	artists := make([dynamic]Artist, context.temp_allocator)
	images := make([dynamic]Image, context.temp_allocator)
	album_name, album_uri := "", ""
	pos := 0
	for pos < len(body) {
		field, wire, bytes, _, field_valid := ap.next_field(body, &pos)
		if !field_valid {return}
		switch field {
		case 4:
			if wire != 2 || len(artists) >= 128 {return}
			artist_name, _, artist_valid := ap.get_bytes(bytes, 2)
			if !artist_valid {return}
			// The GID is best-effort: a nameless link beats a dropped row.
			artist_uri := ""
			if artist_gid, _, artist_gid_valid := ap.get_bytes(bytes, 1);
			   artist_gid_valid && len(artist_gid) == 16 {
				raw: [16]u8
				copy(raw[:], artist_gid)
				id := track.base62_id(raw, context.temp_allocator)
				artist_uri = fmt.aprintf(
					"spotify:artist:%s",
					id,
					allocator = context.temp_allocator,
				)
			}
			if len(artist_name) > 0 {
				append(&artists, Artist{name = string(artist_name), uri = artist_uri})
			}
		case 3:
			if wire != 2 || !playlist_album_images(bytes, &images) {return}
			if album_gid, _, album_gid_valid := ap.get_bytes(bytes, 1);
			   album_gid_valid && len(album_gid) == 16 {
				raw: [16]u8
				copy(raw[:], album_gid)
				id := track.base62_id(raw, context.temp_allocator)
				album_uri = fmt.aprintf("spotify:album:%s", id, allocator = context.temp_allocator)
			}
			if album_title, _, album_title_valid := ap.get_bytes(bytes, 2);
			   album_title_valid && len(album_title) > 0 {
				album_name = string(album_title)
			}
		}
	}
	ref.artists, ref.album.images = artists[:], images[:]
	ref.album.name, ref.album.uri = album_name, album_uri
	return track_row(ref, allocator)
}

playlist_album_images :: proc(body: []u8, images: ^[dynamic]Image, group: bool = false) -> bool {
	pos := 0
	for pos < len(body) {
		field, wire, bytes, _, valid := ap.next_field(body, &pos)
		if !valid {return false}
		if !group && field == 17 {
			if wire != 2 || !playlist_album_images(bytes, images, true) {return false}
		} else if field == (group ? 1 : 9) {
			if wire != 2 || len(images^) >= 32 {return false}
			id, found, parsed := ap.get_bytes(bytes, 1)
			if !parsed {return false}
			if !found || len(id) != 20 {continue}
			size, _, decoded := ap.get_number(bytes, 2)
			width, _, readable := ap.get_number(bytes, 3)
			if !decoded || !readable || width & 1 != 0 || width >> 1 > u64(max(i32)) {return false}
			pixels := int(width >> 1)
			if pixels == 0 {pixels = size == 1 ? 64 : size == 2 ? 640 : size == 3 ? 1200 : 300}
			encoded := hex.encode(id, context.temp_allocator)
			url := fmt.aprintf(
				"https://i.scdn.co/image/%s",
				string(encoded),
				allocator = context.temp_allocator,
			)
			append(images, Image{url = url, width = pixels})
		}
	}
	return true
}
