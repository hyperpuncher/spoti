package library

import http "../http"
import "core:encoding/json"
import "core:fmt"
import "core:strconv"

// getAlbum from the web-player query registry. Private query hashes can change.
ALBUM_COUNTS_HASH :: "0b6ce3511e1b02e4a40fa95440f992acbe85080eb308af9194322d708fc1914f"

parse_album_counts :: proc(body: []u8, id: string, offset: int, rows: []Track_Row) -> bool {
	response: struct {
		errors: []json.Value,
		data:   struct {
			album: struct {
				uri:    string,
				tracks: struct {
					total: int `json:"totalCount"`,
					items: []struct {
						track: struct {
							uri:   string,
							count: string `json:"playcount"`,
						},
					},
				} `json:"tracksV2"`,
			} `json:"albumUnion"`,
		},
	}
	if json.unmarshal(body, &response, allocator = context.temp_allocator) != nil ||
	   len(response.errors) != 0 {return false}
	album := response.data.album
	if album.uri != fmt.aprintf("spotify:album:%s", id, allocator = context.temp_allocator) ||
	   len(album.tracks.items) == 0 ||
	   !sane_page(album.tracks.total, len(album.tracks.items), offset, 50) {return false}
	for item in album.tracks.items {
		count, valid := strconv.parse_i64(item.track.count)
		if !valid || count <= 0 || item.track.uri == "" {continue}
		for &row in rows {
			if row.uri == item.track.uri {row.play_count = count}
		}
	}
	return true
}

fetch_album_counts :: proc(
	access, id: string,
	offset: int,
	rows: []Track_Row,
	reuse: rawptr,
	cancel: ^bool,
	cache_only: bool = false,
) -> bool {
	if len(rows) == 0 || !safe_id(id) || offset < 0 || offset > 1_000_000 {return false}
	key := fmt.aprintf(
		"album-counts:%s:%s:%d",
		ALBUM_COUNTS_HASH,
		id,
		offset,
		allocator = context.temp_allocator,
	)
	if cached, hit := cache_read("api", key, cache_only ? API_STALE : PAGE_TTL); hit {
		defer delete(cached)
		if parse_album_counts(cached[:], id, offset, rows) {return true}
	}
	if cache_only || access == "" {return false}
	variables := struct {
		uri, locale:   string,
		offset, limit: int,
	} {
		uri    = fmt.aprintf("spotify:album:%s", id, allocator = context.temp_allocator),
		offset = offset,
		limit  = 50,
	}
	encoded, ok := persisted_query_request("getAlbum", ALBUM_COUNTS_HASH, variables)
	if !ok {return false}
	body, status, fetched := http.json_request(
		"POST",
		PATHFINDER_QUERY_ADDRESS,
		string(encoded),
		{bearer = access, limit = 2 * 1024 * 1024, cancel = cancel},
		reuse,
	)
	defer delete(body)
	if fetched && status == 200 && parse_album_counts(body[:], id, offset, rows) {
		cache_write("api", key, body[:])
		return true
	}
	if cached, hit := cache_read("api", key, API_STALE); hit {
		defer delete(cached)
		return parse_album_counts(cached[:], id, offset, rows)
	}
	return false
}
