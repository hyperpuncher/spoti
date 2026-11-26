package library

import session "../session"
import track "../track"
import "core:encoding/base64"
import "core:fmt"
import "core:mem/virtual"
import "core:strings"

valid_radio_id :: proc(id: string) -> bool {
	prefixes := [?]string{"track:", "artist:"}
	for prefix in prefixes {
		if strings.has_prefix(id, prefix) && len(id) == len(prefix) + 22 {
			return safe_id(id[len(prefix):])
		}
	}
	return false
}

radio_uri :: proc(seed: string) -> string {
	if !strings.has_prefix(seed, "spotify:") {return ""}
	id := seed[len("spotify:"):]
	if !valid_radio_id(id) {return ""}
	return fmt.tprintf("spotify:station:%s", id)
}

RADIO_TRACK_LIMIT :: 50

radio_tracks :: proc(ctx: session.Playback_Context) -> []string {
	uris := make([dynamic]string, 0, RADIO_TRACK_LIMIT, context.temp_allocator)
	seen := make(map[string]bool, context.temp_allocator)
	for page in ctx.pages {
		for item in page.tracks {
			uri := item.uri
			if uri == "" && item.gid != "" {
				gid, err := base64.decode(item.gid, allocator = context.temp_allocator)
				if err == nil && len(gid) == 16 {
					raw: [16]u8
					copy(raw[:], gid)
					uri = fmt.tprintf(
						"spotify:track:%s",
						track.base62_id(raw, context.temp_allocator),
					)
				}
			}
			if _, valid := playlist_track_id(uri); !valid || uri in seen {continue}
			seen[uri] = true
			append(&uris, uri)
			if len(uris) == RADIO_TRACK_LIMIT {return uris[:]}
		}
	}
	return uris[:]
}

// Resolve one mix and hydrate its rows in a batch. Playback uses these
// rows, not another request for a fresh mix.
read_radio :: proc(
	access, id: string,
	cancel: ^bool,
	reuse: rawptr,
) -> (
	detail: Detail,
	status: int,
	ok: bool,
) {
	if !valid_radio_id(id) {return {}, -1, false}
	uri := fmt.tprintf("spotify:station:%s", id)
	resolved, code, fetched := session.fetch_context(access, uri, cancel, reuse)
	if !fetched {return {}, code, false}
	uris := radio_tracks(resolved)
	if len(uris) == 0 {return {}, 404, false}
	request := playlist_metadata_request(uris)
	defer delete(request)
	body, metadata_code, received := fetch_track_metadata_batch(access, request[:], reuse, cancel)
	defer delete(body)
	if !received {return {}, metadata_code, false}
	if virtual.arena_init_growing(&detail.arena) != nil {return {}, -1, false}
	defer if !ok {free_detail(&detail)}
	allocator := virtual.arena_allocator(&detail.arena)
	rows, parsed := parse_playlist_metadata(body[:], uris, allocator)
	if !parsed {status = PLAYLIST_INVALID_RESPONSE; return}
	if len(rows) == 0 {status = 404; return}
	detail.ready, detail.source = true, .Radio
	detail.id, detail.label = strings.clone(id, allocator), "Radio"
	detail.rows, detail.total = rows, len(rows)
	status, ok = 200, true
	return
}
