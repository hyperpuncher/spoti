// Artist top tracks over the private metadata service. The public
// /artists/{id}/top-tracks endpoint refuses this app key with 403, so the
// rows come from the artist object instead, like librespot: an ARTIST_V4
// extended-metadata request answers with the artist message, whose
// top_track blocks hold one list of track ids per country. Those ids are
// then batched through the same TRACK_V4 request the playlist rows use.
// References: metadata.proto (Artist, TopTracks, Track), extended_metadata.proto.
package library

import diagnostic "../../diagnostic"
import ap "../ap"
import http "../http"
import track "../track"
import "base:runtime"
import "core:fmt"
import "core:time"

ARTIST_V4 :: 8
TOP_TRACKS_MAX :: 10
ARTIST_METADATA_LIMIT :: 2 * 1024 * 1024
ARTIST_METADATA_INVALID :: -4

// BatchedEntityRequest for one artist, asking only for ARTIST_V4.
artist_metadata_request :: proc(uri: string) -> [dynamic]u8 {
	request := make([dynamic]u8)
	entity := make([dynamic]u8)
	defer delete(entity)
	ap.put_bytes(&entity, 1, transmute([]u8)uri)
	ap.put_bytes(&entity, 2, []u8{0x08, ARTIST_V4}) // ExtensionQuery: ARTIST_V4
	ap.put_bytes(&request, 2, entity[:])
	return request
}

// The artist's most-played tracks, cached like any collection body so a
// reopen costs nothing and an offline open still has its rows.
fetch_artist_top_tracks :: proc(
	access, id: string,
	allocator: runtime.Allocator,
	reuse: rawptr = nil,
	country: string = "",
) -> (
	rows: [dynamic]Track_Row,
	status: int,
	ok: bool,
) {
	if len(id) != 22 {return}
	if _, valid := track.parse_id(id); !valid {return}
	artist_key := fmt.aprintf("ap-artist-meta:%s", id)
	defer delete(artist_key)
	tracks_key := fmt.aprintf("ap-artist-tracks:%s:%s", id, country)
	defer delete(tracks_key)
	if cached, hit := read_artist_top_cache(artist_key, tracks_key, country, PAGE_TTL, allocator);
	   hit {
		return cached, 200, true
	}
	artist, artist_status, have_artist := fetch_artist_body(access, id, artist_key, reuse)
	defer delete(artist)
	if !have_artist {
		if stale, hit := read_artist_top_cache(
			artist_key,
			tracks_key,
			country,
			API_STALE,
			allocator,
		); hit {
			diagnostic.writef("artist reused stale top tracks")
			return stale, 200, true
		}
		return nil, artist_status, false
	}
	uris, valid := parse_artist_top_uris(artist[:], country, context.temp_allocator)
	if !valid {return nil, ARTIST_METADATA_INVALID, false}
	if len(uris) == 0 {return {}, 200, true}
	request := playlist_metadata_request(uris)
	defer delete(request)
	if len(request) == 0 {return {}, 200, true}
	metadata, metadata_status, received := http.protobuf_request(
		"POST",
		ap.EXTENDED_METADATA_ADDRESS,
		request[:],
		{bearer = access, limit = ARTIST_METADATA_LIMIT},
		reuse,
	)
	defer delete(metadata)
	if !received || metadata_status != 200 {
		if stale, hit := read_artist_top_cache(
			artist_key,
			tracks_key,
			country,
			API_STALE,
			allocator,
		); hit {
			diagnostic.writef("artist reused stale top tracks")
			return stale, 200, true
		}
		return nil, metadata_status, false
	}
	cached, parsed := parse_playlist_metadata(metadata[:], uris, allocator)
	if !parsed {return nil, ARTIST_METADATA_INVALID, false}
	cache_write("api", tracks_key, metadata[:])
	return cached, 200, true
}

// Both bodies must be fresh for the pair to serve; the track body carries
// the rows and the artist body carries the id list that orders them.
read_artist_top_cache :: proc(
	artist_key, tracks_key, country: string,
	ttl: time.Duration,
	allocator: runtime.Allocator,
) -> (
	rows: [dynamic]Track_Row,
	hit: bool,
) {
	artist, artist_hit := cache_read("api", artist_key, ttl)
	if !artist_hit {return nil, false}
	defer delete(artist)
	uris, valid := parse_artist_top_uris(artist[:], country, context.temp_allocator)
	if !valid {return nil, false}
	if len(uris) == 0 {return {}, true}
	tracks, tracks_hit := cache_read("api", tracks_key, ttl)
	if !tracks_hit {return nil, false}
	defer delete(tracks)
	if cached, parsed := parse_playlist_metadata(tracks[:], uris, allocator); parsed {
		return cached, true
	}
	return nil, false
}

fetch_artist_body :: proc(
	access, id, key: string,
	reuse: rawptr,
) -> (
	body: [dynamic]u8,
	status: int,
	ok: bool,
) {
	uri := fmt.aprintf("spotify:artist:%s", id)
	defer delete(uri)
	request := artist_metadata_request(uri)
	defer delete(request)
	body, status, ok = http.protobuf_request(
		"POST",
		ap.EXTENDED_METADATA_ADDRESS,
		request[:],
		{bearer = access, limit = ARTIST_METADATA_LIMIT},
		reuse,
	)
	if !ok || status != 200 {delete(body); return nil, status, false}
	cache_write("api", key, body[:])
	return body, status, true
}

// The ordered track URIs of the chosen top_track block.
parse_artist_top_uris :: proc(
	body: []u8,
	country: string,
	allocator := context.allocator,
) -> (
	uris: []string,
	ok: bool,
) {
	artist, found, valid := ap.extension_message(body, ARTIST_V4)
	if !valid {return nil, false}
	if !found {return nil, true}
	return parse_artist_top_message(artist, country, allocator)
}

// Pick one top_track block, then collect its track ids. The account country
// wins; the empty block is the worldwide list; the first block is the last
// resort so a section Spotify would show never disappears here.
parse_artist_top_message :: proc(
	body: []u8,
	country: string,
	allocator: runtime.Allocator,
) -> (
	uris: []string,
	ok: bool,
) {
	block: []u8
	best_priority := -1
	pos := 0
	for pos < len(body) {
		field, wire, bytes, _, valid := ap.next_field(body, &pos)
		if !valid {return nil, false}
		if field != 4 {continue}
		if wire != 2 {return nil, false}
		name, _, name_valid := ap.get_bytes(bytes, 1)
		if !name_valid {return nil, false}
		priority := len(name) == 0 ? 1 : 0
		if country != "" && string(name) == country {priority = 2}
		if priority > best_priority {block, best_priority = bytes, priority}
	}
	if best_priority < 0 {return nil, true}
	found: [TOP_TRACKS_MAX]string
	count := 0
	pos = 0
	for pos < len(block) && count < TOP_TRACKS_MAX {
		field, wire, message, _, valid := ap.next_field(block, &pos)
		if !valid {return nil, false}
		if field != 2 {continue}
		if wire != 2 {return nil, false}
		gid, present, gid_valid := ap.get_bytes(message, 1)
		if !gid_valid {return nil, false}
		if !present || len(gid) != 16 {continue}
		raw: [16]u8
		copy(raw[:], gid)
		short := track.base62_id(raw, context.temp_allocator)
		found[count] = fmt.aprintf("spotify:track:%s", short, allocator = context.temp_allocator)
		count += 1
	}
	if count == 0 {return nil, true}
	uris = make([]string, count, allocator)
	copy(uris, found[:count])
	return uris, true
}
