// Read-only internal playlist windows and batched track metadata.
// References: playlist4_external.proto, extended_metadata.proto and metadata.proto.
// All intermediate strings are views or temporary allocations. Only Track_Row
// values, cloned into the caller's response arena, leave the worker.
package library

import ap "../ap"
import http "../http"
import track "../track"
import "base:runtime"
import "core:encoding/hex"
import "core:fmt"
import "core:strings"

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
) -> (
	rows: [dynamic]Track_Row,
	total, next_offset: int,
	has_more: bool,
	status: int,
	ok: bool,
) {
	if len(id) != 22 || offset < 0 || offset > 1_000_000 {return}
	if _, valid := track.parse_id(id); !valid {return}
	address := fmt.aprintf(
		"https://spclient.wg.spotify.com/playlist/v2/playlist/%s?decorate=revision,length,attributes,owner&from=%d&length=%d",
		id,
		offset,
		PLAYLIST_PAGE_SIZE,
	)
	defer delete(address)
	body, code, fetched := http.get(address, {bearer = access, limit = 512 * 1024})
	defer delete(body)
	if !fetched || code != 200 {return nil, 0, 0, false, code, false}
	window, valid := parse_playlist_window(body[:], offset)
	if !valid {return nil, 0, 0, false, PLAYLIST_INVALID_RESPONSE, false}
	request := playlist_metadata_request(window.uris)
	defer delete(request)
	if len(request) == 0 {
		return nil, window.total, window.next_offset, window.next_offset < window.total, 200, true
	}
	metadata, metadata_code, received := http.post_protobuf(
		"https://spclient.wg.spotify.com/extended-metadata/v0/extended-metadata",
		request[:],
		{bearer = access, limit = 2 * 1024 * 1024},
	)
	defer delete(metadata)
	if !received || metadata_code != 200 {return nil, 0, 0, false, metadata_code, false}
	rows, valid = parse_playlist_metadata(metadata[:], window.uris, allocator)
	if !valid {return nil, 0, 0, false, PLAYLIST_INVALID_RESPONSE, false}
	return rows, window.total, window.next_offset, window.next_offset < window.total, 200, true
}

parse_playlist_window :: proc(body: []u8, offset: int) -> (window: Playlist_Window, ok: bool) {
	length, found, valid := ap.get_number(body, 2)
	if !valid || !found || length > 1_000_000 || offset < 0 || offset > 1_000_000 {return}
	contents, present, readable := ap.get_bytes(body, 5)
	if !readable || !present {return}
	position, seen, parsed := ap.get_number(contents, 1)
	if !parsed || !seen || position != u64(offset) {return}
	truncated, marked, decoded := ap.get_number(contents, 2)
	if !decoded || !marked || truncated > 1 {return}
	uris := make([dynamic]string, 0, PLAYLIST_PAGE_SIZE, context.temp_allocator)
	pos := 0
	for pos < len(contents) {
		field, wire, item, _, valid := ap.next_field(contents, &pos)
		if !valid {return}
		if field != 3 {continue}
		if wire != 2 || len(uris) >= PLAYLIST_PAGE_SIZE {return}
		uri, found, item_valid := ap.get_bytes(item, 1)
		if !item_valid || !found || len(uri) == 0 || len(uri) > 512 {return}
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
		entity := make([dynamic]u8)
		ap.put_bytes(&entity, 1, transmute([]u8)uri)
		ap.put_bytes(&entity, 2, []u8{0x08, 10}) // ExtensionQuery: TRACK_V4
		ap.put_bytes(&request, 2, entity[:])
		delete(entity)
	}
	return request
}

Playlist_Answer :: struct {
	seen: bool,
	row:  Track_Row,
}

// Both extension arrays and entities place their status in header field 1.
playlist_proto_status :: proc(body: []u8) -> (code: u64, ok: bool) {
	header, _, valid := ap.get_bytes(body, 1)
	if !valid {return}
	code, _, ok = ap.get_number(header, 1)
	return
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
		field, wire, array, _, valid := ap.next_field(body, &pos)
		if !valid {return}
		if field != 2 {continue}
		if wire != 2 {return}
		kind, _, parsed := ap.get_number(array, 2)
		if !parsed {return}
		if kind != 10 {continue}
		provider, readable := playlist_proto_status(array)
		if !readable || provider != 0 && provider != 200 {return}
		cursor := 0
		for cursor < len(array) {
			field, wire, entity, _, valid := ap.next_field(array, &cursor)
			if !valid {return}
			if field != 3 {continue}
			if wire != 2 {return}
			uri_bytes, present, parsed := ap.get_bytes(entity, 2)
			if !present || !parsed {return}
			uri := string(uri_bytes)
			answer, requested := &answers[uri]
			if !requested || answer.seen {return}
			code, readable := playlist_proto_status(entity)
			if !readable {return}
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
	id, valid := playlist_track_id(uri)
	if !valid {return}
	gid, found, parsed := ap.get_bytes(body, 1)
	if !found || !parsed || len(gid) != 16 {return}
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
	pos := 0
	for pos < len(body) {
		field, wire, bytes, _, valid := ap.next_field(body, &pos)
		if !valid {return}
		switch field {
		case 4:
			if wire != 2 || len(artists) >= 128 {return}
			name, _, valid := ap.get_bytes(bytes, 2)
			if !valid {return}
			if len(name) > 0 {append(&artists, Artist{name = string(name)})}
		case 3:
			if wire != 2 || !playlist_album_images(bytes, &images) {return}
		}
	}
	ref.artists, ref.album.images = artists[:], images[:]
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
